const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const compaction = @import("compaction.zig");
const canonicalize = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;

pub fn promote(function: *Function) !void {
    const scratch = function.scratch;
    const graph = try Graph.init(scratch, function);
    const address_taken = try canonicalize.addressTaken(function);
    const slots = try promotableSlots(function, graph, address_taken);
    var undefined_values: [3]?ValueId = .{ null, null, null };
    for (slots) |slot| try promoteSlot(function, graph, slot, &undefined_values);
}

const Graph = struct {
    reachable: []const bool,
    order: []const u32,
    rank: []const u32,
    dominator: []const u32,
    frontier: []const std.ArrayList(u32),
    incoming: []const std.ArrayList(Incoming),

    const Incoming = struct { block: u32, branch: ?*structures.FunctionBranch };

    fn init(scratch: std.mem.Allocator, function: *Function) !Graph {
        const count = function.blocks.items.len;
        const reachable = try compaction.reachableBlocks(scratch, function);
        const incoming = try scratch.alloc(std.ArrayList(Incoming), count);
        @memset(incoming, .empty);
        for (function.blocks.items, 0..) |*block, index| {
            for (Function.edges(&block.terminator)) |maybe_edge| if (maybe_edge) |edge| {
                try incoming[@backingInt(Function.edgeTarget(edge))].append(scratch, .{
                    .block = @intCast(index),
                    .branch = if (edge == .branch) edge.branch else null,
                });
            };
        }
        const order = try postorder(scratch, function, reachable);
        std.mem.reverse(u32, order);
        const rank = try scratch.alloc(u32, count);
        for (order, 0..) |block, position| rank[block] = @intCast(position);
        const dominator = try dominators(scratch, order, rank, reachable, incoming);
        const frontier = try scratch.alloc(std.ArrayList(u32), count);
        @memset(frontier, .empty);
        for (order) |block| {
            var predecessors: usize = 0;
            for (incoming[block].items) |edge| {
                if (reachable[edge.block]) predecessors += 1;
            }
            if (predecessors < 2) continue;
            for (incoming[block].items) |edge| {
                if (!reachable[edge.block]) continue;
                var runner = edge.block;
                while (runner != dominator[block]) : (runner = dominator[runner]) {
                    if (std.mem.indexOfScalar(u32, frontier[runner].items, block) == null) try frontier[runner].append(scratch, block);
                }
            }
        }
        return .{ .reachable = reachable, .order = order, .rank = rank, .dominator = dominator, .frontier = frontier, .incoming = incoming };
    }

    fn successors(function: *Function, block: u32) [2]?u32 {
        var result: [2]?u32 = .{ null, null };
        for (Function.edges(&function.blocks.items[block].terminator), &result) |maybe_edge, *successor| {
            if (maybe_edge) |edge| successor.* = @backingInt(Function.edgeTarget(edge));
        }
        return result;
    }
};

fn postorder(scratch: std.mem.Allocator, function: *Function, reachable: []const bool) ![]u32 {
    var order: std.ArrayList(u32) = .empty;
    const visited = try scratch.alloc(bool, function.blocks.items.len);
    @memset(visited, false);
    const Frame = struct { block: u32, next: u2 };
    var stack: std.ArrayList(Frame) = .empty;
    const entry = @backingInt(function.body.entry);
    visited[entry] = true;
    try stack.append(scratch, .{ .block = entry, .next = 0 });
    while (stack.items.len != 0) {
        const frame = &stack.items[stack.items.len - 1];
        const successors = Graph.successors(function, frame.block);
        if (frame.next < 2) {
            const successor = successors[frame.next];
            frame.next += 1;
            if (successor) |target| if (!visited[target]) {
                std.debug.assert(reachable[target]);
                visited[target] = true;
                try stack.append(scratch, .{ .block = target, .next = 0 });
            };
            continue;
        }
        try order.append(scratch, frame.block);
        _ = stack.pop();
    }
    return order.items;
}

