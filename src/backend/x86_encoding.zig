const std = @import("std");

pub const Operand = enum { none, i32, u32, u64, rel };

pub const Encoding = struct {
    prefix: []const u8,
    operand: Operand = .none,
    asm_prefix: []const u8,
    asm_suffix: []const u8 = "",

    pub fn length(self: Encoding) usize {
        return self.prefix.len + @as(usize, switch (self.operand) {
            .none => 0,
            .i32, .u32, .rel => 4,
            .u64 => 8,
        });
    }
};

const instructions = .{
    .lea_rax_rip = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x05 }, .operand = .rel, .asm_prefix = "lea rax, [rip+", .asm_suffix = "]" },
    .mov_rax_rdi = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x87 }, .operand = .u32, .asm_prefix = "mov rax, [rdi+", .asm_suffix = "]" },
    .ret = Encoding{ .prefix = &.{0xC3}, .asm_prefix = "ret" },
    .ud2 = Encoding{ .prefix = &.{ 0x0F, 0x0B }, .asm_prefix = "ud2" },
    .zero_edi = Encoding{ .prefix = &.{ 0x31, 0xFF }, .asm_prefix = "xor edi, edi" },
    .cdq = Encoding{ .prefix = &.{0x99}, .asm_prefix = "cdq" },
    .idiv_ecx = Encoding{ .prefix = &.{ 0xF7, 0xF9 }, .asm_prefix = "idiv ecx" },
    .neg_eax = Encoding{ .prefix = &.{ 0xF7, 0xD8 }, .asm_prefix = "neg eax" },
    .call_rax = Encoding{ .prefix = &.{ 0xFF, 0xD0 }, .asm_prefix = "call rax" },
    .mov_edi_eax = Encoding{ .prefix = &.{ 0x89, 0xC7 }, .asm_prefix = "mov edi, eax" },
    .syscall = Encoding{ .prefix = &.{ 0x0F, 0x05 }, .asm_prefix = "syscall" },
    .mov_eax_rsp = Encoding{ .prefix = &.{ 0x8B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov eax, [rsp+", .asm_suffix = "]" },
    .mov_rsp_eax = Encoding{ .prefix = &.{ 0x89, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], eax" },
    .add_eax_rsp = Encoding{ .prefix = &.{ 0x03, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "add eax, [rsp+", .asm_suffix = "]" },
    .sub_eax_rsp = Encoding{ .prefix = &.{ 0x2B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "sub eax, [rsp+", .asm_suffix = "]" },
    .idiv_rsp = Encoding{ .prefix = &.{ 0xF7, 0xBC, 0x24 }, .operand = .u32, .asm_prefix = "idiv dword [rsp+", .asm_suffix = "]" },
    .imul_eax_rsp = Encoding{ .prefix = &.{ 0x0F, 0xAF, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "imul eax, [rsp+", .asm_suffix = "]" },
    .mov_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov rax, [rsp+", .asm_suffix = "]" },
    .mov_rsp_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], rax" },
    .mov_eax = Encoding{ .prefix = &.{0xB8}, .operand = .i32, .asm_prefix = "mov eax, " },
    .mov_ecx = Encoding{ .prefix = &.{0xB9}, .operand = .i32, .asm_prefix = "mov ecx, " },
    .mov_edx = Encoding{ .prefix = &.{0xBA}, .operand = .i32, .asm_prefix = "mov edx, " },
    .mov_rax = Encoding{ .prefix = &.{ 0x48, 0xB8 }, .operand = .u64, .asm_prefix = "mov rax, " },
    .imul_eax = Encoding{ .prefix = &.{ 0x69, 0xC0 }, .operand = .i32, .asm_prefix = "imul eax, eax, " },
    .sub_eax = Encoding{ .prefix = &.{0x2D}, .operand = .i32, .asm_prefix = "sub eax, " },
    .add_eax = Encoding{ .prefix = &.{0x05}, .operand = .i32, .asm_prefix = "add eax, " },
    .cmp_eax = Encoding{ .prefix = &.{0x3D}, .operand = .i32, .asm_prefix = "cmp eax, " },
    .sub_rsp = Encoding{ .prefix = &.{ 0x48, 0x81, 0xEC }, .operand = .u32, .asm_prefix = "sub rsp, " },
    .add_rsp = Encoding{ .prefix = &.{ 0x48, 0x81, 0xC4 }, .operand = .u32, .asm_prefix = "add rsp, " },
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
    .cmp_edx = Encoding{ .prefix = &.{ 0x81, 0xFA }, .operand = .i32, .asm_prefix = "cmp edx, " },
    .cmp_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x39, 0xC8 }, .asm_prefix = "cmp rax, rcx" },
    .mov_rcx_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC1 }, .asm_prefix = "mov rcx, rax" },
    .mov_rax_rax_offset = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x80 }, .operand = .u32, .asm_prefix = "mov rax, [rax+", .asm_suffix = "]" },
    .mov_rax_rcx_offset = Encoding{ .prefix = &.{ 0x48, 0x89, 0x88 }, .operand = .u32, .asm_prefix = "mov [rax+", .asm_suffix = "], rcx" },
    .cmp_eax_rsp = Encoding{ .prefix = &.{ 0x3B, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "cmp eax, [rsp+", .asm_suffix = "]" },
    .movzx_eax_rsp = Encoding{ .prefix = &.{ 0x0F, 0xB6, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "movzx eax, byte [rsp+", .asm_suffix = "]" },
    .mov_rsp_al = Encoding{ .prefix = &.{ 0x88, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "mov [rsp+", .asm_suffix = "], al" },
    .mov_esi = Encoding{ .prefix = &.{0xBE}, .operand = .i32, .asm_prefix = "mov esi, " },
    .mov_r10d = Encoding{ .prefix = &.{ 0x41, 0xBA }, .operand = .i32, .asm_prefix = "mov r10d, " },
    .imul_rsi = Encoding{ .prefix = &.{ 0x48, 0x69, 0xF6 }, .operand = .i32, .asm_prefix = "imul rsi, rsi, " },
    .cmp_rsi = Encoding{ .prefix = &.{ 0x48, 0x81, 0xFE }, .operand = .i32, .asm_prefix = "cmp rsi, " },
    .ja = Encoding{ .prefix = &.{ 0x0F, 0x87 }, .operand = .rel, .asm_prefix = "ja " },
    .jae = Encoding{ .prefix = &.{ 0x0F, 0x83 }, .operand = .rel, .asm_prefix = "jae " },
    .mov_eax_esi = Encoding{ .prefix = &.{ 0x89, 0xF0 }, .asm_prefix = "mov eax, esi" },
    .mov_esi_eax = Encoding{ .prefix = &.{ 0x89, 0xC6 }, .asm_prefix = "mov esi, eax" },
    .movsxd_rcx_rsp = Encoding{ .prefix = &.{ 0x48, 0x63, 0x8C, 0x24 }, .operand = .u32, .asm_prefix = "movsxd rcx, [rsp+", .asm_suffix = "]" },
    .movsxd_rcx_eax = Encoding{ .prefix = &.{ 0x48, 0x63, 0xC8 }, .asm_prefix = "movsxd rcx, eax" },
    .mov_rcx_rsp = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x8C, 0x24 }, .operand = .u32, .asm_prefix = "mov rcx, [rsp+", .asm_suffix = "]" },
    .imul_rcx = Encoding{ .prefix = &.{ 0x48, 0x69, 0xC9 }, .operand = .i32, .asm_prefix = "imul rcx, rcx, " },
    .add_rax_rcx = Encoding{ .prefix = &.{ 0x48, 0x01, 0xC8 }, .asm_prefix = "add rax, rcx" },
    .add_rax = Encoding{ .prefix = &.{ 0x48, 0x05 }, .operand = .i32, .asm_prefix = "add rax, " },
    .mov_rdi_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC7 }, .asm_prefix = "mov rdi, rax" },
    .mov_rdi_eax = Encoding{ .prefix = &.{ 0x89, 0x87 }, .operand = .u32, .asm_prefix = "mov [rdi+", .asm_suffix = "], eax" },
    .mov_rdi_al = Encoding{ .prefix = &.{ 0x88, 0x87 }, .operand = .u32, .asm_prefix = "mov [rdi+", .asm_suffix = "], al" },
    .mov_rdi_rsp = Encoding{ .prefix = &.{ 0x48, 0x8B, 0xBC, 0x24 }, .operand = .u32, .asm_prefix = "mov rdi, [rsp+", .asm_suffix = "]" },
    .mov_rsi_rax = Encoding{ .prefix = &.{ 0x48, 0x89, 0xC6 }, .asm_prefix = "mov rsi, rax" },
    .lea_rsi_rsp = Encoding{ .prefix = &.{ 0x48, 0x8D, 0xB4, 0x24 }, .operand = .u32, .asm_prefix = "lea rsi, [rsp+", .asm_suffix = "]" },
    .lea_rax_rsp = Encoding{ .prefix = &.{ 0x48, 0x8D, 0x84, 0x24 }, .operand = .u32, .asm_prefix = "lea rax, [rsp+", .asm_suffix = "]" },
    .mov_eax_rax = Encoding{ .prefix = &.{ 0x8B, 0x80 }, .operand = .u32, .asm_prefix = "mov eax, [rax+", .asm_suffix = "]" },
    .mov_rax_rax = Encoding{ .prefix = &.{ 0x48, 0x8B, 0x00 }, .asm_prefix = "mov rax, [rax]" },
    .movzx_eax_rax = Encoding{ .prefix = &.{ 0x0F, 0xB6, 0x80 }, .operand = .u32, .asm_prefix = "movzx eax, byte [rax+", .asm_suffix = "]" },
    .lea_rdi_rsp = Encoding{ .prefix = &.{ 0x48, 0x8D, 0xBC, 0x24 }, .operand = .u32, .asm_prefix = "lea rdi, [rsp+", .asm_suffix = "]" },
    .mov_eax_rsi = Encoding{ .prefix = &.{ 0x8B, 0x06 }, .asm_prefix = "mov eax, [rsi]" },
    .rep_movsb = Encoding{ .prefix = &.{ 0xF3, 0xA4 }, .asm_prefix = "rep movsb" },
    .mov_r8d = Encoding{ .prefix = &.{ 0x41, 0xB8 }, .operand = .i32, .asm_prefix = "mov r8d, " },
    .zero_r9d = Encoding{ .prefix = &.{ 0x45, 0x31, 0xC9 }, .asm_prefix = "xor r9d, r9d" },
    .zero_edx = Encoding{ .prefix = &.{ 0x31, 0xD2 }, .asm_prefix = "xor edx, edx" },
    .test_esi = Encoding{ .prefix = &.{ 0x85, 0xF6 }, .asm_prefix = "test esi, esi" },
    .cmp_rax = Encoding{ .prefix = &.{ 0x48, 0x3D }, .operand = .i32, .asm_prefix = "cmp rax, " },
    .shr_rax_32 = Encoding{ .prefix = &.{ 0x48, 0xC1, 0xE8, 32 }, .asm_prefix = "shr rax, 32" },
    .shl_rsi_32 = Encoding{ .prefix = &.{ 0x48, 0xC1, 0xE6, 32 }, .asm_prefix = "shl rsi, 32" },
    .or_rdi_rsi = Encoding{ .prefix = &.{ 0x48, 0x09, 0xF7 }, .asm_prefix = "or rdi, rsi" },
    .mov_edi_rsp = Encoding{ .prefix = &.{ 0x8B, 0xBC, 0x24 }, .operand = .u32, .asm_prefix = "mov edi, [rsp+", .asm_suffix = "]" },
    .mov_esi_rsp = Encoding{ .prefix = &.{ 0x8B, 0xB4, 0x24 }, .operand = .u32, .asm_prefix = "mov esi, [rsp+", .asm_suffix = "]" },
    .cmp_eax_rcx = Encoding{ .prefix = &.{ 0x3B, 0x01 }, .asm_prefix = "cmp eax, [rcx]" },
    .idiv_rcx = Encoding{ .prefix = &.{ 0xF7, 0x39 }, .asm_prefix = "idiv dword [rcx]" },
    .add_eax_rcx = Encoding{ .prefix = &.{ 0x03, 0x01 }, .asm_prefix = "add eax, [rcx]" },
    .sub_eax_rcx = Encoding{ .prefix = &.{ 0x2B, 0x01 }, .asm_prefix = "sub eax, [rcx]" },
    .imul_eax_rcx = Encoding{ .prefix = &.{ 0x0F, 0xAF, 0x01 }, .asm_prefix = "imul eax, [rcx]" },
};

pub const Operation = std.meta.FieldEnum(@TypeOf(instructions));
pub const patterns = blk: {
    const field_names = @typeInfo(@TypeOf(instructions)).@"struct".field_names;
    var result: [field_names.len]Encoding = undefined;
    for (field_names, 0..) |field_name, index| result[index] = @field(instructions, field_name);
    break :blk result;
};

pub fn encoding(operation: Operation) Encoding {
    return patterns[@backingInt(operation)];
}

pub fn append(code: *std.ArrayList(u8), allocator: std.mem.Allocator, operation: Operation, bits: u64) !void {
    const pattern = encoding(operation);
    try code.appendSlice(allocator, pattern.prefix);
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, bits, .little);
    try code.appendSlice(allocator, encoded[0 .. pattern.length() - pattern.prefix.len]);
}
