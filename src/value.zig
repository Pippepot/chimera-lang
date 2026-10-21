const std = @import("std");

/// Structural operations for plain values whose slices, including nested slices,
/// are owned. Borrowed graphs and containers keep their explicit ownership rules.
pub fn Owned(comptime T: type) type {
    return struct {
        pub fn hash(value: T) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, value, .DeepRecursive);
            return hasher.final();
        }

        pub fn eql(a: T, b: T) bool {
            return equal(T, a, b);
        }

        pub fn clone(allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
            return copy(T, allocator, value);
        }

        pub fn deinit(self: *T, allocator: std.mem.Allocator) void {
            free(T, allocator, self);
        }

        pub fn destroy(allocator: std.mem.Allocator, self: *T) void {
            free(T, allocator, self);
        }
    };
}

test "owned values compare allocation contents and distinguish absent and empty slices" {
    const Choice = union(enum) { none, number: i32 };
    const T = struct { name: []const u8, values: ?[]const Choice };
    const original: T = .{ .name = "name", .values = &.{ .none, .{ .number = 7 } } };
    var copied: T = .{ .name = try std.testing.allocator.dupe(u8, original.name), .values = null };
    defer Owned(T).deinit(&copied, std.testing.allocator);
    copied.values = try std.testing.allocator.dupe(Choice, original.values.?);
    try std.testing.expect(Owned(T).eql(original, copied));
    try std.testing.expectEqual(Owned(T).hash(original), Owned(T).hash(copied));
    try std.testing.expect(!Owned(T).eql(.{ .name = "name", .values = null }, .{ .name = "name", .values = &.{} }));
    try std.testing.expect(!Owned(T).eql(original, .{ .name = "name", .values = &.{.none} }));
    try std.testing.expect(!Owned(T).eql(original, .{ .name = "name", .values = &.{ .none, .{ .number = 8 } } }));
}

test "owned values copy nested storage and clean up partial copies" {
    const Choice = union(enum) { none, names: []const []const u8 };
    const T = struct { choices: [3]Choice, extra: ?[]const u8, absent: ?[]const u8 = null };
    const original: T = .{ .choices = .{ .{ .names = &.{"earlier"} }, .none, .{ .names = &.{ "first", "second" } } }, .extra = "extra" };
    var copied = try Owned(T).clone(std.testing.allocator, original);
    defer Owned(T).deinit(&copied, std.testing.allocator);
    try std.testing.expect(Owned(T).eql(original, copied));
    try std.testing.expectEqual(Owned(T).hash(original), Owned(T).hash(copied));
    try std.testing.expect(original.choices[0].names.ptr != copied.choices[0].names.ptr);
    try std.testing.expect(original.choices[0].names[0].ptr != copied.choices[0].names[0].ptr);
    try std.testing.expect(original.choices[2].names.ptr != copied.choices[2].names.ptr);
    try std.testing.expect(original.choices[2].names[0].ptr != copied.choices[2].names[0].ptr);
    try std.testing.expect(original.extra.?.ptr != copied.extra.?.ptr);
    for (0..6) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Owned(T).clone(failing.allocator(), original));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

/// Plain payloads need neither traversal nor initialization during cleanup.
/// All pointer shapes still reach the owning operation's slice validation.
fn ownsStorage(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => return true,
        inline .optional, .array => |info| return ownsStorage(info.child),
        inline .@"struct", .@"union" => |info| {
            for (info.field_types) |Field| if (ownsStorage(Field)) return true;
            return false;
        },
        else => return false,
    }
}

test "owned buffers release uninitialized plain payloads without reading union tags" {
    const Plain = union(enum) { integer: i32, flag: bool };
    const Buffer = struct { values: []Plain };
    var buffer: Buffer = .{ .values = try std.testing.allocator.alloc(Plain, 8) };
    defer Owned(Buffer).deinit(&buffer, std.testing.allocator);
}

fn copy(comptime T: type, allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!T {
    if (comptime !ownsStorage(T)) return value;
    switch (@typeInfo(T)) {
        .optional => |info| return if (value) |present| try copy(info.child, allocator, present) else null,
        .array => |info| {
            var result: T = undefined;
            try copyElements(info.child, allocator, &value, &result);
            return result;
        },
        .@"struct" => |info| {
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, index| {
                if (!attrs.@"comptime" and index < initialized) free(Field, allocator, &@field(result, name));
            };
            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, Field, attrs, index| {
                if (!attrs.@"comptime") @field(result, name) = try copy(Field, allocator, @field(value, name));
                initialized = index + 1;
            }
            return result;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try copy(@TypeOf(payload), allocator, payload)),
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("owned value copying requires slices, not pointers");
            if (value.len == 0) return &.{};
            if (comptime !ownsStorage(info.child)) return allocator.dupe(info.child, value);
            const result = try allocator.alloc(info.child, value.len);
            errdefer allocator.free(result);
            try copyElements(info.child, allocator, value, result);
            return result;
        },
        else => return value,
    }
}

fn copyElements(comptime T: type, allocator: std.mem.Allocator, source: []const T, destination: []T) std.mem.Allocator.Error!void {
    std.debug.assert(source.len == destination.len);
    var initialized: usize = 0;
    errdefer for (destination[0..initialized]) |*element| free(T, allocator, element);
    for (source, destination) |element, *slot| {
        slot.* = try copy(T, allocator, element);
        initialized += 1;
    }
}

/// Compare contents, ignoring allocation identity and struct padding.
pub fn equal(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (a == null or b == null) return a == null and b == null;
            return equal(info.child, a.?, b.?);
        },
        .array => |info| {
            for (a, b) |left, right| if (!equal(info.child, left, right)) return false;
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("content equality requires slices, not pointers");
            if (info.child == u8) return std.mem.eql(u8, a, b);
            if (a.len != b.len) return false;
            for (a, b) |left, right| if (!equal(info.child, left, right)) return false;
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            if (!equal(Field, @field(a, name), @field(b, name))) return false;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |payload, tag| return equal(@TypeOf(payload), payload, @field(b, @tagName(tag))),
            }
        },
        else => return std.meta.eql(a, b),
    }
    return true;
}

pub fn free(comptime T: type, allocator: std.mem.Allocator, value: *T) void {
    if (comptime !ownsStorage(T)) {
        value.* = undefined;
        return;
    }
    switch (@typeInfo(T)) {
        .optional => |info| if (value.*) |*present| free(info.child, allocator, present),
        .array => |info| for (value) |*element| free(info.child, allocator, element),
        .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            if (!attrs.@"comptime") free(Field, allocator, &@field(value.*, name));
        },
        .@"union" => switch (value.*) {
            inline else => |*payload| free(@TypeOf(payload.*), allocator, payload),
        },
        .pointer => |info| {
            if (info.size != .slice) @compileError("owned value cleanup requires slices, not pointers");
            if (comptime ownsStorage(info.child)) for (value.*) |*element| free(info.child, allocator, @constCast(element));
            if (value.*.len != 0) allocator.free(value.*);
        },
        else => {},
    }
    value.* = undefined;
}
