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
    const end = spelling.len - 1;
    while (position < end) {
        const start = position;
        const character = spelling[position];
        position += 1;
        if (character != '\\') {
            try bytes.append(allocator, character);
            continue;
        }
        if (position == end) return invalidEscape(start);
        const escape = spelling[position];
        position += 1;
        switch (escape) {
            '"', '\\' => try bytes.append(allocator, escape),
            'n' => try bytes.append(allocator, '\n'),
            'r' => try bytes.append(allocator, '\r'),
            't' => try bytes.append(allocator, '\t'),
            '0' => try bytes.append(allocator, 0),
            'x' => {
                if (end - position < 2) return invalidEscape(start);
                const high = hex(spelling[position]) orelse return invalidEscape(start);
                const low = hex(spelling[position + 1]) orelse return invalidEscape(start);
                try bytes.append(allocator, high * 16 + low);
                position += 2;
            },
            'u' => {
                const scalar = unicodeEscape(spelling, &position, end) orelse return invalidEscape(start);
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(scalar, &encoded) catch return invalidEscape(start);
                try bytes.appendSlice(allocator, encoded[0..length]);
            },
            else => return invalidEscape(start),
        }
    }
    if (!std.unicode.utf8ValidateSlice(bytes.items)) return .{ .invalid = .{ .offset = sourceOffset(spelling, invalidUtf8Offset(bytes.items)), .kind = .invalid_string_utf8 } };
    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
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

fn invalidEscape(offset: usize) Decoded {
    return .{ .invalid = .{ .offset = offset, .kind = .invalid_string_escape } };
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

// Only failures need a source mapping. Walk already validated escapes rather
// than retaining one source offset for every decoded byte of every literal.
fn sourceOffset(spelling: []const u8, decoded_offset: usize) usize {
    var source: usize = 1;
    var decoded: usize = 0;
    while (source < spelling.len - 1) {
        const start = source;
        source += 1;
        var length: usize = 1;
        if (spelling[start] == '\\') {
            const escape = spelling[source];
            source += 1;
            switch (escape) {
                'x' => source += 2,
                'u' => {
                    source += 1;
                    var scalar: u21 = 0;
                    while (spelling[source] != '}') : (source += 1) scalar = scalar * 16 + hex(spelling[source]).?;
                    source += 1;
                    length = std.unicode.utf8CodepointSequenceLength(scalar) catch unreachable;
                },
                else => {},
            }
        }
        if (decoded_offset < decoded + length) return start;
        decoded += length;
    }
    unreachable;
}
