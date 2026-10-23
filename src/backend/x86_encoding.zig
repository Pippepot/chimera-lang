const std = @import("std");

pub const Operand = enum { none, i8, u8, i32, u32, u64, rel };

const Compact = union(enum) { none, displacement, immediate: []const u8 };

pub const Encoding = struct {
    prefix: []const u8,
    operand: Operand = .none,
    asm_prefix: []const u8,
    asm_suffix: []const u8 = "",
    compact: Compact = .none,

    pub fn length(self: Encoding) usize {
        return self.prefix.len + @as(usize, switch (self.operand) {
            .none => 0,
            .i8, .u8 => 1,
            .i32, .u32, .rel => 4,
            .u64 => 8,
        });
    }
};

const instructions = .{
    .mov_r12_rsp = Encoding{ .prefix = &.{ 0x49, 0x89, 0xE4 }, .asm_prefix = "mov r12, rsp" },
    .mov_r13_r12 = Encoding{ .prefix = &.{ 0x4D, 0x8B, 0x2C, 0x24 }, .asm_prefix = "mov r13, [r12]" },
    .add_r12_8 = Encoding{ .prefix = &.{ 0x49, 0x83, 0xC4, 8 }, .asm_prefix = "add r12, 8" },
    .mov_r14 = Encoding{ .prefix = &.{ 0x49, 0xBE }, .operand = .u64, .asm_prefix = "mov r14, " },
    .mov_r15d = Encoding{ .prefix = &.{ 0x41, 0xBF }, .operand = .i32, .asm_prefix = "mov r15d, " },
    .mov_rax_r14 = Encoding{ .prefix = &.{ 0x49, 0x8B, 0x06 }, .asm_prefix = "mov rax, [r14]" },
    .cmp_rax_r13 = Encoding{ .prefix = &.{ 0x4C, 0x39, 0xE8 }, .asm_prefix = "cmp rax, r13" },
    .add_r14_32 = Encoding{ .prefix = &.{ 0x49, 0x83, 0xC6, 32 }, .asm_prefix = "add r14, 32" },
    .test_rax = Encoding{ .prefix = &.{ 0x48, 0x85, 0xC0 }, .asm_prefix = "test rax, rax" },
    .mov_rax_r14_offset = Encoding{ .prefix = &.{ 0x49, 0x8B, 0x86 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rax, [r14+", .asm_suffix = "]" },
    .mov_rsi_r14_offset = Encoding{ .prefix = &.{ 0x49, 0x8B, 0xB6 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rsi, [r14+", .asm_suffix = "]" },
    .mov_edx_r14_offset = Encoding{ .prefix = &.{ 0x41, 0x8B, 0x96 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov edx, [r14+", .asm_suffix = "]" },
    .add_r12_rax = Encoding{ .prefix = &.{ 0x49, 0x01, 0xC4 }, .asm_prefix = "add r12, rax" },
    .dec_r15d = Encoding{ .prefix = &.{ 0x41, 0xFF, 0xCF }, .asm_prefix = "dec r15d" },
    .add_rsi_rax = Encoding{ .prefix = &.{ 0x48, 0x01, 0xC6 }, .asm_prefix = "add rsi, rax" },
    .sub_rdx_rax = Encoding{ .prefix = &.{ 0x48, 0x29, 0xC2 }, .asm_prefix = "sub rdx, rax" },
    .lea_rax_rip = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x05 }, .operand = .rel, .asm_prefix = "lea rax, [rip+", .asm_suffix = "]" },
    .mov_rax_rdi = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x87 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rax, [rdi+", .asm_suffix = "]" },
    .ret = Encoding{ .prefix = &.{0xC3}, .asm_prefix = "ret" },
    .ud2 = Encoding{ .prefix = &.{ 0x0F, 0x0B }, .asm_prefix = "ud2" },
    .zero_edi = Encoding{ .prefix = &.{ 0x31, 0xFF }, .asm_prefix = "xor edi, edi" },
    .sub_edi_edx = Encoding{ .prefix = &.{ 0x29, 0xD7 }, .asm_prefix = "sub edi, edx" },
    .cdq = Encoding{ .prefix = &.{0x99}, .asm_prefix = "cdq" },
    .idiv_ecx = Encoding{ .prefix = &.{ 0xF7, 0xF9 }, .asm_prefix = "idiv ecx" },
    .neg_eax = Encoding{ .prefix = &.{ 0xF7, 0xD8 }, .asm_prefix = "neg eax" },
    .call_rax = Encoding{ .prefix = &.{ 0xFF, 0xD0 }, .asm_prefix = "call rax" },
    .mov_edx_eax = Encoding{ .prefix = &.{ 0x89, 0xC2 }, .asm_prefix = "mov edx, eax" },
    .mov_edi_eax = Encoding{ .prefix = &.{ 0x89, 0xC7 }, .asm_prefix = "mov edi, eax" },
    .syscall = Encoding{ .prefix = &.{ 0x0F, 0x05 }, .asm_prefix = "syscall" },
    .mov_eax_rsp = Encoding{ .prefix = &.{ 0x8B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov eax, [rsp+", .asm_suffix = "]" },
    .mov_rsp_eax = Encoding{ .prefix = &.{ 0x89, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rsp+", .asm_suffix = "], eax" },
    .add_eax_rsp = Encoding{ .prefix = &.{ 0x03, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "add eax, [rsp+", .asm_suffix = "]" },
    .sub_eax_rsp = Encoding{ .prefix = &.{ 0x2B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "sub eax, [rsp+", .asm_suffix = "]" },
    .mov_ecx_rsp = Encoding{ .prefix = &.{ 0x8B, 0x8C, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov ecx, [rsp+", .asm_suffix = "]" },
    .cmp_ecx = Encoding{ .prefix = &.{ 0x81, 0xF9 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xF9 } }, .asm_prefix = "cmp ecx, " },
    .imul_eax_rsp = Encoding{ .prefix = &.{ 0x0F, 0xAF, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "imul eax, [rsp+", .asm_suffix = "]" },
    .mov_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rax, [rsp+", .asm_suffix = "]" },
    .mov_rsp_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rsp+", .asm_suffix = "], rax" },
    .mov_edi = Encoding{ .prefix = &.{0xBF}, .operand = .i32, .asm_prefix = "mov edi, " },
    .mov_eax = Encoding{ .prefix = &.{0xB8}, .operand = .i32, .asm_prefix = "mov eax, " },
    .mov_ecx = Encoding{ .prefix = &.{0xB9}, .operand = .i32, .asm_prefix = "mov ecx, " },
    .mov_edx = Encoding{ .prefix = &.{0xBA}, .operand = .i32, .asm_prefix = "mov edx, " },
    .mov_rax = Encoding{ .prefix = &.{ 0x48, 0xB8 }, .operand = .u64, .asm_prefix = "mov rax, " },
    .imul_eax = Encoding{ .prefix = &.{ 0x69, 0xC0 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x6B, 0xC0 } }, .asm_prefix = "imul eax, eax, " },
    .sub_eax = Encoding{ .prefix = &.{0x2D}, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xE8 } }, .asm_prefix = "sub eax, " },
    .add_eax = Encoding{ .prefix = &.{0x05}, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xC0 } }, .asm_prefix = "add eax, " },
    .cmp_eax = Encoding{ .prefix = &.{0x3D}, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xF8 } }, .asm_prefix = "cmp eax, " },
    .sub_rsp = Encoding{ .prefix = &.{ 0x48, 0x81, 0xEC }, .operand = .u32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xEC } }, .asm_prefix = "sub rsp, " },
    .add_rsp = Encoding{ .prefix = &.{ 0x48, 0x81, 0xC4 }, .operand = .u32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xC4 } }, .asm_prefix = "add rsp, " },
    .call_relative = Encoding{ .prefix = &.{0xE8}, .operand = .rel, .asm_prefix = "call " },
    .jmp = Encoding{ .prefix = &.{0xE9}, .operand = .rel, .asm_prefix = "jmp " },
    .je = Encoding{ .prefix = &.{ 0x0F, 0x84 }, .operand = .rel, .asm_prefix = "je " },
    .jne = Encoding{ .prefix = &.{ 0x0F, 0x85 }, .operand = .rel, .asm_prefix = "jne " },
    .jl = Encoding{ .prefix = &.{ 0x0F, 0x8C }, .operand = .rel, .asm_prefix = "jl " },
    .jg = Encoding{ .prefix = &.{ 0x0F, 0x8F }, .operand = .rel, .asm_prefix = "jg " },
    .jle = Encoding{ .prefix = &.{ 0x0F, 0x8E }, .operand = .rel, .asm_prefix = "jle " },
    .jge = Encoding{ .prefix = &.{ 0x0F, 0x8D }, .operand = .rel, .asm_prefix = "jge " },
    .nop = Encoding{ .prefix = &.{0x90}, .asm_prefix = "nop" },
    .test_edx = Encoding{ .prefix = &.{ 0x85, 0xD2 }, .asm_prefix = "test edx, edx" },
    .cmp_edx = Encoding{ .prefix = &.{ 0x81, 0xFA }, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xFA } }, .asm_prefix = "cmp edx, " },
    .cmp_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x39, 0xC8 }, .asm_prefix = "cmp rax, rcx" },
    .mov_rcx_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC1 }, .asm_prefix = "mov rcx, rax" },
    .mov_rax_rax_offset = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x80 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rax, [rax+", .asm_suffix = "]" },
    .mov_rax_rcx_offset = Encoding{ .prefix = &.{ 0x48, 0x89, 0x88 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rax+", .asm_suffix = "], rcx" },
    .cmp_eax_rsp = Encoding{ .prefix = &.{ 0x3B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "cmp eax, [rsp+", .asm_suffix = "]" },
    .movzx_eax_rsp = Encoding{ .prefix = &.{ 0x0F, 0xB6, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movzx eax, byte [rsp+", .asm_suffix = "]" },
    .mov_rsp_al = Encoding{ .prefix = &.{ 0x88, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rsp+", .asm_suffix = "], al" },
    .mov_esi = Encoding{ .prefix = &.{0xBE}, .operand = .i32, .asm_prefix = "mov esi, " },
    .mov_r10d = Encoding{ .prefix = &.{ 0x41, 0xBA }, .operand = .i32, .asm_prefix = "mov r10d, " },
    .imul_rsi = Encoding{ .prefix = &.{ 0x48, 0x69, 0xF6 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x6B, 0xF6 } }, .asm_prefix = "imul rsi, rsi, " },
    .cmp_rsi = Encoding{ .prefix = &.{ 0x48, 0x81, 0xFE }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xFE } }, .asm_prefix = "cmp rsi, " },
    .ja = Encoding{ .prefix = &.{ 0x0F, 0x87 }, .operand = .rel, .asm_prefix = "ja " },
    .jae = Encoding{ .prefix = &.{ 0x0F, 0x83 }, .operand = .rel, .asm_prefix = "jae " },
    .mov_eax_esi = Encoding{ .prefix = &.{ 0x89, 0xF0 }, .asm_prefix = "mov eax, esi" },
    .mov_esi_eax = Encoding{ .prefix = &.{ 0x89, 0xC6 }, .asm_prefix = "mov esi, eax" },
    .movsxd_rcx_rsp = Encoding{ .prefix = &.{ 0x48, 0x63, 0x8C, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movsxd rcx, [rsp+", .asm_suffix = "]" },
    .movsxd_rcx_eax = Encoding{ .prefix = &.{ 0x48, 0x63, 0xC8 }, .asm_prefix = "movsxd rcx, eax" },
    .mov_rcx_rsp = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x8C, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rcx, [rsp+", .asm_suffix = "]" },
    .imul_rcx = Encoding{ .prefix = &.{ 0x48, 0x69, 0xC9 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x6B, 0xC9 } }, .asm_prefix = "imul rcx, rcx, " },
    .add_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x01, 0xC8 }, .asm_prefix = "add rax, rcx" },
    .lea_rax_rax_rcx_2 = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x04, 0x48 }, .asm_prefix = "lea rax, [rax+rcx*2]" },
    .lea_rax_rax_rcx_4 = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x04, 0x88 }, .asm_prefix = "lea rax, [rax+rcx*4]" },
    .lea_rax_rax_rcx_8 = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x04, 0xC8 }, .asm_prefix = "lea rax, [rax+rcx*8]" },
    .add_rax = Encoding{ .prefix = &.{ 0x48, 0x05 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xC0 } }, .asm_prefix = "add rax, " },
    .mov_rdi_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC7 }, .asm_prefix = "mov rdi, rax" },
    .mov_rdi_eax = Encoding{ .prefix = &.{ 0x89, 0x87 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rdi+", .asm_suffix = "], eax" },
    .mov_rdi_al = Encoding{ .prefix = &.{ 0x88, 0x87 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rdi+", .asm_suffix = "], al" },
    .mov_rdi_rsp = Encoding{ .prefix = &.{ 0x48, 0x8B, 0xBC, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rdi, [rsp+", .asm_suffix = "]" },
    .mov_rsi_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC6 }, .asm_prefix = "mov rsi, rax" },
    .lea_rsi_rsp = Encoding{ .prefix = &.{ 0x48, 0x8D, 0xB4, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "lea rsi, [rsp+", .asm_suffix = "]" },
    .lea_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "lea rax, [rsp+", .asm_suffix = "]" },
    .mov_eax_rax = Encoding{ .prefix = &.{ 0x8B, 0x80 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov eax, [rax+", .asm_suffix = "]" },
    .mov_rax_rax = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x00 }, .asm_prefix = "mov rax, [rax]" },
    .movzx_eax_rax = Encoding{ .prefix = &.{ 0x0F, 0xB6, 0x80 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movzx eax, byte [rax+", .asm_suffix = "]" },
    .lea_rdi_rsp = Encoding{ .prefix = &.{ 0x48, 0x8D, 0xBC, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "lea rdi, [rsp+", .asm_suffix = "]" },
    .mov_eax_rsi = Encoding{ .prefix = &.{ 0x8B, 0x06 }, .asm_prefix = "mov eax, [rsi]" },
    .mov_rax_rsi_offset = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x86 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rax, [rsi+", .asm_suffix = "]" },
    .mov_eax_rsi_offset = Encoding{ .prefix = &.{ 0x8B, 0x86 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov eax, [rsi+", .asm_suffix = "]" },
    .movzx_eax_rsi_offset = Encoding{ .prefix = &.{ 0x0F, 0xB6, 0x86 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movzx eax, byte [rsi+", .asm_suffix = "]" },
    .mov_rdi_rax_offset = Encoding{ .prefix = &.{ 0x48, 0x89, 0x87 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov [rdi+", .asm_suffix = "], rax" },
    .rep_movsb = Encoding{ .prefix = &.{ 0xF3, 0xA4 }, .asm_prefix = "rep movsb" },
    .mov_r8d = Encoding{ .prefix = &.{ 0x41, 0xB8 }, .operand = .i32, .asm_prefix = "mov r8d, " },
    .zero_r9d = Encoding{ .prefix = &.{ 0x45, 0x31, 0xC9 }, .asm_prefix = "xor r9d, r9d" },
    .zero_edx = Encoding{ .prefix = &.{ 0x31, 0xD2 }, .asm_prefix = "xor edx, edx" },
    .test_esi = Encoding{ .prefix = &.{ 0x85, 0xF6 }, .asm_prefix = "test esi, esi" },
    .cmp_rax = Encoding{ .prefix = &.{ 0x48, 0x3D }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xF8 } }, .asm_prefix = "cmp rax, " },
    .shr_rax_32 = Encoding{ .prefix = &.{ 0x48, 0xC1, 0xE8, 32 }, .asm_prefix = "shr rax, 32" },
    .shl_rsi_32 = Encoding{ .prefix = &.{ 0x48, 0xC1, 0xE6, 32 }, .asm_prefix = "shl rsi, 32" },
    .or_rdi_rsi = Encoding{ .prefix = &.{ 0x48, 0x09, 0xF7 }, .asm_prefix = "or rdi, rsi" },
    .mov_edi_rsp = Encoding{ .prefix = &.{ 0x8B, 0xBC, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov edi, [rsp+", .asm_suffix = "]" },
    .mov_esi_rsp = Encoding{ .prefix = &.{ 0x8B, 0xB4, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov esi, [rsp+", .asm_suffix = "]" },
    .cmp_eax_rcx = Encoding{ .prefix = &.{ 0x3B, 0x01 }, .asm_prefix = "cmp eax, [rcx]" },
    .mov_ecx_rcx = Encoding{ .prefix = &.{ 0x8B, 0x09 }, .asm_prefix = "mov ecx, [rcx]" },
    .add_eax_rcx = Encoding{ .prefix = &.{ 0x03, 0x01 }, .asm_prefix = "add eax, [rcx]" },
    .sub_eax_rcx = Encoding{ .prefix = &.{ 0x2B, 0x01 }, .asm_prefix = "sub eax, [rcx]" },
    .imul_eax_rcx = Encoding{ .prefix = &.{ 0x0F, 0xAF, 0x01 }, .asm_prefix = "imul eax, [rcx]" },
};

pub const Operation = std.meta.FieldEnum(@TypeOf(instructions));

const Forms = struct { full: Encoding, small: ?Encoding = null, zero: ?Encoding = null };

fn displacementEncoding(comptime full: Encoding, comptime operand: Operand) Encoding {
    var prefix = full.prefix[0..full.prefix.len].*;
    const modrm_index = prefix.len - @as(usize, if (prefix[prefix.len - 1] == 0x24) 2 else 1);
    std.debug.assert(prefix[modrm_index] & 0xc0 == 0x80);
    std.debug.assert(prefix[modrm_index] & 7 != 5);
    prefix[modrm_index] = (prefix[modrm_index] & 0x3f) | @as(u8, if (operand == .none) 0 else 0x40);
    const stored_prefix = prefix;
    return .{
        .prefix = &stored_prefix,
        .operand = operand,
        .asm_prefix = if (operand == .none) full.asm_prefix[0 .. full.asm_prefix.len - 1] ++ full.asm_suffix else full.asm_prefix,
        .asm_suffix = if (operand == .none) "" else full.asm_suffix,
    };
}

const forms = blk: {
    @setEvalBranchQuota(10000);
    const field_names = @typeInfo(@TypeOf(instructions)).@"struct".field_names;
    var result: [field_names.len]Forms = undefined;
    for (field_names, 0..) |field_name, index| {
        const full = @field(instructions, field_name);
        result[index] = .{ .full = full };
        switch (full.compact) {
            .none => {},
            .displacement => {
                result[index].small = displacementEncoding(full, .u8);
                result[index].zero = displacementEncoding(full, .none);
            },
            .immediate => |prefix| result[index].small = .{ .prefix = prefix, .operand = .i8, .asm_prefix = full.asm_prefix, .asm_suffix = full.asm_suffix },
        }
    }
    break :blk result;
};

/// Every encodable form, each operation's forms in order full, small, zero.
pub const patterns = blk: {
    var result: [3 * forms.len]Encoding = undefined;
    var count: usize = 0;
    for (forms) |form| for ([_]?Encoding{ form.full, form.small, form.zero }) |maybe_pattern| if (maybe_pattern) |pattern| {
        result[count] = pattern;
        count += 1;
    };
    const used = result[0..count].*;
    break :blk used;
};

pub fn encoding(operation: Operation) Encoding {
    return forms[@backingInt(operation)].full;
}

pub fn selectedEncoding(operation: Operation, bits: u64) Encoding {
    const form = forms[@backingInt(operation)];
    switch (form.full.compact) {
        .none => {},
        .displacement => {
            if (bits == 0) return form.zero.?;
            if (bits <= std.math.maxInt(i8)) return form.small.?;
        },
        .immediate => {
            const value: i32 = @bitCast(@as(u32, @truncate(bits)));
            if ((form.full.operand == .i32 or bits <= std.math.maxInt(i8)) and std.math.cast(i8, value) != null) return form.small.?;
        },
    }
    return form.full;
}

pub fn append(code: *std.ArrayList(u8), allocator: std.mem.Allocator, operation: Operation, bits: u64) !void {
    const pattern = selectedEncoding(operation, bits);
    const destination = try code.addManyAsSlice(allocator, pattern.length());
    @memcpy(destination[0..pattern.prefix.len], pattern.prefix);
    const operand = destination[pattern.prefix.len..];
    switch (pattern.operand) {
        .none => {},
        .i8, .u8 => operand[0] = @truncate(bits),
        .i32, .u32, .rel => std.mem.writeInt(u32, operand[0..4], @truncate(bits), .little),
        .u64 => std.mem.writeInt(u64, operand[0..8], bits, .little),
    }
}

test "x86 instruction append preserves prefix and operand bytes" {
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(std.testing.allocator);
    const bits: u64 = 0x88776655ccbbaa99;
    const encoded = [_]u8{ 0x99, 0xaa, 0xbb, 0xcc, 0x55, 0x66, 0x77, 0x88 };
    for (std.meta.tags(Operation)) |operation| {
        const pattern = selectedEncoding(operation, bits);
        code.clearRetainingCapacity();
        try code.append(std.testing.allocator, 0xcc);
        try append(&code, std.testing.allocator, operation, bits);
        try std.testing.expectEqual(@as(u8, 0xcc), code.items[0]);
        try std.testing.expectEqual(1 + pattern.length(), code.items.len);
        try std.testing.expectEqualSlices(u8, pattern.prefix, code.items[1..][0..pattern.prefix.len]);
        const operand = code.items[1 + pattern.prefix.len ..];
        try std.testing.expectEqualSlices(u8, encoded[0..operand.len], operand);
    }
}

test "x86 instruction compact forms respect displacement and signed immediate boundaries" {
    const cases = [_]struct { operation: Operation, bits: u64, expected: []const u8 }{
        .{ .operation = .mov_eax_rsp, .bits = 0, .expected = &.{ 0x8b, 0x04, 0x24 } },
        .{ .operation = .mov_eax_rsp, .bits = 127, .expected = &.{ 0x8b, 0x44, 0x24, 127 } },
        .{ .operation = .mov_eax_rsp, .bits = 128, .expected = &.{ 0x8b, 0x84, 0x24, 128, 0, 0, 0 } },
        .{ .operation = .mov_eax_rax, .bits = 0, .expected = &.{ 0x8b, 0x00 } },
        .{ .operation = .add_eax, .bits = @as(u32, @bitCast(@as(i32, -128))), .expected = &.{ 0x83, 0xc0, 128 } },
        .{ .operation = .add_eax, .bits = @as(u32, @bitCast(@as(i32, -129))), .expected = &.{ 0x05, 127, 255, 255, 255 } },
        .{ .operation = .imul_eax, .bits = 127, .expected = &.{ 0x6b, 0xc0, 127 } },
        .{ .operation = .imul_eax, .bits = 128, .expected = &.{ 0x69, 0xc0, 128, 0, 0, 0 } },
        .{ .operation = .sub_rsp, .bits = 127, .expected = &.{ 0x48, 0x83, 0xec, 127 } },
        .{ .operation = .sub_rsp, .bits = 128, .expected = &.{ 0x48, 0x81, 0xec, 128, 0, 0, 0 } },
    };
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(std.testing.allocator);
    for (cases) |case| {
        code.clearRetainingCapacity();
        try append(&code, std.testing.allocator, case.operation, case.bits);
        try std.testing.expectEqualSlices(u8, case.expected, code.items);
    }
}

test "x86 instruction append leaves code unchanged on allocation failure" {
    var code = try std.ArrayList(u8).initCapacity(std.testing.allocator, 1);
    defer code.deinit(std.testing.allocator);
    while (code.items.len < code.capacity) code.appendAssumeCapacity(0xcc);
    const original_len = code.items.len;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, append(&code, failing.allocator(), .add_eax, 42));
    try std.testing.expectEqual(original_len, code.items.len);
    for (code.items) |byte| try std.testing.expectEqual(@as(u8, 0xcc), byte);
}
