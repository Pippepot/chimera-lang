const std = @import("std");

pub fn ScopeStack(comptime T: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            name: []const u8,
            value: T,
        };

        entries: std.ArrayList(Entry),

        pub fn init() Self {
            return .{ .entries = .empty };
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.entries.deinit(gpa);
        }

        pub fn mark(self: *const Self) usize {
            return self.entries.items.len;
        }

        pub fn restore(self: *Self, mark_len: usize) void {
            self.entries.shrinkRetainingCapacity(mark_len);
        }

        fn find(self: *const Self, name: []const u8) ?usize {
            var i = self.entries.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, self.entries.items[i].name, name)) return i;
            }
            return null;
        }

        pub fn lookup(self: *const Self, name: []const u8) ?T {
            const i = self.find(name) orelse return null;
            return self.entries.items[i].value;
        }

        pub fn lookupPtr(self: *Self, name: []const u8) ?*T {
            const i = self.find(name) orelse return null;
            return &self.entries.items[i].value;
        }

        pub fn push(self: *Self, gpa: std.mem.Allocator, name: []const u8, value: T) !void {
            if (self.lookup(name) != null) return error.DuplicateVariable;
            try self.entries.append(gpa, .{ .name = name, .value = value });
        }
    };
}
