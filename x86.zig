const std = @import("std");

pub const AstNode = union(enum) {
    int: i32,
    print: *const AstNode,
    add: *const [2]AstNode,
    sub: *const [2]AstNode,
    mul: *const [2]AstNode,
    div: *const [2]AstNode,
};

fn emitBinary(kids: *const [2]AstNode, buf: *std.ArrayList(u8), gpa: std.mem.Allocator, suffix: []const u8) error{OutOfMemory}!void {
    try emit(&kids[0], buf, gpa);
    try buf.appendSlice(gpa, "    push rax\n");
    try emit(&kids[1], buf, gpa);
    try buf.print(gpa, "    mov rbx, rax\n    pop rax\n{s}\n", .{suffix});
}

fn emit(node: *const AstNode, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    switch (node.*) {
        .int => |v| try buf.print(gpa, "    mov eax, {d}\n", .{v}),
        .print => |child| {
            try emit(child, buf, gpa);
            try buf.appendSlice(gpa, "    push rax\n    call print_int\n    pop rax\n");
        },
        .add => |kids| try emitBinary(kids, buf, gpa, "add eax, ebx"),
        .sub => |kids| try emitBinary(kids, buf, gpa, "sub eax, ebx"),
        .mul => |kids| try emitBinary(kids, buf, gpa, "imul eax, ebx"),
        .div => |kids| try emitBinary(kids, buf, gpa, "cdq\n    idiv ebx"),
    }
}

pub fn compile(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 256);
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "global _start\n_start:\n");
    try emit(node, &buf, gpa);
    try buf.appendSlice(gpa, "    mov edi, eax\n    mov eax, 60\n    syscall\n");
    try buf.appendSlice(gpa, @embedFile("print.asm"));
    return buf.toOwnedSlice(gpa);
}

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

pub fn runProg(io: std.Io) u8 {
    var child = std.process.spawn(io, .{ .argv = &.{"./prog"}, .stderr = .inherit }) catch std.process.exit(1);
    switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| return code,
        else => std.process.exit(1),
    }
}

pub fn eval(io: std.Io, node: *const AstNode, gpa: std.mem.Allocator) u8 {
    const asm_source = compile(node, gpa) catch std.process.exit(1);
    defer gpa.free(asm_source);
    assembleAndLink(io, asm_source);
    return runProg(io);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var kids = [2]AstNode{ .{ .int = 12 }, .{ .int = 3 } };
    var div = AstNode{ .div = &kids };
    var root = AstNode{ .print = &div };

    const asm_source = try compile(&root, gpa);
    defer gpa.free(asm_source);

    assembleAndLink(io, asm_source);
    _ = runProg(io);
}
