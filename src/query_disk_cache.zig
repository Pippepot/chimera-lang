const std = @import("std");
const cache = @import("cache.zig");
const codec = @import("query/codec.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const structures = @import("structures.zig");

const format = "CHIQRY13";
const max_records = 1_000_000;

pub fn save(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, key: cache.Key, db: *query.Database) !void {
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.bytes.appendSlice(allocator, format);
    try db.writeInternedValues(&writer);
    try db.writeCompletedQueries(queries.AnalyzeFunctionInstance, &writer);
    try db.writeCompletedQueries(queries.CompileFunction, &writer);
    try cache.save(io, allocator, directory, key, writer.bytes.items);
}

pub fn restoreInterns(db: *query.Database, allocator: std.mem.Allocator, payload: []const u8) !usize {
    var reader: codec.Reader = .{ .allocator = allocator, .bytes = payload };
    if (!std.mem.eql(u8, try reader.take(format.len), format)) return error.InvalidCache;
    const count = try readCount(&reader);
    for (0..count) |index| {
        const name = try reader.read([]const u8);
        defer allocator.free(name);
        try restoreNamedIntern(name, db, &reader, index);
    }
    return reader.offset;
}

fn restoreNamedIntern(name: []const u8, db: *query.Database, reader: *codec.Reader, index: usize) !void {
    inline for (.{ queries.ModulePaths, queries.ItemLocations, queries.Types, queries.CompileTimeValues, queries.CompileTimeValueTuples }) |I| {
        if (std.mem.eql(u8, name, @typeName(I))) return restoreIntern(I, db, reader, index);
    }
    return error.InvalidCache;
}

fn restoreIntern(comptime I: type, db: *query.Database, reader: *codec.Reader, index: usize) !void {
    var value = try reader.read(I.Value);
    defer codec.freeValue(I.Value, reader.allocator, &value);
    if (!(try validateIds(I.Value, db, value))) return error.InvalidCache;
    if (I == queries.Types) {
        switch (value) {
            .variant => |variant| {
                if (variant.members.len < 2) return error.InvalidCache;
                for (variant.members[1..], 1..) |member, member_index| {
                    if (@intFromEnum(variant.members[member_index - 1]) >= @intFromEnum(member))
                        return error.InvalidCache;
                }
            },
            else => {},
        }
    }
    const id = try db.intern(I, value);
    if (@intFromEnum(id) != index) return error.InvalidCache;
}

pub fn restoreQueries(db: *query.Database, payload: []const u8, offset: usize) !usize {
    if (offset > payload.len) return error.InvalidCache;
    var reader: codec.Reader = .{ .allocator = db.allocator, .bytes = payload, .offset = offset };
    var imported = try restoreQuery(queries.AnalyzeFunctionInstance, db, &reader);
    imported += try restoreQuery(queries.CompileFunction, db, &reader);
    if (!reader.finished()) return error.InvalidCache;
    return imported;
}

fn restoreQuery(comptime Q: type, db: *query.Database, reader: *codec.Reader) !usize {
    const count = try readCount(reader);
    var imported_count: usize = 0;
    for (0..count) |_| {
        const input = try reader.read(Q.Input);
        var output = try reader.read(Q.Output);
        var transferred = false;
        defer if (!transferred) codec.freeValue(Q.Output, reader.allocator, &output);
        if (output == null) return error.InvalidCache;
        const dep_count = try readCount(reader);
        var deps: std.ArrayList(query.PersistedInputRef) = .empty;
        defer deps.deinit(reader.allocator);
        var query_deps: std.ArrayList(query.PersistedQueryRef) = .empty;
        defer query_deps.deinit(reader.allocator);
        var valid = try validateIds(Q.Input, db, input) and
            try validateIds(Q.Output, db, output) and
            try validOutput(Q, db, output);
        for (0..dep_count) |_| {
            const matched = try restoreNamedInput(db, reader, valid);
            if (matched) |dep| {
                try deps.append(reader.allocator, dep);
            } else valid = false;
        }
        const query_dep_count = try readCount(reader);
        for (0..query_dep_count) |_| {
            const matched = try restoreNamedQueryDependency(db, reader, valid);
            if (matched) |dep| {
                try query_deps.append(reader.allocator, dep);
            } else valid = false;
        }
        if (valid) {
            try db.importCompletedQuery(Q, input, output, deps.items, query_deps.items);
            transferred = true;
            imported_count += 1;
        }
    }
    return imported_count;
}

fn restoreNamedInput(db: *query.Database, reader: *codec.Reader, check: bool) !?query.PersistedInputRef {
    const name = try reader.read([]const u8);
    defer reader.allocator.free(name);
    inline for (.{ queries.SourceText, queries.FileModule, queries.ModuleMembers, queries.ModuleCatalog, queries.StandardPreludeModule, queries.StandardFile }) |I| {
        if (std.mem.eql(u8, name, @typeName(I))) return restoreInput(I, db, reader, check);
    }
    return error.InvalidCache;
}

fn restoreNamedQueryDependency(db: *query.Database, reader: *codec.Reader, check: bool) !?query.PersistedQueryRef {
    const name = try reader.read([]const u8);
    defer reader.allocator.free(name);
    inline for (.{ queries.BuildModuleScope, queries.ModuleDeclarations, queries.IndexModuleItems, queries.ResolveItem, queries.FunctionSignature, queries.FunctionInstanceSignature, queries.AnalyzeFunctionInstance }) |Q| {
        if (std.mem.eql(u8, name, @typeName(Q))) return restoreQueryDependency(Q, db, reader, check);
    }
    return error.InvalidCache;
}

fn restoreQueryDependency(comptime Q: type, db: *query.Database, reader: *codec.Reader, check: bool) !?query.PersistedQueryRef {
    const input = try reader.read(Q.Input);
    var digest: [32]u8 = undefined;
    @memcpy(&digest, try reader.take(digest.len));
    if (!check or !(try validateIds(Q.Input, db, input))) return null;
    return db.matchPersistedQuery(Q, input, digest);
}

fn restoreInput(comptime I: type, db: *query.Database, reader: *codec.Reader, check: bool) !?query.PersistedInputRef {
    const key = try reader.read(I.Key);
    var digest: [32]u8 = undefined;
    @memcpy(&digest, try reader.take(digest.len));
    if (!check or !(try validateIds(I.Key, db, key))) return null;
    return db.matchPersistedInput(I, key, digest);
}

fn readCount(reader: *codec.Reader) !usize {
    const count = try reader.read(u64);
    if (count > max_records or count > reader.bytes.len - reader.offset) return error.InvalidCache;
    return @intCast(count);
}

fn validateIds(comptime T: type, db: *query.Database, value: T) anyerror!bool {
    if (T == u8) return true;
    if (T == structures.ModuleId) return (try db.lookupInternedAs(queries.ModulePaths, value)) != null;
    if (T == structures.ItemId) return (try db.lookupInternedAs(queries.ItemLocations, value)) != null;
    if (T == structures.CompileTimeValueId) return (try db.lookupInternedAs(queries.CompileTimeValues, value)) != null;
    if (T == structures.CompileTimeValueTupleId) return (try db.lookupInternedAs(queries.CompileTimeValueTuples, value)) != null;
    if (T == structures.InternedTypeId) return (try db.lookupInternedAs(queries.Types, value)) != null;
    if (T == structures.TypeId) {
        if (value.isPrimitive()) return true;
        const interned = value.interned() orelse return false;
        return (try db.lookupInternedAs(queries.Types, interned)) != null;
    }
    return switch (@typeInfo(T)) {
        .optional => |info| if (value) |present| try validateIds(info.child, db, present) else true,
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (!field.is_comptime and !(try validateIds(field.type, db, @field(value, field.name)))) break :blk false;
            }
            break :blk true;
        },
        .@"union" => switch (value) {
            inline else => |payload| try validateIds(@TypeOf(payload), db, payload),
        },
        .array => |info| blk: {
            for (value) |element| {
                if (!(try validateIds(info.child, db, element))) break :blk false;
            }
            break :blk true;
        },
        .pointer => |info| blk: {
            if (info.size != .slice) @compileError("unexpected pointer in persisted value");
            for (value) |element| {
                if (!(try validateIds(info.child, db, element))) break :blk false;
            }
            break :blk true;
        },
        else => true,
    };
}

