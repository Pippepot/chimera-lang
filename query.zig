const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const analyze = @import("analyze.zig");
const ir_mod = @import("ir.zig");
const codegen = @import("codegen.zig");
const ast = @import("ast.zig");
const query_cache = @import("query_cache.zig");

pub const SourceId = db.SourceId;
pub const QueryStats = db.QueryStats;
pub const Stage = db.Stage;
pub const CompileResult = db.CompileResult;
pub const QueryError = db.QueryError;

pub const QueryDbOptions = struct {
    persistent_cache_enabled: bool = true,
    cache_dir_override: ?[]const u8 = null,
    io: ?std.Io = null,
};

const SourceInput = struct {
    text: []u8,
    changed_at: db.Revision,
    source_path: ?[]u8 = null,
};

const ActiveQuery = struct {
    key: db.QueryKey,
    deps: std.ArrayList(db.Dependency),
};

fn stageValueType(comptime stage: Stage) type {
    return switch (stage) {
        .parse => parser.ParsedAst,
        .resolve => resolver.ResolvedAst,
        .typecheck => analyze.AnalyzedAst,
        .lower => ir_mod.Program,
        .compile => []const u8,
    };
}

fn freeMemoValue(comptime T: type, value: *?T, gpa: std.mem.Allocator) void {
    if (value.*) |*v| {
        if (comptime T == []const u8) {
            gpa.free(v.*);
        } else if (comptime T == analyze.AnalyzedAst) {
            v.deinit();
        } else {
            v.deinit(gpa);
        }
    }
}

fn deinitMemo(comptime T: type, memo: *db.Memo(T), gpa: std.mem.Allocator) void {
    freeMemoValue(T, &memo.value, gpa);
    for (memo.diagnostics.items) |diag| {
        if (diag.message_allocated) gpa.free(diag.message);
    }
    memo.diagnostics.deinit(gpa);
    memo.deps.deinit(gpa);
}

fn prevStage(comptime stage: Stage) Stage {
    return switch (stage) {
        .parse => unreachable,
        .resolve => .parse,
        .typecheck => .resolve,
        .lower => .typecheck,
        .compile => .lower,
    };
}

fn deserializeStageValue(comptime stage: Stage, gpa: std.mem.Allocator, bytes: []const u8, parse_ast: ?*const ast.Ast) (anyerror!stageValueType(stage)) {
    return switch (stage) {
        .parse => query_cache.deserializeParsed(gpa, bytes),
        .resolve => query_cache.deserializeResolved(gpa, bytes),
        .typecheck => query_cache.deserializeTyped(gpa, bytes, parse_ast.?),
        .lower => query_cache.deserializeProgram(gpa, bytes),
        .compile => unreachable,
    };
}

