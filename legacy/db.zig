const std = @import("std");
const ast = @import("ast.zig");

pub const SourceId = u32;
pub const Revision = u64;

pub const PackageId = u32;

pub const ModuleId = struct {
    package_id: PackageId,
    source_id: SourceId,
};

pub const ItemKind = enum {
    function,
    comptime_value,
    comptime_struct,
    top_level_entry,
    synthetic,
};

pub const ItemId = struct {
    module: ModuleId,
    kind: ItemKind,
    name_hash: u64,
};

pub const BodyKind = enum {
    function,
    comptime_value,
    struct_policy_hook,
    top_level_entry,
};

pub const BodyId = struct {
    owner: ItemId,
    kind: BodyKind,
};

pub const TypeId = u32;
pub const ComptimeArgHash = u64;

pub const InstanceId = struct {
    item: ItemId,
    comptime_args_hash: ComptimeArgHash,
};

pub const CtEvalKey = struct {
    body: BodyId,
    instance: ?InstanceId = null,
    args_hash: ComptimeArgHash,
    target_hash: u64,
};

pub const ProgramKey = struct {
    package_id: PackageId,
    entry: InstanceId,
};

pub const Stage = enum {
    parse,
    resolve,
    typecheck,
    lower,
    compile,
};

pub fn stageLabel(stage: Stage) []const u8 {
    return switch (stage) {
        .parse => "parse",
        .resolve => "resolve",
        .typecheck => "type",
        .lower => "lower",
        .compile => "compile",
    };
}

pub const QueryKind = enum {
    parse,
    resolve,
    typecheck,
    lower,
    compile,
    discover_items,
    module_scope,
    package_scope,
    resolve_item,
    header_signature,
    effective_signature,
    comptime_value,
    struct_layout,
    ownership_policy,
    check_body,
    lower_body,
    ct_lower_body,
    ct_eval,

    pub const count = @typeInfo(QueryKind).@"enum".fields.len;

    pub fn label(self: QueryKind) []const u8 {
        return switch (self) {
            .parse => "parse",
            .resolve => "resolve",
            .typecheck => "type",
            .lower => "lower",
            .compile => "compile",
            .discover_items => "discover_items",
            .module_scope => "module_scope",
            .package_scope => "package_scope",
            .resolve_item => "resolve_item",
            .header_signature => "header_signature",
            .effective_signature => "effective_signature",
            .comptime_value => "comptime_value",
            .struct_layout => "struct_layout",
            .ownership_policy => "ownership_policy",
            .check_body => "check_body",
            .lower_body => "lower_body",
            .ct_lower_body => "ct_lower_body",
            .ct_eval => "ct_eval",
        };
    }

    pub fn fromStage(stage_value: Stage) QueryKind {
        return switch (stage_value) {
            .parse => .parse,
            .resolve => .resolve,
            .typecheck => .typecheck,
            .lower => .lower,
            .compile => .compile,
        };
    }

    pub fn stage(self: QueryKind) ?Stage {
        return switch (self) {
            .parse => .parse,
            .resolve => .resolve,
            .typecheck => .typecheck,
            .lower => .lower,
            .compile => .compile,
            else => null,
        };
    }
};

pub const Diagnostic = struct {
    stage: Stage,
    span: ?ast.Span,
    message: []const u8,
    message_allocated: bool = false,
};

pub const QueryError = error{
    SourceNotFound,
    QueryCycle,
};

pub const DbError = QueryError || std.mem.Allocator.Error;

pub const QueryKey = struct {
    kind: QueryKind,
    source_id: SourceId,
    package_id: PackageId = 0,
    module_id: ModuleId = .{ .package_id = 0, .source_id = 0 },
    item_id: ?ItemId = null,
    body_id: ?BodyId = null,
    type_id: ?TypeId = null,
    instance_id: ?InstanceId = null,
    ct_eval_key: ?CtEvalKey = null,
    program_key: ?ProgramKey = null,
};

pub const Dependency = union(enum) {
    source: SourceId,
    query: QueryKey,
};

