const std = @import("std");
const structures = @import("../structures.zig");
const compaction = @import("compaction.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;

pub fn verify(body: *const Body) void {
    std.debug.assert(@backingInt(body.entry) < body.blocks.len);
    std.debug.assert(body.instruction_spans.len == 0 or body.instruction_spans.len == body.instructions.len);
    std.debug.assert(body.terminator_spans.len == 0 or body.terminator_spans.len == body.blocks.len);
    var instruction_count: usize = 0;
    for (body.blocks) |block| {
        std.debug.assert(block.argument_start <= block.argument_end);
        std.debug.assert(block.argument_end <= body.block_arguments.len);
        std.debug.assert(block.instruction_start <= block.instruction_end);
        std.debug.assert(block.instruction_end <= body.instructions.len);
        instruction_count += block.instruction_end - block.instruction_start;
        compaction.visitTerminatorReferences(body, &block.terminator, body, checkValue);
        verifyTargets(body, block.terminator);
    }
    std.debug.assert(instruction_count == body.instructions.len);
    for (body.instructions) |*instruction| compaction.visitInstructionReferences(body, instruction, body, checkValue);
    for (body.initializer_regions) |*region| verify(region);
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
        .fallible_call => |fallible| {
            std.debug.assert(@backingInt(fallible.success) < body.blocks.len);
            if (fallible.failure) |failure| std.debug.assert(@backingInt(failure) < body.blocks.len);
        },
        .return_unit, .return_value, .return_failure, .diverge => {},
    }
}

fn verifyBranch(body: *const Body, branch: structures.FunctionBranch) void {
    std.debug.assert(@backingInt(branch.target) < body.blocks.len);
    const target = body.blocks[@backingInt(branch.target)];
    std.debug.assert(branch.arguments.end - branch.arguments.start == target.argument_end - target.argument_start);
}
