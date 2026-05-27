const std = @import("std");
const testing = std.testing;
const AstNode = @import("x86.zig").AstNode;
const compile = @import("codegen.zig").compile;
const assembleAndLink = @import("x86.zig").assembleAndLink;

fn runTestCapture(node: *const AstNode, args: []const []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const asm_source = try compile(node, testing.allocator);
    defer testing.allocator.free(asm_source);

    assembleAndLink(io, asm_source);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var argv = try std.ArrayList([]const u8).initCapacity(testing.allocator, 1 + args.len);
    defer argv.deinit(testing.allocator);
    argv.appendAssumeCapacity("./prog");
    for (args) |a| argv.appendAssumeCapacity(a);

    const result = try std.process.run(testing.allocator, io, .{
        .argv = argv.items,
    });
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expectEqual(@as(u8, 0), code),
        else => return error.TestFailed,
    }

    return result.stdout;
}

fn testPrint(node: *const AstNode, expected: []const u8) !void {
    var print_node = AstNode{ .print = node };
    const out = try runTestCapture(&print_node, &.{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

fn testPrintArgs(node: *const AstNode, expected: []const u8, args: []const []const u8) !void {
    var print_node = AstNode{ .print = node };
    const out = try runTestCapture(&print_node, args);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "int" {
    const n = AstNode{ .int = 42 };
    try testPrint(&n, "42\n");
}

test "add" {
    const kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    const n = AstNode{ .add = &kids };
    try testPrint(&n, "7\n");
}

test "sub" {
    const kids = [2]AstNode{ .{ .int = 10 }, .{ .int = 3 } };
    const n = AstNode{ .sub = &kids };
    try testPrint(&n, "7\n");
}

test "mul" {
    const kids = [2]AstNode{ .{ .int = 5 }, .{ .int = 6 } };
    const n = AstNode{ .mul = &kids };
    try testPrint(&n, "30\n");
}

test "div" {
    const kids = [2]AstNode{ .{ .int = 20 }, .{ .int = 4 } };
    const n = AstNode{ .div = &kids };
    try testPrint(&n, "5\n");
}

test "nested" {
    const inner = [2]AstNode{ .{ .int = 6 }, .{ .int = 2 } };
    const outer_kids = [2]AstNode{ .{ .int = 10 }, .{ .mul = &inner } };
    const n = AstNode{ .sub = &outer_kids };
    try testPrint(&n, "-2\n");
}

test "arg" {
    const n = AstNode{ .arg = 1 };
    try testPrintArgs(&n, "42\n", &.{"42"});
}
