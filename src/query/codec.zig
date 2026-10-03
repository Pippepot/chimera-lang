const std = @import("std");

/// An explicit, padding-free encoding for the owned value shapes persisted by
/// the compiler. Integer widths and union tags are checked while reading.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    fn writeInt(self: *Writer, comptime T: type, value: T) !void {
        const U = std.meta.Int(.unsigned, @sizeOf(T) * 8);
        var encoded: [@sizeOf(T)]u8 = undefined;
        const widened: U = if (@typeInfo(T).int.signedness == .signed)
            @bitCast(@as(std.meta.Int(.signed, @sizeOf(T) * 8), value))
        else
            value;
        std.mem.writeInt(U, &encoded, widened, .little);
        try self.bytes.appendSlice(self.allocator, &encoded);
    }

    pub fn write(self: *Writer, comptime T: type, value: T) std.mem.Allocator.Error!void {
        switch (@typeInfo(T)) {
            .void => {},
            .bool => try self.bytes.append(self.allocator, @intFromBool(value)),
            .int => |info| {
                if (info.bits > 64) @compileError("disk codec supports integers up to 64 bits");
                try self.writeInt(T, value);
            },
            .@"enum" => try self.write(@typeInfo(T).@"enum".tag_type, @intFromEnum(value)),
            .optional => |info| {
                try self.write(bool, value != null);
                if (value) |present| try self.write(info.child, present);
            },
            .array => |info| for (value) |element| try self.write(info.child, element),
            .@"struct" => |info| inline for (info.fields) |field| {
                if (!field.is_comptime) try self.write(field.type, @field(value, field.name));
            },
            .@"union" => |info| {
                const Tag = info.tag_type orelse @compileError("untagged unions cannot be persisted");
                const tag = std.meta.activeTag(value);
                try self.write(Tag, tag);
                switch (value) {
                    inline else => |payload| try self.write(@TypeOf(payload), payload),
                }
            },
            .pointer => |info| {
                if (info.size != .slice) @compileError("only owned slices can be persisted");
                try self.write(u64, @intCast(value.len));
                if (info.child == u8) {
                    try self.bytes.appendSlice(self.allocator, value);
                } else {
                    for (value) |element| try self.write(info.child, element);
                }
            },
            else => @compileError("unsupported disk cache value: " ++ @typeName(T)),
        }
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    offset: usize = 0,
    nesting: usize = 0,

    pub fn take(self: *Reader, count: usize) error{InvalidCache}![]const u8 {
        if (self.offset > self.bytes.len) return error.InvalidCache;
        if (count > self.bytes.len - self.offset) return error.InvalidCache;
        const result = self.bytes[self.offset..][0..count];
        self.offset += count;
        return result;
    }

    fn readInt(self: *Reader, comptime T: type) error{InvalidCache}!T {
        const U = std.meta.Int(.unsigned, @sizeOf(T) * 8);
        const bytes: *const [@sizeOf(T)]u8 = @ptrCast(try self.take(@sizeOf(T)));
        const raw = std.mem.readInt(U, bytes, .little);
        const result = if (@typeInfo(T).int.signedness == .signed)
            std.math.cast(T, @as(std.meta.Int(.signed, @sizeOf(T) * 8), @bitCast(raw)))
        else
            std.math.cast(T, raw);
        return result orelse error.InvalidCache;
    }

    pub fn read(self: *Reader, comptime T: type) anyerror!T {
        // Owned initializer regions make bodies recursive. Damaged snapshots
        // must fail at this boundary rather than exhaust the compiler's stack.
        if (self.nesting == 256) return error.InvalidCache;
        self.nesting += 1;
        defer self.nesting -= 1;
        return switch (@typeInfo(T)) {
            .void => {},
            .bool => blk: {
                const byte = (try self.take(1))[0];
                if (byte > 1) return error.InvalidCache;
                break :blk byte == 1;
            },
            .int => |info| blk: {
                if (info.bits > 64) @compileError("disk codec supports integers up to 64 bits");
                break :blk try self.readInt(T);
            },
            .@"enum" => |info| blk: {
                const raw = try self.read(info.tag_type);
                if (info.is_exhaustive) {
                    inline for (info.fields) |field| {
                        if (raw == field.value) break :blk @enumFromInt(raw);
                    }
                    return error.InvalidCache;
                }
                break :blk @enumFromInt(raw);
            },
            .optional => |info| blk: {
                if (!(try self.read(bool))) break :blk null;
                break :blk try self.read(info.child);
            },
            .array => |info| blk: {
                var result: T = undefined;
                var initialized: usize = 0;
                errdefer for (result[0..initialized]) |*element| freeValue(info.child, self.allocator, element);
                for (&result) |*element| {
                    element.* = try self.read(info.child);
                    initialized += 1;
                }
                break :blk result;
            },
            .@"struct" => |info| blk: {
                var result: T = undefined;
                var initialized: usize = 0;
                errdefer inline for (info.fields, 0..) |field, index| {
                    if (!field.is_comptime and index < initialized) freeValue(field.type, self.allocator, &@field(result, field.name));
                };
                inline for (info.fields) |field| {
                    if (!field.is_comptime) {
                        @field(result, field.name) = try self.read(field.type);
                        initialized += 1;
                    }
                }
                break :blk result;
            },
            .@"union" => |info| blk: {
                const Tag = info.tag_type orelse @compileError("untagged unions cannot be persisted");
                const tag = try self.read(Tag);
                break :blk switch (tag) {
                    inline else => |active| @unionInit(T, @tagName(active), try self.read(@FieldType(T, @tagName(active)))),
                };
            },
            .pointer => |info| blk: {
                if (info.size != .slice) @compileError("only owned slices can be persisted");
                const count = std.math.cast(usize, try self.read(u64)) orelse return error.InvalidCache;
                if (count > self.bytes.len - self.offset) return error.InvalidCache;
                if (info.child == u8) {
                    break :blk try self.allocator.dupe(u8, try self.take(count));
                }
                const values = try self.allocator.alloc(info.child, count);
                var initialized: usize = 0;
                errdefer {
                    for (values[0..initialized]) |*element| freeValue(info.child, self.allocator, element);
                    self.allocator.free(values);
                }
                for (values) |*element| {
                    element.* = try self.read(info.child);
                    initialized += 1;
                }
                break :blk values;
            },
            else => @compileError("unsupported disk cache value: " ++ @typeName(T)),
        };
    }

    pub fn finished(self: Reader) bool {
        return self.offset == self.bytes.len;
    }
};

