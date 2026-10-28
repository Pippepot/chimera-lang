const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const graph_ir = @import("graph.zig");
const value_rules = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const Function = function_ir.Function;
const Graph = graph_ir.Graph;

pub const Loop = struct {
    header: u32,
    members: []bool,
    blocks: []const u32,
    latches: []const u32,
    depth: u32 = 1,

    pub fn contains(self: Loop, block: u32) bool {
        return block < self.members.len and self.members[block];
    }
};

pub fn find(scratch: std.mem.Allocator, function: *Function, graph: Graph) ![]Loop {
    const count = function.blocks.items.len;
    var loops: std.ArrayList(Loop) = .empty;
    for (graph.order) |header| {
        var latches: std.ArrayList(u32) = .empty;
        for (graph.incoming[header].items) |edge| {
            if (graph.dominates(header, edge.block)) try latches.append(scratch, edge.block);
        }
        if (latches.items.len == 0) continue;
        const members = try scratch.alloc(bool, count);
        @memset(members, false);
        members[header] = true;
        var blocks: std.ArrayList(u32) = .empty;
        try blocks.append(scratch, header);
        var pending: std.ArrayList(u32) = .empty;
        for (latches.items) |latch| if (!members[latch]) {
            members[latch] = true;
            try blocks.append(scratch, latch);
            try pending.append(scratch, latch);
        };
        while (pending.pop()) |block| for (graph.incoming[block].items) |edge| {
            if (members[edge.block]) continue;
            members[edge.block] = true;
            try blocks.append(scratch, edge.block);
            try pending.append(scratch, edge.block);
        };
        std.mem.sort(u32, blocks.items, graph.rank, byRank);
        try loops.append(scratch, .{ .header = header, .members = members, .blocks = blocks.items, .latches = latches.items });
    }
    for (loops.items) |*loop| {
        for (loops.items) |other| {
            if (other.header != loop.header and other.contains(loop.header)) loop.depth += 1;
        }
    }
    std.mem.sort(Loop, loops.items, {}, deeperFirst);
    return loops.items;
}

fn byRank(rank: []const u32, left: u32, right: u32) bool {
    return rank[left] < rank[right];
}

fn deeperFirst(_: void, left: Loop, right: Loop) bool {
    return left.depth > right.depth;
}

pub fn canonicalize(function: *Function) !bool {
    const scratch = function.scratch;
    const graph = (try function.controlFlow()).*;
    const loops = try find(scratch, function, graph);
    var changed = false;
    for (loops) |loop| {
        if (try insertPreheader(function, graph, loop)) changed = true;
        if (changed) return true;
        if (try mergeLatches(function, loop)) return true;
    }
    return changed;
}

pub fn preheader(function: *Function, graph: Graph, loop: Loop) ?u32 {
    var outside: ?u32 = null;
    for (graph.incoming[loop.header].items) |edge| {
        if (loop.contains(edge.block)) continue;
        if (outside != null) return null;
        outside = edge.block;
    }
    const block = outside orelse return null;
    if (function.blocks.items[block].terminator != .branch) return null;
    return block;
}

