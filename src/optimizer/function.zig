const std = @import("std");
const structures = @import("../structures.zig");
const Graph = @import("graph.zig").Graph;

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const BlockId = structures.FunctionBlockId;
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
};

pub const Block = struct {
    parameters: std.ArrayList(ValueId) = .empty,
    instructions: std.ArrayList(u32) = .empty,
    terminator: Terminator,
    span: SourceSpan,
    frame: InlineFrameId,
};

pub const Edge = *structures.FunctionBranch;

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
    direct_types: std.AutoHashMapUnmanaged(structures.TypeId, bool) = .empty,
    classified_values: usize = 0,
    control_flow: ?Graph = null,
    operands_dirty: bool = false,
    address_taken: ?[]const bool = null,
    storage_possible: bool = true,

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
            for (block.argument_start..block.argument_end) |argument| {
                function.definitions.items[argument].argument.block = @intCast(index);
                try editable.parameters.append(scratch, @fromBackingInt(@intCast(argument)));
            }
            for (block.instruction_start..block.instruction_end) |instruction| try editable.instructions.append(scratch, @intCast(instruction));
        }
        try function.instructions.appendSlice(scratch, body.instructions);
        try function.removed.appendNTimes(scratch, false, body.instructions.len);
        try function.spans.appendSlice(scratch, body.instruction_spans);
        if (framed) try function.frames.appendSlice(scratch, body.instruction_frames) else if (function.publishes_spans) try function.frames.appendNTimes(scratch, .root, body.instructions.len);
        for (body.instructions, 0..) |instruction, index| {
            if (instruction == .local_storage) function.storage_possible = true;
            function.definitions.appendAssumeCapacity(.{ .instruction = @intCast(index) });
            function.replacement.appendAssumeCapacity(@fromBackingInt(@intCast(function.replacement.items.len)));
            try function.results.append(scratch, body.instructionValue(index));
        }
        try function.call_arguments.appendSlice(scratch, body.call_arguments);
        try function.branch_arguments.appendSlice(scratch, body.branch_arguments);
        try function.initializer_captures.appendSlice(scratch, body.initializer_captures);
        try function.aggregate_fields.appendSlice(scratch, body.aggregate_fields);
        try function.variant_coercion_tags.appendSlice(scratch, body.variant_coercion_tags);
        try function.borrow_fields.appendSlice(scratch, body.borrow_fields);
        try function.inline_frames.appendSlice(scratch, body.inline_frames);
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

    pub fn plainValue(self: *const Function, value: ValueId) bool {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => |argument| argument.data.representation == .value and (argument.block == self.entry or self.direct(argument.data.type_id)),
            .instruction => |index| switch (self.instructions.items[index]) {
                .const_int, .const_bool, .const_byte, .const_unit, .const_none, .addi, .subi, .muli, .divsi, .negi, .byte_to_int, .variant_tag, .field_access, .compare, .select, .aggregate, .function_ref, .borrow_address => true,
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
        std.debug.assert(self.find(target) != value);
        self.replacement.items[@backingInt(value)] = target;
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

    pub fn instructionSpan(self: *const Function, index: u32) SourceSpan {
        return if (self.publishes_spans) self.spans.items[index] else .{ .start = 0, .end = 0 };
    }

    pub fn instructionFrame(self: *const Function, index: u32) InlineFrameId {
        return if (self.publishes_spans) self.frames.items[index] else .root;
    }

    pub fn addParameter(self: *Function, block: u32, argument: structures.FunctionBlockArgument) !ValueId {
        self.invalidateOperands();
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

    pub fn copyBranchArguments(self: *Function, range: structures.FunctionValueRange) !structures.FunctionValueRange {
        self.invalidateOperands();
        try self.branch_arguments.ensureUnusedCapacity(self.scratch, range.end - range.start);
        const start: u32 = @intCast(self.branch_arguments.items.len);
        for (range.start..range.end) |index| self.branch_arguments.appendAssumeCapacity(self.branch_arguments.items[index]);
        return .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
    }

    pub fn appendBranchArgument(self: *Function, branch: *structures.FunctionBranch, value: ValueId) !void {
        self.invalidateOperands();
        const start: u32 = @intCast(self.branch_arguments.items.len);
        try self.branch_arguments.ensureUnusedCapacity(self.scratch, branch.arguments.end - branch.arguments.start + 1);
        for (branch.arguments.start..branch.arguments.end) |index| self.branch_arguments.appendAssumeCapacity(self.branch_arguments.items[index]);
        self.branch_arguments.appendAssumeCapacity(.{ .value = value });
        branch.arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
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

    pub fn edges(terminator: *Terminator) [2]?Edge {
        return switch (terminator.*) {
            .branch => |*branch| .{ branch, null },
            .predicate_branch => |*predicate| .{ &predicate.then_branch, &predicate.else_branch },
            .return_unit, .return_value, .diverge => .{ null, null },
        };
    }

    pub fn edgeTarget(edge: Edge) BlockId {
        return edge.target;
    }

    pub fn successors(self: *Function, block: u32) [2]?u32 {
        var result: [2]?u32 = .{ null, null };
        for (edges(&self.blocks.items[block].terminator), &result) |maybe_edge, *successor| {
            if (maybe_edge) |edge| successor.* = @backingInt(edgeTarget(edge));
        }
        return result;
    }

    pub fn resolveReferences(self: *Function) void {
        if (!self.operands_dirty) return;
        self.address_taken = null;
        for (self.instructions.items, self.removed.items) |*instruction, removed| {
            if (removed) continue;
            for (instruction.operands()) |operand| if (operand) |value| {
                value.* = self.find(value.*);
            };
        }
        for (self.blocks.items) |*block| for (block.terminator.operands()) |operand| if (operand) |value| {
            value.* = self.find(value.*);
        };
        for (self.call_arguments.items) |*argument| argument.operand().* = self.find(argument.valueId());
        for (self.branch_arguments.items) |*argument| argument.value = self.find(argument.value);
        for (self.initializer_captures.items) |*capture| capture.* = self.find(capture.*);
        for (self.aggregate_fields.items) |*field| field.* = self.find(field.*);
        self.operands_dirty = false;
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
    const arguments = try function.appendBranchArguments(&.{.{ .value = first }});
    function.resolveReferences();
    try testing.expectEqual(third, function.branch_arguments.items[arguments.start].value);
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
    visitInstructionReferences(tableView(function), instruction, &uses, StorageUses.reference);
    return uses.found;
}

pub fn scalar(type_id: structures.TypeId) bool {
    return type_id == .int or type_id == .bool or type_id == .byte;
}

pub fn visitInstructionReferences(tables: anytype, instruction: *const Instruction, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (instruction.operands()) |operand| if (operand) |value| visit(context, value.*);
    switch (instruction.*) {
        .call => |call| visitCallArguments(tables, call, context, visit),
        .initializer_ref => |reference| for (tables.initializer_captures[reference.captures.start..reference.captures.end]) |capture| visit(context, capture),
        .aggregate => |aggregate| for (tables.aggregate_fields[aggregate.fields.start..aggregate.fields.end]) |field| visit(context, field),
        else => {},
    }
}

pub fn allOperands(function: *Function, instruction: *Instruction, context: anytype, comptime visit: fn (@TypeOf(context), *ValueId) void) void {
    for (instruction.operands()) |operand| if (operand) |value| visit(context, value);
    switch (instruction.*) {
        .call => |call| for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |*argument| visit(context, argument.operand()),
        .initializer_ref => |reference| for (function.initializer_captures.items[reference.captures.start..reference.captures.end]) |*capture| visit(context, capture),
        .aggregate => |aggregate| for (function.aggregate_fields.items[aggregate.fields.start..aggregate.fields.end]) |*field| visit(context, field),
        else => {},
    }
}

pub fn terminatorAllOperands(function: *Function, terminator: *Terminator, context: anytype, comptime visit: fn (@TypeOf(context), *ValueId) void) void {
    for (terminator.operands()) |operand| if (operand) |value| visit(context, value);
    for (terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
        for (function.branchArguments(branch.*)) |*argument| visit(context, &argument.value);
    };
}

pub fn readOperands(function: *Function, instruction: *Instruction, context: anytype, comptime visit: fn (@TypeOf(context), *ValueId) void) void {
    switch (instruction.*) {
        .addi, .subi, .muli, .divsi => |*operands| {
            visit(context, &operands.lhs);
            visit(context, &operands.rhs);
        },
        .compare => |*operation| {
            visit(context, &operation.operands.lhs);
            visit(context, &operation.operands.rhs);
        },
        .select => |*operation| {
            visit(context, &operation.condition);
            visit(context, &operation.then_value);
            visit(context, &operation.else_value);
        },
        .negi, .byte_to_int, .variant_tag => |*operand| visit(context, operand),
        .value_copy => |*operation| visit(context, &operation.source),
        inline .variant_coerce, .variant_extract => |*operation| visit(context, &operation.operand),
        .field_access => |*operation| visit(context, &operation.operand),
        .allocation_element => |*operation| {
            visit(context, &operation.allocation);
            visit(context, &operation.index);
        },
        .array_element => |*operation| visit(context, &operation.index),
        .cursor_offset, .cursor_element => |*operation| {
            visit(context, &operation.cursor);
            visit(context, &operation.index);
        },
        .borrow_read, .borrow_box => |*operation| visit(context, &operation.source),
        .borrow_address => |*operation| if (operation.base_is_reference) visit(context, &operation.source),
        .borrow_write => |*operation| {
            visit(context, &operation.reference);
            visit(context, &operation.value);
        },
        .initializer_capture_write => |*operation| visit(context, &operation.value),
        .fill => |*operation| {
            visit(context, &operation.count);
            visit(context, &operation.value);
        },
        .move => |*operation| visit(context, &operation.count),
        .aggregate => |aggregate| for (function.aggregate_fields.items[aggregate.fields.start..aggregate.fields.end]) |*field| visit(context, field),
        .call => |*call| callReadOperands(function, call, context, visit),
        else => {},
    }
}

fn callReadOperands(function: *Function, call: *structures.FunctionCall, context: anytype, comptime visit: fn (@TypeOf(context), *ValueId) void) void {
    if (call.target == .indirect) visit(context, &call.target.indirect);
    for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |*argument| {
        if (argument.* == .prepared) visit(context, &argument.prepared.value);
    }
}

pub fn terminatorReadOperands(function: *Function, terminator: *Terminator, context: anytype, comptime visit: fn (@TypeOf(context), *ValueId) void) void {
    switch (terminator.*) {
        .predicate_branch => |*predicate| {
            visit(context, &predicate.operands.lhs);
            visit(context, &predicate.operands.rhs);
        },
        .return_value => |*use| visit(context, &use.value),
        .branch, .return_unit, .diverge => {},
    }
    for (terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
        const all_arguments = function.branchArguments(branch.*);
        const all_parameters = function.blocks.items[@backingInt(branch.target)].parameters.items;
        const count = @min(all_arguments.len, all_parameters.len);
        for (all_arguments[0..count], all_parameters[0..count]) |*argument, parameter| {
            const data = function.definitions.items[@backingInt(parameter)].argument.data;
            if (data.representation == .value and function.direct(data.type_id)) visit(context, &argument.value);
        }
    };
}

pub fn visitReads(tables: anytype, instruction: *const Instruction, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    switch (instruction.*) {
        .addi, .subi, .muli, .divsi => |operands| {
            visit(context, operands.lhs);
            visit(context, operands.rhs);
        },
        .compare => |operation| {
            visit(context, operation.operands.lhs);
            visit(context, operation.operands.rhs);
        },
        .select => |operation| {
            visit(context, operation.condition);
            visit(context, operation.then_value);
            visit(context, operation.else_value);
        },
        .negi, .byte_to_int, .variant_tag => |operand| visit(context, operand),
        .value_copy => |operation| visit(context, operation.source),
        inline .variant_coerce, .variant_extract => |operation| visit(context, operation.operand),
        .field_access => |operation| visit(context, operation.operand),
        .allocation_element => |operation| {
            visit(context, operation.allocation);
            visit(context, operation.index);
        },
        .array_element => |operation| visit(context, operation.index),
        .cursor_offset, .cursor_element => |operation| {
            visit(context, operation.cursor);
            visit(context, operation.index);
        },
        .borrow_read, .borrow_box => |operation| visit(context, operation.source),
        .borrow_address => |operation| if (operation.base_is_reference) visit(context, operation.source),
        .borrow_write => |operation| {
            visit(context, operation.reference);
            visit(context, operation.value);
        },
        .initializer_capture_write => |operation| visit(context, operation.value),
        .fill => |operation| {
            visit(context, operation.count);
            visit(context, operation.value);
        },
        .move => |operation| visit(context, operation.count),
        .aggregate => |aggregate| for (tables.aggregate_fields[aggregate.fields.start..aggregate.fields.end]) |field| visit(context, field),
        .call => |call| visitCallReads(tables, call, context, visit),
        else => {},
    }
}

pub fn visitCallReads(tables: anytype, call: structures.FunctionCall, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    if (call.target == .indirect) visit(context, call.target.indirect);
    for (tables.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
        if (argument == .prepared) visit(context, argument.prepared.value);
    }
}

pub fn visitTerminatorOperands(_: anytype, terminator: *const Terminator, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (terminator.operands()) |operand| if (operand) |value| visit(context, value.*);
}

pub fn visitTerminatorReferences(tables: anytype, terminator: *const Terminator, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    visitTerminatorOperands(tables, terminator, context, visit);
    switch (terminator.*) {
        .branch => |branch| visitBranchArguments(tables, branch, context, visit),
        .predicate_branch => |predicate| {
            visitBranchArguments(tables, predicate.then_branch, context, visit);
            visitBranchArguments(tables, predicate.else_branch, context, visit);
        },
        .return_unit, .return_value, .diverge => {},
    }
}

fn visitCallArguments(tables: anytype, call: structures.FunctionCall, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (tables.call_arguments[call.arguments.start..call.arguments.end]) |argument| visit(context, argument.valueId());
}

fn visitBranchArguments(tables: anytype, branch: structures.FunctionBranch, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (tables.branch_arguments[branch.arguments.start..branch.arguments.end]) |argument| visit(context, argument.value);
}

pub const TableView = struct {
    call_arguments: []const structures.FunctionCallArgument,
    branch_arguments: []const structures.FunctionValueUse,
    initializer_captures: []const ValueId,
    aggregate_fields: []const ValueId,
};

pub fn tableView(function: *const Function) TableView {
    return .{
        .call_arguments = function.call_arguments.items,
        .branch_arguments = function.branch_arguments.items,
        .initializer_captures = function.initializer_captures.items,
        .aggregate_fields = function.aggregate_fields.items,
    };
}
