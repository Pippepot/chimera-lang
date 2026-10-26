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

        pub fn grow(self: *Self, len: usize) void {
            self.len = @max(self.len, len);
        }

        pub inline fn get(self: Self, index: usize) Element {
            return self.getPtr(index).*;
        }

        pub inline fn getPtr(self: Self, index: usize) *const Element {
            std.debug.assert(index < self.len);
            const page = self.leafPage(index) orelse return &initial;
            return &page.values[index % page_size];
        }

        inline fn leafPage(self: Self, index: usize) ?*Page {
            const root = self.root orelse return null;
            const page = index / page_size;
            return if (page < root.pages.len) root.pages[page] else null;
        }

        fn write(self: *Self, allocator: std.mem.Allocator, index: usize) !*Element {
            std.debug.assert(index < self.len);
            const pages = (self.len + page_size - 1) / page_size;
            if (self.root == null or !self.root.?.writable or self.root.?.pages.len < pages) {
                const root = try allocator.create(Root);
                root.* = .{ .pages = try allocator.alloc(?*Page, pages) };
                @memset(root.pages, null);
                if (self.root) |previous| {
                    @memcpy(root.pages[0..previous.pages.len], previous.pages);
                    for (root.pages) |maybe_page| if (maybe_page) |page| {
                        page.writable = false;
                    };
                }
                self.root = root;
            }
            const slot = &self.root.?.pages[index / page_size];
            if (slot.* == null or !slot.*.?.writable) {
                const page = try allocator.create(Page);
                page.* = .{ .values = if (slot.*) |previous| previous.values else @splat(initial) };
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

        /// The first index from `start` whose page `other` does not share.
        fn nextUnshared(self: Self, other: Self, start: usize) usize {
            var index = start;
            while (index < self.len and self.sharesPage(other, index)) index = self.pageEnd(index);
            return index;
        }

        pub fn eql(self: Self, other: Self) bool {
            if (self.len != other.len) return false;
            var index = self.nextUnshared(other, 0);
            while (index < self.len) : (index = self.nextUnshared(other, index + 1)) {
                if (!std.meta.eql(self.get(index), other.get(index))) return false;
            }
            return true;
        }

        pub fn merge(self: *Self, allocator: std.mem.Allocator, other: Self, comptime combine: fn (Element, Element) Element) !void {
            std.debug.assert(self.len == other.len);
            var index = self.nextUnshared(other, 0);
            while (index < self.len) : (index = self.nextUnshared(other, index + 1)) {
                try self.set(allocator, index, combine(self.get(index), other.get(index)));
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
    const first_value = first.getPtr(0);
    const default_value = first.getPtr(32);
    try live.set(allocator, 32, 7);
    var second = live.snapshot();
    try std.testing.expect(first.sharesPage(second, 0));
    try std.testing.expect(!first.sharesPage(second, 32));
    try std.testing.expectEqual(@as(?u32, null), first.get(32));
    live = first.snapshot();
    try std.testing.expectEqual(@as(?u32, null), live.get(32));
    try live.set(allocator, 0, 5);
    try second.set(allocator, 512, 11);
    try second.set(allocator, 0, 13);
    try std.testing.expectEqual(@as(?u32, 1), first.get(0));
    try std.testing.expectEqual(@as(?u32, 13), second.get(0));
    try std.testing.expectEqual(@as(?u32, 9), first.get(512));
    try std.testing.expectEqual(@as(?u32, 9), live.get(512));
    try std.testing.expectEqual(@as(?u32, 11), second.get(512));
    try std.testing.expectEqual(@as(?u32, 1), first_value.*);
    try std.testing.expectEqual(@as(?u32, null), default_value.*);
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

test "growing a snapshot preserves its earlier pages and independent lengths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = Buffer(u32, 0).init(1);
    try state.set(allocator, 0, 7);
    const before = state.snapshot();
    state.grow(100);
    try std.testing.expectEqual(0, state.get(99));
    try state.set(allocator, 99, 23);
    try std.testing.expectEqual(1, before.len);
    try std.testing.expectEqual(7, before.get(0));
    try std.testing.expect(state.sharesPage(before, 0));
    try state.set(allocator, 0, 11);
    try std.testing.expectEqual(7, before.get(0));
    try std.testing.expectEqual(11, state.get(0));
    try std.testing.expectEqual(23, state.get(99));
}
