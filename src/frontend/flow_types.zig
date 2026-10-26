const std = @import("std");
const structures = @import("../structures.zig");
const flow_snapshot = @import("flow_snapshot.zig");

/// A snapshot contains only fact IDs. Records and snapshots borrow the body arena;
/// ordinary values and their declared storage types do not carry narrowed types.
pub const State = flow_snapshot.Buffer(u32, 0);

pub const Fact = struct {
    version: u32 = 0,
    type_id: ?structures.TypeId = null,
    span: structures.SourceSpan = .{ .start = 0, .end = 0 },
    previous: u32 = 0,
};

pub const Store = struct {
    records: std.ArrayList(Fact) = .empty,
    next_version: u32 = 1,

    pub fn get(self: *const Store, state: State, place: usize) Fact {
        return self.record(if (place < state.len) state.get(place) else 0);
    }

    pub fn record(self: *const Store, id: u32) Fact {
        return if (id == 0) .{} else self.records.items[id - 1];
    }

    pub fn put(self: *Store, allocator: std.mem.Allocator, state: *State, place: usize, fact: Fact) !void {
        state.grow(place + 1);
        const current = self.get(state.*, place);
        if (std.meta.eql(current, fact)) return;
        try self.records.append(allocator, fact);
        try state.set(allocator, place, @intCast(self.records.items.len));
    }

    pub fn version(self: *Store) !u32 {
        const result = self.next_version;
        self.next_version = std.math.add(u32, result, 1) catch return error.AnalysisTooLarge;
        return result;
    }

    pub fn invalidate(self: *Store, allocator: std.mem.Allocator, state: *State, place: usize, span: structures.SourceSpan) !void {
        const current = self.get(state.*, place);
        const previous = if (current.type_id != null) state.get(place) else current.previous;
        try self.put(allocator, state, place, .{ .version = try self.version(), .previous = previous, .span = span });
    }
};
