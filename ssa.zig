const std = @import("std");
const structures = @import("structures.zig");

pub fn lowerFunction(body: structures.FunctionBodyAnalysis, gpa: std.mem.Allocator) !structures.SsaFunction {
    const block_argument_types = try gpa.dupe(structures.Type, body.block_argument_types);
    errdefer gpa.free(block_argument_types);
    const call_arguments = try gpa.dupe(structures.FunctionValueId, body.call_arguments);
    errdefer gpa.free(call_arguments);
    const instructions = try gpa.alloc(structures.SsaFunction.Instruction, body.instructions.len);
    errdefer gpa.free(instructions);
    for (body.instructions, instructions) |instruction, *lowered| {
        lowered.* = switch (instruction) {
            .consti => |value| .{ .consti = value },
            .call => |call| .{ .call = .{
                .target = .{ .item = call.target },
                .arguments = call.arguments,
                .return_type = call.return_type,
            } },
            .negi => |operand| .{ .negi = operand },
            .addi => |operands| .{ .addi = operands },
            .subi => |operands| .{ .subi = operands },
            .muli => |operands| .{ .muli = operands },
            .divsi => |operands| .{ .divsi = operands },
        };
    }

    const blocks = try gpa.alloc(structures.SsaFunction.Block, body.blocks.len);
    @memcpy(blocks, body.blocks);
    return .{
        .block_argument_types = block_argument_types,
        .call_arguments = call_arguments,
        .instructions = instructions,
        .blocks = blocks,
        .entry = body.entry,
    };
}

fn functionBody(
    instructions: []structures.FunctionBodyAnalysis.Instruction,
    blocks: []structures.FunctionBodyAnalysis.Block,
) structures.FunctionBodyAnalysis {
    return .{
        .block_argument_types = &.{},
        .call_arguments = &.{},
        .instructions = instructions,
        .blocks = blocks,
        .entry = @enumFromInt(0),
    };
}

test "literal return lowers to owned function SSA" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .consti = 7 }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = @enumFromInt(0) },
    }};
    var lowered = try lowerFunction(functionBody(&instructions, &blocks), std.testing.allocator);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), lowered.instructions.len);
    try std.testing.expectEqual(@as(i32, 7), lowered.instructions[0].consti);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(lowered.blocks[0].terminator.return_value));
}

test "unit lowers to an explicit empty block" {
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 0,
        .terminator = .return_unit,
    }};
    var lowered = try lowerFunction(functionBody(&.{}, &blocks), std.testing.allocator);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), lowered.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), lowered.blocks.len);
    try std.testing.expectEqual(structures.SsaFunction.Terminator.return_unit, lowered.blocks[0].terminator);
}

test "typed expression operations preserve their value graph" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{
        .{ .consti = 7 },
        .{ .negi = @enumFromInt(0) },
        .{ .addi = .{
            .lhs = @enumFromInt(0),
            .rhs = @enumFromInt(1),
        } },
    };
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = instructions.len,
        .terminator = .{ .return_value = @enumFromInt(2) },
    }};
    var lowered = try lowerFunction(functionBody(&instructions, &blocks), std.testing.allocator);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(lowered.instructions[1].negi));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(lowered.instructions[2].addi.lhs));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(lowered.instructions[2].addi.rhs));
}

test "function SSA allocation failure leaves no partial result" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .consti = 7 }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = @enumFromInt(0) },
    }};
    const body = functionBody(&instructions, &blocks);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lowerFunction(body, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "direct call lowers to owned value-equal symbolic SSA" {
    const target: structures.ItemId = @enumFromInt(7);
    var block_argument_types = [_]structures.Type{ .int, .int };
    var call_arguments = [_]structures.FunctionValueId{ @enumFromInt(0), @enumFromInt(1) };
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .call = .{
        .target = target,
        .arguments = .{ .start = 0, .end = 2 },
        .return_type = .int,
    } }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .argument_end = 2,
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const body: structures.FunctionBodyAnalysis = .{
        .block_argument_types = &block_argument_types,
        .call_arguments = &call_arguments,
        .instructions = &instructions,
        .blocks = &blocks,
        .entry = @enumFromInt(0),
    };
    var first = try lowerFunction(body, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try lowerFunction(body, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.instructions.ptr != second.instructions.ptr);
    try std.testing.expect(first.call_arguments.ptr != second.call_arguments.ptr);
    try std.testing.expect(structures.SsaFunction.eql(first, second));
    try std.testing.expectEqualSlices(structures.Type, &.{ .int, .int }, first.block_argument_types);
    try std.testing.expectEqualSlices(structures.FunctionValueId, &call_arguments, first.call_arguments);
    try std.testing.expectEqual(@as(usize, 1), first.instructions.len);
    try std.testing.expectEqual(structures.InstanceId{ .item = target }, first.instructions[0].call.target);
    try std.testing.expectEqual(structures.SsaFunction.Terminator.return_unit, first.blocks[0].terminator);
}

test "direct call SSA allocation failure leaves no partial result" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .call = .{
        .target = @enumFromInt(0),
        .arguments = .{ .start = 0, .end = 0 },
        .return_type = .int,
    } }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const body = functionBody(&instructions, &blocks);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lowerFunction(body, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
