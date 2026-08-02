const std = @import("std");
const structures = @import("structures.zig");

const LineInfo = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

fn lineInfoForOffset(source: []const u8, offset: usize) LineInfo {
    const safe_offset = @min(offset, source.len);
    var line: usize = 1;
    var column: usize = 1;
    var line_start: usize = 0;

    for (source[0..safe_offset], 0..) |byte, index| {
        if (byte == '\n') {
            line += 1;
            column = 1;
            line_start = index + 1;
        } else {
            column += 1;
        }
    }

    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    return .{
        .line = line,
        .column = column,
        .line_start = line_start,
        .line_end = line_end,
    };
}

fn highlightLen(span: structures.SourceSpan, line_start: usize, line_end: usize) usize {
    const start = @max(span.start, line_start);
    const end = @min(span.end, line_end);
    return if (end > start) end - start else 1;
}

pub fn renderDiagnostic(
    writer: *std.Io.Writer,
    source_path: []const u8,
    source: []const u8,
    diagnostic: structures.Diagnostic,
) !void {
    if (diagnostic.span) |span| {
        const info = lineInfoForOffset(source, span.start);
        try writer.print("\x1b[31merror:\x1b[0m {s}:{d}:{d}: {s}\n", .{
            source_path,
            info.line,
            info.column,
            diagnostic.message,
        });
        try writer.writeAll(source[info.line_start..info.line_end]);
        try writer.writeByte('\n');
        try writer.splatByteAll(' ', info.column - 1);
        try writer.writeByte('^');
        const highlight_len = highlightLen(span, info.line_start, info.line_end);
        if (highlight_len > 1) try writer.splatByteAll('~', highlight_len - 1);
        try writer.writeByte('\n');
        return;
    }

    try writer.print("\x1b[31merror:\x1b[0m {s}: {s}\n", .{ source_path, diagnostic.message });
}

pub fn renderDiagnostics(
    writer: *std.Io.Writer,
    source_path: []const u8,
    source: []const u8,
    diagnostics: []const structures.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        try renderDiagnostic(writer, source_path, source, diagnostic);
    }
}

test "render diagnostics with source spans and messages" {
    const source = "const x 1\nbeta gamma\n";
    const diagnostics = [_]structures.Diagnostic{
        .{
            .file_id = 1,
            .span = .{ .start = 8, .end = 9 },
            .message = "expected .equal, found .number_literal",
        },
        .{
            .file_id = 1,
            .span = .{ .start = 10, .end = 14 },
            .message = "four-byte highlight",
        },
        .{
            .file_id = 1,
            .span = null,
            .message = "file-wide failure",
        },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostics(&output.writer, "test.star", source, &diagnostics);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star:1:9: expected .equal, found .number_literal\n" ++
            "const x 1\n" ++
            "        ^\n" ++
            "\x1b[31merror:\x1b[0m test.star:2:1: four-byte highlight\n" ++
            "beta gamma\n" ++
            "^~~~\n" ++
            "\x1b[31merror:\x1b[0m test.star: file-wide failure\n",
        output.writer.buffered(),
    );
}

test "render diagnostic clamps locations past the source" {
    const diagnostic: structures.Diagnostic = .{
        .file_id = 1,
        .span = .{ .start = 100, .end = 101 },
        .message = "at eof",
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostic(&output.writer, "test.star", "line\n", diagnostic);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star:2:1: at eof\n\n^\n",
        output.writer.buffered(),
    );
}
