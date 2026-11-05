const std = @import("std");
const standard_artifact = @import("standard_artifact.zig");

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) return error.MissingOutputPath;
    const bytes = try standard_artifact.build(init.gpa);
    defer init.gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = arguments[1], .data = bytes });
}