pub fn freeValue(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .optional => |info| if (value.*) |*present| freeValue(info.child, allocator, present),
        .array => |info| for (value) |*element| freeValue(info.child, allocator, element),
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!field.is_comptime) freeValue(field.type, allocator, &@field(value.*, field.name));
        },
        .@"union" => switch (value.*) {
            inline else => |*payload| freeValue(@TypeOf(payload.*), allocator, payload),
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("only owned slices can be persisted");
            for (value.*) |*element| freeValue(info.child, allocator, @constCast(element));
            allocator.free(value.*);
        },
        else => {},
    }
    value.* = undefined;
}

test "disk codec roundtrips nested owned values and rejects invalid tags" {
    const testing = std.testing;
    const Value = struct { name: []const u8, choices: []const union(enum) { none, number: i32 }, maybe: ?u31 };
    const input: Value = .{ .name = "hello", .choices = &.{ .none, .{ .number = -7 } }, .maybe = 23 };
    var writer: Writer = .{ .allocator = testing.allocator };
    defer writer.deinit();
    try writer.write(Value, input);
    var reader: Reader = .{ .allocator = testing.allocator, .bytes = writer.bytes.items };
    var decoded = try reader.read(Value);
    defer freeValue(Value, testing.allocator, &decoded);
    try testing.expect(reader.finished());
    try testing.expectEqualStrings(input.name, decoded.name);
    try testing.expectEqual(@as(i32, -7), decoded.choices[1].number);
    var invalid: Reader = .{ .allocator = testing.allocator, .bytes = &.{255} };
    try testing.expectError(error.InvalidCache, invalid.read(bool));
    invalid.offset = 0;
    try testing.expectError(error.InvalidCache, invalid.read(union(enum) { none, number: i32 }));
}

test "disk codec bounds recursive owned values and cleans up a truncated region" {
    const Node = struct { children: []const @This() };
    const leaf: Node = .{ .children = &.{} };
    const child: Node = .{ .children = &.{leaf} };
    const root: Node = .{ .children = &.{child} };
    var writer: Writer = .{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try writer.write(Node, root);
    var short: Reader = .{ .allocator = std.testing.allocator, .bytes = writer.bytes.items[0 .. writer.bytes.items.len - 1] };
    try std.testing.expectError(error.InvalidCache, short.read(Node));
    try std.testing.expectEqual(@as(usize, 0), short.nesting);
    var deep: Reader = .{ .allocator = std.testing.allocator, .bytes = writer.bytes.items, .nesting = 255 };
    try std.testing.expectError(error.InvalidCache, deep.read(Node));
    try std.testing.expectEqual(@as(usize, 255), deep.nesting);
}
