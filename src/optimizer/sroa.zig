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
    var changed = false;
    while (try splitOnce(function, context, order, layouts)) changed = true;
    return changed;
}

const Slot = struct {
    storage: ValueId,
    instruction: u32,
    type_id: structures.TypeId,
    fields: []const structures.TypeId,
    parts: []const ValueId = &.{},
    references: u32 = 0,
    accepted: u32 = 0,
    valid: bool = true,
    epoch: usize = 0,
    whole: ?ValueId = null,
};

const Uses = struct {
    mapping: []const ?u32,
    slots: []Slot,

    fn lookupSlot(self: *Uses, value: ValueId) ?*Slot {
        const index = self.mapping[@backingInt(value)] orelse return null;
        return &self.slots[index];
    }

    fn reference(self: *Uses, value: ValueId) void {
        if (self.lookupSlot(value)) |candidate| candidate.references += 1;
    }

    fn accept(self: *Uses, operand: *ValueId) void {
        if (self.lookupSlot(operand.*)) |candidate| candidate.accepted += 1;
    }
};

fn splitOnce(function: *Function, context: anytype, order: []const u32, layouts: *Layouts) !bool {
    const scratch = function.scratch;
    function.resolveReferences();
    var slots: std.ArrayList(Slot) = .empty;
    for (order) |block| for (function.blocks.items[block].instructions.items) |index| {
        if (function.removed.items[index] or function.instructions.items[index] != .local_storage) continue;
        const type_id = function.instructions.items[index].local_storage;
        const fields = (try layouts.get(scratch, context, type_id)) orelse continue;
        if (fields.len == 0) continue;
        try slots.append(scratch, .{ .storage = function.results.items[index], .instruction = index, .type_id = type_id, .fields = fields });
    };
    if (slots.items.len == 0) return false;
    const mapping = try scratch.alloc(?u32, function.valueCount());
    @memset(mapping, null);
    for (slots.items, 0..) |slot, index| mapping[@backingInt(slot.storage)] = @intCast(index);
    var uses: Uses = .{ .mapping = mapping, .slots = slots.items };
    const tables = function_ir.tableView(function);
    for (order) |block_index| {
        const block = &function.blocks.items[block_index];
        for (block.instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            function_ir.visitInstructionReferences(tables, instruction, &uses, Uses.reference);
            switch (instruction.*) {
                .storage_projection => |projection| if (uses.lookupSlot(projection.owner)) |slot| {
                    if (projection.projection != .field) {
                        slot.valid = false;
                    } else if (slot.fields[projection.projection.field] != projection.type_id) slot.valid = false;
                    slot.accepted += 1;
                    continue;
                },
                .field_access => |access| if (uses.lookupSlot(access.operand)) |slot| {
                    if (slot.fields[access.field_index] != access.field_type) slot.valid = false;
                    slot.accepted += 1;
                    continue;
                },
                .value_copy => |copy| if (copy.destination) |destination| {
                    if (uses.lookupSlot(destination)) |slot| {
                        if (copy.source == destination or copy.type_id != slot.type_id or function.valueType(copy.source) != slot.type_id) slot.valid = false;
                        slot.accepted += 1;
                    }
                },
                else => {},
            }
            function_ir.readOperands(function, instruction, &uses, Uses.accept);
        }
        function_ir.visitTerminatorReferences(tables, &block.terminator, &uses, Uses.reference);
        function_ir.terminatorReadOperands(function, &block.terminator, &uses, Uses.accept);
    }
    var changed = false;
    for (slots.items) |*slot| {
        if (!slot.valid or slot.references != slot.accepted) {
            mapping[@backingInt(slot.storage)] = null;
            continue;
        }
        const parts = try scratch.alloc(ValueId, slot.fields.len);
        for (slot.fields, parts) |field, *part| {
            const index = try function.newInstruction(.{ .local_storage = field }, function.instructionSpan(slot.instruction), function.instructionFrame(slot.instruction));
            part.* = function.results.items[index];
        }
        slot.parts = parts;
        changed = true;
    }
    if (changed) {
        try replace(function, order, mapping, slots.items);
        function.invalidateOperands();
    }
    return changed;
}

