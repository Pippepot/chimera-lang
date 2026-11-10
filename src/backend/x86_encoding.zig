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
    .and_eax_ecx = Encoding{ .prefix = &.{ 0x21, 0xc8 }, .asm_prefix = "and eax, ecx" },
    .sub_ecx = Encoding{ .prefix = &.{ 0x81, 0xE9 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xE9 } }, .asm_prefix = "sub ecx, " },
    .add_eax_ecx = Encoding{ .prefix = &.{ 0x01, 0xc8 }, .asm_prefix = "add eax, ecx" },
    .sub_eax_ecx = Encoding{ .prefix = &.{ 0x29, 0xc8 }, .asm_prefix = "sub eax, ecx" },
    .imul_eax_ecx = Encoding{ .prefix = &.{ 0x0f, 0xaf, 0xc1 }, .asm_prefix = "imul eax, ecx" },
    .mul_ecx = Encoding{ .prefix = &.{ 0xf7, 0xe1 }, .asm_prefix = "mul ecx" },
    .mov_rax_from_rdi = Encoding{ .prefix = &.{ 0x48, 0x89, 0xf8 }, .asm_prefix = "mov rax, rdi" },
    .movaps_xmm2_xmm1 = Encoding{ .prefix = &.{ 0x0f, 0x28, 0xd1 }, .asm_prefix = "movaps xmm2, xmm1" },
    .movaps_xmm1_xmm2 = Encoding{ .prefix = &.{ 0x0f, 0x28, 0xca }, .asm_prefix = "movaps xmm1, xmm2" },
    .mov_rcx = Encoding{ .prefix = &.{ 0x48, 0xB9 }, .operand = .u64, .asm_prefix = "mov rcx, " },
    .cmp_rax_rdx = Encoding{ .prefix = &.{ 0x48, 0x39, 0xD0 }, .asm_prefix = "cmp rax, rdx" },
    .cvtsd2si_rax_xmm0 = Encoding{ .prefix = &.{ 0xf2, 0x48, 0x0f, 0x2d, 0xc0 }, .asm_prefix = "cvtsd2si rax, xmm0" },
    .mov_rax_rsi = Encoding{ .prefix = &.{ 0x48, 0x89, 0xf0 }, .asm_prefix = "mov rax, rsi" },
    .mov_rax_rdx = Encoding{ .prefix = &.{ 0x48, 0x89, 0xd0 }, .asm_prefix = "mov rax, rdx" },
    .mov_rdx_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xc2 }, .asm_prefix = "mov rdx, rax" },
    .mov_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x89, 0xc8 }, .asm_prefix = "mov rax, rcx" },
    .sub_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x29, 0xc8 }, .asm_prefix = "sub rax, rcx" },
    .imul_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0xf, 0xaf, 0xc1 }, .asm_prefix = "imul rax, rcx" },
    .mul_rcx = Encoding{ .prefix = &.{ 0x48, 0xf7, 0xe1 }, .asm_prefix = "mul rcx" },
    .idiv_rcx = Encoding{ .prefix = &.{ 0x48, 0xf7, 0xf9 }, .asm_prefix = "idiv rcx" },
    .div_rcx = Encoding{ .prefix = &.{ 0x48, 0xf7, 0xf1 }, .asm_prefix = "div rcx" },
    .cqo = Encoding{ .prefix = &.{ 0x48, 0x99 }, .asm_prefix = "cqo" },
    .not_rax = Encoding{ .prefix = &.{ 0x48, 0xf7, 0xd0 }, .asm_prefix = "not rax" },
    .and_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x21, 0xc8 }, .asm_prefix = "and rax, rcx" },
    .or_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x9, 0xc8 }, .asm_prefix = "or rax, rcx" },
    .xor_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x31, 0xc8 }, .asm_prefix = "xor rax, rcx" },
    .shl_rax_cl = Encoding{ .prefix = &.{ 0x48, 0xd3, 0xe0 }, .asm_prefix = "shl rax, cl" },
    .sar_rax_cl = Encoding{ .prefix = &.{ 0x48, 0xd3, 0xf8 }, .asm_prefix = "sar rax, cl" },
    .shr_rax_cl = Encoding{ .prefix = &.{ 0x48, 0xd3, 0xe8 }, .asm_prefix = "shr rax, cl" },
    .test_rcx = Encoding{ .prefix = &.{ 0x48, 0x85, 0xc9 }, .asm_prefix = "test rcx, rcx" },
    .test_rdx = Encoding{ .prefix = &.{ 0x48, 0x85, 0xd2 }, .asm_prefix = "test rdx, rdx" },
    .test_rsi = Encoding{ .prefix = &.{ 0x48, 0x85, 0xf6 }, .asm_prefix = "test rsi, rsi" },
    .movsx_rax_al = Encoding{ .prefix = &.{ 0x48, 0xf, 0xbe, 0xc0 }, .asm_prefix = "movsx rax, al" },
    .movsx_rax_ax = Encoding{ .prefix = &.{ 0x48, 0xf, 0xbf, 0xc0 }, .asm_prefix = "movsx rax, ax" },
    .movsxd_rax_eax = Encoding{ .prefix = &.{ 0x48, 0x63, 0xc0 }, .asm_prefix = "movsxd rax, eax" },
    .movzx_eax_ax = Encoding{ .prefix = &.{ 0xf, 0xb7, 0xc0 }, .asm_prefix = "movzx eax, ax" },
    .mov_eax_eax = Encoding{ .prefix = &.{ 0x89, 0xc0 }, .asm_prefix = "mov eax, eax" },
    .movq_xmm0_rax = Encoding{ .prefix = &.{ 0x66, 0x48, 0xf, 0x6e, 0xc0 }, .asm_prefix = "movq xmm0, rax" },
    .movq_xmm1_rax = Encoding{ .prefix = &.{ 0x66, 0x48, 0xf, 0x6e, 0xc8 }, .asm_prefix = "movq xmm1, rax" },
    .movq_rax_xmm0 = Encoding{ .prefix = &.{ 0x66, 0x48, 0xf, 0x7e, 0xc0 }, .asm_prefix = "movq rax, xmm0" },
    .movq_xmm2_rax = Encoding{ .prefix = &.{ 0x66, 0x48, 0xf, 0x6e, 0xd0 }, .asm_prefix = "movq xmm2, rax" },
    .movaps_xmm1_xmm0 = Encoding{ .prefix = &.{ 0xf, 0x28, 0xc8 }, .asm_prefix = "movaps xmm1, xmm0" },
    .movaps_xmm2_xmm0 = Encoding{ .prefix = &.{ 0xf, 0x28, 0xd0 }, .asm_prefix = "movaps xmm2, xmm0" },
    .cvtsi2ss_xmm0_rax = Encoding{ .prefix = &.{ 0xf3, 0x48, 0xf, 0x2a, 0xc0 }, .asm_prefix = "cvtsi2ss xmm0, rax" },
    .cvtsi2sd_xmm0_rax = Encoding{ .prefix = &.{ 0xf2, 0x48, 0xf, 0x2a, 0xc0 }, .asm_prefix = "cvtsi2sd xmm0, rax" },
    .cvtss2sd_xmm0_xmm0 = Encoding{ .prefix = &.{ 0xf3, 0xf, 0x5a, 0xc0 }, .asm_prefix = "cvtss2sd xmm0, xmm0" },
    .cvtsd2ss_xmm0_xmm0 = Encoding{ .prefix = &.{ 0xf2, 0xf, 0x5a, 0xc0 }, .asm_prefix = "cvtsd2ss xmm0, xmm0" },
    .cvttsd2si_rax_xmm0 = Encoding{ .prefix = &.{ 0xf2, 0x48, 0xf, 0x2c, 0xc0 }, .asm_prefix = "cvttsd2si rax, xmm0" },
    .ucomiss_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf, 0x2e, 0xc1 }, .asm_prefix = "ucomiss xmm0, xmm1" },
    .ucomisd_xmm0_xmm1 = Encoding{ .prefix = &.{ 0x66, 0xf, 0x2e, 0xc1 }, .asm_prefix = "ucomisd xmm0, xmm1" },
    .ucomisd_xmm0_xmm2 = Encoding{ .prefix = &.{ 0x66, 0xf, 0x2e, 0xc2 }, .asm_prefix = "ucomisd xmm0, xmm2" },
    .ucomisd_xmm0_xmm0 = Encoding{ .prefix = &.{ 0x66, 0xf, 0x2e, 0xc0 }, .asm_prefix = "ucomisd xmm0, xmm0" },
    .ucomiss_xmm0_xmm0 = Encoding{ .prefix = &.{ 0xf, 0x2e, 0xc0 }, .asm_prefix = "ucomiss xmm0, xmm0" },
    .jo = Encoding{ .prefix = &.{ 0xf, 0x80 }, .operand = .rel, .asm_prefix = "jo " },
    .jno = Encoding{ .prefix = &.{ 0xf, 0x81 }, .operand = .rel, .asm_prefix = "jno " },
    .jb = Encoding{ .prefix = &.{ 0xf, 0x82 }, .operand = .rel, .asm_prefix = "jb " },
    .jbe = Encoding{ .prefix = &.{ 0xf, 0x86 }, .operand = .rel, .asm_prefix = "jbe " },
    .jp = Encoding{ .prefix = &.{ 0xf, 0x8a }, .operand = .rel, .asm_prefix = "jp " },
    .jnp = Encoding{ .prefix = &.{ 0xf, 0x8b }, .operand = .rel, .asm_prefix = "jnp " },
    .js = Encoding{ .prefix = &.{ 0xf, 0x88 }, .operand = .rel, .asm_prefix = "js " },
    .jns = Encoding{ .prefix = &.{ 0xf, 0x89 }, .operand = .rel, .asm_prefix = "jns " },
    .addss_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf3, 0xf, 0x58, 0xc1 }, .asm_prefix = "addss xmm0, xmm1" },
    .subss_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf3, 0xf, 0x5c, 0xc1 }, .asm_prefix = "subss xmm0, xmm1" },
    .mulss_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf3, 0xf, 0x59, 0xc1 }, .asm_prefix = "mulss xmm0, xmm1" },
    .divss_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf3, 0xf, 0x5e, 0xc1 }, .asm_prefix = "divss xmm0, xmm1" },
    .addsd_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf2, 0xf, 0x58, 0xc1 }, .asm_prefix = "addsd xmm0, xmm1" },
    .subsd_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf2, 0xf, 0x5c, 0xc1 }, .asm_prefix = "subsd xmm0, xmm1" },
    .mulsd_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf2, 0xf, 0x59, 0xc1 }, .asm_prefix = "mulsd xmm0, xmm1" },
    .divsd_xmm0_xmm1 = Encoding{ .prefix = &.{ 0xf2, 0xf, 0x5e, 0xc1 }, .asm_prefix = "divsd xmm0, xmm1" },
    .sar_rax = Encoding{ .prefix = &.{ 0x48, 0xc1, 0xf8 }, .operand = .u8, .asm_prefix = "sar rax, " },
    .shr_rsi = Encoding{ .prefix = &.{ 0x48, 0xc1, 0xee }, .operand = .u8, .asm_prefix = "shr rsi, " },
    .add_rax_rsi = Encoding{ .prefix = &.{ 0x48, 0x01, 0xf0 }, .asm_prefix = "add rax, rsi" },
    .shl_rax = Encoding{ .prefix = &.{ 0x48, 0xc1, 0xe0 }, .operand = .u8, .asm_prefix = "shl rax, " },
    .sub_rax_rsi = Encoding{ .prefix = &.{ 0x48, 0x29, 0xf0 }, .asm_prefix = "sub rax, rsi" },
    .cmovb_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x42, 0xC1 }, .asm_prefix = "cmovb eax, ecx" },
    .cmovae_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x43, 0xC1 }, .asm_prefix = "cmovae eax, ecx" },
    .cmovne_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x45, 0xC1 }, .asm_prefix = "cmovne eax, ecx" },
    .cmovbe_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x46, 0xC1 }, .asm_prefix = "cmovbe eax, ecx" },
    .cmova_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x47, 0xC1 }, .asm_prefix = "cmova eax, ecx" },
    .cmovl_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x4C, 0xC1 }, .asm_prefix = "cmovl eax, ecx" },
    .cmovge_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x4D, 0xC1 }, .asm_prefix = "cmovge eax, ecx" },
    .cmovle_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x4E, 0xC1 }, .asm_prefix = "cmovle eax, ecx" },
    .cmovg_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x4F, 0xC1 }, .asm_prefix = "cmovg eax, ecx" },
    .setb_al = Encoding{ .prefix = &.{ 0x0F, 0x92, 0xC0 }, .asm_prefix = "setb al" },
    .setae_al = Encoding{ .prefix = &.{ 0x0F, 0x93, 0xC0 }, .asm_prefix = "setae al" },
    .setbe_al = Encoding{ .prefix = &.{ 0x0F, 0x96, 0xC0 }, .asm_prefix = "setbe al" },
    .seta_al = Encoding{ .prefix = &.{ 0x0F, 0x97, 0xC0 }, .asm_prefix = "seta al" },
    .movsd_xmm0_rsp = Encoding{ .prefix = &.{ 0xF2, 0x0F, 0x10, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movsd xmm0, [rsp+", .asm_suffix = "]" },
    .movsd_rsp_xmm0 = Encoding{ .prefix = &.{ 0xF2, 0x0F, 0x11, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movsd [rsp+", .asm_suffix = "], xmm0" },
    .addsd_xmm0_rsp = Encoding{ .prefix = &.{ 0xF2, 0x0F, 0x58, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "addsd xmm0, [rsp+", .asm_suffix = "]" },
    .subsd_xmm0_rsp = Encoding{ .prefix = &.{ 0xF2, 0x0F, 0x5C, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "subsd xmm0, [rsp+", .asm_suffix = "]" },
    .mulsd_xmm0_rsp = Encoding{ .prefix = &.{ 0xF2, 0x0F, 0x59, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mulsd xmm0, [rsp+", .asm_suffix = "]" },
    .divsd_xmm0_rsp = Encoding{ .prefix = &.{ 0xF2, 0x0F, 0x5E, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "divsd xmm0, [rsp+", .asm_suffix = "]" },
    .movss_xmm0_rsp = Encoding{ .prefix = &.{ 0xF3, 0x0F, 0x10, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movss xmm0, [rsp+", .asm_suffix = "]" },
    .movss_rsp_xmm0 = Encoding{ .prefix = &.{ 0xF3, 0x0F, 0x11, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "movss [rsp+", .asm_suffix = "], xmm0" },
    .addss_xmm0_rsp = Encoding{ .prefix = &.{ 0xF3, 0x0F, 0x58, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "addss xmm0, [rsp+", .asm_suffix = "]" },
    .subss_xmm0_rsp = Encoding{ .prefix = &.{ 0xF3, 0x0F, 0x5C, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "subss xmm0, [rsp+", .asm_suffix = "]" },
    .mulss_xmm0_rsp = Encoding{ .prefix = &.{ 0xF3, 0x0F, 0x59, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mulss xmm0, [rsp+", .asm_suffix = "]" },
    .divss_xmm0_rsp = Encoding{ .prefix = &.{ 0xF3, 0x0F, 0x5E, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "divss xmm0, [rsp+", .asm_suffix = "]" },
    .ucomisd_xmm0_rsp = Encoding{ .prefix = &.{ 0x66, 0x0F, 0x2E, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "ucomisd xmm0, [rsp+", .asm_suffix = "]" },
    .ucomiss_xmm0_rsp = Encoding{ .prefix = &.{ 0x0F, 0x2E, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "ucomiss xmm0, [rsp+", .asm_suffix = "]" },
    .add_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x03, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "add rax, [rsp+", .asm_suffix = "]" },
    .sub_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x2B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "sub rax, [rsp+", .asm_suffix = "]" },
    .imul_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x0F, 0xAF, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "imul rax, [rsp+", .asm_suffix = "]" },
    .cmp_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x3B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "cmp rax, [rsp+", .asm_suffix = "]" },
    .add_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x03, 0x01 }, .asm_prefix = "add rax, [rcx]" },
    .sub_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x2B, 0x01 }, .asm_prefix = "sub rax, [rcx]" },
    .imul_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x0F, 0xAF, 0x01 }, .asm_prefix = "imul rax, [rcx]" },
    .cmp_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x3B, 0x01 }, .asm_prefix = "cmp rax, [rcx]" },
    .sub_rax = Encoding{ .prefix = &.{ 0x48, 0x2D }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xE8 } }, .asm_prefix = "sub rax, " },
    .imul_rax = Encoding{ .prefix = &.{ 0x48, 0x69, 0xC0 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x6B, 0xC0 } }, .asm_prefix = "imul rax, rax, " },
    .and_eax = Encoding{ .prefix = &.{0x25}, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xE0 } }, .asm_prefix = "and eax, " },
    .or_eax = Encoding{ .prefix = &.{0x0D}, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xC8 } }, .asm_prefix = "or eax, " },
    .xor_eax = Encoding{ .prefix = &.{0x35}, .operand = .i32, .compact = .{ .immediate = &.{ 0x83, 0xF0 } }, .asm_prefix = "xor eax, " },
    .and_eax_rsp = Encoding{ .prefix = &.{ 0x23, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "and eax, [rsp+", .asm_suffix = "]" },
    .or_eax_rsp = Encoding{ .prefix = &.{ 0x0B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "or eax, [rsp+", .asm_suffix = "]" },
    .xor_eax_rsp = Encoding{ .prefix = &.{ 0x33, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "xor eax, [rsp+", .asm_suffix = "]" },
    .and_eax_mem_rcx = Encoding{ .prefix = &.{ 0x23, 0x01 }, .asm_prefix = "and eax, [rcx]" },
    .or_eax_mem_rcx = Encoding{ .prefix = &.{ 0x0B, 0x01 }, .asm_prefix = "or eax, [rcx]" },
    .xor_eax_mem_rcx = Encoding{ .prefix = &.{ 0x33, 0x01 }, .asm_prefix = "xor eax, [rcx]" },
    .or_rax = Encoding{ .prefix = &.{ 0x48, 0x0D }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xC8 } }, .asm_prefix = "or rax, " },
    .xor_rax = Encoding{ .prefix = &.{ 0x48, 0x35 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xF0 } }, .asm_prefix = "xor rax, " },
    .and_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x23, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "and rax, [rsp+", .asm_suffix = "]" },
    .or_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x0B, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "or rax, [rsp+", .asm_suffix = "]" },
    .xor_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x33, 0x84, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "xor rax, [rsp+", .asm_suffix = "]" },
    .and_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x23, 0x01 }, .asm_prefix = "and rax, [rcx]" },
    .or_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x0B, 0x01 }, .asm_prefix = "or rax, [rcx]" },
    .xor_rax_mem_rcx = Encoding{ .prefix = &.{ 0x48, 0x33, 0x01 }, .asm_prefix = "xor rax, [rcx]" },
    .sar_rsi = Encoding{ .prefix = &.{ 0x48, 0xc1, 0xfe }, .operand = .u8, .asm_prefix = "sar rsi, " },
    .imul_rcx_wide = Encoding{ .prefix = &.{ 0x48, 0xf7, 0xe9 }, .asm_prefix = "imul rcx" },
    .neg_rax = Encoding{ .prefix = &.{ 0x48, 0xf7, 0xd8 }, .asm_prefix = "neg rax" },
    .mov_rsi_rdi = Encoding{ .prefix = &.{ 0x48, 0x89, 0xfe }, .asm_prefix = "mov rsi, rdi" },
    .add_rax_rdi = Encoding{ .prefix = &.{ 0x48, 0x01, 0xf8 }, .asm_prefix = "add rax, rdi" },
    .add_rax_rdx = Encoding{ .prefix = &.{ 0x48, 0x01, 0xd0 }, .asm_prefix = "add rax, rdx" },
    .sub_rax_rdx = Encoding{ .prefix = &.{ 0x48, 0x29, 0xd0 }, .asm_prefix = "sub rax, rdx" },
    .and_rax = Encoding{ .prefix = &.{ 0x48, 0x25 }, .operand = .i32, .compact = .{ .immediate = &.{ 0x48, 0x83, 0xe0 } }, .asm_prefix = "and rax, " },
    .shr_rax = Encoding{ .prefix = &.{ 0x48, 0xc1, 0xe8 }, .operand = .u8, .asm_prefix = "shr rax, " },
    .movzx_eax_word_rsp = Encoding{ .prefix = &.{ 0xf, 0xb7, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "movzx eax, word [rsp+", .asm_suffix = "]" },
    .movzx_eax_word_rax = Encoding{ .prefix = &.{ 0xf, 0xb7, 0x80 }, .operand = .u32, .asm_prefix = "movzx eax, word [rax+", .asm_suffix = "]" },
    .mov_rsp_ax = Encoding{ .prefix = &.{ 0x66, 0x89, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], ax" },
    .mov_rdi_ax = Encoding{ .prefix = &.{ 0x66, 0x89, 0x87 }, .operand = .u32, .asm_prefix = "mov [rdi+", .asm_suffix = "], ax" },
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
    .mov_rax_i32 = Encoding{ .prefix = &.{ 0xC7, 0x00 }, .operand = .i32, .asm_prefix = "mov dword [rax], " },
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
    .cmp_eax_ecx = Encoding{ .prefix = &.{ 0x39, 0xC8 }, .asm_prefix = "cmp eax, ecx" },
    .cmp_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x39, 0xC8 }, .asm_prefix = "cmp rax, rcx" },
    .mov_rcx_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC1 }, .asm_prefix = "mov rcx, rax" },
    .mov_rax_rax_offset = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x80 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov rax, [rax+", .asm_suffix = "]" },
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
    .mov_edi_rsp = Encoding{ .prefix = &.{ 0x8B, 0xBC, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov edi, [rsp+", .asm_suffix = "]" },
    .mov_esi_rsp = Encoding{ .prefix = &.{ 0x8B, 0xB4, 0x24 }, .operand = .u32, .compact = .displacement, .asm_prefix = "mov esi, [rsp+", .asm_suffix = "]" },
    .cmp_eax_mem_rcx = Encoding{ .prefix = &.{ 0x3B, 0x01 }, .asm_prefix = "cmp eax, [rcx]" },
    .mov_ecx_rcx = Encoding{ .prefix = &.{ 0x8B, 0x09 }, .asm_prefix = "mov ecx, [rcx]" },
    .add_eax_mem_rcx = Encoding{ .prefix = &.{ 0x03, 0x01 }, .asm_prefix = "add eax, [rcx]" },
    .sub_eax_mem_rcx = Encoding{ .prefix = &.{ 0x2B, 0x01 }, .asm_prefix = "sub eax, [rcx]" },
    .imul_eax_mem_rcx = Encoding{ .prefix = &.{ 0x0F, 0xAF, 0x01 }, .asm_prefix = "imul eax, [rcx]" },
    .sete_al = Encoding{ .prefix = &.{ 0x0F, 0x94, 0xC0 }, .asm_prefix = "sete al" },
    .setne_al = Encoding{ .prefix = &.{ 0x0F, 0x95, 0xC0 }, .asm_prefix = "setne al" },
    .setl_al = Encoding{ .prefix = &.{ 0x0F, 0x9C, 0xC0 }, .asm_prefix = "setl al" },
    .setg_al = Encoding{ .prefix = &.{ 0x0F, 0x9F, 0xC0 }, .asm_prefix = "setg al" },
    .setle_al = Encoding{ .prefix = &.{ 0x0F, 0x9E, 0xC0 }, .asm_prefix = "setle al" },
    .setge_al = Encoding{ .prefix = &.{ 0x0F, 0x9D, 0xC0 }, .asm_prefix = "setge al" },
    .movzx_eax_al = Encoding{ .prefix = &.{ 0x0F, 0xB6, 0xC0 }, .asm_prefix = "movzx eax, al" },
    .test_eax = Encoding{ .prefix = &.{ 0x85, 0xC0 }, .asm_prefix = "test eax, eax" },
    .cmove_eax_ecx = Encoding{ .prefix = &.{ 0x0F, 0x44, 0xC1 }, .asm_prefix = "cmove eax, ecx" },
    .rep_stosd = Encoding{ .prefix = &.{ 0xF3, 0xAB }, .asm_prefix = "rep stosd" },
    .std = Encoding{ .prefix = &.{0xFD}, .asm_prefix = "std" },
    .cld = Encoding{ .prefix = &.{0xFC}, .asm_prefix = "cld" },
    .rep_stosb = Encoding{ .prefix = &.{ 0xF3, 0xAA }, .asm_prefix = "rep stosb" },
    .shl_eax = Encoding{ .prefix = &.{ 0xC1, 0xE0 }, .operand = .u8, .asm_prefix = "shl eax, " },
    .sar_eax = Encoding{ .prefix = &.{ 0xC1, 0xF8 }, .operand = .u8, .asm_prefix = "sar eax, " },
    .shl_eax_cl = Encoding{ .prefix = &.{ 0xD3, 0xE0 }, .asm_prefix = "shl eax, cl" },
    .sar_eax_cl = Encoding{ .prefix = &.{ 0xD3, 0xF8 }, .asm_prefix = "sar eax, cl" },
    .mov_ecx_eax = Encoding{ .prefix = &.{ 0x89, 0xC1 }, .asm_prefix = "mov ecx, eax" },
};

pub const Operation = std.meta.FieldEnum(@TypeOf(instructions));

const stack_offset_operations = blk: {
    @setEvalBranchQuota(20000);
    var result: std.EnumSet(Operation) = .empty;
    for (std.meta.tags(Operation)) |operation| {
        if (std.mem.indexOf(u8, @field(instructions, @tagName(operation)).asm_prefix, "[rsp+") != null) result.insert(operation);
    }
    break :blk result;
};

pub fn hasStackOffset(operation: Operation) bool {
    return stack_offset_operations.contains(operation);
}

/// An instruction's full encoding plus the shorter forms selected by operand value.
const Forms = struct {
    full: Encoding,
    small: ?Encoding = null,
    zero: ?Encoding = null,

    fn of(comptime full: Encoding) Forms {
        return switch (full.compact) {
            .none => .{ .full = full },
            .displacement => .{ .full = full, .small = displacementEncoding(full, .u8), .zero = displacementEncoding(full, .none) },
            .immediate => |prefix| .{ .full = full, .small = .{ .prefix = prefix, .operand = .i8, .asm_prefix = full.asm_prefix, .asm_suffix = full.asm_suffix } },
        };
    }

    fn select(self: Forms, bits: u64) Encoding {
        switch (self.full.compact) {
            .none => {},
            .displacement => {
                if (bits == 0) return self.zero.?;
                if (bits <= std.math.maxInt(i8)) return self.small.?;
            },
            .immediate => {
                const value: i32 = @bitCast(@as(u32, @truncate(bits)));
                if ((self.full.operand == .i32 or bits <= std.math.maxInt(i8)) and std.math.cast(i8, value) != null) return self.small.?;
            },
        }
        return self.full;
    }
};

fn displacementEncoding(comptime full: Encoding, comptime operand: Operand) Encoding {
    var prefix = full.prefix[0..full.prefix.len].*;
    const modrm_index = prefix.len - @as(usize, if (prefix[prefix.len - 1] & 7 == 4) 2 else 1);
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
    var result: [std.meta.tags(Operation).len]Forms = undefined;
    for (std.meta.tags(Operation), &result) |operation, *form| form.* = .of(@field(instructions, @tagName(operation)));
    break :blk result;
};

pub const Register = enum(u4) {
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    rbx = 3,
    rbp = 5,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub fn calleeSaved(self: Register) bool {
        return switch (self) {
            .rbx, .rbp, .r12, .r13, .r14, .r15 => true,
            .r8, .r9, .r10, .r11 => false,
        };
    }

    fn low(self: Register) u8 {
        return @as(u8, @backingInt(self)) & 7;
    }

    fn extended(self: Register) bool {
        return @backingInt(self) >= 8;
    }

    fn name32(self: Register) []const u8 {
        return switch (self) {
            .rbx => "ebx",
            .rbp => "ebp",
            inline else => |register| @tagName(register) ++ "d",
        };
    }
};

pub const RegisterSet = std.enums.EnumSet(Register);

pub fn fixedRegisters(operation: Operation) RegisterSet {
    return switch (operation) {
        .mov_r12_rsp, .add_r12_8, .add_r12_rax => .initOne(.r12),
        .mov_r13_r12 => .initMany(&.{ .r12, .r13 }),
        .cmp_rax_r13 => .initOne(.r13),
        .mov_r14, .mov_rax_r14, .add_r14_32, .mov_rax_r14_offset, .mov_rsi_r14_offset, .mov_edx_r14_offset => .initOne(.r14),
        .mov_r15d, .dec_r15d => .initOne(.r15),
        .mov_r8d => .initOne(.r8),
        .zero_r9d => .initOne(.r9),
        .mov_r10d => .initOne(.r10),
        .syscall => .initOne(.r11),
        else => .empty,
    };
}

pub fn clobberedRegisters(operation: Operation) RegisterSet {
    return switch (operation) {
        .call_relative, .call_rax => .initMany(&.{ .r8, .r9, .r10, .r11 }),
        .syscall => .initOne(.r11),
        else => .empty,
    };
}

pub const RegisterOperation = enum { load_byte, store_byte, load_eax, store_eax, load_rax, store_rax, store_indexed_i32, add_eax, sub_eax, imul_eax, cmp_eax, add_rax, sub_rax, imul_rax, cmp_rax, and_eax, or_eax, xor_eax, and_rax, or_rax, xor_rax, load_ecx, sign_extend_rcx, add_immediate, sub_immediate, imul_immediate, cmp_immediate, load_stack_byte, load_stack, load_stack_64, add_stack, sub_stack, imul_stack, cmp_stack, save, restore };

/// REX prefix with the given W/R/X/B bits, omitted when no bit is set.
fn rex(comptime bits: u8) []const u8 {
    return if (bits == 0) &.{} else &.{0x40 | bits};
}

fn rexBit(register: ?Register, bit: u8) u8 {
    const selected = register orelse return 0;
    return if (selected.extended()) bit else 0;
}

fn immediateEncoding(comptime prefix: []const u8, comptime opcodes: [2]u8, comptime modrm: u8, comptime asm_prefix: []const u8) Encoding {
    return .{ .prefix = prefix ++ &[_]u8{ opcodes[0], modrm }, .operand = .i32, .compact = .{ .immediate = prefix ++ &[_]u8{ opcodes[1], modrm } }, .asm_prefix = asm_prefix };
}

fn stackEncoding(comptime prefix: []const u8, comptime asm_prefix: []const u8, comptime asm_suffix: []const u8) Encoding {
    return .{ .prefix = prefix, .operand = .u32, .compact = .displacement, .asm_prefix = asm_prefix, .asm_suffix = asm_suffix };
}

fn registerEncoding(comptime operation: RegisterOperation, comptime register: Register) Encoding {
    const r = register.low();
    const reg = rexBit(register, 4);
    const base = rexBit(register, 1);
    const name = register.name32();
    const stack = [_]u8{ 0x84 | (r << 3), 0x24 };
    return switch (operation) {
        .load_byte, .load_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x89, 0xC0 | (r << 3) }, .asm_prefix = "mov eax, " ++ name },
        .store_byte, .store_eax => .{ .prefix = rex(base) ++ &[_]u8{ 0x89, 0xC0 | r }, .asm_prefix = "mov " ++ name ++ ", eax" },
        .load_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x89, 0xC0 | (r << 3) }, .asm_prefix = "mov rax, " ++ @tagName(register) },
        .store_rax => .{ .prefix = rex(8 | base) ++ &[_]u8{ 0x89, 0xC0 | r }, .asm_prefix = "mov " ++ @tagName(register) ++ ", rax" },
        .store_indexed_i32 => .{
            .prefix = rex(base) ++ &[_]u8{ 0xC7, if (r == 5) 0x44 else 0x04, 0x88 | r } ++ (if (r == 5) &[_]u8{0} else &[_]u8{}),
            .operand = .i32,
            .asm_prefix = "mov dword [" ++ @tagName(register) ++ "+rcx*4], ",
        },
        .add_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x01, 0xC0 | (r << 3) }, .asm_prefix = "add eax, " ++ name },
        .sub_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x29, 0xC0 | (r << 3) }, .asm_prefix = "sub eax, " ++ name },
        .imul_eax => .{ .prefix = rex(base) ++ &[_]u8{ 0x0F, 0xAF, 0xC0 | r }, .asm_prefix = "imul eax, " ++ name },
        .cmp_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x39, 0xC0 | (r << 3) }, .asm_prefix = "cmp eax, " ++ name },
        .and_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x21, 0xC0 | (r << 3) }, .asm_prefix = "and rax, " ++ @tagName(register) },
        .or_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x09, 0xC0 | (r << 3) }, .asm_prefix = "or rax, " ++ @tagName(register) },
        .xor_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x31, 0xC0 | (r << 3) }, .asm_prefix = "xor rax, " ++ @tagName(register) },
        .and_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x21, 0xC0 | (r << 3) }, .asm_prefix = "and eax, " ++ name },
        .or_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x09, 0xC0 | (r << 3) }, .asm_prefix = "or eax, " ++ name },
        .xor_eax => .{ .prefix = rex(reg) ++ &[_]u8{ 0x31, 0xC0 | (r << 3) }, .asm_prefix = "xor eax, " ++ name },
        .add_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x01, 0xC0 | (r << 3) }, .asm_prefix = "add rax, " ++ @tagName(register) },
        .sub_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x29, 0xC0 | (r << 3) }, .asm_prefix = "sub rax, " ++ @tagName(register) },
        .imul_rax => .{ .prefix = rex(8 | base) ++ &[_]u8{ 0x0F, 0xAF, 0xC0 | r }, .asm_prefix = "imul rax, " ++ @tagName(register) },
        .cmp_rax => .{ .prefix = rex(8 | reg) ++ &[_]u8{ 0x39, 0xC0 | (r << 3) }, .asm_prefix = "cmp rax, " ++ @tagName(register) },
        .load_ecx => .{ .prefix = rex(reg) ++ &[_]u8{ 0x89, 0xC1 | (r << 3) }, .asm_prefix = "mov ecx, " ++ name },
        .sign_extend_rcx => .{ .prefix = rex(8 | base) ++ &[_]u8{ 0x63, 0xC8 | r }, .asm_prefix = "movsxd rcx, " ++ name },
        .add_immediate => immediateEncoding(rex(base), .{ 0x81, 0x83 }, 0xC0 | r, "add " ++ name ++ ", "),
        .sub_immediate => immediateEncoding(rex(base), .{ 0x81, 0x83 }, 0xE8 | r, "sub " ++ name ++ ", "),
        .imul_immediate => immediateEncoding(rex(reg | base), .{ 0x69, 0x6B }, 0xC0 | (r << 3) | r, "imul " ++ name ++ ", " ++ name ++ ", "),
        .cmp_immediate => immediateEncoding(rex(base), .{ 0x81, 0x83 }, 0xF8 | r, "cmp " ++ name ++ ", "),
        .load_stack_byte => stackEncoding(rex(reg) ++ &[_]u8{ 0x0F, 0xB6 } ++ stack, "movzx " ++ name ++ ", byte [rsp+", "]"),
        .load_stack => stackEncoding(rex(reg) ++ &[_]u8{0x8B} ++ stack, "mov " ++ name ++ ", [rsp+", "]"),
        .load_stack_64 => stackEncoding(rex(8 | reg) ++ &[_]u8{0x8B} ++ stack, "mov " ++ @tagName(register) ++ ", [rsp+", "]"),
        .add_stack => stackEncoding(rex(reg) ++ &[_]u8{0x03} ++ stack, "add " ++ name ++ ", [rsp+", "]"),
        .sub_stack => stackEncoding(rex(reg) ++ &[_]u8{0x2B} ++ stack, "sub " ++ name ++ ", [rsp+", "]"),
        .imul_stack => stackEncoding(rex(reg) ++ &[_]u8{ 0x0F, 0xAF } ++ stack, "imul " ++ name ++ ", [rsp+", "]"),
        .cmp_stack => stackEncoding(rex(reg) ++ &[_]u8{0x3B} ++ stack, "cmp " ++ name ++ ", [rsp+", "]"),
        .save => stackEncoding(rex(8 | reg) ++ &[_]u8{0x89} ++ stack, "mov [rsp+", "], " ++ @tagName(register)),
        .restore => stackEncoding(rex(8 | reg) ++ &[_]u8{0x8B} ++ stack, "mov " ++ @tagName(register) ++ ", [rsp+", "]"),
    };
}

