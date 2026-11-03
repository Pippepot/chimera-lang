const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;

pub const Layouts = struct {
    types: std.AutoHashMapUnmanaged(structures.TypeId, ?[]const structures.TypeId) = .empty,

    fn get(self: *Layouts, scratch: std.mem.Allocator, context: anytype, type_id: structures.TypeId) !?[]const structures.TypeId {
        if (type_id.isPrimitive()) return null;
        if (self.types.get(type_id)) |fields| return fields;
        const fields = try context.structFields(scratch, type_id);
        try self.types.put(scratch, type_id, fields);
        return fields;
    }
};

/// Splits every eligible struct slot, including slots nested in split slots, in one analysis and one rewrite.
pub fn split(function: *Function, context: anytype, layouts: *Layouts) !bool {
    var has_struct_storage = false;
    for (function.instructions.items, function.removed.items) |instruction, removed| {
        if (!removed and instruction == .local_storage and !instruction.local_storage.isPrimitive()) {
            has_struct_storage = true;
            break;
        }
    }
    if (!has_struct_storage) return false;
    const order = (try function.controlFlowEdges()).order;
    return splitSlots(function, context, order, layouts);
}

/// A struct-typed storage that may be replaced by one storage per field. Root slots are
/// `local_storage` instructions; child slots are field projections of their parents, which
/// lets a nested struct be judged and split together with its owner.
const Slot = struct {
    /// Root instruction that supplies the span and frame of every storage created for this slot.
    instruction: u32,
    type_id: structures.TypeId,
    fields: []const structures.TypeId,
    /// Child slots reached through projections of each field, allocated on the first projection.
    children: []?u32 = &.{},
    /// One entry per field once the slot is split.
    parts: []const Part = &.{},
    references: u32 = 0,
    accepted: u32 = 0,
    valid: bool = true,
    selected: bool = false,
    epoch: usize = 0,
    whole: ?ValueId = null,

    fn eligible(self: *const Slot) bool {
        return self.valid and self.references == self.accepted;
    }
};

const Part = union(enum) {
    storage: ValueId,
    slot: u32,
};

const Uses = struct {
    /// Maps root storage values and the projection results of candidate slots to their slots.
    mapping: []?u32,
    slots: std.ArrayList(Slot) = .empty,
    /// Blocks that mention a candidate slot; every other block is left untouched.
    touched: []bool,
    block: u32 = 0,

    fn index(self: *Uses, value: ValueId) ?u32 {
        return self.mapping[@backingInt(value)];
    }

    fn reference(self: *Uses, value: ValueId) void {
        const slot = self.index(value) orelse return;
        self.slots.items[slot].references += 1;
        self.touched[self.block] = true;
    }

    fn accept(self: *Uses, operand: *ValueId) void {
        if (self.index(operand.*)) |slot| self.slots.items[slot].accepted += 1;
    }

    /// Makes `result`, a projection of `field` of `owner`, an alias of that field's child slot.
    fn alias(self: *Uses, scratch: std.mem.Allocator, fields: []const structures.TypeId, owner: u32, field: u32, result: ValueId) !void {
        const parent = &self.slots.items[owner];
        if (parent.children.len == 0) {
            parent.children = try scratch.alloc(?u32, parent.fields.len);
            @memset(parent.children, null);
        }
        const instruction = parent.instruction;
        const children = parent.children;
        const type_id = parent.fields[field];
        const child = children[field] orelse child: {
            const child: u32 = @intCast(self.slots.items.len);
            try self.slots.append(scratch, .{ .instruction = instruction, .type_id = type_id, .fields = fields });
            children[field] = child;
            break :child child;
        };
        self.mapping[@backingInt(result)] = child;
    }
};