fn insertPreheader(function: *Function, graph: Graph, loop: Loop) !bool {
    if (preheader(function, graph, loop) != null) return false;
    var outside: std.ArrayList(graph_ir.Incoming) = .empty;
    for (graph.incoming[loop.header].items) |edge| {
        if (loop.contains(edge.block)) continue;
        try outside.append(function.scratch, edge);
    }
    if (outside.items.len == 0) return false;
    const taken = try value_rules.addressTaken(function);
    const header = &function.blocks.items[loop.header];
    const block = try function.addBlock(.diverge, header.span, header.frame);
    var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (function.blocks.items[loop.header].parameters.items, 0..) |parameter, position| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        const first = function.branchArguments(outside.items[0].branch(function).*)[position];
        const value = function.find(first.value);
        if (data.representation == .value and function.direct(data.type_id) and function.plainValue(value) and !taken[@backingInt(value)] and first.coerce_to == null) {
            for (outside.items[1..]) |edge| {
                const argument = function.branchArguments(edge.branch(function).*)[position];
                if (argument.coerce_to != null or function.find(argument.value) != value) break;
            } else {
                try arguments.append(function.scratch, .{ .value = value });
                continue;
            }
        }
        try arguments.append(function.scratch, .{ .value = try function.addParameter(block, data) });
    }
    function.blocks.items[block].terminator = .{ .branch = .{ .target = @fromBackingInt(loop.header), .arguments = try function.appendBranchArguments(arguments.items) } };
    for (outside.items) |edge| {
        const branch = edge.branch(function);
        const original = function.branchArguments(branch.*);
        var forwarded: std.ArrayList(structures.FunctionValueUse) = .empty;
        for (arguments.items, original) |argument, incoming| {
            const definition = function.definitions.items[@backingInt(argument.value)];
            if (definition == .argument and definition.argument.block == block) try forwarded.append(function.scratch, incoming);
        }
        branch.* = .{ .target = @fromBackingInt(block), .arguments = try function.appendBranchArguments(forwarded.items) };
    }
    const position = std.mem.indexOfScalar(u32, function.order.items, loop.header).?;
    try function.order.insert(function.scratch, position, block);
    return true;
}

fn mergeLatches(function: *Function, loop: Loop) !bool {
    if (loop.latches.len < 2) return false;
    var back: std.ArrayList(graph_ir.Incoming) = .empty;
    for (loop.latches) |latch| {
        for (Function.edges(&function.blocks.items[latch].terminator), 0..) |maybe_edge, ordinal| if (maybe_edge) |edge| {
            if (@backingInt(Function.edgeTarget(edge)) != loop.header) continue;
            try back.append(function.scratch, .{ .block = latch, .ordinal = @intCast(ordinal) });
        };
    }
    const header = &function.blocks.items[loop.header];
    const block = try function.addBlock(.diverge, header.span, header.frame);
    var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (function.blocks.items[loop.header].parameters.items) |parameter| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        try arguments.append(function.scratch, .{ .value = try function.addParameter(block, data) });
    }
    function.blocks.items[block].terminator = .{ .branch = .{ .target = @fromBackingInt(loop.header), .arguments = try function.appendBranchArguments(arguments.items) } };
    for (back.items) |edge| edge.branch(function).target = @fromBackingInt(block);
    try function.placeAfter(block, loop.latches[loop.latches.len - 1]);
    return true;
}

