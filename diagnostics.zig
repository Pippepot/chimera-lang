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
        for (callable.parameters, 0..) |parameter, index| {
            if (index != 0) try writer.writeAll(", ");
            if (parameter.mode != .imm) try writer.print("{s} ", .{@tagName(parameter.mode)});
            try writeTypeInner(types, writer, parameter.type_id);
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
        .struct_member_not_supported => try writer.writeAll("struct bodies currently support only fields and `move`, `copy`, or `drop` properties"),
        .duplicate_struct_field => try writeSourceLabel(writer, "struct field is already declared", source, span),
        .duplicate_struct_property => try writeSourceLabel(writer, "struct ownership property is already declared", source, span),
        .unknown_struct_property => {
            try writeSourceLabel(writer, "unknown struct ownership property", source, span);
            try writer.writeAll("; expected `move`, `copy`, or `drop`");
        },
        .invalid_struct_property_value => |property| {
            try writeSourceLabel(writer, "invalid ownership setting", source, span);
            switch (property) {
                .move, .copy => try writer.writeAll("; expected `trivial`, `fieldwise`, `none`, or a hook function"),
                .drop => try writer.writeAll("; expected `trivial`, `fieldwise`, `explicit`, or a hook function"),
            }
        },
        .struct_ownership_hook_signature_mismatch => |mismatch| {
            try writer.writeAll("struct ownership hook signature mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .struct_ownership_property_incompatible_with_fields => |reason| switch (reason) {
            .trivial_move => try writer.writeAll("`move = trivial` requires every field to be trivially movable"),
            .fieldwise_move => try writer.writeAll("`move = fieldwise` requires every field to be movable"),
            .trivial_copy => try writer.writeAll("`copy = trivial` requires every field to be trivially copyable"),
            .fieldwise_copy => try writer.writeAll("`copy = fieldwise` requires every field to be copyable"),
            .trivial_drop => try writer.writeAll("`drop = trivial` requires every field to have trivial drop behavior"),
        },
        .struct_field_type_not_supported => try writer.writeAll("this struct field type is not supported yet"),
        .recursive_struct_containment => try writeSourceLabel(writer, "struct recursively contains itself by value through field", source, span),
        .static_initializer_type_mismatch => |mismatch| {
            try writer.writeAll("static initializer type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .type_value_used_as_runtime_value => try writeSourceLabel(writer, "expected a value, found a type", source, span),
        .value_used_as_type => try writeSourceLabel(writer, "expected a type, found a value", source, span),
        .function_annotation_not_supported => try writer.writeAll("type annotations on function bindings are not supported yet"),
        .parameter_mode_not_supported => try writer.writeAll("this parameter access mode is not supported yet"),
        .static_parameter_requires_specialization => try writer.writeAll("a function with static parameters must be called with compile-time arguments"),
        .static_argument_not_supported => try writer.writeAll("this static argument is not supported yet"),
        .static_argument_type_mismatch => try writer.writeAll("static argument does not match the parameter type"),
        .duplicate_parameter => {
            try writeSourceLabel(writer, "parameter name is already declared", source, span);
        },
        .parameter_type_missing => try writer.writeAll("parameter is missing its type; write it as `name: Type`"),
        .parameter_type_not_supported => try writer.writeAll("this parameter type is not supported yet"),
        .return_type_not_supported => try writer.writeAll("this return type is not supported yet"),
        .top_level_return => try writer.writeAll("cannot return from top-level code"),
        .break_outside_loop => try writer.writeAll("break is only allowed inside a loop"),
        .continue_outside_loop => try writer.writeAll("continue is only allowed inside a loop"),
        .nested_declaration_not_supported => try writer.writeAll("nested declarations are not supported yet; move this declaration to the top level"),
        .ownership_transfer_requires_place => try writer.writeAll("`^` can only transfer a whole local binding"),
        .ownership_transfer_requires_owned_place => try writer.writeAll("cannot transfer this borrowed value; ownership remains with the caller"),
        .ownership_transfer_requires_owning_context => try writer.writeAll("remove `^`: this use borrows the value instead of taking ownership"),
        .mutable_argument_requires_place, .mutable_argument_requires_mutable_place => try writer.writeAll("argument to a `mut` parameter must be a mutable local or one of its fields"),
        .overlapping_mutable_arguments => try writer.writeAll("this `mut` argument accesses the same value as another argument in the call"),
        .use_after_transfer => try writer.writeAll("cannot use this value after it was transferred with `^`"),
        .possibly_transferred => try writer.writeAll("cannot use this value because it may already have been transferred with `^`"),
        .transferred_value_not_restored_before_loop_backedge => try writer.writeAll("transferred value must be reassigned before the next loop iteration"),
        .type_not_movable => |type_id| {
            try writer.writeAll("cannot transfer value of immovable type ");
            try writeType(types, writer, type_id);
        },
        .type_not_copyable => |details| {
            try writer.writeAll("cannot implicitly copy value of non-copyable type ");
            try writeType(types, writer, details.type_id);
            if (details.is_movable) try writer.writeAll("; use `^` to transfer ownership");
        },
        .value_requires_explicit_drop => |type_id| {
            try writeType(types, writer, type_id);
            try writer.writeAll(" must be transferred with `^` or passed to a `deinit` parameter before this scope ends");
        },
        .expression_not_supported => try writer.writeAll("this expression is not supported yet"),
        .struct_initializer_not_struct => |found| {
            try writer.writeAll("only a struct type can be initialized with `{...}`; found ");
            try writeType(types, writer, found);
        },
        .unknown_struct_field => try writeSourceLabel(writer, "unknown struct field", source, span),
        .duplicate_struct_initializer_field => try writeSourceLabel(writer, "struct field is initialized more than once", source, span),
        .missing_struct_initializer_field => |details| {
            const start = @min(details.name_span.start, source.len);
            const end = @min(@max(details.name_span.end, start), source.len);
            try writer.print("struct initializer is missing required field `{s}`", .{source[start..end]});
        },
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
        .float_type_not_supported => try writer.writeAll("the `float` type is not supported yet"),
        .unknown_type => try writeSourceLabel(writer, "unknown type", source, span),
        .unknown_value => {
            try writeSourceLabel(writer, "unknown value", source, span);
        },
        .assignment_target_not_local => try writer.writeAll("assignment target must be a mutable local or one of its fields"),
        .assignment_to_immutable => {
            try writeSourceLabel(writer, "cannot assign to immutable binding", source, span);
        },
        .assignment_type_mismatch => |mismatch| {
            try writer.writeAll("assignment type mismatch: ");
            try writeMismatch(types, writer, mismatch);
        },
        .integer_literal_not_decimal => try writer.writeAll("integer literal must use decimal notation"),
        .float_literal_not_supported => try writer.writeAll("float literals are not supported yet"),
        .integer_literal_out_of_range => try writer.writeAll("integer literal is outside the supported i32 range"),
        .fallible_condition_not_supported => try writer.writeAll("this condition syntax is not supported yet"),
        .if_condition_not_fallible => try writer.writeAll("condition must be able to fail, such as a comparison; plain values are not supported as conditions"),
        .inspection_type_not_supported => try writer.writeAll("this inspection type is not supported yet"),
        .variant_inspection_operand_not_variant => |found| {
            try writer.writeAll("variant inspection requires a variant value, found ");
            try writeType(types, writer, found);
        },
        .condition_binding_must_be_immutable => try writer.writeAll("an `if` binding must use `const`, not `var`"),
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
        .fallible_expression_outside_fallible_function => try writer.writeAll("this expression can fail; handle it with `if` or use it inside a `fallible` function"),
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
