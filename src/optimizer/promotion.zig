const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const compaction = @import("compaction.zig");
const canonicalize = @import("canonicalize.zig");
const Graph = @import("graph.zig").Graph;

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;

pub fn promote(function: *Function) !bool {
    const scratch = function.scratch;
    var has_candidates = false;
    for (function.instructions.items, function.removed.items) |instruction, removed| {
        if (!removed and instruction == .local_storage and function.direct(instruction.local_storage)) {
            has_candidates = true;
            break;
        }
    }
    if (!has_candidates) return false;
    function.resolveReferences();
    const graph = (try function.controlFlowEdges()).*;
    const slots = try collectSlots(function, graph);
    if (slots.len == 0) return false;
    const address_taken = try canonicalize.addressTaken(function);
    var undefined_values: [3]?ValueId = .{ null, null, null };
    var shared_slots: std.ArrayList(Slot) = .empty;
    var shared_uses: std.ArrayList(std.ArrayList(Site)) = .empty;
    var changed = false;
    for (slots) |slot| {
        const sites = slot.uses;
        if (localSites(sites.items)) {
            if (try promoteLocal(function, address_taken, slot, sites.items, &undefined_values)) changed = true;
        } else {
            try shared_slots.append(scratch, slot);
            try shared_uses.append(scratch, sites);
        }
    }
    if (shared_slots.items.len != 0 and try promoteShared(function, address_taken, shared_slots.items, shared_uses.items, &undefined_values)) changed = true;
    if (changed) function.invalidateOperands();
    return changed;
}

const Slot = struct {
    storage: ValueId,
    instruction: u32,
    type_id: structures.TypeId,
    references: u32 = 0,
    accepted: u32 = 0,
    uses: std.ArrayList(Site) = .empty,
};

const Site = struct { block: u32, instruction: ?u32 };

const Scan = struct {
    allocator: std.mem.Allocator,
    mapping: []const ?u32,
    slots: []Slot,
    site: Site,
    failed: bool = false,

    fn accept(self: *Scan, operand: *ValueId) void {
        const index = self.mapping[@backingInt(operand.*)] orelse return;
        const slot = &self.slots[index];
        slot.accepted += 1;
        const sites = &slot.uses;
        if (sites.items.len != 0 and std.meta.eql(sites.items[sites.items.len - 1], self.site)) return;
        sites.append(self.allocator, self.site) catch {
            self.failed = true;
        };
    }

    fn reference(self: *Scan, value: ValueId) void {
        const index = self.mapping[@backingInt(value)] orelse return;
        self.slots[index].references += 1;
    }
};

fn collectSlots(function: *Function, graph: Graph) ![]const Slot {
    const scratch = function.scratch;
    const mapping = try scratch.alloc(?u32, function.valueCount());
    @memset(mapping, null);
    var slots: std.ArrayList(Slot) = .empty;
    for (graph.order) |block| for (function.blocks.items[block].instructions.items) |index| {
        if (function.removed.items[index]) continue;
        const instruction = function.instructions.items[index];
        if (instruction != .local_storage or !function.direct(instruction.local_storage)) continue;
        const storage = function.results.items[index];
        mapping[@backingInt(storage)] = @intCast(slots.items.len);
        try slots.append(scratch, .{ .storage = storage, .instruction = index, .type_id = instruction.local_storage });
    };
    var scan: Scan = .{ .allocator = scratch, .mapping = mapping, .slots = slots.items, .site = undefined };
    const tables = function_ir.tableView(function);
    for (graph.order) |block_index| {
        const block = &function.blocks.items[block_index];
        for (block.instructions.items) |index| {
            if (function.removed.items[index]) continue;
            scan.site = .{ .block = block_index, .instruction = index };
            const instruction = &function.instructions.items[index];
            function_ir.visitInstructionReferences(tables, instruction, &scan, Scan.reference);
            if (instruction.* == .value_copy) if (instruction.value_copy.destination) |destination| {
                if (destination != instruction.value_copy.source and instruction.value_copy.type_id == function.valueType(destination)) {
                    var storage = destination;
                    scan.accept(&storage);
                }
            };
            function_ir.readOperands(function, instruction, &scan, Scan.accept);
        }
        scan.site = .{ .block = block_index, .instruction = null };
        function_ir.visitTerminatorReferences(tables, &block.terminator, &scan, Scan.reference);
        function_ir.terminatorReadOperands(function, &block.terminator, &scan, Scan.accept);
    }
    if (scan.failed) return error.OutOfMemory;
    var kept: usize = 0;
    for (slots.items) |slot| if (slot.accepted == slot.references) {
        slots.items[kept] = slot;
        kept += 1;
    };
    slots.shrinkRetainingCapacity(kept);
    return slots.items;
}

