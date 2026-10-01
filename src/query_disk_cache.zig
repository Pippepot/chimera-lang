const std = @import("std");
const cache = @import("cache.zig");
const codec = @import("query/codec.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const structures = @import("structures.zig");

const format = "CHIQRY08";
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
        if (std.mem.eql(u8, name, @typeName(queries.ModulePaths))) {
            try restoreIntern(queries.ModulePaths, db, &reader, index);
        } else if (std.mem.eql(u8, name, @typeName(queries.ItemLocations))) {
            try restoreIntern(queries.ItemLocations, db, &reader, index);
        } else if (std.mem.eql(u8, name, @typeName(queries.Types))) {
            try restoreIntern(queries.Types, db, &reader, index);
        } else if (std.mem.eql(u8, name, @typeName(queries.CompileTimeValues))) {
            try restoreIntern(queries.CompileTimeValues, db, &reader, index);
        } else if (std.mem.eql(u8, name, @typeName(queries.CompileTimeValueTuples))) {
            try restoreIntern(queries.CompileTimeValueTuples, db, &reader, index);
        } else return error.InvalidCache;
    }
    return reader.offset;
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
            const name = try reader.read([]const u8);
            defer reader.allocator.free(name);
            const matched = if (std.mem.eql(u8, name, @typeName(queries.SourceText)))
                try restoreInput(queries.SourceText, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.FileModule)))
                try restoreInput(queries.FileModule, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.ModuleMembers)))
                try restoreInput(queries.ModuleMembers, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.ModuleCatalog)))
                try restoreInput(queries.ModuleCatalog, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.StandardPreludeModule)))
                try restoreInput(queries.StandardPreludeModule, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.StandardFile)))
                try restoreInput(queries.StandardFile, db, reader, valid)
            else
                return error.InvalidCache;
            if (matched) |dep| {
                try deps.append(reader.allocator, dep);
            } else valid = false;
        }
        const query_dep_count = try readCount(reader);
        for (0..query_dep_count) |_| {
            const name = try reader.read([]const u8);
            defer reader.allocator.free(name);
            const matched = if (std.mem.eql(u8, name, @typeName(queries.BuildModuleScope)))
                try restoreQueryDependency(queries.BuildModuleScope, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.ModuleDeclarations)))
                try restoreQueryDependency(queries.ModuleDeclarations, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.IndexModuleItems)))
                try restoreQueryDependency(queries.IndexModuleItems, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.ResolveItem)))
                try restoreQueryDependency(queries.ResolveItem, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.FunctionSignature)))
                try restoreQueryDependency(queries.FunctionSignature, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.FunctionInstanceSignature)))
                try restoreQueryDependency(queries.FunctionInstanceSignature, db, reader, valid)
            else if (std.mem.eql(u8, name, @typeName(queries.AnalyzeFunctionInstance)))
                try restoreQueryDependency(queries.AnalyzeFunctionInstance, db, reader, valid)
            else
                return error.InvalidCache;
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

fn validateIds(comptime T: type, db: *query.Database, value: T) !bool {
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
    if (!validFunctionBody(output.?)) return false;
    return validReferenceOperations(db, output.?) catch |err| switch (err) {
        error.Unavailable => false,
        else => return err,
    };
}

fn validReferenceOperations(db: *query.Database, body: structures.FunctionBodyAnalysis) !bool {
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    for (body.instructions) |instruction| {
        if (instruction == .borrow_address) {
            if (!try validBorrowFields(types, body, instruction.borrow_address)) return false;
            continue;
        }
        if (instruction == .storage_projection and !try validStorageProjection(types, body, instruction.storage_projection)) return false;
    }
    return true;
}

fn validBorrowFields(types: anytype, body: structures.FunctionBodyAnalysis, operation: structures.BorrowAddressOperation) !bool {
    const source_index = @intFromEnum(operation.source);
    var type_id = if (source_index < body.block_argument_types.len)
        body.block_argument_types[source_index]
    else
        body.instructions[source_index - body.block_argument_types.len].resultType();
    if (operation.base_is_reference) type_id = (try types.borrowElement(type_id)) orelse return false;
    for (body.borrow_fields[operation.fields.start..operation.fields.end]) |field_index| {
        const definition = (try types.structDefinition(type_id)) orelse return false;
        if (field_index >= definition.fields.len) return false;
        type_id = definition.fields[field_index].type_id;
    }
    return type_id == ((try types.borrowElement(operation.type_id)) orelse return false);
}