fn validOutput(comptime Q: type, db: *query.Database, output: Q.Output) !bool {
    if (Q == queries.CompileFunction) return validCompiledFunction(output.?);
    if (output.?.is_initializer_region) return false;
    if (!validFunctionBody(output.?)) return false;
    return validStorageOperations(db, output.?) catch |err| switch (err) {
        error.Unavailable => false,
        else => return err,
    };
}

fn validStorageOperations(db: *query.Database, body: structures.FunctionBodyAnalysis) anyerror!bool {
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    for (body.instructions) |instruction| {
        switch (instruction) {
            .borrow_address => |operation| if (!try validBorrowFields(types, body, operation)) return false,
            .storage_projection => |operation| if (!try validStorageProjection(types, body, operation)) return false,
            .allocation_element => |operation| {
                if (body.valueType(operation.index) != .int) return false;
                const element = (try types.allocationElement(body.valueType(operation.allocation))) orelse return false;
                if (element != operation.type_id) return false;
            },
            else => {},
        }
    }
    for (body.initializer_regions) |region| if (!try validStorageOperations(db, region)) return false;
    return true;
}

fn validBorrowFields(types: anytype, body: structures.FunctionBodyAnalysis, operation: structures.BorrowAddressOperation) !bool {
    var type_id = body.valueType(operation.source);
    if (operation.base_is_reference) type_id = (try types.borrowElement(type_id)) orelse return false;
    for (body.borrow_fields[operation.fields.start..operation.fields.end]) |field_index| {
        const definition = (try types.structDefinition(type_id)) orelse return false;
        if (field_index >= definition.fields.len) return false;
        type_id = definition.fields[field_index].type_id;
    }
    return type_id == ((try types.borrowElement(operation.type_id)) orelse return false);
}

fn validStorageProjection(types: anytype, body: structures.FunctionBodyAnalysis, operation: structures.StorageProjection) !bool {
    const type_id = body.valueType(operation.owner);
    switch (operation.projection) {
        .box_element => return operation.type_id == ((try types.boxElement(type_id)) orelse return false),
        .field => |field| {
            const definition = (try types.structDefinition(type_id)) orelse return false;
            return field < definition.fields.len and definition.fields[field].type_id == operation.type_id;
        },
        .variant => {
            const members = (try types.variantMembers(type_id)) orelse return false;
            return std.mem.indexOfScalar(structures.TypeId, members, operation.type_id) != null;
        },
    }
}

fn validRange(range: structures.FunctionValueRange, length: usize) bool {
    return range.start <= range.end and range.end <= length;
}

fn validValue(value: structures.FunctionValueId, body: structures.FunctionBodyAnalysis) bool {
    return @intFromEnum(value) < body.valueCount();
}

fn validUse(use: structures.FunctionValueUse, body: structures.FunctionBodyAnalysis) bool {
    return validOrdinaryValue(use.value, body) and
        (use.variant_tag_mapping == null or validRange(use.variant_tag_mapping.?, body.variant_coercion_tags.len));
}

fn validOrdinaryValue(value: structures.FunctionValueId, body: structures.FunctionBodyAnalysis) bool {
    if (!validValue(value, body)) return false;
    return valueRepresentation(body, value) != .initializer;
}

fn validCallArgument(argument: structures.FunctionCallArgument, body: structures.FunctionBodyAnalysis) bool {
    return switch (argument) {
        .prepared => |use| validUse(use, body),
        .deinit => |value| validOrdinaryValue(value, body),
        .initializer => |value| validValue(value, body) and valueRepresentation(body, value) == .initializer,
    };
}

fn validCall(call: structures.FunctionCall, body: structures.FunctionBodyAnalysis) bool {
    if (!validRange(call.arguments, body.call_arguments.len)) return false;
    if (call.destination) |destination| if (!validOrdinaryValue(destination, body) or body.valueType(destination) != call.return_type) return false;
    if (call.target == .indirect and !validOrdinaryValue(call.target.indirect, body)) return false;
    if (call.target == .initializer) {
        const value = call.target.initializer;
        if (!validValue(value, body)) return false;
        return call.arguments.start == call.arguments.end and valueRepresentation(body, value) == .initializer and body.valueType(value) == call.return_type;
    }
    return true;
}

fn valueRepresentation(body: structures.FunctionBodyAnalysis, value: structures.FunctionValueId) structures.ValueRepresentation {
    const index = @intFromEnum(value);
    if (index < body.block_arguments.len) return body.block_arguments[index].representation;
    return switch (body.instructions[index - body.block_arguments.len]) {
        .initializer_ref => .initializer,
        else => .value,
    };
}

fn validBranch(branch: structures.FunctionBranch, body: structures.FunctionBodyAnalysis) bool {
    if (@intFromEnum(branch.target) >= body.blocks.len or !validRange(branch.arguments, body.branch_arguments.len)) return false;
    const target = body.blocks[@intFromEnum(branch.target)];
    if (target.argument_start > target.argument_end or target.argument_end > body.block_arguments.len) return false;
    if (branch.arguments.end - branch.arguments.start != target.argument_end - target.argument_start) return false;
    for (body.branch_arguments[branch.arguments.start..branch.arguments.end], body.block_arguments[target.argument_start..target.argument_end]) |use, argument| {
        if (argument.representation == .initializer) return false;
        if ((use.coerce_to orelse body.valueType(use.value)) != argument.type_id) return false;
        if (argument.representation == .storage and (use.coerce_to != null or use.variant_tag_mapping != null)) return false;
    }
    return true;
}

fn validVariantOperation(operation: structures.VariantOperation, body: structures.FunctionBodyAnalysis) bool {
    return operation.tag_mapping == null or validRange(operation.tag_mapping.?, body.variant_coercion_tags.len);
}

fn validCallMutArgument(operation: structures.CallMutArgument, body: structures.FunctionBodyAnalysis) bool {
    if (!validRange(operation.arguments, body.call_arguments.len) or
        operation.argument_index >= operation.arguments.end - operation.arguments.start) return false;
    const argument = body.call_arguments[operation.arguments.start + operation.argument_index];
    if (argument != .prepared) return false;
    const prepared_type = argument.prepared.coerce_to orelse body.valueType(argument.prepared.value);
    if (operation.type_id != prepared_type) return false;
    if (operation.destination) |destination| {
        if (!validOrdinaryValue(destination, body) or body.valueType(destination) != operation.type_id) return false;
    }
    var found = false;
    for (body.instructions) |instruction| {
        if (instruction != .call) continue;
        const call = instruction.call;
        if (!std.meta.eql(call.arguments, operation.arguments)) continue;
        if (call.return_type != operation.return_type) return false;
        found = true;
    }
    for (body.blocks) |block| {
        if (block.terminator != .fallible_call) continue;
        const call = block.terminator.fallible_call.call;
        if (!std.meta.eql(call.arguments, operation.arguments)) continue;
        if (call.return_type != operation.return_type) return false;
        found = true;
    }
    return found;
}

