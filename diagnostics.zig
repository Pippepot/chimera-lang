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

fn writeKindMessage(writer: *std.Io.Writer, kind: structures.Diagnostic.Kind) !void {
    switch (kind) {
        .expected_token => |payload| try writer.print("expected {}, found {}", .{ payload.expected, payload.found }),
        .invalid_expression => |tag| try writer.print("{} is not a valid expression", .{tag}),
        .duplicate_top_level_function => try writer.writeAll("duplicate top-level function name"),
        .parameter_mode_not_supported => try writer.writeAll("parameter modes are not supported yet"),
        .duplicate_parameter => try writer.writeAll("duplicate parameter"),
        .parameter_type_missing => try writer.writeAll("function parameters must declare a type"),
        .parameter_type_not_supported => try writer.writeAll("only int and variant parameter types are supported yet"),
        .return_type_missing => try writer.writeAll("function must declare a return type"),
        .return_type_not_supported => try writer.writeAll("only int, unit, and variant return types are supported yet"),
        .entry_statement_not_supported => try writer.writeAll("runtime top-level statements are not supported yet"),
        .body_shape_not_supported => try writer.writeAll("function body must end in one return; preceding statements must be const bindings or calls"),
        .expression_not_supported => try writer.writeAll("expression is not supported yet"),
        .duplicate_local_binding => try writer.writeAll("duplicate local binding"),
        .local_type_not_supported => try writer.writeAll("only int and unit local bindings are supported yet"),
        .unknown_value => try writer.writeAll("unknown value"),
        .integer_literal_not_decimal => try writer.writeAll("only decimal integer literals are supported yet"),
        .integer_literal_out_of_range => try writer.writeAll("integer literal does not fit i32"),
        .fallible_condition_not_supported => try writer.writeAll("fallible condition form is not supported yet"),
        .if_condition_not_fallible => try writer.writeAll("if condition must be a fallible expression"),
        .if_branch_shape_not_supported => try writer.writeAll("if branch must contain one expression"),
        .value_not_callable => try writer.writeAll("value is not callable"),
        .duplicate_variant_member_type => try writer.writeAll("duplicate variant member type"),
        .local_type_mismatch => try writer.writeAll("local binding type does not match initializer"),
        .negation_operand_not_int => try writer.writeAll("integer negation requires an int operand"),
        .arithmetic_operands_not_int => try writer.writeAll("integer operation requires int operands"),
        .comparison_operands_not_int => try writer.writeAll("fallible comparison requires int operands"),
        .missing_return_value => |return_type| switch (return_type) {
            .int => try writer.writeAll("function returning int must return a value"),
            else => try writer.writeAll("function return type requires a value"),
        },
        .return_type_mismatch => try writer.writeAll("return type does not match function signature"),
        .if_branch_type_mismatch => try writer.writeAll("if branches must have the same type"),
        .unknown_function => try writer.writeAll("unknown function"),
        .call_argument_count_mismatch => try writer.writeAll("call argument count does not match function signature"),
        .call_argument_type_mismatch => try writer.writeAll("call argument type does not match function signature"),
    }
}

pub fn renderDiagnostic(
    writer: *std.Io.Writer,
    source_path: []const u8,
    source: []const u8,
    diagnostic: structures.Diagnostic,
) !void {
    if (diagnostic.span) |span| {
        const info = lineInfoForOffset(source, span.start);
        try writer.print("\x1b[31merror:\x1b[0m {s}:{d}:{d}: ", .{
            source_path,
            info.line,
            info.column,
        });
        try writeKindMessage(writer, diagnostic.kind);
        try writer.writeByte('\n');
        try writer.writeAll(source[info.line_start..info.line_end]);
        try writer.writeByte('\n');
        try writer.splatByteAll(' ', info.column - 1);
        try writer.writeByte('^');
        const highlight_len = highlightLen(span, info.line_start, info.line_end);
        if (highlight_len > 1) try writer.splatByteAll('~', highlight_len - 1);
        try writer.writeByte('\n');
        return;
    }

    try writer.print("\x1b[31merror:\x1b[0m {s}: ", .{source_path});
    try writeKindMessage(writer, diagnostic.kind);
    try writer.writeByte('\n');
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
            .kind = .{ .expected_token = .{ .expected = .equal, .found = .number_literal } },
        },
        .{
            .file_id = 1,
            .span = .{ .start = 10, .end = 14 },
            .kind = .unknown_value,
        },
        .{
            .file_id = 1,
            .span = null,
            .kind = .duplicate_top_level_function,
        },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostics(&output.writer, "test.star", source, &diagnostics);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star:1:9: expected .equal, found .number_literal\n" ++
            "const x 1\n" ++
            "        ^\n" ++
            "\x1b[31merror:\x1b[0m test.star:2:1: unknown value\n" ++
            "beta gamma\n" ++
            "^~~~\n" ++
            "\x1b[31merror:\x1b[0m test.star: duplicate top-level function name\n",
        output.writer.buffered(),
    );
}

test "render diagnostic clamps locations past the source" {
    const diagnostic: structures.Diagnostic = .{
        .file_id = 1,
        .span = .{ .start = 100, .end = 101 },
        .kind = .unknown_value,
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostic(&output.writer, "test.star", "line\n", diagnostic);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star:2:1: unknown value\n\n^\n",
        output.writer.buffered(),
    );
}
