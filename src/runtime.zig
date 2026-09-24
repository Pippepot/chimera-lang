const std = @import("std");

fn writeProgramToAtomic(io: std.Io, prog_bytes: []const u8) !std.Io.File.Atomic {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, "prog", .{
        .permissions = .executable_file,
        .replace = true,
    });
    errdefer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, prog_bytes);
    try atomic.file.setPermissions(io, .executable_file);
    return atomic;
}

pub fn writeProgram(io: std.Io, prog_bytes: []const u8) !void {
    var atomic = try writeProgramToAtomic(io, prog_bytes);
    defer atomic.deinit(io);
    try atomic.replace(io);
}

pub const PreparedProgram = struct {
    path: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PreparedProgram, io: std.Io) void {
        std.Io.Dir.cwd().deleteFile(io, self.path) catch {};
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn run(self: PreparedProgram, io: std.Io, args: []const []const u8) !u8 {
        return runProgram(io, self.allocator, self.path, args);
    }
};

/// Publish `./prog` and retain a hard link to the same inode for this run.
/// Replacing `./prog` in another compiler process cannot change this program.
pub fn prepareProgram(io: std.Io, gpa: std.mem.Allocator, bytes: []const u8) !PreparedProgram {
    var random: [16]u8 = undefined;
    io.random(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const filename = try std.fmt.allocPrint(gpa, "./.chi-run-{s}", .{&hex});
    errdefer gpa.free(filename);
    var atomic = try writeProgramToAtomic(io, bytes);
    defer atomic.deinit(io);
    const linked = blk: {
        atomic.file.hardLink(io, std.Io.Dir.cwd(), filename, .{}) catch |err| switch (err) {
            error.OperationUnsupported => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (!linked) {
        // Some filesystems cannot hard-link open files. Preserve the private
        // executable guarantee by writing a second copy there.
        const file = try std.Io.Dir.cwd().createFile(io, filename, .{
            .exclusive = true,
            .permissions = .executable_file,
        });
        errdefer std.Io.Dir.cwd().deleteFile(io, filename) catch {};
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.setPermissions(io, .executable_file);
    }
    errdefer std.Io.Dir.cwd().deleteFile(io, filename) catch {};
    try atomic.replace(io);
    return .{ .path = filename, .allocator = gpa };
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

test "prepared program keeps its executable across output replacement" {
    const io = std.testing.io;
    var first = try prepareProgram(io, std.testing.allocator, "#!/bin/sh\nexit 41\n");
    defer first.deinit(io);
    var second = try prepareProgram(io, std.testing.allocator, "#!/bin/sh\nexit 42\n");
    defer second.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    try std.testing.expectEqual(@as(u8, 41), try first.run(io, &.{}));
    try std.testing.expectEqual(@as(u8, 42), try second.run(io, &.{}));
}

pub fn runProg(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    return runProgram(io, gpa, "./prog", args);
}

fn runProgram(io: std.Io, gpa: std.mem.Allocator, path: []const u8, args: []const []const u8) !u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(gpa, 1 + args.len);
    defer argv.deinit(gpa);

    argv.appendAssumeCapacity(path);
    for (args) |arg| argv.appendAssumeCapacity(arg);

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    return switch (try child.wait(io)) {
        .exited => |code| code,
        else => error.ProgramDidNotExitNormally,
    };
}
