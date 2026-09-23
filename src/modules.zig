const std = @import("std");
const standard_library = @import("standard_library");
const query = @import("query.zig");
const queries = @import("queries.zig");
const structures = @import("structures.zig");

pub const DiscoveredFile = struct {
    path: []const u8,
    module_path: []u8,
};

pub const SourceFile = struct {
    path: []const u8,
    source: []const u8,
    module_path: []const u8,
};

pub const StandardSource = struct {
    registry_path: []const u8,
    display_path: []const u8,
    source: []const u8,
    module_path: []const u8,
};

/// Standard-library files have reserved `std.<filename>` module identities.
/// They are embedded so compilation does not depend on the process working
/// directory or an adjacent source checkout.
pub const standard_sources = [_]StandardSource{
    .{
        .registry_path = "$std/example.chi",
        .display_path = "std/example.chi",
        .source = standard_library.example,
        .module_path = "std.example",
    },
    .{
        .registry_path = "$std/exit.chi",
        .display_path = "std/exit.chi",
        .source = standard_library.exit,
        .module_path = "std.exit",
    },
    .{
        .registry_path = "$std/prelude.chi",
        .display_path = "std/prelude.chi",
        .source = standard_library.prelude,
        .module_path = "std.prelude",
    },
};

pub const Catalog = struct {
    files: []DiscoveredFile,
    modules: [][]u8,

    pub fn deinit(self: *Catalog, gpa: std.mem.Allocator) void {
        for (self.files) |file| {
            gpa.free(file.path);
            gpa.free(file.module_path);
        }
        gpa.free(self.files);
        for (self.modules) |module| gpa.free(module);
        gpa.free(self.modules);
        self.* = undefined;
    }
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
    if (name.len == 0 or structures.Token.getKeyword(name) != null) return false;
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
    const owned_files = try files.toOwnedSlice(gpa);
    errdefer {
        for (owned_files) |file| {
            gpa.free(file.path);
            gpa.free(file.module_path);
        }
        gpa.free(owned_files);
    }
    return .{ .files = owned_files, .modules = try modules.toOwnedSlice(gpa) };
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
        const source = try entry_dir.readFileAlloc(io, file.path, gpa, .limited(std.math.maxInt(usize)));
        errdefer gpa.free(source);
        try sources.append(gpa, .{
            .path = file.path,
            .source = source,
            .module_path = file.module_path,
        });
    }
    return sources.toOwnedSlice(gpa);
}

/// Retain this registry alongside a database when refreshing a directory tree.
/// File IDs survive enumeration-order changes. Removed inputs remain unreachable;
/// membership and the catalog are the authorities for current existence.
pub const SourceRegistry = struct {
    paths: std.StringHashMapUnmanaged(structures.FileId) = .empty,
    known_modules: std.AutoHashMapUnmanaged(structures.ModuleId, void) = .empty,

    pub fn deinit(self: *SourceRegistry, gpa: std.mem.Allocator) void {
        var paths = self.paths.keyIterator();
        while (paths.next()) |path| gpa.free(path.*);
        self.paths.deinit(gpa);
        self.known_modules.deinit(gpa);
        self.* = undefined;
    }

    pub fn fileId(self: SourceRegistry, path: []const u8) ?structures.FileId {
        return self.paths.get(path);
    }

    // Apply only while the database is idle, before demanding any queries.
    // An allocation failure aborts the update; retry it or discard the database.
    pub fn update(self: *SourceRegistry, db: *query.Database, gpa: std.mem.Allocator, entry_source: []const u8, files: []const SourceFile, module_paths: []const []const u8) !void {
        const entry_module = try db.intern(queries.ModulePaths, .{ .path = "" });
        try putInput(db, queries.SourceText, 0, entry_source);
        try putInput(db, queries.FileModule, 0, entry_module);
        var current: std.AutoArrayHashMapUnmanaged(structures.ModuleId, std.ArrayList(structures.FileId)) = .empty;
        defer {
            for (current.values()) |*members| members.deinit(gpa);
            current.deinit(gpa);
        }
        try current.put(gpa, entry_module, .empty);
        try current.getPtr(entry_module).?.append(gpa, 0);
        for (module_paths) |path| {
            const module = try db.intern(queries.ModulePaths, .{ .path = path });
            const slot = try current.getOrPut(gpa, module);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
        }
        for (files) |file| try self.registerFile(db, gpa, &current, file);
        for (standard_sources) |file| try self.registerFile(db, gpa, &current, .{
            .path = file.registry_path,
            .module_path = file.module_path,
            .source = file.source,
        });
        try putInput(db, queries.StandardExitFile, {}, self.fileId("$std/exit.chi").?);
        const prelude_module = try db.intern(queries.ModulePaths, .{ .path = "std.prelude" });
        try putInput(db, queries.StandardPreludeModule, {}, prelude_module);
        for (current.keys(), current.values()) |module, *members| {
            std.mem.sort(structures.FileId, members.items, {}, std.sort.asc(structures.FileId));
            try self.known_modules.put(gpa, module, {});
            try putInput(db, queries.ModuleMembers, module, members.items);
        }
        var previous_modules = self.known_modules.keyIterator();
        while (previous_modules.next()) |module| {
            if (!current.contains(module.*)) try putInput(db, queries.ModuleMembers, module.*, &.{});
        }
        const catalog = try gpa.dupe(structures.ModuleId, current.keys());
        defer gpa.free(catalog);
        std.mem.sort(structures.ModuleId, catalog, {}, struct {
            fn lessThan(_: void, a: structures.ModuleId, b: structures.ModuleId) bool {
                return @intFromEnum(a) < @intFromEnum(b);
            }
        }.lessThan);
        try putInput(db, queries.ModuleCatalog, {}, catalog);
        // Keep partially updated memberships until a refresh fully commits.
        self.known_modules.clearRetainingCapacity();
        for (current.keys()) |module| self.known_modules.putAssumeCapacity(module, {});
    }

    fn registerFile(
        self: *SourceRegistry,
        db: *query.Database,
        gpa: std.mem.Allocator,
        current: *std.AutoArrayHashMapUnmanaged(structures.ModuleId, std.ArrayList(structures.FileId)),
        file: SourceFile,
    ) !void {
        const id = self.paths.get(file.path) orelse new: {
            try self.paths.ensureUnusedCapacity(gpa, 1);
            const owned = try gpa.dupe(u8, file.path);
            const id: structures.FileId = @intCast(self.paths.count() + 1);
            self.paths.putAssumeCapacityNoClobber(owned, id);
            break :new id;
        };
        const module = try db.intern(queries.ModulePaths, .{ .path = file.module_path });
        try putInput(db, queries.SourceText, id, file.source);
        try putInput(db, queries.FileModule, id, module);
        const slot = try current.getOrPut(gpa, module);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(gpa, id);
    }
};

