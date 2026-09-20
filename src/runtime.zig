const std = @import("std");

pub fn writeProgram(io: std.Io, prog_bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{
        .sub_path = "prog",
        .data = prog_bytes,
        .flags = .{ .permissions = .executable_file },
    });
}

pub fn runProg(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(gpa, 1 + args.len);
    defer argv.deinit(gpa);

    argv.appendAssumeCapacity("./prog");
    for (args) |arg| argv.appendAssumeCapacity(arg);

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => error.ProgramDidNotExitNormally,
    };
}
