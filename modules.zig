const std = @import("std");
const query = @import("query_new.zig");
const queries = @import("query_structures.zig");
const structures = @import("structures.zig");

pub const DiscoveredFile = struct {
    path: []const u8,
    module_path: []u8,
};

pub const SourceFile = struct {
    source: []const u8,
    module_path: []const u8,
};

pub const Catalog = struct {
    files: []DiscoveredFile,
    modules: [][]u8,
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

fn isModuleSegment(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const valid = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9' => i != 0,
            else => false,
        };
        if (!valid) return false;
    }
    return true;
}

pub fn collectModuleFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    entry_dir: std.Io.Dir,
    entry_name: []const u8,
) !Catalog {
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
    var modules: std.ArrayList([]u8) = .empty;
    errdefer {
        for (modules.items) |module| gpa.free(module);
        modules.deinit(gpa);
    }
    try modules.append(gpa, try modulePath(gpa, ""));
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (!isModuleSegment(entry.basename)) {
                walker.leave(io);
                continue;
            }
            const visited = try modulePath(gpa, entry.path);
            errdefer gpa.free(visited);
            try modules.append(gpa, visited);
            continue;
        }
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
    return .{ .files = try files.toOwnedSlice(gpa), .modules = try modules.toOwnedSlice(gpa) };
}

fn freeCatalog(gpa: std.mem.Allocator, catalog: Catalog) void {
    for (catalog.files) |file| {
        gpa.free(file.path);
        gpa.free(file.module_path);
    }
    gpa.free(catalog.files);
    for (catalog.modules) |module| gpa.free(module);
    gpa.free(catalog.modules);
}

pub fn readSources(
    io: std.Io,
    gpa: std.mem.Allocator,
    entry_dir: std.Io.Dir,
    files: []const DiscoveredFile,
) ![]SourceFile {
    var sources: std.ArrayList(SourceFile) = .empty;
    errdefer {
        for (sources.items) |file| gpa.free(file.source);
        sources.deinit(gpa);
    }
    for (files) |file| {
        try sources.append(gpa, .{
            .source = try entry_dir.readFileAlloc(io, file.path, gpa, .limited(std.math.maxInt(usize))),
            .module_path = file.module_path,
        });
    }
    return sources.toOwnedSlice(gpa);
}

pub fn registerSources(
    db: *query.Database,
    gpa: std.mem.Allocator,
    entry_source: []const u8,
    files: []const SourceFile,
    modules: []const []const u8,
) !void {
    const entry_module = try db.intern(queries.ModulePaths, .{ .path = "" });
    try db.addInput(queries.SourceText, 0, entry_source);
    try db.addInput(queries.FileModule, 0, entry_module);
    const file_modules = try gpa.alloc(structures.ModuleId, files.len);
    defer gpa.free(file_modules);
    var seen: std.ArrayList(structures.ModuleId) = .empty;
    defer seen.deinit(gpa);
    try seen.append(gpa, entry_module);
    for (files, 0..) |file, index| {
        const id: structures.FileId = @intCast(index + 1);
        const module = try db.intern(queries.ModulePaths, .{ .path = file.module_path });
        file_modules[index] = module;
        try db.addInput(queries.FileModule, id, module);
        try db.addInput(queries.SourceText, id, file.source);
        if (std.mem.indexOfScalar(structures.ModuleId, seen.items, module) == null)
            try seen.append(gpa, module);
    }
    for (modules) |module_path| {
        const module = try db.intern(queries.ModulePaths, .{ .path = module_path });
        if (std.mem.indexOfScalar(structures.ModuleId, seen.items, module) == null)
            try seen.append(gpa, module);
    }
    for (seen.items) |module| {
        var members: std.ArrayList(structures.FileId) = .empty;
        defer members.deinit(gpa);
        if (module == entry_module) try members.append(gpa, 0);
        for (file_modules, 0..) |file_module, index| {
            if (file_module != module) continue;
            try members.append(gpa, @intCast(index + 1));
        }
        try db.addInput(queries.ModuleMembers, module, members.items);
    }
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
    defer freeCatalog(std.testing.allocator, discovered);
    try std.testing.expectEqual(@as(usize, 0), discovered.files.len);
    try std.testing.expectEqual(@as(usize, 1), discovered.modules.len);

    const root_discovered = try collectModuleFiles(std.testing.allocator, io, tmp.dir, "main.chi");
    defer freeCatalog(std.testing.allocator, root_discovered);
    const root_files = root_discovered.files;
    try std.testing.expectEqual(@as(usize, 4), root_files.len);
    try std.testing.expectEqualStrings("helpers.chi", root_files[0].path);
    try std.testing.expectEqualStrings("", root_files[0].module_path);
    try std.testing.expectEqualStrings("physics/body.chi", root_files[1].path);
    try std.testing.expectEqualStrings("physics", root_files[1].module_path);
    try std.testing.expectEqualStrings("physics/collision/raycast.chi", root_files[2].path);
    try std.testing.expectEqualStrings("physics.collision", root_files[2].module_path);
    try std.testing.expectEqualStrings("sibling/other.chi", root_files[3].path);
    try std.testing.expectEqualStrings("sibling", root_files[3].module_path);
    try std.testing.expectEqual(@as(usize, 4), root_discovered.modules.len);
}

test "module discovery ignores directories without spellable names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "physics/collision");
    try tmp.dir.createDirPath(io, "physics.collision");
    try tmp.dir.createDirPath(io, "with-dash");
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, "_priv");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics/collision/raycast.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics.collision/flat.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "with-dash/other.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "_priv/ok.chi", .data = "exit(0)" });

    const discovered = try collectModuleFiles(std.testing.allocator, io, tmp.dir, "main.chi");
    defer freeCatalog(std.testing.allocator, discovered);
    const files = discovered.files;
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("_priv/ok.chi", files[0].path);
    try std.testing.expectEqualStrings("_priv", files[0].module_path);
    try std.testing.expectEqualStrings("physics/collision/raycast.chi", files[1].path);
    try std.testing.expectEqualStrings("physics.collision", files[1].module_path);
    for ([_][]const u8{ "", "physics", "physics.collision", "_priv", "empty" }) |expected| {
        var found = false;
        for (discovered.modules) |module| found = found or std.mem.eql(u8, module, expected);
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 5), discovered.modules.len);
}

test "source registration groups members by module" {
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try registerSources(db, std.testing.allocator, "exit(0)", &.{
        .{ .source = "static answer = 40", .module_path = "physics" },
        .{ .source = "static extra = 1", .module_path = "physics" },
        .{ .source = "static answer = 2", .module_path = "other" },
    }, &.{ "", "physics", "other", "empty" });

    const physics = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try std.testing.expect(physics.resolve("answer") != null);
    try std.testing.expect(physics.resolve("extra") != null);
    const other = (try db.get(queries.BuildModuleScope, 3)).*.?;
    try std.testing.expect(other.resolve("answer") != null);
    try std.testing.expect(physics.resolve("answer").? != other.resolve("answer").?);
    const empty = try db.intern(queries.ModulePaths, .{ .path = "empty" });
    try std.testing.expectEqual(@as(usize, 0), (try db.get(queries.ModuleDeclarations, empty)).*.?.entries.len);
}
