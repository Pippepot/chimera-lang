const std = @import("std");

pub fn Snapshot(comptime Element: type, comptime page_size: usize) type {
    return struct {
        const Self = @This();
        pub const Page = struct {
            references: usize,
            values: [page_size]Element,
        };

        len: usize,
        storage: union(enum) {
            borrowed: []Element,
            contiguous: []Element,
            paged: []*Page,
        },

        pub fn borrowed(values: []Element) Self {
            return .{ .len = values.len, .storage = .{ .borrowed = values } };
        }

        pub fn retainedPages(self: Self) []*Page {
            return switch (self.storage) {
                .paged => |saved| saved,
                .borrowed, .contiguous => &.{},
            };
        }

        pub fn retainedBytes(self: Self) usize {
            return switch (self.storage) {
                .borrowed => 0,
                .contiguous => |values| std.mem.sliceAsBytes(values).len,
                .paged => |saved| std.mem.sliceAsBytes(saved).len,
            };
        }

        pub inline fn get(self: Self, index: usize) Element {
            std.debug.assert(index < self.len);
            return switch (self.storage) {
                .borrowed, .contiguous => |values| values[index],
                .paged => |saved| saved[index / page_size].values[index % page_size],
            };
        }

        pub fn set(self: Self, allocator: std.mem.Allocator, index: usize, value: Element) !void {
            std.debug.assert(index < self.len);
            switch (self.storage) {
                .borrowed, .contiguous => |values| {
                    values[index] = value;
                    return;
                },
                .paged => {},
            }
            if (std.meta.eql(self.get(index), value)) return;
            const page_slot = &self.storage.paged[index / page_size];
            if (page_slot.*.references != 1) {
                const replacement = try allocator.create(Page);
                replacement.* = page_slot.*.*;
                replacement.references = 1;
                page_slot.*.references -= 1;
                page_slot.* = replacement;
            }
            page_slot.*.values[index % page_size] = value;
        }

        pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
            return self.capture(allocator, null);
        }

        pub fn capture(self: Self, allocator: std.mem.Allocator, previous: ?Self) !Self {
            if (self.len <= page_size * 16) {
                const values = try allocator.alloc(Element, self.len);
                self.copyTo(values);
                return .{ .len = self.len, .storage = .{ .contiguous = values } };
            }
            const page_count = std.math.divCeil(usize, self.len, page_size) catch unreachable;
            const pages = try allocator.alloc(*Page, page_count);
            var initialized: usize = 0;
            errdefer {
                for (pages[0..initialized]) |page| release(allocator, page);
                allocator.free(pages);
            }
            for (pages, 0..) |*destination, page_index| {
                if (self.storage == .paged) {
                    destination.* = self.storage.paged[page_index];
                    destination.*.references += 1;
                } else {
                    const start = page_index * page_size;
                    const end = @min(self.len, start + page_size);
                    const values = switch (self.storage) {
                        .borrowed, .contiguous => |live| live[start..end],
                        .paged => unreachable,
                    };
                    var shared: ?*Page = null;
                    if (previous) |old| {
                        if (old.storage == .paged and old.len >= end and page_index < old.storage.paged.len) {
                            const candidate = old.storage.paged[page_index];
                            var equal = true;
                            for (values, candidate.values[0..values.len]) |current, saved| {
                                if (!std.meta.eql(current, saved)) {
                                    equal = false;
                                    break;
                                }
                            }
                            if (equal) shared = candidate;
                        }
                    }
                    if (shared) |page| {
                        destination.* = page;
                        page.references += 1;
                    } else {
                        const page = try allocator.create(Page);
                        page.references = 1;
                        @memcpy(page.values[0..values.len], values);
                        destination.* = page;
                    }
                }
                initialized += 1;
            }
            return .{ .len = self.len, .storage = .{ .paged = pages } };
        }

        pub fn copyTo(self: Self, destination: []Element) void {
            std.debug.assert(destination.len == self.len);
            switch (self.storage) {
                .borrowed, .contiguous => |values| {
                    @memcpy(destination, values[0..self.len]);
                    return;
                },
                .paged => {},
            }
            for (self.storage.paged, 0..) |page, page_index| {
                const start = page_index * page_size;
                const count = @min(page_size, self.len - start);
                @memcpy(destination[start..][0..count], page.values[0..count]);
            }
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            switch (self.storage) {
                .borrowed => unreachable,
                .contiguous => |values| allocator.free(values),
                .paged => |saved| {
                    for (saved) |page| release(allocator, page);
                    allocator.free(saved);
                },
            }
            self.* = undefined;
        }

        fn release(allocator: std.mem.Allocator, page: *Page) void {
            std.debug.assert(page.references != 0);
            page.references -= 1;
            if (page.references == 0) allocator.destroy(page);
        }
    };
}

test "flow snapshots share unchanged pages and isolate writes" {
    const Values = Snapshot(?u32, 2);
    const allocator = std.testing.allocator;
    var live: [33]?u32 = @splat(null);
    live[0..5].* = .{ 1, 2, 3, null, 5 };
    live[32] = 9;
    var first = try Values.borrowed(&live).clone(allocator);
    defer first.deinit(allocator);
    live[2] = 9;
    var second = try Values.borrowed(&live).capture(allocator, first);
    defer second.deinit(allocator);
    try std.testing.expect(first.retainedPages()[0] == second.retainedPages()[0]);
    try std.testing.expect(first.retainedPages()[1] != second.retainedPages()[1]);
    try std.testing.expect(first.retainedPages()[2] == second.retainedPages()[2]);
    try second.set(allocator, 0, 7);
    try std.testing.expectEqual(@as(?u32, 1), first.get(0));
    try std.testing.expectEqual(@as(?u32, 7), second.get(0));
    var restored: [33]?u32 = undefined;
    first.copyTo(&restored);
    live[2] = 3;
    try std.testing.expectEqualSlices(?u32, &live, &restored);
}

fn checkSnapshotAllocations(allocator: std.mem.Allocator) !void {
    const Values = Snapshot(?u32, 2);
    var live: [33]?u32 = @splat(null);
    live[0..5].* = .{ 1, 2, 3, null, 5 };
    live[32] = 9;
    var first = try Values.borrowed(&live).clone(allocator);
    defer first.deinit(allocator);
    var second = try first.clone(allocator);
    defer second.deinit(allocator);
    try second.set(allocator, 4, 9);
    live[2] = 7;
    var third = try Values.borrowed(&live).capture(allocator, second);
    defer third.deinit(allocator);
    try std.testing.expectEqual(@as(?u32, 5), first.get(4));
}

test "flow snapshots release every failed allocation" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSnapshotAllocations, .{});
}

test "small flow snapshots retain independent contiguous storage" {
    const Values = Snapshot(?u32, 2);
    const allocator = std.testing.allocator;
    var live = [_]?u32{ 1, null, 3 };
    var first = try Values.borrowed(&live).clone(allocator);
    defer first.deinit(allocator);
    var second = try first.clone(allocator);
    defer second.deinit(allocator);
    try second.set(allocator, 0, 7);
    try std.testing.expectEqual(@as(?u32, 1), first.get(0));
    try std.testing.expectEqual(@as(?u32, 7), second.get(0));
    try std.testing.expect(first.storage == .contiguous);
    try std.testing.expect(second.storage == .contiguous);
}
