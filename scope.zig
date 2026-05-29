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

        pub fn lookup(self: *const Self, name: []const u8) ?T {
            var idx = self.entries.items.len;
            while (idx > 0) {
                idx -= 1;
                const entry = self.entries.items[idx];
                if (std.mem.eql(u8, entry.name, name)) return entry.value;
            }
            return null;
        }

        pub fn push(self: *Self, gpa: std.mem.Allocator, name: []const u8, value: T) !void {
            if (self.lookup(name) != null) return error.DuplicateVariable;
            try self.entries.append(gpa, .{ .name = name, .value = value });
        }
    };
}
