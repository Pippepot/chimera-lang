const std = @import("std");
const structures = @import("../structures.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const BlockId = structures.FunctionBlockId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;

pub const Definition = union(enum) {
    argument: struct { block: u32, data: structures.FunctionBlockArgument },
    instruction: u32,
};

pub const Block = struct {
    parameters: std.ArrayList(ValueId),
    instructions: std.ArrayList(u32),
    terminator: Terminator,
    layout: u32,
};

pub const Edge = union(enum) {
    branch: *structures.FunctionBranch,
    fallible: BlockId,
};

pub const Function = struct {
    scratch: std.mem.Allocator,
    body: *const Body,
    definitions: std.ArrayList(Definition) = .empty,
    replacement: std.ArrayList(ValueId) = .empty,
    instructions: std.ArrayList(Instruction) = .empty,
    results: std.ArrayList(ValueId) = .empty,
    removed: std.ArrayList(bool) = .empty,
    spans: std.ArrayList(structures.SourceSpan) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
    branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
    initializer_captures: std.ArrayList(ValueId) = .empty,

    pub fn init(scratch: std.mem.Allocator, body: *const Body) !Function {
        var function: Function = .{ .scratch = scratch, .body = body };
        try function.blocks.ensureTotalCapacity(scratch, body.blocks.len);
        for (body.blocks) |block| function.blocks.appendAssumeCapacity(.{
            .parameters = .empty,
            .instructions = .empty,
            .terminator = block.terminator,
            .layout = block.instruction_start,
        });
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
        for (body.instructions, 0..) |_, index| {
            function.definitions.appendAssumeCapacity(.{ .instruction = @intCast(index) });
            function.replacement.appendAssumeCapacity(@fromBackingInt(@intCast(function.replacement.items.len)));
            try function.results.append(scratch, body.instructionValue(index));
        }
        try function.call_arguments.appendSlice(scratch, body.call_arguments);
        try function.branch_arguments.appendSlice(scratch, body.branch_arguments);
        try function.initializer_captures.appendSlice(scratch, body.initializer_captures);
        return function;
    }

    pub fn publishesSpans(self: *const Function) bool {
        return self.body.terminator_spans.len != 0;
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

    pub fn valueType(self: *const Function, value: ValueId) structures.TypeId {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => |argument| argument.data.type_id,
            .instruction => |index| self.instructions.items[index].resultType(),
        };
    }

    pub fn plainValue(self: *const Function, value: ValueId) bool {
        return switch (self.definitions.items[@backingInt(value)]) {
            .argument => |argument| argument.data.representation == .value,
            .instruction => |index| switch (self.instructions.items[index]) {
                .const_int, .const_bool, .const_byte, .addi, .subi, .muli, .divsi, .negi, .byte_to_int, .variant_tag => true,
                inline .value_copy, .call => |operation| operation.destination == null,
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
    }

    pub fn insertInstruction(self: *Function, block: u32, position: usize, instruction: Instruction, span: structures.SourceSpan) !ValueId {
        const index: u32 = @intCast(self.instructions.items.len);
        const value: ValueId = @fromBackingInt(@intCast(self.definitions.items.len));
        try self.instructions.append(self.scratch, instruction);
        try self.removed.append(self.scratch, false);
        if (self.publishesSpans()) try self.spans.append(self.scratch, span);
        try self.results.append(self.scratch, value);
        try self.definitions.append(self.scratch, .{ .instruction = index });
        try self.replacement.append(self.scratch, value);
        try self.blocks.items[block].instructions.insert(self.scratch, position, index);
        return value;
    }

    pub fn addParameter(self: *Function, block: u32, argument: structures.FunctionBlockArgument) !ValueId {
        const value: ValueId = @fromBackingInt(@intCast(self.definitions.items.len));
        try self.definitions.append(self.scratch, .{ .argument = .{ .block = block, .data = argument } });
        try self.replacement.append(self.scratch, value);
        try self.blocks.items[block].parameters.append(self.scratch, value);
        return value;
    }

    pub fn appendBranchArgument(self: *Function, branch: *structures.FunctionBranch, value: ValueId) !void {
        const start: u32 = @intCast(self.branch_arguments.items.len);
        try self.branch_arguments.ensureUnusedCapacity(self.scratch, branch.arguments.end - branch.arguments.start + 1);
        for (branch.arguments.start..branch.arguments.end) |index| self.branch_arguments.appendAssumeCapacity(self.branch_arguments.items[index]);
        self.branch_arguments.appendAssumeCapacity(.{ .value = value });
        branch.arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
    }

    pub fn edges(terminator: *Terminator) [2]?Edge {
        return switch (terminator.*) {
            .branch => |*branch| .{ .{ .branch = branch }, null },
            .predicate_branch => |*predicate| .{ .{ .branch = &predicate.then_branch }, .{ .branch = &predicate.else_branch } },
            .fallible_call => |fallible| .{ .{ .fallible = fallible.success }, if (fallible.failure) |failure| .{ .fallible = failure } else null },
            .return_unit, .return_value, .return_failure, .diverge => .{ null, null },
        };
    }

    pub fn edgeTarget(edge: Edge) BlockId {
        return switch (edge) {
            .branch => |branch| branch.target,
            .fallible => |target| target,
        };
    }

    pub fn resolveReferences(self: *Function) void {
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
    }
};

pub fn visitInstructionReferences(tables: anytype, instruction: *const Instruction, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (instruction.operands()) |operand| if (operand) |value| visit(context, value.*);
    switch (instruction.*) {
        .call => |call| visitCallArguments(tables, call, context, visit),
        .initializer_ref => |reference| for (tables.initializer_captures[reference.captures.start..reference.captures.end]) |capture| visit(context, capture),
        else => {},
    }
}

pub fn visitTerminatorOperands(tables: anytype, terminator: *const Terminator, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (terminator.operands()) |operand| if (operand) |value| visit(context, value.*);
    if (terminator.* == .fallible_call) visitCallArguments(tables, terminator.fallible_call.call, context, visit);
}

pub fn visitTerminatorReferences(tables: anytype, terminator: *const Terminator, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    visitTerminatorOperands(tables, terminator, context, visit);
    switch (terminator.*) {
        .branch => |branch| visitBranchArguments(tables, branch, context, visit),
        .predicate_branch => |predicate| {
            visitBranchArguments(tables, predicate.then_branch, context, visit);
            visitBranchArguments(tables, predicate.else_branch, context, visit);
        },
        .fallible_call, .return_unit, .return_value, .return_failure, .diverge => {},
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
};

pub fn tableView(function: *const Function) TableView {
    return .{
        .call_arguments = function.call_arguments.items,
        .branch_arguments = function.branch_arguments.items,
        .initializer_captures = function.initializer_captures.items,
    };
}
