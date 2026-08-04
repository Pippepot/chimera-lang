const std = @import("std");
const structures = @import("structures.zig");

pub fn lowerFunction(body: structures.FunctionBodyAnalysis, gpa: std.mem.Allocator) !structures.SsaFunction {
    std.debug.assert(body.blocks.len != 0);
    std.debug.assert(@intFromEnum(body.entry) < body.blocks.len);

    const instructions = try gpa.alloc(structures.SsaFunction.Instruction, body.instructions.len);
    errdefer gpa.free(instructions);
    for (body.instructions, instructions) |instruction, *lowered| {
        lowered.* = switch (instruction) {
            .integer_constant => |value| .{ .integer_constant = value },
            .call => |target| .{ .direct_call = .{ .item = target } },
        };
    }

    const blocks = try gpa.alloc(structures.SsaFunction.Block, body.blocks.len);
    for (body.blocks, blocks) |block, *lowered| {
        std.debug.assert(block.instruction_start <= block.instruction_end);
        std.debug.assert(block.instruction_end <= body.instructions.len);
        lowered.* = .{
            .instruction_start = block.instruction_start,
            .instruction_end = block.instruction_end,
            .terminator = switch (block.terminator) {
                .return_unit => .return_unit,
                .return_value => |value| .{ .return_value = @enumFromInt(@intFromEnum(value)) },
            },
        };
    }
    return .{ .instructions = instructions, .blocks = blocks, .entry = @enumFromInt(@intFromEnum(body.entry)) };
}

test "literal return lowers to owned function SSA" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .integer_constant = 7 }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = @enumFromInt(0) },
    }};
    var lowered = try lowerFunction(.{ .instructions = &instructions, .blocks = &blocks, .entry = @enumFromInt(0) }, std.testing.allocator);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), lowered.instructions.len);
    try std.testing.expectEqual(@as(i32, 7), lowered.instructions[0].integer_constant);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(lowered.blocks[0].terminator.return_value));
}

test "unit lowers to an explicit empty block" {
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 0,
        .terminator = .return_unit,
    }};
    var lowered = try lowerFunction(.{ .instructions = &.{}, .blocks = &blocks, .entry = @enumFromInt(0) }, std.testing.allocator);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), lowered.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), lowered.blocks.len);
    try std.testing.expectEqual(structures.SsaFunction.Terminator.return_unit, lowered.blocks[0].terminator);
}

test "function SSA allocation failure leaves no partial result" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .integer_constant = 7 }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .{ .return_value = @enumFromInt(0) },
    }};
    const body: structures.FunctionBodyAnalysis = .{ .instructions = &instructions, .blocks = &blocks, .entry = @enumFromInt(0) };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lowerFunction(body, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "direct call lowers to owned value-equal symbolic SSA" {
    const target: structures.ItemId = @enumFromInt(7);
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .call = target }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const body: structures.FunctionBodyAnalysis = .{ .instructions = &instructions, .blocks = &blocks, .entry = @enumFromInt(0) };
    var first = try lowerFunction(body, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try lowerFunction(body, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.instructions.ptr != second.instructions.ptr);
    try std.testing.expect(structures.SsaFunction.eql(first, second));
    try std.testing.expectEqual(@as(usize, 1), first.instructions.len);
    try std.testing.expectEqual(structures.InstanceId{ .item = target }, first.instructions[0].direct_call);
    try std.testing.expectEqual(structures.SsaFunction.Terminator.return_unit, first.blocks[0].terminator);
}

test "direct call SSA allocation failure leaves no partial result" {
    var instructions = [_]structures.FunctionBodyAnalysis.Instruction{.{ .call = @enumFromInt(0) }};
    var blocks = [_]structures.FunctionBodyAnalysis.Block{.{
        .instruction_start = 0,
        .instruction_end = 1,
        .terminator = .return_unit,
    }};
    const body: structures.FunctionBodyAnalysis = .{ .instructions = &instructions, .blocks = &blocks, .entry = @enumFromInt(0) };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lowerFunction(body, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
