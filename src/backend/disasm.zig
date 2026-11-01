const std = @import("std");
const x86 = @import("x86_encoding.zig");
const Pattern = x86.Encoding;

pub const Symbol = struct {
    offset: usize,
    name: []const u8,
    addend: i64 = 0,
};

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

fn collectTargets(code: []const u8, symbols: *const std.AutoHashMap(usize, Symbol), gpa: std.mem.Allocator) !std.AutoHashMap(i64, usize) {
    var targets = std.AutoHashMap(i64, usize).init(gpa);
    errdefer targets.deinit();
    var next_label: usize = 0;
    var cursor: usize = 0;
    while (cursor < code.len) {
        const pat = matchPattern(code[cursor..]) orelse break;
        try targets.put(@intCast(cursor), std.math.maxInt(usize));
        cursor += pat.length();
    }
    cursor = 0;
    while (cursor < code.len) {
        const pat = matchPattern(code[cursor..]) orelse break;
        if (pat.operand == .rel and !symbols.contains(cursor + pat.prefix.len)) {
            const target = relativeTarget(code, cursor, pat);
            if (targets.getPtr(target)) |label| if (label.* == std.math.maxInt(usize)) {
                label.* = next_label;
                next_label += 1;
            };
        }
        cursor += pat.length();
    }
    return targets;
}

pub fn disassemble(code: []const u8, gpa: std.mem.Allocator) ![]const u8 {
    return disassembleWithSymbols(code, &.{}, gpa);
}

pub fn disassembleWithSymbols(code: []const u8, named_operands: []const Symbol, gpa: std.mem.Allocator) ![]const u8 {
    var symbols = std.AutoHashMap(usize, Symbol).init(gpa);
    defer symbols.deinit();
    for (named_operands) |symbol| {
        const entry = try symbols.getOrPut(symbol.offset);
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = symbol;
    }
    var out = try std.ArrayList(u8).initCapacity(gpa, 4096);
    errdefer out.deinit(gpa);
    var targets = try collectTargets(code, &symbols, gpa);
    defer targets.deinit();
    var cursor: usize = 0;
    while (cursor < code.len) {
        if (targets.get(@intCast(cursor))) |label_idx| if (label_idx != std.math.maxInt(usize)) {
            try out.print(gpa, "L{d}:\n", .{label_idx});
        };
        const pat = matchPattern(code[cursor..]) orelse {
            for (code[cursor..]) |byte| try out.print(gpa, "  db 0x{x:0>2}\n", .{byte});
            break;
        };
        if (symbols.get(cursor + pat.prefix.len)) |symbol| {
            std.debug.assert(pat.operand == .rel or pat.operand == .u64);
            try out.print(gpa, "  {s}{s}", .{ pat.asm_prefix, symbol.name });
            if (symbol.addend != 0) try out.print(gpa, "{s}{d}", .{ if (symbol.addend > 0) "+" else "", symbol.addend });
            try out.print(gpa, "{s}\n", .{pat.asm_suffix});
            cursor += pat.length();
            continue;
        }
        switch (pat.operand) {
            .none => try out.print(gpa, "  {s}{s}\n", .{ pat.asm_prefix, pat.asm_suffix }),
            .i8 => {
                const val: i8 = @bitCast(code[cursor + pat.prefix.len]);
                try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, val, pat.asm_suffix });
            },
            .u8 => try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, code[cursor + pat.prefix.len], pat.asm_suffix }),
            .i32 => {
                const val = std.mem.readInt(i32, code[cursor + pat.prefix.len ..][0..4], .little);
                try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, val, pat.asm_suffix });
            },
            .u32 => {
                const val = std.mem.readInt(u32, code[cursor + pat.prefix.len ..][0..4], .little);
                try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, val, pat.asm_suffix });
            },
            .u64 => {
                const val = std.mem.readInt(u64, code[cursor + pat.prefix.len ..][0..8], .little);
                try out.print(gpa, "  {s}0x{x}{s}\n", .{ pat.asm_prefix, val, pat.asm_suffix });
            },
            .rel => {
                const target = relativeTarget(code, cursor, pat);
                const label = targets.get(target) orelse std.math.maxInt(usize);
                if (label != std.math.maxInt(usize)) {
                    try out.print(gpa, "  {s}L{d}{s}\n", .{ pat.asm_prefix, label, pat.asm_suffix });
                } else {
                    try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, target, pat.asm_suffix });
                }
            },
        }
        cursor += pat.length();
    }
    return out.toOwnedSlice(gpa);
}

test "disassembly resolves calls and addresses without inventing local labels" {
    const code = [_]u8{
        0xe8, 0,    0,    0,    0,
        0x48, 0xb8, 0,    0,    0,
        0,    0,    0,    0,    0,
        0x48, 0xb8, 0,    0,    0,
        0,    0,    0,    0,    0,
        0xe9, 0xfb, 0xff, 0xff, 0xff,
    };
    const symbols = [_]Symbol{
        .{ .offset = 1, .name = "std.io.print_value(int)" },
        .{ .offset = 7, .name = "$entry.id(int)" },
        .{ .offset = 17, .name = ".data0", .addend = -4 },
    };
    const rendered = try disassembleWithSymbols(&code, &symbols, std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "  call std.io.print_value(int)\n  mov rax, $entry.id(int)\n  mov rax, .data0-4\nL0:\n  jmp L0\n",
        rendered,
    );
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

test "disassembly decodes stack comparisons byte copies and register writes" {
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
