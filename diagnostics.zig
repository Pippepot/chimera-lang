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

fn writeType(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId) !void {
    try writer.writeByte('`');
    try writeTypeInner(types, writer, type_id);
    try writer.writeByte('`');
}

fn writeTypeInner(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId) !void {
    switch (type_id) {
        .int, .bool, .unit, .none, .never => return writer.writeAll(@tagName(type_id)),
        _ => {},
    }
    if (try types.structName(type_id)) |name| return writer.writeAll(name);
    if (try types.callable(type_id)) |callable| {
        try writer.writeAll(if (callable.is_fallible) "fallible(" else "func(");
        for (callable.parameter_types, 0..) |parameter_type, index| {
            if (index != 0) try writer.writeAll(", ");
            try writeTypeInner(types, writer, parameter_type);
        }
        try writer.writeAll(") ");
        return writeTypeInner(types, writer, callable.return_type);
    }

    const members = (try types.variantMembers(type_id)) orelse unreachable;
    for (members, 0..) |member, index| {
        if (index != 0) try writer.writeAll(" | ");
        if (try types.callable(member) != null) {
            try writer.writeByte('(');
            try writeTypeInner(types, writer, member);
            try writer.writeByte(')');
        } else {
            try writeTypeInner(types, writer, member);
        }
    }
}

fn writeMismatch(types: anytype, writer: *std.Io.Writer, mismatch: structures.Diagnostic.TypeMismatch) !void {
    try writer.writeAll("expected ");
    try writeType(types, writer, mismatch.expected);
    try writer.writeAll(", found ");
    try writeType(types, writer, mismatch.found);
}

fn writeToken(writer: *std.Io.Writer, tag: structures.Token.Tag) !void {
    const spelling: ?[]const u8 = switch (tag) {
        .equal => "=",
        .equal_angle_bracket_right => "=>",
        .plus => "+",
        .minus => "-",
        .asterisk => "*",
        .slash => "/",
        .percent => "%",
        .caret => "^",
        .pipe => "|",
        .ampersand => "&",
        .angle_bracket_left => "<",
        .angle_bracket_angle_bracket_left => "<<",
        .angle_bracket_right => ">",
        .angle_bracket_angle_bracket_right => ">>",
        .equal_equal => "==",
        .plus_equal => "+=",
        .minus_equal => "-=",
        .asterisk_equal => "*=",
        .slash_equal => "/=",
        .percent_equal => "%=",
        .caret_equal => "^=",
        .pipe_equal => "|=",
        .ampersand_equal => "&=",
        .angle_bracket_left_angle_bracket_right => "<>",
        .angle_bracket_left_equal => "<=",
        .angle_bracket_angle_bracket_left_equal => "<<=",
        .angle_bracket_right_equal => ">=",
        .angle_bracket_angle_bracket_right_equal => ">>=",
        .l_brace => "{",
        .r_brace => "}",
        .l_paren => "(",
        .r_paren => ")",
        .l_bracket => "[",
        .r_bracket => "]",
        .question_mark => "?",
        .arrow => "->",
        .tilde => "~",
        .period => ".",
        .comma => ",",
        .colon => ":",
        .semicolon => ";",
        .ellipsis2 => "..",
        .ellipsis3 => "...",
        else => null,
    };
    if (spelling) |text| {
        try writer.print("`{s}`", .{text});
        return;
    }
    switch (tag) {
        .invalid => try writer.writeAll("an invalid token"),
        .eof => try writer.writeAll("end of file"),
        .indent => try writer.writeAll("an indented block"),
        .dedent => try writer.writeAll("the end of the block"),
        .identifier => try writer.writeAll("an identifier"),
        .number_literal => try writer.writeAll("a number"),
        .char_literal => try writer.writeAll("a character literal"),
        .string_literal => try writer.writeAll("a string literal"),
        else => {
            const name = @tagName(tag);
            if (std.mem.startsWith(u8, name, "keyword_")) {
                try writer.print("`{s}`", .{name["keyword_".len..]});
            } else {
                try writer.print("{s}", .{name});
            }
        },
    }
}

