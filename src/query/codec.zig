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
        const U = @Int(.unsigned, @sizeOf(T) * 8);
        var encoded: [@sizeOf(T)]u8 = undefined;
        const widened: U = if (@typeInfo(T).int.signedness == .signed)
            @bitCast(@as(@Int(.signed, @sizeOf(T) * 8), value))
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
            .@"enum" => try self.write(@typeInfo(T).@"enum".tag_type, @backingInt(value)),
            .optional => |info| {
                try self.write(bool, value != null);
                if (value) |present| try self.write(info.child, present);
            },
            .array => |info| for (value) |element| try self.write(info.child, element),
            .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |field_name, FieldType, attrs| {
                if (!attrs.@"comptime") try self.write(FieldType, @field(value, field_name));
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
        const U = @Int(.unsigned, @sizeOf(T) * 8);
        const bytes: *const [@sizeOf(T)]u8 = @ptrCast(try self.take(@sizeOf(T)));
        const raw = std.mem.readInt(U, bytes, .little);
        const result = if (@typeInfo(T).int.signedness == .signed)
            std.math.cast(T, @as(@Int(.signed, @sizeOf(T) * 8), @bitCast(raw)))
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
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return self.readBool(),
            .int => |info| {
                if (info.bits > 64) @compileError("disk codec supports integers up to 64 bits");
                return self.readInt(T);
            },
            .@"enum" => return self.readEnum(T),
            .optional => |info| {
                if (!(try self.read(bool))) return null;
                return try self.read(info.child);
            },
            .array => {
                var result: T = undefined;
                try self.readElements(@typeInfo(T).array.child, &result);
                return result;
            },
            .@"struct" => return self.readStruct(T),
            .@"union" => |info| {
                const Tag = info.tag_type orelse @compileError("untagged unions cannot be persisted");
                const tag = try self.read(Tag);
                switch (tag) {
                    inline else => |active| return @unionInit(T, @tagName(active), try self.read(@FieldType(T, @tagName(active)))),
                }
            },
            .pointer => return self.readSlice(T),
            else => @compileError("unsupported disk cache value: " ++ @typeName(T)),
        }
    }

    fn readBool(self: *Reader) !bool {
        const byte = (try self.take(1))[0];
        if (byte > 1) return error.InvalidCache;
        return byte == 1;
    }

    fn readEnum(self: *Reader, comptime T: type) !T {
        const info = @typeInfo(T).@"enum";
        const raw = try self.read(info.tag_type);
        if (info.mode == .nonexhaustive) return @fromBackingInt(@intCast(raw));
        inline for (info.field_values) |field_value| {
            if (raw == field_value) return @fromBackingInt(@intCast(raw));
        }
        return error.InvalidCache;
    }

    fn readStruct(self: *Reader, comptime T: type) !T {
        const info = @typeInfo(T).@"struct";
        var result: T = undefined;
        var initialized: usize = 0;
        errdefer inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, FieldType, attrs, index| {
            if (!attrs.@"comptime" and index < initialized) freeValue(FieldType, self.allocator, &@field(result, field_name));
        };
        inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, FieldType, attrs, index| {
            if (!attrs.@"comptime") {
                @field(result, field_name) = try self.read(FieldType);
                initialized = index + 1;
            }
        }
        return result;
    }

    fn readSlice(self: *Reader, comptime T: type) !T {
        const info = @typeInfo(T).pointer;
        if (info.size != .slice) @compileError("only owned slices can be persisted");
        const count = std.math.cast(usize, try self.read(u64)) orelse return error.InvalidCache;
        if (count > self.bytes.len - self.offset) return error.InvalidCache;
        if (info.child == u8) return self.allocator.dupe(u8, try self.take(count));
        const values = try self.allocator.alloc(info.child, count);
        errdefer self.allocator.free(values);
        try self.readElements(info.child, values);
        return values;
    }

    fn readElements(self: *Reader, comptime T: type, values: []T) !void {
        var initialized: usize = 0;
        errdefer for (values[0..initialized]) |*element| freeValue(T, self.allocator, element);
        for (values) |*element| {
            element.* = try self.read(T);
            initialized += 1;
        }
    }

    pub fn finished(self: Reader) bool {
        return self.offset == self.bytes.len;
    }
};

pub const freeValue = @import("../value.zig").free;

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

test "disk codec cleans up partial aggregates with comptime fields" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPartialAggregates, .{});
}

fn testPartialAggregates(allocator: std.mem.Allocator) !void {
    const Element = struct {
        comptime label: []const u8 = "metadata",
        name: []const u8,
        comptime version: u32 = 1,
        suffix: []const u8,
    };
    const elements = [_]Element{
        .{ .name = "first", .suffix = "one" },
        .{ .name = "second", .suffix = "two" },
    };
    // Exercise both owners of the shared element-reading cleanup path.
    inline for (.{ @TypeOf(elements), []const Element }) |T| {
        var writer: Writer = .{ .allocator = allocator };
        defer writer.deinit();
        try writer.write(T, if (T == @TypeOf(elements)) elements else &elements);
        for (0..writer.bytes.items.len) |length| {
            var reader: Reader = .{ .allocator = allocator, .bytes = writer.bytes.items[0..length] };
            var unexpected = reader.read(T) catch |err| {
                if (err != error.InvalidCache) return err;
                try std.testing.expectEqual(@as(usize, 0), reader.nesting);
                continue;
            };
            defer freeValue(T, allocator, &unexpected);
            return error.TestExpectedError;
        }
        var reader: Reader = .{ .allocator = allocator, .bytes = writer.bytes.items };
        var decoded = try reader.read(T);
        defer freeValue(T, allocator, &decoded);
        try std.testing.expect(reader.finished());
        for (elements, decoded) |expected, actual| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqualStrings(expected.suffix, actual.suffix);
        }
    }
}