fn validFunctionBody(body: structures.FunctionBodyAnalysis) bool {
    if (body.blocks.len == 0 or @intFromEnum(body.entry) >= body.blocks.len) return false;
    if (body.is_initializer_region and !body.is_fallible) return false;
    if (body.valueCount() > std.math.maxInt(u32)) return false;
    if (body.instruction_spans.len != 0 and body.instruction_spans.len != body.instructions.len) return false;
    if (body.terminator_spans.len != 0 and body.terminator_spans.len != body.blocks.len) return false;
    for (body.struct_field_values) |field| if (!validOrdinaryValue(field.value, body)) return false;
    for (body.branch_arguments) |use| if (!validUse(use, body)) return false;
    for (body.call_arguments) |argument| if (!validCallArgument(argument, body)) return false;
    for (body.initializer_captures) |capture| if (!validValue(capture, body)) return false;
    for (body.initializer_regions) |region| {
        if (!region.is_initializer_region or !validFunctionBody(region)) return false;
    }
    const entry = body.blocks[@intFromEnum(body.entry)];
    if (entry.argument_start != 0 or entry.argument_end > body.block_arguments.len) return false;
    if (body.parameter_modes.len != entry.argument_end - entry.argument_start) return false;
    for (body.parameter_modes, body.block_arguments[entry.argument_start..entry.argument_end]) |mode, argument| {
        if ((mode == .init) != (argument.representation == .initializer)) return false;
        if (body.is_initializer_region and ((mode != .imm and mode != .mut and mode != .init) or
            (argument.representation != .storage and argument.representation != .initializer))) return false;
    }
    for (body.block_arguments[entry.argument_end..]) |argument| if (argument.representation == .initializer) return false;
    for (body.instructions) |original| {
        var instruction = original;
        for (instruction.operands()) |operand| if (operand) |value| {
            if (!validValue(value.*, body)) return false;
            if (valueRepresentation(body, value.*) == .initializer and instruction != .call) return false;
        };
        const valid = switch (instruction) {
            .initializer_ref => |reference| validInitializerReference(reference, body),
            .variant_coerce, .variant_extract, .callable_coerce => |operation| validVariantOperation(operation, body),
            .struct_init => |operation| validRange(operation.fields, body.struct_field_values.len),
            .result_storage => |type_id| type_id == body.return_type,
            .borrow_address => |operation| validRange(operation.fields, body.borrow_fields.len),
            .mut_parameter_write => |operation| operation.parameter_index < body.parameter_modes.len and
                body.parameter_modes[operation.parameter_index] == .mut,
            .call_mut_argument => |operation| validCallMutArgument(operation, body),
            .call => |call| validCall(call, body) and call.target != .initializer,
            else => true,
        };
        if (!valid) return false;
    }
    for (body.blocks) |block| {
        if (block.argument_start > block.argument_end or block.argument_end > body.block_arguments.len or
            block.instruction_start > block.instruction_end or block.instruction_end > body.instructions.len) return false;
        var terminator = block.terminator;
        for (terminator.operands()) |operand| if (operand) |value| {
            if (!validValue(value.*, body)) return false;
            if (valueRepresentation(body, value.*) == .initializer and terminator != .fallible_call) return false;
        };
        for (terminator.successors()) |successor| if (successor) |target| {
            if (@intFromEnum(target.*) >= body.blocks.len) return false;
        };
        const valid = switch (block.terminator) {
            .branch => |branch| validBranch(branch, body),
            .predicate_branch => |branch| validBranch(branch.then_branch, body) and validBranch(branch.else_branch, body),
            .fallible_call => |branch| validCall(branch.call, body) and
                validFallibleTargets(branch.call, branch.success, branch.failure, body),
            .return_value => |use| validUse(use, body),
            .return_failure => body.is_fallible,
            .return_unit, .diverge => true,
        };
        if (!valid) return false;
    }
    return true;
}

fn validInitializerReference(reference: @FieldType(structures.FunctionInstruction, "initializer_ref"), body: structures.FunctionBodyAnalysis) bool {
    if (reference.region >= body.initializer_regions.len or !validRange(reference.captures, body.initializer_captures.len)) return false;
    const region = body.initializer_regions[reference.region];
    if (reference.type_id != region.return_type or reference.captures.end - reference.captures.start != region.parameter_modes.len) return false;
    const entry = region.blocks[@intFromEnum(region.entry)];
    for (body.initializer_captures[reference.captures.start..reference.captures.end], region.block_arguments[entry.argument_start..entry.argument_end]) |capture, argument| {
        if (body.valueType(capture) != argument.type_id) return false;
        if ((argument.representation == .initializer) != (valueRepresentation(body, capture) == .initializer)) return false;
    }
    return true;
}

fn validFallibleTargets(call: structures.FunctionCall, success: structures.FunctionBlockId, failure: ?structures.FunctionBlockId, body: structures.FunctionBodyAnalysis) bool {
    if (@intFromEnum(success) >= body.blocks.len) return false;
    const success_block = body.blocks[@intFromEnum(success)];
    if (success_block.argument_start > success_block.argument_end or success_block.argument_end > body.block_arguments.len or
        success_block.argument_end - success_block.argument_start != 1) return false;
    const result = body.block_arguments[success_block.argument_start];
    if (result.representation != .value or result.type_id != (if (call.destination == null) call.return_type else .unit)) return false;
    if (failure) |target| {
        if (@intFromEnum(target) >= body.blocks.len) return false;
        const block = body.blocks[@intFromEnum(target)];
        if (block.argument_end > body.block_arguments.len or block.argument_end != block.argument_start) return false;
    }
    return true;
}

fn validCompiledFunction(artifact: structures.CompiledFunction) bool {
    if (artifact.code.len == 0 or artifact.required_alignment == 0 or !std.math.isPowerOfTwo(artifact.required_alignment)) return false;
    for (artifact.relocations) |relocation| {
        if (@intFromEnum(relocation.reference) >= artifact.referenced_instances.len) return false;
        const width: usize = switch (relocation.kind) {
            .call_relative_32 => 4,
            .address_absolute_64 => 8,
        };
        if (relocation.offset > artifact.code.len or width > artifact.code.len - relocation.offset) return false;
    }
    return true;
}

test "query restore rejects the obsolete lexical IR format" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try std.testing.expectError(error.InvalidCache, restoreInterns(db, allocator, "CHIQRY12"));
}

test "restoring a malformed canonical type rejects the snapshot" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();

    for ([_][]const structures.TypeId{
        &.{.int},
        &.{ .bool, .int },
    }) |members| {
        var writer: codec.Writer = .{ .allocator = allocator };
        defer writer.deinit();
        try writer.bytes.appendSlice(allocator, format);
        try writer.write(u64, 1);
        try writer.write([]const u8, @typeName(queries.Types));
        try writer.write(queries.Types.Value, .{ .variant = .{ .members = members } });
        try std.testing.expectError(error.InvalidCache, restoreInterns(db, allocator, writer.bytes.items));
    }
}

test "query restore rejects an offset past the payload" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try std.testing.expectError(error.InvalidCache, restoreQueries(db, "short", 6));
}

