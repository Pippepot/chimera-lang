const std = @import("std");
const structures = @import("../structures.zig");
const Graph = @import("graph.zig").Graph;

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const SourceSpan = structures.SourceSpan;
const InlineFrameId = structures.InlineFrameId;

pub const Definition = union(enum) {
    argument: struct { block: u32, data: structures.FunctionBlockArgument },
    instruction: u32,
};

pub const Changes = struct {
    changed: bool = false,
    storage: bool = false,
    control_flow: bool = false,
    uses: bool = false,
};

pub const Block = struct {
    parameters: std.ArrayList(ValueId) = .empty,
    instructions: std.ArrayList(u32) = .empty,
    terminator: Terminator,
    span: SourceSpan,
    frame: InlineFrameId,
};

/// Interned type ids are small and dense, so a multiplicative hash spreads them well.
const TypeContext = struct {
    pub fn hash(_: TypeContext, type_id: structures.TypeId) u64 {
        return @as(u64, @backingInt(type_id)) *% 0x9e3779b97f4a7c15;
    }

    pub fn eql(_: TypeContext, first: structures.TypeId, second: structures.TypeId) bool {
        return first == second;
    }
};

pub const Function = struct {
    scratch: std.mem.Allocator,
    return_type: structures.TypeId,
    is_initializer_region: bool,
    parameter_modes: []const structures.ParameterMode,
    publishes_spans: bool,
    root_instance: ?structures.InstanceId,
    entry: u32,
    definitions: std.ArrayList(Definition) = .empty,
    replacement: std.ArrayList(ValueId) = .empty,
    instructions: std.ArrayList(Instruction) = .empty,
    results: std.ArrayList(ValueId) = .empty,
    removed: std.ArrayList(bool) = .empty,
    spans: std.ArrayList(SourceSpan) = .empty,
    frames: std.ArrayList(InlineFrameId) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    order: std.ArrayList(u32) = .empty,
    call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
    branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
    initializer_captures: std.ArrayList(ValueId) = .empty,
    aggregate_fields: std.ArrayList(ValueId) = .empty,
    variant_coercion_tags: std.ArrayList(u32) = .empty,
    borrow_fields: std.ArrayList(structures.BorrowProjection) = .empty,
    inline_frames: std.ArrayList(structures.InlineFrame) = .empty,
    regions: std.ArrayList(Body) = .empty,
    direct_types: std.HashMapUnmanaged(structures.TypeId, bool, TypeContext, 80) = .empty,
    classified_values: usize = 0,
    control_flow: ?Graph = null,
    canonical_loops: ?[]const @import("loops.zig").Loop = null,
    operands_dirty: bool = false,
    address_taken: ?[]const bool = null,
    storage_possible: bool = true,
    join_parameters_possible: bool = true,

    pub fn hasJoinParameters(self: *Function) bool {
        if (!self.join_parameters_possible) return false;
        for (self.blocks.items, 0..) |block, index| {
            if (index != self.entry and block.parameters.items.len != 0) return true;
        }
        self.join_parameters_possible = false;
        return false;
    }

    pub fn hasStorage(self: *Function) bool {
        if (!self.storage_possible) return false;
        for (self.instructions.items, self.removed.items) |instruction, removed| {
            if (!removed and instruction == .local_storage) return true;
        }
        self.storage_possible = false;
        return false;
    }

    pub fn invalidateOperands(self: *Function) void {
        self.operands_dirty = true;
        self.address_taken = null;
    }

    pub fn controlFlow(self: *Function) !*Graph {
        const graph = try self.controlFlowEdges();
        try graph.analyzeDominance(self.scratch);
        return graph;
    }

    pub fn controlFlowEdges(self: *Function) !*Graph {
        if (self.control_flow == null) self.control_flow = try Graph.init(self.scratch, self);
        return &self.control_flow.?;
    }

    pub fn invalidateControlFlow(self: *Function) void {
        self.control_flow = null;
        self.canonical_loops = null;
        self.invalidateOperands();
    }

    pub fn init(scratch: std.mem.Allocator, body: *const Body, regions: []const Body) !Function {
        var function: Function = .{
            .scratch = scratch,
            .return_type = body.return_type,
            .is_initializer_region = body.is_initializer_region,
            .parameter_modes = body.parameter_modes,
            .publishes_spans = body.terminator_spans.len != 0,
            .root_instance = body.root_instance,
            .entry = @backingInt(body.entry),
            .storage_possible = false,
        };
        const framed = body.inline_frames.len != 0;
        try function.blocks.ensureTotalCapacity(scratch, body.blocks.len);
        for (body.blocks, 0..) |block, index| function.blocks.appendAssumeCapacity(.{
            .terminator = block.terminator,
            .span = if (function.publishes_spans) body.terminator_spans[index] else .{ .start = 0, .end = 0 },
            .frame = if (framed) body.terminator_frames[index] else .root,
        });
        try function.order.ensureTotalCapacity(scratch, body.blocks.len);
        for (0..body.blocks.len) |index| function.order.appendAssumeCapacity(@intCast(index));
        try function.definitions.ensureTotalCapacity(scratch, body.valueCount());
        try function.replacement.ensureTotalCapacity(scratch, body.valueCount());
        for (body.block_arguments) |argument| {
            function.definitions.appendAssumeCapacity(.{ .argument = .{ .block = 0, .data = argument } });
            function.replacement.appendAssumeCapacity(@fromBackingInt(@intCast(function.replacement.items.len)));
        }
        for (body.blocks, function.blocks.items, 0..) |block, *editable, index| {
            try editable.parameters.ensureTotalCapacityPrecise(scratch, block.argument_end - block.argument_start);
            try editable.instructions.ensureTotalCapacityPrecise(scratch, block.instruction_end - block.instruction_start);
            for (block.argument_start..block.argument_end) |argument| {
                function.definitions.items[argument].argument.block = @intCast(index);
                editable.parameters.appendAssumeCapacity(@fromBackingInt(@intCast(argument)));
            }
            for (block.instruction_start..block.instruction_end) |instruction| editable.instructions.appendAssumeCapacity(@intCast(instruction));
        }
        try function.instructions.appendSlice(scratch, body.instructions);
        try function.removed.appendNTimes(scratch, false, body.instructions.len);
        try function.results.ensureTotalCapacityPrecise(scratch, body.instructions.len);
        try function.spans.appendSlice(scratch, body.instruction_spans);
        if (framed) try function.frames.appendSlice(scratch, body.instruction_frames) else if (function.publishes_spans) try function.frames.appendNTimes(scratch, .root, body.instructions.len);
        for (body.instructions, 0..) |instruction, index| {
            if (instruction == .local_storage) function.storage_possible = true;
            function.definitions.appendAssumeCapacity(.{ .instruction = @intCast(index) });
            function.replacement.appendAssumeCapacity(@fromBackingInt(@intCast(function.replacement.items.len)));
            function.results.appendAssumeCapacity(body.instructionValue(index));
        }
        inline for (.{ "call_arguments", "branch_arguments", "initializer_captures", "aggregate_fields", "variant_coercion_tags", "borrow_fields", "inline_frames" }) |table| {
            try @field(function, table).appendSlice(scratch, @field(body, table));
        }
        try function.regions.appendSlice(scratch, regions);
        return function;
    }

    pub fn classifyTypes(self: *Function, context: anytype) !void {
        for (self.definitions.items[self.classified_values..]) |defined| {
            const type_id = switch (defined) {
                .argument => |argument| argument.data.type_id,
                .instruction => |index| self.instructions.items[index].resultType(),
            };
            if (scalar(type_id) or self.direct_types.contains(type_id)) continue;
            try self.direct_types.put(self.scratch, type_id, !try context.passesIndirectly(type_id));
        }
        self.classified_values = self.definitions.items.len;
    }

    pub fn direct(self: *const Function, type_id: structures.TypeId) bool {
        return scalar(type_id) or (self.direct_types.get(type_id) orelse false);
    }

    pub fn valueCount(self: *const Function) usize {
        return self.definitions.items.len;
    }

    pub fn definition(self: *const Function, value: ValueId) ?Instruction {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => null,
            .instruction => |index| self.instructions.items[index],
        };
    }

    pub fn instructionIndex(self: *const Function, value: ValueId) ?u32 {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => null,
            .instruction => |index| index,
        };
    }

    pub fn valueType(self: *const Function, value: ValueId) structures.TypeId {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => |argument| argument.data.type_id,
            .instruction => |index| self.instructions.items[index].resultType(),
        };
    }

    /// Direct value parameters receive copies; other parameters alias their incoming storage.
    pub fn directParameter(self: *const Function, parameter: ValueId) bool {
        const data = self.definitions.items[@backingInt(parameter)].argument.data;
        return data.representation == .value and self.direct(data.type_id);
    }

    pub fn constantInt(self: *const Function, value: ValueId) ?i32 {
        return switch (self.definition(self.find(value)) orelse return null) {
            .const_int => |integer| integer,
            .const_bool => |boolean| @intFromBool(boolean),
            .const_byte => |byte| byte,
            else => null,
        };
    }

    pub fn constantBool(self: *const Function, value: ValueId) ?bool {
        const instruction = self.definition(self.find(value)) orelse return null;
        return if (instruction == .const_bool) instruction.const_bool else null;
    }

    pub fn plainValue(self: *const Function, value: ValueId) bool {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => |argument| argument.data.representation == .value and (argument.block == self.entry or self.direct(argument.data.type_id)),
            .instruction => |index| switch (self.instructions.items[index]) {
                // Cursor operations snapshot an address, not the contents it points to.
                .const_numeric, .numeric_binary, .numeric_unary, .numeric_convert, .const_int, .const_bool, .const_byte, .const_unit, .const_none, .const_static_string, .addi, .subi, .muli, .divsi, .shli, .shrsi, .negi, .variant_tag, .field_access, .compare, .select, .aggregate, .function_ref, .erased_callable, .callable_payload, .callable_invoke, .callable_allocation, .borrow_address, .const_storage_cursor, .storage_cursor, .cursor_offset, .cursor_element => true,
                inline .value_copy, .call, .variant_coerce, .variant_extract => |operation| operation.destination == null,
                else => false,
            },
        };
    }

    pub fn find(self: *const Function, value: ValueId) ValueId {
        var current = value;
        while (self.replacement.items[@backingInt(current)] != current) current = self.replacement.items[@backingInt(current)];
        return current;
    }

    pub fn replace(self: *Function, value: ValueId, target: ValueId) void {
        const canonical = self.find(target);
        std.debug.assert(canonical != value);
        self.replacement.items[@backingInt(value)] = canonical;
        self.invalidateOperands();
    }

    pub fn newInstruction(self: *Function, instruction: Instruction, span: SourceSpan, frame: InlineFrameId) !u32 {
        self.invalidateOperands();
        if (instruction == .local_storage) self.storage_possible = true;
        const index: u32 = @intCast(self.instructions.items.len);
        const value: ValueId = @fromBackingInt(@intCast(self.definitions.items.len));
        try self.instructions.append(self.scratch, instruction);
        try self.removed.append(self.scratch, false);
        if (self.publishes_spans) {
            try self.spans.append(self.scratch, span);
            try self.frames.append(self.scratch, frame);
        }
        try self.results.append(self.scratch, value);
        try self.definitions.append(self.scratch, .{ .instruction = index });
        try self.replacement.append(self.scratch, value);
        return index;
    }

    pub fn insertInstruction(self: *Function, block: u32, position: usize, instruction: Instruction, span: SourceSpan, frame: InlineFrameId) !ValueId {
        const index = try self.newInstruction(instruction, span, frame);
        try self.blocks.items[block].instructions.insert(self.scratch, position, index);
        return self.results.items[index];
    }

    pub fn appendInstruction(self: *Function, block: u32, instruction: Instruction, span: SourceSpan, frame: InlineFrameId) !ValueId {
        return self.insertInstruction(block, self.blocks.items[block].instructions.items.len, instruction, span, frame);
    }

    /// Appends an instruction that carries the block's own source position.
    pub fn appendLocal(self: *Function, block: u32, instruction: Instruction) !ValueId {
        const site = self.blocks.items[block];
        return self.appendInstruction(block, instruction, site.span, site.frame);
    }

    pub fn instructionSpan(self: *const Function, index: u32) SourceSpan {
        return if (self.publishes_spans) self.spans.items[index] else .{ .start = 0, .end = 0 };
    }

    pub fn instructionFrame(self: *const Function, index: u32) InlineFrameId {
        return if (self.publishes_spans) self.frames.items[index] else .root;
    }

    pub fn addParameter(self: *Function, block: u32, argument: structures.FunctionBlockArgument) !ValueId {
        self.invalidateOperands();
        if (block != self.entry) self.join_parameters_possible = true;
        const value: ValueId = @fromBackingInt(@intCast(self.definitions.items.len));
        try self.definitions.append(self.scratch, .{ .argument = .{ .block = block, .data = argument } });
        try self.replacement.append(self.scratch, value);
        try self.blocks.items[block].parameters.append(self.scratch, value);
        return value;
    }

    pub fn addBlock(self: *Function, terminator: Terminator, span: SourceSpan, frame: InlineFrameId) !u32 {
        self.invalidateControlFlow();
        const index: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(self.scratch, .{ .terminator = terminator, .span = span, .frame = frame });
        return index;
    }

    pub fn placeAfter(self: *Function, block: u32, previous: u32) !void {
        const position = std.mem.indexOfScalar(u32, self.order.items, previous).?;
        try self.order.insert(self.scratch, position + 1, block);
    }

    pub fn splitBlock(self: *Function, block: u32, position: usize) !u32 {
        const original = &self.blocks.items[block];
        const tail = try self.addBlock(original.terminator, original.span, original.frame);
        const head = &self.blocks.items[block];
        try self.blocks.items[tail].instructions.appendSlice(self.scratch, head.instructions.items[position..]);
        head.instructions.shrinkRetainingCapacity(position);
        head.terminator = .{ .branch = .{ .target = @fromBackingInt(tail), .arguments = .{ .start = 0, .end = 0 } } };
        try self.placeAfter(tail, block);
        return tail;
    }

    pub fn branchArguments(self: *const Function, branch: structures.FunctionBranch) []structures.FunctionValueUse {
        return self.branch_arguments.items[branch.arguments.start..branch.arguments.end];
    }

    pub fn appendBranchArguments(self: *Function, values: []const structures.FunctionValueUse) !structures.FunctionValueRange {
        self.invalidateOperands();
        const start: u32 = @intCast(self.branch_arguments.items.len);
        try self.branch_arguments.appendSlice(self.scratch, values);
        return .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
    }

    /// Copies a branch argument range, appending values for added target parameters.
    pub fn copyBranchArguments(self: *Function, range: structures.FunctionValueRange, appended: []const ValueId) !structures.FunctionValueRange {
        self.invalidateOperands();
        try self.branch_arguments.ensureUnusedCapacity(self.scratch, range.end - range.start + appended.len);
        const start: u32 = @intCast(self.branch_arguments.items.len);
        for (range.start..range.end) |index| self.branch_arguments.appendAssumeCapacity(self.branch_arguments.items[index]);
        for (appended) |value| self.branch_arguments.appendAssumeCapacity(.{ .value = value });
        return .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
    }

    pub fn removeParameter(self: *Function, block: u32, position: usize, incoming: []const @import("graph.zig").Incoming) !void {
        self.invalidateOperands();
        _ = self.blocks.items[block].parameters.orderedRemove(position);
        for (incoming) |edge| {
            const branch = edge.branch(self);
            try self.branch_arguments.ensureUnusedCapacity(self.scratch, branch.arguments.end - branch.arguments.start);
            const arguments = self.branchArguments(branch.*);
            const start: u32 = @intCast(self.branch_arguments.items.len);
            for (arguments, 0..) |argument, index| if (index != position) self.branch_arguments.appendAssumeCapacity(argument);
            branch.arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
        }
    }

    pub fn successors(self: *const Function, block: u32) [2]?u32 {
        var result: [2]?u32 = .{ null, null };
        for (self.blocks.items[block].terminator.successors(), &result) |target, *successor| {
            if (target) |id| successor.* = @backingInt(id.*);
        }
        return result;
    }

    /// The tag of an argument that injects exactly one alternative into a variant.
    pub fn injectedTag(self: *const Function, use: structures.FunctionValueUse) ?u32 {
        const mapping = use.variant_tag_mapping orelse return null;
        if (use.coerce_to == null or mapping.end - mapping.start != 1) return null;
        return self.variant_coercion_tags.items[mapping.start];
    }

    pub fn branchTo(self: *const Function, block: u32, target: u32) ?*structures.FunctionBranch {
        for (self.blocks.items[block].terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
            if (@backingInt(branch.target) == target) return branch;
        };
        return null;
    }

    pub fn resolveReferences(self: *Function) void {
        if (!self.operands_dirty) return;
        self.address_taken = null;
        for (self.blocks.items) |*block| {
            for (block.instructions.items) |index| {
                if (!self.removed.items[index]) visitOperands(self, &self.instructions.items[index], .all, self, resolveOperand);
            }
            visitTerminatorOperands(self, &block.terminator, .all, self, resolveOperand);
        }
        self.operands_dirty = false;
    }

    pub fn resolveOperand(self: *Function, value: *ValueId) void {
        value.* = self.find(value.*);
    }
};

