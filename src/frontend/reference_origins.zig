const std = @import("std");

pub fn Store(comptime Origin: type, comptime Projection: type, comptime Transform: type) type {
    return struct {
        origins: std.ArrayList(Origin) = .empty,
        projections: std.AutoArrayHashMapUnmanaged(Projection, void) = .empty,
        transforms: std.AutoArrayHashMapUnmanaged(Transform, void) = .empty,

        pub fn projection(self: *@This(), allocator: std.mem.Allocator, value: Projection) !u32 {
            return @intCast((try self.projections.getOrPut(allocator, value)).index);
        }

        pub fn transform(self: *@This(), allocator: std.mem.Allocator, value: Transform) !u32 {
            return @intCast((try self.transforms.getOrPut(allocator, value)).index);
        }

        pub fn add(self: *@This(), allocator: std.mem.Allocator, head: ?u32, origin: Origin) !?u32 {
            var cursor = head;
            while (cursor) |index| {
                const existing = &self.origins.items[index];
                if (sameOrigin(existing, &origin)) return head;
                cursor = existing.next;
            }
            return try self.prependAssumeUnique(allocator, head, origin);
        }

        /// The caller has established that this origin is absent from the set.
        pub inline fn prependAssumeUnique(self: *@This(), allocator: std.mem.Allocator, head: ?u32, origin: Origin) !u32 {
            const index: u32 = @intCast(self.origins.items.len);
            var added = origin;
            added.next = head;
            try self.origins.append(allocator, added);
            return index;
        }

        inline fn sameOrigin(left: *const Origin, right: *const Origin) bool {
            inline for (@typeInfo(Origin).@"struct".field_names) |name| {
                if (comptime std.mem.eql(u8, name, "next")) continue;
                const first = @field(left.*, name);
                const second = @field(right.*, name);
                if (comptime @typeInfo(@TypeOf(first)) == .@"union") {
                    if (!std.meta.eql(first, second)) return false;
                } else if (first != second) return false;
            }
            return true;
        }

        pub fn merge(self: *@This(), allocator: std.mem.Allocator, first: ?u32, second: ?u32) !?u32 {
            if (first == null) return second;
            if (first == second) return first;
            var merged = first;
            var cursor = second;
            while (cursor) |index| {
                const origin = self.origins.items[index];
                merged = try self.add(allocator, merged, origin);
                cursor = origin.next;
            }
            return merged;
        }
    };
}

test "reference paths have canonical identities and origin sets ignore list links" {
    const Projection = struct { step: u32, next: ?u32 };
    const Transform = struct { operation: union(enum) { readonly, prefix: u32 }, previous: ?u32 };
    const Origin = struct { projection: ?u32 = null, source_path: ?u32 = null, transform: ?u32 = null, next: ?u32 = null };
    var store: Store(Origin, Projection, Transform) = .{};
    const allocator = std.testing.allocator;
    defer store.origins.deinit(allocator);
    defer store.projections.deinit(allocator);
    defer store.transforms.deinit(allocator);
    const tail = try store.projection(allocator, .{ .step = 7, .next = null });
    const path = try store.projection(allocator, .{ .step = 9, .next = tail });
    try std.testing.expectEqual(path, try store.projection(allocator, .{ .step = 9, .next = tail }));
    try std.testing.expect(path != try store.projection(allocator, .{ .step = 9, .next = null }));
    const transform = try store.transform(allocator, .{ .operation = .readonly, .previous = null });
    try std.testing.expectEqual(transform, try store.transform(allocator, .{ .operation = .readonly, .previous = null }));
    try std.testing.expect(transform != try store.transform(allocator, .{ .operation = .{ .prefix = 9 }, .previous = null }));
    const origin: Origin = .{ .projection = path, .source_path = tail, .transform = transform };
    const first = try store.add(allocator, null, origin);
    const second = try store.add(allocator, first, .{ .projection = tail });
    try std.testing.expectEqual(second, try store.add(allocator, second, origin));
    try std.testing.expectEqual(@as(usize, 2), store.origins.items.len);
}
