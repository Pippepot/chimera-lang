const std = @import("std");
const structures = @import("structures.zig");

pub fn lowerFunction(body: structures.FunctionBodyAnalysis, gpa: std.mem.Allocator) !structures.SsaFunction {
    return switch (body) {
        .unit => .{
            .instructions = try gpa.alloc(structures.SsaFunction.Instruction, 0),
            .terminator = .return_unit,
        },
        .integer_return => |value| blk: {
            const instructions = try gpa.alloc(structures.SsaFunction.Instruction, 1);
            instructions[0] = .{ .integer_constant = value };
            break :blk .{
                .instructions = instructions,
                .terminator = .{ .return_value = @enumFromInt(0) },
            };
        },
        .direct_call => |target| blk: {
            const instructions = try gpa.alloc(structures.SsaFunction.Instruction, 1);
            instructions[0] = .{ .direct_call = .{ .item = target } };
            break :blk .{
                .instructions = instructions,
                .terminator = .return_unit,
            };
        },
    };
}

test "literal return lowers to owned function SSA" {
    var lowered = try lowerFunction(.{ .integer_return = 7 }, std.testing.allocator);
    defer lowered.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), lowered.instructions.len);
    try std.testing.expectEqual(@as(i32, 7), lowered.instructions[0].integer_constant);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(lowered.terminator.return_value));
}

test "unit lowers to empty SSA without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var lowered = try lowerFunction(.unit, failing.allocator());
    defer lowered.deinit(failing.allocator());

    try std.testing.expectEqual(@as(usize, 0), lowered.instructions.len);
    try std.testing.expectEqual(structures.SsaFunction.Terminator.return_unit, lowered.terminator);
    try std.testing.expect(!failing.has_induced_failure);
}

test "function SSA allocation failure leaves no partial result" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lowerFunction(.{ .integer_return = 7 }, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "direct call lowers to owned value-equal symbolic SSA" {
    const target: structures.ItemId = @enumFromInt(7);
    var first = try lowerFunction(.{ .direct_call = target }, std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    var second = try lowerFunction(.{ .direct_call = target }, std.testing.allocator);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.instructions.ptr != second.instructions.ptr);
    try std.testing.expect(structures.SsaFunction.eql(first, second));
    try std.testing.expectEqual(@as(usize, 1), first.instructions.len);
    try std.testing.expectEqual(structures.InstanceId{ .item = target }, first.instructions[0].direct_call);
    try std.testing.expectEqual(structures.SsaFunction.Terminator.return_unit, first.terminator);
}

test "direct call SSA allocation failure leaves no partial result" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, lowerFunction(.{ .direct_call = @enumFromInt(0) }, failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
