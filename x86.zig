const std = @import("std");
const debug = @import("debug.zig");
const codegen = @import("codegen.zig");

pub const AstNode = union(enum) {
    int: i32,
    print: *const AstNode,
    add: *const [2]AstNode,
    sub: *const [2]AstNode,
    mul: *const [2]AstNode,
    div: *const [2]AstNode,
    arg: u32,
};

pub fn assembleAndLink(io: std.Io, asm_source: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = "x86.asm", .data = asm_source }) catch std.process.exit(1);
    defer cwd.deleteFile(io, "x86.asm") catch {};
    defer cwd.deleteFile(io, "x86.o") catch {};

    var nasm_child = std.process.spawn(io, .{ .argv = &.{ "nasm", "-f", "elf64", "x86.asm", "-o", "x86.o" }, .stderr = .inherit }) catch std.process.exit(1);
    switch (nasm_child.wait(io) catch std.process.exit(1)) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }

    var ld_child = std.process.spawn(io, .{ .argv = &.{ "ld", "x86.o", "-o", "prog" }, .stderr = .inherit }) catch std.process.exit(1);
    switch (ld_child.wait(io) catch std.process.exit(1)) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}

pub fn runProg(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var argv = std.ArrayList([]const u8).initCapacity(gpa, 1 + args.len) catch std.process.exit(1);
    defer argv.deinit(gpa);
    argv.appendAssumeCapacity("./prog");
    for (args) |a| argv.appendAssumeCapacity(a);
    var child = std.process.spawn(io, .{ .argv = argv.items, .stderr = .inherit }) catch std.process.exit(1);
    switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| return code,
        else => std.process.exit(1),
    }
}

pub fn eval(io: std.Io, node: *const AstNode, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const asm_source = codegen.compile(node, gpa) catch std.process.exit(1);
    defer gpa.free(asm_source);
    assembleAndLink(io, asm_source);
    return runProg(io, gpa, args);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var prog_args_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer prog_args_list.deinit(gpa);

    const flags = debug.parseDebugFlags(init.minimal.args);

    var iter = std.process.Args.Iterator.init(init.minimal.args);
    defer iter.deinit();
    _ = iter.next();
    while (iter.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--debug=")) try prog_args_list.append(gpa, arg);
    }
    const prog_args = prog_args_list.items;

    var arg_node: AstNode = undefined;
    var mkids: [2]AstNode = undefined;
    var akids: [2]AstNode = undefined;
    const root = if (prog_args.len > 0) blk: {
        arg_node = .{ .arg = 1 };
        break :blk AstNode{ .print = &arg_node };
    } else blk: {
        mkids = .{ .{ .int = 2 }, .{ .int = 5 } };
        const mul = AstNode{ .mul = &mkids };
        akids = .{ mul, .{ .int = 3 } };
        const add = AstNode{ .add = &akids };
        break :blk AstNode{ .print = &add };
    };

    var ir = try codegen.lower(&root, gpa);
    defer ir.deinit(gpa);

    try debug.dumpDebugInfo(io, flags, &root, &ir, gpa);

    const asm_source = try codegen.compileIr(&ir, gpa);
    defer gpa.free(asm_source);

    assembleAndLink(io, asm_source);
    _ = runProg(io, gpa, prog_args);
}