test "cached body validation rejects invalid control flow and argument indexes" {
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .int }};
    var parameter_modes = [_]structures.ParameterMode{.imm};
    var branch_arguments = [_]structures.FunctionValueUse{.{ .value = @enumFromInt(0) }};
    var call_arguments: [0]structures.FunctionCallArgument = .{};
    var instructions = [_]structures.FunctionInstruction{.{ .mut_parameter_write = .{
        .parameter_index = 1,
        .value = @enumFromInt(0),
        .type_id = .int,
    } }};
    var blocks = [_]structures.FunctionBlock{.{
        .argument_start = 0,
        .argument_end = 1,
        .instruction_start = 0,
        .instruction_end = 0,
        .terminator = .return_unit,
    }};
    var body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .parameter_modes = &parameter_modes,
        .block_arguments = &block_arguments,
        .branch_arguments = branch_arguments[0..0],
        .call_arguments = &call_arguments,
        .instructions = instructions[0..0],
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(validFunctionBody(body));

    blocks[0].terminator = .{ .branch = .{ .target = @enumFromInt(0), .arguments = .{ .start = 0, .end = 0 } } };
    try std.testing.expect(!validFunctionBody(body));

    body.branch_arguments = &branch_arguments;
    blocks[0].terminator.branch.arguments.end = 1;
    block_arguments[0].representation = .storage;
    try std.testing.expect(validFunctionBody(body));
    branch_arguments[0].coerce_to = .none;
    try std.testing.expect(!validFunctionBody(body));
    branch_arguments[0].coerce_to = null;
    block_arguments[0].representation = .value;

    blocks[0].terminator = .return_unit;
    blocks[0].instruction_end = 1;
    body.instructions = &instructions;
    try std.testing.expect(!validFunctionBody(body));

    instructions[0] = .{ .call_mut_argument = .{
        .arguments = .{ .start = 0, .end = 0 },
        .return_type = .unit,
        .argument_index = 0,
        .type_id = .int,
    } };
    try std.testing.expect(!validFunctionBody(body));

    blocks[0].instruction_end = 0;
    body.instructions = instructions[0..0];
    blocks[0].terminator = .return_failure;
    try std.testing.expect(!validFunctionBody(body));
    body.is_fallible = true;
    try std.testing.expect(validFunctionBody(body));

    instructions[0] = .{ .storage_projection = .{
        .owner = @enumFromInt(0),
        .projection = .{ .field = 7 },
        .type_id = .int,
    } };
    body.instructions = &instructions;
    blocks[0].instruction_end = 1;
    blocks[0].terminator = .return_unit;
    try std.testing.expect(validFunctionBody(body));
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try std.testing.expect(!(try validStorageOperations(db, body)));

    const modules = @import("modules.zig");
    try modules.registerSources(db, std.testing.allocator,
        \\import std.memory.{Allocation}
        \\struct Pair
        \\  value: int
        \\static IntRef = Ref(int, false)
        \\static IntBox = Box(int)
        \\static IntSlots = Allocation(int)
        \\exit(42)
    , &.{}, &.{});
    const module = try db.intern(queries.ModulePaths, .{ .path = "" });
    const pair = (try db.get(queries.ModuleDeclarations, module)).*.?.resolveStatic("Pair").?;
    const pair_type = structures.TypeId.fromInterned(try db.intern(queries.Types, .{ .structure = .{ .declared = pair } }));
    block_arguments[0].type_id = pair_type;
    instructions[0].storage_projection.projection = .{ .field = 0 };
    try std.testing.expect(try validStorageOperations(db, body));
    instructions[0].storage_projection.projection = .{ .field = 7 };
    try std.testing.expect(!(try validStorageOperations(db, body)));

    const variant_type = structures.TypeId.fromInterned(try db.intern(queries.Types, .{ .variant = .{ .members = &.{ .int, .byte } } }));
    block_arguments[0].type_id = variant_type;
    instructions[0].storage_projection.projection = .variant;
    try std.testing.expect(try validStorageOperations(db, body));
    instructions[0].storage_projection.type_id = .bool;
    try std.testing.expect(!(try validStorageOperations(db, body)));

    const box_item = (try db.get(queries.ModuleDeclarations, module)).*.?.resolveStatic("IntBox").?;
    const box_value = (try db.get(queries.ResolveStatic, box_item)).*.?;
    block_arguments[0].type_id = (try db.lookupInterned(queries.CompileTimeValues, box_value)).type;
    instructions[0].storage_projection.projection = .box_element;
    instructions[0].storage_projection.type_id = .int;
    try std.testing.expect(try validStorageOperations(db, body));
    instructions[0].storage_projection.type_id = .bool;
    try std.testing.expect(!(try validStorageOperations(db, body)));
    instructions[0].storage_projection.type_id = .int;
    block_arguments[0].type_id = pair_type;
    try std.testing.expect(!(try validStorageOperations(db, body)));

    const allocation_item = (try db.get(queries.ModuleDeclarations, module)).*.?.resolveStatic("IntSlots").?;
    const allocation_value = (try db.get(queries.ResolveStatic, allocation_item)).*.?;
    block_arguments[0].type_id = (try db.lookupInterned(queries.CompileTimeValues, allocation_value)).type;
    var slot_instructions = [_]structures.FunctionInstruction{
        .{ .const_int = 0 },
        .{ .allocation_element = .{ .allocation = @enumFromInt(0), .index = body.instructionValue(0), .type_id = .int } },
    };
    body.instructions = &slot_instructions;
    blocks[0].instruction_end = slot_instructions.len;
    try std.testing.expect(validFunctionBody(body));
    try std.testing.expect(try validStorageOperations(db, body));
    slot_instructions[1].allocation_element.type_id = .bool;
    try std.testing.expect(!(try validStorageOperations(db, body)));
    slot_instructions[1].allocation_element.type_id = .int;
    slot_instructions[0] = .{ .const_bool = false };
    try std.testing.expect(!(try validStorageOperations(db, body)));
    slot_instructions[0] = .{ .const_int = 0 };
    block_arguments[0].type_id = pair_type;
    try std.testing.expect(!(try validStorageOperations(db, body)));
    body.instructions = &instructions;
    blocks[0].instruction_end = instructions.len;

    instructions[0] = .{ .value_copy = .{ .source = @enumFromInt(0), .type_id = variant_type, .destination = @enumFromInt(999) } };
    try std.testing.expect(!validFunctionBody(body));

    instructions[0] = .{ .result_storage = .unit };
    try std.testing.expect(validFunctionBody(body));
    instructions[0] = .{ .result_storage = pair_type };
    try std.testing.expect(!validFunctionBody(body));

    const reference_item = (try db.get(queries.ModuleDeclarations, module)).*.?.resolveStatic("IntRef").?;
    const reference_value = (try db.get(queries.ResolveStatic, reference_item)).*.?;
    const reference_type = (try db.lookupInterned(queries.CompileTimeValues, reference_value)).type;
    var path = [_]u32{0};
    body.borrow_fields = &path;
    block_arguments[0].type_id = pair_type;
    instructions[0] = .{ .borrow_address = .{
        .source = @enumFromInt(0),
        .type_id = reference_type,
        .fields = .{ .start = 0, .end = 1 },
    } };
    try std.testing.expect(validFunctionBody(body));
    try std.testing.expect(try validStorageOperations(db, body));
    path[0] = 1;
    try std.testing.expect(!(try validStorageOperations(db, body)));
    path[0] = 0;
    instructions[0].borrow_address.fields.end = 2;
    try std.testing.expect(!validFunctionBody(body));
    instructions[0].borrow_address.fields.end = 1;
    instructions[0].borrow_address.type_id = .int;
    try std.testing.expect(!(try validStorageOperations(db, body)));
}

