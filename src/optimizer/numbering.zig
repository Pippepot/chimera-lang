const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const effects = @import("effects.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;
const Graph = @import("graph.zig").Graph;

/// Word-at-a-time multiplicative hasher: instruction keys are short and hashed
/// field by field, where buffered Wyhash updates cost more than the lookup.
const Fold = struct {
    state: u64 = 0,

    pub inline fn update(self: *Fold, bytes: []const u8) void {
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 8) {
            var word: u64 = 0;
            const length = @min(8, bytes.len - offset);
            @memcpy(std.mem.asBytes(&word)[0..length], bytes[offset..][0..length]);
            self.state = (self.state ^ word) *% 0x9e3779b97f4a7c15;
            self.state ^= self.state >> 32;
        }
    }
};

const Context = struct {
    pub fn hash(_: Context, instruction: Instruction) u64 {
        var fold: Fold = .{};
        std.hash.autoHash(&fold, instruction);
        return fold.state;
    }

    pub fn eql(_: Context, left: Instruction, right: Instruction) bool {
        return std.meta.eql(left, right);
    }
};

const Candidate = struct { value: ValueId, block: u32 };

const Alternative = struct { candidate: Candidate, next: ?u32 = null };

const Candidates = struct {
    first: Candidate,
    head: ?u32 = null,
    tail: ?u32 = null,

    fn findOrAppend(self: *Candidates, scratch: std.mem.Allocator, alternatives: *std.ArrayList(Alternative), graph: *const Graph, candidate: Candidate) !?ValueId {
        if (graph.dominates(self.first.block, candidate.block)) return self.first.value;
        var next = self.head;
        while (next) |index| {
            const alternative = alternatives.items[index];
            if (graph.dominates(alternative.candidate.block, candidate.block)) return alternative.candidate.value;
            next = alternative.next;
        }
        const index: u32 = @intCast(alternatives.items.len);
        try alternatives.append(scratch, .{ .candidate = candidate });
        if (self.tail) |tail| alternatives.items[tail].next = index else self.head = index;
        self.tail = index;
        return null;
    }
};

const Aggregate = struct { type_id: structures.TypeId, fields: []const ValueId };

const AggregateContext = struct {
    pub fn hash(_: AggregateContext, key: Aggregate) u64 {
        var hasher = std.hash.Wyhash.init(@backingInt(key.type_id));
        for (key.fields) |field| std.hash.autoHash(&hasher, field);
        return hasher.final();
    }

    pub fn eql(_: AggregateContext, left: Aggregate, right: Aggregate) bool {
        return left.type_id == right.type_id and std.mem.eql(ValueId, left.fields, right.fields);
    }
};

const AggregateLookup = struct {
    function: *const Function,

    pub fn hash(self: AggregateLookup, key: Aggregate) u64 {
        var hasher = std.hash.Wyhash.init(@backingInt(key.type_id));
        for (key.fields) |field| std.hash.autoHash(&hasher, self.function.find(field));
        return hasher.final();
    }

    pub fn eql(self: AggregateLookup, key: Aggregate, stored: Aggregate) bool {
        if (key.type_id != stored.type_id or key.fields.len != stored.fields.len) return false;
        for (key.fields, stored.fields) |field, saved| if (self.function.find(field) != saved) return false;
        return true;
    }
};

pub const Workspace = struct {
    pure: std.HashMapUnmanaged(Instruction, Candidates, Context, 80) = .empty,
    loads: std.HashMapUnmanaged(Instruction, ValueId, Context, 80) = .empty,
    /// Snapshot copies made in the current block, by copy, with the storage each copied.
    snapshots: std.AutoHashMapUnmanaged(ValueId, ValueId) = .empty,
    aggregates: std.HashMapUnmanaged(Aggregate, Candidates, AggregateContext, 80) = .empty,
    alternatives: std.ArrayList(Alternative) = .empty,
};

