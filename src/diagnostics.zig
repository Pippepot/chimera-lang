const std = @import("std");
const structures = @import("structures.zig");

pub const TimingLog = struct {
    const Stage = struct {
        label: []const u8,
        duration: std.Io.Duration,
    };

    started: std.Io.Timestamp,
    previous: std.Io.Timestamp,
    stages: [16]Stage = undefined,
    count: usize = 0,

    pub fn init(started: std.Io.Timestamp) TimingLog {
        return .{ .started = started, .previous = started };
    }

    pub fn mark(self: *TimingLog, io: std.Io, label: []const u8) void {
        std.debug.assert(self.count < self.stages.len);
        const now = std.Io.Clock.awake.now(io);
        self.stages[self.count] = .{ .label = label, .duration = self.previous.durationTo(now) };
        self.count += 1;
        self.previous = now;
    }

    pub fn print(self: *const TimingLog, io: std.Io, writer: *std.Io.Writer) !void {
        const finished = std.Io.Clock.awake.now(io);
        const total = self.started.durationTo(finished);
        var buffer: [32]u8 = undefined;

        var label_width: usize = "total".len;
        var value_width = displayWidth(try formatDuration(&buffer, total));
        for (self.stages[0..self.count]) |stage| {
            label_width = @max(label_width, stage.label.len);
            value_width = @max(value_width, displayWidth(try formatDuration(&buffer, stage.duration)));
        }

        try writer.writeAll("timing\n");
        for (self.stages[0..self.count]) |stage| {
            try writeRow(writer, stage.label, label_width, try formatDuration(&buffer, stage.duration), value_width);
            const share = fractionOf(stage.duration, total);
            try writer.print("  {d:>5.1}%  ", .{share * 100});
            try writeShareBar(writer, share);
            try writer.writeByte('\n');
        }
        try writeRow(writer, "total", label_width, try formatDuration(&buffer, total), value_width);
        try writer.writeByte('\n');
    }
};

// Wraps the backing allocator to report peak and total heap usage.
pub const MemoryTracker = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *MemoryTracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    pub fn print(self: *const MemoryTracker, writer: *std.Io.Writer) !void {
        const rows = [_]struct { label: []const u8, bytes: usize }{
            .{ .label = "peak live", .bytes = self.peak.load(.monotonic) },
            .{ .label = "total allocated", .bytes = self.total.load(.monotonic) },
            .{ .label = "still live", .bytes = self.live.load(.monotonic) },
        };
        var buffer: [32]u8 = undefined;

        var label_width: usize = 0;
        var value_width: usize = 0;
        for (rows) |row| {
            label_width = @max(label_width, row.label.len);
            value_width = @max(value_width, displayWidth(try formatByteSize(&buffer, row.bytes)));
        }

        try writer.writeAll("memory\n");
        for (rows) |row| {
            try writeRow(writer, row.label, label_width, try formatByteSize(&buffer, row.bytes), value_width);
            try writer.writeByte('\n');
        }
        const allocations = try std.fmt.bufPrint(&buffer, "{d}", .{self.allocations.load(.monotonic)});
        try writeRow(writer, "allocations", label_width, allocations, value_width);
        try writer.writeByte('\n');
    }

    fn grow(self: *MemoryTracker, bytes: usize) void {
        _ = self.total.fetchAdd(bytes, .monotonic);
        const live = self.live.fetchAdd(bytes, .monotonic) + bytes;
        _ = self.peak.fetchMax(live, .monotonic);
    }

    fn shrink(self: *MemoryTracker, bytes: usize) void {
        _ = self.live.fetchSub(bytes, .monotonic);
    }

    fn resized(self: *MemoryTracker, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) self.grow(new_len - old_len) else self.shrink(old_len - new_len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        self.grow(len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resized(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.shrink(memory.len);
    }
};

const share_bar_width = 24;

fn formatDuration(buffer: []u8, duration: std.Io.Duration) ![]const u8 {
    const nanoseconds = duration.toNanoseconds();
    if (nanoseconds < 1_000) return std.fmt.bufPrint(buffer, "{d} ns", .{nanoseconds});
    const scale: struct { divisor: f64, unit: []const u8 } = if (nanoseconds < 1_000_000)
        .{ .divisor = 1_000.0, .unit = "µs" }
    else if (nanoseconds < 1_000_000_000)
        .{ .divisor = 1_000_000.0, .unit = "ms" }
    else
        .{ .divisor = 1_000_000_000.0, .unit = "s" };
    return std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ @as(f64, @floatFromInt(nanoseconds)) / scale.divisor, scale.unit });
}

