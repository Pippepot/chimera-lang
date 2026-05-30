const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const typecheck = @import("typecheck.zig");
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

pub fn appendQueryDiagnostics(out: *std.ArrayList(u8), gpa: std.mem.Allocator, stats: QueryStats) !void {
    try out.appendSlice(gpa, "; query diagnostics:\n");
    try out.print(gpa, ";   revision: {d}\n", .{stats.revision});
    try out.print(gpa, ";   source_sets: {d}\n", .{stats.source_sets});
    try out.print(gpa, ";   source_unchanged: {d}\n", .{stats.source_unchanged});
    try out.print(gpa, ";   parse: hits={d} recomputes={d}\n", .{ stats.parse_hits, stats.parse_recomputes });
    try out.print(gpa, ";   resolve: hits={d} recomputes={d}\n", .{ stats.resolve_hits, stats.resolve_recomputes });
    try out.print(gpa, ";   type: hits={d} recomputes={d}\n", .{ stats.type_hits, stats.type_recomputes });
    try out.print(gpa, ";   lower: hits={d} recomputes={d}\n", .{ stats.lower_hits, stats.lower_recomputes });
    try out.print(gpa, ";   compile: hits={d} recomputes={d}\n", .{ stats.compile_hits, stats.compile_recomputes });
    try out.print(gpa, ";   dependencies: checks={d} invalidations={d}\n", .{ stats.dependency_checks, stats.dependency_invalidations });
}

const SourceInput = struct {
    text: []u8,
    changed_at: db.Revision,
    source_path: ?[]u8 = null,
};

const ActiveQuery = struct {
    key: db.QueryKey,
    deps: std.ArrayList(db.Dependency),
};

/// Maps Stage enum to the Zig type stored in the memo's `.value` field.
fn stageValueType(comptime stage: Stage) type {
    return switch (stage) {
        .parse => parser.ParsedAst,
        .resolve => resolver.ResolvedAst,
        .typecheck => typecheck.TypedAst,
        .lower => ir_mod.Program,
        .compile => []const u8,
    };
}

fn freeMemoValue(comptime T: type, value: *?T, gpa: std.mem.Allocator) void {
    if (value.*) |*v| {
        if (comptime T == parser.ParsedAst) {
            v.deinit(gpa);
        } else if (comptime T == resolver.ResolvedAst) {
            v.deinit(gpa);
        } else if (comptime T == typecheck.TypedAst) {
            v.deinit();
        } else if (comptime T == ir_mod.Program) {
            v.deinit(gpa);
        } else if (comptime T == []const u8) {
            gpa.free(v.*);
        }
    }
}

fn deinitMemo(comptime T: type, memo: *db.Memo(T), gpa: std.mem.Allocator) void {
    freeMemoValue(T, &memo.value, gpa);
    memo.diagnostics.deinit(gpa);
    memo.deps.deinit(gpa);
}

fn recordHit(stats: *db.QueryStats, comptime stage: Stage) void {
    switch (stage) {
        .parse => stats.parse_hits += 1,
        .resolve => stats.resolve_hits += 1,
        .typecheck => stats.type_hits += 1,
        .lower => stats.lower_hits += 1,
        .compile => stats.compile_hits += 1,
    }
}