test "optimizer operand normalization invalidates after replacement and appended uses" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var function: Function = .{
        .scratch = arena.allocator(),
        .return_type = .int,
        .is_initializer_region = false,
        .parameter_modes = &.{},
        .publishes_spans = false,
        .root_instance = null,
        .entry = 0,
    };
    const span: SourceSpan = .{ .start = 0, .end = 0 };
    _ = try function.addBlock(.return_unit, span, .root);
    try testing.expect(!function.hasJoinParameters());
    const first = try function.insertInstruction(0, 0, .{ .const_int = 1 }, span, .root);
    const second = try function.insertInstruction(0, 1, .{ .const_int = 2 }, span, .root);
    const third = try function.insertInstruction(0, 2, .{ .const_int = 3 }, span, .root);
    const copied = try function.insertInstruction(0, 3, .{ .value_copy = .{ .source = first, .type_id = .int } }, span, .root);
    function.replace(first, second);
    function.resolveReferences();
    try testing.expect(!function.operands_dirty);
    try testing.expectEqual(second, function.definition(copied).?.value_copy.source);
    function.resolveReferences();
    function.replace(second, third);
    function.resolveReferences();
    try testing.expectEqual(third, function.definition(copied).?.value_copy.source);
    const appended = try function.insertInstruction(0, 4, .{ .value_copy = .{ .source = first, .type_id = .int } }, span, .root);
    try testing.expect(function.operands_dirty);
    function.resolveReferences();
    try testing.expectEqual(third, function.definition(appended).?.value_copy.source);
    const detached = try function.newInstruction(.{ .value_copy = .{ .source = first, .type_id = .int } }, span, .root);
    const obsolete = try function.appendBranchArguments(&.{.{ .value = first }});
    try function.aggregate_fields.append(function.scratch, first);
    try function.initializer_captures.append(function.scratch, first);
    const arguments = try function.appendBranchArguments(&.{.{ .value = first }});
    const destination = try function.addBlock(.return_unit, span, .root);
    _ = try function.addParameter(destination, .{ .type_id = .int });
    try testing.expect(function.hasJoinParameters());
    function.blocks.items[0].terminator = .{ .branch = .{ .target = @fromBackingInt(destination), .arguments = arguments } };
    function.invalidateControlFlow();
    function.resolveReferences();
    try testing.expectEqual(third, function.branch_arguments.items[arguments.start].value);
    try testing.expectEqual(first, function.instructions.items[detached].value_copy.source);
    try testing.expectEqual(first, function.branch_arguments.items[obsolete.start].value);
    try testing.expectEqual(first, function.aggregate_fields.items[0]);
    try testing.expectEqual(first, function.initializer_captures.items[0]);
    try testing.expect(!function.operands_dirty);
    try testing.expect(!function.hasStorage());
    const canonicalize = @import("canonicalize.zig");
    const storage = try function.insertInstruction(0, 5, .{ .local_storage = .int }, span, .root);
    try testing.expect(function.hasStorage());
    const stored = try function.insertInstruction(0, 6, .{ .value_copy = .{ .source = third, .destination = storage, .type_id = .int } }, span, .root);
    function.resolveReferences();
    const taken = try canonicalize.addressTaken(&function);
    try testing.expect(taken[@backingInt(storage)]);
    try testing.expectEqual(taken.ptr, (try canonicalize.addressTaken(&function)).ptr);
    function.removed.items[function.instructionIndex(stored).?] = true;
    function.invalidateOperands();
    const released = try canonicalize.addressTaken(&function);
    try testing.expect(!released[@backingInt(storage)]);
    try testing.expect(taken.ptr != released.ptr);
    function.resolveReferences();
    try testing.expect(function.address_taken == null);
    function.removed.items[function.instructionIndex(storage).?] = true;
    try testing.expect(!function.hasStorage());
    _ = try function.newInstruction(.{ .local_storage = .int }, span, .root);
    try testing.expect(function.hasStorage());
}

