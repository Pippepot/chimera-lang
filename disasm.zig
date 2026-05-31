const std = @import("std");

const Operand = enum {
    none,
    i32,
    u32,
    rel,
};

const Pattern = struct {
    prefix: []const u8,
    total_len: u8,
    operand: Operand,
    asm_prefix: []const u8,
    asm_suffix: []const u8,
};

fn patterns() [patternCount()]Pattern {
    return [_]Pattern{
        // stack frame
        .{ .prefix = &.{0x55}, .total_len = 1, .operand = .none, .asm_prefix = "push rbp", .asm_suffix = "" },
        .{ .prefix = &.{0x5D}, .total_len = 1, .operand = .none, .asm_prefix = "pop rbp", .asm_suffix = "" },
        .{ .prefix = &.{0xC3}, .total_len = 1, .operand = .none, .asm_prefix = "ret", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xE5 }, .total_len = 3, .operand = .none, .asm_prefix = "mov rbp, rsp", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x89, 0xEC }, .total_len = 3, .operand = .none, .asm_prefix = "mov rsp, rbp", .asm_suffix = "" },

        // entry setup
        .{ .prefix = &.{ 0x4C, 0x8D, 0x7C, 0x24, 0x08 }, .total_len = 5, .operand = .none, .asm_prefix = "lea r15, [rsp+8]", .asm_suffix = "" },

        // integer arithmetic
        .{ .prefix = &.{ 0x01, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "add eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x29, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "sub eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0xAF, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "imul eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{0x99}, .total_len = 1, .operand = .none, .asm_prefix = "cdq", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF7, 0xFB }, .total_len = 2, .operand = .none, .asm_prefix = "idiv ebx", .asm_suffix = "" },

        // comparisons
        .{ .prefix = &.{ 0x39, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "cmp eax, ebx", .asm_suffix = "" },
        .{ .prefix = &.{ 0x83, 0xF8, 0x00 }, .total_len = 3, .operand = .none, .asm_prefix = "cmp eax, 0", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x2E, 0xC1 }, .total_len = 3, .operand = .none, .asm_prefix = "ucomiss xmm0, xmm1", .asm_suffix = "" },

        // indirect call
        .{ .prefix = &.{ 0xFF, 0xD0 }, .total_len = 2, .operand = .none, .asm_prefix = "call rax", .asm_suffix = "" },

        // boolean ops
        .{ .prefix = &.{ 0x0F, 0xB6, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "movzx eax, al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x20, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "and al, bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x08, 0xD8 }, .total_len = 2, .operand = .none, .asm_prefix = "or al, bl", .asm_suffix = "" },

        // exit sequence
        .{ .prefix = &.{ 0x89, 0xC7 }, .total_len = 2, .operand = .none, .asm_prefix = "mov edi, eax", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x05 }, .total_len = 2, .operand = .none, .asm_prefix = "syscall", .asm_suffix = "" },

        // setcc al
        .{ .prefix = &.{ 0x0F, 0x92, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setb al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x96, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setbe al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x97, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "seta al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x93, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setae al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9C, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setl al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9F, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setg al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9E, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setle al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9D, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setge al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x94, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "sete al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x95, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setne al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9A, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setp al", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9B, 0xC0 }, .total_len = 3, .operand = .none, .asm_prefix = "setnp al", .asm_suffix = "" },

        // setcc bl
        .{ .prefix = &.{ 0x0F, 0x92, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setb bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x96, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setbe bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x97, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "seta bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x93, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setae bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9C, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setl bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9F, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setg bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9E, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setle bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9D, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setge bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x94, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "sete bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x95, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setne bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9A, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setp bl", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x9B, 0xC3 }, .total_len = 3, .operand = .none, .asm_prefix = "setnp bl", .asm_suffix = "" },

        // float binary ops
        .{ .prefix = &.{ 0xF3, 0x0F, 0x58, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "addss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x5C, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "subss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x59, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "mulss xmm0, xmm1", .asm_suffix = "" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x5E, 0xC1 }, .total_len = 4, .operand = .none, .asm_prefix = "divss xmm0, xmm1", .asm_suffix = "" },

        // slot loads — mov reg, [rsp+{d}]
        .{ .prefix = &.{ 0x8B, 0x84, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov eax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x8B, 0x9C, 0x24 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov ebx, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0xBC, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rdi, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0xB4, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rsi, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x94, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rdx, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov rcx, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x4C, 0x8B, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov r8, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x4C, 0x8B, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov r9, [rsp+", .asm_suffix = "]" },

        // slot stores — mov [rsp+{d}], reg
        .{ .prefix = &.{ 0x48, 0x89, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rax" },
        .{ .prefix = &.{ 0x48, 0x89, 0xBC, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rdi" },
        .{ .prefix = &.{ 0x48, 0x89, 0xB4, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rsi" },
        .{ .prefix = &.{ 0x48, 0x89, 0x94, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rdx" },
        .{ .prefix = &.{ 0x48, 0x89, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rcx" },
        .{ .prefix = &.{ 0x4C, 0x89, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], r8" },
        .{ .prefix = &.{ 0x4C, 0x89, 0x8C, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], r9" },

        // xmm slot loads
        .{ .prefix = &.{ 0xF3, 0x0F, 0x10, 0x84, 0x24 }, .total_len = 9, .operand = .u32, .asm_prefix = "movss xmm0, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0xF3, 0x0F, 0x10, 0x8C, 0x24 }, .total_len = 9, .operand = .u32, .asm_prefix = "movss xmm1, [rsp+", .asm_suffix = "]" },

        // xmm slot store
        .{ .prefix = &.{ 0xF3, 0x0F, 0x11, 0x84, 0x24 }, .total_len = 9, .operand = .u32, .asm_prefix = "movss [rsp+", .asm_suffix = "], xmm0" },

        // pointer/memory helpers
        .{ .prefix = &.{ 0x48, 0x8D, 0x84, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "lea rax, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x4C, 0x8D, 0x94, 0x24 }, .total_len = 8, .operand = .u32, .asm_prefix = "lea r10, [rsp+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x48, 0x8B, 0x80 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov rax, [rax+", .asm_suffix = "]" },
        .{ .prefix = &.{ 0x49, 0x89, 0x82 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov [r10+", .asm_suffix = "], rax" },
        .{ .prefix = &.{ 0x48, 0x89, 0x82 }, .total_len = 7, .operand = .u32, .asm_prefix = "mov [rdx+", .asm_suffix = "], rax" },

        // immediate (signed)
        .{ .prefix = &.{0xB8}, .total_len = 5, .operand = .i32, .asm_prefix = "mov eax, ", .asm_suffix = "" },

        // sub rsp, frame_size
        .{ .prefix = &.{ 0x48, 0x81, 0xEC }, .total_len = 7, .operand = .u32, .asm_prefix = "sub rsp, ", .asm_suffix = "" },

        // argv load
        .{ .prefix = &.{ 0x49, 0x8B, 0xBF }, .total_len = 7, .operand = .u32, .asm_prefix = "mov rdi, [r15+", .asm_suffix = "]" },

        // rel32
        .{ .prefix = &.{0xE8}, .total_len = 5, .operand = .rel, .asm_prefix = "call ", .asm_suffix = "" },
        .{ .prefix = &.{0xE9}, .total_len = 5, .operand = .rel, .asm_prefix = "jmp ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x84 }, .total_len = 6, .operand = .rel, .asm_prefix = "je ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x0F, 0x85 }, .total_len = 6, .operand = .rel, .asm_prefix = "jne ", .asm_suffix = "" },
        .{ .prefix = &.{ 0x48, 0x8D, 0x05 }, .total_len = 7, .operand = .rel, .asm_prefix = "lea rax, [rip+", .asm_suffix = "]" },
    };
}

fn patternCount() comptime_int {
    return 80;
}

fn matchPattern(code: []const u8) ?Pattern {
    for (patterns()) |pat| {
        if (code.len < pat.prefix.len) continue;
        if (std.mem.eql(u8, code[0..pat.prefix.len], pat.prefix)) {
            return pat;
        }
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
            .none => {
                try out.print(gpa, "  {s}\n", .{pat.asm_prefix});
            },
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
