const std = @import("std");

pub const DiscoveredFile = struct {
    path: []const u8,
    module_path: []u8,
};

pub fn modulePath(gpa: std.mem.Allocator, dir_path: []const u8) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);
    var parts = std.mem.splitScalar(u8, dir_path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        try segments.append(gpa, part);
    }
    return std.mem.join(gpa, ".", segments.items);
}

pub fn collectModuleFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    entry_dir: std.Io.Dir,
    entry_name: []const u8,
) ![]DiscoveredFile {
    var walker = try entry_dir.walk(gpa);
    defer walker.deinit();
    var files: std.ArrayList(DiscoveredFile) = .empty;
    errdefer {
        for (files.items) |file| {
            gpa.free(file.path);
            gpa.free(file.module_path);
        }
        files.deinit(gpa);
    }
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".chi")) continue;
        if (std.mem.eql(u8, entry.path, entry_name)) continue;
        const path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(path);
        const dir_path = std.fs.path.dirname(entry.path) orelse "";
        const module_path = try modulePath(gpa, dir_path);
        errdefer gpa.free(module_path);
        try files.append(gpa, .{ .path = path, .module_path = module_path });
    }
    // Walker order is undefined; sort for deterministic FileIds.
    std.mem.sort(DiscoveredFile, files.items, {}, struct {
        fn lessThan(_: void, left: DiscoveredFile, right: DiscoveredFile) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.lessThan);
    return files.toOwnedSlice(gpa);
}

test "module directories map to module paths with $entry at the root" {
    const allocator = std.testing.allocator;
    for ([_]struct { dir: []const u8, expected: []const u8 }{
        .{ .dir = "", .expected = "" },
        .{ .dir = ".", .expected = "" },
        .{ .dir = "physics", .expected = "physics" },
        .{ .dir = "physics/collision", .expected = "physics.collision" },
    }) |case| {
        const path = try modulePath(allocator, case.dir);
        defer allocator.free(path);
        try std.testing.expectEqualStrings(case.expected, path);
    }
}

test "module discovery collects nested sources and skips the entry file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "physics/collision");
    try tmp.dir.createDirPath(io, "sibling");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "not source" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics/body.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics/collision/raycast.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sibling/other.chi", .data = "exit(0)" });

    var entry_dir = try tmp.dir.openDir(io, "sibling", .{ .iterate = true });
    defer entry_dir.close(io);
    const discovered = try collectModuleFiles(std.testing.allocator, io, entry_dir, "other.chi");
    defer {
        for (discovered) |file| {
            std.testing.allocator.free(file.path);
            std.testing.allocator.free(file.module_path);
        }
        std.testing.allocator.free(discovered);
    }
    try std.testing.expectEqual(@as(usize, 0), discovered.len);

    const root_discovered = try collectModuleFiles(std.testing.allocator, io, tmp.dir, "main.chi");
    defer {
        for (root_discovered) |file| {
            std.testing.allocator.free(file.path);
            std.testing.allocator.free(file.module_path);
        }
        std.testing.allocator.free(root_discovered);
    }
    try std.testing.expectEqual(@as(usize, 4), root_discovered.len);
    try std.testing.expectEqualStrings("helpers.chi", root_discovered[0].path);
    try std.testing.expectEqualStrings("", root_discovered[0].module_path);
    try std.testing.expectEqualStrings("physics/body.chi", root_discovered[1].path);
    try std.testing.expectEqualStrings("physics", root_discovered[1].module_path);
    try std.testing.expectEqualStrings("physics/collision/raycast.chi", root_discovered[2].path);
    try std.testing.expectEqualStrings("physics.collision", root_discovered[2].module_path);
    try std.testing.expectEqualStrings("sibling/other.chi", root_discovered[3].path);
    try std.testing.expectEqualStrings("sibling", root_discovered[3].module_path);
}