fn storedValue(instruction: Instruction, slot: ValueId) ?ValueId {
    if (instruction != .value_copy) return null;
    const copy = instruction.value_copy;
    if (copy.destination != slot or copy.source == slot) return null;
    return copy.source;
}

const Rewrite = struct {
    slot: ValueId,
    current: ValueId,
    reads: bool = false,

    fn substitute(self: *Rewrite, operand: *ValueId) void {
        if (operand.* != self.slot) return;
        operand.* = self.current;
    }

    fn observe(self: *Rewrite, operand: *ValueId) void {
        if (operand.* == self.slot) self.reads = true;
    }
};

fn localSites(sites: []const Site) bool {
    if (sites.len == 0) return true;
    for (sites) |site| if (site.block != sites[0].block) return false;
    return true;
}

fn promoteLocal(function: *Function, address_taken: []const bool, slot: Slot, sites: []const Site, undefined_values: *[3]?ValueId) !bool {
    var rewrite: Rewrite = .{ .slot = slot.storage, .current = slot.storage };
    if (sites.len != 0) {
        const stored_first = if (sites[0].instruction) |index| storedValue(function.instructions.items[index], slot.storage) != null else false;
        if (!stored_first) {
            if (!compaction.isScalar(slot.type_id)) return false;
            rewrite.current = try undefinedValue(function, slot, undefined_values);
        }
    }
    for (sites) |site| rewriteSite(function, address_taken, slot, site, &rewrite);
    function.removed.items[slot.instruction] = true;
    return true;
}

const SlotBits = struct {
    words: usize,
    bits: []u64,

    fn init(scratch: std.mem.Allocator, blocks: usize, slots: usize) !SlotBits {
        const words = std.math.divCeil(usize, slots, 64) catch unreachable;
        const bits = try scratch.alloc(u64, blocks * words);
        @memset(bits, 0);
        return .{ .words = words, .bits = bits };
    }

    fn row(self: SlotBits, block: u32) []u64 {
        return self.bits[@as(usize, block) * self.words ..][0..self.words];
    }

    fn contains(self: SlotBits, block: u32, slot: usize) bool {
        return self.row(block)[slot / 64] & (@as(u64, 1) << @as(u6, @intCast(slot % 64))) != 0;
    }

    fn insert(self: SlotBits, block: u32, slot: usize) bool {
        const word = &self.row(block)[slot / 64];
        const mask = @as(u64, 1) << @as(u6, @intCast(slot % 64));
        const fresh = word.* & mask == 0;
        word.* |= mask;
        return fresh;
    }
};

const Phi = struct { slot: u32, value: ValueId };