fn formatByteSize(buffer: []u8, bytes: usize) ![]const u8 {
    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes});
    var scaled: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
    var unit: usize = 0;
    while (scaled >= 1024.0 and unit + 1 < units.len) : (unit += 1) scaled /= 1024.0;
    return std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ scaled, units[unit] });
}

fn fractionOf(part: std.Io.Duration, whole: std.Io.Duration) f64 {
    const whole_ns = whole.toNanoseconds();
    if (whole_ns <= 0) return 0;
    const fraction = @as(f64, @floatFromInt(part.toNanoseconds())) / @as(f64, @floatFromInt(whole_ns));
    return std.math.clamp(fraction, 0, 1);
}

fn writeShareBar(writer: *std.Io.Writer, share: f64) !void {
    const filled: usize = @intFromFloat(@round(share * share_bar_width));
    try writer.splatBytesAll("█", filled);
    try writer.splatBytesAll("░", share_bar_width - filled);
}

fn writeRow(
    writer: *std.Io.Writer,
    label: []const u8,
    label_width: usize,
    value: []const u8,
    value_width: usize,
) !void {
    try writer.writeAll("  ");
    try writePadded(writer, label, label_width, .left);
    try writer.writeAll("  ");
    try writePadded(writer, value, value_width, .right);
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize, alignment: enum { left, right }) !void {
    const text_width = displayWidth(text);
    const padding = if (text_width < width) width - text_width else 0;
    if (alignment == .right) try writer.splatByteAll(' ', padding);
    try writer.writeAll(text);
    if (alignment == .left) try writer.splatByteAll(' ', padding);
}