test "loop canonicalization preserves branch payloads when block storage relocates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var relocating = std.testing.FailingAllocator.init(arena.allocator(), .{ .resize_fail_index = 0 });
    const scratch = relocating.allocator();
    var function: Function = .{
        .scratch = scratch,
        .return_type = .int,
        .is_initializer_region = false,
        .parameter_modes = &.{},
        .publishes_spans = false,
        .root_instance = null,
        .entry = 0,
        .blocks = try std.ArrayList(function_ir.Block).initCapacity(scratch, 6),
        .branch_arguments = try std.ArrayList(structures.FunctionValueUse).initCapacity(scratch, 8),
    };
    for (0..6) |_| {
        const block = try function.addBlock(.diverge, .{ .start = 0, .end = 0 }, .root);
        try function.order.append(scratch, block);
    }
    const shared = try function.addParameter(0, .{ .type_id = .int });
    const varying = try function.addParameter(0, .{ .type_id = .int });
    const carried_shared = try function.addParameter(1, .{ .type_id = .int });
    const carried_varying = try function.addParameter(1, .{ .type_id = .int });
    const empty: structures.FunctionValueRange = .{ .start = 0, .end = 0 };
    function.blocks.items[0].terminator = .{ .predicate_branch = .{
        .operation = .lti,
        .operands = .{ .lhs = shared, .rhs = varying },
        .then_branch = .{ .target = @fromBackingInt(1), .arguments = try function.appendBranchArguments(&.{ .{ .value = shared }, .{ .value = varying } }) },
        .else_branch = .{ .target = @fromBackingInt(2), .arguments = empty },
    } };
    function.blocks.items[2].terminator = .{ .branch = .{
        .target = @fromBackingInt(1),
        .arguments = try function.appendBranchArguments(&.{ .{ .value = shared }, .{ .value = shared } }),
    } };
    function.blocks.items[1].terminator = .{ .predicate_branch = .{
        .operation = .lti,
        .operands = .{ .lhs = carried_shared, .rhs = carried_varying },
        .then_branch = .{ .target = @fromBackingInt(3), .arguments = empty },
        .else_branch = .{ .target = @fromBackingInt(5), .arguments = empty },
    } };
    function.blocks.items[3].terminator = .{ .predicate_branch = .{
        .operation = .lti,
        .operands = .{ .lhs = carried_shared, .rhs = carried_varying },
        .then_branch = .{ .target = @fromBackingInt(1), .arguments = try function.appendBranchArguments(&.{ .{ .value = carried_shared }, .{ .value = carried_varying } }) },
        .else_branch = .{ .target = @fromBackingInt(4), .arguments = empty },
    } };
    function.blocks.items[4].terminator = .{ .branch = .{
        .target = @fromBackingInt(1),
        .arguments = try function.appendBranchArguments(&.{ .{ .value = shared }, .{ .value = carried_shared } }),
    } };
    function.blocks.items[5].terminator = .{ .return_value = .{ .value = carried_shared } };
    const verifier = @import("verifier.zig");
    try verifier.verifyFunction(&function);
    const original_blocks = function.blocks.items.ptr;
    try std.testing.expect(try canonicalize(&function));
    try std.testing.expect(original_blocks != function.blocks.items.ptr);
    try std.testing.expectEqual(@as(usize, 7), function.blocks.items.len);
    const preheader_block = function.blocks.items[6];
    try std.testing.expectEqual(@as(usize, 1), preheader_block.parameters.items.len);
    try expectBranch(&function, preheader_block.terminator.branch, 1, &.{ .{ .value = shared }, .{ .value = preheader_block.parameters.items[0] } });
    try expectBranch(&function, function.blocks.items[0].terminator.predicate_branch.then_branch, 6, &.{.{ .value = varying }});
    try expectBranch(&function, function.blocks.items[2].terminator.branch, 6, &.{.{ .value = shared }});
    try expectBranch(&function, function.blocks.items[3].terminator.predicate_branch.then_branch, 1, &.{ .{ .value = carried_shared }, .{ .value = carried_varying } });
    try expectBranch(&function, function.blocks.items[4].terminator.branch, 1, &.{ .{ .value = shared }, .{ .value = carried_shared } });
    try verifier.verifyFunction(&function);
    try std.testing.expect(try graph_ir.dominatesUses(&function));

    try function.blocks.shrinkToLen(scratch);
    const preheader_blocks = function.blocks.items.ptr;
    try std.testing.expect(try canonicalize(&function));
    try std.testing.expect(preheader_blocks != function.blocks.items.ptr);
    try std.testing.expectEqual(@as(usize, 8), function.blocks.items.len);
    const latch = function.blocks.items[7];
    try std.testing.expectEqual(@as(usize, 2), latch.parameters.items.len);
    try expectBranch(&function, latch.terminator.branch, 1, &.{ .{ .value = latch.parameters.items[0] }, .{ .value = latch.parameters.items[1] } });
    try expectBranch(&function, function.blocks.items[3].terminator.predicate_branch.then_branch, 7, &.{ .{ .value = carried_shared }, .{ .value = carried_varying } });
    try expectBranch(&function, function.blocks.items[4].terminator.branch, 7, &.{ .{ .value = shared }, .{ .value = carried_shared } });
    try verifier.verifyFunction(&function);
    try std.testing.expect(try graph_ir.dominatesUses(&function));
    try std.testing.expect(!try canonicalize(&function));
}

fn expectBranch(function: *const Function, branch: structures.FunctionBranch, target: u32, arguments: []const structures.FunctionValueUse) !void {
    try std.testing.expectEqual(target, @backingInt(branch.target));
    const actual = function.branchArguments(branch);
    try std.testing.expectEqual(arguments.len, actual.len);
    for (arguments, actual) |expected, found| try std.testing.expectEqualDeep(expected, found);
}
