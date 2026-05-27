const std = @import("std");
const testing = std.testing;
const AstNode = @import("x86.zig").AstNode;
const eval = @import("x86.zig").eval;

fn runTest(node: *const AstNode) u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    return eval(threaded.io(), node, testing.allocator);
}

test "int" {
    var n = AstNode{ .int = 42 };
    try testing.expectEqual(42, runTest(&n));
}

test "add" {
    var kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    var n = AstNode{ .add = &kids };
    try testing.expectEqual(7, runTest(&n));
}

test "sub" {
    var kids = [2]AstNode{ .{ .int = 10 }, .{ .int = 3 } };
    var n = AstNode{ .sub = &kids };
    try testing.expectEqual(7, runTest(&n));
}

test "mul" {
    var kids = [2]AstNode{ .{ .int = 5 }, .{ .int = 6 } };
    var n = AstNode{ .mul = &kids };
    try testing.expectEqual(30, runTest(&n));
}

test "div" {
    var kids = [2]AstNode{ .{ .int = 20 }, .{ .int = 4 } };
    var n = AstNode{ .div = &kids };
    try testing.expectEqual(5, runTest(&n));
}

test "nested" {
    var inner = [2]AstNode{ .{ .int = 6 }, .{ .int = 2 } };
    var outer = [2]AstNode{ .{ .int = 10 }, .{ .mul = &inner } };
    var root = AstNode{ .sub = &outer };
    try testing.expectEqual(@as(u8, 254), runTest(&root));
}