fn validStorageProjection(types: anytype, body: structures.FunctionBodyAnalysis, operation: structures.StorageProjection) !bool {
    const index = @intFromEnum(operation.owner);
    const type_id = if (index < body.block_argument_types.len) body.block_argument_types[index] else body.instructions[index - body.block_argument_types.len].resultType();
    switch (operation.projection) {
        .dereference => return true,
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
    return validValue(use.value, body) and
        (use.variant_tag_mapping == null or validRange(use.variant_tag_mapping.?, body.variant_coercion_tags.len));
}

fn validCall(call: structures.FunctionCall, body: structures.FunctionBodyAnalysis) bool {
    return validRange(call.arguments, body.call_arguments.len);
}

fn validBranch(branch: structures.FunctionBranch, body: structures.FunctionBodyAnalysis) bool {
    if (@intFromEnum(branch.target) >= body.blocks.len or !validRange(branch.arguments, body.branch_arguments.len)) return false;
    const target = body.blocks[@intFromEnum(branch.target)];
    if (target.argument_start > target.argument_end or target.argument_end > body.block_argument_types.len) return false;
    return branch.arguments.end - branch.arguments.start == target.argument_end - target.argument_start;
}

fn validVariantOperation(operation: structures.VariantOperation, body: structures.FunctionBodyAnalysis) bool {
    return operation.tag_mapping == null or validRange(operation.tag_mapping.?, body.variant_coercion_tags.len);
}

fn validFunctionBody(body: structures.FunctionBodyAnalysis) bool {
    if (body.blocks.len == 0 or @intFromEnum(body.entry) >= body.blocks.len) return false;
    if (body.valueCount() > std.math.maxInt(u32)) return false;
    if (body.instruction_spans.len != 0 and body.instruction_spans.len != body.instructions.len) return false;
    if (body.terminator_spans.len != 0 and body.terminator_spans.len != body.blocks.len) return false;
    for (body.struct_field_values) |field| if (!validValue(field.value, body)) return false;
    for (body.branch_arguments) |use| if (!validUse(use, body)) return false;
    for (body.call_arguments) |argument| if (!validUse(argument.valueUse(), body)) return false;
    const entry = body.blocks[@intFromEnum(body.entry)];
    if (entry.argument_start > entry.argument_end or entry.argument_end > body.block_argument_types.len) return false;
    if (body.parameter_modes.len != entry.argument_end - entry.argument_start) return false;
    for (body.instructions) |original| {
        var instruction = original;
        for (instruction.operands()) |operand| if (operand) |value| {
            if (!validValue(value.*, body)) return false;
        };
        const valid = switch (instruction) {
            .variant_coerce, .variant_extract, .callable_coerce => |operation| validVariantOperation(operation, body),
            .struct_init => |operation| validRange(operation.fields, body.struct_field_values.len),
            .result_storage => |type_id| type_id == body.return_type,
            .borrow_address => |operation| validRange(operation.fields, body.borrow_fields.len),
            .mut_parameter_write => |operation| operation.parameter_index < entry.argument_end - entry.argument_start,
            .call_mut_argument => |operation| validRange(operation.arguments, body.call_arguments.len) and
                operation.argument_index < operation.arguments.end - operation.arguments.start,
            .call => |call| validCall(call, body),
            else => true,
        };
        if (!valid) return false;
    }
    for (body.blocks) |block| {
        if (block.argument_start > block.argument_end or block.argument_end > body.block_argument_types.len or
            block.instruction_start > block.instruction_end or block.instruction_end > body.instructions.len) return false;
        var terminator = block.terminator;
        for (terminator.operands()) |operand| if (operand) |value| {
            if (!validValue(value.*, body)) return false;
        };
        for (terminator.successors()) |successor| if (successor) |target| {
            if (@intFromEnum(target.*) >= body.blocks.len) return false;
        };
        const valid = switch (block.terminator) {
            .branch => |branch| validBranch(branch, body),
            .predicate_branch => |branch| validBranch(branch.then_branch, body) and validBranch(branch.else_branch, body),
            .fallible_call => |branch| validCall(branch.call, body) and
                validFallibleTargets(branch.success, branch.failure, body),
            .return_value => |use| validUse(use, body),
            .return_failure => body.is_fallible,
            .return_unit, .diverge => true,
        };
        if (!valid) return false;
    }
    return true;
}

fn validFallibleTargets(success: structures.FunctionBlockId, failure: structures.FunctionBlockId, body: structures.FunctionBodyAnalysis) bool {
    if (@intFromEnum(success) >= body.blocks.len or @intFromEnum(failure) >= body.blocks.len) return false;
    const success_block = body.blocks[@intFromEnum(success)];
    const failure_block = body.blocks[@intFromEnum(failure)];
    if (success_block.argument_start > success_block.argument_end or success_block.argument_end > body.block_argument_types.len or
        failure_block.argument_start > failure_block.argument_end or failure_block.argument_end > body.block_argument_types.len) return false;
    return success_block.argument_end - success_block.argument_start == 1 and
        failure_block.argument_end == failure_block.argument_start;
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
    var argument_types = [_]structures.TypeId{.int};
    var parameter_modes = [_]structures.ParameterMode{.imm};
    var branch_arguments: [0]structures.FunctionValueUse = .{};
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
        .block_argument_types = &argument_types,
        .branch_arguments = &branch_arguments,
        .call_arguments = &call_arguments,
        .instructions = instructions[0..0],
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    try std.testing.expect(validFunctionBody(body));

    blocks[0].terminator = .{ .branch = .{ .target = @enumFromInt(0), .arguments = .{ .start = 0, .end = 0 } } };
    try std.testing.expect(!validFunctionBody(body));

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
    try std.testing.expect(!(try validReferenceOperations(db, body)));

    const modules = @import("modules.zig");
    try modules.registerSources(db, std.testing.allocator,
        \\struct Pair
        \\  value: int
        \\static IntRef = Ref(int, false)
        \\exit(42)
    , &.{}, &.{});
    const module = try db.intern(queries.ModulePaths, .{ .path = "" });
    const pair = (try db.get(queries.ModuleDeclarations, module)).*.?.resolveStatic("Pair").?;
    const pair_type = structures.TypeId.fromInterned(try db.intern(queries.Types, .{ .structure = .{ .declared = pair } }));
    argument_types[0] = pair_type;
    instructions[0].storage_projection.projection = .{ .field = 0 };
    try std.testing.expect(try validReferenceOperations(db, body));
    instructions[0].storage_projection.projection = .{ .field = 7 };
    try std.testing.expect(!(try validReferenceOperations(db, body)));

    const variant_type = structures.TypeId.fromInterned(try db.intern(queries.Types, .{ .variant = .{ .members = &.{ .int, .byte } } }));
    argument_types[0] = variant_type;
    instructions[0].storage_projection.projection = .variant;
    try std.testing.expect(try validReferenceOperations(db, body));
    instructions[0].storage_projection.type_id = .bool;
    try std.testing.expect(!(try validReferenceOperations(db, body)));

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
    argument_types[0] = pair_type;
    instructions[0] = .{ .borrow_address = .{
        .source = @enumFromInt(0),
        .type_id = reference_type,
        .fields = .{ .start = 0, .end = 1 },
    } };
    try std.testing.expect(validFunctionBody(body));
    try std.testing.expect(try validReferenceOperations(db, body));
    path[0] = 1;
    try std.testing.expect(!(try validReferenceOperations(db, body)));
    path[0] = 0;
    instructions[0].borrow_address.fields.end = 2;
    try std.testing.expect(!validFunctionBody(body));
    instructions[0].borrow_address.fields.end = 1;
    instructions[0].borrow_address.type_id = .int;
    try std.testing.expect(!(try validReferenceOperations(db, body)));
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

test "in-place Box initializer bodies restore from disk" {
    const modules = @import("modules.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const source =
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible run() unit
        \\  const owner = Box.new(Immovable{value = 42})
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
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
    try save(io, allocator, directory, digest, first);
    const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);

    const second = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer second.deinit();
    const offset = try restoreInterns(second, allocator, payload);
    try modules.registerSources(second, allocator, source, &.{}, &.{});
    try std.testing.expect((try restoreQueries(second, payload, offset)) > 0);
    const run = (try second.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try second.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    var has_in_place_fields = false;
    for (body.instructions) |instruction| if (instruction == .value_copy and instruction.value_copy.destination != null) {
        has_in_place_fields = true;
    };
    try std.testing.expect(has_in_place_fields);
    const restored = (try second.get(queries.BuildExecutable, 0)).* orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, original.bytes, restored.bytes);
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
        \\const callback = take
        \\exit(callback(42))
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