const StorageUses = struct {
    function: *const Function,
    found: bool = false,

    fn reference(self: *StorageUses, value: ValueId) void {
        const instruction = self.function.definition(self.function.find(value)) orelse return;
        if (instruction == .local_storage) self.found = true;
    }
};

pub fn usesStorage(function: *const Function, instruction: *const Instruction) bool {
    var uses: StorageUses = .{ .function = function };
    visitOperands(function, instruction, .all, &uses, StorageUses.reference);
    return uses.found;
}

/// Appends a copy of `source[range]` to `table` and returns the copied range.
pub fn copyRange(comptime T: type, scratch: std.mem.Allocator, table: *std.ArrayList(T), source: []const T, range: structures.FunctionValueRange) !structures.FunctionValueRange {
    const start: u32 = @intCast(table.items.len);
    try table.appendSlice(scratch, source[range.start..range.end]);
    return .{ .start = start, .end = @intCast(table.items.len) };
}

pub fn scalar(type_id: structures.TypeId) bool {
    return type_id.numericType() != null or type_id == .bool;
}

pub fn zero(type_id: structures.TypeId) Instruction {
    return if (type_id == .bool) .{ .const_bool = false } else Instruction.numericConstantInstruction(type_id, 0);
}

/// Whether a typed numeric operation can still trap. Division and shifts by a constant
/// right operand they accept never do.
pub inline fn numericMayTrap(function: *const Function, instruction: Instruction) bool {
    if (!instruction.numericMayTrap()) return false;
    if (instruction != .numeric_binary) return true;
    return switch (instruction.numeric_binary.operation) {
        .div, .rem, .shl, .shr => constantRightMayTrap(function, instruction.numeric_binary),
        else => true,
    };
}