pub const QueryDb = struct {
    gpa: std.mem.Allocator,
    io: ?std.Io,
    persistent_cache_enabled: bool,
    cache_dir_override: ?[]u8,
    cache_backings: std.ArrayList([]u8),
    revision: db.Revision,
    sources: std.AutoHashMap(db.SourceId, SourceInput),
    parse_memos: std.AutoHashMap(db.SourceId, db.Memo(parser.ParsedAst)),
    resolve_memos: std.AutoHashMap(db.SourceId, db.Memo(resolver.ResolvedAst)),
    type_memos: std.AutoHashMap(db.SourceId, db.Memo(analyze.AnalyzedAst)),
    lower_memos: std.AutoHashMap(db.SourceId, db.Memo(ir_mod.Program)),
    compile_memos: std.AutoHashMap(db.SourceId, db.Memo([]const u8)),
    active_stack: std.ArrayList(ActiveQuery),
    stats: db.QueryStats,

    pub fn init(gpa: std.mem.Allocator) QueryDb {
        return initWithOptions(gpa, .{
            .io = if (builtin.is_test) std.testing.io else null,
        });
    }

    pub fn initWithOptions(gpa: std.mem.Allocator, options: QueryDbOptions) QueryDb {
        const override_copy = if (options.cache_dir_override) |dir| gpa.dupe(u8, dir) catch null else null;
        return .{
            .gpa = gpa,
            .io = options.io,
            .persistent_cache_enabled = options.persistent_cache_enabled,
            .cache_dir_override = override_copy,
            .cache_backings = .empty,
            .revision = 0,
            .sources = std.AutoHashMap(db.SourceId, SourceInput).init(gpa),
            .parse_memos = std.AutoHashMap(db.SourceId, db.Memo(parser.ParsedAst)).init(gpa),
            .resolve_memos = std.AutoHashMap(db.SourceId, db.Memo(resolver.ResolvedAst)).init(gpa),
            .type_memos = std.AutoHashMap(db.SourceId, db.Memo(analyze.AnalyzedAst)).init(gpa),
            .lower_memos = std.AutoHashMap(db.SourceId, db.Memo(ir_mod.Program)).init(gpa),
            .compile_memos = std.AutoHashMap(db.SourceId, db.Memo([]const u8)).init(gpa),
            .active_stack = .empty,
            .stats = .{},
        };
    }

    fn memosFor(self: *@This(), comptime stage: Stage) *std.AutoHashMap(db.SourceId, db.Memo(stageValueType(stage))) {
        return switch (stage) {
            .parse => &self.parse_memos,
            .resolve => &self.resolve_memos,
            .typecheck => &self.type_memos,
            .lower => &self.lower_memos,
            .compile => &self.compile_memos,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.io) |io| {
            self.flushPersistentCaches(io) catch {};
        }

        var source_iter = self.sources.iterator();
        while (source_iter.next()) |entry| {
            self.gpa.free(entry.value_ptr.text);
            if (entry.value_ptr.source_path) |path| self.gpa.free(path);
        }
        self.sources.deinit();

        self.deinitStageMemos(.parse);
        self.deinitStageMemos(.resolve);
        self.deinitStageMemos(.typecheck);
        self.deinitStageMemos(.lower);
        self.deinitStageMemos(.compile);

        for (self.active_stack.items) |*frame| {
            frame.deps.deinit(self.gpa);
        }
        self.active_stack.deinit(self.gpa);

        for (self.cache_backings.items) |backing| self.gpa.free(backing);
        self.cache_backings.deinit(self.gpa);

        if (self.cache_dir_override) |dir| self.gpa.free(dir);
    }

    fn deinitStageMemos(self: *@This(), comptime stage: Stage) void {
        const T = stageValueType(stage);
        var iter = self.memosFor(stage).iterator();
        while (iter.next()) |entry| deinitMemo(T, entry.value_ptr, self.gpa);
        self.memosFor(stage).deinit();
    }

    pub fn setSource(self: *@This(), source_id: db.SourceId, text: []const u8) !void {
        try self.setSourceImpl(source_id, null, text);
    }

    pub fn setSourceFile(self: *@This(), source_id: db.SourceId, source_path: []const u8, text: []const u8) !void {
        try self.setSourceImpl(source_id, source_path, text);
    }

    fn setSourceImpl(self: *@This(), source_id: db.SourceId, source_path: ?[]const u8, text: []const u8) !void {
        if (self.sources.getPtr(source_id)) |existing| {
            if (std.mem.eql(u8, existing.text, text)) {
                self.stats.source_unchanged += 1;
                return;
            }

            const new_text = try self.gpa.dupe(u8, text);
            self.gpa.free(existing.text);
            existing.text = new_text;
            if (source_path) |path| {
                if (existing.source_path) |old_path| self.gpa.free(old_path);
                existing.source_path = try self.gpa.dupe(u8, path);
            }
            self.bumpRevision();
            existing.changed_at = self.revision;
            self.stats.source_sets += 1;
            self.tryLoadPersistentCache(source_id, existing);
            return;
        }

        const owned_text = try self.gpa.dupe(u8, text);
        const owned_path = if (source_path) |path| try self.gpa.dupe(u8, path) else null;
        self.bumpRevision();
        self.stats.source_sets += 1;
        try self.sources.put(source_id, .{
            .text = owned_text,
            .changed_at = self.revision,
            .source_path = owned_path,
        });

        const input = self.sources.getPtr(source_id).?;
        self.tryLoadPersistentCache(source_id, input);
    }

    pub fn sourceText(self: *const @This(), source_id: db.SourceId) ?[]const u8 {
        if (self.sources.get(source_id)) |input| return input.text;
        return null;
    }

    pub fn parsedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const ast.Ast {
        const memo = try self.ensureMemo(source_id, true, .parse);
        if (memo.value) |*parsed| return &parsed.ast;
        return null;
    }

    pub fn resolvedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const resolver.ResolvedAst {
        const memo = try self.ensureMemo(source_id, true, .resolve);
        if (memo.value) |*resolved| return resolved;
        return null;
    }

    pub fn typedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const analyze.AnalyzedAst {
        const memo = try self.ensureMemo(source_id, true, .typecheck);
        if (memo.value) |*typed| return typed;
        return null;
    }

    pub fn loweredProgram(self: *@This(), source_id: db.SourceId) db.DbError!?*const ir_mod.Program {
        const memo = try self.ensureMemo(source_id, true, .lower);
        if (memo.value) |*prog| return prog;
        return null;
    }

    pub fn compileBytes(self: *@This(), source_id: db.SourceId) db.DbError!?[]const u8 {
        const memo = try self.ensureMemo(source_id, true, .compile);
        return memo.value;
    }

    pub fn compileResult(self: *@This(), source_id: db.SourceId) db.DbError!CompileResult {
        const memo = try self.ensureMemo(source_id, true, .compile);
        return .{
            .bytes = memo.value,
            .diagnostics = memo.diagnostics.items,
        };
    }

    pub fn statsSnapshot(self: *const @This()) QueryStats {
        var snapshot = self.stats;
        snapshot.revision = self.revision;
        return snapshot;
    }

    pub fn resetStats(self: *@This()) void {
        self.stats = .{ .revision = self.revision };
    }

    pub fn changedAt(self: *@This(), stage: Stage, source_id: SourceId) ?db.Revision {
        return switch (stage) {
            .parse => if (self.parse_memos.get(source_id)) |memo| memo.changed_at else null,
            .resolve => if (self.resolve_memos.get(source_id)) |memo| memo.changed_at else null,
            .typecheck => if (self.type_memos.get(source_id)) |memo| memo.changed_at else null,
            .lower => if (self.lower_memos.get(source_id)) |memo| memo.changed_at else null,
            .compile => if (self.compile_memos.get(source_id)) |memo| memo.changed_at else null,
        };
    }

    fn cacheOptions(self: *const @This()) query_cache.CacheOptions {
        return .{ .cache_dir_override = self.cache_dir_override };
    }

    fn tryLoadPersistentCache(self: *@This(), source_id: db.SourceId, input: *SourceInput) void {
        if (!self.persistent_cache_enabled) return;
        if (self.io == null) return;
        const source_path = input.source_path orelse return;
        const io = self.io.?;

        var loaded = query_cache.load(io, self.gpa, self.cacheOptions(), source_path, input.text) catch return orelse return;
        defer if (loaded.backing.len > 0) loaded.deinit(self.gpa);

        var parse_ast: ?*const ast.Ast = null;
        self.loadPersistentStage(source_id, .parse, &loaded.parse, parse_ast);
        if (self.parse_memos.get(source_id)) |stored| {
            parse_ast = if (stored.value) |*p| &p.ast else null;
        }
        self.loadPersistentStage(source_id, .resolve, &loaded.resolve, parse_ast);
        self.loadPersistentStage(source_id, .typecheck, &loaded.typecheck, parse_ast);
        self.loadPersistentStage(source_id, .lower, &loaded.lower, parse_ast);
        self.loadPersistentStage(source_id, .compile, &loaded.compile, parse_ast);

        self.cache_backings.append(self.gpa, loaded.backing) catch return;
        loaded.backing = loaded.backing[0..0];
    }

    fn loadPersistentStage(
        self: *@This(),
        source_id: db.SourceId,
        comptime stage: Stage,
        loaded_stage: *query_cache.LoadedStage,
        parse_ast: ?*const ast.Ast,
    ) void {
        const T = stageValueType(stage);
        if (!loaded_stage.has_value or loaded_stage.bytes == null) return;

        var value: ?T = switch (stage) {
            .compile => self.gpa.dupe(u8, loaded_stage.bytes.?) catch return,
            .typecheck => query_cache.deserializeTyped(self.gpa, loaded_stage.bytes.?, parse_ast orelse return) catch return,
            else => deserializeStageValue(stage, self.gpa, loaded_stage.bytes.?, null) catch return,
        };

        var memo = db.makeMemo(T, value, loaded_stage.diagnostics);
        loaded_stage.diagnostics = .empty;
        value = null;

        memo.deps = if (stage == .parse) (self.depForSource(source_id) catch {
            deinitMemo(T, &memo, self.gpa);
            return;
        }) else (self.depForStage(source_id, prevStage(stage)) catch {
            deinitMemo(T, &memo, self.gpa);
            return;
        });
        memo.verified_at = self.revision;
        memo.changed_at = self.revision;

        const old = self.memosFor(stage).fetchPut(source_id, memo) catch {
            deinitMemo(T, &memo, self.gpa);
            return;
        };
        if (old) |kv| {
            var old_memo = kv.value;
            deinitMemo(T, &old_memo, self.gpa);
        }
    }

    fn depForSource(self: *@This(), source_id: db.SourceId) std.mem.Allocator.Error!std.ArrayList(db.Dependency) {
        var list = try std.ArrayList(db.Dependency).initCapacity(self.gpa, 1);
        try list.append(self.gpa, .{ .source = source_id });
        return list;
    }

    fn depForStage(self: *@This(), source_id: db.SourceId, stage: Stage) std.mem.Allocator.Error!std.ArrayList(db.Dependency) {
        var list = try std.ArrayList(db.Dependency).initCapacity(self.gpa, 1);
        try list.append(self.gpa, .{ .query = queryFor(stage, source_id) });
        return list;
    }

    fn snapshotStage(self: *@This(), source_id: db.SourceId, comptime stage: Stage, gpa: std.mem.Allocator) (error{OutOfMemory}!query_cache.StageSnapshot) {
        return if (self.memosFor(stage).get(source_id)) |memo| .{
            .changed_at = memo.changed_at,
            .has_value = memo.value != null,
            .diagnostics = memo.diagnostics.items,
            .bytes = if (memo.value) |*v|
                if (comptime stage == .compile) try gpa.dupe(u8, v.*)
                else try serializeStageValue(stage, gpa, v)
            else
                null,
        } else .{ .changed_at = 0, .has_value = false, .diagnostics = &.{}, .bytes = null };
    }

    fn serializeStageValue(comptime stage: Stage, gpa: std.mem.Allocator, v: anytype) error{OutOfMemory}![]u8 {
        return switch (stage) {
            .parse => query_cache.serializeParsed(gpa, @ptrCast(v)),
            .resolve => query_cache.serializeResolved(gpa, @ptrCast(v)),
            .typecheck => query_cache.serializeTyped(gpa, @ptrCast(v)),
            else => query_cache.serializeProgram(gpa, @ptrCast(v)),
        };
    }

    fn flushPersistentCaches(self: *@This(), io: std.Io) !void {
        if (!self.persistent_cache_enabled) return;

        {
            var iter = self.sources.iterator();
            if (iter.next()) |entry| {
                const source = entry.value_ptr.*;
                if (source.source_path) |path|
                    query_cache.sweepStaleCaches(io, self.gpa, self.cacheOptions(), path) catch {};
            }
        }

        var iter = self.sources.iterator();
        while (iter.next()) |entry| {
            const source_id = entry.key_ptr.*;
            const source = entry.value_ptr.*;
            const source_path = source.source_path orelse continue;
            if (self.compile_memos.get(source_id) == null) continue;

            var snaps: [5]query_cache.StageSnapshot = undefined;
            snaps[0] = try self.snapshotStage(source_id, .parse, self.gpa);
            snaps[1] = try self.snapshotStage(source_id, .resolve, self.gpa);
            snaps[2] = try self.snapshotStage(source_id, .typecheck, self.gpa);
            snaps[3] = try self.snapshotStage(source_id, .lower, self.gpa);
            snaps[4] = try self.snapshotStage(source_id, .compile, self.gpa);
            errdefer for (&snaps) |s| if (s.bytes) |b| self.gpa.free(b);

            try query_cache.save(io, self.gpa, self.cacheOptions(), .{
                .source_path = source_path,
                .source_text = source.text,
                .parse = snaps[0],
                .resolve = snaps[1],
                .typecheck = snaps[2],
                .lower = snaps[3],
                .compile = snaps[4],
            });

            for (&snaps) |s| if (s.bytes) |b| self.gpa.free(b);
        }
    }

    fn bumpRevision(self: *@This()) void {
        self.revision += 1;
    }

    fn queryFor(kind: db.Stage, source_id: db.SourceId) db.QueryKey {
        return .{ .kind = kind, .source_id = source_id };
    }

    fn ensureMemo(
        self: *@This(),
        source_id: db.SourceId,
        track_dependency: bool,
        comptime stage: Stage,
    ) (db.DbError || std.mem.Allocator.Error)!*db.Memo(stageValueType(stage)) {
        const T = stageValueType(stage);
        const memos = self.memosFor(stage);
        const backdate = comptime stage == .compile;
        const query_key = queryFor(stage, source_id);
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (memos.getPtr(source_id)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                self.stats.hit(stage);
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                self.stats.hit(stage);
                return memo;
            }

            self.stats.recompute(stage);
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            var fresh = try self.computeStage(source_id, stage);
            errdefer deinitMemo(T, &fresh, self.gpa);
            const frame = self.endQuery();

            const old_changed_at = memo.changed_at;
            const same_value = if (backdate) db.valuesEqual(memo.value, fresh.value) else false;
            const same_diagnostics = if (backdate) db.diagnosticsEqual(memo.diagnostics.items, fresh.diagnostics.items) else false;

            deinitMemo(T, memo, self.gpa);
            memo.value = fresh.value;
            memo.diagnostics = fresh.diagnostics;
            memo.deps = frame.deps;
            memo.verified_at = self.revision;
            memo.changed_at = if (backdate and same_value and same_diagnostics) old_changed_at else self.revision;
            return memo;
        }

        self.stats.recompute(stage);
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        var fresh = try self.computeStage(source_id, stage);
        errdefer deinitMemo(T, &fresh, self.gpa);
        const frame = self.endQuery();
        fresh.deps = frame.deps;
        fresh.verified_at = self.revision;
        fresh.changed_at = self.revision;

        const old = try memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            deinitMemo(T, &old_memo, self.gpa);
        }
        return memos.getPtr(source_id).?;
    }

    fn computeStage(self: *@This(), source_id: db.SourceId, comptime stage: Stage) (db.DbError || std.mem.Allocator.Error)!db.Memo(stageValueType(stage)) {
        return switch (stage) {
            .parse => try parser.computeParse(try self.getSourceText(source_id), self.gpa),
            .resolve => try resolver.computeResolve(try self.ensureMemo(source_id, true, .parse), self.gpa),
            .typecheck => try analyze.computeAnalyze(
                try self.ensureMemo(source_id, true, .resolve),
                try self.ensureMemo(source_id, true, .parse),
                self.gpa,
            ),
            .lower => try ir_mod.computeLower(try self.ensureMemo(source_id, true, .typecheck), self.gpa),
            .compile => try codegen.computeCompile(try self.ensureMemo(source_id, true, .lower), self.gpa),
        };
    }

    fn dependenciesUnchanged(self: *@This(), deps: []const db.Dependency, verified_at: db.Revision) db.DbError!bool {
        for (deps) |dep| {
            self.stats.dependency_checks += 1;
            switch (dep) {
                .source => |source_id| {
                    const input = self.sources.get(source_id) orelse return error.SourceNotFound;
                    if (input.changed_at > verified_at) {
                        self.stats.dependency_invalidations += 1;
                        return false;
                    }
                },
                .query => |query_key| {
                    if (try self.queryChangedAfter(query_key, verified_at)) {
                        self.stats.dependency_invalidations += 1;
                        return false;
                    }
                },
            }
        }
        return true;
    }

    fn queryChangedAfter(self: *@This(), key: db.QueryKey, revision: db.Revision) db.DbError!bool {
        return switch (key.kind) {
            .parse => (try self.ensureMemo(key.source_id, false, .parse)).changed_at > revision,
            .resolve => (try self.ensureMemo(key.source_id, false, .resolve)).changed_at > revision,
            .typecheck => (try self.ensureMemo(key.source_id, false, .typecheck)).changed_at > revision,
            .lower => (try self.ensureMemo(key.source_id, false, .lower)).changed_at > revision,
            .compile => (try self.ensureMemo(key.source_id, false, .compile)).changed_at > revision,
        };
    }

    fn getSourceText(self: *@This(), source_id: db.SourceId) db.DbError![]const u8 {
        try self.noteSourceDependency(source_id);
        const input = self.sources.get(source_id) orelse return error.SourceNotFound;
        return input.text;
    }

    fn beginQuery(self: *@This(), key: db.QueryKey) db.DbError!void {
        for (self.active_stack.items) |active| {
            if (active.key.kind == key.kind and active.key.source_id == key.source_id) return error.QueryCycle;
        }

        var deps = try std.ArrayList(db.Dependency).initCapacity(self.gpa, 8);
        errdefer deps.deinit(self.gpa);

        try self.active_stack.append(self.gpa, .{
            .key = key,
            .deps = deps,
        });
    }

    fn endQuery(self: *@This()) ActiveQuery {
        std.debug.assert(self.active_stack.items.len > 0);
        return self.active_stack.pop().?;
    }

    fn abortQuery(self: *@This()) void {
        std.debug.assert(self.active_stack.items.len > 0);
        var frame = self.active_stack.pop().?;
        frame.deps.deinit(self.gpa);
    }

    fn noteSourceDependency(self: *@This(), source_id: db.SourceId) std.mem.Allocator.Error!void {
        if (self.active_stack.items.len == 0) return;
        const top_idx = self.active_stack.items.len - 1;
        try db.appendDependencyUnique(&self.active_stack.items[top_idx].deps, self.gpa, .{ .source = source_id });
    }

    fn noteQueryDependency(self: *@This(), key: db.QueryKey) std.mem.Allocator.Error!void {
        if (self.active_stack.items.len == 0) return;
        const top_idx = self.active_stack.items.len - 1;
        try db.appendDependencyUnique(&self.active_stack.items[top_idx].deps, self.gpa, .{ .query = key });
    }
};
