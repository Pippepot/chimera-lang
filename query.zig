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
const discover = @import("discover.zig");
const semantic_queries = @import("semantic_queries.zig");

pub const QueryKind = db.QueryKind;
pub const ItemId = db.ItemId;
pub const InstanceId = db.InstanceId;
pub const SourceId = db.SourceId;
pub const QueryStats = db.QueryStats;
pub const Stage = db.Stage;
pub const CompileResult = db.CompileResult;
pub const QueryError = db.QueryError;

pub const QueryDbOptions = struct { persistent_cache_enabled: bool = true };

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

fn memoValueEqual(comptime T: type, gpa: std.mem.Allocator, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    if (comptime T == []const u8) return std.mem.eql(u8, a.?, b.?);
    if (comptime T == parser.ParsedAst) return parsedAstEql(&a.?, &b.?);
    if (comptime T == resolver.ResolvedAst) return resolvedAstEql(&a.?, &b.?);
    if (comptime T == analyze.AnalyzedAst) return analyzedAstEql(&a.?, &b.?);
    if (comptime T == ir_mod.Program) return programEql(gpa, &a.?, &b.?);
    if (comptime T == ir_mod.FunctionIR) return functionIREql(gpa, &a.?, &b.?);
    if (comptime T == discover.ItemTree) return itemTreeEql(&a.?, &b.?);
    if (comptime T == semantic_queries.ScopeSummary) return scopeSummaryEql(&a.?, &b.?);
    if (comptime T == semantic_queries.ResolvedItem) return resolvedItemEql(&a.?, &b.?);
    if (comptime T == semantic_queries.HeaderSignature) return headerSignatureEql(&a.?, &b.?);
    if (comptime T == semantic_queries.EffectiveSignature) return effectiveSignatureEql(&a.?, &b.?);
    if (comptime T == semantic_queries.BodyAnalysis) return bodyAnalysisEql(&a.?, &b.?);
    return false;
}

fn parsedAstEql(a: *const parser.ParsedAst, b: *const parser.ParsedAst) bool {
    const ao = &a.ast;
    const an = &b.ast;
    if (ao.nodes.len != an.nodes.len) return false;
    if (ao.decls.len != an.decls.len) return false;
    if (ao.entry != an.entry) return false;
    if (ao.extra.len != an.extra.len) return false;
    if (ao.ident_offsets.len != an.ident_offsets.len) return false;
    if (ao.ident_bytes.len != an.ident_bytes.len) return false;
    if (!std.mem.eql(u8, ao.ident_bytes, an.ident_bytes)) return false;
    for (ao.nodes, an.nodes) |na, nb| {
        if (@intFromEnum(na.tag) != @intFromEnum(nb.tag)) return false;
        if (na.data0 != nb.data0) return false;
        if (na.data1 != nb.data1) return false;
    }
    for (ao.extra, an.extra) |ea, eb| {
        if (ea != eb) return false;
    }
    return true;
}

fn resolvedAstEql(a: *const resolver.ResolvedAst, b: *const resolver.ResolvedAst) bool {
    if (a.functions.items.len != b.functions.items.len) return false;
    for (a.functions.items, b.functions.items) |oi, ni| {
        if (oi != ni) return false;
    }
    if (a.function_names.count() != b.function_names.count()) return false;
    {
        var iter = a.function_names.iterator();
        while (iter.next()) |entry| {
            const new_val = b.function_names.get(entry.key_ptr.*) orelse return false;
            if (entry.value_ptr.* != new_val) return false;
        }
    }
    if (a.comptime_value_names.count() != b.comptime_value_names.count()) return false;
    {
        var iter = a.comptime_value_names.iterator();
        while (iter.next()) |entry| {
            const new_val = b.comptime_value_names.get(entry.key_ptr.*) orelse return false;
            if (entry.value_ptr.* != new_val) return false;
        }
    }
    if (a.struct_names.count() != b.struct_names.count()) return false;
    {
        var iter = a.struct_names.iterator();
        while (iter.next()) |entry| {
            if (!b.struct_names.contains(entry.key_ptr.*)) return false;
        }
    }
    if (a.node_refs.count() != b.node_refs.count()) return false;
    {
        var iter = a.node_refs.iterator();
        while (iter.next()) |entry| {
            const new_val = b.node_refs.get(entry.key_ptr.*) orelse return false;
            const tag_a = std.meta.activeTag(entry.value_ptr.*);
            const tag_b = std.meta.activeTag(new_val);
            if (tag_a != tag_b) return false;
            switch (entry.value_ptr.*) {
                .local, .builtin_type => {},
                .function => |id| if (id != new_val.function) return false,
                .comptime_value => |decl| if (decl != new_val.comptime_value) return false,
                .struct_decl => |decl| if (decl != new_val.struct_decl) return false,
            }
        }
    }
    return true;
}

fn analyzedAstEql(a: *const analyze.AnalyzedAst, b: *const analyze.AnalyzedAst) bool {
    if (a.entry_function != b.entry_function) return false;
    if (a.functions.items.len != b.functions.items.len) return false;
    for (a.functions.items, b.functions.items) |oi, ni| {
        if (oi.decl != ni.decl) return false;
        if (!funcTypeEql(oi.ty.*, ni.ty.*)) return false;
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(oi.param_modes), std.mem.sliceAsBytes(ni.param_modes))) return false;
        if (oi.has_explicit_return != ni.has_explicit_return) return false;
        if (oi.is_monomorphized != ni.is_monomorphized) return false;
    }
    if (!hashMapTypeEql(a.node_types, b.node_types, analyze.typeEql)) return false;
    if (!hashMapValueEql(a.field_index, b.field_index)) return false;
    if (!hashMapTypeEql(a.decl_binding_types, b.decl_binding_types, analyze.typeEql)) return false;
    if (!hashMapSliceEql(a.is_variant_tags, b.is_variant_tags)) return false;
    if (!hashMapValueEql(a.query_none_tags, b.query_none_tags)) return false;
    if (!hashMapComptimeValueEql(a.comptime_node_values, b.comptime_node_values)) return false;
    if (!strHashMapComptimeValueEql(a.comptime_values, b.comptime_values)) return false;
    return true;
}

