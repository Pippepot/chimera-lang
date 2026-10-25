const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const Function = function_ir.Function;

pub const Incoming = struct {
    block: u32,
    ordinal: u1,

    pub fn branch(self: Incoming, function: *Function) *structures.FunctionBranch {
        return Function.edges(&function.blocks.items[self.block].terminator)[self.ordinal].?;
    }
};

pub const Graph = struct {
    reachable: []const bool,
    order: []const u32,
    rank: []const u32,
    dominator: []const u32 = &.{},
    subtree_start: []const u32 = &.{},
    subtree_end: []const u32 = &.{},
    first_child: []const u32 = &.{},
    next_sibling: []const u32 = &.{},
    frontier: ?[]const std.ArrayList(u32) = null,
    incoming: []const std.ArrayList(Incoming),

    pub fn init(scratch: std.mem.Allocator, function: *Function) !Graph {
        const count = function.blocks.items.len;
        const order = try reversePostorder(scratch, function);
        const reachable = try scratch.alloc(bool, count);
        @memset(reachable, false);
        for (order) |block| reachable[block] = true;
        const incoming = try scratch.alloc(std.ArrayList(Incoming), count);
        @memset(incoming, .empty);
        for (function.blocks.items, reachable, 0..) |*block, kept, index| {
            if (!kept) continue;
            for (Function.edges(&block.terminator), 0..) |maybe_edge, ordinal| if (maybe_edge) |edge| {
                try incoming[@backingInt(Function.edgeTarget(edge))].append(scratch, .{
                    .block = @intCast(index),
                    .ordinal = @intCast(ordinal),
                });
            };
        }
        const rank = try scratch.alloc(u32, count);
        @memset(rank, std.math.maxInt(u32));
        for (order, 0..) |block, position| rank[block] = @intCast(position);
        return .{ .reachable = reachable, .order = order, .rank = rank, .incoming = incoming };
    }

    pub fn analyzeDominance(self: *Graph, scratch: std.mem.Allocator) !void {
        if (self.dominator.len != 0) return;
        const count = self.reachable.len;
        const order = self.order;
        const dominator = try dominators(scratch, order, self.rank, self.incoming);
        const first_child = try scratch.alloc(u32, count);
        const next_sibling = try scratch.alloc(u32, count);
        const subtree_size = try scratch.alloc(u32, count);
        const subtree_start = try scratch.alloc(u32, count);
        const subtree_end = try scratch.alloc(u32, count);
        const unset = std.math.maxInt(u32);
        @memset(first_child, unset);
        @memset(subtree_size, 1);
        @memset(subtree_start, unset);
        @memset(subtree_end, unset);
        var position = order.len;
        while (position > 1) {
            position -= 1;
            const block = order[position];
            const parent = dominator[block];
            subtree_size[parent] += subtree_size[block];
            next_sibling[block] = first_child[parent];
            first_child[parent] = block;
        }
        const pending = try scratch.alloc(u32, order.len);
        pending[0] = order[0];
        var pending_count: usize = 1;
        var clock: u32 = 0;
        while (pending_count != 0) {
            pending_count -= 1;
            const block = pending[pending_count];
            subtree_start[block] = clock;
            subtree_end[block] = clock + subtree_size[block];
            clock += 1;
            var child = first_child[block];
            while (child != unset) : (child = next_sibling[child]) {
                pending[pending_count] = child;
                pending_count += 1;
            }
        }
        self.dominator = dominator;
        self.subtree_start = subtree_start;
        self.subtree_end = subtree_end;
        self.first_child = first_child;
        self.next_sibling = next_sibling;
    }

    pub fn dominanceFrontiers(self: *Graph, scratch: std.mem.Allocator) ![]const std.ArrayList(u32) {
        if (self.frontier) |frontier| return frontier;
        try self.analyzeDominance(scratch);
        const frontier = try scratch.alloc(std.ArrayList(u32), self.reachable.len);
        @memset(frontier, .empty);
        for (self.order) |block| {
            if (self.incoming[block].items.len < 2) continue;
            for (self.incoming[block].items) |edge| {
                var runner = edge.block;
                while (runner != self.dominator[block]) : (runner = self.dominator[runner]) {
                    if (std.mem.indexOfScalar(u32, frontier[runner].items, block) == null) try frontier[runner].append(scratch, block);
                }
            }
        }
        self.frontier = frontier;
        return frontier;
    }

    pub fn dominates(self: Graph, dominator: u32, block: u32) bool {
        return self.subtree_start[dominator] <= self.subtree_start[block] and self.subtree_start[block] < self.subtree_end[dominator];
    }
};

pub fn reversePostorder(scratch: std.mem.Allocator, function: *Function) ![]u32 {
    var order: std.ArrayList(u32) = .empty;
    const visited = try scratch.alloc(bool, function.blocks.items.len);
    @memset(visited, false);
    const Frame = struct { block: u32, next: u2 };
    var stack: std.ArrayList(Frame) = .empty;
    visited[function.entry] = true;
    try stack.append(scratch, .{ .block = function.entry, .next = 0 });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const successors = function.successors(frame.block);
        if (frame.next < 2) {
            const successor = successors[frame.next];
            frame.next += 1;
            if (successor) |target| if (!visited[target]) {
                visited[target] = true;
                try stack.append(scratch, .{ .block = target, .next = 0 });
            };
            continue;
        }
        try order.append(scratch, frame.block);
        _ = stack.pop();
    }
    std.mem.reverse(u32, order.items);
    return order.items;
}