fn constantRightMayTrap(function: *const Function, operation: structures.NumericBinary) bool {
    const kind = operation.type_id.numericType().?;
    const constant = (function.definition(function.find(operation.operands.rhs)) orelse return true).numericConstant() orelse return true;
    const value = structures.numeric.asInteger(kind, constant.bits);
    return switch (operation.operation) {
        .div, .rem => value == 0 or (kind.isSigned() and value == -1),
        .shl, .shr => value < 0 or value >= kind.width(),
        else => unreachable,
    };
}

/// Integer division and shifts are pure only for constant right operands they accept.
pub fn validConstantRhs(function: *const Function, instruction: Instruction, rhs: ValueId) bool {
    const constant = function.definition(rhs) orelse return false;
    return constant == .const_int and instruction.integerRhsIsValid(constant.const_int);
}

/// Which operands a traversal reaches. A read operand supplies a value; an address
/// operand names storage that the instruction reads or writes through.
pub const Roles = struct {
    read: bool,
    address: bool,

    pub const all: Roles = .{ .read = true, .address = true };
    pub const reads: Roles = .{ .read = true, .address = false };
    pub const addresses: Roles = .{ .read = false, .address = true };
};

/// Forwards operands of the selected roles; `visit` takes either the operand pointer or its value.
fn Walk(comptime Context: type, comptime roles: Roles, comptime visit: anytype) type {
    return struct {
        context: Context,

        inline fn emit(self: @This(), operand: anytype) void {
            const by_value = @typeInfo(@TypeOf(visit)).@"fn".param_types[1].? == ValueId;
            visit(self.context, if (by_value) operand.* else operand);
        }

        inline fn read(self: @This(), operand: anytype) void {
            if (roles.read) self.emit(operand);
        }

        inline fn address(self: @This(), operand: anytype) void {
            if (roles.address) self.emit(operand);
        }
    };
}