fn programEql(gpa: std.mem.Allocator, a: *const ir_mod.Program, b: *const ir_mod.Program) bool {
    const ba = query_cache.serializeProgram(gpa, a) catch return false;
    defer gpa.free(ba);
    const bb = query_cache.serializeProgram(gpa, b) catch return false;
    defer gpa.free(bb);
    return std.mem.eql(u8, ba, bb);
}

fn functionIREql(gpa: std.mem.Allocator, a: *const ir_mod.FunctionIR, b: *const ir_mod.FunctionIR) bool {
    const ba = query_cache.serializeFunctionIR(gpa, a) catch return false;
    defer gpa.free(ba);
    const bb = query_cache.serializeFunctionIR(gpa, b) catch return false;
    defer gpa.free(bb);
    return std.mem.eql(u8, ba, bb);
}

fn itemTreeEql(a: *const discover.ItemTree, b: *const discover.ItemTree) bool {
    if (a.source_id != b.source_id) return false;
    if (!db.moduleIdEql(a.module_id, b.module_id)) return false;
    if (a.items.items.len != b.items.items.len) return false;
    for (a.items.items, b.items.items) |oi, ni| {
        if (!db.itemIdEql(oi.id, ni.id)) return false;
        if (!std.mem.eql(u8, oi.name, ni.name)) return false;
        if (oi.decl != ni.decl) return false;
        if (oi.body) |ob| {
            const nb = ni.body orelse return false;
            if (!db.itemIdEql(ob.owner, nb.owner)) return false;
            if (ob.kind != nb.kind) return false;
        } else if (ni.body != null) return false;
    }
    return true;
}

fn scopeSummaryEql(a: *const semantic_queries.ScopeSummary, b: *const semantic_queries.ScopeSummary) bool {
    if (a.entries.len != b.entries.len) return false;
    for (a.entries, b.entries) |oe, ne| {
        if (!std.mem.eql(u8, oe.name, ne.name)) return false;
        if (!db.itemIdEql(oe.item_id, ne.item_id)) return false;
        if (oe.decl != ne.decl) return false;
    }
    return true;
}

fn resolvedItemEql(a: *const semantic_queries.ResolvedItem, b: *const semantic_queries.ResolvedItem) bool {
    if (!db.itemIdEql(a.item, b.item)) return false;
    if (a.decl != b.decl) return false;
    if (a.node_refs.count() != b.node_refs.count()) return false;
    var iter = a.node_refs.iterator();
    while (iter.next()) |entry| {
        const new_val = b.node_refs.get(entry.key_ptr.*) orelse return false;
        const tag_a = std.meta.activeTag(entry.value_ptr.*);
        const tag_b = std.meta.activeTag(new_val);
        if (tag_a != tag_b) return false;
        switch (entry.value_ptr.*) {
            .local, .builtin_type => {},
            .function => |id| if (id != new_val.function) return false,
            .comptime_value => |decl| if (decl != new_val.comptime_value) return false,
            .struct_decl => |decl| if (decl != new_val.struct_decl) return false,
        }
    }
    return true;
}

fn headerSignatureEql(a: *const semantic_queries.HeaderSignature, b: *const semantic_queries.HeaderSignature) bool {
    if (!db.itemIdEql(a.item, b.item)) return false;
    if (a.decl != b.decl) return false;
    if (a.param_count != b.param_count) return false;
    if (a.comptime_mask != b.comptime_mask) return false;
    if (a.has_inferred_return != b.has_inferred_return) return false;
    if (a.has_body != b.has_body) return false;
    if (a.param_modes.len != b.param_modes.len) return false;
    for (a.param_modes, b.param_modes) |om, nm| {
        if (@intFromEnum(om) != @intFromEnum(nm)) return false;
    }
    if (a.param_types.len != b.param_types.len) return false;
    for (a.param_types, b.param_types) |ot, nt| {
        if (!analyze.typeEql(ot, nt)) return false;
    }
    if (!analyze.typeEql(a.return_type, b.return_type)) return false;
    return true;
}

fn effectiveSignatureEql(a: *const semantic_queries.EffectiveSignature, b: *const semantic_queries.EffectiveSignature) bool {
    if (!db.instanceIdEql(a.instance, b.instance)) return false;
    if (a.function_id != b.function_id) return false;
    if (a.decl != b.decl) return false;
    if (a.param_count != b.param_count) return false;
    if (a.has_inferred_return != b.has_inferred_return) return false;
    if (a.has_explicit_return != b.has_explicit_return) return false;
    return true;
}

fn bodyAnalysisEql(a: *const semantic_queries.BodyAnalysis, b: *const semantic_queries.BodyAnalysis) bool {
    if (!db.instanceIdEql(a.instance, b.instance)) return false;
    if (a.function_id != b.function_id) return false;
    if (a.decl != b.decl) return false;
    if (a.body != b.body) return false;
    if (!hashMapTypeEql(a.node_types, b.node_types, analyze.typeEql)) return false;
    if (!hashMapValueEql(a.field_index, b.field_index)) return false;
    if (!hashMapInstanceIdEql(a.call_targets, b.call_targets)) return false;
    if (!hashMapSliceEql(a.is_variant_tags, b.is_variant_tags)) return false;
    if (!hashMapValueEql(a.query_none_tags, b.query_none_tags)) return false;
    if (!hashMapTypeEql(a.decl_binding_types, b.decl_binding_types, analyze.typeEql)) return false;
    return true;
}

