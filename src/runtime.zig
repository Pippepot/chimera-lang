const std = @import("std");

pub fn writeProgram(io: std.Io, prog_bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, "prog", .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, prog_bytes);
    // Creation permissions do not update an existing output file.
    try file.setPermissions(io, .executable_file);
}

test "replacing a non-executable output makes the new program runnable" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, "prog", .{});
        defer file.close(io);
        try file.setPermissions(io, .default_file);
    }
    try writeProgram(io, "#!/bin/sh\nexit 42\n");
    try std.testing.expectEqual(@as(u8, 42), try runProg(io, std.testing.allocator, &.{}));
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