/// Visits the operands of an instruction, including its side-table operands.
pub fn visitOperands(function: *const Function, instruction: anytype, comptime roles: Roles, context: anytype, comptime visit: anytype) void {
    const walk: Walk(@TypeOf(context), roles, visit) = .{ .context = context };
    // Every operand: the hot path of operand resolution, so it avoids per-kind dispatch.
    if (roles.read and roles.address) {
        for (instruction.operands()) |operand| if (operand) |value| walk.read(value);
        switch (instruction.*) {
            .call => |call| for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |*argument| walk.read(argument.operand()),
            .initializer_ref => |reference| for (function.initializer_captures.items[reference.captures.start..reference.captures.end]) |*capture| walk.read(capture),
            .aggregate => |aggregate| for (function.aggregate_fields.items[aggregate.fields.start..aggregate.fields.end]) |*field| walk.read(field),
            else => {},
        }
        return;
    }
    switch (instruction.*) {
        .value_copy => |*operation| {
            walk.read(&operation.source);
            if (operation.destination) |*destination| walk.address(destination);
        },
        inline .variant_coerce, .variant_extract => |*operation| {
            walk.read(&operation.operand);
            if (operation.destination) |*destination| walk.address(destination);
        },
        .static_conversion => |*operation| {
            walk.address(&operation.operand);
            if (operation.destination) |*destination| walk.address(destination);
        },
        .storage_projection => |*operation| walk.address(&operation.owner),
        .storage_cursor => |*operation| walk.address(&operation.source),
        .array_element => |*operation| {
            walk.address(&operation.array);
            walk.read(&operation.index);
        },
        .borrow_address => |*operation| if (operation.base_is_reference) walk.read(&operation.source) else walk.address(&operation.source),
        .fill => |*operation| {
            walk.address(&operation.first);
            walk.read(&operation.count);
            walk.read(&operation.value);
        },
        .move => |*operation| {
            walk.address(&operation.destination);
            walk.address(&operation.source);
            walk.read(&operation.count);
        },
        .aggregate => |aggregate| if (roles.read) for (function.aggregate_fields.items[aggregate.fields.start..aggregate.fields.end]) |*field| walk.read(field),
        .initializer_ref => |reference| if (roles.address) for (function.initializer_captures.items[reference.captures.start..reference.captures.end]) |*capture| walk.address(capture),
        .call => |*call| {
            switch (call.target) {
                .indirect, .initializer => |*target| walk.read(target),
                .direct => {},
            }
            if (call.destination) |*destination| walk.address(destination);
            for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |*argument| switch (argument.*) {
                .prepared => |*use| walk.read(&use.value),
                .deinit, .borrowed, .initializer => |*source| walk.address(source),
            };
        },
        else => if (roles.read) for (instruction.operands()) |operand| if (operand) |value| walk.read(value),
    }
}

