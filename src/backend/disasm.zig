const std = @import("std");
const x86 = @import("x86_encoding.zig");
const Pattern = x86.Encoding;

fn matchPattern(code: []const u8) ?Pattern {
    for (x86.patterns) |pat| {
        if (code.len < pat.length()) continue;
        if (std.mem.eql(u8, code[0..pat.prefix.len], pat.prefix)) return pat;
    }
    return null;
}

fn relativeTarget(code: []const u8, cursor: usize, pattern: Pattern) i64 {
    const relative = std.mem.readInt(i32, code[cursor + pattern.prefix.len ..][0..4], .little);
    return @as(i64, @intCast(cursor + pattern.length())) + relative;
}

/// Maps every instruction start to its label, if a branch targets it.
fn collectTargets(code: []const u8, gpa: std.mem.Allocator) !std.AutoHashMap(i64, ?usize) {
    var targets = std.AutoHashMap(i64, ?usize).init(gpa);
    errdefer targets.deinit();
    var next_label: usize = 0;
    var cursor: usize = 0;
    while (cursor < code.len) {
        const pat = matchPattern(code[cursor..]) orelse break;
        try targets.put(@intCast(cursor), null);
        cursor += pat.length();
    }
    cursor = 0;
    while (cursor < code.len) {
        const pat = matchPattern(code[cursor..]) orelse break;
        if (pat.operand == .rel) {
            const target = relativeTarget(code, cursor, pat);
            if (targets.getPtr(target)) |label| if (label.* == null) {
                label.* = next_label;
                next_label += 1;
            };
        }
        cursor += pat.length();
    }
    return targets;
}

pub fn disassemble(code: []const u8, gpa: std.mem.Allocator) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(gpa, 4096);
    errdefer out.deinit(gpa);
    var targets = try collectTargets(code, gpa);
    defer targets.deinit();
    var cursor: usize = 0;
    while (cursor < code.len) {
        if (targets.get(@intCast(cursor)) orelse null) |label| try out.print(gpa, "L{d}:\n", .{label});
        const pat = matchPattern(code[cursor..]) orelse {
            for (code[cursor..]) |byte| try out.print(gpa, "  db 0x{x:0>2}\n", .{byte});
            break;
        };
        try out.print(gpa, "  {s}", .{pat.asm_prefix});
        const operand = code[cursor + pat.prefix.len ..];
        switch (pat.operand) {
            .none => {},
            .i8 => try out.print(gpa, "{d}", .{@as(i8, @bitCast(operand[0]))}),
            .u8 => try out.print(gpa, "{d}", .{operand[0]}),
            .i32 => try out.print(gpa, "{d}", .{std.mem.readInt(i32, operand[0..4], .little)}),
            .u32 => try out.print(gpa, "{d}", .{std.mem.readInt(u32, operand[0..4], .little)}),
            .u64 => try out.print(gpa, "0x{x}", .{std.mem.readInt(u64, operand[0..8], .little)}),
            .rel => {
                const target = relativeTarget(code, cursor, pat);
                if (targets.get(target) orelse null) |label| {
                    try out.print(gpa, "L{d}", .{label});
                } else try out.print(gpa, "{d}", .{target});
            },
        }
        try out.print(gpa, "{s}\n", .{pat.asm_suffix});
        cursor += pat.length();
    }
    return out.toOwnedSlice(gpa);
}

test "disassembly handles truncated instructions and external branch targets" {
    const cases = [_]struct { code: []const u8, expected: []const u8 }{
        .{ .code = &.{0xB8}, .expected = "  db 0xb8\n" },
        .{ .code = &.{ 0xE8, 0x00 }, .expected = "  db 0xe8\n  db 0x00\n" },
        .{ .code = &.{ 0xE9, 0xFA, 0xFF, 0xFF, 0xFF }, .expected = "  jmp -1\n" },
        .{ .code = &.{ 0xE9, 0x00, 0x00, 0x00, 0x00 }, .expected = "  jmp 5\n" },
        .{ .code = &.{ 0xE9, 0xFB, 0xFF, 0xFF, 0xFF }, .expected = "L0:\n  jmp L0\n" },
    };
    for (cases) |case| {
        const rendered = try disassemble(case.code, std.testing.allocator);
        defer std.testing.allocator.free(rendered);
        try std.testing.expectEqualStrings(case.expected, rendered);
    }
}

test "disassembly decodes stack comparisons byte copies and fallible status" {
    const code = [_]u8{
        0x3B, 0x84, 0x24, 4,    0, 0, 0,
        0x0F, 0xB6, 0x84, 0x24, 8, 0, 0,
        0,    0x88, 0x84, 0x24, 9, 0, 0,
        0,    0x85, 0xD2, 0x90,
    };
    const rendered = try disassemble(&code, std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "  cmp eax, [rsp+4]\n  movzx eax, byte [rsp+8]\n  mov [rsp+9], al\n  test edx, edx\n  nop\n",
        rendered,
    );
}

test "every encoder operation decodes as exactly one instruction" {
    for (std.meta.tags(x86.Operation)) |operation| {
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(std.testing.allocator);
        for ([_]u64{ 0, 1, 127, 128, 0xffffff80, 0xffffff7f, 0xe8e8e8e8e8e8e8e8 }) |bits| {
            code.clearRetainingCapacity();
            try x86.append(&code, std.testing.allocator, operation, bits);
            const pattern = matchPattern(code.items).?;
            try std.testing.expectEqual(code.items.len, pattern.length());
            const selected = x86.selectedEncoding(operation, bits);
            try std.testing.expectEqualStrings(selected.asm_prefix, pattern.asm_prefix);
            try std.testing.expectEqualStrings(selected.asm_suffix, pattern.asm_suffix);
            const rendered = try disassemble(code.items, std.testing.allocator);
            defer std.testing.allocator.free(rendered);
            try std.testing.expect(std.mem.indexOf(u8, rendered, "db ") == null);
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "\n"));
        }
    }
}

test "disassembly decodes compact instruction forms and truncated operands" {
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(std.testing.allocator);
    try x86.append(&code, std.testing.allocator, .mov_eax_rsp, 0);
    try x86.append(&code, std.testing.allocator, .mov_rsp_rax, 127);
    try x86.append(&code, std.testing.allocator, .add_eax, @as(u32, @bitCast(@as(i32, -128))));
    try x86.append(&code, std.testing.allocator, .imul_eax, 128);
    const rendered = try disassemble(code.items, std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("  mov eax, [rsp]\n  mov [rsp+127], rax\n  add eax, -128\n  imul eax, eax, 128\n", rendered);
    const truncated = try disassemble(&.{ 0x8b, 0x44, 0x24 }, std.testing.allocator);
    defer std.testing.allocator.free(truncated);
    try std.testing.expectEqualStrings("  db 0x8b\n  db 0x44\n  db 0x24\n", truncated);
}

test "unknown bytes and instruction interiors do not become branch labels" {
    const unknown = try disassemble(&.{ 0xff, 0xe8, 0, 0, 0, 0, 0x90 }, std.testing.allocator);
    defer std.testing.allocator.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "call") == null);
    const interior = try disassemble(&.{ 0xe9, 0xfd, 0xff, 0xff, 0xff }, std.testing.allocator);
    defer std.testing.allocator.free(interior);
    try std.testing.expectEqualStrings("  jmp 2\n", interior);
}