const register_count = std.enums.values(Register).len;

/// Table index of a register; the index past the last register stands for no register.
fn registerIndex(register: ?Register) usize {
    const selected = register orelse return register_count;
    return std.mem.indexOfScalar(Register, std.enums.values(Register), selected).?;
}

fn tableRegister(index: usize) ?Register {
    return if (index < register_count) std.enums.values(Register)[index] else null;
}

const register_forms = blk: {
    @setEvalBranchQuota(20000);
    var result: [std.enums.values(RegisterOperation).len][register_count]Forms = undefined;
    for (std.enums.values(RegisterOperation), &result) |operation, *row| for (std.enums.values(Register), row) |register, *form| {
        form.* = .of(registerEncoding(operation, register));
    };
    break :blk result;
};

pub fn appendRegister(code: *std.ArrayList(u8), allocator: std.mem.Allocator, operation: RegisterOperation, register: Register, bits: u64) !void {
    try appendPattern(code, allocator, register_forms[@backingInt(operation)][registerIndex(register)].select(bits), bits);
}

const binary_operations = [_]RegisterOperation{ .add_eax, .sub_eax, .imul_eax, .cmp_eax, .store_eax, .store_rax };

fn binaryEncoding(comptime operation: RegisterOperation, comptime destination: Register, comptime source: Register) Encoding {
    const selected: struct { opcode: []const u8, name: []const u8 } = switch (operation) {
        .add_eax => .{ .opcode = &.{0x03}, .name = "add " },
        .sub_eax => .{ .opcode = &.{0x2B}, .name = "sub " },
        .imul_eax => .{ .opcode = &.{ 0x0F, 0xAF }, .name = "imul " },
        .cmp_eax => .{ .opcode = &.{0x3B}, .name = "cmp " },
        .store_eax => .{ .opcode = &.{0x8B}, .name = "mov " },
        .store_rax => .{ .opcode = &.{0x8B}, .name = "mov " },
        else => unreachable,
    };
    return .{
        .prefix = rex((if (operation == .store_rax) @as(u8, 8) else 0) | rexBit(destination, 4) | rexBit(source, 1)) ++ selected.opcode ++ &[_]u8{0xC0 | (destination.low() << 3) | source.low()},
        .asm_prefix = selected.name ++ (if (operation == .store_rax) @tagName(destination) else destination.name32()) ++ ", " ++ (if (operation == .store_rax) @tagName(source) else source.name32()),
    };
}