// Multi-byte units such as 'µs' occupy fewer columns than bytes.
fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

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
        .int, .int_literal, .string_literal, .static_data, .byte, .bool, .unit, .none, .never, .type => return writer.writeAll(@tagName(type_id)),
        _ => {},
    }
    if (try types.arrayType(type_id)) |array| {
        try writer.writeAll("Array(");
        try writeTypeInner(types, writer, array.element_type);
        return writer.print(", {d})", .{array.length});
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

fn writeTypedMessage(types: anytype, writer: *std.Io.Writer, prefix: []const u8, type_id: structures.TypeId, suffix: []const u8) !void {
    try writer.writeAll(prefix);
    try writeType(types, writer, type_id);
    try writer.writeAll(suffix);
}

fn writeMismatch(types: anytype, writer: *std.Io.Writer, prefix: []const u8, mismatch: structures.Diagnostic.TypeMismatch) !void {
    try writer.writeAll(prefix);
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
        .unsupported_syntax => |tag| {
            try writeToken(writer, tag);
            try writer.writeAll(" syntax is not implemented yet");
        },
        .unexpected_indented_block => try writer.writeAll("unexpected indented block; the previous expression does not introduce a block"),
        .indented_block_after_inline_body => try writer.writeAll("indented block cannot follow an inline function body; `->` starts the body, and the return type goes before it"),
        .duplicate_top_level_declaration => {
            try writeSourceLabel(writer, "top-level name is already declared", source, span);
        },
        .declaration_cycle => try writeSourceLabel(writer, "declaration depends on itself", source, span),
        .static_initializer_not_supported => try writer.writeAll("this static initializer is not supported yet"),
        .compile_time_call_cycle => try writer.writeAll("compile-time call recursively depends on the same function and arguments"),
        .compile_time_unhandled_failure => try writer.writeAll("compile-time expression failed without handling the failure"),
        .compile_time_division_by_zero => try writer.writeAll("division by zero during compile-time execution"),
        .compile_time_integer_overflow => try writer.writeAll("integer overflow during compile-time execution"),
        .compile_time_unsupported_operation => try writer.writeAll("operation is not supported during compile-time execution"),
        .compile_time_escaping_storage => try writer.writeAll("evaluation-owned storage cannot escape compile-time execution"),
        .compile_time_call_trace => try writer.writeAll("called at compile time from here"),
        .unsupported_external_declaration => try writer.writeAll("external function has no compiler-provided implementation"),
        .invalid_external_signature => try writer.writeAll("external function signature does not match its compiler-provided implementation"),
        .invalid_operation_signature => try writer.writeAll("operation function must match its exact compiler-specified signature"),
        .ambiguous_operation_reference => try writer.writeAll("operator reference requires an unambiguous operand count or a function-type annotation"),
        .struct_member_not_supported => try writer.writeAll("struct bodies support fields, namespace declarations, and `move`, `copy`, or `drop` properties"),
        .duplicate_struct_member => try writeSourceLabel(writer, "struct member is already declared", source, span),
        .reserved_ownership_member => try writeSourceLabel(writer, "`copy` and `move` are reserved for ownership capabilities", source, span),
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
        .struct_ownership_hook_signature_mismatch => |mismatch| try writeMismatch(types, writer, "struct ownership hook signature mismatch: ", mismatch),
        .struct_ownership_property_incompatible_with_fields => |reason| switch (reason) {
            .trivial_move => try writer.writeAll("`move = trivial` requires every field to be trivially movable"),
            .fieldwise_move => try writer.writeAll("`move = fieldwise` requires every field to be movable"),
            .custom_move => try writer.writeAll("a custom move hook requires every field to be movable"),
            .trivial_copy => try writer.writeAll("`copy = trivial` requires every field to be trivially copyable"),
            .fieldwise_copy => try writer.writeAll("`copy = fieldwise` requires every field to be copyable"),
            .trivial_drop => try writer.writeAll("`drop = trivial` requires every field to have trivial drop behavior"),
        },
        .struct_field_type_not_supported => try writer.writeAll("this struct field type is not supported yet"),
        .recursive_struct_containment => try writeSourceLabel(writer, "struct recursively contains itself by value through field", source, span),
        .static_initializer_type_mismatch => |mismatch| try writeMismatch(types, writer, "static initializer type mismatch: ", mismatch),
        .type_value_used_as_runtime_value => try writeSourceLabel(writer, "expected a value, found a type", source, span),
        .value_used_as_type => try writeSourceLabel(writer, "expected a type, found a value", source, span),
        .type_factory_requires_call => try writeSourceLabel(writer, "call this type-producing function to obtain a type", source, span),
        .generic_struct_requires_specialization => {
            try writer.writeAll("struct must be specialized before initialization");
            if (span) |focus| {
                const start = @min(focus.start, source.len);
                const end = @min(@max(focus.end, start), source.len);
                try writer.print("; write `{s}(...){{...}}`", .{source[start..end]});
            }
        },
        .function_annotation_not_supported => try writer.writeAll("type annotations on function bindings are not supported yet"),
        .parameter_mode_not_supported => try writer.writeAll("this parameter access mode is not supported yet"),
        .initializer_not_consumed => try writer.writeAll("every successful return must construct or forward each init parameter"),
        .initializer_already_consumed => try writer.writeAll("this init parameter has already been constructed or forwarded on a possible path"),
        .initializer_requires_construction => try writer.writeAll("an init parameter can only be constructed into owned storage or forwarded to init"),
        .initializer_consumed_in_loop => try writer.writeAll("a loop backedge cannot change an init parameter's pending state"),
        .initializer_exit_outside_boundary => try writer.writeAll("return, break, and continue cannot exit a deferred initializer; fail can only fail its current initializer region"),
        .initializer_capture_conflict => try writer.writeAll("this write or consumption conflicts with a pending initializer capture"),
        .static_parameter_requires_specialization => try writer.writeAll("a function with static parameters must be called with compile-time arguments"),
        .static_argument_cannot_be_inferred => try writer.writeAll("cannot infer every static argument from the runtime argument types"),
        .static_argument_inference_conflict => try writer.writeAll("runtime argument types infer conflicting values for a static parameter"),
        .comptime_runtime_capture => try writer.writeAll("compile-time expressions cannot capture runtime locals"),
        .static_argument_not_supported => try writer.writeAll("this static argument is not supported yet"),
        .static_argument_type_mismatch => try writer.writeAll("static argument does not match the parameter type"),
        .where_condition_failed => try writer.writeAll("function specialization does not satisfy this where condition"),
        .duplicate_parameter => {
            try writeSourceLabel(writer, "parameter name is already declared", source, span);
        },
        .parameter_type_missing => try writer.writeAll("parameter is missing its type; write it as `name: Type`"),
        .parameter_type_not_supported => try writer.writeAll("this parameter type is not supported yet"),
        .return_type_not_supported => try writer.writeAll("this return type is not supported yet"),
        .top_level_return => try writer.writeAll("cannot return from top-level code"),
        .break_outside_loop => try writer.writeAll("break is only allowed inside a loop"),
        .continue_outside_loop => try writer.writeAll("continue is only allowed inside a loop"),
        .import_outside_top_level => try writer.writeAll("import is only allowed at the top level"),
        .misplaced_pub => try writer.writeAll("pub is only allowed on top-level static, function, struct, and import declarations"),
        .namespace_used_as_value => try writer.writeAll("a module namespace is not a value"),
        .unknown_namespace_member => try writeSourceLabel(writer, "unknown struct namespace member", source, span),
        .missing_operation => |missing| {
            try writeType(types, writer, missing.receiver);
            try writer.print(" does not define operation `{s}`", .{missing.operation.spelling()});
        },
        .invalid_namespace_owner => try writer.writeAll("qualified declaration owner must be a declared struct in the same module or a primitive in the registered standard prelude"),
        .unknown_module => try writeSourceLabel(writer, "unknown module", source, span),
        .unknown_imported_name => try writeSourceLabel(writer, "unknown imported name", source, span),
        .private_access => try writeSourceLabel(writer, "declaration is not public", source, span),
        .import_conflict => try writeSourceLabel(writer, "imported name is already declared", source, span),
        .nested_declaration_not_supported => try writer.writeAll("nested declarations are not supported yet; move this declaration to the top level"),
        .ownership_transfer_requires_place => try writer.writeAll("`^` can only transfer a local binding or one of its fields"),
        .ownership_transfer_requires_owned_place => try writer.writeAll("cannot transfer this borrowed value; ownership remains with the caller"),
        .partial_field_transfer_not_supported => try writer.writeAll("cannot transfer or join these fields independently under the current ownership rules"),
        .explicit_drop_field_cannot_be_implicitly_ended => try writer.writeAll("cannot implicitly end an explicit-drop field; transfer or dispose of it on every path"),
        .field_not_restored_before_mut_return => try writer.writeAll("a `mut` argument must have every transferred field restored before returning"),
        .ownership_transfer_requires_owning_context => try writer.writeAll("remove `^`: this use borrows the value instead of taking ownership"),
        .mutable_argument_requires_place, .mutable_argument_requires_mutable_place => try writer.writeAll("argument to a `mut` parameter must be a mutable local or one of its fields"),
        .overlapping_mutable_arguments => try writer.writeAll("this `mut` argument accesses the same value as another argument in the call"),
        .use_after_transfer => try writer.writeAll("cannot use this value after it was transferred with `^`"),
        .possibly_transferred => try writer.writeAll("cannot use this value because it may already have been transferred with `^`"),
        .replaced_value_used => try writer.writeAll("cannot use this value while it is replaced in its own storage; its type cannot move directly, so read or transfer it before the replacement"),
        .consumed_storage_in_use => try writer.writeAll("cannot overwrite storage retained by a pending `deinit` argument; replace it after the call completes"),
        .borrow_outlives_source => try writer.writeAll("borrow cannot outlive the value or storage it references"),
        .compile_time_only_type => |type_id| try writeTypedMessage(types, writer, "compile-time-only type ", type_id, " cannot be materialized during runtime execution"),
        .ambiguous_conversion => |mismatch| {
            try writer.writeAll("multiple conversions apply from ");
            try writeType(types, writer, mismatch.found);
            try writer.writeAll(" to ");
            try writeType(types, writer, mismatch.expected);
        },
        .invalid_converter => try writer.writeAll("converter must have one immutable runtime source or one compile-time-only static source and an infallible result"),
        .invalid_converter_owner => try writer.writeAll("converter must be declared in the defining module of its source or target type"),
        .borrow_requires_place => try writer.writeAll("borrowing a value's storage requires a named local or parameter, or one of its fields"),
        .mutable_borrow_requires_writable_place => try writer.writeAll("`borrow mut` requires a mutable place or writable Ref"),
        .dereference_requires_ref => |type_id| try writeTypedMessage(types, writer, "dereference requires a Ref, found ", type_id, ""),
        .reference_not_writable => try writer.writeAll("cannot assign through a read-only Ref"),
        .transferred_value_not_restored_before_loop_backedge => try writer.writeAll("transferred value must be reassigned before the next loop iteration"),
        .type_not_movable => |type_id| try writeTypedMessage(types, writer, "cannot transfer value of immovable type ", type_id, ""),
        .relocation_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "a completed value of type ", type_id, " cannot move directly into another destination; construct it there, giving the result a known type if needed"),
        .type_not_copyable => |details| {
            try writeTypedMessage(types, writer, "cannot implicitly copy value of non-copyable type ", details.type_id, "");
            if (details.is_movable) try writer.writeAll("; use `^` to transfer ownership");
        },
        .list_cannot_store_borrow_element => |type_id| try writeTypedMessage(types, writer, "List cannot store values containing Ref yet; element type is ", type_id, ""),
        .list_requires_automatic_drop => |type_id| try writeTypedMessage(types, writer, "List requires an automatically droppable element type; found ", type_id, ""),
        .list_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "List requires a directly movable element type for relocation; found ", type_id, ""),
        .borrow_write_cannot_store_borrow => |type_id| try writeTypedMessage(types, writer, "write cannot replace a value containing Ref yet; pointee type is ", type_id, ""),
        .borrow_write_requires_automatic_drop => |type_id| try writeTypedMessage(types, writer, "write requires an automatically droppable pointee type; found ", type_id, ""),
        .borrow_write_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "write requires a directly movable pointee type; found ", type_id, ""),
        .box_requires_automatic_drop => |type_id| try writeTypedMessage(types, writer, "Box requires an automatically droppable element type; found ", type_id, ""),
        .box_extraction_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "cannot extract a non-directly-movable value from Box; found ", type_id, ""),
        .value_requires_explicit_drop => |type_id| {
            try writeType(types, writer, type_id);
            try writer.writeAll(" must be transferred with `^` or passed to a `deinit` parameter before this scope ends");
        },
        .expression_not_supported => try writer.writeAll("this expression is not supported yet"),
        .struct_initializer_not_struct => |found| try writeTypedMessage(types, writer, "only a struct type can be initialized with `{...}`; found ", found, ""),
        .unknown_struct_field => try writeSourceLabel(writer, "unknown struct field", source, span),
        .duplicate_struct_initializer_field => try writeSourceLabel(writer, "struct field is initialized more than once", source, span),
        .missing_struct_initializer_field => |details| {
            const definition = (try types.structDefinition(details.type_id)) orelse unreachable;
            try writer.print("struct initializer is missing required field `{s}`", .{definition.fields[details.field_index].name});
        },
        .struct_initializer_field_type_mismatch => |mismatch| try writeMismatch(types, writer, "struct field initializer type mismatch: ", mismatch),
        .field_access_not_struct => |found| try writeTypedMessage(types, writer, "field access requires a struct value, found ", found, ""),
        .private_struct_field => |type_id| try writeTypedMessage(types, writer, "cannot name a private field of ", type_id, " outside its defining module"),
        .public_field_private_type => try writer.writeAll("a public field's type cannot name a private declaration"),
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
        .assignment_type_mismatch => |mismatch| try writeMismatch(types, writer, "assignment type mismatch: ", mismatch),
        .integer_literal_not_decimal => try writer.writeAll("integer literal must use decimal notation"),
        .float_literal_not_supported => try writer.writeAll("float literals are not supported yet"),
        .invalid_string_escape => try writer.writeAll("invalid string escape"),
        .invalid_string_utf8 => try writer.writeAll("string literal is not valid UTF-8"),
        .integer_literal_out_of_range => try writer.writeAll("integer literal is outside the supported i32 range"),
        .fallible_condition_not_supported => try writer.writeAll("this condition syntax is not supported yet"),
        .if_condition_not_fallible => try writer.writeAll("condition must be able to fail, such as a comparison; plain values are not supported as conditions"),
        .inspection_type_not_supported => try writer.writeAll("this inspection type is not supported yet"),
        .variant_inspection_operand_not_variant => |found| try writeTypedMessage(types, writer, "variant inspection requires a variant value, found ", found, ""),
        .condition_binding_must_be_immutable => try writer.writeAll("an `if` binding must use `const`, not `var`"),
        .value_not_callable => {
            try writeSourceLabel(writer, "value is not callable", source, span);
        },
        .duplicate_variant_member_type => try writer.writeAll("variant contains the same member type more than once"),
        .local_type_mismatch => |mismatch| try writeMismatch(types, writer, "initializer type mismatch: ", mismatch),
        .negation_operand_not_int => |found| try writeTypedMessage(types, writer, "negation requires `int`, found ", found, ""),
        .arithmetic_operand_not_int => |found| try writeTypedMessage(types, writer, "arithmetic requires `int`, found ", found, ""),
        .comparison_operand_not_int => |found| try writeTypedMessage(types, writer, "comparison requires `int`, found ", found, ""),
        .equality_operand_not_supported => |found| try writeTypedMessage(types, writer, "equality is not supported for ", found, ""),
        .equality_operand_type_mismatch => |mismatch| try writeMismatch(types, writer, "equality operand type mismatch: ", mismatch),
        .fallible_expression_outside_fallible_function => try writer.writeAll("this expression can fail; handle it with `if` or use it inside a `fallible` function"),
        .fallible_call_requires_marker => try writer.writeAll("fallible invocation requires `?(...)` unless this call itself is required to be fallible"),
        .fallible_call_not_fallible => try writer.writeAll("`?(...)` requires a fallible callable; this callable is infallible"),
        .missing_return_value => |expected| try writeTypedMessage(types, writer, "function must return ", expected, " on every reachable path"),
        .return_type_mismatch => |mismatch| try writeMismatch(types, writer, "return type mismatch: ", mismatch),
        .unknown_function => {
            try writeSourceLabel(writer, "unknown function", source, span);
        },
        .call_argument_count_mismatch => |count| try writer.print("expected {d} call argument{s}, found {d}", .{
            count.expected,
            if (count.expected == 1) "" else "s",
            count.found,
        }),
        .call_argument_type_mismatch => |mismatch| try writeMismatch(types, writer, "argument type mismatch: ", mismatch),
    }
}