const Rewriter = struct {
    function: *Function,
    mapping: []const ?u32,
    slots: []Slot,
    list: *std.ArrayList(u32),
    span: structures.SourceSpan,
    frame: structures.InlineFrameId,
    needed: std.ArrayList(u32) = .empty,
    epoch: usize = 0,
    failed: bool = false,

    fn lookupSlot(self: *Rewriter, value: ValueId) ?*Slot {
        if (@backingInt(value) >= self.mapping.len) return null;
        const index = self.mapping[@backingInt(value)] orelse return null;
        return &self.slots[index];
    }

    fn emit(self: *Rewriter, instruction: Instruction) !ValueId {
        const index = try self.function.newInstruction(instruction, self.span, self.frame);
        try self.list.append(self.function.scratch, index);
        return self.function.results.items[index];
    }

    fn assemble(self: *Rewriter, slot: *Slot) !void {
        const function = self.function;
        const start: u32 = @intCast(function.aggregate_fields.items.len);
        for (slot.parts, slot.fields) |part, field| {
            const loaded = try self.emit(.{ .value_copy = .{ .source = part, .type_id = field } });
            try function.aggregate_fields.append(function.scratch, loaded);
        }
        slot.whole = try self.emit(.{ .aggregate = .{ .type_id = slot.type_id, .fields = .{ .start = start, .end = @intCast(function.aggregate_fields.items.len) } } });
    }

    fn observe(self: *Rewriter, operand: *ValueId) void {
        const slot = self.lookupSlot(operand.*) orelse return;
        if (slot.epoch == self.epoch) return;
        slot.epoch = self.epoch;
        self.needed.append(self.function.scratch, self.mapping[@backingInt(operand.*)].?) catch {
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
        for (self.needed.items) |index| try self.assemble(&self.slots[index]);
        return self.needed.items.len != 0;
    }
};

fn replace(function: *Function, order: []const u32, mapping: []const ?u32, slots: []Slot) !void {
    const scratch = function.scratch;
    var rewriter: Rewriter = .{ .function = function, .mapping = mapping, .slots = slots, .list = undefined, .span = undefined, .frame = undefined };
    for (order) |block_index| {
        var rebuilt: std.ArrayList(u32) = .empty;
        rewriter.list = &rebuilt;
        for (function.blocks.items[block_index].instructions.items) |index| {
            if (function.removed.items[index]) {
                try rebuilt.append(scratch, index);
                continue;
            }
            rewriter.span = function.instructionSpan(index);
            rewriter.frame = function.instructionFrame(index);
            const instruction = &function.instructions.items[index];
            switch (instruction.*) {
                .local_storage => if (rewriter.lookupSlot(function.results.items[index])) |slot| {
                    for (slot.parts) |part| try rebuilt.append(scratch, function.definitions.items[@backingInt(part)].instruction);
                    function.removed.items[index] = true;
                    continue;
                },
                .storage_projection => |projection| if (rewriter.lookupSlot(projection.owner)) |slot| {
                    function.replace(function.results.items[index], slot.parts[projection.projection.field]);
                    function.removed.items[index] = true;
                    continue;
                },
                .field_access => |access| if (rewriter.lookupSlot(access.operand)) |slot| {
                    instruction.* = .{ .value_copy = .{ .source = slot.parts[access.field_index], .type_id = access.field_type } };
                    try rebuilt.append(scratch, index);
                    continue;
                },
                .value_copy => |copy| if (copy.destination) |destination| {
                    if (rewriter.lookupSlot(destination)) |slot| {
                        _ = try rewriter.prepare(index, block_index);
                        var source = copy.source;
                        rewriter.substitute(&source);
                        for (slot.parts, slot.fields, 0..) |part, field, field_index| {
                            const value = try rewriter.emit(.{ .field_access = .{ .operand = source, .field_index = @intCast(field_index), .field_type = field } });
                            _ = try rewriter.emit(.{ .value_copy = .{ .source = value, .type_id = field, .destination = part } });
                        }
                        function.removed.items[index] = true;
                        continue;
                    }
                },
                else => {},
            }
            if (try rewriter.prepare(index, block_index))
                function_ir.readOperands(function, &function.instructions.items[index], &rewriter, Rewriter.substitute);
            try rebuilt.append(scratch, index);
        }
        rewriter.span = function.blocks.items[block_index].span;
        rewriter.frame = function.blocks.items[block_index].frame;
        if (try rewriter.prepare(null, block_index))
            function_ir.terminatorReadOperands(function, &function.blocks.items[block_index].terminator, &rewriter, Rewriter.substitute);
        function.blocks.items[block_index].instructions = rebuilt;
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
