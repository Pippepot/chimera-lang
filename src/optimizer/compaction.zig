const std = @import("std");
const structures = @import("../structures.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const BlockId = structures.FunctionBlockId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const View = structures.FunctionBodyFinalization;

pub fn compact(scratch: std.mem.Allocator, body: *const Body, view: View, regions: []const Body) !Body {
    const reachable = try reachableBlocks(scratch, body, view);
    const block_of = try instructionBlocks(scratch, body);
    const live = try liveValues(scratch, body, view, reachable, block_of);

    const block_map = try scratch.alloc(?u32, body.blocks.len);
    var block_count: u32 = 0;
    for (block_map, reachable) |*mapped, kept| {
        mapped.* = if (kept) block_count else null;
        if (kept) block_count += 1;
    }

    const value_map = try scratch.alloc(?u32, body.valueCount());
    @memset(value_map, null);
    var block_arguments: std.ArrayList(structures.FunctionBlockArgument) = .empty;
    const argument_starts = try scratch.alloc(u32, body.blocks.len);
    for (body.blocks, reachable, argument_starts) |block, kept, *start| {
        start.* = @intCast(block_arguments.items.len);
        if (!kept) continue;
        for (block.argument_start..block.argument_end) |index| {
            value_map[index] = @intCast(block_arguments.items.len);
            try block_arguments.append(scratch, body.block_arguments[index]);
        }
    }
    const argument_count: u32 = @intCast(block_arguments.items.len);

    const kept_before = try scratch.alloc(u32, body.instructions.len + 1);
    var instructions: std.ArrayList(Instruction) = .empty;
    var instruction_spans: std.ArrayList(structures.SourceSpan) = .empty;
    const has_instruction_spans = body.instruction_spans.len == body.instructions.len and body.instructions.len != 0;
    for (body.instructions, 0..) |_, index| {
        kept_before[index] = @intCast(instructions.items.len);
        if (!reachable[block_of[index]] or !live[body.block_arguments.len + index]) continue;
        value_map[body.block_arguments.len + index] = argument_count + @as(u32, @intCast(instructions.items.len));
        try instructions.append(scratch, view.instructions[index]);
        if (has_instruction_spans) try instruction_spans.append(scratch, body.instruction_spans[index]);
    }
    kept_before[body.instructions.len] = @intCast(instructions.items.len);

    var tables: Tables = .{};
    for (instructions.items) |*instruction| try tables.relocateInstruction(scratch, view, instruction);

    var blocks: std.ArrayList(structures.FunctionBlock) = .empty;
    var terminator_spans: std.ArrayList(structures.SourceSpan) = .empty;
    const has_terminator_spans = body.terminator_spans.len == body.blocks.len and body.blocks.len != 0;
    for (body.blocks, view.blocks, reachable, 0..) |original, current, kept, index| {
        if (!kept) continue;
        var terminator = current.terminator;
        try tables.relocateTerminator(scratch, view, &terminator);
        remapTargets(&terminator, block_map);
        try blocks.append(scratch, .{
            .argument_start = argument_starts[index],
            .argument_end = argument_starts[index] + (original.argument_end - original.argument_start),
            .instruction_start = kept_before[original.instruction_start],
            .instruction_end = kept_before[original.instruction_end],
            .terminator = terminator,
        });
        if (has_terminator_spans) try terminator_spans.append(scratch, body.terminator_spans[index]);
    }

    const result_view: View = .{
        .instructions = instructions.items,
        .blocks = blocks.items,
        .call_arguments = tables.call_arguments.items,
        .branch_arguments = tables.branch_arguments.items,
        .initializer_captures = tables.initializer_captures.items,
    };
    result_view.visitValueReferences(value_map, remapValue);
    for (instructions.items) |*instruction| if (instruction.* == .initializer_capture_write) {
        const write = &instruction.initializer_capture_write;
        write.parameter_index = value_map[write.parameter_index].?;
    };

    return .{
        .return_type = body.return_type,
        .is_fallible = body.is_fallible,
        .is_initializer_region = body.is_initializer_region,
        .initializer_regions = regions,
        .initializer_captures = tables.initializer_captures.items,
        .parameter_modes = body.parameter_modes,
        .block_arguments = block_arguments.items,
        .variant_coercion_tags = body.variant_coercion_tags,
        .borrow_fields = body.borrow_fields,
        .branch_arguments = tables.branch_arguments.items,
        .call_arguments = tables.call_arguments.items,
        .instructions = instructions.items,
        .instruction_spans = if (has_instruction_spans) instruction_spans.items else body.instruction_spans[0..0],
        .terminator_spans = if (has_terminator_spans) terminator_spans.items else body.terminator_spans[0..0],
        .blocks = blocks.items,
        .entry = @fromBackingInt(block_map[@backingInt(body.entry)].?),
    };
}

const Tables = struct {
    call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
    branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
    initializer_captures: std.ArrayList(ValueId) = .empty,

    fn relocateInstruction(self: *Tables, scratch: std.mem.Allocator, view: View, instruction: *Instruction) !void {
        switch (instruction.*) {
            .call => |*call| try self.relocateCall(scratch, view, call),
            .initializer_ref => |*reference| reference.captures = try relocate(ValueId, scratch, &self.initializer_captures, view.initializer_captures, reference.captures),
            else => {},
        }
    }

    fn relocateTerminator(self: *Tables, scratch: std.mem.Allocator, view: View, terminator: *Terminator) !void {
        switch (terminator.*) {
            .branch => |*branch| try self.relocateBranch(scratch, view, branch),
            .predicate_branch => |*predicate| {
                try self.relocateBranch(scratch, view, &predicate.then_branch);
                try self.relocateBranch(scratch, view, &predicate.else_branch);
            },
            .fallible_call => |*fallible| try self.relocateCall(scratch, view, &fallible.call),
            .return_unit, .return_value, .return_failure, .diverge => {},
        }
    }

    fn relocateCall(self: *Tables, scratch: std.mem.Allocator, view: View, call: *structures.FunctionCall) !void {
        call.arguments = try relocate(structures.FunctionCallArgument, scratch, &self.call_arguments, view.call_arguments, call.arguments);
    }

    fn relocateBranch(self: *Tables, scratch: std.mem.Allocator, view: View, branch: *structures.FunctionBranch) !void {
        branch.arguments = try relocate(structures.FunctionValueUse, scratch, &self.branch_arguments, view.branch_arguments, branch.arguments);
    }
};

fn relocate(comptime T: type, scratch: std.mem.Allocator, table: *std.ArrayList(T), source: []const T, range: structures.FunctionValueRange) !structures.FunctionValueRange {
    const start: u32 = @intCast(table.items.len);
    try table.appendSlice(scratch, source[range.start..range.end]);
    return .{ .start = start, .end = @intCast(table.items.len) };
}

fn remapTargets(terminator: *Terminator, block_map: []const ?u32) void {
    switch (terminator.*) {
        .branch => |*branch| remapBlock(&branch.target, block_map),
        .predicate_branch => |*predicate| {
            remapBlock(&predicate.then_branch.target, block_map);
            remapBlock(&predicate.else_branch.target, block_map);
        },
        .fallible_call => |*fallible| {
            remapBlock(&fallible.success, block_map);
            if (fallible.failure) |*failure| remapBlock(failure, block_map);
        },
        .return_unit, .return_value, .return_failure, .diverge => {},
    }
}

fn remapBlock(block: *BlockId, block_map: []const ?u32) void {
    block.* = @fromBackingInt(block_map[@backingInt(block.*)].?);
}

fn remapValue(value_map: []const ?u32, value: *ValueId) void {
    value.* = @fromBackingInt(value_map[@backingInt(value.*)].?);
}

fn reachableBlocks(scratch: std.mem.Allocator, body: *const Body, view: View) ![]const bool {
    const reachable = try scratch.alloc(bool, body.blocks.len);
    @memset(reachable, false);
    var pending: std.ArrayList(BlockId) = .empty;
    try pending.append(scratch, body.entry);
    reachable[@backingInt(body.entry)] = true;
    while (pending.pop()) |block| {
        var successors: [2]?BlockId = .{ null, null };
        switch (view.blocks[@backingInt(block)].terminator) {
            .branch => |branch| successors[0] = branch.target,
            .predicate_branch => |predicate| successors = .{ predicate.then_branch.target, predicate.else_branch.target },
            .fallible_call => |fallible| successors = .{ fallible.success, fallible.failure },
            .return_unit, .return_value, .return_failure, .diverge => {},
        }
        for (successors) |successor| if (successor) |target| if (!reachable[@backingInt(target)]) {
            reachable[@backingInt(target)] = true;
            try pending.append(scratch, target);
        };
    }
    return reachable;
}

fn instructionBlocks(scratch: std.mem.Allocator, body: *const Body) ![]const u32 {
    const block_of = try scratch.alloc(u32, body.instructions.len);
    for (body.blocks, 0..) |block, index| @memset(block_of[block.instruction_start..block.instruction_end], @intCast(index));
    return block_of;
}

const Liveness = struct {
    live: []bool,
    pending: std.ArrayList(u32) = .empty,
    argument_count: usize,
    scratch: std.mem.Allocator,
    failed: ?std.mem.Allocator.Error = null,

    fn mark(self: *Liveness, value: ValueId) void {
        const index = @backingInt(value);
        if (self.live[index]) return;
        self.live[index] = true;
        if (index < self.argument_count) return;
        self.pending.append(self.scratch, @intCast(index - self.argument_count)) catch |err| {
            self.failed = err;
        };
    }
};

fn liveValues(scratch: std.mem.Allocator, body: *const Body, view: View, reachable: []const bool, block_of: []const u32) ![]const bool {
    var liveness: Liveness = .{ .live = try scratch.alloc(bool, body.valueCount()), .argument_count = body.block_arguments.len, .scratch = scratch };
    @memset(liveness.live, false);
    for (view.instructions, 0..) |instruction, index| {
        if (reachable[block_of[index]] and !removableWhenUnused(view, body.block_arguments.len, instruction))
            liveness.mark(body.instructionValue(index));
    }
    for (view.blocks, reachable) |*block, kept| {
        if (!kept) continue;
        visitTerminatorReferences(view, &block.terminator, &liveness, Liveness.mark);
    }
    while (liveness.pending.pop()) |index| visitInstructionReferences(view, &view.instructions[index], &liveness, Liveness.mark);
    if (liveness.failed) |err| return err;
    return liveness.live;
}

pub fn visitInstructionReferences(view: anytype, instruction: *const Instruction, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (instruction.operands()) |operand| if (operand) |value| visit(context, value.*);
    switch (instruction.*) {
        .call => |call| visitCallArguments(view, call, context, visit),
        .initializer_ref => |reference| for (view.initializer_captures[reference.captures.start..reference.captures.end]) |capture| visit(context, capture),
        else => {},
    }
}

pub fn visitTerminatorReferences(view: anytype, terminator: *const Terminator, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (terminator.operands()) |operand| if (operand) |value| visit(context, value.*);
    switch (terminator.*) {
        .branch => |branch| visitBranchArguments(view, branch, context, visit),
        .predicate_branch => |predicate| {
            visitBranchArguments(view, predicate.then_branch, context, visit);
            visitBranchArguments(view, predicate.else_branch, context, visit);
        },
        .fallible_call => |fallible| visitCallArguments(view, fallible.call, context, visit),
        .return_unit, .return_value, .return_failure, .diverge => {},
    }
}

fn visitCallArguments(view: anytype, call: structures.FunctionCall, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (view.call_arguments[call.arguments.start..call.arguments.end]) |argument| visit(context, argument.valueId());
}

fn visitBranchArguments(view: anytype, branch: structures.FunctionBranch, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
    for (view.branch_arguments[branch.arguments.start..branch.arguments.end]) |argument| visit(context, argument.value);
}

fn removableWhenUnused(view: View, argument_count: usize, instruction: Instruction) bool {
    return switch (instruction) {
        .const_int, .const_int_literal, .const_string_literal, .const_static_string, .const_storage_cursor, .const_byte, .const_bool, .const_type, .const_unit, .const_none, .function_ref, .addi, .subi, .muli, .negi, .byte_to_int => true,
        .divsi => |operands| nonzeroConstant(view, argument_count, operands.rhs),
        else => false,
    };
}

fn nonzeroConstant(view: View, argument_count: usize, value: ValueId) bool {
    const index = @backingInt(value);
    if (index < argument_count) return false;
    return switch (view.instructions[index - argument_count]) {
        .const_int => |integer| integer != 0,
        else => false,
    };
}