const binary_register_patterns = blk: {
    @setEvalBranchQuota(20000);
    var result: [binary_operations.len][register_count][register_count]Encoding = undefined;
    for (binary_operations, &result) |operation, *rows| for (std.enums.values(Register), rows) |destination, *row| for (std.enums.values(Register), row) |source, *pattern| {
        pattern.* = binaryEncoding(operation, destination, source);
    };
    break :blk result;
};

pub fn appendRegisterBinary(code: *std.ArrayList(u8), allocator: std.mem.Allocator, operation: RegisterOperation, destination: Register, source: Register) !void {
    const operation_index = std.mem.indexOfScalar(RegisterOperation, &binary_operations, operation) orelse unreachable;
    try appendPattern(code, allocator, binary_register_patterns[operation_index][registerIndex(destination)][registerIndex(source)], 0);
}

fn indexedLoadEncoding(comptime byte: bool, comptime base: ?Register, comptime destination: ?Register, comptime index: ?Register) Encoding {
    const base_low = if (base) |selected| selected.low() else 4;
    const destination_low = if (destination) |selected| selected.low() else 0;
    const mode: u8 = if (base == null) 0x80 else if (base_low == 5) 0x40 else 0;
    return .{
        .prefix = rex(rexBit(destination, 4) | rexBit(index, 2) | rexBit(base, 1)) ++
            (if (byte) &[_]u8{ 0x0f, 0xb6 } else &[_]u8{0x8b}) ++
            &[_]u8{ mode | (destination_low << 3) | 4, (if (byte) @as(u8, 0) else 0x80) | ((if (index) |selected| selected.low() else 1) << 3) | base_low } ++
            (if (base != null and base_low == 5) &[_]u8{0} else &[_]u8{}),
        .operand = if (base == null) .u32 else .none,
        .compact = if (base == null) .displacement else .none,
        .asm_prefix = (if (byte) "movzx " else "mov ") ++ (if (destination) |selected| selected.name32() else "eax") ++
            (if (byte) ", byte [" else ", [") ++ (if (base) |selected| @tagName(selected) else "rsp") ++
            "+" ++ (if (index) |selected| @tagName(selected) else "rcx") ++ (if (byte) "" else "*4") ++ (if (base == null) "+" else "]"),
        .asm_suffix = if (base == null) "]" else "",
    };
}