fn dominators(scratch: std.mem.Allocator, order: []const u32, rank: []const u32, incoming: []const std.ArrayList(Incoming)) ![]u32 {
    const unset = std.math.maxInt(u32);
    const dominator = try scratch.alloc(u32, rank.len);
    @memset(dominator, unset);
    dominator[order[0]] = order[0];
    var changed = true;
    while (changed) {
        changed = false;
        for (order[1..]) |block| {
            var candidate: u32 = unset;
            for (incoming[block].items) |edge| {
                if (dominator[edge.block] == unset) continue;
                candidate = if (candidate == unset) edge.block else intersect(dominator, rank, edge.block, candidate);
            }
            if (candidate != dominator[block]) {
                dominator[block] = candidate;
                changed = true;
            }
        }
    }
    return dominator;
}

fn intersect(dominator: []const u32, rank: []const u32, first: u32, second: u32) u32 {
    var left = first;
    var right = second;
    while (left != right) {
        while (rank[left] > rank[right]) left = dominator[left];
        while (rank[right] > rank[left]) right = dominator[right];
    }
    return left;
}

const Uses = struct {
    function: *Function,
    graph: *const Graph,
    owner: []const u32,
    site: u32 = 0,
    sound: bool = true,

    fn check(self: *Uses, value: structures.FunctionValueId) void {
        const block = switch (self.function.definitions.items[@backingInt(self.function.find(value))]) {
            .argument => |argument| argument.block,
            .instruction => |index| self.owner[index],
        };
        if (block == std.math.maxInt(u32) or !self.graph.reachable[block] or !self.graph.dominates(block, self.site)) self.sound = false;
    }
};

pub fn dominatesUses(function: *Function) !bool {
    const scratch = function.scratch;
    const graph = (try function.controlFlow()).*;
    const owner = try scratch.alloc(u32, function.instructions.items.len);
    @memset(owner, std.math.maxInt(u32));
    for (function.blocks.items, 0..) |block, index| for (block.instructions.items) |instruction| {
        if (!function.removed.items[instruction]) owner[instruction] = @intCast(index);
    };
    var uses: Uses = .{ .function = function, .graph = &graph, .owner = owner };
    const tables = function_ir.tableView(function);
    for (graph.order) |block| {
        uses.site = block;
        for (function.blocks.items[block].instructions.items) |index| {
            if (!function.removed.items[index]) function_ir.visitInstructionReferences(tables, &function.instructions.items[index], &uses, Uses.check);
        }
        function_ir.visitTerminatorReferences(tables, &function.blocks.items[block].terminator, &uses, Uses.check);
    }
    return uses.sound;
}

test "optimizer graph reuses analysis and computes reachable dominance intervals" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var function: Function = .{
        .scratch = arena.allocator(),
        .return_type = .unit,
        .is_initializer_region = false,
        .parameter_modes = &.{},
        .publishes_spans = false,
        .root_instance = null,
        .entry = 2,
    };
    const span: structures.SourceSpan = .{ .start = 0, .end = 0 };
    for (0..6) |_| {
        _ = try function.addBlock(.return_unit, span, .root);
    }
    function.blocks.items[2].terminator = .{ .predicate_branch = .{
        .operation = .eqi,
        .operands = .{ .lhs = @fromBackingInt(0), .rhs = @fromBackingInt(0) },
        .then_branch = .{ .target = @fromBackingInt(1), .arguments = .{ .start = 0, .end = 0 } },
        .else_branch = .{ .target = @fromBackingInt(3), .arguments = .{ .start = 0, .end = 0 } },
    } };
    for ([_]u32{ 1, 3, 5 }) |block| function.blocks.items[block].terminator = .{ .branch = .{
        .target = @fromBackingInt(4),
        .arguments = .{ .start = 0, .end = 0 },
    } };
    function.blocks.items[4].terminator = .{ .branch = .{ .target = @fromBackingInt(5), .arguments = .{ .start = 0, .end = 0 } } };
    const topology = try function.controlFlowEdges();
    try testing.expectEqual(@as(usize, 0), topology.dominator.len);
    const graph = try function.controlFlow();
    const order = graph.order;
    try testing.expect(graph.frontier == null);
    for (0..6) |dominator| for (0..6) |block| {
        var expected = false;
        if (graph.reachable[dominator] and graph.reachable[block]) {
            var current: u32 = @intCast(block);
            while (true) {
                if (current == dominator) expected = true;
                if (graph.dominator[current] == current) break;
                current = graph.dominator[current];
            }
        }
        try testing.expectEqual(expected, graph.dominates(@intCast(dominator), @intCast(block)));
    };
    _ = try function.insertInstruction(2, 0, .{ .const_int = 0 }, span, .root);
    try testing.expectEqual(order.ptr, (try function.controlFlow()).order.ptr);
    const frontiers = try graph.dominanceFrontiers(function.scratch);
    try testing.expectEqualSlices(u32, &.{4}, frontiers[1].items);
    try testing.expectEqual(frontiers.ptr, (try graph.dominanceFrontiers(function.scratch)).ptr);
    const edge = graph.incoming[4].items[0];
    const added = try function.addBlock(.{ .branch = .{ .target = @fromBackingInt(4), .arguments = .{ .start = 0, .end = 0 } } }, span, .root);
    try testing.expect(function.control_flow == null);
    try testing.expectEqual(@as(u32, 4), @backingInt(edge.branch(&function).target));
    function.blocks.items[3].terminator.branch.target = @fromBackingInt(added);
    const rebuilt = try function.controlFlow();
    try testing.expect(order.ptr != rebuilt.order.ptr);
    try testing.expect(rebuilt.reachable[added]);
    try testing.expect(!rebuilt.dominates(4, added));
}
