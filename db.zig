const std = @import("std");
const ast = @import("ast.zig");

pub const SourceId = u32;
pub const Revision = u64;

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
    kind: Stage,
    source_id: SourceId,
};

pub const Dependency = union(enum) {
    source: SourceId,
    query: QueryKey,
};

pub const QueryStats = struct {
    revision: Revision = 0,
    source_sets: usize = 0,
    source_unchanged: usize = 0,
    hits: [5]usize = .{0} ** 5,
    recomputes: [5]usize = .{0} ** 5,
    dependency_checks: usize = 0,
    dependency_invalidations: usize = 0,

    pub fn hit(self: *QueryStats, stage: Stage) void {
        self.hits[@intFromEnum(stage)] += 1;
    }

    pub fn recompute(self: *QueryStats, stage: Stage) void {
        self.recomputes[@intFromEnum(stage)] += 1;
    }

    pub fn print(self: *const QueryStats, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, "; query diagnostics:\n");
        try out.print(gpa, ";   revision: {d}\n", .{self.revision});
        try out.print(gpa, ";   source_sets: {d}\n", .{self.source_sets});
        try out.print(gpa, ";   source_unchanged: {d}\n", .{self.source_unchanged});
        inline for (std.meta.tags(Stage)) |stage| {
            const i = @intFromEnum(stage);
            try out.print(gpa, ";   {s}: hits={d} recomputes={d}\n", .{
                stageLabel(stage), self.hits[i], self.recomputes[i],
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
        value: ?T,
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
        .query => |lhs| b == .query and lhs.kind == b.query.kind and lhs.source_id == b.query.source_id,
    };
}

pub fn appendDependencyUnique(deps: *std.ArrayList(Dependency), gpa: std.mem.Allocator, dep: Dependency) std.mem.Allocator.Error!void {
    for (deps.items) |existing| {
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
        try out.print(gpa, "error: {s}:{d}:{d}: {s}\n", .{ source_path, info.line, info.column, diag.message });

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

    try out.print(gpa, "error: {s}: {s}\n", .{ source_path, diag.message });
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