fn writeSourceLabel(writer: *std.Io.Writer, label: []const u8, source: []const u8, span: ?structures.SourceSpan) !void {
    try writer.writeAll(label);
    const focus = span orelse return;
    const start = @min(focus.start, source.len);
    const end = @min(@max(focus.end, start), source.len);
    if (end == start or std.mem.indexOfScalar(u8, source[start..end], '\n') != null) return;
    try writer.print(": `{s}`", .{source[start..end]});
}

fn writeKindMessage(types: anytype, writer: *std.Io.Writer, source: []const u8, span: ?structures.SourceSpan, kind: structures.Diagnostic.Kind) !void {
    switch (kind) {
        .expected_token => |payload| {
            try writer.writeAll("expected ");
            try writeToken(writer, payload.expected);
            try writer.writeAll(", found ");
            try writeToken(writer, payload.found);
        },
        .invalid_expression => |tag| {
            try writer.writeAll("expected an expression, found ");
            try writeToken(writer, tag);
        },
        .duplicate_top_level_declaration => {
            try writeSourceLabel(writer, "top-level name is already declared", source, span);
        },
        .declaration_cycle => try writeSourceLabel(writer, "declaration depends on itself", source, span),
        .static_initializer_not_supported => try writer.writeAll("this static initializer is not supported yet"),
        .struct_member_not_supported => try writer.writeAll("this struct member is not supported yet"),
        .duplicate_struct_field => try writeSourceLabel(writer, "struct field is already declared", source, span),
        .struct_field_type_not_supported => try writer.writeAll("this struct field type is not supported yet"),
        .recursive_struct_containment => try writeSourceLabel(writer, "struct recursively contains itself by value through field", source, span),
        .static_initializer_type_mismatch => |mismatch| {
            try writer.writeAll("static initializer type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .type_value_used_as_runtime_value => try writer.writeAll("a type cannot be used as a runtime value"),
        .value_used_as_type => try writer.writeAll("a runtime value cannot be used as a type"),
        .function_annotation_not_supported => try writer.writeAll("type annotations on function bindings are not supported yet"),
        .parameter_mode_not_supported => try writer.writeAll("parameter access modes are not supported yet"),
        .duplicate_parameter => {
            try writeSourceLabel(writer, "parameter name is already declared", source, span);
        },
        .parameter_type_missing => try writer.writeAll("parameter requires a type annotation"),
        .parameter_type_not_supported => try writer.writeAll("this parameter type is not supported yet"),
        .return_type_not_supported => try writer.writeAll("this return type is not supported yet"),
        .top_level_return => try writer.writeAll("cannot return from top-level code"),
        .break_outside_loop => try writer.writeAll("break is only allowed inside a loop"),
        .continue_outside_loop => try writer.writeAll("continue is only allowed inside a loop"),
        .expression_not_supported => try writer.writeAll("this expression is not supported yet"),
        .struct_initializer_not_struct => |found| {
            try writer.writeAll("struct initializer requires a struct type, found ");
            try writeType(types, writer, found);
        },
        .unknown_struct_field => try writeSourceLabel(writer, "unknown struct field", source, span),
        .duplicate_struct_initializer_field => try writeSourceLabel(writer, "struct field is initialized more than once", source, span),
        .missing_struct_initializer_field => try writer.writeAll("struct initializer is missing a required field"),
        .struct_initializer_field_type_mismatch => |mismatch| {
            try writer.writeAll("struct field initializer type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .field_access_not_struct => |found| {
            try writer.writeAll("field access requires a struct value, found ");
            try writeType(types, writer, found);
        },
        .unknown_field => try writeSourceLabel(writer, "unknown struct field", source, span),
        .duplicate_local_binding => {
            try writeSourceLabel(writer, "binding is already declared in this scope", source, span);
        },
        .local_type_not_supported => try writer.writeAll("this local binding type is not supported yet"),
        .unknown_type => try writeSourceLabel(writer, "unknown type", source, span),
        .unknown_value => {
            try writeSourceLabel(writer, "unknown value", source, span);
        },
        .assignment_target_not_local => try writer.writeAll("assignment target must be a mutable local binding"),
        .assignment_to_immutable => {
            try writeSourceLabel(writer, "cannot assign to immutable binding", source, span);
        },
        .assignment_type_mismatch => |mismatch| {
            try writer.writeAll("assignment type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .integer_literal_not_decimal => try writer.writeAll("integer literal must use decimal notation"),
        .integer_literal_out_of_range => try writer.writeAll("integer literal is outside the supported i32 range"),
        .fallible_condition_not_supported => try writer.writeAll("this fallible condition form is not supported yet"),
        .if_condition_not_fallible => try writer.writeAll("condition must be a comparison or another fallible expression"),
        .inspection_type_not_supported => try writer.writeAll("this inspection type is not supported yet"),
        .variant_inspection_operand_not_variant => |found| {
            try writer.writeAll("variant inspection requires a variant value, found ");
            try writeType(types, writer, found);
        },
        .condition_binding_must_be_immutable => try writer.writeAll("condition bindings must be immutable"),
        .value_not_callable => {
            try writeSourceLabel(writer, "value is not callable", source, span);
        },
        .duplicate_variant_member_type => try writer.writeAll("variant contains the same member type more than once"),
        .local_type_mismatch => |mismatch| {
            try writer.writeAll("initializer type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .negation_operand_not_int => |found| {
            try writer.writeAll("negation requires `int`, found ");
            try writeType(types, writer, found);
        },
        .arithmetic_operand_not_int => |found| {
            try writer.writeAll("arithmetic requires `int`, found ");
            try writeType(types, writer, found);
        },
        .comparison_operand_not_int => |found| {
            try writer.writeAll("comparison requires `int`, found ");
            try writeType(types, writer, found);
        },
        .equality_operand_not_supported => |found| {
            try writer.writeAll("equality is not supported for ");
            try writeType(types, writer, found);
        },
        .equality_operand_type_mismatch => |mismatch| {
            try writer.writeAll("equality operand type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .fallible_expression_outside_fallible_function => try writer.writeAll("fallible expression must be handled or used inside a fallible function"),
        .missing_return_value => |expected| {
            try writer.writeAll("function must return ");
            try writeType(types, writer, expected);
            try writer.writeAll(" on every reachable path");
        },
        .return_type_mismatch => |mismatch| {
            try writer.writeAll("return type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .unknown_function => {
            try writeSourceLabel(writer, "unknown function", source, span);
        },
        .call_argument_count_mismatch => |count| try writer.print("expected {d} call argument{s}, found {d}", .{
            count.expected,
            if (count.expected == 1) "" else "s",
            count.found,
        }),
        .call_argument_type_mismatch => |mismatch| {
            try writer.writeAll("argument type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
    }
}

pub fn renderDiagnostic(
    types: anytype,
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
        try writeKindMessage(types, writer, source, diagnostic.span, diagnostic.kind);
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
    try writeKindMessage(types, writer, source, diagnostic.span, diagnostic.kind);
    try writer.writeByte('\n');
}

pub fn renderDiagnostics(
    types: anytype,
    writer: *std.Io.Writer,
    source_path: []const u8,
    source: []const u8,
    diagnostics: []const structures.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        try renderDiagnostic(types, writer, source_path, source, diagnostic);
    }
}

const PrimitiveTypes = struct {
    fn structName(_: @This(), _: structures.TypeId) !?[]const u8 {
        return null;
    }

    fn callable(_: @This(), _: structures.TypeId) !?structures.CallableType {
        return null;
    }

    fn variantMembers(_: @This(), _: structures.TypeId) !?[]const structures.TypeId {
        return null;
    }
};

const DetailedTypes = struct {
    const int_callable = structures.TypeId.fromInterned(@enumFromInt(0));
    const bool_callable = structures.TypeId.fromInterned(@enumFromInt(1));
    const callable_variant = structures.TypeId.fromInterned(@enumFromInt(2));
    const structure = structures.TypeId.fromInterned(@enumFromInt(3));

    fn structName(_: @This(), type_id: structures.TypeId) !?[]const u8 {
        return if (type_id == structure) "Pair" else null;
    }

    fn callable(_: @This(), type_id: structures.TypeId) !?structures.CallableType {
        if (type_id == int_callable) return .{
            .parameter_types = &.{.int},
            .return_type = .int,
            .is_fallible = false,
        };
        if (type_id == bool_callable) return .{
            .parameter_types = &.{.bool},
            .return_type = .int,
            .is_fallible = true,
        };
        return null;
    }

    fn variantMembers(_: @This(), type_id: structures.TypeId) !?[]const structures.TypeId {
        if (type_id == callable_variant) return &.{ int_callable, .none };
        return null;
    }
};

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
            .kind = .duplicate_top_level_declaration,
        },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostics(PrimitiveTypes{}, &output.writer, "test.star", source, &diagnostics);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star:1:9: expected `=`, found a number\n" ++
            "const x 1\n" ++
            "        ^\n" ++
            "\x1b[31merror:\x1b[0m test.star:2:1: unknown value: `beta`\n" ++
            "beta gamma\n" ++
            "^~~~\n" ++
            "\x1b[31merror:\x1b[0m test.star: top-level name is already declared\n",
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
    try renderDiagnostic(PrimitiveTypes{}, &output.writer, "test.star", "line\n", diagnostic);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star:2:1: unknown value\n\n^\n",
        output.writer.buffered(),
    );
}

test "render type mismatches and call counts with concrete facts" {
    const source = "exit(b)\n";
    const diagnostics = [_]structures.Diagnostic{
        .{
            .file_id = 1,
            .span = .{ .start = 5, .end = 6 },
            .kind = .{ .call_argument_type_mismatch = .{
                .expected = .int,
                .found = .none,
            } },
        },
        .{
            .file_id = 1,
            .span = .{ .start = 0, .end = 4 },
            .kind = .{ .call_argument_count_mismatch = .{ .expected = 1, .found = 0 } },
        },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostics(PrimitiveTypes{}, &output.writer, "test.chi", source, &diagnostics);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.chi:1:6: argument type mismatch: expected `int`, found `none`\n" ++
            "exit(b)\n" ++
            "     ^\n" ++
            "\x1b[31merror:\x1b[0m test.chi:1:1: expected 1 call argument, found 0\n" ++
            "exit(b)\n" ++
            "^~~~\n",
        output.writer.buffered(),
    );
}

test "render diagnostics preserve callable signatures and nested variants" {
    const diagnostic: structures.Diagnostic = .{
        .file_id = 1,
        .span = null,
        .kind = .{ .static_initializer_type_mismatch = .{
            .expected = DetailedTypes.callable_variant,
            .found = DetailedTypes.bool_callable,
        } },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostic(DetailedTypes{}, &output.writer, "test.star", "", diagnostic);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.star: static initializer type mismatch: expected `(func(int) int) | none`, found `fallible(bool) int`\n",
        output.writer.buffered(),
    );
}

test "render diagnostics use nominal struct names" {
    const diagnostic: structures.Diagnostic = .{
        .file_id = 1,
        .span = null,
        .kind = .{ .return_type_mismatch = .{
            .expected = DetailedTypes.structure,
            .found = .int,
        } },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderDiagnostic(DetailedTypes{}, &output.writer, "test.chi", "", diagnostic);

    try std.testing.expectEqualStrings(
        "\x1b[31merror:\x1b[0m test.chi: return type mismatch: expected `Pair`, found `int`\n",
        output.writer.buffered(),
    );
}
