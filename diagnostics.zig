const std = @import("std");
const ast = @import("ast.zig");

pub const Stage = enum {
    parse,
    typecheck,
    lower,
    compile,
};

pub const Diagnostic = struct {
    stage: Stage,
    span: ?ast.Span,
    message: []const u8,
};

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
