const std = @import("std");
const db = @import("db.zig");
const parser = @import("parser.zig");
const typecheck = @import("typecheck.zig");
const ir_mod = @import("ir.zig");
const codegen = @import("codegen.zig");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const AstNode = ast.AstNode;
const Diagnostic = diagnostics.Diagnostic;

pub const SourceId = db.SourceId;
pub const QueryStats = db.QueryStats;
pub const Stage = db.Stage;
pub const CompileResult = db.CompileResult;
pub const QueryError = db.QueryError;

const SourceInput = struct {
    text: []u8,
    changed_at: db.Revision,
};

const ActiveQuery = struct {
    key: db.QueryKey,
    deps: std.ArrayList(db.Dependency),
};

pub const QueryDb = struct {
    gpa: std.mem.Allocator,
    revision: db.Revision,
    sources: std.AutoHashMap(db.SourceId, SourceInput),
    parse_memos: std.AutoHashMap(db.SourceId, parser.ParseMemo),
    type_memos: std.AutoHashMap(db.SourceId, typecheck.TypeMemo),
    lower_memos: std.AutoHashMap(db.SourceId, ir_mod.LowerMemo),
    compile_memos: std.AutoHashMap(db.SourceId, codegen.CompileMemo),
    active_stack: std.ArrayList(ActiveQuery),
    stats: db.QueryStats,

    pub fn init(gpa: std.mem.Allocator) QueryDb {
        return .{
            .gpa = gpa,
            .revision = 0,
            .sources = std.AutoHashMap(db.SourceId, SourceInput).init(gpa),
            .parse_memos = std.AutoHashMap(db.SourceId, parser.ParseMemo).init(gpa),
            .type_memos = std.AutoHashMap(db.SourceId, typecheck.TypeMemo).init(gpa),
            .lower_memos = std.AutoHashMap(db.SourceId, ir_mod.LowerMemo).init(gpa),
            .compile_memos = std.AutoHashMap(db.SourceId, codegen.CompileMemo).init(gpa),
            .active_stack = .empty,
            .stats = .{},
        };
    }

    pub fn deinit(self: *@This()) void {
        var source_iter = self.sources.iterator();
        while (source_iter.next()) |entry| {
            self.gpa.free(entry.value_ptr.text);
        }
        self.sources.deinit();

        var parse_iter = self.parse_memos.iterator();
        while (parse_iter.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
        }
        self.parse_memos.deinit();

        var type_iter = self.type_memos.iterator();
        while (type_iter.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
        }
        self.type_memos.deinit();

        var lower_iter = self.lower_memos.iterator();
        while (lower_iter.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
        }
        self.lower_memos.deinit();

        var compile_iter = self.compile_memos.iterator();
        while (compile_iter.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
        }
        self.compile_memos.deinit();

        for (self.active_stack.items) |*frame| {
            frame.deps.deinit(self.gpa);
        }
        self.active_stack.deinit(self.gpa);
    }

    pub fn setSource(self: *@This(), source_id: db.SourceId, text: []const u8) !void {
        if (self.sources.getPtr(source_id)) |existing| {
            if (std.mem.eql(u8, existing.text, text)) {
                self.stats.source_unchanged += 1;
                return;
            }

            const new_text = try self.gpa.dupe(u8, text);
            self.gpa.free(existing.text);
            existing.text = new_text;
            self.bumpRevision();
            existing.changed_at = self.revision;
            self.stats.source_sets += 1;
            return;
        }

        const owned_text = try self.gpa.dupe(u8, text);
        self.bumpRevision();
        self.stats.source_sets += 1;
        try self.sources.put(source_id, .{
            .text = owned_text,
            .changed_at = self.revision,
        });
    }

    pub fn sourceText(self: *const @This(), source_id: db.SourceId) ?[]const u8 {
        if (self.sources.get(source_id)) |input| return input.text;
        return null;
    }

    pub fn parsedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const AstNode {
        const memo = try self.ensureParseMemo(source_id, true);
        if (memo.value) |*parsed| return parsed.root;
        return null;
    }

    pub fn loweredProgram(self: *@This(), source_id: db.SourceId) db.DbError!?*const ir_mod.Program {
        const memo = try self.ensureLowerMemo(source_id, true);
        if (memo.value) |*prog| return prog;
        return null;
    }

    pub fn typedAst(self: *@This(), source_id: db.SourceId) db.DbError!?*const typecheck.TypedAst {
        const memo = try self.ensureTypeMemo(source_id, true);
        if (memo.value) |*typed| return typed;
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
            .typecheck => if (self.type_memos.get(source_id)) |memo| memo.changed_at else null,
            .lower => if (self.lower_memos.get(source_id)) |memo| memo.changed_at else null,
            .compile => if (self.compile_memos.get(source_id)) |memo| memo.changed_at else null,
        };
    }

    fn bumpRevision(self: *@This()) void {
        self.revision += 1;
    }

    fn queryFor(kind: db.QueryKind, source_id: db.SourceId) db.QueryKey {
        return .{ .kind = kind, .source_id = source_id };
    }

    fn ensureParseMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) db.DbError!*parser.ParseMemo {
        const query_key = queryFor(.parse, source_id);
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (self.parse_memos.getPtr(source_id)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                self.stats.parse_hits += 1;
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                self.stats.parse_hits += 1;
                return memo;
            }

            self.stats.parse_recomputes += 1;
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            const source = try self.getSourceText(source_id);
            var fresh = try parser.computeParse(source, self.gpa);
            errdefer fresh.deinit(self.gpa);
            const frame = self.endQuery();

            if (memo.value) |*parsed| parsed.deinit();
            memo.diagnostics.deinit(self.gpa);
            memo.deps.deinit(self.gpa);
            memo.value = fresh.value;
            memo.diagnostics = fresh.diagnostics;
            memo.deps = frame.deps;
            memo.verified_at = self.revision;
            memo.changed_at = self.revision;
            return memo;
        }

        self.stats.parse_recomputes += 1;
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        const source = try self.getSourceText(source_id);
        var fresh = try parser.computeParse(source, self.gpa);
        errdefer fresh.deinit(self.gpa);
        const frame = self.endQuery();
        fresh.deps = frame.deps;
        fresh.verified_at = self.revision;
        fresh.changed_at = self.revision;

        const old = try self.parse_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.parse_memos.getPtr(source_id).?;
    }

    fn ensureTypeMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) db.DbError!*typecheck.TypeMemo {
        const query_key = queryFor(.typecheck, source_id);
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (self.type_memos.getPtr(source_id)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                self.stats.type_hits += 1;
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                self.stats.type_hits += 1;
                return memo;
            }

            self.stats.type_recomputes += 1;
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            const parse_memo = try self.ensureParseMemo(source_id, true);
            var fresh = try typecheck.computeType(parse_memo, self.gpa);
            errdefer fresh.deinit(self.gpa);
            const frame = self.endQuery();

            if (memo.value) |*typed| typed.deinit();
            memo.diagnostics.deinit(self.gpa);
            memo.deps.deinit(self.gpa);
            memo.value = fresh.value;
            memo.diagnostics = fresh.diagnostics;
            memo.deps = frame.deps;
            memo.verified_at = self.revision;
            memo.changed_at = self.revision;
            return memo;
        }

        self.stats.type_recomputes += 1;
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        const parse_memo = try self.ensureParseMemo(source_id, true);
        var fresh = try typecheck.computeType(parse_memo, self.gpa);
        errdefer fresh.deinit(self.gpa);
        const frame = self.endQuery();
        fresh.deps = frame.deps;
        fresh.verified_at = self.revision;
        fresh.changed_at = self.revision;

        const old = try self.type_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.type_memos.getPtr(source_id).?;
    }

    fn ensureLowerMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) db.DbError!*ir_mod.LowerMemo {
        const query_key = queryFor(.lower, source_id);
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (self.lower_memos.getPtr(source_id)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                self.stats.lower_hits += 1;
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                self.stats.lower_hits += 1;
                return memo;
            }

            self.stats.lower_recomputes += 1;
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            const type_memo = try self.ensureTypeMemo(source_id, true);
            const parse_memo = try self.ensureParseMemo(source_id, true);
            var fresh = try ir_mod.computeLower(type_memo, parse_memo, self.gpa);
            errdefer fresh.deinit(self.gpa);
            const frame = self.endQuery();

            if (memo.value) |*program| program.deinit(self.gpa);
            memo.diagnostics.deinit(self.gpa);
            memo.deps.deinit(self.gpa);
            memo.value = fresh.value;
            memo.diagnostics = fresh.diagnostics;
            memo.deps = frame.deps;
            memo.verified_at = self.revision;
            memo.changed_at = self.revision;
            return memo;
        }

        self.stats.lower_recomputes += 1;
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        const type_memo = try self.ensureTypeMemo(source_id, true);
        const parse_memo = try self.ensureParseMemo(source_id, true);
        var fresh = try ir_mod.computeLower(type_memo, parse_memo, self.gpa);
        errdefer fresh.deinit(self.gpa);
        const frame = self.endQuery();
        fresh.deps = frame.deps;
        fresh.verified_at = self.revision;
        fresh.changed_at = self.revision;

        const old = try self.lower_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.lower_memos.getPtr(source_id).?;
    }

    fn ensureCompileMemo(self: *@This(), source_id: db.SourceId, track_dependency: bool) db.DbError!*codegen.CompileMemo {
        const query_key = queryFor(.compile, source_id);
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (self.compile_memos.getPtr(source_id)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                self.stats.compile_hits += 1;
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                self.stats.compile_hits += 1;
                return memo;
            }

            self.stats.compile_recomputes += 1;
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            const lower_memo = try self.ensureLowerMemo(source_id, true);
            var fresh = try codegen.computeCompile(lower_memo, self.gpa);
            errdefer fresh.deinit(self.gpa);
            const frame = self.endQuery();

            const old_changed_at = memo.changed_at;
            const same_value = db.valuesEqual(memo.value, fresh.value);
            const same_diagnostics = db.diagnosticsEqual(memo.diagnostics.items, fresh.diagnostics.items);

            if (memo.value) |bytes| self.gpa.free(bytes);
            memo.diagnostics.deinit(self.gpa);
            memo.deps.deinit(self.gpa);
            memo.value = fresh.value;
            memo.diagnostics = fresh.diagnostics;
            memo.deps = frame.deps;
            memo.verified_at = self.revision;
            memo.changed_at = if (same_value and same_diagnostics) old_changed_at else self.revision;
            return memo;
        }

        self.stats.compile_recomputes += 1;
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        const lower_memo = try self.ensureLowerMemo(source_id, true);
        var fresh = try codegen.computeCompile(lower_memo, self.gpa);
        errdefer fresh.deinit(self.gpa);
        const frame = self.endQuery();
        fresh.deps = frame.deps;
        fresh.verified_at = self.revision;
        fresh.changed_at = self.revision;

        const old = try self.compile_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.compile_memos.getPtr(source_id).?;
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
