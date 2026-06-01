const std = @import("std");

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
    return switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| code,
        else => std.process.exit(1),
    };
}