pub const QueryStats = struct {
    revision: Revision = 0,
    source_sets: usize = 0,
    source_unchanged: usize = 0,
    hits: [QueryKind.count]usize = .{0} ** QueryKind.count,
    recomputes: [QueryKind.count]usize = .{0} ** QueryKind.count,
    dependency_checks: usize = 0,
    dependency_invalidations: usize = 0,

    pub fn hit(self: *QueryStats, kind: QueryKind) void {
        self.hits[@intFromEnum(kind)] += 1;
    }

    pub fn recompute(self: *QueryStats, kind: QueryKind) void {
        self.recomputes[@intFromEnum(kind)] += 1;
    }

    pub fn print(self: *const QueryStats, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, "; query diagnostics:\n");
        try out.print(gpa, ";   revision: {d}\n", .{self.revision});
        try out.print(gpa, ";   source_sets: {d}\n", .{self.source_sets});
        try out.print(gpa, ";   source_unchanged: {d}\n", .{self.source_unchanged});
        for (std.meta.tags(QueryKind)) |kind| {
            const i = @intFromEnum(kind);
            const h = self.hits[i];
            const r = self.recomputes[i];
            const is_legacy = kind.stage() != null;
            if (h == 0 and r == 0 and !is_legacy) continue;
            try out.print(gpa, ";   {s}: hits={d} recomputes={d}\n", .{
                kind.label(), h, r,
            });
        }
        try out.print(gpa, ";   dependencies: checks={d} invalidations={d}\n", .{ self.dependency_checks, self.dependency_invalidations });
    }
};

pub const CompileResult = struct {
    bytes: ?[]const u8,
    diagnostics: []const Diagnostic,
};

pub fn Memo(comptime T: type) type {
    return struct {
        value: ?T, // value can be null when a query has failed, producing diagnostics only
        diagnostics: std.ArrayList(Diagnostic),
        deps: std.ArrayList(Dependency),
        verified_at: Revision = 0,
        changed_at: Revision = 0,
        computing: bool = false,
    };
}

pub fn diagnosticsEqual(a: []const Diagnostic, b: []const Diagnostic) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.stage != right.stage) return false;
        if (!(if (left.span) |ls| (if (right.span) |rs| ls.start == rs.start and ls.end == rs.end else false) else right.span == null)) return false;
        if (!std.mem.eql(u8, left.message, right.message)) return false;
    }
    return true;
}

pub fn valuesEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn dependencyEql(a: Dependency, b: Dependency) bool {
    return switch (a) {
        .source => |lhs| b == .source and lhs == b.source,
        .query => |lhs| b == .query and queryKeyEql(lhs, b.query),
    };
}

pub fn queryKeyEql(a: QueryKey, b: QueryKey) bool {
    if (a.kind != b.kind) return false;
    if (a.source_id != b.source_id) return false;
    if (a.package_id != b.package_id) return false;
    if (!moduleIdEql(a.module_id, b.module_id)) return false;
    if (!optionalItemIdEql(a.item_id, b.item_id)) return false;
    if (!optionalBodyIdEql(a.body_id, b.body_id)) return false;
    if (a.type_id != b.type_id) return false;
    if (!optionalInstanceIdEql(a.instance_id, b.instance_id)) return false;
    if (!optionalCtEvalKeyEql(a.ct_eval_key, b.ct_eval_key)) return false;
    if (!optionalProgramKeyEql(a.program_key, b.program_key)) return false;
    return true;
}

pub fn moduleIdEql(a: ModuleId, b: ModuleId) bool {
    return a.package_id == b.package_id and a.source_id == b.source_id;
}

pub fn itemIdEql(a: ItemId, b: ItemId) bool {
    return moduleIdEql(a.module, b.module) and a.kind == b.kind and a.name_hash == b.name_hash;
}

fn optionalItemIdEql(a: ?ItemId, b: ?ItemId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return itemIdEql(a.?, b.?);
}

pub fn bodyIdEql(a: BodyId, b: BodyId) bool {
    return itemIdEql(a.owner, b.owner) and a.kind == b.kind;
}

fn optionalBodyIdEql(a: ?BodyId, b: ?BodyId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return bodyIdEql(a.?, b.?);
}

pub fn instanceIdEql(a: InstanceId, b: InstanceId) bool {
    return itemIdEql(a.item, b.item) and a.comptime_args_hash == b.comptime_args_hash;
}

fn optionalInstanceIdEql(a: ?InstanceId, b: ?InstanceId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return instanceIdEql(a.?, b.?);
}

pub fn ctEvalKeyEql(a: CtEvalKey, b: CtEvalKey) bool {
    if (!bodyIdEql(a.body, b.body)) return false;
    if (!optionalInstanceIdEql(a.instance, b.instance)) return false;
    return a.args_hash == b.args_hash and a.target_hash == b.target_hash;
}