fn putInput(db: *query.Database, comptime I: type, key: I.Key, value: I.Value) !void {
    db.setInput(I, key, value) catch |err| switch (err) {
        error.InputNotFound => try db.addInput(I, key, value),
        else => return err,
    };
}

pub fn registerSources(db: *query.Database, gpa: std.mem.Allocator, entry_source: []const u8, files: []const SourceFile, module_paths: []const []const u8) !void {
    var registry: SourceRegistry = .{};
    defer registry.deinit(gpa);
    try registry.update(db, gpa, entry_source, files, module_paths);
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
    var discovered = try collectModuleFiles(std.testing.allocator, io, entry_dir, "other.chi");
    defer discovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), discovered.files.len);
    try std.testing.expectEqual(@as(usize, 1), discovered.modules.len);

    var root_discovered = try collectModuleFiles(std.testing.allocator, io, tmp.dir, "main.chi");
    defer root_discovered.deinit(std.testing.allocator);
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
    try tmp.dir.createDirPath(io, "import");
    try tmp.dir.createDirPath(io, "empty");
    try tmp.dir.createDirPath(io, "_priv");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics/collision/raycast.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics.collision/flat.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "with-dash/other.chi", .data = "exit(0)" });
    try tmp.dir.writeFile(io, .{ .sub_path = "_priv/ok.chi", .data = "exit(0)" });

    var discovered = try collectModuleFiles(std.testing.allocator, io, tmp.dir, "main.chi");
    defer discovered.deinit(std.testing.allocator);
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
    try registerSources(db, std.testing.allocator, "import physics\nexit(0)", &.{
        .{ .path = "physics/body.chi", .source = "static answer = 40", .module_path = "physics" },
        .{ .path = "physics/world.chi", .source = "static extra = 1", .module_path = "physics" },
        .{ .path = "other.chi", .source = "static answer = 2", .module_path = "other" },
    }, &.{ "", "physics", "other", "empty" });

    try std.testing.expect((try db.get(queries.ResolveFileImports, 0)).* != null);
    const physics = (try db.get(queries.BuildModuleScope, 1)).*.?;
    try std.testing.expect(physics.resolve("answer") != null);
    try std.testing.expect(physics.resolve("extra") != null);
    const other = (try db.get(queries.BuildModuleScope, 3)).*.?;
    try std.testing.expect(other.resolve("answer") != null);
    try std.testing.expect(physics.resolve("answer").? != other.resolve("answer").?);
    const empty = try db.intern(queries.ModulePaths, .{ .path = "empty" });
    try std.testing.expectEqual(@as(usize, 0), (try db.get(queries.ModuleDeclarations, empty)).*.?.entries.len);
}

test "module discovery and loading clean up every allocation failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "physics");
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers.chi", .data = "static X = 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "physics/body.chi", .data = "pub static Y = 2" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCatalogAllocations, .{tmp.dir});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testSourceAllocations, .{tmp.dir});
}

fn testCatalogAllocations(gpa: std.mem.Allocator, directory: std.Io.Dir) !void {
    var catalog = try collectModuleFiles(gpa, std.testing.io, directory, "main.chi");
    defer catalog.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), catalog.files.len);
}

fn testSourceAllocations(gpa: std.mem.Allocator, directory: std.Io.Dir) !void {
    var root_path: [0]u8 = .{};
    var physics_path = "physics".*;
    const sources = try readSources(std.testing.io, gpa, directory, &.{
        .{ .path = "helpers.chi", .module_path = &root_path },
        .{ .path = "physics/body.chi", .module_path = &physics_path },
    });
    defer {
        for (sources) |file| gpa.free(file.source);
        gpa.free(sources);
    }
    try std.testing.expectEqual(@as(usize, 2), sources.len);
}