test "typed bodies and code survive an edit to another file" {
    const modules = @import("modules.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const source_files = [_]modules.SourceFile{
        .{ .path = "a.chi", .module_path = "", .source = "static a = func() int -> return 2" },
        .{ .path = "b.chi", .module_path = "", .source = "static b = func() int -> return 3" },
    };
    const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &source_files);

    const first = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer first.deinit();
    try modules.registerSources(first, allocator, "exit(a() + b())", &source_files, &.{""});
    const original = (try first.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try save(io, allocator, directory, digest, first);
    const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);

    const second = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer second.deinit();
    const offset = try restoreInterns(second, allocator, payload);
    var second_registry: modules.SourceRegistry = .{};
    defer second_registry.deinit(allocator);
    try second_registry.update(second, allocator, "exit(a() + b() + 1)", &source_files, &.{""});
    const imported = try restoreQueries(second, payload, offset);
    try std.testing.expect(imported >= 4);
    const edited = (try second.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, original.bytes, edited.bytes));
    const edited_bytes = try allocator.dupe(u8, edited.bytes);
    defer allocator.free(edited_bytes);

    const refreshed_files = [_]modules.SourceFile{
        source_files[0],
        .{ .path = "b.chi", .module_path = "", .source = "static b = func() int -> return 5" },
    };
    try second_registry.update(second, allocator, "exit(a() + b() + 1)", &refreshed_files, &.{""});
    const refreshed = (try second.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, edited_bytes, refreshed.bytes));

    const changed_files = [_]modules.SourceFile{
        source_files[0],
        .{ .path = "b.chi", .module_path = "", .source = "static b = func() int -> return 4" },
    };
    const third = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer third.deinit();
    const third_offset = try restoreInterns(third, allocator, payload);
    try modules.registerSources(third, allocator, "exit(a() + b())", &changed_files, &.{""});
    const reused = try restoreQueries(third, payload, third_offset);
    try std.testing.expect(reused > 0);
    try std.testing.expect(reused < imported);
    const changed = (try third.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, original.bytes, changed.bytes));

    const fourth = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer fourth.deinit();
    const fourth_offset = try restoreInterns(fourth, allocator, payload[0 .. payload.len - 1]);
    try modules.registerSources(fourth, allocator, "exit(a() + b())", &source_files, &.{""});
    try std.testing.expectError(error.InvalidCache, restoreQueries(fourth, payload[0 .. payload.len - 1], fourth_offset));
}