fn optionalCtEvalKeyEql(a: ?CtEvalKey, b: ?CtEvalKey) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return ctEvalKeyEql(a.?, b.?);
}

pub fn programKeyEql(a: ProgramKey, b: ProgramKey) bool {
    return a.package_id == b.package_id and instanceIdEql(a.entry, b.entry);
}

fn optionalProgramKeyEql(a: ?ProgramKey, b: ?ProgramKey) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return programKeyEql(a.?, b.?);
}

pub fn appendDependencyUnique(deps: *std.ArrayList(Dependency), gpa: std.mem.Allocator, dep: Dependency) std.mem.Allocator.Error!void {
    for (deps.items) |existing| { // Replace with set (AutoHashmap(Dependency, void)) if order does not matter
        if (dependencyEql(existing, dep)) return;
    }
    try deps.append(gpa, dep);
}

pub fn initDiagnosticList(
    gpa: std.mem.Allocator,
    inherited: []const Diagnostic,
    extra_capacity: usize,
) std.mem.Allocator.Error!std.ArrayList(Diagnostic) {
    var list = try std.ArrayList(Diagnostic).initCapacity(gpa, inherited.len + extra_capacity);
    errdefer list.deinit(gpa);
    for (inherited) |diag| {
        try list.append(gpa, .{
            .stage = diag.stage,
            .span = diag.span,
            .message = diag.message,
        });
    }
    return list;
}

pub fn appendStageError(
    list: *std.ArrayList(Diagnostic),
    gpa: std.mem.Allocator,
    stage: Stage,
    message: []const u8,
) std.mem.Allocator.Error!void {
    try list.append(gpa, .{
        .stage = stage,
        .span = null,
        .message = message,
    });
}

pub fn makeMemo(comptime T: type, value: ?T, diagnostics_list: std.ArrayList(Diagnostic)) Memo(T) {
    return .{
        .value = value,
        .diagnostics = diagnostics_list,
        .deps = .empty,
        .verified_at = 0,
        .changed_at = 0,
        .computing = false,
    };
}

// ── Source-line diagnostics formatting ──

const LineInfo = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

fn lineInfoForOffset(source: []const u8, offset: usize) LineInfo {
    var line: usize = 1;
    var column: usize = 1;
    var line_start: usize = 0;

    var idx: usize = 0;
    const safe_offset = if (offset > source.len) source.len else offset;
    while (idx < safe_offset) : (idx += 1) {
        if (source[idx] == '\n') {
            line += 1;
            column = 1;
            line_start = idx + 1;
        } else {
            column += 1;
        }
    }

    var line_end = source.len;
    idx = line_start;
    while (idx < source.len) : (idx += 1) {
        if (source[idx] == '\n') {
            line_end = idx;
            break;
        }
    }

    return .{
        .line = line,
        .column = column,
        .line_start = line_start,
        .line_end = line_end,
    };
}

fn highlightLen(span: ast.Span, line_start: usize, line_end: usize) usize {
    const start = if (span.start < line_start) line_start else span.start;
    const capped_end = if (span.end > line_end) line_end else span.end;
    if (capped_end <= start) return 1;
    return capped_end - start;
}

pub fn appendDiagnostic(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    diag: Diagnostic,
) !void {
    if (diag.span) |span| {
        const info = lineInfoForOffset(source, span.start);
        try out.print(gpa, "\x1b[31merror:\x1b[0m {s}:{d}:{d}: {s}\n", .{ source_path, info.line, info.column, diag.message });

        const line_text = source[info.line_start..info.line_end];
        try out.appendSlice(gpa, line_text);
        try out.appendSlice(gpa, "\n");

        const caret_indent = if (info.column > 0) info.column - 1 else 0;
        try out.appendNTimes(gpa, ' ', caret_indent);
        try out.append(gpa, '^');

        const extra = highlightLen(span, info.line_start, info.line_end);
        if (extra > 1) try out.appendNTimes(gpa, '~', extra - 1);
        try out.appendSlice(gpa, "\n");
        return;
    }

    try out.print(gpa, "\x1b[31merror:\x1b[0m {s}: {s}\n", .{ source_path, diag.message });
}

pub fn appendDiagnostics(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    diags: []const Diagnostic,
) !void {
    for (diags) |diag| {
        try appendDiagnostic(out, gpa, source_path, source, diag);
    }
}