pub fn number(function: *Function, workspace: *Workspace) !function_ir.Changes {
    const scratch = function.scratch;
    function.resolveReferences();
    const graph = (try function.controlFlow()).*;
    const roots = try effects.Roots.init(function);
    const taken = roots.address_taken;
    const pure = &workspace.pure;
    const loads = &workspace.loads;
    const snapshots = &workspace.snapshots;
    const aggregates = &workspace.aggregates;
    const alternatives = &workspace.alternatives;
    pure.clearRetainingCapacity();
    aggregates.clearRetainingCapacity();
    alternatives.clearRetainingCapacity();
    var changes: function_ir.Changes = .{};
    for (graph.order) |block| {
        if (loads.count() != 0) loads.clearRetainingCapacity();
        if (snapshots.count() != 0) snapshots.clearRetainingCapacity();
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            // Operands were resolved above; only this pass's own eliminations stale them.
            // Users follow their definitions, so resolving in place leaves nothing for a later sweep.
            if (changes.changed) function_ir.allOperands(function, &function.instructions.items[index], function, Function.resolveOperand);
            var instruction = function.instructions.items[index];
            const result = function.results.items[index];
            const shareable = !taken[@backingInt(result)];
            // A read of a snapshot reads the copied storage directly while nothing writes it.
            if (snapshots.count() != 0) if (try forwardSnapshotRead(function, snapshots, index)) {
                instruction = function.instructions.items[index];
                changes.changed = true;
                changes.storage = true;
            };
            if (instruction == .aggregate) {
                if (!shareable) continue;
                const operation = instruction.aggregate;
                const original = function.aggregate_fields.items[operation.fields.start..operation.fields.end];
                const entry = try aggregates.getOrPutAdapted(scratch, Aggregate{ .type_id = operation.type_id, .fields = original }, AggregateLookup{ .function = function });
                const candidate: Candidate = .{ .value = result, .block = block };
                if (!entry.found_existing) {
                    const fields = try scratch.alloc(ValueId, original.len);
                    for (fields, original) |*field, value| field.* = function.find(value);
                    entry.key_ptr.* = .{ .type_id = operation.type_id, .fields = fields };
                    entry.value_ptr.* = .{ .first = candidate };
                } else if (try entry.value_ptr.findOrAppend(scratch, alternatives, &graph, candidate)) |value| {
                    eliminate(function, index, value, &changes);
                }
                continue;
            }
            switch (kind(&roots, instruction)) {
                .pure => if (shareable) {
                    const entry = try pure.getOrPut(scratch, instruction);
                    const candidate: Candidate = .{ .value = result, .block = block };
                    if (!entry.found_existing) {
                        entry.value_ptr.* = .{ .first = candidate };
                    } else if (try entry.value_ptr.findOrAppend(scratch, alternatives, &graph, candidate)) |value| {
                        eliminate(function, index, value, &changes);
                    }
                },
                .load => if (shareable) {
                    const entry = try loads.getOrPut(scratch, instruction);
                    if (entry.found_existing) {
                        eliminate(function, index, entry.value_ptr.*, &changes);
                    } else {
                        entry.value_ptr.* = result;
                        if (instruction == .value_copy and !function_ir.scalar(instruction.value_copy.type_id)) try snapshots.put(scratch, result, function.find(instruction.value_copy.source));
                    }
                },
                .write => if (loads.count() != 0 or snapshots.count() != 0) invalidateLoads(loads, snapshots, &roots, instruction),
                .none => {},
            }
        }
        if (changes.changed) function_ir.terminatorAllOperands(function, &function.blocks.items[block].terminator, function, Function.resolveOperand);
    }
    if (changes.changed) {
        for (function.blocks.items, graph.reachable) |*block, reachable| {
            if (!reachable) function_ir.visitBlockOperands(function, block, function, Function.resolveOperand);
        }
        function.operands_dirty = false;
    }
    return changes;
}

fn eliminate(function: *Function, index: u32, target: ValueId, changes: *function_ir.Changes) void {
    changes.storage = changes.storage or function_ir.usesStorage(function, &function.instructions.items[index]);
    function.replace(function.results.items[index], target);
    function.removed.items[index] = true;
    changes.changed = true;
}

const Kind = enum { pure, load, write, none };

