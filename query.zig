const std = @import("std");
const parser = @import("parser.zig");
const ir_mod = @import("ir.zig");
const codegen = @import("codegen.zig");
const x86 = @import("main.zig");
const AstNode = x86.AstNode;
const Program = ir_mod.Program;
const CompileErrorSet = @typeInfo(@typeInfo(@TypeOf(codegen.compileProgram)).@"fn".return_type.?).error_union.error_set;

pub const SourceId = u32;
pub const Revision = u64;

pub const QueryError = error{
    SourceNotFound,
    QueryCycle,
};

pub const DbError = QueryError || parser.ParseError || std.mem.Allocator.Error || CompileErrorSet;

const QueryKind = enum {
    parse,
    lower,
    compile,
};

const QueryKey = struct {
    kind: QueryKind,
    source_id: SourceId,
};

const Dependency = union(enum) {
    source: SourceId,
    query: QueryKey,
};

const SourceInput = struct {
    text: []u8,
    changed_at: Revision,
};

const ParseMemo = struct {
    value: parser.ParsedAst,
    deps: std.ArrayList(Dependency),
    verified_at: Revision,
    changed_at: Revision,
    computing: bool,

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.value.deinit();
        self.deps.deinit(gpa);
    }
};

const LowerMemo = struct {
    value: Program,
    deps: std.ArrayList(Dependency),
    verified_at: Revision,
    changed_at: Revision,
    computing: bool,

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.value.deinit(gpa);
        self.deps.deinit(gpa);
    }
};

const CompileMemo = struct {
    value: []const u8,
    deps: std.ArrayList(Dependency),
    verified_at: Revision,
    changed_at: Revision,
    computing: bool,

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.value);
        self.deps.deinit(gpa);
    }
};

const ActiveQuery = struct {
    key: QueryKey,
    deps: std.ArrayList(Dependency),
};

pub const QueryStats = struct {
    revision: Revision = 0,
    source_sets: usize = 0,
    source_unchanged: usize = 0,
    parse_hits: usize = 0,
    parse_recomputes: usize = 0,
    lower_hits: usize = 0,
    lower_recomputes: usize = 0,
    compile_hits: usize = 0,
    compile_recomputes: usize = 0,
    dependency_checks: usize = 0,
    dependency_invalidations: usize = 0,
};

pub const Stage = enum {
    parse,
    lower,
    compile,
};

