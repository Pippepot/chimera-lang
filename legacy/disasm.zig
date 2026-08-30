const std = @import("std");

const Operand = enum { none, i32, u32, rel };

const Pattern = struct {
    prefix: []const u8,
    total_len: u8,
    operand: Operand,
    asm_prefix: []const u8,
    asm_suffix: []const u8,
};

const PATTERNS = blk: {
    const fixed = [_]Pattern{
        .{ .prefix = &.{0x55}, .total_len = 1, .operand = .none, .asm_prefix = "push rbp", .asm_suffix = "" },
        .{ .prefix = &.{0x53}, .total_len = 1, .operand = .none, .asm_prefix = "push rbx", .asm_suffix = "" },
        .{ .prefix = &.{0x5B}, .total_len = 1, .operand = .none, .asm_prefix = "pop rbx", .asm_suffix = "" },
        .{ .prefix = &.{0x5D}, .total_len = 1, .operand = .none, .asm_prefix = "pop rbp", .asm_suffix = "" },
        .{ .prefix = &.{0xC9}, .total_len = 1, .operand = .none, .asm_prefix = "leave", .asm_suffix = "" },
        .{ .prefix = &.{0xC3}, .total_len = 1, .operand = .none, .asm_prefix = "ret", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xE5 }, .total_len = 3, .operand = .none, .asm_prefix = "mov rbp, rsp", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xEC }, .total_len = 3, .operand = .none, .asm_prefix = "mov rsp, rbp", .asm_suffix = "" },
        .{ .prefix = &.{ 0x4C, 0x8D, 0x7C, 0x24, 0x08 }, .total_len = 5, .operand = .none, .asm_prefix = "lea r15, [rsp+8]", .asm_suffix = "" },
        .{ .prefix = &.{ 0x01, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "add eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x31, 0xFF }, .total_len = 2, .operand = .none, .asm_prefix = "xor edi, edi", .asm_suffix = "" },
        .{ .prefix = &.{ 0x29, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "sub eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0xAF, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "imul eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{0x99}, .total_len = 1, .operand = .none, .asm_prefix = "cdq", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF7, 0xFB }, .total_len = 2, .operand = .none, .asm_prefix = "idiv ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF7, 0xF9 }, .total_len = 2, .operand = .none, .asm_prefix = "idiv ecx", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF7, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "neg eax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x39, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "cmp eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x83, 0xF8, 0x00 }, .total_len = 3, .operand = .none, .asm_prefix = "cmp eax, 0", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x2E, 0xC1 }, .total_len = 3, .operand = .none, .asm_prefix = "ucomiss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xFF, 0xD0 }, .total_len = 2, .operand = .none, .asm_prefix = "call rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0xB6, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "movzx eax, al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x20, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "and al, bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x08, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "or al, bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x89, 0xC7 }, .total_len = 2, .operand = .none, .asm_prefix = "mov edi, eax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x05 }, .total_len = 2, .operand = .none, .asm_prefix = "syscall", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x58, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "addss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x5C, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "subss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x59, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "mulss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x5E, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "divss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0x8B, 0x84, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov eax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x89, 0x84, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], eax" },
        .{ .prefix = &.{ 0x03, 0x84, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "add eax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x2B, 0x84, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "sub eax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0xF7, 0xBC, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "idiv dword [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x0F, 0xAF, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "imul eax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x8B, 0x9C, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov ebx, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0xBC, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rdi, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0xB4, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rsi, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x94, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rdx, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rcx, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x4C, 0x8B, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov r8, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x4C, 0x8B, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov r9, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x89, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rax" },
        .{ .prefix = &.{ 0x48, 0x89, 0xBC, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rdi" },
        .{ .prefix = &.{ 0x48, 0x89, 0xB4, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rsi" },
        .{ .prefix = &.{ 0x48, 0x89, 0x94, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rdx" },
        .{ .prefix = &.{ 0x48, 0x89, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rcx" },
        .{ .prefix = &.{ 0x4C, 0x89, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], r8" },
        .{ .prefix = &.{ 0x4C, 0x89, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], r9" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x10, 0x84, 0x24 }, .total_len = 9, .operand = .u32, .asm_prefix = "movss xmm0, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x10, 0x8C, 0x24 }, .total_len = 9, .operand = .u32, .asm_prefix = "movss xmm1, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x11, 0x84, 0x24 }, .total_len = 9, .operand = .u32, .asm_prefix = "movss [rsp+", .asm_suffix = "], xmm0" },
        .{ .prefix = &.{ 0x48, 0x8D, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "lea rax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x4C, 0x8D, 0x94, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "lea r10, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x80 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov rax, [rax+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x49, 0x89, 0x82 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov [r10+", .asm_suffix = "], rax" },
        .{ .prefix = &.{ 0x48, 0x89, 0x82 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov [rdx+", .asm_suffix = "], rax" },
        .{ .prefix = &.{0xB8}, .total_len = 5, .operand = .i32, .asm_prefix = "mov eax, ", .asm_suffix = "" },
        .{ .prefix = &.{0xB9}, .total_len = 5, .operand = .i32, .asm_prefix = "mov ecx, ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x69, 0xC0 }, .total_len = 6, .operand = .i32, .asm_prefix = "imul eax, eax, ", .asm_suffix = "" },
        .{ .prefix = &.{0x2D}, .total_len = 5, .operand = .i32, .asm_prefix = "sub eax, ", .asm_suffix = "" },
        .{ .prefix = &.{0x05}, .total_len = 5, .operand = .i32, .asm_prefix = "add eax, ", .asm_suffix = "" },
        .{ .prefix = &.{0x3D}, .total_len = 5, .operand = .i32, .asm_prefix = "cmp eax, ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x89, 0xC3 }, .total_len = 2, .operand = .none, .asm_prefix = "mov ebx, eax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x89, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "mov eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x85, 0xC0 }, .total_len = 2, .operand = .none, .asm_prefix = "test eax, eax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xC7 }, .total_len = 3, .operand = .none, .asm_prefix = "mov rdi, rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xC6 }, .total_len = 3, .operand = .none, .asm_prefix = "mov rsi, rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xC2 }, .total_len = 3, .operand = .none, .asm_prefix = "mov rdx, rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xC1 }, .total_len = 3, .operand = .none, .asm_prefix = "mov rcx, rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x4C, 0x89, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "mov r8, rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x4C, 0x89, 0xC8 }, .total_len = 3, .operand = .none, .asm_prefix = "mov r9, rax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x81, 0xEC }, .total_len = 7, .operand = .u32, .asm_prefix = "sub rsp, ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x81, 0xC4 }, .total_len = 7, .operand = .u32, .asm_prefix = "add rsp, ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x49, 0x8B, 0xBF }, .total_len = 7, .operand = .u32, .asm_prefix = "mov rdi, [r15+", .asm_suffix = "]" },
        .{ .prefix = &.{0xE8}, .total_len = 5, .operand = .rel, .asm_prefix = "call ", .asm_suffix = "" },
        .{ .prefix = &.{0xE9}, .total_len = 5, .operand = .rel, .asm_prefix = "jmp ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x84 }, .total_len = 6, .operand = .rel, .asm_prefix = "je ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x85 }, .total_len = 6, .operand = .rel, .asm_prefix = "jne ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x8C }, .total_len = 6, .operand = .rel, .asm_prefix = "jl ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x8F }, .total_len = 6, .operand = .rel, .asm_prefix = "jg ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x8E }, .total_len = 6, .operand = .rel, .asm_prefix = "jle ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x8D }, .total_len = 6, .operand = .rel, .asm_prefix = "jge ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x8D, 0x05 }, .total_len = 7, .operand = .rel, .asm_prefix = "lea rax, [rip+", .asm_suffix = "]" },
    };
    const setcc_conds = [_]struct { code: u8, name: []const u8 }{
        .{ .code = 0x92, .name = "b" },
        .{ .code = 0x96, .name = "be" },
        .{ .code = 0x97, .name = "a" },
        .{ .code = 0x93, .name = "ae" },
        .{ .code = 0x9C, .name = "l" },
        .{ .code = 0x9F, .name = "g" },
        .{ .code = 0x9E, .name = "le" },
        .{ .code = 0x9D, .name = "ge" },
        .{ .code = 0x94, .name = "e" },
        .{ .code = 0x95, .name = "ne" },
        .{ .code = 0x9A, .name = "p" },
        .{ .code = 0x9B, .name = "np" },
    };
    const setcc_regs = [_]struct { name: []const u8, code: u8 }{
        .{ .name = "al", .code = 0xC0 },
        .{ .name = "bl", .code = 0xC3 },
    };
    var result: [fixed.len + setcc_conds.len * setcc_regs.len]Pattern = undefined;
    for (fixed, 0..) |p, i| result[i] = p;
    var idx: usize = fixed.len;
    for (setcc_regs) |reg| {
        for (setcc_conds) |cond| {
            result[idx] = .{
                .prefix = &[_]u8{ 0x0F, cond.code, reg.code },
                .total_len = 3,
                .operand = .none,
                .asm_prefix = "set" ++ cond.name ++ " " ++ reg.name,
                .asm_suffix = "",
            };
            idx += 1;
        }
    }
    break :blk result;
};

fn matchPattern(code: []const u8) ?Pattern {
    for (PATTERNS) |pat| {
        if (code.len < pat.prefix.len) continue;
        if (std.mem.eql(u8, code[0..pat.prefix.len], pat.prefix)) return pat;
    }
    return null;
}

fn collectTargets(code: []const u8, gpa: std.mem.Allocator) !std.AutoHashMap(usize, usize) {
    var targets = std.AutoHashMap(usize, usize).init(gpa);
    errdefer targets.deinit();
    var next_label: usize = 0;
    var cursor: usize = 0;
    while (cursor < code.len) {
        const pat = matchPattern(code[cursor..]) orelse {
            cursor += 1;
            continue;
        };
        if (pat.operand == .rel) {
            const rel = std.mem.readInt(i32, code[cursor + pat.prefix.len ..][0..4], .little);
            const target: usize = @intCast(@as(i64, @intCast(cursor)) + @as(i64, @intCast(pat.total_len)) + @as(i64, rel));
            if (!targets.contains(target)) {
                try targets.put(target, next_label);
                next_label += 1;
            }
        }
        cursor += pat.total_len;
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
        if (targets.get(cursor)) |label_idx| {
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
            .rel => {
                const rel = std.mem.readInt(i32, code[cursor + pat.prefix.len ..][0..4], .little);
                const target: usize = @intCast(@as(i64, @intCast(cursor)) + @as(i64, @intCast(pat.total_len)) + @as(i64, rel));
                if (targets.get(target)) |label_idx| {
                    try out.print(gpa, "  {s}L{d}{s}\n", .{ pat.asm_prefix, label_idx, pat.asm_suffix });
                } else {
                    try out.print(gpa, "  {s}{d}{s}\n", .{ pat.asm_prefix, target, pat.asm_suffix });
                }
            },
        }
        cursor += pat.total_len;
    }
    return out.toOwnedSlice(gpa);
}