fn splitSlots(function: *Function, context: anytype, order: []const u32, layouts: *Layouts) !bool {
    const scratch = function.scratch;
    function.resolveReferences();
    const mapping = try scratch.alloc(?u32, function.valueCount());
    @memset(mapping, null);
    const touched = try scratch.alloc(bool, function.blocks.items.len);
    @memset(touched, false);
    var uses: Uses = .{ .mapping = mapping, .touched = touched };
    for (order) |block| for (function.blocks.items[block].instructions.items) |index| {
        if (function.removed.items[index] or function.instructions.items[index] != .local_storage) continue;
        const type_id = function.instructions.items[index].local_storage;
        const fields = (try layouts.get(scratch, context, type_id)) orelse continue;
        if (fields.len == 0) continue;
        mapping[@backingInt(function.results.items[index])] = @intCast(uses.slots.items.len);
        try uses.slots.append(scratch, .{ .instruction = index, .type_id = type_id, .fields = fields });
        touched[block] = true;
    };
    const root_count = uses.slots.items.len;
    if (root_count == 0) return false;
    for (order) |block_index| {
        uses.block = block_index;
        const block = &function.blocks.items[block_index];
        for (block.instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            function_ir.visitInstructionReferences(function, instruction, &uses, Uses.reference);
            switch (instruction.*) {
                .storage_projection => |projection| if (uses.index(projection.owner)) |owner| {
                    try analyzeProjection(function, context, layouts, &uses, owner, projection, function.results.items[index]);
                    continue;
                },
                .field_access => |access| if (uses.index(access.operand)) |owner| {
                    const slot = &uses.slots.items[owner];
                    if (slot.fields[access.field_index] != access.field_type) slot.valid = false;
                    slot.accepted += 1;
                    continue;
                },
                .value_copy => |copy| if (copy.destination) |destination| if (uses.index(destination)) |owner| {
                    const slot = &uses.slots.items[owner];
                    if (uses.index(copy.source) == owner or copy.type_id != slot.type_id or function.valueType(copy.source) != slot.type_id) slot.valid = false;
                    slot.accepted += 1;
                },
                else => {},
            }
            function_ir.readOperands(function, instruction, &uses, Uses.accept);
        }
        function_ir.visitTerminatorReferences(function, &block.terminator, &uses, Uses.reference);
        function_ir.terminatorReadOperands(function, &block.terminator, &uses, Uses.accept);
    }
    var changed = false;
    for (uses.slots.items[0..root_count]) |*slot| {
        slot.selected = slot.eligible();
        changed = changed or slot.selected;
    }
    if (!changed) return false;
    try commit(function, context, layouts, &uses.slots);
    try replace(function, order, touched, mapping, uses.slots.items);
    function.invalidateOperands();
    return true;
}

fn analyzeProjection(function: *Function, context: anytype, layouts: *Layouts, uses: *Uses, owner: u32, projection: structures.StorageProjection, result: ValueId) !void {
    const slot = &uses.slots.items[owner];
    slot.accepted += 1;
    const field = switch (projection.projection) {
        .field => |field| field,
        .variant, .allocation_array => {
            slot.valid = false;
            return;
        },
    };
    if (slot.fields[field] != projection.type_id) {
        slot.valid = false;
        return;
    }
    if (!slot.valid) return;
    const fields = (try layouts.get(function.scratch, context, projection.type_id)) orelse return;
    if (fields.len != 0) try uses.alias(function.scratch, fields, owner, field, result);
}

/// Creates the field storage of every selected slot. A field that is itself a splittable struct
/// becomes a selected child slot unless its projections forbid it; slots are appended after their
/// parents, so a single forward pass reaches every nested slot.
fn commit(function: *Function, context: anytype, layouts: *Layouts, slots: *std.ArrayList(Slot)) !void {
    const scratch = function.scratch;
    var index: usize = 0;
    while (index < slots.items.len) : (index += 1) {
        const slot = slots.items[index];
        if (!slot.selected) continue;
        const parts = try scratch.alloc(Part, slot.fields.len);
        for (slot.fields, parts, 0..) |field, *part, field_index| {
            if (try childSlot(function, context, layouts, slots, slot, field_index)) |child| {
                slots.items[child].selected = true;
                part.* = .{ .slot = child };
            } else {
                const storage = try function.newInstruction(.{ .local_storage = field }, function.instructionSpan(slot.instruction), function.instructionFrame(slot.instruction));
                part.* = .{ .storage = function.results.items[storage] };
            }
        }
        slots.items[index].parts = parts;
    }
}

/// The slot that replaces one field of a split slot, or null when the field keeps a plain storage.
/// A field never projected has no uses besides whole copies, which are always splittable.
fn childSlot(function: *Function, context: anytype, layouts: *Layouts, slots: *std.ArrayList(Slot), parent: Slot, field_index: usize) !?u32 {
    if (parent.children.len != 0) if (parent.children[field_index]) |child| return if (slots.items[child].eligible()) child else null;
    const type_id = parent.fields[field_index];
    const fields = (try layouts.get(function.scratch, context, type_id)) orelse return null;
    if (fields.len == 0) return null;
    const child: u32 = @intCast(slots.items.len);
    try slots.append(function.scratch, .{ .instruction = parent.instruction, .type_id = type_id, .fields = fields });
    return child;
}