fn hashMapValueEql(a: anytype, b: anytype) bool {
    if (a.count() != b.count()) return false;
    var iter = a.iterator();
    while (iter.next()) |entry| {
        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (entry.value_ptr.* != b_val) return false;
    }
    return true;
}

fn hashMapTypeEql(a: anytype, b: anytype, comptime typeEq: anytype) bool {
    if (a.count() != b.count()) return false;
    var iter = a.iterator();
    while (iter.next()) |entry| {
        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (!@call(.auto, typeEq, .{ entry.value_ptr.*, b_val })) return false;
    }
    return true;
}

fn hashMapSliceEql(a: anytype, b: anytype) bool {
    if (a.count() != b.count()) return false;
    var iter = a.iterator();
    while (iter.next()) |entry| {
        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (!std.mem.eql(@TypeOf(entry.value_ptr.*[0]), entry.value_ptr.*, b_val)) return false;
    }
    return true;
}

fn hashMapInstanceIdEql(a: anytype, b: anytype) bool {
    if (a.count() != b.count()) return false;
    var iter = a.iterator();
    while (iter.next()) |entry| {
        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (!db.instanceIdEql(entry.value_ptr.*, b_val)) return false;
    }
    return true;
}

fn hashMapComptimeValueEql(a: anytype, b: anytype) bool {
    if (a.count() != b.count()) return false;
    var iter = a.iterator();
    while (iter.next()) |entry| {
        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (!comptimeValueEql(entry.value_ptr.*, b_val)) return false;
    }
    return true;
}

fn strHashMapComptimeValueEql(a: anytype, b: anytype) bool {
    if (a.count() != b.count()) return false;
    var iter = a.iterator();
    while (iter.next()) |entry| {
        const b_val = b.get(entry.key_ptr.*) orelse return false;
        if (!comptimeValueEql(entry.value_ptr.*, b_val)) return false;
    }
    return true;
}

fn comptimeValueEql(a: analyze.ComptimeValue, b: analyze.ComptimeValue) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;
    return switch (a) {
        .unit, .none => true,
        .bool => |v| v == b.bool,
        .int => |v| v == b.int,
        .float => |v| v == b.float,
        .func => |id| id == b.func,
        .struct_type => |decl| decl == b.struct_type,
        .struct_value => |sv| comptimeStructValueEql(sv, b.struct_value),
        .type_value => |ty| analyze.typeEql(ty, b.type_value),
    };
}

fn funcTypeEql(a: analyze.FuncType, b: analyze.FuncType) bool {
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params) |pa, pb| {
        if (!analyze.typeEql(pa, pb)) return false;
    }
    return analyze.typeEql(a.ret, b.ret);
}

fn comptimeStructValueEql(a: analyze.StructValue, b: analyze.StructValue) bool {
    if (a.decl != b.decl) return false;
    if (a.fields.len != b.fields.len) return false;
    for (a.fields, b.fields) |fa, fb| {
        if (!comptimeValueEql(fa, fb)) return false;
    }
    return true;
}

