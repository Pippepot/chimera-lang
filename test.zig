const std = @import("std");
const testing = std.testing;
const x86 = @import("main.zig");
const AstNode = x86.AstNode;
const IfNode = x86.IfNode;
const compile = @import("codegen.zig").compile;
const writeProgram = @import("main.zig").writeProgram;

fn runTestCapture(node: *const AstNode, args: []const []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const prog_bytes = try compile(node, testing.allocator);
    defer testing.allocator.free(prog_bytes);

    writeProgram(io, prog_bytes);
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

test "compile emits ELF executable bytes" {
    const n = AstNode{ .int = 0 };
    const elf = try compile(&n, testing.allocator);
    defer testing.allocator.free(elf);

    try testing.expect(elf.len >= 64);
    try testing.expectEqual(@as(u8, 0x7f), elf[0]);
    try testing.expectEqual(@as(u8, 'E'), elf[1]);
    try testing.expectEqual(@as(u8, 'L'), elf[2]);
    try testing.expectEqual(@as(u8, 'F'), elf[3]);
    try testing.expectEqual(@as(u8, 2), elf[4]);
    try testing.expectEqual(@as(u8, 1), elf[5]);

    const e_type = std.mem.readInt(u16, elf[16..][0..2], .little);
    const e_machine = std.mem.readInt(u16, elf[18..][0..2], .little);
    try testing.expectEqual(@as(u16, 2), e_type);
    try testing.expectEqual(@as(u16, 62), e_machine);
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

test "arithmetic" {
    const n = AstNode{ .int = 42 };
    try testPrint(&n, "42\n");

    const add_kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    const add = AstNode{ .add = &add_kids };
    try testPrint(&add, "7\n");

    const sub_kids = [2]AstNode{ .{ .int = 10 }, .{ .int = 3 } };
    const sub = AstNode{ .sub = &sub_kids };
    try testPrint(&sub, "7\n");

    const mul_kids = [2]AstNode{ .{ .int = 5 }, .{ .int = 6 } };
    const mul = AstNode{ .mul = &mul_kids };
    try testPrint(&mul, "30\n");

    const div_kids = [2]AstNode{ .{ .int = 20 }, .{ .int = 4 } };
    const div = AstNode{ .div = &div_kids };
    try testPrint(&div, "5\n");

    const inner = [2]AstNode{ .{ .int = 6 }, .{ .int = 2 } };
    const outer_kids = [2]AstNode{ .{ .int = 10 }, .{ .mul = &inner } };
    const nested = AstNode{ .sub = &outer_kids };
    try testPrint(&nested, "-2\n");
}

test "arg" {
    const n = AstNode{ .arg = 1 };
    try testPrintArgs(&n, "42\n", &.{"42"});
}

test "comparisons" {
    const lt_true_kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    const lt_true = AstNode{ .lt = &lt_true_kids };
    try testPrint(&lt_true, "1\n");

    const lt_false_kids = [2]AstNode{ .{ .int = 4 }, .{ .int = 3 } };
    const lt_false = AstNode{ .lt = &lt_false_kids };
    try testPrint(&lt_false, "0\n");

    const gt_true_kids = [2]AstNode{ .{ .int = 4 }, .{ .int = 3 } };
    const gt_true = AstNode{ .gt = &gt_true_kids };
    try testPrint(&gt_true, "1\n");

    const le_equal_kids = [2]AstNode{ .{ .int = 4 }, .{ .int = 4 } };
    const le_equal = AstNode{ .le = &le_equal_kids };
    try testPrint(&le_equal, "1\n");

    const ge_false_kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    const ge_false = AstNode{ .ge = &ge_false_kids };
    try testPrint(&ge_false, "0\n");

    const eq_true_kids = [2]AstNode{ .{ .int = -7 }, .{ .int = -7 } };
    const eq_true = AstNode{ .eq = &eq_true_kids };
    try testPrint(&eq_true, "1\n");

    const ne_false_kids = [2]AstNode{ .{ .int = 9 }, .{ .int = 9 } };
    const ne_false = AstNode{ .ne = &ne_false_kids };
    try testPrint(&ne_false, "0\n");
}

test "if branches" {
    const true_cond_kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    const true_cond = AstNode{ .lt = &true_cond_kids };
    const true_then_val = AstNode{ .int = 11 };
    const true_else_val = AstNode{ .int = 22 };
    const true_then = AstNode{ .print = &true_then_val };
    const true_else = AstNode{ .print = &true_else_val };
    const true_if_data = IfNode{ .cond = &true_cond, .then_ = &true_then, .else_ = &true_else };
    const true_if = AstNode{ .if_ = &true_if_data };
    const true_out = try runTestCapture(&true_if, &.{});
    defer testing.allocator.free(true_out);
    try testing.expectEqualStrings("11\n", true_out);

    const false_cond_kids = [2]AstNode{ .{ .int = 3 }, .{ .int = 4 } };
    const false_cond = AstNode{ .gt = &false_cond_kids };
    const false_then_val = AstNode{ .int = 33 };
    const false_else_val = AstNode{ .int = 44 };
    const false_then = AstNode{ .print = &false_then_val };
    const false_else = AstNode{ .print = &false_else_val };
    const false_if_data = IfNode{ .cond = &false_cond, .then_ = &false_then, .else_ = &false_else };
    const false_if = AstNode{ .if_ = &false_if_data };
    const false_out = try runTestCapture(&false_if, &.{});
    defer testing.allocator.free(false_out);
    try testing.expectEqualStrings("44\n", false_out);
}

test "if expression" {
    const true_cond_kids = [2]AstNode{ .{ .int = 8 }, .{ .int = 2 } };
    const true_cond = AstNode{ .gt = &true_cond_kids };
    const true_then = AstNode{ .int = 55 };
    const true_else = AstNode{ .int = 66 };
    const true_if_data = IfNode{ .cond = &true_cond, .then_ = &true_then, .else_ = &true_else };
    const true_if = AstNode{ .if_ = &true_if_data };
    try testPrint(&true_if, "55\n");

    const false_cond_kids = [2]AstNode{ .{ .int = 8 }, .{ .int = 2 } };
    const false_cond = AstNode{ .lt = &false_cond_kids };
    const false_then = AstNode{ .int = 77 };
    const false_else = AstNode{ .int = 88 };
    const false_if_data = IfNode{ .cond = &false_cond, .then_ = &false_then, .else_ = &false_else };
    const false_if = AstNode{ .if_ = &false_if_data };
    try testPrint(&false_if, "88\n");

    const add_cond_kids = [2]AstNode{ .{ .int = 2 }, .{ .int = 2 } };
    const add_cond = AstNode{ .eq = &add_cond_kids };
    const add_then = AstNode{ .int = 5 };
    const add_else = AstNode{ .int = 6 };
    const add_if_data = IfNode{ .cond = &add_cond, .then_ = &add_then, .else_ = &add_else };
    const add_if = AstNode{ .if_ = &add_if_data };
    const add_kids = [2]AstNode{ add_if, .{ .int = 7 } };
    const add = AstNode{ .add = &add_kids };
    try testPrint(&add, "12\n");
}
