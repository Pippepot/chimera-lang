const std = @import("std");
const structures = @import("../structures.zig");

pub const Decoded = union(enum) {
    bytes: []u8,
    invalid: struct { offset: usize, kind: structures.Diagnostic.Kind },
};

/// Decode one demanded literal. Returned bytes are owned; failures identify the
/// source byte that begins the rejected escape or the malformed text.
pub fn decode(allocator: std.mem.Allocator, spelling: []const u8) !Decoded {
    std.debug.assert(spelling.len >= 2);
    std.debug.assert(spelling[0] == '"');
    std.debug.assert(spelling[spelling.len - 1] == '"');
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var position: usize = 1;
    while (position < spelling.len - 1) {
        const start = position;
        const unit = decodeUnit(spelling, &position) orelse return .{ .invalid = .{ .offset = start, .kind = .invalid_string_escape } };
        try bytes.appendSlice(allocator, unit.buffer[0..unit.len]);
    }
    if (!std.unicode.utf8ValidateSlice(bytes.items)) return .{ .invalid = .{ .offset = sourceOffset(spelling, invalidUtf8Offset(bytes.items)), .kind = .invalid_string_utf8 } };
    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
}

/// The bytes that one source character or escape decodes to.
const Unit = struct {
    buffer: [4]u8,
    len: u3,

    fn byte(value: u8) Unit {
        return .{ .buffer = .{ value, 0, 0, 0 }, .len = 1 };
    }
};

/// Decodes the character or escape at `position.*` and advances past it.
/// Returns null for a rejected escape.
fn decodeUnit(spelling: []const u8, position: *usize) ?Unit {
    const end = spelling.len - 1;
    const character = spelling[position.*];
    position.* += 1;
    if (character != '\\') return .byte(character);
    if (position.* == end) return null;
    const escape = spelling[position.*];
    position.* += 1;
    switch (escape) {
        '"', '\\' => return .byte(escape),
        'n' => return .byte('\n'),
        'r' => return .byte('\r'),
        't' => return .byte('\t'),
        '0' => return .byte(0),
        'x' => {
            if (end - position.* < 2) return null;
            const high = hex(spelling[position.*]) orelse return null;
            const low = hex(spelling[position.* + 1]) orelse return null;
            position.* += 2;
            return .byte(high * 16 + low);
        },
        'u' => {
            const scalar = unicodeEscape(spelling, position, end) orelse return null;
            var unit: Unit = .{ .buffer = undefined, .len = undefined };
            unit.len = std.unicode.utf8Encode(scalar, &unit.buffer) catch return null;
            return unit;
        },
        else => return null,
    }
}

fn unicodeEscape(spelling: []const u8, position: *usize, end: usize) ?u21 {
    if (position.* == end or spelling[position.*] != '{') return null;
    position.* += 1;
    const digits = position.*;
    var scalar: u32 = 0;
    while (position.* < end and spelling[position.*] != '}') : (position.* += 1) {
        if (position.* - digits == 6) return null;
        scalar = scalar * 16 + (hex(spelling[position.*]) orelse return null);
    }
    if (position.* == end or position.* == digits or scalar > 0x10ffff) return null;
    position.* += 1;
    return @intCast(scalar);
}

fn hex(character: u8) ?u8 {
    return switch (character) {
        '0'...'9' => character - '0',
        'a'...'f' => character - 'a' + 10,
        'A'...'F' => character - 'A' + 10,
        else => null,
    };
}

fn invalidUtf8Offset(bytes: []const u8) usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch return index;
        if (length > bytes.len - index) return index;
        _ = std.unicode.utf8Decode(bytes[index..][0..length]) catch return index;
        index += length;
    }
    unreachable;
}

// Only failures need a source mapping. Decode the already validated escapes
// again rather than retaining one source offset for every decoded byte of every literal.
fn sourceOffset(spelling: []const u8, decoded_offset: usize) usize {
    var position: usize = 1;
    var decoded: usize = 0;
    while (true) {
        const start = position;
        decoded += decodeUnit(spelling, &position).?.len;
        if (decoded_offset < decoded) return start;
    }
}
