const std = @import("std");

const max_h = 384;

pub const HelperBlob = struct {
    bytes: [max_h]u8 = [_]u8{0} ** max_h,
    len: usize = 0,

    pub fn slice(self: *const @This()) []const u8 {
        return self.bytes[0..self.len];
    }

    fn append(self: *@This(), bytes: []const u8) void {
        const new_len = self.len + bytes.len;
        if (new_len > self.bytes.len) @compileError("helper blob exceeds max_h");
        @memcpy(self.bytes[self.len..new_len], bytes);
        self.len = new_len;
    }

    fn rel32(self: *@This()) usize {
        const pos = self.len;
        self.append(&.{ 0, 0, 0, 0 });
        return pos;
    }

    fn patch(self: *@This(), disp: usize, target: usize) void {
        const rel: i32 = @intCast(@as(i64, @intCast(target)) - (@as(i64, @intCast(disp)) + 4));
        std.mem.writeInt(i32, self.bytes[disp..][0..4], rel, .little);
    }
};

pub const HelperId = enum {
    print_int,
    print_bool,
    print_float32,
    atoi,
};

pub const HelperDef = struct {
    id: HelperId,
    blob: HelperBlob,
};

const push6 = [_]u8{ 0x50, 0x53, 0x51, 0x52, 0x56, 0x57 };
const pop6  = [_]u8{ 0x5F, 0x5E, 0x5A, 0x59, 0x5B, 0x58 };
const push4 = [_]u8{ 0x50, 0x52, 0x56, 0x57 };
const pop4  = [_]u8{ 0x5F, 0x5E, 0x5A, 0x58 };

const write_stdout = [_]u8{
    0xBF, 0x01, 0x00, 0x00, 0x00,
    0xB8, 0x01, 0x00, 0x00, 0x00,
    0x0F, 0x05,
};

fn buildPrintIntBlob() HelperBlob {
    var b = HelperBlob{};

    b.append(&push6);
    b.append(&.{ 0xBB, 0x0A, 0x00, 0x00, 0x00 });
    b.append(&.{ 0x48, 0x83, 0xEC, 0x20 });
    b.append(&.{ 0xC6, 0x04, 0x24, 0x00 });
    b.append(&.{ 0x48, 0x8D, 0x7C, 0x24, 0x1F });
    b.append(&.{ 0xC6, 0x07, 0x0A });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0x83, 0xF8, 0x00 });
    b.append(&.{ 0x0F, 0x8D });
    const jge = b.rel32();

    b.append(&.{ 0xF7, 0xD8 });
    b.append(&.{ 0xC6, 0x04, 0x24, 0x01 });

    const loop = b.len;

    b.append(&.{ 0x31, 0xD2 });
    b.append(&.{ 0xF7, 0xF3 });
    b.append(&.{ 0x80, 0xC2, '0' });
    b.append(&.{ 0x88, 0x17 });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0x85, 0xC0 });
    b.append(&.{ 0x0F, 0x85 });
    const jnz = b.rel32();

    b.append(&.{ 0x80, 0x3C, 0x24, 0x01 });
    b.append(&.{ 0x0F, 0x85 });
    const jne = b.rel32();

    b.append(&.{ 0xC6, 0x07, '-' });
    b.append(&.{ 0x48, 0xFF, 0xCF });

    const write = b.len;

    b.append(&.{ 0x48, 0x8D, 0x77, 0x01 });
    b.append(&.{ 0x48, 0x89, 0xE2 });
    b.append(&.{ 0x48, 0x83, 0xC2, 0x20 });
    b.append(&.{ 0x48, 0x29, 0xF2 });
    b.append(&write_stdout);
    b.append(&.{ 0x48, 0x83, 0xC4, 0x20 });

    b.append(&pop6);
    b.append(&.{0xC3});

    b.patch(jge, loop);
    b.patch(jnz, loop);
    b.patch(jne, write);

    return b;
}

fn buildAtoiBlob() HelperBlob {
    var b = HelperBlob{};

    b.append(&.{ 0x51 });
    b.append(&.{ 0x31, 0xC0 });
    b.append(&.{ 0x31, 0xC9 });
    b.append(&.{ 0x80, 0x3F, '-' });
    b.append(&.{ 0x0F, 0x85 });
    const jne = b.rel32();

    b.append(&.{ 0xB1, 0x01 });
    b.append(&.{ 0x48, 0xFF, 0xC7 });

    const loop = b.len;

    b.append(&.{ 0x0F, 0xB6, 0x17 });
    b.append(&.{ 0x84, 0xD2 });
    b.append(&.{ 0x0F, 0x84 });
    const jz_done = b.rel32();

    b.append(&.{ 0x83, 0xEA, '0' });
    b.append(&.{ 0x83, 0xFA, 0x09 });
    b.append(&.{ 0x0F, 0x87 });
    const ja_done = b.rel32();

    b.append(&.{ 0x6B, 0xC0, 0x0A });
    b.append(&.{ 0x01, 0xD0 });
    b.append(&.{ 0x48, 0xFF, 0xC7 });
    b.append(&.{ 0xE9 });
    const jmp = b.rel32();

    const done = b.len;

    b.append(&.{ 0x85, 0xC9 });
    b.append(&.{ 0x0F, 0x84 });
    const jz_ret = b.rel32();

    b.append(&.{ 0xF7, 0xD8 });

    const ret = b.len;

    b.append(&.{ 0x59 });
    b.append(&.{ 0xC3 });

    b.patch(jne, loop);
    b.patch(jz_done, done);
    b.patch(ja_done, done);
    b.patch(jmp, loop);
    b.patch(jz_ret, ret);

    return b;
}