const Renaming = struct {
    function: *Function,
    mapping: []const ?u32,
    enabled: []const bool,
    current: []ValueId,
    undo: std.ArrayList(struct { slot: u32, value: ValueId }) = .empty,

    fn substitute(self: *Renaming, operand: *ValueId) void {
        if (@backingInt(operand.*) >= self.mapping.len) return;
        const slot = self.mapping[@backingInt(operand.*)] orelse return;
        if (self.enabled[slot]) operand.* = self.current[slot];
    }

    fn set(self: *Renaming, slot: u32, value: ValueId) !void {
        try self.undo.append(self.function.scratch, .{ .slot = slot, .value = self.current[slot] });
        self.current[slot] = value;
    }

    fn restore(self: *Renaming, position: usize) void {
        while (self.undo.items.len > position) {
            const previous = self.undo.pop().?;
            self.current[previous.slot] = previous.value;
        }
    }
};

fn promoteShared(function: *Function, address_taken: []const bool, slots: []const Slot, uses: []const std.ArrayList(Site), undefined_values: *[3]?ValueId) !bool {
    const scratch = function.scratch;
    const graph = (try function.controlFlow()).*;
    const count = function.blocks.items.len;
    const defines = try SlotBits.init(scratch, count, slots.len);
    const live_in = try SlotBits.init(scratch, count, slots.len);
    const merges = try SlotBits.init(scratch, count, slots.len);
    const definitions = try scratch.alloc(std.ArrayList(u32), slots.len);
    @memset(definitions, .empty);
    for (slots, uses, 0..) |slot, sites, slot_index| {
        for (sites.items) |site| {
            var observer: Rewrite = .{ .slot = slot.storage, .current = slot.storage };
            if (site.instruction) |index| {
                if (function.removed.items[index]) continue;
                function_ir.readOperands(function, &function.instructions.items[index], &observer, Rewrite.observe);
                if (observer.reads and !defines.contains(site.block, slot_index)) _ = live_in.insert(site.block, slot_index);
                if (storedValue(function.instructions.items[index], slot.storage) != null and defines.insert(site.block, slot_index))
                    try definitions[slot_index].append(scratch, site.block);
            } else {
                function_ir.terminatorReadOperands(function, &function.blocks.items[site.block].terminator, &observer, Rewrite.observe);
                if (observer.reads and !defines.contains(site.block, slot_index)) _ = live_in.insert(site.block, slot_index);
            }
        }
    }
    var pending: std.ArrayList(u32) = .empty;
    const queued = try scratch.alloc(bool, count);
    @memset(queued, false);
    for (graph.order) |block| for (live_in.row(block)) |word| {
        if (word == 0) continue;
        try pending.append(scratch, block);
        queued[block] = true;
        break;
    };
    while (pending.pop()) |block| {
        queued[block] = false;
        for (graph.incoming[block].items) |edge| {
            var changed = false;
            for (live_in.row(edge.block), live_in.row(block), defines.row(edge.block)) |*before, after, defined| {
                const combined = before.* | (after & ~defined);
                changed = changed or combined != before.*;
                before.* = combined;
            }
            if (changed and !queued[edge.block]) {
                try pending.append(scratch, edge.block);
                queued[edge.block] = true;
            }
        }
    }
    const enabled = try scratch.alloc(bool, slots.len);
    const frontiers = try (try function.controlFlow()).dominanceFrontiers(scratch);
    for (slots, definitions, 0..) |slot, blocks, slot_index| {
        enabled[slot_index] = !live_in.contains(function.entry, slot_index) or compaction.isScalar(slot.type_id);
        if (!enabled[slot_index]) continue;
        pending.clearRetainingCapacity();
        try pending.appendSlice(scratch, blocks.items);
        while (pending.pop()) |block| for (frontiers[block].items) |frontier| {
            if (merges.contains(frontier, slot_index) or !live_in.contains(frontier, slot_index)) continue;
            _ = merges.insert(frontier, slot_index);
            if (!defines.contains(frontier, slot_index)) try pending.append(scratch, frontier);
        };
    }
    const phis = try scratch.alloc(std.ArrayList(Phi), count);
    @memset(phis, .empty);
    for (graph.order) |block| {
        for (merges.row(block), 0..) |word, word_index| {
            var remaining = word;
            while (remaining != 0) {
                const slot_index = word_index * 64 + @ctz(remaining);
                remaining &= remaining - 1;
                if (!enabled[slot_index]) continue;
                try phis[block].append(scratch, .{ .slot = @intCast(slot_index), .value = try function.addParameter(block, .{ .type_id = slots[slot_index].type_id }) });
            }
        }
    }
    const mapping = try scratch.alloc(?u32, function.valueCount());
    @memset(mapping, null);
    var rename: Renaming = .{ .function = function, .mapping = mapping, .enabled = enabled, .current = try scratch.alloc(ValueId, slots.len) };
    var changed = false;
    for (slots, enabled, 0..) |slot, active, slot_index| {
        rename.current[slot_index] = slot.storage;
        if (!active) continue;
        mapping[@backingInt(slot.storage)] = @intCast(slot_index);
        if (live_in.contains(function.entry, slot_index)) rename.current[slot_index] = try undefinedValue(function, slot, undefined_values);
        function.removed.items[slot.instruction] = true;
        changed = true;
    }
    const Frame = struct { block: u32, restore: ?usize = null };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(scratch, .{ .block = function.entry });
    while (stack.pop()) |frame| {
        if (frame.restore) |position| {
            rename.restore(position);
            continue;
        }
        const block = frame.block;
        const position = rename.undo.items.len;
        for (phis[block].items) |phi| try rename.set(phi.slot, phi.value);
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            function_ir.readOperands(function, instruction, &rename, Renaming.substitute);
            if (instruction.* == .value_copy) if (instruction.value_copy.destination) |destination| {
                if (@backingInt(destination) >= mapping.len) continue;
                const slot_index = mapping[@backingInt(destination)] orelse continue;
                const source = function.find(instruction.value_copy.source);
                if (function.plainValue(source) and !taken(address_taken, source)) {
                    try rename.set(slot_index, source);
                    function.removed.items[index] = true;
                } else {
                    instruction.value_copy.destination = null;
                    try rename.set(slot_index, function.results.items[index]);
                }
            };
        }
        function_ir.terminatorReadOperands(function, &function.blocks.items[block].terminator, &rename, Renaming.substitute);
        for (Function.edges(&function.blocks.items[block].terminator)) |maybe_edge| if (maybe_edge) |edge| {
            for (phis[@backingInt(edge.target)].items) |phi| try function.appendBranchArgument(edge, rename.current[phi.slot]);
        };
        try stack.append(scratch, .{ .block = block, .restore = position });
        var child = graph.first_child[block];
        while (child != std.math.maxInt(u32)) : (child = graph.next_sibling[child]) try stack.append(scratch, .{ .block = child });
    }
    return changed;
}

fn taken(address_taken: []const bool, value: ValueId) bool {
    return @backingInt(value) < address_taken.len and address_taken[@backingInt(value)];
}

fn rewriteSite(function: *Function, address_taken: []const bool, slot: Slot, site: Site, rewrite: *Rewrite) void {
    const index = site.instruction orelse {
        function_ir.terminatorReadOperands(function, &function.blocks.items[site.block].terminator, rewrite, Rewrite.substitute);
        return;
    };
    if (function.removed.items[index]) return;
    const instruction = &function.instructions.items[index];
    if (storedValue(instruction.*, slot.storage)) |stored| {
        const source = function.find(stored);
        if (function.plainValue(source) and !taken(address_taken, source)) {
            rewrite.current = source;
            function.removed.items[index] = true;
        } else {
            instruction.value_copy.destination = null;
            rewrite.current = function.results.items[index];
        }
        return;
    }
    function_ir.readOperands(function, instruction, rewrite, Rewrite.substitute);
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
    const value = try function.insertInstruction(function.entry, 0, instruction, function.instructionSpan(slot.instruction), function.instructionFrame(slot.instruction));
    cache[index] = value;
    return value;
}