pub const QueryDb = struct {
    gpa: std.mem.Allocator,
    revision: Revision,
    sources: std.AutoHashMap(SourceId, SourceInput),
    parse_memos: std.AutoHashMap(SourceId, ParseMemo),
    lower_memos: std.AutoHashMap(SourceId, LowerMemo),
    compile_memos: std.AutoHashMap(SourceId, CompileMemo),
    active_stack: std.ArrayList(ActiveQuery),
    stats: QueryStats,

    pub fn init(gpa: std.mem.Allocator) QueryDb {
        return .{
            .gpa = gpa,
            .revision = 0,
            .sources = std.AutoHashMap(SourceId, SourceInput).init(gpa),
            .parse_memos = std.AutoHashMap(SourceId, ParseMemo).init(gpa),
            .lower_memos = std.AutoHashMap(SourceId, LowerMemo).init(gpa),
            .compile_memos = std.AutoHashMap(SourceId, CompileMemo).init(gpa),
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

    pub fn setSource(self: *@This(), source_id: SourceId, text: []const u8) !void {
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

    pub fn parsedAst(self: *@This(), source_id: SourceId) DbError!*const AstNode {
        const memo = try self.ensureParseMemo(source_id, true);
        return memo.value.root;
    }

    pub fn loweredProgram(self: *@This(), source_id: SourceId) DbError!*const Program {
        const memo = try self.ensureLowerMemo(source_id, true);
        return &memo.value;
    }

    pub fn compileBytes(self: *@This(), source_id: SourceId) DbError![]const u8 {
        const memo = try self.ensureCompileMemo(source_id, true);
        return memo.value;
    }

    pub fn statsSnapshot(self: *const @This()) QueryStats {
        var snapshot = self.stats;
        snapshot.revision = self.revision;
        return snapshot;
    }

    pub fn resetStats(self: *@This()) void {
        self.stats = .{ .revision = self.revision };
    }

    pub fn changedAt(self: *const @This(), stage: Stage, source_id: SourceId) ?Revision {
        return switch (stage) {
            .parse => if (self.parse_memos.get(source_id)) |memo| memo.changed_at else null,
            .lower => if (self.lower_memos.get(source_id)) |memo| memo.changed_at else null,
            .compile => if (self.compile_memos.get(source_id)) |memo| memo.changed_at else null,
        };
    }

    fn bumpRevision(self: *@This()) void {
        self.revision += 1;
    }

    fn queryFor(kind: QueryKind, source_id: SourceId) QueryKey {
        return .{ .kind = kind, .source_id = source_id };
    }

    fn ensureParseMemo(self: *@This(), source_id: SourceId, track_dependency: bool) DbError!*ParseMemo {
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
            try self.recomputeParseMemo(source_id, memo);
            return memo;
        }

        self.stats.parse_recomputes += 1;
        var fresh = try self.computeParseMemo(source_id);
        errdefer fresh.deinit(self.gpa);

        const old = try self.parse_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.parse_memos.getPtr(source_id).?;
    }

    fn ensureLowerMemo(self: *@This(), source_id: SourceId, track_dependency: bool) DbError!*LowerMemo {
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
            try self.recomputeLowerMemo(source_id, memo);
            return memo;
        }

        self.stats.lower_recomputes += 1;
        var fresh = try self.computeLowerMemo(source_id);
        errdefer fresh.deinit(self.gpa);

        const old = try self.lower_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.lower_memos.getPtr(source_id).?;
    }

    fn ensureCompileMemo(self: *@This(), source_id: SourceId, track_dependency: bool) DbError!*CompileMemo {
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
            try self.recomputeCompileMemo(source_id, memo);
            return memo;
        }

        self.stats.compile_recomputes += 1;
        var fresh = try self.computeCompileMemo(source_id);
        errdefer fresh.deinit(self.gpa);

        const old = try self.compile_memos.fetchPut(source_id, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            old_memo.deinit(self.gpa);
        }
        return self.compile_memos.getPtr(source_id).?;
    }

    fn computeParseMemo(self: *@This(), source_id: SourceId) DbError!ParseMemo {
        try self.beginQuery(queryFor(.parse, source_id));
        errdefer self.abortQuery();

        const source = try self.getSourceText(source_id);
        const value = try parser.parseOwned(source, self.gpa);

        const frame = self.endQuery();

        return .{
            .value = value,
            .deps = frame.deps,
            .verified_at = self.revision,
            .changed_at = self.revision,
            .computing = false,
        };
    }

    fn recomputeParseMemo(self: *@This(), source_id: SourceId, memo: *ParseMemo) DbError!void {
        memo.computing = true;
        defer memo.computing = false;

        var fresh = try self.computeParseMemo(source_id);
        errdefer fresh.deinit(self.gpa);

        memo.value.deinit();
        memo.deps.deinit(self.gpa);
        memo.value = fresh.value;
        memo.deps = fresh.deps;
        memo.verified_at = fresh.verified_at;
        memo.changed_at = self.revision;
    }

    fn computeLowerMemo(self: *@This(), source_id: SourceId) DbError!LowerMemo {
        try self.beginQuery(queryFor(.lower, source_id));
        errdefer self.abortQuery();

        const parse_memo = try self.ensureParseMemo(source_id, true);
        const lowered = try ir_mod.lower(parse_memo.value.root, self.gpa);

        const frame = self.endQuery();

        return .{
            .value = lowered,
            .deps = frame.deps,
            .verified_at = self.revision,
            .changed_at = self.revision,
            .computing = false,
        };
    }

    fn recomputeLowerMemo(self: *@This(), source_id: SourceId, memo: *LowerMemo) DbError!void {
        memo.computing = true;
        defer memo.computing = false;

        var fresh = try self.computeLowerMemo(source_id);
        errdefer fresh.deinit(self.gpa);

        memo.value.deinit(self.gpa);
        memo.deps.deinit(self.gpa);
        memo.value = fresh.value;
        memo.deps = fresh.deps;
        memo.verified_at = fresh.verified_at;
        memo.changed_at = self.revision;
    }

    fn computeCompileMemo(self: *@This(), source_id: SourceId) DbError!CompileMemo {
        try self.beginQuery(queryFor(.compile, source_id));
        errdefer self.abortQuery();

        const lower_memo = try self.ensureLowerMemo(source_id, true);
        const bytes = try codegen.compileProgram(&lower_memo.value, self.gpa);

        const frame = self.endQuery();

        return .{
            .value = bytes,
            .deps = frame.deps,
            .verified_at = self.revision,
            .changed_at = self.revision,
            .computing = false,
        };
    }

    fn recomputeCompileMemo(self: *@This(), source_id: SourceId, memo: *CompileMemo) DbError!void {
        memo.computing = true;
        defer memo.computing = false;

        var fresh = try self.computeCompileMemo(source_id);
        errdefer fresh.deinit(self.gpa);

        const old_changed_at = memo.changed_at;
        const same_value = std.mem.eql(u8, memo.value, fresh.value);

        self.gpa.free(memo.value);
        memo.deps.deinit(self.gpa);
        memo.value = fresh.value;
        memo.deps = fresh.deps;
        memo.verified_at = fresh.verified_at;
        memo.changed_at = if (same_value) old_changed_at else self.revision;
    }

    fn dependenciesUnchanged(self: *@This(), deps: []const Dependency, verified_at: Revision) DbError!bool {
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

    fn queryChangedAfter(self: *@This(), key: QueryKey, revision: Revision) DbError!bool {
        return switch (key.kind) {
            .parse => block: {
                const memo = try self.ensureParseMemo(key.source_id, false);
                break :block memo.changed_at > revision;
            },
            .lower => block: {
                const memo = try self.ensureLowerMemo(key.source_id, false);
                break :block memo.changed_at > revision;
            },
            .compile => block: {
                const memo = try self.ensureCompileMemo(key.source_id, false);
                break :block memo.changed_at > revision;
            },
        };
    }

    fn getSourceText(self: *@This(), source_id: SourceId) DbError![]const u8 {
        try self.noteSourceDependency(source_id);
        const input = self.sources.get(source_id) orelse return error.SourceNotFound;
        return input.text;
    }

    fn beginQuery(self: *@This(), key: QueryKey) DbError!void {
        for (self.active_stack.items) |active| {
            if (queryKeyEql(active.key, key)) return error.QueryCycle;
        }

        var deps = try std.ArrayList(Dependency).initCapacity(self.gpa, 8);
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

    fn noteSourceDependency(self: *@This(), source_id: SourceId) std.mem.Allocator.Error!void {
        if (self.active_stack.items.len == 0) return;
        const top_idx = self.active_stack.items.len - 1;
        try appendDependencyUnique(&self.active_stack.items[top_idx].deps, self.gpa, .{ .source = source_id });
    }

    fn noteQueryDependency(self: *@This(), key: QueryKey) std.mem.Allocator.Error!void {
        if (self.active_stack.items.len == 0) return;
        const top_idx = self.active_stack.items.len - 1;
        try appendDependencyUnique(&self.active_stack.items[top_idx].deps, self.gpa, .{ .query = key });
    }
};

fn queryKeyEql(a: QueryKey, b: QueryKey) bool {
    return a.kind == b.kind and a.source_id == b.source_id;
}

fn dependencyEql(a: Dependency, b: Dependency) bool {
    return switch (a) {
        .source => |lhs| switch (b) {
            .source => |rhs| lhs == rhs,
            .query => false,
        },
        .query => |lhs| switch (b) {
            .source => false,
            .query => |rhs| queryKeyEql(lhs, rhs),
        },
    };
}

fn appendDependencyUnique(deps: *std.ArrayList(Dependency), gpa: std.mem.Allocator, dep: Dependency) std.mem.Allocator.Error!void {
    for (deps.items) |existing| {
        if (dependencyEql(existing, dep)) return;
    }
    try deps.append(gpa, dep);
}