pub const DiagnosticSource = struct {
    file_id: structures.FileId,
    path: []const u8,
    source: []const u8,
};

fn sourceFor(sources: []const DiagnosticSource, file_id: structures.FileId) DiagnosticSource {
    for (sources) |candidate| if (candidate.file_id == file_id) return candidate;
    unreachable; // Every diagnostic must have a registered source.
}

pub fn renderDiagnostic(
    types: anytype,
    writer: *std.Io.Writer,
    sources: []const DiagnosticSource,
    diagnostic: structures.Diagnostic,
) !void {
    const file = sourceFor(sources, diagnostic.file_id);
    const source_path = file.path;
    const source = file.source;
    const is_note = std.meta.activeTag(diagnostic.kind) == .compile_time_call_trace;
    const label = if (is_note) "\x1b[36mnote:\x1b[0m" else "\x1b[31merror:\x1b[0m";
    if (diagnostic.span) |span| {
        const info = lineInfoForOffset(source, span.start);
        try writer.print("{s} {s}:{d}:{d}: ", .{
            label,
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

    try writer.print("{s} {s}: ", .{ label, source_path });
    try writeKindMessage(types, writer, source, diagnostic.span, diagnostic.kind);
    try writer.writeByte('\n');
}

pub fn renderDiagnostics(
    types: anytype,
    writer: *std.Io.Writer,
    sources: []const DiagnosticSource,
    diagnostics: []const structures.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        if (std.meta.activeTag(diagnostic.kind) == .compile_time_call_trace) continue;
        try renderDiagnostic(types, writer, sources, diagnostic);
    }
    var index = diagnostics.len;
    while (index > 0) {
        index -= 1;
        const diagnostic = diagnostics[index];
        if (std.meta.activeTag(diagnostic.kind) != .compile_time_call_trace) continue;
        try renderDiagnostic(types, writer, sources, diagnostic);
    }
}

test "diagnostic types display array elements lengths and nested variants" {
    const query = @import("query/engine.zig");
    const queries = @import("queries.zig");
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    const element: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .variant = .{ .members = &.{ .int, .none } } }));
    const row: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .array = .{ .element_type = element, .length = 2 } }));
    const matrix: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .array = .{ .element_type = row, .length = 0 } }));
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeType(types, &output.writer, matrix);
    try std.testing.expectEqualStrings("`Array(Array(int | none, 2), 0)`", output.writer.buffered());
    const cases = [_]struct { kind: structures.Diagnostic.Kind, message: []const u8 }{
        .{ .kind = .{ .missing_operation = .{ .receiver = .bool, .operation = .@"+" } }, .message = "`bool` does not define operation `+`" },
        .{ .kind = .{ .unsupported_syntax = .keyword_for }, .message = "`for` syntax is not implemented yet" },
        .{ .kind = .{ .compile_time_only_type = matrix }, .message = "compile-time-only type `Array(Array(int | none, 2), 0)` cannot be materialized during runtime execution" },
        .{ .kind = .{ .return_type_mismatch = .{ .expected = matrix, .found = .int } }, .message = "return type mismatch: expected `Array(Array(int | none, 2), 0)`, found `int`" },
        .{ .kind = .{ .type_not_copyable = .{ .type_id = matrix, .is_movable = true } }, .message = "cannot implicitly copy value of non-copyable type `Array(Array(int | none, 2), 0)`; use `^` to transfer ownership" },
        .{ .kind = .{ .type_not_copyable = .{ .type_id = matrix, .is_movable = false } }, .message = "cannot implicitly copy value of non-copyable type `Array(Array(int | none, 2), 0)`" },
    };
    for (cases) |case| {
        output.clearRetainingCapacity();
        try writeKindMessage(types, &output.writer, "", null, case.kind);
        try std.testing.expectEqualStrings(case.message, output.writer.buffered());
    }
}