pub const QueryDb = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    persistent_cache_enabled: bool,
    cache_backings: std.ArrayList([]u8),
    revision: db.Revision,
    sources: std.AutoHashMap(db.SourceId, SourceInput),
    parse_memos: std.AutoHashMap(db.SourceId, db.Memo(parser.ParsedAst)),
    resolve_memos: std.AutoHashMap(db.SourceId, db.Memo(resolver.ResolvedAst)),
    type_memos: std.AutoHashMap(db.SourceId, db.Memo(analyze.AnalyzedAst)),
    lower_memos: std.AutoHashMap(db.SourceId, db.Memo(ir_mod.Program)),
    compile_memos: std.AutoHashMap(db.SourceId, db.Memo([]const u8)),
    discover_memos: std.AutoHashMap(db.ModuleId, db.Memo(discover.ItemTree)),
    scope_memos: std.AutoHashMap(db.ModuleId, db.Memo(semantic_queries.ScopeSummary)),
    resolve_item_memos: std.AutoHashMap(db.ItemId, db.Memo(semantic_queries.ResolvedItem)),
    header_memos: std.AutoHashMap(db.ItemId, db.Memo(semantic_queries.HeaderSignature)),
    effective_memos: std.AutoHashMap(db.InstanceId, db.Memo(semantic_queries.EffectiveSignature)),
    body_memos: std.AutoHashMap(db.InstanceId, db.Memo(semantic_queries.BodyAnalysis)),
    lower_body_memos: std.AutoHashMap(db.InstanceId, db.Memo(ir_mod.FunctionIR)),
    active_stack: std.ArrayList(ActiveQuery),
    stats: db.QueryStats,

    pub fn initWithOptions(gpa: std.mem.Allocator, io: std.Io, options: QueryDbOptions) QueryDb {
        return .{
            .gpa = gpa,
            .io = io,
            .persistent_cache_enabled = options.persistent_cache_enabled,
            .cache_backings = .empty,
            .revision = 0,
            .sources = std.AutoHashMap(db.SourceId, SourceInput).init(gpa),
            .parse_memos = std.AutoHashMap(db.SourceId, db.Memo(parser.ParsedAst)).init(gpa),
            .resolve_memos = std.AutoHashMap(db.SourceId, db.Memo(resolver.ResolvedAst)).init(gpa),
            .type_memos = std.AutoHashMap(db.SourceId, db.Memo(analyze.AnalyzedAst)).init(gpa),
            .lower_memos = std.AutoHashMap(db.SourceId, db.Memo(ir_mod.Program)).init(gpa),
            .compile_memos = std.AutoHashMap(db.SourceId, db.Memo([]const u8)).init(gpa),
            .discover_memos = std.AutoHashMap(db.ModuleId, db.Memo(discover.ItemTree)).init(gpa),
            .scope_memos = std.AutoHashMap(db.ModuleId, db.Memo(semantic_queries.ScopeSummary)).init(gpa),
            .resolve_item_memos = std.AutoHashMap(db.ItemId, db.Memo(semantic_queries.ResolvedItem)).init(gpa),
            .header_memos = std.AutoHashMap(db.ItemId, db.Memo(semantic_queries.HeaderSignature)).init(gpa),
            .effective_memos = std.AutoHashMap(db.InstanceId, db.Memo(semantic_queries.EffectiveSignature)).init(gpa),
            .body_memos = std.AutoHashMap(db.InstanceId, db.Memo(semantic_queries.BodyAnalysis)).init(gpa),
            .lower_body_memos = std.AutoHashMap(db.InstanceId, db.Memo(ir_mod.FunctionIR)).init(gpa),
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
        self.flushPersistentCaches(self.io) catch {};

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

        self.deinitMemoMap(discover.ItemTree, &self.discover_memos);
        self.deinitMemoMap(semantic_queries.ScopeSummary, &self.scope_memos);
        self.deinitMemoMap(semantic_queries.ResolvedItem, &self.resolve_item_memos);
        self.deinitMemoMap(semantic_queries.HeaderSignature, &self.header_memos);
        self.deinitMemoMap(semantic_queries.EffectiveSignature, &self.effective_memos);
        self.deinitMemoMap(semantic_queries.BodyAnalysis, &self.body_memos);
        self.deinitMemoMap(ir_mod.FunctionIR, &self.lower_body_memos);

        for (self.active_stack.items) |*frame| {
            frame.deps.deinit(self.gpa);
        }
        self.active_stack.deinit(self.gpa);

        for (self.cache_backings.items) |backing| self.gpa.free(backing);
        self.cache_backings.deinit(self.gpa);
    }

    fn deinitStageMemos(self: *@This(), comptime stage: Stage) void {
        const T = stageValueType(stage);
        var iter = self.memosFor(stage).iterator();
        while (iter.next()) |entry| deinitMemo(T, entry.value_ptr, self.gpa);
        self.memosFor(stage).deinit();
    }

    fn deinitMemoMap(self: *@This(), comptime T: type, memos: anytype) void {
        var iter = memos.iterator();
        while (iter.next()) |entry| deinitMemo(T, entry.value_ptr, self.gpa);
        memos.deinit();
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
            // self.tryLoadPersistentCache(source_id, existing);
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

        // const input = self.sources.getPtr(source_id).?;
        // self.tryLoadPersistentCache(source_id, input);
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

    pub fn discoveredItems(self: *@This(), module_id: db.ModuleId) db.DbError!?*const discover.ItemTree {
        const memo = try self.ensureDiscoverMemo(module_id);
        if (memo.value) |*v| return v;
        return null;
    }

    pub fn moduleScope(self: *@This(), module_id: db.ModuleId) db.DbError!?*const semantic_queries.ScopeSummary {
        const memo = try self.ensureScopeMemo(module_id);
        if (memo.value) |*v| return v;
        return null;
    }

    pub fn resolveItem(self: *@This(), item_id: db.ItemId) db.DbError!?*const semantic_queries.ResolvedItem {
        const memo = try self.ensureResolveItemMemo(item_id);
        if (memo.value) |*v| return v;
        return null;
    }

    pub fn headerSignature(self: *@This(), item_id: db.ItemId) db.DbError!?*const semantic_queries.HeaderSignature {
        const memo = try self.ensureHeaderSignature(item_id);
        if (memo.value) |*v| return v;
        return null;
    }

    pub fn effectiveSignature(self: *@This(), instance_id: db.InstanceId) db.DbError!?*const semantic_queries.EffectiveSignature {
        const memo = try self.ensureEffectiveSignature(instance_id);
        if (memo.value) |*v| return v;
        return null;
    }

    pub fn checkedBody(self: *@This(), instance_id: db.InstanceId) db.DbError!?*const semantic_queries.BodyAnalysis {
        const memo = try self.ensureBodyAnalysis(instance_id);
        if (memo.value) |*v| return v;
        return null;
    }

    pub fn loweredBody(self: *@This(), instance_id: db.InstanceId) db.DbError!?*const ir_mod.FunctionIR {
        const memo = try self.ensureLowerBodyMemo(instance_id);
        if (memo.value) |*v| return v;
        return null;
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

    fn tryLoadPersistentCache(self: *@This(), source_id: db.SourceId, input: *SourceInput) void {
        if (!self.persistent_cache_enabled) return;
        const source_path = input.source_path orelse return;

        // Phase 1: try source-hash-based match (fast path, no parsing needed)
        const maybe_loaded = query_cache.load(self.io, self.gpa, source_path, input.text, null, null) catch null;
        if (maybe_loaded) |loaded| {
            self.loadAllFromCache(source_id, loaded, null);
            // All 5 stages loaded from cache — no computation needed
            self.stats.hit(.parse);
            self.stats.hit(.resolve);
            self.stats.hit(.typecheck);
            self.stats.hit(.lower);
            self.stats.hit(.compile);
            return;
        }

        // Phase 2: parse source, compute AST hash, try AST-hash-based match
        var parsed = parser.parseOwned(input.text, self.gpa) catch return;
        const ast_hash = ast.structuralHash(&parsed.ast);
        const ast_cached = query_cache.load(self.io, self.gpa, source_path, input.text, ast_hash, null) catch {
            parsed.deinit(self.gpa);
            return;
        };
        if (ast_cached) |loaded| {
            // AST hash matched — parse was freshly computed (recompute),
            // load remaining stages from cache (hits)
            self.stats.recompute(.parse);

            const parse_memo = db.makeMemo(parser.ParsedAst, parsed, .empty);
            const old_parse = self.parse_memos.fetchPut(source_id, parse_memo) catch {
                parsed.deinit(self.gpa);
                return;
            };
            if (old_parse) |kv| {
                var old_memo = kv.value;
                deinitMemo(parser.ParsedAst, &old_memo, self.gpa);
            }
            const parse_ast = if (self.parse_memos.get(source_id)) |m| if (m.value) |*p| &p.ast else null else null;
            self.loadAllFromCache(source_id, loaded, parse_ast);
            // resolve, typecheck, lower, compile loaded from cache
            self.stats.hit(.resolve);
            self.stats.hit(.typecheck);
            self.stats.hit(.lower);
            self.stats.hit(.compile);
            return;
        }

        // Phase 3: try lowered-IR-hash-based match.
        // Parse is done; resolve + typecheck + lower to compute an IR hash,
        // then load cached compile when the IR hash matches.
        // `parsed` is moved into `phase3_parse` — cleanup via defer.
        {
            var phase3_parse = db.makeMemo(parser.ParsedAst, parsed, .empty);
            var phase3_resolve: ?db.Memo(resolver.ResolvedAst) = null;
            var phase3_typed: ?db.Memo(analyze.AnalyzedAst) = null;
            var phase3_lower: ?db.Memo(ir_mod.Program) = null;
            var phase3_ok = false;
            defer {
                if (!phase3_ok) {
                    if (phase3_lower) |*m| deinitMemo(ir_mod.Program, m, self.gpa);
                    if (phase3_typed) |*m| deinitMemo(analyze.AnalyzedAst, m, self.gpa);
                    if (phase3_resolve) |*m| deinitMemo(resolver.ResolvedAst, m, self.gpa);
                    deinitMemo(parser.ParsedAst, &phase3_parse, self.gpa);
                }
            }

            phase3_resolve = resolver.computeResolve(&phase3_parse, self.gpa) catch return;
            phase3_typed = analyze.computeAnalyze(&phase3_resolve.?, &phase3_parse, self.gpa) catch return;
            phase3_lower = ir_mod.computeLower(&phase3_typed.?, self.gpa) catch return;

            if (phase3_lower.?.value) |*prog| {
                const ir_bytes = query_cache.serializeProgram(self.gpa, prog) catch return;
                defer self.gpa.free(ir_bytes);
                const ir_hash = std.hash.Wyhash.hash(0, ir_bytes);

                var ir_cached = query_cache.load(self.io, self.gpa, source_path, input.text, ast_hash, ir_hash) catch return;

                if (ir_cached) |*loaded| {
                    // IR hash matched — parse (phase 2), resolve, typecheck, lower
                    // were freshly computed; compile loaded from cache.
                    self.stats.recompute(.parse);
                    self.stats.recompute(.resolve);
                    self.stats.recompute(.typecheck);
                    self.stats.recompute(.lower);
                    self.stats.hit(.compile);

                    phase3_ok = true;

                    { // Parse memo — parsed is owned by phase3_parse
                        var pm = db.makeMemo(parser.ParsedAst, phase3_parse.value, phase3_parse.diagnostics);
                        phase3_parse.value = null;
                        phase3_parse.diagnostics = .empty;
                        pm.deps = self.depForSource(source_id) catch {
                            deinitMemo(parser.ParsedAst, &pm, self.gpa);
                            return;
                        };
                        pm.verified_at = self.revision;
                        pm.changed_at = self.revision;
                        const old = self.parse_memos.fetchPut(source_id, pm) catch {
                            deinitMemo(parser.ParsedAst, &pm, self.gpa);
                            return;
                        };
                        if (old) |kv| {
                            var old_memo = kv.value;
                            deinitMemo(parser.ParsedAst, &old_memo, self.gpa);
                        }
                    }

                    { // Resolve memo
                        var rm = db.makeMemo(resolver.ResolvedAst, phase3_resolve.?.value, phase3_resolve.?.diagnostics);
                        phase3_resolve.?.value = null;
                        phase3_resolve.?.diagnostics = .empty;
                        rm.deps = self.depForStage(source_id, .parse) catch {
                            deinitMemo(resolver.ResolvedAst, &rm, self.gpa);
                            return;
                        };
                        rm.verified_at = self.revision;
                        rm.changed_at = self.revision;
                        const old = self.resolve_memos.fetchPut(source_id, rm) catch {
                            deinitMemo(resolver.ResolvedAst, &rm, self.gpa);
                            return;
                        };
                        if (old) |kv| {
                            var old_memo = kv.value;
                            deinitMemo(resolver.ResolvedAst, &old_memo, self.gpa);
                        }
                    }

                    { // Typecheck memo
                        var tm = db.makeMemo(analyze.AnalyzedAst, phase3_typed.?.value, phase3_typed.?.diagnostics);
                        phase3_typed.?.value = null;
                        phase3_typed.?.diagnostics = .empty;
                        tm.deps = self.depForStage(source_id, .resolve) catch {
                            deinitMemo(analyze.AnalyzedAst, &tm, self.gpa);
                            return;
                        };
                        tm.verified_at = self.revision;
                        tm.changed_at = self.revision;
                        const old = self.type_memos.fetchPut(source_id, tm) catch {
                            deinitMemo(analyze.AnalyzedAst, &tm, self.gpa);
                            return;
                        };
                        if (old) |kv| {
                            var old_memo = kv.value;
                            deinitMemo(analyze.AnalyzedAst, &old_memo, self.gpa);
                        }
                    }

                    { // Lower memo — freshly computed, move into memos
                        var lm = db.makeMemo(ir_mod.Program, phase3_lower.?.value, phase3_lower.?.diagnostics);
                        phase3_lower.?.value = null;
                        phase3_lower.?.diagnostics = .empty;
                        lm.deps = self.depForStage(source_id, .typecheck) catch {
                            deinitMemo(ir_mod.Program, &lm, self.gpa);
                            return;
                        };
                        lm.verified_at = self.revision;
                        lm.changed_at = self.revision;
                        const old = self.lower_memos.fetchPut(source_id, lm) catch {
                            deinitMemo(ir_mod.Program, &lm, self.gpa);
                            return;
                        };
                        if (old) |kv| {
                            var old_memo = kv.value;
                            deinitMemo(ir_mod.Program, &old_memo, self.gpa);
                        }
                    }

                    // Compile from cache
                    self.loadPersistentStage(source_id, .compile, &loaded.compile, null);

                    self.cache_backings.append(self.gpa, loaded.backing) catch {};
                    loaded.backing = loaded.backing[0..0];
                    return;
                }
            }
        }
        // Phase 3 didn't match — `parsed` was cleaned up by the defer above
    }

    fn loadAllFromCache(self: *@This(), source_id: db.SourceId, loaded_in: query_cache.LoadPayload, skip_parse_ast: ?*const ast.Ast) void {
        var loaded = loaded_in;
        var parse_ast: ?*const ast.Ast = skip_parse_ast;
        if (parse_ast == null) {
            self.loadPersistentStage(source_id, .parse, &loaded.parse, null);
            if (self.parse_memos.get(source_id)) |stored| {
                parse_ast = if (stored.value) |*p| &p.ast else null;
            }
        }
        self.loadPersistentStage(source_id, .resolve, &loaded.resolve, parse_ast);
        self.loadPersistentStage(source_id, .typecheck, &loaded.typecheck, parse_ast);
        self.loadPersistentStage(source_id, .lower, &loaded.lower, parse_ast);
        self.loadPersistentStage(source_id, .compile, &loaded.compile, parse_ast);

        self.cache_backings.append(self.gpa, loaded.backing) catch {};
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

        if (!loaded_stage.has_value and loaded_stage.diagnostics.items.len == 0) return;

        var value: ?T = null;
        if (loaded_stage.has_value) {
            if (loaded_stage.bytes) |bytes| {
                value = switch (stage) {
                    .compile => self.gpa.dupe(u8, bytes) catch return,
                    .typecheck => query_cache.deserializeTyped(self.gpa, bytes, parse_ast orelse return) catch return,
                    else => deserializeStageValue(stage, self.gpa, bytes, null) catch return,
                };
            }
        }

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
        try list.append(self.gpa, .{ .query = queryFor(db.QueryKind.fromStage(stage), source_id) });
        return list;
    }

    fn snapshotStage(self: *@This(), source_id: db.SourceId, comptime stage: Stage, gpa: std.mem.Allocator) (error{OutOfMemory}!query_cache.StageSnapshot) {
        return if (self.memosFor(stage).get(source_id)) |memo| .{
            .changed_at = memo.changed_at,
            .has_value = memo.value != null,
            .diagnostics = memo.diagnostics.items,
            .bytes = if (memo.value) |*v|
                if (comptime stage == .compile) try gpa.dupe(u8, v.*) else try serializeStageValue(stage, gpa, v)
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
                    query_cache.sweepStaleCaches(io, self.gpa, path) catch {};
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

            const ast_hash: u64 = if (self.parse_memos.get(source_id)) |pm|
                if (pm.value) |*p| ast.structuralHash(&p.ast) else 0
            else
                0;

            const ir_hash: u64 = if (snaps[3].bytes) |bytes| std.hash.Wyhash.hash(0, bytes) else 0;

            try query_cache.save(io, self.gpa, .{
                .source_path = source_path,
                .source_text = source.text,
                .ast_hash = ast_hash,
                .ir_hash = ir_hash,
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

    fn queryFor(kind: db.QueryKind, source_id: db.SourceId) db.QueryKey {
        return .{ .kind = kind, .source_id = source_id };
    }

    fn ensureMemo(
        self: *@This(),
        source_id: db.SourceId,
        track_dependency: bool,
        comptime stage: Stage,
    ) (db.DbError || std.mem.Allocator.Error)!*db.Memo(stageValueType(stage)) {
        const T = stageValueType(stage);
        const qk = queryFor(db.QueryKind.fromStage(stage), source_id);
        const compute = struct {
            fn f(ql: *QueryDb, sid: db.SourceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(T) {
                return ql.computeStage(sid, stage);
            }
        }.f;
        return try self.ensureGeneric(T, self.memosFor(stage), source_id, qk, track_dependency, compute);
    }

    fn ensureGeneric(
        self: *@This(),
        comptime T: type,
        memos: anytype,
        key: anytype,
        query_key: db.QueryKey,
        track_dependency: bool,
        comptime compute_fn: anytype,
    ) (db.DbError || std.mem.Allocator.Error)!*db.Memo(T) {
        if (track_dependency) try self.noteQueryDependency(query_key);

        if (memos.getPtr(key)) |memo| {
            if (memo.computing) return error.QueryCycle;

            if (memo.verified_at == self.revision) {
                self.stats.hit(query_key.kind);
                return memo;
            }

            if (try self.dependenciesUnchanged(memo.deps.items, memo.verified_at)) {
                memo.verified_at = self.revision;
                self.stats.hit(query_key.kind);
                return memo;
            }

            self.stats.recompute(query_key.kind);
            memo.computing = true;
            defer memo.computing = false;

            try self.beginQuery(query_key);
            errdefer self.abortQuery();
            var fresh = try compute_fn(self, key);
            errdefer deinitMemo(T, &fresh, self.gpa);
            const frame = self.endQuery();

            const old_changed_at = memo.changed_at;
            const same_value = memoValueEqual(T, self.gpa, memo.value, fresh.value);
            const same_diagnostics = db.diagnosticsEqual(memo.diagnostics.items, fresh.diagnostics.items);

            deinitMemo(T, memo, self.gpa);
            memo.value = fresh.value;
            memo.diagnostics = fresh.diagnostics;
            memo.deps = frame.deps;
            memo.verified_at = self.revision;
            memo.changed_at = if (same_value and same_diagnostics) old_changed_at else self.revision;
            return memo;
        }

        self.stats.recompute(query_key.kind);
        try self.beginQuery(query_key);
        errdefer self.abortQuery();
        var fresh = try compute_fn(self, key);
        errdefer deinitMemo(T, &fresh, self.gpa);
        const frame = self.endQuery();
        fresh.deps = frame.deps;
        fresh.verified_at = self.revision;
        fresh.changed_at = self.revision;

        const old = try memos.fetchPut(key, fresh);
        if (old) |kv| {
            var old_memo = kv.value;
            deinitMemo(T, &old_memo, self.gpa);
        }
        return memos.getPtr(key).?;
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
            .lower => blk: {
                _ = try self.ensureMemo(source_id, true, .parse);
                break :blk try ir_mod.computeLower(try self.ensureMemo(source_id, true, .typecheck), self.gpa);
            },
            .compile => blk: {
                try self.ensureSourceBodyAnalyses(source_id);
                break :blk try codegen.computeCompile(try self.ensureMemo(source_id, true, .lower), self.gpa);
            },
        };
    }

    fn ensureSourceBodyAnalyses(self: *@This(), source_id: db.SourceId) (db.DbError || std.mem.Allocator.Error)!void {
        const module_id: db.ModuleId = .{ .package_id = 0, .source_id = source_id };
        const discover_memo = try self.ensureDiscoverMemo(module_id);
        const item_tree = if (discover_memo.value) |*tree| tree else return;
        for (item_tree.items.items) |item| {
            _ = try self.ensureHeaderSignature(item.id);
            if (item.id.kind != .function and item.id.kind != .top_level_entry) continue;
            _ = try self.ensureBodyAnalysis(db.InstanceId{ .item = item.id, .comptime_args_hash = 0 });
        }
    }

    // ── Discover ──

    pub fn ensureDiscoverMemo(self: *@This(), module_id: db.ModuleId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(discover.ItemTree) {
        const qk = db.QueryKey{ .kind = .discover_items, .source_id = module_id.source_id, .module_id = module_id };
        return self.ensureGeneric(discover.ItemTree, &self.discover_memos, module_id, qk, true, @This().computeDiscover);
    }

    fn computeDiscover(self: *@This(), module_id: db.ModuleId) (db.DbError || std.mem.Allocator.Error)!db.Memo(discover.ItemTree) {
        const source_id = module_id.source_id;
        const parse_memo = try self.ensureMemo(source_id, true, .parse);
        return discover.computeDiscover(source_id, parse_memo, self.gpa);
    }

    // ── Module scope ──

    pub fn ensureScopeMemo(self: *@This(), module_id: db.ModuleId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(semantic_queries.ScopeSummary) {
        const qk = db.QueryKey{ .kind = .module_scope, .source_id = module_id.source_id, .module_id = module_id };
        return self.ensureGeneric(semantic_queries.ScopeSummary, &self.scope_memos, module_id, qk, true, @This().computeScope);
    }

    fn computeScope(self: *@This(), module_id: db.ModuleId) (db.DbError || std.mem.Allocator.Error)!db.Memo(semantic_queries.ScopeSummary) {
        const source_id = module_id.source_id;
        const item_tree = try self.ensureDiscoverMemo(module_id);
        const parsed = try self.ensureMemo(source_id, true, .parse);
        const parsed_ast: *const ast.Ast = if (parsed.value) |*p| &p.ast else return db.Memo(semantic_queries.ScopeSummary){ .value = null, .diagnostics = .empty, .deps = .empty };
        if (item_tree.value) |*tree| {
            return semantic_queries.computeModuleScope(tree, parsed_ast, self.gpa);
        }
        return db.makeMemo(semantic_queries.ScopeSummary, null, .empty);
    }

    // ── Resolve item ──

    pub fn ensureResolveItemMemo(self: *@This(), item_id: db.ItemId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(semantic_queries.ResolvedItem) {
        const qk = db.QueryKey{ .kind = .resolve_item, .source_id = item_id.module.source_id, .item_id = item_id };
        return self.ensureGeneric(semantic_queries.ResolvedItem, &self.resolve_item_memos, item_id, qk, true, @This().computeResolveItem);
    }

    fn computeResolveItem(self: *@This(), item_id: db.ItemId) (db.DbError || std.mem.Allocator.Error)!db.Memo(semantic_queries.ResolvedItem) {
        const source_id = item_id.module.source_id;
        const module_id = item_id.module;
        const resolved = try self.ensureMemo(source_id, true, .resolve);
        const item_tree = try self.ensureDiscoverMemo(module_id);
        const parsed = try self.ensureMemo(source_id, true, .parse);
        const parsed_ast: *const ast.Ast = if (parsed.value) |*p| &p.ast else return db.Memo(semantic_queries.ResolvedItem){ .value = null, .diagnostics = .empty, .deps = .empty };
        if (resolved.value) |*rv| {
            if (item_tree.value) |*tree| {
                return semantic_queries.computeResolveItem(item_id, rv, tree, parsed_ast, self.gpa);
            }
        }
        return db.makeMemo(semantic_queries.ResolvedItem, null, .empty);
    }

    // ── Header signature ──

    pub fn ensureHeaderSignature(self: *@This(), item_id: db.ItemId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(semantic_queries.HeaderSignature) {
        const qk = db.QueryKey{ .kind = .header_signature, .source_id = item_id.module.source_id, .item_id = item_id };
        return self.ensureGeneric(semantic_queries.HeaderSignature, &self.header_memos, item_id, qk, true, @This().computeHeaderSignature);
    }

    fn computeHeaderSignature(self: *@This(), item_id: db.ItemId) (db.DbError || std.mem.Allocator.Error)!db.Memo(semantic_queries.HeaderSignature) {
        const source_id = item_id.module.source_id;
        const module_id = item_id.module;
        const parsed = try self.ensureMemo(source_id, true, .parse);
        const resolved = try self.ensureMemo(source_id, true, .resolve);
        const item_tree = try self.ensureDiscoverMemo(module_id);
        const parsed_ast: *const ast.Ast = if (parsed.value) |*p| &p.ast else return db.Memo(semantic_queries.HeaderSignature){ .value = null, .diagnostics = .empty, .deps = .empty };
        if (resolved.value) |*rv| {
            if (item_tree.value) |*tree| {
                return semantic_queries.computeHeaderSignature(item_id, tree, parsed_ast, rv, self.gpa);
            }
        }
        return db.makeMemo(semantic_queries.HeaderSignature, null, .empty);
    }

    // ── Effective signature ──

    pub fn ensureEffectiveSignature(self: *@This(), instance_id: db.InstanceId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(semantic_queries.EffectiveSignature) {
        const qk = db.QueryKey{ .kind = .effective_signature, .source_id = instance_id.item.module.source_id, .instance_id = instance_id };
        return self.ensureGeneric(semantic_queries.EffectiveSignature, &self.effective_memos, instance_id, qk, true, @This().computeEffectiveSignature);
    }

    fn computeEffectiveSignature(self: *@This(), instance_id: db.InstanceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(semantic_queries.EffectiveSignature) {
        const source_id = instance_id.item.module.source_id;
        const module_id = instance_id.item.module;
        const typed = try self.ensureMemo(source_id, true, .typecheck);
        const item_tree = try self.ensureDiscoverMemo(module_id);
        if (typed.value) |*tv| {
            if (item_tree.value) |*tree| {
                return semantic_queries.computeEffectiveSignature(instance_id, tv, tree, self.gpa);
            }
        }
        return db.makeMemo(semantic_queries.EffectiveSignature, null, .empty);
    }

    // ── Body analysis / type-check body ──

    pub fn ensureBodyAnalysis(self: *@This(), instance_id: db.InstanceId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(semantic_queries.BodyAnalysis) {
        const qk = db.QueryKey{ .kind = .check_body, .source_id = instance_id.item.module.source_id, .instance_id = instance_id };
        return self.ensureGeneric(semantic_queries.BodyAnalysis, &self.body_memos, instance_id, qk, true, @This().computeBodyAnalysis);
    }

    fn computeBodyAnalysis(self: *@This(), instance_id: db.InstanceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(semantic_queries.BodyAnalysis) {
        const source_id = instance_id.item.module.source_id;
        const typed = try self.ensureMemo(source_id, true, .typecheck);
        const effective = try self.ensureEffectiveSignature(instance_id);
        if (typed.value) |*tv| {
            if (effective.value) |*eff| {
                return semantic_queries.computeBodyAnalysis(instance_id, eff, tv, self.gpa);
            }
        }
        return db.makeMemo(semantic_queries.BodyAnalysis, null, .empty);
    }

    // ── Lower body ──

    pub fn ensureLowerBodyMemo(self: *@This(), instance_id: db.InstanceId) (db.DbError || std.mem.Allocator.Error)!*db.Memo(ir_mod.FunctionIR) {
        const qk = db.QueryKey{ .kind = .lower_body, .source_id = instance_id.item.module.source_id, .instance_id = instance_id };
        return self.ensureGeneric(ir_mod.FunctionIR, &self.lower_body_memos, instance_id, qk, true, @This().computeLowerBody);
    }

    fn computeLowerBody(self: *@This(), instance_id: db.InstanceId) (db.DbError || std.mem.Allocator.Error)!db.Memo(ir_mod.FunctionIR) {
        const source_id = instance_id.item.module.source_id;
        const typed = try self.ensureMemo(source_id, true, .typecheck);
        const body = try self.ensureBodyAnalysis(instance_id);
        if (typed.value) |*tv| {
            if (body.value) |*bv| {
                const fir = ir_mod.computeLowerBody(tv, bv, self.gpa) catch {
                    return db.Memo(ir_mod.FunctionIR){ .value = null, .diagnostics = .empty, .deps = .empty };
                };
                return db.makeMemo(ir_mod.FunctionIR, fir, .empty);
            }
        }
        return db.makeMemo(ir_mod.FunctionIR, null, .empty);
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
            .discover_items => (try self.ensureDiscoverMemo(.{ .package_id = key.package_id, .source_id = key.source_id })).changed_at > revision,
            .module_scope => (try self.ensureScopeMemo(.{ .package_id = key.package_id, .source_id = key.source_id })).changed_at > revision,
            .resolve_item => (try self.ensureResolveItemMemo(key.item_id.?)).changed_at > revision,
            .header_signature => (try self.ensureHeaderSignature(key.item_id.?)).changed_at > revision,
            .effective_signature => (try self.ensureEffectiveSignature(key.instance_id.?)).changed_at > revision,
            .check_body => (try self.ensureBodyAnalysis(key.instance_id.?)).changed_at > revision,
            .lower_body => (try self.ensureLowerBodyMemo(key.instance_id.?)).changed_at > revision,
            else => false,
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
