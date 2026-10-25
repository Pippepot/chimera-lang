const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;

pub fn verify(body: *const Body) void {
    std.debug.assert(@backingInt(body.entry) < body.blocks.len);
    std.debug.assert(body.instruction_spans.len == 0 or body.instruction_spans.len == body.instructions.len);
    std.debug.assert(body.terminator_spans.len == 0 or body.terminator_spans.len == body.blocks.len);
    if (body.inline_frames.len != 0) {
        std.debug.assert(body.instruction_frames.len == body.instruction_spans.len);
        std.debug.assert(body.terminator_frames.len == body.terminator_spans.len);
        for (body.instruction_frames) |frame| checkFrame(body, frame);
        for (body.terminator_frames) |frame| checkFrame(body, frame);
        for (body.inline_frames, 0..) |frame, index| if (frame.parent != .root) std.debug.assert(@backingInt(frame.parent) < index);
    }
    var instruction_count: usize = 0;
    for (body.blocks) |block| {
        std.debug.assert(block.argument_start <= block.argument_end);
        std.debug.assert(block.argument_end <= body.block_arguments.len);
        std.debug.assert(block.instruction_start <= block.instruction_end);
        std.debug.assert(block.instruction_end <= body.instructions.len);
        instruction_count += block.instruction_end - block.instruction_start;
        function_ir.visitTerminatorReferences(body, &block.terminator, body, checkValue);
        verifyTargets(body, block.terminator);
    }
    std.debug.assert(instruction_count == body.instructions.len);
    for (body.instructions) |*instruction| function_ir.visitInstructionReferences(body, instruction, body, checkValue);
    for (body.initializer_regions) |*region| verify(region);
}

fn checkFrame(body: *const Body, frame: structures.InlineFrameId) void {
    if (frame != .root) std.debug.assert(@backingInt(frame) < body.inline_frames.len);
}

fn checkValue(body: *const Body, value: ValueId) void {
    std.debug.assert(@backingInt(value) < body.valueCount());
}

fn verifyTargets(body: *const Body, terminator: structures.FunctionTerminator) void {
    switch (terminator) {
        .branch => |branch| verifyBranch(body, branch),
        .predicate_branch => |predicate| {
            verifyBranch(body, predicate.then_branch);
            verifyBranch(body, predicate.else_branch);
        },
        .return_unit, .return_value, .diverge => {},
    }
}

fn verifyBranch(body: *const Body, branch: structures.FunctionBranch) void {
    std.debug.assert(@backingInt(branch.target) < body.blocks.len);
    const target = body.blocks[@backingInt(branch.target)];
    std.debug.assert(branch.arguments.end - branch.arguments.start == target.argument_end - target.argument_start);
}

const Function = function_ir.Function;

const FunctionCheck = struct {
    function: *const Function,
    defined: []const bool,

    fn check(self: *const FunctionCheck, value: ValueId) void {
        std.debug.assert(@backingInt(value) < self.function.valueCount());
        std.debug.assert(self.defined[@backingInt(self.function.find(value))]);
    }
};

pub fn verifyFunction(function: *Function) !void {
    const scratch = function.scratch;
    const reachable = (try function.controlFlowEdges()).reachable;
    const defined = try scratch.alloc(bool, function.valueCount());
    @memset(defined, false);
    for (function.blocks.items, reachable) |block, kept| {
        if (!kept) continue;
        for (block.parameters.items) |parameter| defined[@backingInt(parameter)] = true;
        for (block.instructions.items) |index| if (!function.removed.items[index]) {
            defined[@backingInt(function.results.items[index])] = true;
        };
    }
    const tables = function_ir.tableView(function);
    const context: FunctionCheck = .{ .function = function, .defined = defined };
    for (function.blocks.items, reachable) |*block, kept| {
        if (!kept) continue;
        for (block.instructions.items) |instruction| if (!function.removed.items[instruction]) {
            function_ir.visitInstructionReferences(tables, &function.instructions.items[instruction], &context, FunctionCheck.check);
        };
        function_ir.visitTerminatorReferences(tables, &block.terminator, &context, FunctionCheck.check);
        for (block.terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
            std.debug.assert(branch.arguments.end - branch.arguments.start == function.blocks.items[@backingInt(branch.target)].parameters.items.len);
        };
    }
}