/// Visits the terminator operands and the branch arguments. An argument passed to a
/// direct parameter is a read; any other argument shares storage with its parameter.
pub fn visitTerminatorOperands(function: *const Function, terminator: anytype, comptime roles: Roles, context: anytype, comptime visit: anytype) void {
    const walk: Walk(@TypeOf(context), roles, visit) = .{ .context = context };
    if (roles.read) for (terminator.operands()) |operand| if (operand) |value| walk.read(value);
    var copy = terminator.*;
    for (copy.branches()) |maybe_branch| if (maybe_branch) |branch| {
        if (roles.read and roles.address) {
            for (function.branchArguments(branch.*)) |*argument| walk.read(&argument.value);
            continue;
        }
        const parameters = function.blocks.items[@backingInt(branch.target)].parameters.items;
        for (function.branchArguments(branch.*), 0..) |*argument, position| {
            if (position < parameters.len and function.directParameter(parameters[position])) walk.read(&argument.value) else walk.address(&argument.value);
        }
    };
}

/// Visits the live instructions and the terminator of one block.
pub fn visitBlockOperands(function: *const Function, block: anytype, comptime roles: Roles, context: anytype, comptime visit: anytype) void {
    for (block.instructions.items) |index| {
        if (!function.removed.items[index]) visitOperands(function, &function.instructions.items[index], roles, context, visit);
    }
    visitTerminatorOperands(function, &block.terminator, roles, context, visit);
}