test "Box and Ref alias bodies restore and invalidate after a binding edit" {
    const modules = @import("modules.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const initial_source =
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  borrow item = owner.borrow()[]
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    ;
    const edited_source =
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  borrow mut item = owner.borrow_mut()[]
        \\  item = 42
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &.{});

    const first = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer first.deinit();
    try modules.registerSources(first, allocator, initial_source, &.{}, &.{});
    const original = (try first.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    const run = (try first.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const original_body = (try first.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    try save(io, allocator, directory, digest, first);
    const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);

    const second = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer second.deinit();
    const offset = try restoreInterns(second, allocator, payload);
    try modules.registerSources(second, allocator, initial_source, &.{}, &.{});
    const imported = try restoreQueries(second, payload, offset);
    try std.testing.expect(imported > 0);
    const restored_run = (try second.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const restored_body = (try second.get(queries.AnalyzeFunctionInstance, .{ .item = restored_run })).*.?;
    try std.testing.expect(structures.FunctionBodyAnalysis.eql(original_body, restored_body));
    const restored = (try second.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, original.bytes, restored.bytes);

    const third = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer third.deinit();
    const third_offset = try restoreInterns(third, allocator, payload);
    try modules.registerSources(third, allocator, edited_source, &.{}, &.{});
    const reused = try restoreQueries(third, payload, third_offset);
    try std.testing.expect(reused < imported);
    const edited_run = (try third.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const edited_body = (try third.get(queries.AnalyzeFunctionInstance, .{ .item = edited_run })).*.?;
    var wrote_referent = false;
    for (edited_body.instructions) |instruction| if (instruction == .borrow_write) {
        wrote_referent = true;
    };
    try std.testing.expect(wrote_referent);
    const edited = (try third.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, original.bytes, edited.bytes));
}

test "in-place bodies restore and invalidate movability edits" {
    const modules = @import("modules.zig");
    const runtime = @import("runtime.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source =
        \\struct Item
        \\  move = none
        \\  value: int
        \\struct Pair
        \\  first: Item
        \\  second: Item | none
        \\func make(value: int) Item -> Item{value = value}
        \\func bump(mut item: Item)
        \\  item.value += 1
        \\func build() Pair -> Pair{first = make(20), second = if 1 < 2 -> make(22) else none}
        \\func update() int
        \\  var pair = build()
        \\  var index = 0
        \\  loop
        \\    index += 1
        \\    bump(pair.first)
        \\    if index == 2 -> break
        \\  const current = pair.first.value
        \\  pair.first = make(current)
        \\  return pair.first.value
        \\exit(update() + 20)
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &.{});

    const first = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer first.deinit();
    try modules.registerSources(first, allocator, source, &.{}, &.{});
    const original = (try first.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    const first_scope = (try first.get(queries.BuildModuleScope, 0)).*.?;
    const original_build = (try first.get(queries.AnalyzeFunctionInstance, .{ .item = first_scope.resolveFunction("build").? })).*.?;
    const original_update = (try first.get(queries.AnalyzeFunctionInstance, .{ .item = first_scope.resolveFunction("update").? })).*.?;
    try save(io, allocator, directory, digest, first);
    const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    const second = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer second.deinit();
    const offset = try restoreInterns(second, allocator, payload);
    try modules.registerSources(second, allocator, source, &.{}, &.{});
    const imported = try restoreQueries(second, payload, offset);
    try std.testing.expect(imported > 0);
    const second_scope = (try second.get(queries.BuildModuleScope, 0)).*.?;
    const restored_build = (try second.get(queries.AnalyzeFunctionInstance, .{ .item = second_scope.resolveFunction("build").? })).*.?;
    const restored_update = (try second.get(queries.AnalyzeFunctionInstance, .{ .item = second_scope.resolveFunction("update").? })).*.?;
    try std.testing.expect(structures.FunctionBodyAnalysis.eql(original_build, restored_build));
    try std.testing.expect(structures.FunctionBodyAnalysis.eql(original_update, restored_update));
    var constructed_in_place = false;
    for (restored_build.instructions) |instruction| if (instruction == .result_storage) {
        constructed_in_place = true;
    };
    try std.testing.expect(constructed_in_place);
    var updated_in_place = false;
    for (restored_update.instructions) |instruction| if (instruction == .call_mut_argument) {
        updated_in_place = instruction.call_mut_argument.destination != null;
    };
    try std.testing.expect(updated_in_place);
    const restored = (try second.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, original.bytes, restored.bytes);
    try runtime.writeProgram(io, restored.bytes);
    try std.testing.expectEqual(@as(u8, 42), try runtime.runProg(io, allocator, &.{}));

    const edited_source = try std.mem.replaceOwned(u8, allocator, source, "move = none", "move = fieldwise");
    defer allocator.free(edited_source);
    const third = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer third.deinit();
    const edited_offset = try restoreInterns(third, allocator, payload);
    try modules.registerSources(third, allocator, edited_source, &.{}, &.{});
    try std.testing.expect((try restoreQueries(third, payload, edited_offset)) < imported);
    const edited = (try third.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    const cold = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer cold.deinit();
    try modules.registerSources(cold, allocator, edited_source, &.{}, &.{});
    const rebuilt = (try cold.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, rebuilt.bytes, edited.bytes);
    try std.testing.expect(!std.mem.eql(u8, original.bytes, edited.bytes));
    try runtime.writeProgram(io, edited.bytes);
    try std.testing.expectEqual(@as(u8, 42), try runtime.runProg(io, allocator, &.{}));
}

test "deinit bodies restore and invalidate when parameter modes change" {
    const modules = @import("modules.zig");
    const runtime = @import("runtime.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source =
        \\func take(deinit value: int | none) int
        \\  if const number = value as int -> return number
        \\  return 1
        \\func pick(flag: int) int
        \\  const first: int | none = 20
        \\  const second: int | none = 22
        \\  const callback = take
        \\  return callback(if flag == 1 -> first else second)
        \\exit(pick(1) + pick(0))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &.{});

    const first = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer first.deinit();
    try modules.registerSources(first, allocator, source, &.{}, &.{});
    const original = (try first.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    const take = (try first.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("take").?;
    const original_body = (try first.get(queries.AnalyzeFunctionInstance, .{ .item = take })).*.?;
    const pick = (try first.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("pick").?;
    const original_pick = (try first.get(queries.AnalyzeFunctionInstance, .{ .item = pick })).*.?;
    try save(io, allocator, directory, digest, first);
    const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);

    const second = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer second.deinit();
    const offset = try restoreInterns(second, allocator, payload);
    try modules.registerSources(second, allocator, source, &.{}, &.{});
    const imported = try restoreQueries(second, payload, offset);
    try std.testing.expect(imported > 0);
    const restored_take = (try second.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("take").?;
    const restored_body = (try second.get(queries.AnalyzeFunctionInstance, .{ .item = restored_take })).*.?;
    try std.testing.expect(structures.FunctionBodyAnalysis.eql(original_body, restored_body));
    const restored_pick_item = (try second.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("pick").?;
    const restored_pick = (try second.get(queries.AnalyzeFunctionInstance, .{ .item = restored_pick_item })).*.?;
    try std.testing.expect(structures.FunctionBodyAnalysis.eql(original_pick, restored_pick));
    const restored = (try second.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, original.bytes, restored.bytes);
    try runtime.writeProgram(io, restored.bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try std.testing.expectEqual(@as(u8, 42), try runtime.runProg(io, allocator, &.{}));

    const edited_source = try std.mem.replaceOwned(u8, allocator, source, "deinit", "imm");
    defer allocator.free(edited_source);
    const third = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer third.deinit();
    const edited_offset = try restoreInterns(third, allocator, payload);
    try modules.registerSources(third, allocator, edited_source, &.{}, &.{});
    try std.testing.expect((try restoreQueries(third, payload, edited_offset)) < imported);
    const edited = (try third.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;

    const cold = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer cold.deinit();
    try modules.registerSources(cold, allocator, edited_source, &.{}, &.{});
    const rebuilt = (try cold.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, rebuilt.bytes, edited.bytes);
    try std.testing.expect(!std.mem.eql(u8, original.bytes, edited.bytes));
    try runtime.writeProgram(io, edited.bytes);
    try std.testing.expectEqual(@as(u8, 42), try runtime.runProg(io, allocator, &.{}));
}

test "ownership members restore specialized callables and invalidate capability edits" {
    const modules = @import("modules.zig");
    const runtime = @import("runtime.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source =
        \\struct Item
        \\  copy = trivial
        \\  value: int
        \\static duplicate = Item.copy
        \\static transfer = Item.move
        \\const source = Item{value = 42}
        \\const copied = duplicate(source)
        \\const moved = transfer(copied)
        \\exit(moved.value)
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);
    const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &.{});
    const first = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer first.deinit();
    try modules.registerSources(first, allocator, source, &.{}, &.{});
    try std.testing.expect((try first.get(queries.BuildExecutable, 0)).* != null);
    try save(io, allocator, directory, digest, first);
    const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    for ([_][]const u8{ "trivial", "func(imm self: Item) Item -> Item{value = self.value + 1}", "none" }, 0..) |operation, index| {
        const edited_source = try std.mem.replaceOwned(u8, allocator, source, "trivial", operation);
        defer allocator.free(edited_source);
        const restored = try query.Database.init(allocator, .{ .worker_count = 2 });
        defer restored.deinit();
        const offset = try restoreInterns(restored, allocator, payload);
        try modules.registerSources(restored, allocator, edited_source, &.{}, &.{});
        try std.testing.expect(try restoreQueries(restored, payload, offset) > 0);
        const cold = try query.Database.init(allocator, .{ .worker_count = 2 });
        defer cold.deinit();
        try modules.registerSources(cold, allocator, edited_source, &.{}, &.{});
        const warm_result = (try restored.get(queries.BuildExecutable, 0)).*;
        const cold_result = (try cold.get(queries.BuildExecutable, 0)).*;
        if (index == 2) {
            try std.testing.expect(warm_result == null);
            try std.testing.expect(cold_result == null);
            const warm_diagnostics = try restored.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, allocator);
            defer allocator.free(warm_diagnostics);
            const cold_diagnostics = try cold.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, allocator);
            defer allocator.free(cold_diagnostics);
            try std.testing.expectEqual(@as(usize, 1), warm_diagnostics.len);
            try std.testing.expectEqual(@as(usize, 1), cold_diagnostics.len);
            try std.testing.expectEqual(std.meta.Tag(structures.Diagnostic.Kind).unknown_namespace_member, std.meta.activeTag(warm_diagnostics[0].kind));
            try std.testing.expectEqual(std.meta.activeTag(cold_diagnostics[0].kind), std.meta.activeTag(warm_diagnostics[0].kind));
        } else {
            try std.testing.expect(warm_result != null);
            try std.testing.expect(cold_result != null);
            try std.testing.expectEqualSlices(u8, cold_result.?.bytes, warm_result.?.bytes);
            try runtime.writeProgram(io, warm_result.?.bytes);
            try std.testing.expectEqual(@as(u8, if (index == 0) 42 else 43), try runtime.runProg(io, allocator, &.{}));
        }
    }
}

test "invalid machine-code cache shapes are rejected" {
    const valid: structures.CompiledFunction = .{
        .code = &.{ 0, 0, 0, 0 },
        .required_alignment = 1,
        .relocations = &.{.{ .offset = 0, .kind = .call_relative_32, .reference = @enumFromInt(0), .addend = 0 }},
        .referenced_instances = &.{.{ .item = @enumFromInt(0) }},
    };
    try std.testing.expect(validCompiledFunction(valid));
    var damaged = valid;
    damaged.relocations = &.{.{ .offset = 1, .kind = .call_relative_32, .reference = @enumFromInt(0), .addend = 0 }};
    try std.testing.expect(!validCompiledFunction(damaged));
    damaged = valid;
    damaged.relocations = &.{.{ .offset = 0, .kind = .call_relative_32, .reference = @enumFromInt(1), .addend = 0 }};
    try std.testing.expect(!validCompiledFunction(damaged));
}

test {
    _ = @import("query_disk_cache_test.zig");
}

test "cached mutable result requires a matching producer" {
    var instructions = [_]structures.FunctionInstruction{
        .{ .const_int = 42 },
        .{ .call_mut_argument = .{
            .arguments = .{ .start = 0, .end = 1 },
            .argument_index = 0,
            .return_type = .unit,
            .type_id = .int,
        } },
    };
    var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @enumFromInt(0) } }};
    var blocks = [_]structures.FunctionBlock{.{
        .argument_start = 0,
        .argument_end = 0,
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .return_unit,
    }};
    const body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .parameter_modes = &.{},
        .block_arguments = &.{},
        .call_arguments = &call_arguments,
        .branch_arguments = &.{},
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(!validFunctionBody(body));
}

test "cached mutable result validates types and destinations across outcomes" {
    const call: structures.FunctionCall = .{
        .target = .{ .direct = .{ .item = @enumFromInt(0) } },
        .arguments = .{ .start = 0, .end = 1 },
        .return_type = .unit,
    };
    const result: structures.CallMutArgument = .{
        .arguments = call.arguments,
        .argument_index = 0,
        .return_type = .unit,
        .type_id = .int,
    };
    var instructions = [_]structures.FunctionInstruction{
        .{ .const_int = 42 },
        .{ .const_byte = 7 },
        .{ .call = call },
        .{ .call_mut_argument = result },
        .{ .call_mut_argument = result },
    };
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .unit }};
    var call_arguments = [_]structures.FunctionCallArgument{.{ .prepared = .{ .value = @enumFromInt(1) } }};
    var blocks = [_]structures.FunctionBlock{
        .{ .argument_start = 0, .argument_end = 0, .instruction_start = 0, .instruction_end = instructions.len, .terminator = .return_unit },
        .{ .argument_start = 0, .argument_end = 1, .instruction_start = 3, .instruction_end = 4, .terminator = .return_unit },
        .{ .argument_start = 1, .argument_end = 1, .instruction_start = 4, .instruction_end = 5, .terminator = .return_unit },
    };
    var body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .is_fallible = true,
        .parameter_modes = &.{},
        .block_arguments = &block_arguments,
        .call_arguments = &call_arguments,
        .branch_arguments = &.{},
        .instructions = &instructions,
        .blocks = blocks[0..1],
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(validFunctionBody(body));
    instructions[3].call_mut_argument.return_type = .int;
    try std.testing.expect(!validFunctionBody(body));
    instructions[3].call_mut_argument = result;
    instructions[2].call.arguments.end = 0;
    try std.testing.expect(!validFunctionBody(body));
    instructions[2].call = call;
    instructions[3].call_mut_argument.type_id = .byte;
    try std.testing.expect(!validFunctionBody(body));
    instructions[3].call_mut_argument = result;
    instructions[3].call_mut_argument.destination = @enumFromInt(2);
    try std.testing.expect(!validFunctionBody(body));
    instructions[3].call_mut_argument.destination = @enumFromInt(1);
    try std.testing.expect(validFunctionBody(body));
    instructions[3].call_mut_argument = result;

    call_arguments[0].prepared = .{ .value = @enumFromInt(2), .coerce_to = .int };
    try std.testing.expect(validFunctionBody(body));
    call_arguments[0].prepared.coerce_to = null;
    instructions[3].call_mut_argument.type_id = .byte;
    instructions[4].call_mut_argument.type_id = .byte;
    try std.testing.expect(validFunctionBody(body));
    instructions[4].call_mut_argument.type_id = .int;
    try std.testing.expect(!validFunctionBody(body));
    call_arguments[0].prepared = .{ .value = @enumFromInt(1) };
    instructions[3].call_mut_argument = result;
    instructions[4].call_mut_argument = result;

    instructions[2] = .const_unit;
    blocks[0].instruction_end = 3;
    blocks[0].terminator = .{ .fallible_call = .{ .call = call, .success = @enumFromInt(1), .failure = @enumFromInt(2) } };
    body.blocks = &blocks;
    try std.testing.expect(validFunctionBody(body));
    blocks[0].terminator.fallible_call.call.return_type = .int;
    try std.testing.expect(!validFunctionBody(body));
    blocks[0].terminator.fallible_call.call = call;
    try std.testing.expect(validFunctionBody(body));
}

test "cached initializer handles stay out of ordinary operands and mutable writes" {
    var parameter_modes = [_]structures.ParameterMode{.init};
    var block_arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .int, .representation = .initializer }};
    var instructions = [_]structures.FunctionInstruction{.{ .const_int = 42 }};
    var blocks = [_]structures.FunctionBlock{
        .{ .argument_start = 0, .argument_end = 1, .instruction_start = 0, .instruction_end = 1, .terminator = .diverge },
        .{ .argument_start = 1, .argument_end = 1, .instruction_start = 1, .instruction_end = 1, .terminator = .diverge },
    };
    var body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .is_fallible = true,
        .parameter_modes = &parameter_modes,
        .block_arguments = &block_arguments,
        .call_arguments = &.{},
        .branch_arguments = &.{},
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(validFunctionBody(body));
    body.is_fallible = false;
    try std.testing.expect(validFunctionBody(body));
    body.is_fallible = true;

    var fields = [_]structures.StructFieldValue{.{ .field_index = 0, .value = @enumFromInt(0) }};
    body.struct_field_values = &fields;
    try std.testing.expect(!validFunctionBody(body));
    fields[0].value = @enumFromInt(1);
    try std.testing.expect(validFunctionBody(body));
    body.struct_field_values = &.{};

    const branch: structures.FunctionBranch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 0 } };
    blocks[0].terminator = .{ .predicate_branch = .{
        .operation = .eqi,
        .operands = .{ .lhs = @enumFromInt(0), .rhs = @enumFromInt(1) },
        .then_branch = branch,
        .else_branch = branch,
    } };
    try std.testing.expect(!validFunctionBody(body));
    blocks[0].terminator.predicate_branch.operands.lhs = @enumFromInt(1);
    try std.testing.expect(validFunctionBody(body));
    blocks[0].terminator = .diverge;

    var arguments = [_]structures.FunctionCallArgument{.{ .initializer = @enumFromInt(0) }};
    body.call_arguments = &arguments;
    instructions[0] = .{ .call_mut_argument = .{
        .arguments = .{ .start = 0, .end = 1 },
        .return_type = .int,
        .argument_index = 0,
        .type_id = .int,
    } };
    try std.testing.expect(!validFunctionBody(body));

    var writes = [_]structures.FunctionInstruction{
        .{ .const_int = 42 },
        .{ .mut_parameter_write = .{ .parameter_index = 0, .value = @enumFromInt(1), .type_id = .int } },
    };
    body.instructions = &writes;
    blocks[0].instruction_end = 2;
    blocks[1].instruction_start = 2;
    blocks[1].instruction_end = 2;
    try std.testing.expect(!validFunctionBody(body));
    body.call_arguments = &.{};
    parameter_modes[0] = .mut;
    block_arguments[0].representation = .value;
    try std.testing.expect(validFunctionBody(body));
}