const indexed_load_forms = blk: {
    @setEvalBranchQuota(500000);
    var result: [2][register_count + 1][register_count + 1][register_count + 1]Forms = undefined;
    for (&result, 0..) |*bases, width| for (bases, 0..) |*destinations, base| for (destinations, 0..) |*indices, destination| for (indices, 0..) |*form, index| {
        form.* = .of(indexedLoadEncoding(width == 1, tableRegister(base), tableRegister(destination), tableRegister(index)));
    };
    break :blk result;
};

pub fn appendIndexedLoad(code: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: bool, base: ?Register, destination: ?Register, index: ?Register, offset: u64) !void {
    const form = indexed_load_forms[@intFromBool(byte)][registerIndex(base)][registerIndex(destination)][registerIndex(index)];
    try appendPattern(code, allocator, form.select(offset), offset);
}

fn indexedStoreEncoding(comptime base: ?Register, comptime source: ?Register) Encoding {
    const base_low = if (base) |selected| selected.low() else 4;
    const source_low = if (source) |selected| selected.low() else 0;
    const mode: u8 = if (base == null) 0x80 else if (base_low == 5) 0x40 else 0;
    return .{
        .prefix = rex(rexBit(source, 4) | rexBit(base, 1)) ++ &[_]u8{
            0x89, mode | (source_low << 3) | 4, 0x88 | base_low,
        } ++ (if (base != null and base_low == 5) &[_]u8{0} else &[_]u8{}),
        .operand = if (base == null) .u32 else .none,
        .compact = if (base == null) .displacement else .none,
        .asm_prefix = "mov [" ++ (if (base) |selected| @tagName(selected) else "rsp") ++ "+rcx*4" ++ (if (base == null) "+" else "], "),
        .asm_suffix = (if (base == null) "], " else "") ++ (if (source) |selected| selected.name32() else "eax"),
    };
}