const Rewriter = struct {
    const Error = std.mem.Allocator.Error;

    function: *Function,
    mapping: []const ?u32,
    slots: []Slot,
    /// Instructions of the block being rewritten; `list` copies them lazily at the first change.
    source: []const u32 = &.{},
    position: usize = 0,
    list: std.ArrayList(u32) = .empty,
    diverged: bool = false,
    span: structures.SourceSpan = undefined,
    frame: structures.InlineFrameId = undefined,
    needed: std.ArrayList(u32) = .empty,
    epoch: usize = 0,
    failed: bool = false,

    fn lookupIndex(self: *Rewriter, value: ValueId) ?u32 {
        if (@backingInt(value) >= self.mapping.len) return null;
        const index = self.mapping[@backingInt(value)] orelse return null;
        return if (self.slots[index].parts.len != 0) index else null;
    }

    fn lookupSlot(self: *Rewriter, value: ValueId) ?*Slot {
        return &self.slots[self.lookupIndex(value) orelse return null];
    }

    fn begin(self: *Rewriter, source: []const u32) void {
        self.source = source;
        self.list = .empty;
        self.diverged = false;
    }

    /// Starts the rebuilt list as the unchanged prefix before the current instruction.
    fn diverge(self: *Rewriter) Error!void {
        if (self.diverged) return;
        self.diverged = true;
        try self.list.appendSlice(self.function.scratch, self.source[0..self.position]);
    }

    /// Keeps the current instruction in the rebuilt list.
    fn keep(self: *Rewriter, index: u32) Error!void {
        if (self.diverged) try self.list.append(self.function.scratch, index);
    }

    fn emit(self: *Rewriter, instruction: Instruction) Error!ValueId {
        try self.diverge();
        const index = try self.function.newInstruction(instruction, self.span, self.frame);
        try self.list.append(self.function.scratch, index);
        return self.function.results.items[index];
    }

    /// Places the leaf storages of a split slot in its list in field order.
    fn storage(self: *Rewriter, slot: *const Slot) Error!void {
        for (slot.parts) |part| switch (part) {
            .storage => |value| try self.list.append(self.function.scratch, self.function.definitions.items[@backingInt(value)].instruction),
            .slot => |child| try self.storage(&self.slots[child]),
        };
    }

    /// The storage of a leaf field, or the reassembled value of a split child.
    fn partSource(self: *Rewriter, part: Part) Error!ValueId {
        return switch (part) {
            .storage => |value| value,
            .slot => |child| try self.load(&self.slots[child]),
        };
    }

    /// Reassembles the whole value of a split slot from its parts.
    fn load(self: *Rewriter, slot: *const Slot) Error!ValueId {
        const function = self.function;
        const loaded = try function.scratch.alloc(ValueId, slot.parts.len);
        for (slot.parts, slot.fields, loaded) |part, field, *value|
            value.* = try self.emit(.{ .value_copy = .{ .source = try self.partSource(part), .type_id = field } });
        const start: u32 = @intCast(function.aggregate_fields.items.len);
        try function.aggregate_fields.appendSlice(function.scratch, loaded);
        return self.emit(.{ .aggregate = .{ .type_id = slot.type_id, .fields = .{ .start = start, .end = @intCast(function.aggregate_fields.items.len) } } });
    }

    /// Writes a whole value into the parts of a split slot.
    fn store(self: *Rewriter, slot: *const Slot, source: ValueId) Error!void {
        for (slot.parts, slot.fields, 0..) |part, field, field_index| {
            const value = try self.emit(.{ .field_access = .{ .operand = source, .field_index = @intCast(field_index), .field_type = field } });
            switch (part) {
                .storage => |destination| _ = try self.emit(.{ .value_copy = .{ .source = value, .type_id = field, .destination = destination } }),
                .slot => |child| try self.store(&self.slots[child], value),
            }
        }
    }

    fn observe(self: *Rewriter, operand: *ValueId) void {
        const index = self.lookupIndex(operand.*) orelse return;
        const slot = &self.slots[index];
        if (slot.epoch == self.epoch) return;
        slot.epoch = self.epoch;
        self.needed.append(self.function.scratch, index) catch {
            self.failed = true;
        };
    }

    fn substitute(self: *Rewriter, operand: *ValueId) void {
        if (self.lookupSlot(operand.*)) |slot| operand.* = slot.whole.?;
    }

    fn prepare(self: *Rewriter, instruction: ?u32, block: u32) !bool {
        self.epoch += 1;
        self.needed.clearRetainingCapacity();
        if (instruction) |index| {
            function_ir.readOperands(self.function, &self.function.instructions.items[index], self, observe);
        } else function_ir.terminatorReadOperands(self.function, &self.function.blocks.items[block].terminator, self, observe);
        if (self.failed) return error.OutOfMemory;
        for (self.needed.items) |index| self.slots[index].whole = try self.load(&self.slots[index]);
        return self.needed.items.len != 0;
    }
};

