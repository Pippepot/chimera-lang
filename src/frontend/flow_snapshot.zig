const std = @import("std");

/// Body-local persistent arrays. A snapshot freezes its root; the next write
/// copies its pointer table and the changed page. All versions borrow the body's
/// arena; no individual version needs cleanup.
/// Restoring a snapshot is a root assignment, including all default-valued slots.
pub fn Buffer(comptime Element: type, comptime initial: Element) type {
    return struct {
        const Self = @This();
        const page_size = 16;
        const Page = struct { writable: bool = true, values: [page_size]Element = @splat(initial) };
        const Root = struct { writable: bool = true, pages: []?*Page };

        len: usize = 0,
        root: ?*Root = null,

        pub fn init(len: usize) Self {
            return .{ .len = len };
        }

        pub fn snapshot(self: Self) Self {
            if (self.root) |root| root.writable = false;
            return self;
        }

        pub inline fn get(self: Self, index: usize) Element {
            std.debug.assert(index < self.len);
            const page = self.leafPage(index) orelse return initial;
            return page.values[index % page_size];
        }

        inline fn leafPage(self: Self, index: usize) ?*Page {
            return if (self.root) |root| root.pages[index / page_size] else null;
        }

        fn write(self: *Self, allocator: std.mem.Allocator, index: usize) !*Element {
            std.debug.assert(index < self.len);
            if (self.root == null or !self.root.?.writable) {
                const root = try allocator.create(Root);
                root.* = .{ .pages = try allocator.alloc(?*Page, (self.len + page_size - 1) / page_size) };
                if (self.root) |previous| {
                    @memcpy(root.pages, previous.pages);
                    for (root.pages) |maybe_page| if (maybe_page) |page| {
                        page.writable = false;
                    };
                } else @memset(root.pages, null);
                self.root = root;
            }
            const slot = &self.root.?.pages[index / page_size];
            if (slot.* == null or !slot.*.?.writable) {
                const page = try allocator.create(Page);
                page.* = if (slot.*) |previous| previous.* else .{};
                page.writable = true;
                slot.* = page;
            }
            return &slot.*.?.values[index % page_size];
        }

        pub fn set(self: *Self, allocator: std.mem.Allocator, index: usize, value: Element) !void {
            if (!std.meta.eql(self.get(index), value)) (try self.write(allocator, index)).* = value;
        }

        pub fn sharesPage(self: Self, other: Self, index: usize) bool {
            return index < self.len and index < other.len and self.leafPage(index) == other.leafPage(index);
        }

        pub fn pageEnd(self: Self, index: usize) usize {
            return @min(self.len, (index / page_size + 1) * page_size);
        }

        pub fn eql(self: Self, other: Self) bool {
            if (self.len != other.len) return false;
            var index: usize = 0;
            while (index < self.len) {
                if (self.sharesPage(other, index)) {
                    index = self.pageEnd(index);
                    continue;
                }
                if (!std.meta.eql(self.get(index), other.get(index))) return false;
                index += 1;
            }
            return true;
        }

        pub fn merge(self: *Self, allocator: std.mem.Allocator, other: Self, comptime combine: fn (Element, Element) Element) !void {
            std.debug.assert(self.len == other.len);
            var index: usize = 0;
            while (index < self.len) {
                if (self.sharesPage(other, index)) {
                    index = self.pageEnd(index);
                    continue;
                }
                try self.set(allocator, index, combine(self.get(index), other.get(index)));
                index += 1;
            }
        }

        pub fn retainedBytes(self: Self, seen: *std.AutoHashMap(usize, void)) !usize {
            const root = self.root orelse return 0;
            if ((try seen.getOrPut(@intFromPtr(root))).found_existing) return 0;
            var bytes = @sizeOf(Root) + std.mem.sliceAsBytes(root.pages).len;
            for (root.pages) |maybe_page| if (maybe_page) |page| {
                if (!(try seen.getOrPut(@intFromPtr(page))).found_existing) bytes += @sizeOf(Page);
            };
            return bytes;
        }
    };
}

test "persistent flow state isolates writes, restores defaults, and shares untouched pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var live = Buffer(?u32, null).init(513);
    try live.set(allocator, 0, 1);
    try live.set(allocator, 512, 9);
    const first = live.snapshot();
    try live.set(allocator, 32, 7);
    var second = live.snapshot();
    try std.testing.expect(first.sharesPage(second, 0));
    try std.testing.expect(!first.sharesPage(second, 32));
    try std.testing.expectEqual(@as(?u32, null), first.get(32));
    live = first.snapshot();
    try std.testing.expectEqual(@as(?u32, null), live.get(32));
    try live.set(allocator, 0, 5);
    try second.set(allocator, 512, 11);
    try std.testing.expectEqual(@as(?u32, 1), first.get(0));
    try std.testing.expectEqual(@as(?u32, 1), second.get(0));
    try std.testing.expectEqual(@as(?u32, 9), first.get(512));
    try std.testing.expectEqual(@as(?u32, 9), live.get(512));
    try std.testing.expectEqual(@as(?u32, 11), second.get(512));
    var joined = first.snapshot();
    try joined.merge(allocator, second, struct {
        fn combine(left: ?u32, right: ?u32) ?u32 {
            return right orelse left;
        }
    }.combine);
    try std.testing.expect(joined.eql(second));
}

test "failed persistent writes preserve snapshots and remain retryable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var live = Buffer(u32, 0).init(513);
    try live.set(allocator, 0, 3);
    const saved = live.snapshot();
    for (0..3) |fail_index| {
        live = saved.snapshot();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, live.set(failing.allocator(), 512, 7));
        try std.testing.expect(live.eql(saved));
        try live.set(allocator, 512, 7);
        try std.testing.expectEqual(@as(u32, 0), saved.get(512));
        try std.testing.expectEqual(@as(u32, 3), live.get(0));
    }
}
