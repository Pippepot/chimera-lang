const std = @import("std");
const ast = @import("ast.zig");
const codegen = @import("codegen.zig");
const query = @import("query.zig");

const AstNode = ast.AstNode;

fn waitForExitCode(io: std.Io, child: *std.process.Child) u8 {
    switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| return code,
        else => std.process.exit(1),
    }
}

pub fn appendQueryDiagnostics(out: *std.ArrayList(u8), gpa: std.mem.Allocator, stats: query.QueryStats) !void {
    try out.appendSlice(gpa, "; query diagnostics:\n");
    try out.print(gpa, ";   revision: {d}\n", .{stats.revision});
    try out.print(gpa, ";   source_sets: {d}\n", .{stats.source_sets});
    try out.print(gpa, ";   source_unchanged: {d}\n", .{stats.source_unchanged});
    try out.print(gpa, ";   parse: hits={d} recomputes={d}\n", .{ stats.parse_hits, stats.parse_recomputes });
    try out.print(gpa, ";   type: hits={d} recomputes={d}\n", .{ stats.type_hits, stats.type_recomputes });
    try out.print(gpa, ";   lower: hits={d} recomputes={d}\n", .{ stats.lower_hits, stats.lower_recomputes });
    try out.print(gpa, ";   compile: hits={d} recomputes={d}\n", .{ stats.compile_hits, stats.compile_recomputes });
    try out.print(gpa, ";   dependencies: checks={d} invalidations={d}\n", .{ stats.dependency_checks, stats.dependency_invalidations });
}

pub fn writeProgram(io: std.Io, prog_bytes: []const u8) void {
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

    writeProgram(io, prog_bytes);
    return runProg(io, gpa, args);
}