test "cached initializer failures reject invalid ordinary targets and result representations" {
    const allocator = std.testing.allocator;
    var modes = [_]structures.ParameterMode{.init};
    var arguments = [_]structures.FunctionBlockArgument{
        .{ .type_id = .int, .representation = .initializer },
        .{ .type_id = .int },
    };
    var blocks = [_]structures.FunctionBlock{
        .{ .argument_start = 0, .argument_end = 1, .instruction_start = 0, .instruction_end = 0, .terminator = .{ .fallible_call = .{
            .call = .{ .target = .{ .initializer = @enumFromInt(0) }, .arguments = .{ .start = 0, .end = 0 }, .return_type = .int },
            .success = @enumFromInt(1),
            .failure = @enumFromInt(2),
        } } },
        .{ .argument_start = 1, .argument_end = 2, .instruction_start = 0, .instruction_end = 0, .terminator = .{ .return_value = .{ .value = @enumFromInt(1) } } },
        .{ .argument_start = 2, .argument_end = 2, .instruction_start = 0, .instruction_end = 0, .terminator = .return_failure },
    };
    const original: structures.FunctionBodyAnalysis = .{
        .return_type = .int,
        .is_fallible = true,
        .parameter_modes = &modes,
        .block_arguments = &arguments,
        .branch_arguments = &.{},
        .call_arguments = &.{},
        .instructions = &.{},
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.write(structures.FunctionBodyAnalysis, original);
    var reader: codec.Reader = .{ .allocator = allocator, .bytes = writer.bytes.items };
    var body = try reader.read(structures.FunctionBodyAnalysis);
    defer body.deinit(allocator);
    try std.testing.expect(validFunctionBody(body));
    const call = &body.blocks[0].terminator.fallible_call;
    const success = call.success;
    const failure = call.failure;
    call.success = failure.?;
    try std.testing.expect(!validFunctionBody(body));
    call.success = success;
    const success_argument = &body.block_arguments[body.blocks[@intFromEnum(success)].argument_start];
    const success_type = success_argument.type_id;
    success_argument.type_id = .bool;
    try std.testing.expect(!validFunctionBody(body));
    success_argument.type_id = success_type;
    success_argument.representation = .storage;
    try std.testing.expect(!validFunctionBody(body));
    success_argument.representation = .value;
    call.failure = success;
    try std.testing.expect(!validFunctionBody(body));
    call.failure = @enumFromInt(body.blocks.len);
    try std.testing.expect(!validFunctionBody(body));
    call.failure = null;
    try std.testing.expect(validFunctionBody(body));
    call.failure = failure;
    body.is_fallible = false;
    try std.testing.expect(!validFunctionBody(body));
    body.is_fallible = true;
    try std.testing.expect(validFunctionBody(body));
}

test "cached nested handles reject changed capture representations" {
    const modules = @import("modules.zig");
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, allocator,
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(materialize(item))
        \\if const result = forward(42) -> exit(result) else exit(99)
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const original = (try db.get(queries.AnalyzeFunctionInstance, .{ .item = scope.resolveFunction("forward").? })).*.?;
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.write(structures.FunctionBodyAnalysis, original);
    var reader: codec.Reader = .{ .allocator = allocator, .bytes = writer.bytes.items };
    var body = try reader.read(structures.FunctionBodyAnalysis);
    defer body.deinit(allocator);
    try std.testing.expect(validFunctionBody(body));
    const region = &body.initializer_regions[0];
    try std.testing.expectEqual(structures.ValueRepresentation.initializer, region.block_arguments[0].representation);
    region.block_arguments[0].representation = .storage;
    region.parameter_modes[0] = .imm;
    try std.testing.expect(!validFunctionBody(body));
    region.block_arguments[0].representation = .initializer;
    region.parameter_modes[0] = .init;
    try std.testing.expect(validFunctionBody(body));
}

test "cached query outputs cannot adopt a private initializer calling convention" {
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    var modes = [_]structures.ParameterMode{.imm};
    var arguments = [_]structures.FunctionBlockArgument{.{ .type_id = .int, .representation = .storage }};
    var blocks = [_]structures.FunctionBlock{.{ .argument_start = 0, .argument_end = 1, .instruction_start = 0, .instruction_end = 0, .terminator = .diverge }};
    var body: structures.FunctionBodyAnalysis = .{
        .is_initializer_region = true,
        .is_fallible = true,
        .return_type = .unit,
        .parameter_modes = &modes,
        .block_arguments = &arguments,
        .call_arguments = &.{},
        .branch_arguments = &.{},
        .instructions = &.{},
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(validFunctionBody(body));
    try std.testing.expect(!(try validOutput(queries.AnalyzeFunctionInstance, db, body)));
    body.is_fallible = false;
    try std.testing.expect(!validFunctionBody(body));
}

test "cached initializers reject changed regions captures and value representation" {
    const modules = @import("modules.zig");
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, allocator,
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm value: int) int -> return materialize(value + 2)
        \\if const result = run(40) -> exit(result) else exit(99)
    , &.{}, &.{});
    const executable = (try db.get(queries.BuildExecutable, 0)).*;
    try std.testing.expect(executable != null);
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    const original = (try db.get(queries.AnalyzeFunctionInstance, .{ .item = scope.resolveFunction("run").? })).*.?;
    try writer.write(structures.FunctionBodyAnalysis, original);
    var reader: codec.Reader = .{ .allocator = allocator, .bytes = writer.bytes.items };
    var body = try reader.read(structures.FunctionBodyAnalysis);
    defer body.deinit(allocator);
    try std.testing.expect(validFunctionBody(body));
    const reference = &body.instructions[0].initializer_ref;
    const old_region = reference.region;
    reference.region = @intCast(body.initializer_regions.len);
    try std.testing.expect(!validFunctionBody(body));
    reference.region = old_region;
    reference.captures.end += 1;
    try std.testing.expect(!validFunctionBody(body));
    reference.captures.end -= 1;
    body.initializer_regions[0].return_type = .bool;
    try std.testing.expect(!validFunctionBody(body));
    body.initializer_regions[0].return_type = .int;
    body.initializer_regions[0].block_arguments[0].type_id = .bool;
    try std.testing.expect(!validFunctionBody(body));
    body.initializer_regions[0].block_arguments[0].type_id = .int;
    try std.testing.expect(validFunctionBody(body));
    body.call_arguments[0] = .{ .prepared = .{ .value = original.call_arguments[0].valueId() } };
    try std.testing.expect(!validFunctionBody(body));
}

