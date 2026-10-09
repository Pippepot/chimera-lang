const std = @import("std");
const structures = @import("structures.zig");

pub const Edge = struct {
    predecessor: structures.FunctionBlockId,
    successor: structures.FunctionBlockId,
    successor_ordinal: u2,
};

/// Borrows edge identities; parallel edges retain their own ordinals and payloads.
pub const Index = struct {
    const Block = struct {
        outgoing: [2]?usize = .{ null, null },
        first_incoming: ?usize = null,
    };
    blocks: []Block,
    previous_incoming: []?usize,

    pub fn init(allocator: std.mem.Allocator, block_count: usize, edges: anytype) !Index {
        const blocks = try allocator.alloc(Block, block_count);
        errdefer allocator.free(blocks);
        @memset(blocks, .{});
        const previous = try allocator.alloc(?usize, edges.len);
        for (edges, 0..) |edge, index| {
            const predecessor = &blocks[@backingInt(edge.predecessor)];
            std.debug.assert(predecessor.outgoing[edge.successor_ordinal] == null);
            predecessor.outgoing[edge.successor_ordinal] = index;
            const successor = &blocks[@backingInt(edge.successor)];
            previous[index] = successor.first_incoming;
            successor.first_incoming = index;
        }
        return .{ .blocks = blocks, .previous_incoming = previous };
    }

    pub fn deinit(self: Index, allocator: std.mem.Allocator) void {
        allocator.free(self.blocks);
        allocator.free(self.previous_incoming);
    }

    /// Steps publish their changed boundary fact; only its dependents become dirty.
    pub fn solve(self: Index, edges: anytype, reachable: []const bool, dirty: []bool, context: anytype, comptime backward: bool, comptime step: anytype) void {
        @memcpy(dirty, reachable);
        var changed = true;
        while (changed) {
            changed = false;
            for (0..self.blocks.len) |ordinal| {
                const block = if (backward) self.blocks.len - ordinal - 1 else ordinal;
                if (!dirty[block]) continue;
                dirty[block] = false;
                if (!step(context, block)) continue;
                changed = true;
                if (backward) {
                    var incoming = self.blocks[block].first_incoming;
                    while (incoming) |edge| : (incoming = self.previous_incoming[edge]) {
                        const predecessor = @backingInt(edges[edge].predecessor);
                        if (reachable[predecessor]) dirty[predecessor] = true;
                    }
                } else for (self.blocks[block].outgoing) |maybe_edge| {
                    const edge = maybe_edge orelse continue;
                    std.debug.assert(reachable[@backingInt(edges[edge].successor)]);
                    dirty[@backingInt(edges[edge].successor)] = true;
                }
            }
        }
    }
};

test "CFG index retains parallel predecessor edges and self loops" {
    const edges: []const Edge = &.{
        .{ .predecessor = @fromBackingInt(0), .successor = @fromBackingInt(1), .successor_ordinal = 0 },
        .{ .predecessor = @fromBackingInt(0), .successor = @fromBackingInt(1), .successor_ordinal = 1 },
        .{ .predecessor = @fromBackingInt(1), .successor = @fromBackingInt(1), .successor_ordinal = 0 },
    };
    const graph = try Index.init(std.testing.allocator, 3, edges);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?usize, 0), graph.blocks[0].outgoing[0]);
    try std.testing.expectEqual(@as(?usize, 1), graph.blocks[0].outgoing[1]);
    var incoming = graph.blocks[1].first_incoming;
    for ([_]usize{ 2, 1, 0 }) |expected| {
        try std.testing.expectEqual(@as(?usize, expected), incoming);
        incoming = graph.previous_incoming[incoming.?];
    }
    try std.testing.expect(incoming == null);
    try std.testing.expect(graph.blocks[2].first_incoming == null);
}
