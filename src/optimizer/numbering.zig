const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const effects = @import("effects.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;
const Graph = @import("graph.zig").Graph;

const Context = struct {
    pub fn hash(_: Context, instruction: Instruction) u64 {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, instruction);
        return hasher.final();
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
    const aggregates = &workspace.aggregates;
    const alternatives = &workspace.alternatives;
    pure.clearRetainingCapacity();
    aggregates.clearRetainingCapacity();
    alternatives.clearRetainingCapacity();
    var changes: function_ir.Changes = .{};
    for (graph.order) |block| {
        loads.clearRetainingCapacity();
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = canonical(function, function.instructions.items[index]);
            const result = function.results.items[index];
            const shareable = !taken[@backingInt(result)];
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
                    } else entry.value_ptr.* = result;
                },
                .write => loads.clearRetainingCapacity(),
                .none => {},
            }
        }
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

fn canonical(function: *const Function, instruction: Instruction) Instruction {
    var copy = instruction;
    for (copy.operands()) |operand| if (operand) |value| {
        value.* = function.find(value.*);
    };
    return copy;
}

fn kind(roots: *const effects.Roots, instruction: Instruction) Kind {
    return switch (instruction) {
        .const_int, .const_byte, .const_bool, .const_unit, .const_none, .function_ref, .addi, .subi, .muli, .divsi, .shli, .shrsi, .negi, .byte_to_int, .compare, .select, .borrow_address, .storage_projection, .array_element, .borrow_read, .cursor_offset, .cursor_element => .pure,
        .field_access => |operation| read(roots, operation.operand),
        .variant_tag => |operand| read(roots, operand),
        .value_copy => |copy| if (copy.destination == null) read(roots, copy.source) else .write,
        inline .variant_extract, .variant_coerce => |operation| if (operation.destination == null) read(roots, operation.operand) else .write,
        .allocation_element => |element| read(roots, element.allocation),
        .local_storage, .result_storage, .const_int_literal, .const_string_literal, .const_static_string, .const_storage_cursor, .const_type, .initializer_ref, .aggregate, .storage_cursor => .none,
        .borrow_write, .call, .static_conversion, .fill, .move => .write,
    };
}

fn read(roots: *const effects.Roots, value: ValueId) Kind {
    return if (roots.root(value) == .immutable) .pure else .load;
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
