const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

pub const SourceId = u32;
pub const Revision = u64;

pub const QueryError = error{
    SourceNotFound,
    QueryCycle,
};

pub const DbError = QueryError || std.mem.Allocator.Error;

pub const QueryKind = enum {
    parse,
    typecheck,
    lower,
    compile,
};

pub const QueryKey = struct {
    kind: QueryKind,
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
    parse_hits: usize = 0,
    parse_recomputes: usize = 0,
    type_hits: usize = 0,
    type_recomputes: usize = 0,
    lower_hits: usize = 0,
    lower_recomputes: usize = 0,
    compile_hits: usize = 0,
    compile_recomputes: usize = 0,
    dependency_checks: usize = 0,
    dependency_invalidations: usize = 0,
};

pub const Stage = enum {
    parse,
    typecheck,
    lower,
    compile,
};

pub const CompileResult = struct {
    bytes: ?[]const u8,
    diagnostics: []const diagnostics.Diagnostic,
};

pub fn queryKeyEql(a: QueryKey, b: QueryKey) bool {
    return a.kind == b.kind and a.source_id == b.source_id;
}

pub fn spanEql(a: ?ast.Span, b: ?ast.Span) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.start == b.?.start and a.?.end == b.?.end;
}

pub fn diagnosticsEqual(a: []const diagnostics.Diagnostic, b: []const diagnostics.Diagnostic) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.stage != right.stage) return false;
        if (!spanEql(left.span, right.span)) return false;
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

pub fn appendDependencyUnique(deps: *std.ArrayList(Dependency), gpa: std.mem.Allocator, dep: Dependency) std.mem.Allocator.Error!void {
    for (deps.items) |existing| {
        if (dependencyEql(existing, dep)) return;
    }
    try deps.append(gpa, dep);
}