test "cached storage joins reject mismatched types and coercion metadata" {
    var modes = [_]structures.ParameterMode{.imm};
    var arguments = [_]structures.FunctionBlockArgument{
        .{ .type_id = .int },
        .{ .type_id = .int, .representation = .storage },
    };
    var uses = [_]structures.FunctionValueUse{.{ .value = @enumFromInt(0) }};
    var tags = [_]u32{0};
    var blocks = [_]structures.FunctionBlock{
        .{ .argument_start = 0, .argument_end = 1, .instruction_start = 0, .instruction_end = 0, .terminator = .{ .branch = .{ .target = @enumFromInt(1), .arguments = .{ .start = 0, .end = 1 } } } },
        .{ .argument_start = 1, .argument_end = 2, .instruction_start = 0, .instruction_end = 0, .terminator = .return_unit },
    };
    const body: structures.FunctionBodyAnalysis = .{
        .return_type = .unit,
        .parameter_modes = &modes,
        .block_arguments = &arguments,
        .variant_coercion_tags = &tags,
        .branch_arguments = &uses,
        .call_arguments = &.{},
        .instructions = &.{},
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(validFunctionBody(body));
    arguments[1].type_id = .bool;
    try std.testing.expect(!validFunctionBody(body));
    arguments[1].type_id = .int;
    uses[0].coerce_to = .int;
    try std.testing.expect(!validFunctionBody(body));
    uses[0].coerce_to = null;
    uses[0].variant_tag_mapping = .{ .start = 0, .end = 1 };
    try std.testing.expect(!validFunctionBody(body));
    uses[0].variant_tag_mapping = null;
    try std.testing.expect(validFunctionBody(body));
}
