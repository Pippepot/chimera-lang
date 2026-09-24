const std = @import("std");

const Operand = enum { none, i32, u32, u64, rel };

const Pattern = struct {
    prefix: []const u8,
    operand: Operand = .none,
    asm_prefix: []const u8,
    asm_suffix: []const u8 = "",

    fn length(self: Pattern) usize {
        return self.prefix.len + @as(usize, switch (self.operand) {
            .none => 0,
            .i32, .u32, .rel => 4,
            .u64 => 8,
        });
    }
};

// Instructions emitted by the x86 backend, including linker padding.
const patterns = [_]Pattern{
    .{ .prefix = &.{0xC3}, .asm_prefix = "ret" },
    .{ .prefix = &.{ 0x31, 0xFF }, .asm_prefix = "xor edi, edi" },
    .{ .prefix = &.{0x99}, .asm_prefix = "cdq" },
    .{ .prefix = &.{ 0xF7, 0xF9 }, .asm_prefix = "idiv ecx" },
    .{ .prefix = &.{ 0xF7, 0xD8 }, .asm_prefix = "neg eax" },
    .{ .prefix = &.{ 0xFF, 0xD0 }, .asm_prefix = "call rax" },
    .{ .prefix = &.{ 0x89, 0xC7 }, .asm_prefix = "mov edi, eax" },
    .{ .prefix = &.{ 0x0F, 0x05 }, .asm_prefix = "syscall" },
    .{ .prefix = &.{ 0x8B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov eax, [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x89, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], eax" },
    .{ .prefix = &.{ 0x03, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "add eax, [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x2B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "sub eax, [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0xF7, 0xBC, 0x24 }, .operand = .u32, .asm_prefix = "idiv dword [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x0F, 0xAF, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "imul eax, [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x48, 0x8B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov rax, [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x48, 0x89, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rax" },
    .{ .prefix = &.{0xB8}, .operand = .i32, .asm_prefix = "mov eax, " },
    .{ .prefix = &.{0xB9}, .operand = .i32, .asm_prefix = "mov ecx, " },
    .{ .prefix = &.{0xBA}, .operand = .i32, .asm_prefix = "mov edx, " },
    .{ .prefix = &.{ 0x48, 0xB8 }, .operand = .u64, .asm_prefix = "mov rax, " },
    .{ .prefix = &.{ 0x69, 0xC0 }, .operand = .i32, .asm_prefix = "imul eax, eax, " },
    .{ .prefix = &.{0x2D}, .operand = .i32, .asm_prefix = "sub eax, " },
    .{ .prefix = &.{0x05}, .operand = .i32, .asm_prefix = "add eax, " },
    .{ .prefix = &.{0x3D}, .operand = .i32, .asm_prefix = "cmp eax, " },
    .{ .prefix = &.{ 0x48, 0x81, 0xEC }, .operand = .u32, .asm_prefix = "sub rsp, " },
    .{ .prefix = &.{ 0x48, 0x81, 0xC4 }, .operand = .u32, .asm_prefix = "add rsp, " },
    .{ .prefix = &.{0xE8}, .operand = .rel, .asm_prefix = "call " },
    .{ .prefix = &.{0xE9}, .operand = .rel, .asm_prefix = "jmp " },
    .{ .prefix = &.{ 0x0F, 0x84 }, .operand = .rel, .asm_prefix = "je " },
    .{ .prefix = &.{ 0x0F, 0x85 }, .operand = .rel, .asm_prefix = "jne " },
    .{ .prefix = &.{ 0x0F, 0x8C }, .operand = .rel, .asm_prefix = "jl " },
    .{ .prefix = &.{ 0x0F, 0x8F }, .operand = .rel, .asm_prefix = "jg " },
    .{ .prefix = &.{ 0x0F, 0x8E }, .operand = .rel, .asm_prefix = "jle " },
    .{ .prefix = &.{ 0x0F, 0x8D }, .operand = .rel, .asm_prefix = "jge " },
    .{ .prefix = &.{0x90}, .asm_prefix = "nop" },
    .{ .prefix = &.{ 0x85, 0xD2 }, .asm_prefix = "test edx, edx" },
    .{ .prefix = &.{ 0x3B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "cmp eax, [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x0F, 0xB6, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "movzx eax, byte [rsp+", .asm_suffix = "]" },
    .{ .prefix = &.{ 0x88, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], al" },
};

fn matchPattern(code: []const u8) ?Pattern {
    for (patterns) |pat| {
        if (code.len < pat.length()) continue;
        if (std.mem.eql(u8, code[0..pat.prefix.len], pat.prefix)) return pat;
    }
    return null;
}

fn relativeTarget(code: []const u8, cursor: usize, pattern: Pattern) i64 {
    const relative = std.mem.readInt(i32, code[cursor + pattern.prefix.len ..][0..4], .little);
    return @as(i64, @intCast(cursor + pattern.length())) + relative;
}

fn collectTargets(code: []const u8, gpa: std.mem.Allocator) !std.AutoHashMap(i64, usize) {
    var targets = std.AutoHashMap(i64, usize).init(gpa);
    errdefer targets.deinit();
    var next_label: usize = 0;
    var cursor: usize = 0;
    while (cursor < code.len) {
        const pat = matchPattern(code[cursor..]) orelse {
            cursor += 1;
            continue;
        };
        if (pat.operand == .rel) {
            const target = relativeTarget(code, cursor, pat);
            if (target >= 0 and target < code.len and !targets.contains(target)) {
                try targets.put(target, next_label);
                next_label += 1;
            }
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
        if (targets.get(@intCast(cursor))) |label_idx| {
            try out.print(gpa, "L{d}:\n", .{label_idx});
        }
        const pat = matchPattern(code[cursor..]) orelse {
            try out.print(gpa, "  db 0x{x:0>2}\n", .{code[cursor]});
            cursor += 1;
            continue;
        };
        switch (pat.operand) {
            .none => try out.print(gpa, "  {s}\n", .{pat.asm_prefix}),
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
                if (targets.get(target)) |label_idx| {
                    try out.print(gpa, "  {s}L{d}{s}\n", .{ pat.asm_prefix, label_idx, pat.asm_suffix });
                } else {
                    try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, target, pat.asm_suffix });
                }
            },
        }
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