fn recordRecompute(stats: *db.QueryStats, comptime stage: Stage) void {
    switch (stage) {
        .parse => stats.parse_recomputes += 1,
        .resolve => stats.resolve_recomputes += 1,
        .typecheck => stats.type_recomputes += 1,
        .lower => stats.lower_recomputes += 1,
        .compile => stats.compile_recomputes += 1,
    }
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
    type_memos: std.AutoHashMap(db.SourceId, db.Memo(typecheck.TypedAst)),
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
            .type_memos = std.AutoHashMap(db.SourceId, db.Memo(typecheck.TypedAst)).init(gpa),
            .lower_memos = std.AutoHashMap(db.SourceId, db.Memo(ir_mod.Program)).init(gpa),
            .compile_memos = std.AutoHashMap(db.SourceId, db.Memo([]const u8)).init(gpa),
            .active_stack = .empty,
            .stats = .{},
        };
    }

    /// Returns the memo HashMap for a given stage. Used by ensureMemoImpl and deinit.
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

        {
            var iter = self.parse_memos.iterator();
            while (iter.next()) |entry| deinitMemo(parser.ParsedAst, entry.value_ptr, self.gpa);
            self.parse_memos.deinit();
        }
        {
            var iter = self.resolve_memos.iterator();
            while (iter.next()) |entry| deinitMemo(resolver.ResolvedAst, entry.value_ptr, self.gpa);
            self.resolve_memos.deinit();
        }
        {
            var iter = self.type_memos.iterator();
            while (iter.next()) |entry| deinitMemo(typecheck.TypedAst, entry.value_ptr, self.gpa);
            self.type_memos.deinit();
        }
        {
            var iter = self.lower_memos.iterator();
            while (iter.next()) |entry| deinitMemo(ir_mod.Program, entry.value_ptr, self.gpa);
            self.lower_memos.deinit();
        }
        {
            var iter = self.compile_memos.iterator();
            while (iter.next()) |entry| deinitMemo([]const u8, entry.value_ptr, self.gpa);
            self.compile_memos.deinit();
        }

        for (self.active_stack.items) |*frame| {
            frame.deps.deinit(self.gpa);
        }
        self.active_stack.deinit(self.gpa);

        for (self.cache_backings.items) |backing| self.gpa.free(backing);
        self.cache_backings.deinit(self.gpa);

        if (self.cache_dir_override) |dir| self.gpa.free(dir);
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
        const memo = try self.ensureParseMemo(source_id, true);
        if (memo.value) |*parsed| return &parsed.ast;
        return null;
    }

    pub fn resolvedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const resolver.ResolvedAst {
        const memo = try self.ensureResolveMemo(source_id, true);
        if (memo.value) |*resolved| return resolved;
        return null;
    }

    pub fn typedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const typecheck.TypedAst {
        const memo = try self.ensureTypeMemo(source_id, true);
        if (memo.value) |*typed| return typed;
        return null;
    }

    pub fn loweredProgram(self: *@This(), source_id: db.SourceId) db.DbError!?*const ir_mod.Program {
        const memo = try self.ensureLowerMemo(source_id, true);
        if (memo.value) |*prog| return prog;
        return null;
    }

    pub fn compileBytes(self: *@This(), source_id: db.SourceId) db.DbError!?[]const u8 {
        const memo = try self.ensureCompileMemo(source_id, true);
        return memo.value;
    }

    pub fn compileResult(self: *@This(), source_id: db.SourceId) db.DbError!CompileResult {
        const memo = try self.ensureCompileMemo(source_id, true);
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

    pub fn changedAt(self: *const @This(), stage: Stage, source_id: SourceId) ?db.Revision {
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

    /// Load pre-computed stage values from the on-disk persistent cache.
    /// Each block follows the same pattern: deserialize → makeMemo → take diagnostics →
    /// create deps → set timestamps → register.  The typecheck stage is the only one
    /// that additionally needs the parsed AST (from the parse memo) during deserialization.
    fn tryLoadPersistentCache(self: *@This(), source_id: db.SourceId, input: *SourceInput) void {
        if (!self.persistent_cache_enabled) return;
        if (self.io == null) return;
        const source_path = input.source_path orelse return;
        const io = self.io.?;

        var loaded = query_cache.load(io, self.gpa, self.cacheOptions(), source_path, input.text) catch return orelse return;
        errdefer loaded.deinit(self.gpa);

        // ── 1. Parse memo ──
        const parse_value = if (loaded.parse.has_value and loaded.parse.bytes != null)
            query_cache.deserializeParsed(self.gpa, loaded.parse.bytes.?) catch return
        else
            null;
        var parse_memo = db.makeMemo(parser.ParsedAst, parse_value, loaded.parse.diagnostics);
        loaded.parse.diagnostics = .empty;
        {
            var pd = std.ArrayList(db.Dependency).initCapacity(self.gpa, 1) catch return;
            pd.append(self.gpa, .{ .source = source_id }) catch return;
            parse_memo.deps = pd;
        }
        parse_memo.verified_at = self.revision;
        parse_memo.changed_at = self.revision;

        // ── 2. Resolve memo ──
        const resolve_value = if (loaded.resolve.has_value and loaded.resolve.bytes != null)
            query_cache.deserializeResolved(self.gpa, loaded.resolve.bytes.?) catch return
        else
            null;
        var resolve_memo = db.makeMemo(resolver.ResolvedAst, resolve_value, loaded.resolve.diagnostics);
        loaded.resolve.diagnostics = .empty;
        {
            var rd = std.ArrayList(db.Dependency).initCapacity(self.gpa, 1) catch return;
            rd.append(self.gpa, .{ .query = queryFor(.parse, source_id) }) catch return;
            resolve_memo.deps = rd;
        }
        resolve_memo.verified_at = self.revision;
        resolve_memo.changed_at = self.revision;

        // ── 3. Typecheck memo (needs parse_ast from deserialized parse memo) ──
        const parse_ast = if (parse_memo.value) |*p| &p.ast else null;
        const type_value = if (loaded.typecheck.has_value and loaded.typecheck.bytes != null and parse_ast != null)
            query_cache.deserializeTyped(self.gpa, loaded.typecheck.bytes.?, parse_ast.?) catch return
        else
            null;
        var type_memo = db.makeMemo(typecheck.TypedAst, type_value, loaded.typecheck.diagnostics);
        loaded.typecheck.diagnostics = .empty;
        {
            var td = std.ArrayList(db.Dependency).initCapacity(self.gpa, 1) catch return;
            td.append(self.gpa, .{ .query = queryFor(.resolve, source_id) }) catch return;
            type_memo.deps = td;
        }
        type_memo.verified_at = self.revision;
        type_memo.changed_at = self.revision;

        // ── 4. Lower memo ──
        const lower_value = if (loaded.lower.has_value and loaded.lower.bytes != null)
            query_cache.deserializeProgram(self.gpa, loaded.lower.bytes.?) catch return
        else
            null;
        var lower_memo = db.makeMemo(ir_mod.Program, lower_value, loaded.lower.diagnostics);
        loaded.lower.diagnostics = .empty;
        {
            var ld = std.ArrayList(db.Dependency).initCapacity(self.gpa, 1) catch return;
            ld.append(self.gpa, .{ .query = queryFor(.typecheck, source_id) }) catch return;
            lower_memo.deps = ld;
        }
        lower_memo.verified_at = self.revision;
        lower_memo.changed_at = self.revision;

        // ── 5. Compile memo ──
        const compile_bytes = if (loaded.compile.bytes) |bytes| self.gpa.dupe(u8, bytes) catch return else null;
        var compile_memo = db.makeMemo([]const u8, compile_bytes, loaded.compile.diagnostics);
        loaded.compile.diagnostics = .empty;
        {
            var cd = std.ArrayList(db.Dependency).initCapacity(self.gpa, 1) catch return;
            cd.append(self.gpa, .{ .query = queryFor(.lower, source_id) }) catch return;
            compile_memo.deps = cd;
        }
        compile_memo.verified_at = self.revision;
        compile_memo.changed_at = self.revision;

        // ── Retain backing (diagnostics were moved out) ──
        self.cache_backings.append(self.gpa, loaded.backing) catch return;
        loaded.backing = loaded.backing[0..0];

        _ = self.parse_memos.fetchPut(source_id, parse_memo) catch return;
        _ = self.resolve_memos.fetchPut(source_id, resolve_memo) catch return;
        _ = self.type_memos.fetchPut(source_id, type_memo) catch return;
        _ = self.lower_memos.fetchPut(source_id, lower_memo) catch return;
        _ = self.compile_memos.fetchPut(source_id, compile_memo) catch return;
    }

    /// Serialises one stage's memo value (and diagnostics) for persistent cache storage.
    /// Each stage delegates to its dedicated `query_cache.serializeXxx` function.
    fn snapshotStage(self: *@This(), source_id: db.SourceId, comptime stage: Stage, gpa: std.mem.Allocator) (error{OutOfMemory}!query_cache.StageSnapshot) {
        _ = stageValueType(stage);
        return if (self.memosFor(stage).get(source_id)) |memo| .{
            .changed_at = memo.changed_at,
            .has_value = memo.value != null,
            .diagnostics = memo.diagnostics.items,
            .bytes = if (memo.value) |*v|
                if (comptime stage == .compile)
                    v.*
                else if (comptime stage == .parse)
                    try query_cache.serializeParsed(gpa, @as(*const parser.ParsedAst, @ptrCast(v)))
                else if (comptime stage == .resolve)
                    try query_cache.serializeResolved(gpa, @as(*const resolver.ResolvedAst, @ptrCast(v)))
                else if (comptime stage == .typecheck)
                    try query_cache.serializeTyped(gpa, @as(*const typecheck.TypedAst, @ptrCast(v)))
                else
                    try query_cache.serializeProgram(gpa, @as(*const ir_mod.Program, @ptrCast(v)))
            else
                null,
        } else .{ .changed_at = 0, .has_value = false, .diagnostics = &.{}, .bytes = null };
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

            const parse_snap = try self.snapshotStage(source_id, .parse, self.gpa);
            errdefer if (parse_snap.bytes) |b| self.gpa.free(b);
            const resolve_snap = try self.snapshotStage(source_id, .resolve, self.gpa);
            errdefer if (resolve_snap.bytes) |b| self.gpa.free(b);
            const type_snap = try self.snapshotStage(source_id, .typecheck, self.gpa);
            errdefer if (type_snap.bytes) |b| self.gpa.free(b);
            const lower_snap = try self.snapshotStage(source_id, .lower, self.gpa);
            errdefer if (lower_snap.bytes) |b| self.gpa.free(b);
            const compile_snap = try self.snapshotStage(source_id, .compile, self.gpa);

            try query_cache.save(io, self.gpa, self.cacheOptions(), .{
                .source_path = source_path,
                .source_text = source.text,
                .parse = parse_snap,
                .resolve = resolve_snap,
                .typecheck = type_snap,
                .lower = lower_snap,
                .compile = compile_snap,
            });

            if (parse_snap.bytes) |b| self.gpa.free(b);
            if (resolve_snap.bytes) |b| self.gpa.free(b);
            if (type_snap.bytes) |b| self.gpa.free(b);
            if (lower_snap.bytes) |b| self.gpa.free(b);
        }
    }

    fn bumpRevision(self: *@This()) void {
        self.revision += 1;
    }

    fn queryFor(kind: db.Stage, source_id: db.SourceId) db.QueryKey {
        return .{ .kind = kind, .source_id = source_id };
    }

    /// Generic memo ensure logic.  `stage` determines the value type, the memo
    /// HashMap, and the backdate flag (true only for .compile).  `computeFn` is
    /// the stage-specific function that produces a fresh memo.
    fn ensureMemo(
        self: *@This(),
        source_id: db.SourceId,
        track_dependency: bool,
        comptime stage: Stage,
        comptime computeFn: fn (*@This(), db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(stageValueType(stage)),
    ) (db.DbError || std.mem.Allocator.Error)!*db.Memo(stageValueType(stage)) {
        const T = stageValueType(stage);
        const memos = self.memosFor(stage);
        const backdate = comptime stage == .compile;
        const query_key = queryFor(stage, source_id);
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (memos.getPtr(source_id)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                recordHit(&self.stats, stage);
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                recordHit(&self.stats, stage);
                return memo;
            }

            recordRecompute(&self.stats, stage);
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            var fresh = try computeFn(self, source_id);
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

        recordRecompute(&self.stats, stage);
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        var fresh = try computeFn(self, source_id);
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

    fn ensureParseMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) (db.DbError || std.mem.Allocator.Error)!*db.Memo(parser.ParsedAst) {
        return self.ensureMemo(source_id, track_dependency, .parse, struct {
            fn compute(qdb: *QueryDb, sid: db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(parser.ParsedAst) {
                return parser.computeParse(try qdb.getSourceText(sid), qdb.gpa);
            }
        }.compute);
    }

    fn ensureResolveMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) (db.DbError || std.mem.Allocator.Error)!*db.Memo(resolver.ResolvedAst) {
        return self.ensureMemo(source_id, track_dependency, .resolve, struct {
            fn compute(qdb: *QueryDb, sid: db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(resolver.ResolvedAst) {
                const parse_memo = try qdb.ensureParseMemo(sid, true);
                return resolver.computeResolve(parse_memo, qdb.gpa);
            }
        }.compute);
    }

    fn ensureTypeMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) (db.DbError || std.mem.Allocator.Error)!*db.Memo(typecheck.TypedAst) {
        return self.ensureMemo(source_id, track_dependency, .typecheck, struct {
            fn compute(qdb: *QueryDb, sid: db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(typecheck.TypedAst) {
                const resolve_memo = try qdb.ensureResolveMemo(sid, true);
                const parse_memo = try qdb.ensureParseMemo(sid, true);
                return typecheck.computeType(resolve_memo, parse_memo, qdb.gpa);
            }
        }.compute);
    }

    fn ensureLowerMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) (db.DbError || std.mem.Allocator.Error)!*db.Memo(ir_mod.Program) {
        return self.ensureMemo(source_id, track_dependency, .lower, struct {
            fn compute(qdb: *QueryDb, sid: db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(ir_mod.Program) {
                const type_memo = try qdb.ensureTypeMemo(sid, true);
                return ir_mod.computeLower(type_memo, qdb.gpa);
            }
        }.compute);
    }

    fn ensureCompileMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) (db.DbError || std.mem.Allocator.Error)!*db.Memo([]const u8) {
        return self.ensureMemo(source_id, track_dependency, .compile, struct {
            fn compute(qdb: *QueryDb, sid: db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo([]const u8) {
                const lower_memo = try qdb.ensureLowerMemo(sid, true);
                return codegen.computeCompile(lower_memo, qdb.gpa);
            }
        }.compute);
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
            .parse => blk: {
                const memo = try self.ensureParseMemo(key.source_id, false);
                break :blk memo.changed_at > revision;
            },
            .resolve => blk: {
                const memo = try self.ensureResolveMemo(key.source_id, false);
                break :blk memo.changed_at > revision;
            },
            .typecheck => blk: {
                const memo = try self.ensureTypeMemo(key.source_id, false);
                break :blk memo.changed_at > revision;
            },
            .lower => blk: {
                const memo = try self.ensureLowerMemo(key.source_id, false);
                break :blk memo.changed_at > revision;
            },
            .compile => blk: {
                const memo = try self.ensureCompileMemo(key.source_id, false);
                break :blk memo.changed_at > revision;
            },
        };
    }

    fn getSourceText(self: *@This(), source_id: db.SourceId) db.DbError![]const u8 {
        try self.noteSourceDependency(source_id);
        const input = self.sources.get(source_id) orelse return error.SourceNotFound;
        return input.text;
    }

    fn beginQuery(self: *@This(), key: db.QueryKey) db.DbError!void {
        for (self.active_stack.items) |active| {
            if (db.queryKeyEql(active.key, key)) return error.QueryCycle;
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