fn kind(roots: *const effects.Roots, instruction: Instruction) Kind {
    return switch (instruction) {
        .const_numeric, .numeric_binary, .numeric_unary, .numeric_convert, .const_int, .const_byte, .const_bool, .const_unit, .const_none, .function_ref, .addi, .subi, .muli, .divsi, .shli, .shrsi, .negi, .byte_to_int, .compare, .select, .borrow_address, .storage_projection, .array_element, .borrow_read, .cursor_offset, .cursor_element => .pure,
        .field_access => |operation| if (roots.fieldResource(operation.operand, operation.field_index) == .immutable) .pure else .load,
        .variant_tag => |operand| read(roots, operand),
        .value_copy => |copy| if (copy.destination == null) read(roots, copy.source) else .write,
        inline .variant_extract, .variant_coerce => |operation| if (operation.destination == null) read(roots, operation.operand) else .write,
        .allocation_element => |element| read(roots, element.allocation),
        .type_union, .local_storage, .result_storage, .const_int_literal, .const_string_literal, .const_static_string, .const_storage_cursor, .const_type, .initializer_ref, .aggregate, .storage_cursor => .none,
        .borrow_write, .call, .static_conversion, .fill, .move => .write,
    };
}

fn read(roots: *const effects.Roots, value: ValueId) Kind {
    return if (roots.root(value) == .immutable) .pure else .load;
}

/// Redirects a field or tag read of a snapshot copy to the storage it copied.
fn forwardSnapshotRead(function: *Function, snapshots: *const std.AutoHashMapUnmanaged(ValueId, ValueId), index: u32) !bool {
    const operand: *ValueId = switch (function.instructions.items[index]) {
        .field_access => |*access| &access.operand,
        .variant_tag => |*tagged| tagged,
        else => return false,
    };
    const source = snapshots.get(function.find(operand.*)) orelse return false;
    operand.* = source;
    return true;
}

fn invalidateLoads(loads: *std.HashMapUnmanaged(Instruction, ValueId, Context, 80), snapshots: *std.AutoHashMapUnmanaged(ValueId, ValueId), roots: *const effects.Roots, instruction: Instruction) void {
    const written: effects.Resource = switch (instruction) {
        inline .value_copy, .variant_coerce, .variant_extract => |copy| roots.root(copy.destination.?),
        .borrow_write => |write| roots.referent(write.reference),
        .fill => |fill| roots.root(fill.first),
        .move => |move| roots.root(move.destination),
        else => .unknown,
    };
    if (written == .unknown) {
        snapshots.clearRetainingCapacity();
        return loads.clearRetainingCapacity();
    }
    var copied = snapshots.iterator();
    while (copied.next()) |entry| {
        if (effects.Roots.overlaps(written, roots.root(entry.value_ptr.*))) _ = snapshots.remove(entry.key_ptr.*);
    }
    var entries = loads.keyIterator();
    while (entries.next()) |key| {
        const resource: effects.Resource = switch (key.*) {
            .field_access => |field| roots.fieldResource(field.operand, field.field_index),
            .value_copy => |copy| roots.root(copy.source),
            .variant_extract, .variant_coerce => |operation| roots.root(operation.operand),
            .variant_tag => |value| roots.root(value),
            .allocation_element => |element| roots.root(element.allocation),
            else => unreachable,
        };
        if (effects.Roots.overlaps(written, resource)) _ = loads.remove(key.*);
    }
}

test "optimizer numbering reuses scratch capacity without retaining candidates" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var workspace: Workspace = .{};
    for (0..2) |round| {
        var function: Function = .{
            .scratch = arena.allocator(),
            .return_type = .unit,
            .is_initializer_region = false,
            .parameter_modes = &.{},
            .publishes_spans = false,
            .root_instance = null,
            .entry = 0,
        };
        const span: structures.SourceSpan = .{ .start = 0, .end = 0 };
        _ = try function.addBlock(.return_unit, span, .root);
        try function.order.append(function.scratch, 0);
        if (round != 0) _ = try function.insertInstruction(0, 0, .{ .const_bool = true }, span, .root);
        const first = try function.insertInstruction(0, function.blocks.items[0].instructions.items.len, .{ .const_int = 42 }, span, .root);
        const duplicate = try function.insertInstruction(0, function.blocks.items[0].instructions.items.len, .{ .const_int = 42 }, span, .root);
        function.resolveReferences();
        _ = try function.controlFlow();
        _ = try effects.Roots.init(&function);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        if (round != 0) function.scratch = failing.allocator();
        const changes = try number(&function, &workspace);
        try testing.expect(changes.changed);
        try testing.expectEqual(first, function.find(duplicate));
    }
}
