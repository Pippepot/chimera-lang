const std = @import("std");

const max_helper_size = 384;

pub const HelperBlob = struct {
    bytes: [max_helper_size]u8,
    len: usize,

    pub fn slice(self: *const @This()) []const u8 {
        return self.bytes[0..self.len];
    }
};

const HelperBuffer = struct {
    bytes: [max_helper_size]u8 = [_]u8{0} ** max_helper_size,
    len: usize = 0,

    fn appendSlice(self: *@This(), slice: []const u8) void {
        if (self.len + slice.len > self.bytes.len) @compileError("helper blob exceeds max_helper_size");
        for (slice) |byte| {
            self.bytes[self.len] = byte;
            self.len += 1;
        }
    }

    fn appendRel32Placeholder(self: *@This()) usize {
        const pos = self.len;
        self.appendSlice(&.{ 0, 0, 0, 0 });
        return pos;
    }
};

fn patchRel32(buf: *HelperBuffer, disp_pos: usize, target_pos: usize) void {
    const rel_i64 = @as(i64, @intCast(target_pos)) - (@as(i64, @intCast(disp_pos)) + 4);
    if (rel_i64 < std.math.minInt(i32) or rel_i64 > std.math.maxInt(i32)) {
        @compileError("helper rel32 out of range");
    }
    const rel_i32: i32 = @intCast(rel_i64);
    std.mem.writeInt(i32, buf.bytes[disp_pos..][0..4], rel_i32, .little);
}

fn buildPrintIntBlob() HelperBlob {
    var buf = HelperBuffer{};

    buf.appendSlice(&.{
        0x50, // push rax
        0x53, // push rbx
        0x51, // push rcx
        0x52, // push rdx
        0x57, // push rdi
        0x56, // push rsi
    });

    buf.appendSlice(&.{ 0xBB, 0x0A, 0x00, 0x00, 0x00 }); // mov ebx, 10
    buf.appendSlice(&.{ 0x48, 0x83, 0xEC, 0x20 }); // sub rsp, 32
    buf.appendSlice(&.{ 0xC6, 0x04, 0x24, 0x00 }); // mov byte [rsp], 0
    buf.appendSlice(&.{ 0x48, 0x8D, 0x7C, 0x24, 0x1F }); // lea rdi, [rsp+31]
    buf.appendSlice(&.{ 0xC6, 0x07, 0x0A }); // mov byte [rdi], 10
    buf.appendSlice(&.{ 0x48, 0xFF, 0xCF }); // dec rdi
    buf.appendSlice(&.{ 0x83, 0xF8, 0x00 }); // cmp eax, 0

    buf.appendSlice(&.{ 0x0F, 0x8D }); // jge .loop
    const jge_loop_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0xF7, 0xD8 }); // neg eax
    buf.appendSlice(&.{ 0xC6, 0x04, 0x24, 0x01 }); // mov byte [rsp], 1

    const loop_pos = buf.len;

    buf.appendSlice(&.{ 0x31, 0xD2 }); // xor edx, edx
    buf.appendSlice(&.{ 0xF7, 0xF3 }); // div ebx
    buf.appendSlice(&.{ 0x80, 0xC2, '0' }); // add dl, '0'
    buf.appendSlice(&.{ 0x88, 0x17 }); // mov [rdi], dl
    buf.appendSlice(&.{ 0x48, 0xFF, 0xCF }); // dec rdi
    buf.appendSlice(&.{ 0x85, 0xC0 }); // test eax, eax

    buf.appendSlice(&.{ 0x0F, 0x85 }); // jnz .loop
    const jnz_loop_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0x80, 0x3C, 0x24, 0x01 }); // cmp byte [rsp], 1
    buf.appendSlice(&.{ 0x0F, 0x85 }); // jne .write
    const jne_write_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0xC6, 0x07, '-' }); // mov byte [rdi], '-'
    buf.appendSlice(&.{ 0x48, 0xFF, 0xCF }); // dec rdi

    const write_pos = buf.len;

    buf.appendSlice(&.{ 0x48, 0x8D, 0x77, 0x01 }); // lea rsi, [rdi+1]
    buf.appendSlice(&.{ 0x48, 0x89, 0xE2 }); // mov rdx, rsp
    buf.appendSlice(&.{ 0x48, 0x83, 0xC2, 0x20 }); // add rdx, 32
    buf.appendSlice(&.{ 0x48, 0x29, 0xF2 }); // sub rdx, rsi
    buf.appendSlice(&.{ 0xBF, 0x01, 0x00, 0x00, 0x00 }); // mov edi, 1
    buf.appendSlice(&.{ 0xB8, 0x01, 0x00, 0x00, 0x00 }); // mov eax, 1
    buf.appendSlice(&.{ 0x0F, 0x05 }); // syscall
    buf.appendSlice(&.{ 0x48, 0x83, 0xC4, 0x20 }); // add rsp, 32

    buf.appendSlice(&.{
        0x5E, // pop rsi
        0x5F, // pop rdi
        0x5A, // pop rdx
        0x59, // pop rcx
        0x5B, // pop rbx
        0x58, // pop rax
        0xC3, // ret
    });

    patchRel32(&buf, jge_loop_disp, loop_pos);
    patchRel32(&buf, jnz_loop_disp, loop_pos);
    patchRel32(&buf, jne_write_disp, write_pos);

    return .{ .bytes = buf.bytes, .len = buf.len };
}

