const std = @import("std");
const debug = @import("debug.zig");
const codegen = @import("codegen.zig");

pub const IfNode = struct {
    cond: *const AstNode,
    then_: *const AstNode,
    else_: ?*const AstNode,
};

pub const AstNode = union(enum) {
    int: i32,
    print: *const AstNode,
    add: *const [2]AstNode,
    sub: *const [2]AstNode,
    mul: *const [2]AstNode,
    div: *const [2]AstNode,
    arg: u32,
    lt: *const [2]AstNode,
    gt: *const [2]AstNode,
    le: *const [2]AstNode,
    ge: *const [2]AstNode,
    eq: *const [2]AstNode,
    ne: *const [2]AstNode,
    if_: *const IfNode,
};

const CmpKind = enum {
    lt,
    gt,
};

const DemoAst = struct {
    cond_kids: [2]AstNode,
    cond: AstNode,
    then_expr: AstNode,
    else_expr: AstNode,
    then_print: AstNode,
    else_print: AstNode,
    if_node: IfNode,
    root: AstNode,

    fn init(self: *@This(), comptime cmp: CmpKind, lhs: AstNode, rhs: AstNode, then_value: i32, else_value: i32) void {
        self.* = DemoAst{
            .cond_kids = .{ lhs, rhs },
            .cond = undefined,
            .then_expr = .{ .int = then_value },
            .else_expr = .{ .int = else_value },
            .then_print = undefined,
            .else_print = undefined,
            .if_node = undefined,
            .root = undefined,
        };

        self.cond = switch (cmp) {
            .lt => .{ .lt = &self.cond_kids },
            .gt => .{ .gt = &self.cond_kids },
        };
        self.then_print = .{ .print = &self.then_expr };
        self.else_print = .{ .print = &self.else_expr };
        self.if_node = .{ .cond = &self.cond, .then_ = &self.then_print, .else_ = &self.else_print };
        self.root = .{ .if_ = &self.if_node };
    }
};

fn waitForExitCode(io: std.Io, child: *std.process.Child) u8 {
    switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| return code,
        else => std.process.exit(1),
    }
}

fn isDebugFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--debug=");
}

pub fn assembleAndLink(io: std.Io, prog_bytes: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{
        .sub_path = "prog",
        .data = prog_bytes,
        .flags = .{ .permissions = .executable_file },
    }) catch std.process.exit(1);
}

pub fn runProg(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var argv = std.ArrayList([]const u8).initCapacity(gpa, 1 + args.len) catch std.process.exit(1);
    defer argv.deinit(gpa);

    argv.appendAssumeCapacity("./prog");
    for (args) |arg| argv.appendAssumeCapacity(arg);

    var child = std.process.spawn(io, .{ .argv = argv.items, .stderr = .inherit }) catch std.process.exit(1);
    return waitForExitCode(io, &child);
}

pub fn eval(io: std.Io, node: *const AstNode, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const prog_bytes = codegen.compile(node, gpa) catch std.process.exit(1);
    defer gpa.free(prog_bytes);

    assembleAndLink(io, prog_bytes);
    return runProg(io, gpa, args);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const flags = debug.parseDebugFlags(init.minimal.args);

    var prog_args_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer prog_args_list.deinit(gpa);

    var iter = std.process.Args.Iterator.init(init.minimal.args);
    defer iter.deinit();
    _ = iter.next();
    while (iter.next()) |arg| {
        if (!isDebugFlag(arg)) try prog_args_list.append(gpa, arg);
    }

    const prog_args = prog_args_list.items;
    const use_cli_condition = prog_args.len > 0;

    var demo_ast: DemoAst = undefined;
    if (use_cli_condition) {
        demo_ast.init(.gt, .{ .arg = 1 }, .{ .int = 0 }, 111, -111);
    } else {
        demo_ast.init(.lt, .{ .int = 3 }, .{ .int = 4 }, 10, 20);
    }
    const root = demo_ast.root;

    var ir = try codegen.lower(&root, gpa);
    defer ir.deinit(gpa);

    try debug.dumpDebugInfo(io, flags, &root, &ir, gpa);

    const prog_bytes = try codegen.compileProgram(&ir, gpa);
    defer gpa.free(prog_bytes);

    assembleAndLink(io, prog_bytes);
    _ = runProg(io, gpa, prog_args);
}