fn replace(function: *Function, order: []const u32, touched: []const bool, mapping: []const ?u32, slots: []Slot) !void {
    var rewriter: Rewriter = .{ .function = function, .mapping = mapping, .slots = slots };
    for (order) |block_index| {
        if (!touched[block_index]) continue;
        rewriter.begin(function.blocks.items[block_index].instructions.items);
        for (rewriter.source, 0..) |index, position| {
            rewriter.position = position;
            if (function.removed.items[index]) {
                try rewriter.keep(index);
                continue;
            }
            rewriter.span = function.instructionSpan(index);
            rewriter.frame = function.instructionFrame(index);
            const instruction = &function.instructions.items[index];
            switch (instruction.*) {
                .local_storage => if (rewriter.lookupSlot(function.results.items[index])) |slot| {
                    try rewriter.diverge();
                    try rewriter.storage(slot);
                    function.removed.items[index] = true;
                    continue;
                },
                .storage_projection => |projection| if (rewriter.lookupSlot(projection.owner)) |slot| {
                    try rewriter.diverge();
                    switch (slot.parts[projection.projection.field]) {
                        .storage => |part| function.replace(function.results.items[index], part),
                        // Uses of the projection reach the child slot through the mapping.
                        .slot => {},
                    }
                    function.removed.items[index] = true;
                    continue;
                },
                .field_access => |access| if (rewriter.lookupSlot(access.operand)) |slot| {
                    const source = try rewriter.partSource(slot.parts[access.field_index]);
                    function.instructions.items[index] = .{ .value_copy = .{ .source = source, .type_id = access.field_type } };
                    try rewriter.keep(index);
                    continue;
                },
                .value_copy => |copy| if (copy.destination) |destination| {
                    if (rewriter.lookupSlot(destination)) |slot| {
                        _ = try rewriter.prepare(index, block_index);
                        var source = copy.source;
                        rewriter.substitute(&source);
                        try rewriter.store(slot, source);
                        function.removed.items[index] = true;
                        continue;
                    }
                },
                else => {},
            }
            if (try rewriter.prepare(index, block_index))
                function_ir.readOperands(function, &function.instructions.items[index], &rewriter, Rewriter.substitute);
            try rewriter.keep(index);
        }
        const block = &function.blocks.items[block_index];
        rewriter.position = rewriter.source.len;
        rewriter.span = block.span;
        rewriter.frame = block.frame;
        if (try rewriter.prepare(null, block_index))
            function_ir.terminatorReadOperands(function, &block.terminator, &rewriter, Rewriter.substitute);
        if (rewriter.diverged) block.instructions = rewriter.list;
    }
}

test "optimizer scalar replacement reuses field layouts and negative facts" {
    const testing = std.testing;
    const Context = struct {
        requests: *usize,

        pub fn structFields(self: @This(), scratch: std.mem.Allocator, type_id: structures.TypeId) !?[]const structures.TypeId {
            self.requests.* += 1;
            if (@backingInt(type_id) == 1000) return try scratch.dupe(structures.TypeId, &.{ .int, .bool });
            if (@backingInt(type_id) == 1001) return &.{};
            return null;
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var layouts: Layouts = .{};
    var requests: usize = 0;
    const context: Context = .{ .requests = &requests };
    const fields = (try layouts.get(arena.allocator(), context, @fromBackingInt(1000))).?;
    try testing.expectEqualSlices(structures.TypeId, &.{ .int, .bool }, fields);
    try testing.expectEqual(@as(usize, 0), (try layouts.get(arena.allocator(), context, @fromBackingInt(1001))).?.len);
    try testing.expect(try layouts.get(arena.allocator(), context, @fromBackingInt(1002)) == null);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectEqual(fields.ptr, (try layouts.get(failing.allocator(), context, @fromBackingInt(1000))).?.ptr);
    try testing.expectEqual(@as(usize, 0), (try layouts.get(failing.allocator(), context, @fromBackingInt(1001))).?.len);
    try testing.expect(try layouts.get(failing.allocator(), context, @fromBackingInt(1002)) == null);
    try testing.expectEqual(@as(usize, 3), requests);
}
