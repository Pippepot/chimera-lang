const std = @import("std");

/// Folds each scalar field into one 64-bit state. Origins carry dozens of small fields, and
/// streaming each through a general-purpose hash dominated origin interning.
pub const FoldHasher = struct {
    state: u64 = 0x9e3779b97f4a7c15,

    pub fn update(self: *FoldHasher, bytes: []const u8) void {
        var rest = bytes;
        while (true) {
            const chunk = rest[0..@min(rest.len, @sizeOf(u64))];
            var word: u64 = 0;
            @memcpy(std.mem.asBytes(&word)[0..chunk.len], chunk);
            self.state = std.math.rotl(u64, (self.state ^ word) *% 0xff51afd7ed558ccd, 31) +% chunk.len;
            rest = rest[chunk.len..];
            if (rest.len == 0) break;
        }
    }

    pub fn final(self: *const FoldHasher) u64 {
        var mixed = self.state;
        mixed ^= mixed >> 33;
        mixed *%= 0xc4ceb9fe1a85ec53;
        return mixed ^ (mixed >> 29);
    }
};

/// Hashes structurally with the same equality as `std.AutoArrayHashMap`.
pub fn FoldContext(comptime Key: type) type {
    return struct {
        pub fn hash(_: @This(), key: Key) u32 {
            var hasher: FoldHasher = .{};
            std.hash.autoHash(&hasher, key);
            return @truncate(hasher.final());
        }

        pub fn eql(_: @This(), left: Key, right: Key, _: usize) bool {
            return std.meta.eql(left, right);
        }
    };
}

/// Structural hash map context for keys made of small scalar fields.
pub fn FoldHashContext(comptime Key: type) type {
    return struct {
        pub fn hash(_: @This(), key: Key) u64 {
            var hasher: FoldHasher = .{};
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }

        pub fn eql(_: @This(), left: Key, right: Key) bool {
            return std.meta.eql(left, right);
        }
    };
}

pub fn Store(comptime Origin: type, comptime Projection: type, comptime Transform: type) type {
    return struct {
        pub const Origins = std.ArrayHashMapUnmanaged(Origin, void, FoldContext(Origin), true);
        /// Interned nodes are immutable, including their list links.
        origins: Origins = .empty,
        /// Origin sets can grow combinatorially with the nesting of a program's types;
        /// beyond this many entries the analysis fails instead of exhausting memory.
        maximum: usize = std.math.maxInt(u32),
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
                const existing = &self.origins.keys()[index];
                if (sameOrigin(existing, &origin)) return head;
                cursor = existing.next;
            }
            return try self.prependAssumeUnique(allocator, head, origin);
        }

        /// The caller has established that this origin is absent from the set.
        pub inline fn prependAssumeUnique(self: *@This(), allocator: std.mem.Allocator, head: ?u32, origin: Origin) !u32 {
            var added = origin;
            added.next = head;
            if (self.origins.count() >= self.maximum) return @intCast(self.origins.getIndex(added) orelse return error.AnalysisTooLarge);
            return @intCast((try self.origins.getOrPut(allocator, added)).index);
        }

        /// Set membership ignores list links.
        inline fn sameOrigin(left: *const Origin, right: *const Origin) bool {
            var first = left.*;
            first.next = right.next;
            return std.meta.eql(first, right.*);
        }

        pub fn merge(self: *@This(), allocator: std.mem.Allocator, first: ?u32, second: ?u32) !?u32 {
            if (first == null) return second;
            if (first == second) return first;
            var merged = first;
            var cursor = second;
            while (cursor) |index| {
                const origin = self.origins.keys()[index];
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
    try std.testing.expectEqual(first, try store.add(allocator, null, origin));
    try std.testing.expectEqual(second, try store.add(allocator, first, .{ .projection = tail }));
    try std.testing.expectEqual(@as(usize, 2), store.origins.count());
}

test "an origin store refuses to grow past its maximum" {
    const Origin = struct { value: u32 = 0, next: ?u32 = null };
    var store: Store(Origin, struct { step: u32, next: ?u32 }, struct { operation: u32, previous: ?u32 }) = .{ .maximum = 2 };
    const allocator = std.testing.allocator;
    defer store.origins.deinit(allocator);
    const first = try store.add(allocator, null, .{ .value = 1 });
    const second = try store.add(allocator, first, .{ .value = 2 });
    try std.testing.expectEqual(first, try store.add(allocator, first, .{ .value = 1 }));
    try std.testing.expectEqual(first, try store.add(allocator, null, .{ .value = 1 }));
    try std.testing.expectError(error.AnalysisTooLarge, store.add(allocator, second, .{ .value = 3 }));
    try std.testing.expectEqual(@as(usize, 2), store.origins.count());
}