const indexed_store_forms = blk: {
    @setEvalBranchQuota(30000);
    var result: [register_count + 1][register_count + 1]Forms = undefined;
    for (&result, 0..) |*sources, base| for (sources, 0..) |*form, source| {
        form.* = .of(indexedStoreEncoding(tableRegister(base), tableRegister(source)));
    };
    break :blk result;
};

pub fn appendIndexedStore(code: *std.ArrayList(u8), allocator: std.mem.Allocator, base: ?Register, source: ?Register, offset: u64) !void {
    try appendPattern(code, allocator, indexed_store_forms[registerIndex(base)][registerIndex(source)].select(offset), offset);
}

fn flatten(comptime T: type, comptime table: anytype) []const T {
    return @as([*]const T, @ptrCast(table))[0 .. @sizeOf(@TypeOf(table.*)) / @sizeOf(T)];
}

/// Each form's encodings in order full, small, zero.
fn formPatterns(comptime table: []const Forms) []const Encoding {
    @setEvalBranchQuota(500000);
    var result: [3 * table.len]Encoding = undefined;
    var count: usize = 0;
    for (table) |form| for ([_]?Encoding{ form.full, form.small, form.zero }) |maybe_pattern| if (maybe_pattern) |pattern| {
        result[count] = pattern;
        count += 1;
    };
    const used = result[0..count].*;
    return &used;
}

/// Every encodable form.
pub const patterns = formPatterns(&forms) ++ formPatterns(flatten(Forms, &register_forms)) ++
    flatten(Encoding, &binary_register_patterns) ++ formPatterns(flatten(Forms, &indexed_load_forms)) ++
    formPatterns(flatten(Forms, &indexed_store_forms));

pub fn encoding(operation: Operation) Encoding {
    return forms[@backingInt(operation)].full;
}

pub fn selectedEncoding(operation: Operation, bits: u64) Encoding {
    return forms[@backingInt(operation)].select(bits);
}

pub fn append(code: *std.ArrayList(u8), allocator: std.mem.Allocator, operation: Operation, bits: u64) !void {
    try appendPattern(code, allocator, selectedEncoding(operation, bits), bits);
}

pub fn appendPattern(code: *std.ArrayList(u8), allocator: std.mem.Allocator, pattern: Encoding, bits: u64) !void {
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