fn dominators(scratch: std.mem.Allocator, order: []const u32, rank: []const u32, reachable: []const bool, incoming: []const std.ArrayList(Graph.Incoming)) ![]u32 {
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
                if (!reachable[edge.block] or dominator[edge.block] == unset) continue;
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

const Slot = struct { storage: ValueId, instruction: u32, type_id: structures.TypeId };

const Access = union(enum) { load: ValueId, store: ValueId, none };

fn access(instruction: Instruction, slot: ValueId) Access {
    if (instruction != .value_copy) return .none;
    const copy = instruction.value_copy;
    if (copy.destination == null and copy.source == slot) return .{ .load = slot };
    if (copy.destination == slot and copy.source != slot) return .{ .store = copy.source };
    return .none;
}

const SlotScan = struct {
    candidate: []bool,
    allowed: []u32,

    fn disqualify(self: *SlotScan, value: ValueId) void {
        const index = @backingInt(value);
        if (self.allowed[index] != 0) {
            self.allowed[index] -= 1;
            return;
        }
        self.candidate[index] = false;
    }
};

fn terminatorReads(terminator: *structures.FunctionTerminator) [2]?*ValueId {
    return switch (terminator.*) {
        .predicate_branch => |*predicate| .{ &predicate.operands.lhs, &predicate.operands.rhs },
        .return_value => |*use| .{ if (use.coerce_to == null) &use.value else null, null },
        .branch, .fallible_call, .return_unit, .return_failure, .diverge => .{ null, null },
    };
}

fn promotableSlots(function: *Function, graph: Graph, address_taken: []const bool) ![]const Slot {
    const scratch = function.scratch;
    var scan: SlotScan = .{ .candidate = try scratch.alloc(bool, function.valueCount()), .allowed = try scratch.alloc(u32, function.valueCount()) };
    @memset(scan.candidate, false);
    @memset(scan.allowed, 0);
    for (function.blocks.items, graph.reachable) |block, kept| {
        if (!kept) continue;
        for (block.instructions.items) |index| {
            const instruction = function.instructions.items[index];
            if (!function.removed.items[index] and instruction == .local_storage and compaction.isScalar(instruction.local_storage))
                scan.candidate[@backingInt(function.results.items[index])] = true;
        }
    }
    const tables = function_ir.tableView(function);
    for (function.blocks.items, graph.reachable) |*block, kept| {
        if (!kept) continue;
        for (block.instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            if (instruction.* == .value_copy) {
                const copy = instruction.value_copy;
                const loaded = copy.destination == null and scan.candidate[@backingInt(copy.source)] and copy.type_id == function.valueType(copy.source) and !address_taken[@backingInt(function.results.items[index])];
                const stored = if (copy.destination) |destination| scan.candidate[@backingInt(destination)] and copy.type_id == function.valueType(destination) and function.plainValue(copy.source) and !address_taken[@backingInt(copy.source)] else false;
                if (loaded or stored) continue;
            }
            function_ir.visitInstructionReferences(tables, instruction, &scan, SlotScan.disqualify);
        }
        for (terminatorReads(&block.terminator)) |maybe_read| if (maybe_read) |read| {
            scan.allowed[@backingInt(read.*)] += 1;
        };
        function_ir.visitTerminatorReferences(tables, &block.terminator, &scan, SlotScan.disqualify);
    }
    var slots: std.ArrayList(Slot) = .empty;
    for (function.blocks.items, graph.reachable) |block, kept| {
        if (!kept) continue;
        for (block.instructions.items) |index| {
            const result = function.results.items[index];
            if (scan.candidate[@backingInt(result)])
                try slots.append(scratch, .{ .storage = result, .instruction = index, .type_id = function.instructions.items[index].local_storage });
        }
    }
    return slots.items;
}

fn promoteSlot(function: *Function, graph: Graph, slot: Slot, undefined_values: *[3]?ValueId) !void {
    const scratch = function.scratch;
    const count = function.blocks.items.len;
    const defines = try scratch.alloc(bool, count);
    const exposed = try scratch.alloc(bool, count);
    @memset(defines, false);
    @memset(exposed, false);
    for (graph.order) |block| {
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            switch (access(function.instructions.items[index], slot.storage)) {
                .load => if (!defines[block]) {
                    exposed[block] = true;
                },
                .store => defines[block] = true,
                .none => {},
            }
        }
        for (terminatorReads(&function.blocks.items[block].terminator)) |maybe_read| if (maybe_read) |read| {
            if (read.* == slot.storage and !defines[block]) exposed[block] = true;
        };
    }
    const live_in = try scratch.dupe(bool, exposed);
    var changed = true;
    while (changed) {
        changed = false;
        var position = graph.order.len;
        while (position > 0) {
            position -= 1;
            const block = graph.order[position];
            if (live_in[block] or defines[block]) continue;
            for (Graph.successors(function, block)) |successor| if (successor) |target| if (live_in[target]) {
                live_in[block] = true;
                changed = true;
            };
        }
    }

    const merges = try scratch.alloc(bool, count);
    @memset(merges, false);
    var pending: std.ArrayList(u32) = .empty;
    for (graph.order) |block| if (defines[block]) try pending.append(scratch, block);
    while (pending.pop()) |block| for (graph.frontier[block].items) |frontier| {
        if (merges[frontier] or !live_in[frontier]) continue;
        for (graph.incoming[frontier].items) |edge| {
            if (graph.reachable[edge.block] and edge.branch == null) return;
        }
        merges[frontier] = true;
        if (!defines[frontier]) try pending.append(scratch, frontier);
    };

    const parameters = try scratch.alloc(?ValueId, count);
    @memset(parameters, null);
    for (graph.order) |block| if (merges[block]) {
        parameters[block] = try function.addParameter(block, .{ .type_id = slot.type_id });
    };
    const outgoing = try scratch.alloc(?ValueId, count);
    @memset(outgoing, null);
    const entry = @backingInt(function.body.entry);
    for (graph.order) |block| {
        var current: ValueId = if (parameters[block]) |parameter|
            parameter
        else if (block == entry)
            try undefinedValue(function, slot, undefined_values)
        else
            outgoing[graph.dominator[block]].?;
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            switch (access(function.instructions.items[index], slot.storage)) {
                .load => {
                    function.replace(function.results.items[index], current);
                    function.removed.items[index] = true;
                },
                .store => |stored| {
                    current = function.find(stored);
                    function.removed.items[index] = true;
                },
                .none => {},
            }
        }
        for (terminatorReads(&function.blocks.items[block].terminator)) |maybe_read| if (maybe_read) |read| {
            if (read.* == slot.storage) read.* = current;
        };
        outgoing[block] = current;
    }
    for (0..count) |block| if (merges[block]) {
        for (graph.incoming[block].items) |edge| {
            const branch = edge.branch orelse continue;
            const value = if (graph.reachable[edge.block]) outgoing[edge.block].? else try undefinedValue(function, slot, undefined_values);
            try function.appendBranchArgument(branch, value);
        }
    };
    function.removed.items[slot.instruction] = true;
}

fn undefinedValue(function: *Function, slot: Slot, cache: *[3]?ValueId) !ValueId {
    const index: usize = switch (slot.type_id) {
        .int => 0,
        .bool => 1,
        .byte => 2,
        else => unreachable,
    };
    if (cache[index]) |value| return value;
    const instruction: Instruction = switch (slot.type_id) {
        .int => .{ .const_int = 0 },
        .bool => .{ .const_bool = false },
        .byte => .{ .const_byte = 0 },
        else => unreachable,
    };
    const span = if (function.publishesSpans()) function.spans.items[slot.instruction] else structures.SourceSpan{ .start = 0, .end = 0 };
    const value = try function.insertInstruction(@backingInt(function.body.entry), 0, instruction, span);
    cache[index] = value;
    return value;
}