fn buildPrintBoolBlob() HelperBlob {
    var b = HelperBlob{};
    b.append(&push4);
    b.append(&.{ 0x83, 0xF8, 0x00 });
    b.append(&.{ 0x75, 0x0E });
    b.append(&.{ 0x48, 0x8D, 0x35, 0x29, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xBA, 0x06, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xEB, 0x0C });
    b.append(&.{ 0x48, 0x8D, 0x35, 0x16, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xBA, 0x05, 0x00, 0x00, 0x00 });
    b.append(&write_stdout);
    b.append(&pop4);
    b.append(&.{0xC3});
    b.append(&.{ 0x74, 0x72, 0x75, 0x65, 0x0A });
    b.append(&.{ 0x66, 0x61, 0x6C, 0x73, 0x65, 0x0A });
    return b;
}

fn buildPrintFloat32Blob() HelperBlob {
    var b = HelperBlob{};
    b.append(&push6);
    b.append(&.{ 0x48, 0x83, 0xEC, 0x40 });
    b.append(&.{ 0xC6, 0x04, 0x24, 0x00 });
    b.append(&.{ 0x0F, 0x57, 0xD2 });
    b.append(&.{ 0x0F, 0x2E, 0xC2 });
    b.append(&.{ 0x73, 0x10 });
    b.append(&.{ 0xC6, 0x04, 0x24, 0x01 });
    b.append(&.{ 0xF3, 0x0F, 0x10, 0x15, 0xA9, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xF3, 0x0F, 0x59, 0xC2 });
    b.append(&.{ 0xF3, 0x0F, 0x10, 0x0D, 0x99, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xF3, 0x0F, 0x59, 0xC1 });
    b.append(&.{ 0xF3, 0x0F, 0x2C, 0xC0 });
    b.append(&.{ 0xBB, 0x40, 0x42, 0x0F, 0x00 });
    b.append(&.{ 0x31, 0xD2 });
    b.append(&.{ 0xF7, 0xF3 });
    b.append(&.{ 0x41, 0x89, 0xC0 });
    b.append(&.{ 0x41, 0x89, 0xD1 });
    b.append(&.{ 0x48, 0x8D, 0x7C, 0x24, 0x3F });
    b.append(&.{ 0xC6, 0x07, 0x0A });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0x44, 0x89, 0xC8 });
    b.append(&.{ 0xB9, 0x06, 0x00, 0x00, 0x00 });
    b.append(&.{ 0x31, 0xD2 });
    b.append(&.{ 0xBB, 0x0A, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xF7, 0xF3 });
    b.append(&.{ 0x80, 0xC2, 0x30 });
    b.append(&.{ 0x88, 0x17 });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0xFF, 0xC9 });
    b.append(&.{ 0x75, 0xEB });
    b.append(&.{ 0xC6, 0x07, 0x2E });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0x44, 0x89, 0xC0 });
    b.append(&.{ 0x83, 0xF8, 0x00 });
    b.append(&.{ 0x75, 0x08 });
    b.append(&.{ 0xC6, 0x07, 0x30 });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0xEB, 0x15 });
    b.append(&.{ 0x31, 0xD2 });
    b.append(&.{ 0xBB, 0x0A, 0x00, 0x00, 0x00 });
    b.append(&.{ 0xF7, 0xF3 });
    b.append(&.{ 0x80, 0xC2, 0x30 });
    b.append(&.{ 0x88, 0x17 });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0x85, 0xC0 });
    b.append(&.{ 0x75, 0xEB });
    b.append(&.{ 0x80, 0x3C, 0x24, 0x01 });
    b.append(&.{ 0x75, 0x06 });
    b.append(&.{ 0xC6, 0x07, '-' });
    b.append(&.{ 0x48, 0xFF, 0xCF });
    b.append(&.{ 0x48, 0x8D, 0x77, 0x01 });
    b.append(&.{ 0x48, 0x8D, 0x54, 0x24, 0x40 });
    b.append(&.{ 0x48, 0x29, 0xF2 });
    b.append(&write_stdout);
    b.append(&.{ 0x48, 0x83, 0xC4, 0x40 });
    b.append(&pop6);
    b.append(&.{0xC3});
    b.append(&.{ 0x00, 0x24, 0x74, 0x49, 0x00, 0x00, 0x80, 0xBF });
    return b;
}

pub const print_int = buildPrintIntBlob();
pub const print_bool = buildPrintBoolBlob();
pub const print_float32 = buildPrintFloat32Blob();
pub const atoi = buildAtoiBlob();

pub const all_helpers = [_]HelperDef{
    .{ .id = .print_int, .blob = print_int },
    .{ .id = .print_bool, .blob = print_bool },
    .{ .id = .print_float32, .blob = print_float32 },
    .{ .id = .atoi, .blob = atoi },
};

comptime {
    for (&all_helpers) |h| {
        if (h.blob.len > max_h) @compileError("helper " ++ @tagName(h.id) ++ " exceeds max");
    }
    const n = @typeInfo(HelperId).@"enum".fields.len;
    if (all_helpers.len != n) @compileError("all_helpers must include every HelperId");
    for (all_helpers, 0..) |h, i| {
        if (@intFromEnum(h.id) != i) @compileError("all_helpers must follow HelperId enum order");
    }
}

test "helper enum values map to registry index" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(HelperId.print_int));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(HelperId.print_bool));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(HelperId.print_float32));
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum(HelperId.atoi));
}