const Uses = struct {
    function: *const Function,
    from: []const ValueId,
    to: []const ValueId = &.{},
    count: u32 = 0,

    fn visit(self: *Uses, operand: *ValueId) void {
        const position = std.mem.indexOfScalar(ValueId, self.from, self.function.find(operand.*)) orelse return;
        self.count += 1;
        if (self.to.len != 0) operand.* = self.to[position];
    }
};

/// The number of operands in an instruction that name one of `values`.
pub fn countInstructionUses(function: *const Function, instruction: *Instruction, values: []const ValueId) u32 {
    var uses: Uses = .{ .function = function, .from = values };
    visitOperands(function, instruction, .all, &uses, Uses.visit);
    return uses.count;
}

/// The number of operands in a block that name one of `values`.
pub fn countUses(function: *const Function, block: *Block, values: []const ValueId) u32 {
    var uses: Uses = .{ .function = function, .from = values };
    visitBlockOperands(function, block, .all, &uses, Uses.visit);
    return uses.count;
}

/// Replaces each operand of a block that names `from[position]` by `to[position]`.
pub fn replaceUses(function: *const Function, block: *Block, from: []const ValueId, to: []const ValueId) void {
    var uses: Uses = .{ .function = function, .from = from, .to = to };
    visitBlockOperands(function, block, .all, &uses, Uses.visit);
}