fn buildAtoiBlob() HelperBlob {
    var buf = HelperBuffer{};

    buf.appendSlice(&.{
        0x51, // push rcx
        0x31, 0xC0, // xor eax, eax
        0x31, 0xC9, // xor ecx, ecx
        0x80, 0x3F, '-', // cmp byte [rdi], '-'
    });

    buf.appendSlice(&.{ 0x0F, 0x85 }); // jne .loop
    const jne_loop_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0xB1, 0x01 }); // mov cl, 1
    buf.appendSlice(&.{ 0x48, 0xFF, 0xC7 }); // inc rdi

    const loop_pos = buf.len;

    buf.appendSlice(&.{ 0x0F, 0xB6, 0x17 }); // movzx edx, byte [rdi]
    buf.appendSlice(&.{ 0x84, 0xD2 }); // test dl, dl

    buf.appendSlice(&.{ 0x0F, 0x84 }); // jz .done
    const jz_done_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0x83, 0xEA, '0' }); // sub edx, '0'
    buf.appendSlice(&.{ 0x83, 0xFA, 0x09 }); // cmp edx, 9

    buf.appendSlice(&.{ 0x0F, 0x87 }); // ja .done
    const ja_done_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0x6B, 0xC0, 0x0A }); // imul eax, 10
    buf.appendSlice(&.{ 0x01, 0xD0 }); // add eax, edx
    buf.appendSlice(&.{ 0x48, 0xFF, 0xC7 }); // inc rdi

    buf.appendSlice(&.{0xE9}); // jmp .loop
    const jmp_loop_disp = buf.appendRel32Placeholder();

    const done_pos = buf.len;

    buf.appendSlice(&.{ 0x85, 0xC9 }); // test ecx, ecx

    buf.appendSlice(&.{ 0x0F, 0x84 }); // jz .ret
    const jz_ret_disp = buf.appendRel32Placeholder();

    buf.appendSlice(&.{ 0xF7, 0xD8 }); // neg eax

    const ret_pos = buf.len;

    buf.appendSlice(&.{
        0x59, // pop rcx
        0xC3, // ret
    });

    patchRel32(&buf, jne_loop_disp, loop_pos);
    patchRel32(&buf, jz_done_disp, done_pos);
    patchRel32(&buf, ja_done_disp, done_pos);
    patchRel32(&buf, jmp_loop_disp, loop_pos);
    patchRel32(&buf, jz_ret_disp, ret_pos);

    return .{ .bytes = buf.bytes, .len = buf.len };
}

pub const print_int = buildPrintIntBlob();
pub const atoi = buildAtoiBlob();
