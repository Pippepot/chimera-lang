const std = @import("std");
const structures = @import("../structures.zig");

pub const ExecutionErrorReason = enum {
    call_cycle,
    division_by_zero,
    integer_overflow,
    unsupported_operation,
    escaping_storage,
};

pub const ExecutionError = struct {
    reason: ExecutionErrorReason,
    span: ?structures.SourceSpan = null,
};

pub const Heap = struct {
    allocator: std.mem.Allocator,
    identities: std.heap.ArenaAllocator,
    records: std.ArrayList(*Allocation) = .empty,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator, .identities = .init(allocator) };
    }

    pub fn deinit(self: *Heap) void {
        for (self.records.items) |record| {
            record.release();
            self.allocator.destroy(record);
        }
        self.records.deinit(self.allocator);
        self.identities.deinit();
    }

    pub fn allocate(self: *Heap, element_type: structures.TypeId, capacity: u32) !*Allocation {
        const record = try self.allocator.create(Allocation);
        errdefer self.allocator.destroy(record);
        record.* = .{
            .identity = self.records.items.len,
            .element_type = element_type,
            .capacity = capacity,
            .backing = .init(self.allocator),
            .identities = self.identities.allocator(),
        };
        try self.records.append(self.allocator, record);
        return record;
    }
};

pub const Allocation = struct {
    identity: usize,
    element_type: structures.TypeId,
    capacity: u32,
    released: bool = false,
    backing: std.heap.ArenaAllocator,
    identities: std.mem.Allocator,
    elements: std.AutoHashMapUnmanaged(u32, *Cell) = .empty,

    pub fn element(self: *Allocation, index: u32) !*Cell {
        std.debug.assert(!self.released);
        std.debug.assert(index < self.capacity);
        if (self.elements.get(index)) |cell| return cell;
        const cell = try self.identities.create(Cell);
        cell.* = .{ .type_id = self.element_type, .storage = self.identities, .contents = .uninitialized };
        try self.elements.put(self.backing.allocator(), index, cell);
        return cell;
    }

    pub fn release(self: *Allocation) void {
        if (self.released) return;
        var cells = self.elements.valueIterator();
        while (cells.next()) |cell| cell.*.invalidate();
        self.elements = .empty;
        self.backing.deinit();
        self.released = true;
    }
};

pub fn allocationByteSize(element_size: u32, count: i32) ?u32 {
    if (count < 0) return null;
    const size = @as(u64, element_size) * @as(u32, @intCast(count));
    if (size > std.math.maxInt(i32)) return null;
    return @intCast(size);
}

pub const Value = union(enum) {
    runtime: structures.CompileTimeValue.RuntimeValue,
    type: structures.TypeId,
    place: *Cell,
    initializer: struct { body: *const structures.FunctionBodyAnalysis, captures: []Value },
};

pub const Cell = struct {
    type_id: structures.TypeId,
    storage: std.mem.Allocator,
    contents: union(enum) {
        uninitialized,
        value: structures.CompileTimeValue.RuntimeValue,
        fields: []Cell,
        variant_payload: *Cell,
        reference: *Cell,
        storage_cursor: struct { owner: *Cell, offset: u32 },
        allocation: *Allocation,
    },

    fn invalidate(self: *Cell) void {
        switch (self.contents) {
            .fields => |fields| for (fields) |*field| field.invalidate(),
            .variant_payload => |payload| payload.invalidate(),
            .uninitialized, .value, .reference, .storage_cursor, .allocation => {},
        }
        self.contents = .uninitialized;
    }
};

pub const ValueSnapshot = struct {
    const CellPair = struct { left: *const Cell, right: *const Cell };

    values: []const Value,
    sources: std.AutoHashMapUnmanaged(*const Cell, *const Cell),

    pub fn init(values: []const Value, storage: std.mem.Allocator) anyerror!ValueSnapshot {
        var cloner: Cloner = .{ .storage = storage };
        defer cloner.copies.deinit(storage);
        defer cloner.allocations.deinit(storage);
        const saved_values = try cloner.cloneValues(values);
        return .{ .values = saved_values, .sources = cloner.sources };
    }

    pub fn eql(left: ValueSnapshot, right: ValueSnapshot, scratch: std.mem.Allocator) anyerror!bool {
        var comparison: Comparison = .{ .left = left, .right = right, .scratch = scratch };
        defer comparison.compared.deinit(scratch);
        return comparison.sameValues(left.values, right.values);
    }

    fn sourceCell(self: ValueSnapshot, snapshot: *const Cell) *const Cell {
        return self.sources.get(snapshot).?;
    }

    const Cloner = struct {
        storage: std.mem.Allocator,
        copies: std.AutoHashMapUnmanaged(*const Cell, *Cell) = .empty,
        sources: std.AutoHashMapUnmanaged(*const Cell, *const Cell) = .empty,
        allocations: std.AutoHashMapUnmanaged(*const Allocation, *Allocation) = .empty,

        fn cloneValues(self: *@This(), values: []const Value) anyerror![]Value {
            const copies = try self.storage.alloc(Value, values.len);
            for (values, copies) |value, *copy| copy.* = try self.cloneValue(value);
            return copies;
        }

        fn cloneValue(self: *@This(), value: Value) anyerror!Value {
            switch (value) {
                .runtime, .type => return value,
                .place => |cell| return .{ .place = try self.cloneCell(cell) },
                .initializer => |initializer| return self.cloneInitializer(initializer),
            }
        }

        fn cloneInitializer(self: *@This(), initializer: @FieldType(Value, "initializer")) anyerror!Value {
            return .{ .initializer = .{ .body = initializer.body, .captures = try self.cloneValues(initializer.captures) } };
        }

        fn cloneCell(self: *@This(), cell: *const Cell) anyerror!*Cell {
            if (self.copies.get(cell)) |snapshot| return snapshot;
            const snapshot = try self.storage.create(Cell);
            try self.registerCell(cell, snapshot);
            try self.cloneContents(cell, snapshot);
            return snapshot;
        }

        fn registerCell(self: *@This(), cell: *const Cell, snapshot: *Cell) !void {
            if (!self.copies.contains(cell)) try self.copies.put(self.storage, cell, snapshot);
            try self.sources.put(self.storage, snapshot, cell);
        }

        fn cloneContents(self: *@This(), cell: *const Cell, snapshot: *Cell) anyerror!void {
            snapshot.* = .{ .type_id = cell.type_id, .storage = self.storage, .contents = .uninitialized };
            switch (cell.contents) {
                .uninitialized => {},
                .value => |value| snapshot.contents = .{ .value = value },
                .fields => |fields| snapshot.contents = .{ .fields = try self.cloneFields(fields) },
                .variant_payload => |payload| snapshot.contents = .{ .variant_payload = try self.cloneCell(payload) },
                .storage_cursor => |pointer| snapshot.contents = .{ .storage_cursor = .{ .owner = try self.cloneCell(pointer.owner), .offset = pointer.offset } },
                .reference => |target| snapshot.contents = .{ .reference = try self.cloneCell(target) },
                .allocation => |allocation| snapshot.contents = .{ .allocation = try self.cloneAllocation(allocation) },
            }
        }

        fn cloneAllocation(self: *@This(), allocation: *const Allocation) anyerror!*Allocation {
            if (self.allocations.get(allocation)) |copy| return copy;
            const copy = try self.storage.create(Allocation);
            copy.* = .{
                .identity = allocation.identity,
                .element_type = allocation.element_type,
                .capacity = allocation.capacity,
                .released = allocation.released,
                .backing = .init(self.storage),
                .identities = self.storage,
            };
            try self.allocations.put(self.storage, allocation, copy);
            var entries = allocation.elements.iterator();
            while (entries.next()) |entry| try copy.elements.put(self.storage, entry.key_ptr.*, try self.cloneCell(entry.value_ptr.*));
            return copy;
        }

        fn cloneFields(self: *@This(), fields: []const Cell) anyerror![]Cell {
            const copies = try self.storage.alloc(Cell, fields.len);
            for (fields, copies) |*field, *copy| try self.registerCell(field, copy);
            for (fields, copies) |*field, *copy| try self.cloneContents(field, copy);
            return copies;
        }
    };

    const Comparison = struct {
        left: ValueSnapshot,
        right: ValueSnapshot,
        scratch: std.mem.Allocator,
        compared: std.AutoHashMapUnmanaged(CellPair, void) = .empty,

        fn sameValues(self: *@This(), left: []const Value, right: []const Value) anyerror!bool {
            if (left.len != right.len) return false;
            for (left, right) |first, second| if (!try self.sameValue(first, second)) return false;
            return true;
        }

        fn sameValue(self: *@This(), left: Value, right: Value) anyerror!bool {
            if (left == .place and left.place.contents == .value)
                return self.sameValue(.{ .runtime = left.place.contents.value }, right);
            if (right == .place and right.place.contents == .value)
                return self.sameValue(left, .{ .runtime = right.place.contents.value });
            if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
            switch (left) {
                .runtime => |runtime| return std.meta.eql(runtime, right.runtime),
                .type => |type_id| return type_id == right.type,
                .place => |cell| return self.sameCell(cell, right.place),
                .initializer => |initializer| return initializer.body == right.initializer.body and
                    try self.sameValues(initializer.captures, right.initializer.captures),
            }
        }

        fn sameCell(self: *@This(), left: *const Cell, right: *const Cell) anyerror!bool {
            if (left.type_id != right.type_id) return false;
            if (std.meta.activeTag(left.contents) != std.meta.activeTag(right.contents)) return false;
            const pair: CellPair = .{ .left = left, .right = right };
            if (self.compared.contains(pair)) return true;
            try self.compared.put(self.scratch, pair, {});
            switch (left.contents) {
                .uninitialized => return true,
                .value => |value| return std.meta.eql(value, right.contents.value),
                .fields => |fields| return self.sameFields(fields, right.contents.fields),
                .variant_payload => |payload| return self.sameCell(payload, right.contents.variant_payload),
                .storage_cursor => return self.sameStorageCursor(left, right),
                .reference => |target| return self.left.sourceCell(target) == self.right.sourceCell(right.contents.reference) and
                    try self.sameCell(target, right.contents.reference),
                .allocation => |allocation| return self.sameAllocation(allocation, right.contents.allocation),
            }
        }

        fn sameStorageCursor(self: *@This(), left: *const Cell, right: *const Cell) anyerror!bool {
            const first = left.contents.storage_cursor;
            const second = right.contents.storage_cursor;
            if (first.offset != second.offset) return false;
            // Copied allocation descriptors still denote the same allocation;
            // inline arrays retain the identity of their original storage cell.
            if (first.owner.contents == .allocation and second.owner.contents == .allocation)
                return self.sameAllocation(first.owner.contents.allocation, second.owner.contents.allocation);
            return self.left.sourceCell(first.owner) == self.right.sourceCell(second.owner) and
                try self.sameCell(first.owner, second.owner);
        }

        fn sameAllocation(self: *@This(), left: *const Allocation, right: *const Allocation) anyerror!bool {
            if (left.identity != right.identity or left.element_type != right.element_type or left.capacity != right.capacity or left.released != right.released) return false;
            if (left.elements.count() != right.elements.count()) return false;
            var entries = left.elements.iterator();
            while (entries.next()) |entry| {
                const other = right.elements.get(entry.key_ptr.*) orelse return false;
                if (!try self.sameCell(entry.value_ptr.*, other)) return false;
            }
            return true;
        }

        fn sameFields(self: *@This(), left: []const Cell, right: []const Cell) anyerror!bool {
            if (left.len != right.len) return false;
            for (left, right) |*first, *second| if (!try self.sameCell(first, second)) return false;
            return true;
        }
    };
};

pub const Result = union(enum) {
    returned: Value,
    failure,
    exit: i32,
    execution_error: ExecutionError,
    reported_error,
    unavailable,
};

/// Execute the supported subset of a typed body. Slots are dense and frame-local;
/// aggregate components are interned only when they cross value boundaries.
pub fn execute(
    body: *const structures.FunctionBodyAnalysis,
    arguments: []Value,
    executor: anytype,
    gpa: std.mem.Allocator,
) anyerror!Result {
    var storage_arena: std.heap.ArenaAllocator = .init(gpa);
    defer storage_arena.deinit();
    const result = try executeInStorage(body, arguments, executor, gpa, storage_arena.allocator());
    return publish(result, arguments, body.parameter_modes, executor, gpa);
}

pub fn publish(result: Result, arguments: []Value, modes: []const structures.ParameterMode, executor: anytype, gpa: std.mem.Allocator) !Result {
    if (result != .returned and result != .failure) return result;
    for (arguments, modes) |*argument, mode| {
        if (mode != .mut or argument.* != .place) continue;
        if (containsReference(argument.place)) return executionError(.escaping_storage, null);
        const runtime = (try materialize(argument.place, executor, gpa)) orelse return executionError(.unsupported_operation, null);
        argument.* = .{ .runtime = runtime };
    }
    if (result == .returned and result.returned == .place) {
        if (containsReference(result.returned.place)) return executionError(.escaping_storage, null);
        const runtime = (try materialize(result.returned.place, executor, gpa)) orelse return executionError(.unsupported_operation, null);
        return .{ .returned = .{ .runtime = runtime } };
    }
    if (result == .returned and result.returned == .initializer) return executionError(.escaping_storage, null);
    return result;
}

pub fn executeInStorage(
    body: *const structures.FunctionBodyAnalysis,
    arguments: []Value,
    executor: anytype,
    gpa: std.mem.Allocator,
    storage: std.mem.Allocator,
) anyerror!Result {
    const slot_count = body.valueCount();
    const branch_scratch_count = body.block_arguments.len;
    const frame = try gpa.alloc(Value, slot_count + branch_scratch_count + body.call_arguments.len);
    defer gpa.free(frame);
    const slots = frame[0..slot_count];
    const scratch = frame[slot_count .. slot_count + branch_scratch_count];
    const call_scratch = frame[slot_count + branch_scratch_count ..];
    @memset(slots, .{ .runtime = .unit });

    var block_id = body.entry;
    const entry = body.blocks[@backingInt(block_id)];
    std.debug.assert(entry.argument_start == 0);
    std.debug.assert(entry.argument_end == arguments.len);
    @memcpy(slots[entry.argument_start..entry.argument_end], arguments);
    while (true) {
        const block = body.blocks[@backingInt(block_id)];
        for (block.instruction_start..block.instruction_end) |instruction_index| {
            const instruction = body.instructions[instruction_index];
            const destination = @backingInt(body.instructionValue(instruction_index));
            switch (instruction) {
                .const_int => |value| slots[destination] = .{ .runtime = .{ .int = value } },
                .const_string_literal => |value| slots[destination] = .{ .runtime = .{ .string_literal = value } },
                .const_data => |value| slots[destination] = .{ .runtime = .{ .static_data = value } },
                .const_storage_cursor => |value| slots[destination] = .{ .runtime = .{ .storage_cursor = value } },
                .storage_cursor => |operation| switch (try storageCursor(body, slots, operation, executor, storage)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .cursor_offset => |operation| slots[destination] = try offsetStorageCursor(slots[@backingInt(operation.cursor)], operation.type_id, @intCast(integer(slots, operation.index)), storage),
                .cursor_element => |operation| slots[destination] = try storageCursorElement(slots[@backingInt(operation.cursor)], operation.type_id, @intCast(integer(slots, operation.index)), storage),
                .byte_to_int => |source| slots[destination] = .{ .runtime = .{ .int = scalar(slots, source).byte } },
                .const_int_literal => |value| slots[destination] = .{ .runtime = .{ .int_literal = value } },
                .static_conversion => |conversion| {
                    const source = (try readSlot(slots, conversion.operand, executor, gpa)) orelse return .unavailable;
                    if (source == .place and containsReference(source.place)) return executionError(.escaping_storage, instructionSpan(body, instruction_index));
                    const runtime = switch (source) {
                        .runtime => |value| value,
                        .place => |cell| (try materialize(cell, executor, gpa)) orelse return executionError(.unsupported_operation, instructionSpan(body, instruction_index)),
                        .type, .initializer => unreachable,
                    };
                    switch (try executor.convertStaticValue(body.valueType(conversion.operand), runtime, conversion.type_id, instructionSpan(body, instruction_index), storage)) {
                        .returned => |value| try store(slots, destination, conversion.destination, value, executor),
                        else => |result| return result,
                    }
                },
                .const_byte => |value| slots[destination] = .{ .runtime = .{ .byte = value } },
                .const_bool => |value| slots[destination] = .{ .runtime = .{ .bool = value } },
                .const_type => |type_id| slots[destination] = .{ .type = type_id },
                .const_unit => slots[destination] = .{ .runtime = .unit },
                .const_none => slots[destination] = .{ .runtime = .none },
                .function_ref => |reference| slots[destination] = .{ .runtime = .{ .function_ref = reference } },
                .initializer_ref => |reference| slots[destination] = try initializerValue(body, slots, reference, storage),
                .callable_coerce => |operation| {
                    var reference = scalar(slots, operation.operand).function_ref;
                    reference.type_id = operation.target_type;
                    try store(slots, destination, operation.destination, .{ .runtime = .{ .function_ref = reference } }, executor);
                },
                .negi => |operand| slots[destination] = .{ .runtime = .{ .int = -%integer(slots, operand) } },
                .addi => |operands| slots[destination] = .{ .runtime = .{ .int = integer(slots, operands.lhs) +% integer(slots, operands.rhs) } },
                .subi => |operands| slots[destination] = .{ .runtime = .{ .int = integer(slots, operands.lhs) -% integer(slots, operands.rhs) } },
                .muli => |operands| slots[destination] = .{ .runtime = .{ .int = integer(slots, operands.lhs) *% integer(slots, operands.rhs) } },
                .divsi => |operands| {
                    const lhs = integer(slots, operands.lhs);
                    const rhs = integer(slots, operands.rhs);
                    if (rhs == 0) return executionError(.division_by_zero, instructionSpan(body, instruction_index));
                    if (lhs == std.math.minInt(i32) and rhs == -1) return executionError(.integer_overflow, instructionSpan(body, instruction_index));
                    slots[destination] = .{ .runtime = .{ .int = @divTrunc(lhs, rhs) } };
                },
                .call => |call| if (try executeReturningCall(body, slots, call_scratch, destination, instruction_index, call, executor, gpa, storage)) |result| return result,
                .variant_tag => |operand| switch (try variantTag(body, (try readSlot(slots, operand, executor, gpa)) orelse return .unavailable, operand, executor)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .variant_coerce => |operation| switch (try coerceVariant(body, (try readSlot(slots, operation.operand, executor, gpa)) orelse return .unavailable, operation, executor)) {
                    .returned => |value| try store(slots, destination, operation.destination, value, executor),
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .variant_extract => |operation| switch (try extractVariant(body, (try readSlot(slots, operation.operand, executor, gpa)) orelse return .unavailable, operation, executor)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .local_storage, .result_storage => |type_id| {
                    const cell = try storage.create(Cell);
                    cell.* = .{ .type_id = type_id, .storage = storage, .contents = .uninitialized };
                    slots[destination] = .{ .place = cell };
                },
                .storage_projection => |operation| switch (try projectStorage(body, slots, operation, executor, storage)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .array_element => |operation| switch (try projectArray(body, slots, operation, executor, storage)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .borrow_address => |operation| switch (try borrowAddress(body, slots, operation, executor, storage)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .borrow_read => |operation| {
                    if (try readStaticReference(slots[@backingInt(operation.source)], executor)) |value| {
                        slots[destination] = value;
                        continue;
                    }
                    const target = referenceTarget(slots[@backingInt(operation.source)]) orelse return executionError(.unsupported_operation, instructionSpan(body, instruction_index));
                    std.debug.assert(target.type_id == operation.type_id);
                    slots[destination] = .{ .place = target };
                },
                .borrow_write => |operation| {
                    const target = referenceTarget(slots[@backingInt(operation.reference)]) orelse return executionError(.unsupported_operation, instructionSpan(body, instruction_index));
                    std.debug.assert(target.type_id == operation.type_id);
                    try assignCell(target, slots[@backingInt(operation.value)], executor);
                    slots[destination] = .{ .runtime = .unit };
                },
                .allocation_element => |operation| {
                    const allocation = allocationRecord(slots[@backingInt(operation.allocation)]);
                    std.debug.assert(allocation.element_type == operation.type_id);
                    slots[destination] = .{ .place = try allocation.element(@intCast(integer(slots, operation.index))) };
                },
                .borrow_box => |operation| {
                    const allocation = allocationRecord(slots[@backingInt(operation.source)]);
                    slots[destination] = try referenceValue(operation.type_id, try allocation.element(0), storage);
                },
                .value_copy => |operation| {
                    var copied = (try readSlot(slots, operation.source, executor, gpa)) orelse return .unavailable;
                    if (copied == .runtime and copied.runtime == .storage_cursor)
                        copied.runtime.storage_cursor.type_id = operation.type_id;
                    if (operation.destination == null and copied == .place) {
                        const cell = try storage.create(Cell);
                        cell.* = .{ .type_id = operation.type_id, .storage = storage, .contents = .uninitialized };
                        try assignCell(cell, copied, executor);
                        copied = .{ .place = cell };
                    }
                    try store(slots, destination, operation.destination, copied, executor);
                },
                .field_access => |operation| switch (try accessField(slots[@backingInt(operation.operand)], operation, executor, gpa, storage)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .mut_parameter_write => |operation| {
                    std.debug.assert(operation.parameter_index < arguments.len);
                    const updated = (try readSlot(slots, operation.value, executor, gpa)) orelse return .unavailable;
                    if (arguments[operation.parameter_index] == .place) {
                        try assignCell(arguments[operation.parameter_index].place, updated, executor);
                    } else arguments[operation.parameter_index] = updated;
                    slots[destination] = .{ .runtime = .unit };
                },
                .call_mut_argument => |operation| {
                    const index = operation.arguments.start + operation.argument_index;
                    std.debug.assert(index < operation.arguments.end);
                    try store(slots, destination, operation.destination, call_scratch[index], executor);
                },
            }
        }

        switch (block.terminator) {
            .branch => |branch| switch (try branchTarget(body, slots, scratch, branch, executor, gpa, storage)) {
                .next => |next| block_id = next,
                .result => |result| return result,
            },
            .predicate_branch => |predicate| {
                const branch = if (predicateValue(slots, predicate.operation, predicate.operands))
                    predicate.then_branch
                else
                    predicate.else_branch;
                switch (try branchTarget(body, slots, scratch, branch, executor, gpa, storage)) {
                    .next => |next| block_id = next,
                    .result => |result| return result,
                }
            },
            .return_unit => return .{ .returned = .{ .runtime = .unit } },
            .return_value => |value_use| return valueUse(body, slots, value_use, executor, gpa),
            .return_failure => return .failure,
            .diverge => unreachable,
            .fallible_call => |fallible| switch (try executeFallibleCall(body, slots, call_scratch, fallible.call, fallible.success, fallible.failure, terminatorSpan(body, block_id), executor, gpa, storage)) {
                .next => |next| block_id = next,
                .result => |result| return result,
            },
        }
    }
}

fn executionError(reason: ExecutionErrorReason, span: ?structures.SourceSpan) Result {
    return .{ .execution_error = .{
        .reason = reason,
        .span = span,
    } };
}

fn instructionSpan(body: *const structures.FunctionBodyAnalysis, instruction_index: usize) ?structures.SourceSpan {
    return if (body.instruction_spans.len == body.instructions.len) body.instruction_spans[instruction_index] else null;
}

fn terminatorSpan(body: *const structures.FunctionBodyAnalysis, block_id: structures.FunctionBlockId) ?structures.SourceSpan {
    return if (body.terminator_spans.len == body.blocks.len) body.terminator_spans[@backingInt(block_id)] else null;
}

fn initializerValue(body: *const structures.FunctionBodyAnalysis, slots: []Value, reference: @FieldType(structures.FunctionInstruction, "initializer_ref"), storage: std.mem.Allocator) !Value {
    const source = body.initializer_captures[reference.captures.start..reference.captures.end];
    const captures = try storage.alloc(Value, source.len);
    for (source, captures) |capture, *value| value.* = if (slots[@backingInt(capture)] == .initializer) slots[@backingInt(capture)] else .{ .place = try storageCell(body, slots, capture, storage) };
    return .{ .initializer = .{ .body = &body.initializer_regions[reference.region], .captures = captures } };
}

fn integer(slots: []const Value, value: structures.FunctionValueId) i32 {
    return scalar(slots, value).int;
}

fn scalar(slots: []const Value, value: structures.FunctionValueId) structures.CompileTimeValue.RuntimeValue {
    return switch (slots[@backingInt(value)]) {
        .runtime => |runtime| runtime,
        .place => |cell| cell.contents.value,
        .type, .initializer => unreachable,
    };
}

fn predicateValue(
    slots: []const Value,
    operation: structures.PredicateOperation,
    operands: structures.BinaryOperands,
) bool {
    return switch (operation) {
        .lti => predicateInteger(slots, operands.lhs) < predicateInteger(slots, operands.rhs),
        .gti => predicateInteger(slots, operands.lhs) > predicateInteger(slots, operands.rhs),
        .lei => predicateInteger(slots, operands.lhs) <= predicateInteger(slots, operands.rhs),
        .gei => predicateInteger(slots, operands.lhs) >= predicateInteger(slots, operands.rhs),
        .eqi => predicateInteger(slots, operands.lhs) == predicateInteger(slots, operands.rhs),
        .nei => predicateInteger(slots, operands.lhs) != predicateInteger(slots, operands.rhs),
        .eqb => scalar(slots, operands.lhs).bool == scalar(slots, operands.rhs).bool,
        .neb => scalar(slots, operands.lhs).bool != scalar(slots, operands.rhs).bool,
        .eqt => slots[@backingInt(operands.lhs)].type == slots[@backingInt(operands.rhs)].type,
        .net => slots[@backingInt(operands.lhs)].type != slots[@backingInt(operands.rhs)].type,
    };
}

fn predicateInteger(slots: []const Value, value: structures.FunctionValueId) i64 {
    return switch (scalar(slots, value)) {
        .int => |integer_value| integer_value,
        .int_literal => |literal| literal,
        else => unreachable,
    };
}

fn executeCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []Value,
    scratch: []Value,
    call: structures.FunctionCall,
    call_span: ?structures.SourceSpan,
    executor: anytype,
    gpa: std.mem.Allocator,
    storage: std.mem.Allocator,
) !Result {
    if (call.target == .initializer) {
        const initializer = slots[@backingInt(call.target.initializer)].initializer;
        return executeInStorage(initializer.body, initializer.captures, executor, gpa, storage);
    }
    const instance = switch (call.target) {
        .direct => |instance| instance,
        .indirect => |value| scalar(slots, value).function_ref.instance(),
        .initializer => unreachable,
    };
    const arguments = body.call_arguments[call.arguments.start..call.arguments.end];
    const interpreted = scratch[call.arguments.start..call.arguments.end];
    for (arguments, interpreted) |argument, *destination| {
        if (argument == .initializer) {
            destination.* = slots[@backingInt(argument.initializer)];
            std.debug.assert(destination.* == .initializer);
            continue;
        }
        const use = argument.valueUse();
        if (use.coerce_to == null and try executor.argumentPassing(body.valueType(use.value)) == .indirect) {
            destination.* = .{ .place = try storageCell(body, slots, use.value, storage) };
            continue;
        }
        switch (try valueUse(body, slots, use, executor, gpa)) {
            .returned => |value| destination.* = try copyStoredValue(value, use.coerce_to orelse body.valueType(use.value), executor, storage),
            else => |result| return result,
        }
    }
    return executor.callInStorage(instance, interpreted, call_span, storage);
}

fn executeReturningCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []Value,
    scratch: []Value,
    destination: usize,
    instruction_index: usize,
    call: structures.FunctionCall,
    executor: anytype,
    gpa: std.mem.Allocator,
    storage: std.mem.Allocator,
) !?Result {
    return switch (atSpan(
        try executeCall(body, slots, scratch, call, instructionSpan(body, instruction_index), executor, gpa, storage),
        instructionSpan(body, instruction_index),
    )) {
        .returned => |value| blk: {
            try store(slots, destination, call.destination, value, executor);
            break :blk null;
        },
        .failure => unreachable,
        .exit => |status| .{ .exit = status },
        .execution_error => |value| .{ .execution_error = value },
        .reported_error => .reported_error,
        .unavailable => .unavailable,
    };
}

const Step = union(enum) {
    next: structures.FunctionBlockId,
    result: Result,
};

fn executeFallibleCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []Value,
    scratch: []Value,
    call: structures.FunctionCall,
    success_id: structures.FunctionBlockId,
    failure_id: ?structures.FunctionBlockId,
    call_span: ?structures.SourceSpan,
    executor: anytype,
    gpa: std.mem.Allocator,
    storage: std.mem.Allocator,
) !Step {
    return switch (try executeCall(body, slots, scratch, call, call_span, executor, gpa, storage)) {
        .returned => |value| blk: {
            const success = body.blocks[@backingInt(success_id)];
            std.debug.assert(success.argument_end - success.argument_start == 1);
            try store(slots, success.argument_start, call.destination, value, executor);
            break :blk .{ .next = success_id };
        },
        .failure => .{ .next = failure_id orelse unreachable },
        .exit => |status| .{ .result = .{ .exit = status } },
        .execution_error => |value| .{ .result = .{ .execution_error = value } },
        .reported_error => .{ .result = .reported_error },
        .unavailable => .{ .result = .unavailable },
    };
}

fn store(slots: []Value, own: usize, destination: ?structures.FunctionValueId, value: Value, executor: anytype) !void {
    const storage = destination orelse {
        slots[own] = value;
        return;
    };
    switch (slots[@backingInt(storage)]) {
        .place => |cell| try assignCell(cell, value, executor),
        .runtime => slots[@backingInt(storage)] = value,
        .type, .initializer => unreachable,
    }
    slots[own] = .{ .runtime = .unit };
}

fn readSlot(slots: []const Value, value: structures.FunctionValueId, executor: anytype, gpa: std.mem.Allocator) !?Value {
    return switch (slots[@backingInt(value)]) {
        .place => |cell| if (containsReference(cell)) .{ .place = cell } else if (try materialize(cell, executor, gpa)) |runtime| .{ .runtime = runtime } else null,
        else => |ordinary| ordinary,
    };
}

fn copyStoredValue(value: Value, type_id: structures.TypeId, executor: anytype, storage: std.mem.Allocator) !Value {
    if (value != .place) return value;
    const copy = try storage.create(Cell);
    copy.* = .{ .type_id = type_id, .storage = storage, .contents = .uninitialized };
    try assignCell(copy, value, executor);
    return .{ .place = copy };
}

fn storageCell(body: *const structures.FunctionBodyAnalysis, slots: []Value, value: structures.FunctionValueId, storage: std.mem.Allocator) !*Cell {
    const slot = &slots[@backingInt(value)];
    if (slot.* == .place) return slot.place;
    std.debug.assert(slot.* == .runtime);
    const cell = try storage.create(Cell);
    cell.* = .{ .type_id = body.valueType(value), .storage = storage, .contents = .{ .value = slot.runtime } };
    slot.* = .{ .place = cell };
    return cell;
}

fn arrayType(executor: anytype, type_id: structures.TypeId) !?structures.ArrayType {
    return executor.arrayType(type_id);
}

pub fn containsReference(cell: *const Cell) bool {
    switch (cell.contents) {
        .reference, .storage_cursor, .allocation => return true,
        .fields => |fields| for (fields) |*field| {
            if (containsReference(field)) return true;
        },
        .variant_payload => |payload| return containsReference(payload),
        .uninitialized, .value => {},
    }
    return false;
}

pub fn referenceTarget(value: Value) ?*Cell {
    if (value != .place or value.place.contents != .reference) return null;
    return value.place.contents.reference;
}

pub fn referenceValue(type_id: structures.TypeId, target: *Cell, storage: std.mem.Allocator) !Value {
    const cell = try storage.create(Cell);
    cell.* = .{ .type_id = type_id, .storage = storage, .contents = .{ .reference = target } };
    return .{ .place = cell };
}

pub fn assignCell(destination: *Cell, source: Value, executor: anytype) anyerror!void {
    if (source == .place and destination == source.place) return;
    if (destination.contents == .allocation) {
        if (try arrayType(executor, destination.type_id)) |array| {
            const allocation = destination.contents.allocation;
            std.debug.assert(array.element_type == allocation.element_type);
            std.debug.assert(array.length <= allocation.capacity);
            for (0..array.length) |index| {
                const element = try allocation.element(@intCast(index));
                if (source == .place and source.place.contents == .fields) {
                    try assignCell(element, .{ .place = &source.place.contents.fields[index] }, executor);
                } else if (source == .place and source.place.contents == .allocation) {
                    try assignCell(element, .{ .place = try source.place.contents.allocation.element(@intCast(index)) }, executor);
                } else {
                    const runtime = if (source == .place) source.place.contents.value else source.runtime;
                    const values = try executor.lookupTuple(runtime.structure);
                    const value = (try executor.lookupRuntime(values[index])) orelse return error.Unavailable;
                    try assignRuntime(element, value.value, executor);
                }
            }
            return;
        }
    }
    switch (source) {
        .runtime => |runtime| try assignRuntime(destination, runtime, executor),
        .place => |cell| {
            if (destination == cell) return;
            switch (cell.contents) {
                .value => |runtime| try assignRuntime(destination, runtime, executor),
                .uninitialized => destination.contents = .uninitialized,
                .storage_cursor => |pointer| destination.contents = .{ .storage_cursor = pointer },
                .reference => |target| destination.contents = .{ .reference = target },
                .allocation => |allocation| {
                    if (try arrayType(executor, cell.type_id)) |array| {
                        const copied = try destination.storage.alloc(Cell, array.length);
                        for (copied, 0..) |*copy, index| {
                            copy.* = .{ .type_id = array.element_type, .storage = destination.storage, .contents = .uninitialized };
                            try assignCell(copy, .{ .place = try allocation.element(@intCast(index)) }, executor);
                        }
                        destination.contents = .{ .fields = copied };
                    } else destination.contents = .{ .allocation = allocation };
                },
                .fields => |fields| {
                    if (destination.contents != .fields) {
                        const copied = try destination.storage.alloc(Cell, fields.len);
                        for (fields, copied) |field, *copy| copy.* = .{ .type_id = field.type_id, .storage = destination.storage, .contents = .uninitialized };
                        destination.contents = .{ .fields = copied };
                    }
                    std.debug.assert(destination.contents.fields.len == fields.len);
                    for (fields, destination.contents.fields) |*field, *copy| {
                        std.debug.assert(copy.type_id == .never or copy.type_id == field.type_id);
                        copy.type_id = field.type_id;
                        try assignCell(copy, .{ .place = field }, executor);
                    }
                },
                .variant_payload => |payload| {
                    if (destination.contents != .variant_payload) {
                        const copied = try destination.storage.create(Cell);
                        copied.* = .{ .type_id = payload.type_id, .storage = destination.storage, .contents = .uninitialized };
                        destination.contents = .{ .variant_payload = copied };
                    }
                    destination.contents.variant_payload.type_id = payload.type_id;
                    try assignCell(destination.contents.variant_payload, .{ .place = payload }, executor);
                },
            }
        },
        .type, .initializer => unreachable,
    }
}

fn assignRuntime(destination: *Cell, runtime: structures.CompileTimeValue.RuntimeValue, executor: anytype) anyerror!void {
    if (destination.contents == .fields and runtime == .structure) {
        const values = try executor.lookupTuple(runtime.structure);
        std.debug.assert(values.len == destination.contents.fields.len);
        for (values, destination.contents.fields) |value_id, *field| {
            const value = (try executor.lookupRuntime(value_id)) orelse return error.Unavailable;
            std.debug.assert(field.type_id == .never or field.type_id == value.type_id);
            field.type_id = value.type_id;
            try assignRuntime(field, value.value, executor);
        }
        return;
    }
    if (destination.contents == .variant_payload and runtime == .variant) {
        const payload = destination.contents.variant_payload;
        const value = (try executor.lookupRuntime(runtime.variant.payload)) orelse return error.Unavailable;
        payload.type_id = value.type_id;
        try assignRuntime(payload, value.value, executor);
        return;
    }
    destination.contents = .{ .value = runtime };
}

fn expandFields(cell: *Cell, executor: anytype) !bool {
    switch (cell.contents) {
        .uninitialized => {
            const array = try arrayType(executor, cell.type_id);
            const count = if (array) |shape| shape.length else (try executor.structFieldCount(cell.type_id)) orelse return false;
            const fields = try cell.storage.alloc(Cell, count);
            for (fields) |*field| field.* = .{ .type_id = if (array) |shape| shape.element_type else .never, .storage = cell.storage, .contents = .uninitialized };
            cell.contents = .{ .fields = fields };
        },
        .value => |runtime| {
            std.debug.assert(runtime == .structure);
            const values = try executor.lookupTuple(runtime.structure);
            const array = try arrayType(executor, cell.type_id);
            if (array) |shape| std.debug.assert(values.len == shape.length);
            const fields = try cell.storage.alloc(Cell, values.len);
            for (values, fields) |value_id, *field| {
                const value = (try executor.lookupRuntime(value_id)) orelse return false;
                if (array) |shape| std.debug.assert(value.type_id == shape.element_type);
                field.* = .{ .type_id = value.type_id, .storage = cell.storage, .contents = .{ .value = value.value } };
            }
            cell.contents = .{ .fields = fields };
        },
        .fields => {},
        .variant_payload, .reference, .storage_cursor, .allocation => unreachable,
    }
    return true;
}

fn projectArray(body: *const structures.FunctionBodyAnalysis, slots: []Value, operation: structures.ArrayElement, executor: anytype, storage: std.mem.Allocator) !Result {
    const cell = try storageCell(body, slots, operation.array, storage);
    const array = (try arrayType(executor, cell.type_id)) orelse return .unavailable;
    std.debug.assert(array.element_type == operation.type_id);
    const index = integer(slots, operation.index);
    std.debug.assert(index >= 0);
    std.debug.assert(@as(u32, @intCast(index)) < array.length);
    if (cell.contents == .allocation) return .{ .returned = .{ .place = try cell.contents.allocation.element(@intCast(index)) } };
    if (!try expandFields(cell, executor)) return .unavailable;
    return .{ .returned = .{ .place = &cell.contents.fields[@intCast(index)] } };
}

fn borrowAddress(body: *const structures.FunctionBodyAnalysis, slots: []Value, operation: structures.BorrowAddressOperation, executor: anytype, storage: std.mem.Allocator) !Result {
    var target = if (operation.base_is_reference)
        referenceTarget(slots[@backingInt(operation.source)]) orelse return executionError(.unsupported_operation, null)
    else
        try storageCell(body, slots, operation.source, storage);
    for (body.borrow_fields[operation.fields.start..operation.fields.end]) |projection| switch (projection) {
        .field => |index| {
            if (!try expandFields(target, executor)) return .unavailable;
            const field = &target.contents.fields[index];
            if (field.type_id == .never) field.type_id = (try executor.structFieldType(target.type_id, index)) orelse return .unavailable;
            target = field;
        },
        .variant => |member| target = (try borrowVariantCell(target, member, executor)) orelse return .unavailable,
    };
    return .{ .returned = try referenceValue(operation.type_id, target, storage) };
}

fn borrowVariantCell(target: *Cell, member: structures.TypeId, executor: anytype) !?*Cell {
    if (target.contents == .value) {
        const value = (try executor.lookupRuntime(target.contents.value.variant.payload)) orelse return null;
        std.debug.assert(value.type_id == member);
        const payload = try target.storage.create(Cell);
        payload.* = .{ .type_id = member, .storage = target.storage, .contents = .{ .value = value.value } };
        target.contents = .{ .variant_payload = payload };
    }
    std.debug.assert(target.contents == .variant_payload);
    std.debug.assert(target.contents.variant_payload.type_id == member);
    return target.contents.variant_payload;
}

fn materialize(cell: *const Cell, executor: anytype, gpa: std.mem.Allocator) !?structures.CompileTimeValue.RuntimeValue {
    switch (cell.contents) {
        .value => |value| return value,
        .reference, .storage_cursor, .allocation => return null,
        .uninitialized => {
            std.debug.assert(cell.type_id != .never);
            if (try arrayType(executor, cell.type_id)) |array| {
                if (array.length != 0) return null;
                return .{ .structure = try executor.internTuple(&.{}) };
            }
            const field_count = (try executor.structFieldCount(cell.type_id)) orelse return null;
            if (field_count != 0) return null;
            return .{ .structure = try executor.internTuple(&.{}) };
        },
        .fields => |fields| {
            const values = try gpa.alloc(structures.CompileTimeValueId, fields.len);
            defer gpa.free(values);
            for (fields, values) |*field, *value_id| {
                const value = (try materialize(field, executor, gpa)) orelse return null;
                value_id.* = try executor.internRuntime(field.type_id, value);
            }
            return .{ .structure = try executor.internTuple(values) };
        },
        .variant_payload => |payload| {
            const value = (try materialize(payload, executor, gpa)) orelse return null;
            return variantValue(payload.type_id, try executor.internRuntime(payload.type_id, value));
        },
    }
}

fn projectStorage(
    body: *const structures.FunctionBodyAnalysis,
    slots: []Value,
    operation: structures.StorageProjection,
    executor: anytype,
    storage: std.mem.Allocator,
) !Result {
    const cell = try storageCell(body, slots, operation.owner, storage);
    switch (operation.projection) {
        .field => |index| {
            if (!try expandFields(cell, executor)) return .unavailable;
            const field = &cell.contents.fields[index];
            std.debug.assert(field.type_id == .never or field.type_id == operation.type_id);
            field.type_id = operation.type_id;
            return .{ .returned = .{ .place = field } };
        },
        .variant => {
            switch (cell.contents) {
                .uninitialized => {
                    const payload = try cell.storage.create(Cell);
                    payload.* = .{ .type_id = operation.type_id, .storage = cell.storage, .contents = .uninitialized };
                    cell.contents = .{ .variant_payload = payload };
                },
                .value => |owner| {
                    const active = try activeVariant(body, .{ .runtime = owner }, operation.owner, executor);
                    const payload = try cell.storage.create(Cell);
                    payload.* = .{ .type_id = operation.type_id, .storage = cell.storage, .contents = .uninitialized };
                    if (active.member_type == operation.type_id)
                        try assignCell(payload, active.payload, executor);
                    cell.contents = .{ .variant_payload = payload };
                },
                .variant_payload => |payload| if (payload.type_id != operation.type_id) {
                    payload.* = .{ .type_id = operation.type_id, .storage = cell.storage, .contents = .uninitialized };
                },
                .fields, .reference, .storage_cursor, .allocation => unreachable,
            }
            return .{ .returned = .{ .place = cell.contents.variant_payload } };
        },
        .box_element => return .{ .returned = .{ .place = try allocationRecord(.{ .place = cell }).element(0) } },
        .allocation_array => {
            const allocation = allocationRecord(.{ .place = cell });
            const array = (try arrayType(executor, operation.type_id)) orelse return .unavailable;
            std.debug.assert(array.element_type == allocation.element_type);
            std.debug.assert(array.length <= allocation.capacity);
            return .{ .returned = try allocationValue(operation.type_id, allocation, storage) };
        },
    }
}

fn accessField(
    value: Value,
    operation: structures.FieldAccessOperation,
    executor: anytype,
    gpa: std.mem.Allocator,
    storage: std.mem.Allocator,
) !Result {
    if (value == .place and value.place.contents == .fields) {
        const fields = value.place.contents.fields;
        std.debug.assert(operation.field_index < fields.len);
        const field = &fields[operation.field_index];
        std.debug.assert(field.type_id == operation.field_type);
        if (containsReference(field)) return .{ .returned = try copyStoredValue(.{ .place = field }, operation.field_type, executor, storage) };
        const field_value = (try materialize(field, executor, gpa)) orelse return .unavailable;
        return .{ .returned = .{ .runtime = field_value } };
    }
    const owner = if (value == .place) value.place.contents.value else value.runtime;
    const fields = try executor.lookupTuple(owner.structure);
    std.debug.assert(operation.field_index < fields.len);
    const field = (try executor.lookupRuntime(fields[operation.field_index])) orelse return .unavailable;
    std.debug.assert(field.type_id == operation.field_type);
    return .{ .returned = .{ .runtime = field.value } };
}

const ActiveVariant = struct {
    member_type: structures.TypeId,
    payload: Value,
};

fn activeVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: Value,
    operand: structures.FunctionValueId,
    executor: anytype,
) !ActiveVariant {
    if (value == .place and value.place.contents == .variant_payload) {
        const payload = value.place.contents.variant_payload;
        return .{ .member_type = payload.type_id, .payload = .{ .place = payload } };
    }
    if (value == .runtime and value.runtime == .variant) {
        const payload = (try executor.lookupRuntime(value.runtime.variant.payload)) orelse return error.Unavailable;
        return .{ .member_type = value.runtime.variant.member_type, .payload = .{ .runtime = payload.value } };
    }
    const source_type = body.valueType(operand);
    std.debug.assert(try executor.variantMembers(source_type) == null);
    return .{ .member_type = source_type, .payload = value };
}

fn variantTag(
    body: *const structures.FunctionBodyAnalysis,
    value: Value,
    operand: structures.FunctionValueId,
    executor: anytype,
) !Result {
    const active = try activeVariant(body, value, operand, executor);
    const members = (try executor.variantMembers(body.valueType(operand))) orelse unreachable;
    for (members, 0..) |member, tag| if (member == active.member_type) return .{ .returned = .{ .runtime = .{ .int = @intCast(tag) } } };
    unreachable;
}

fn variantValue(member_type: structures.TypeId, payload: structures.CompileTimeValueId) structures.CompileTimeValue.RuntimeValue {
    return .{ .variant = .{ .member_type = member_type, .payload = payload } };
}

pub fn storedVariantValue(type_id: structures.TypeId, member_type: structures.TypeId, payload: Value, executor: anytype) !Value {
    if (payload == .runtime) return .{ .runtime = variantValue(member_type, try executor.internRuntime(member_type, payload.runtime)) };
    std.debug.assert(payload == .place);
    const storage = payload.place.storage;
    const member = try storage.create(Cell);
    member.* = .{ .type_id = member_type, .storage = storage, .contents = .uninitialized };
    try assignCell(member, payload, executor);
    const variant = try storage.create(Cell);
    variant.* = .{ .type_id = type_id, .storage = storage, .contents = .{ .variant_payload = member } };
    return .{ .place = variant };
}

fn coerceVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: Value,
    operation: structures.VariantOperation,
    executor: anytype,
) !Result {
    const mapping = body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
    const source_type = body.valueType(operation.operand);
    const source_members = try executor.variantMembers(source_type);
    const active = try activeVariant(body, value, operation.operand, executor);
    const source_tag: usize = if (source_members) |members| blk: {
        break :blk for (members, 0..) |member, tag| {
            if (member == active.member_type) break tag;
        } else unreachable;
    } else 0;
    std.debug.assert(source_tag < mapping.len);
    const target_tag = mapping[source_tag];
    std.debug.assert(target_tag != structures.invalid_variant_tag);
    const target_members = (try executor.variantMembers(operation.target_type)) orelse unreachable;
    std.debug.assert(target_tag < target_members.len);
    if (value == .runtime) {
        const payload = if (value.runtime == .variant) value.runtime.variant.payload else try executor.internRuntime(source_type, value.runtime);
        return .{ .returned = .{ .runtime = variantValue(target_members[target_tag], payload) } };
    }
    return .{ .returned = try storedVariantValue(operation.target_type, target_members[target_tag], active.payload, executor) };
}

fn extractVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: Value,
    operation: structures.VariantOperation,
    executor: anytype,
) !Result {
    const active = try activeVariant(body, value, operation.operand, executor);
    if (try executor.variantMembers(operation.target_type)) |target_members| {
        const source_members = (try executor.variantMembers(body.valueType(operation.operand))).?;
        const source_tag = for (source_members, 0..) |member, tag| {
            if (member == active.member_type) break tag;
        } else unreachable;
        const mapping = body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
        const target_tag = mapping[source_tag];
        std.debug.assert(target_tag != structures.invalid_variant_tag);
        std.debug.assert(target_tag < target_members.len);
        if (value == .runtime and value.runtime == .variant)
            return .{ .returned = .{ .runtime = variantValue(target_members[target_tag], value.runtime.variant.payload) } };
        return .{ .returned = try storedVariantValue(operation.target_type, target_members[target_tag], active.payload, executor) };
    }
    if (value == .runtime and value.runtime == .variant) {
        const payload = (try executor.lookupRuntime(value.runtime.variant.payload)) orelse return .unavailable;
        if (payload.type_id == operation.target_type) return .{ .returned = .{ .runtime = payload.value } };
        var reference = payload.value.function_ref;
        reference.type_id = operation.target_type;
        return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
    }
    if (active.member_type == operation.target_type) return .{ .returned = active.payload };
    var reference = active.payload.runtime.function_ref;
    reference.type_id = operation.target_type;
    return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
}

fn atSpan(result: Result, span: ?structures.SourceSpan) Result {
    return switch (result) {
        .execution_error => |value| if (value.span == null)
            executionError(value.reason, span)
        else
            result,
        else => result,
    };
}

fn valueUse(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const Value,
    use: structures.FunctionValueUse,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Result {
    const value = (try readSlot(slots, use.value, executor, gpa)) orelse return .unavailable;
    const target = use.coerce_to orelse return .{ .returned = value };
    if (use.variant_tag_mapping) |mapping| return coerceVariant(body, value, .{
        .operand = use.value,
        .target_type = target,
        .tag_mapping = mapping,
    }, executor);
    var reference = value.runtime.function_ref;
    reference.type_id = target;
    return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
}

fn branchTarget(
    body: *const structures.FunctionBodyAnalysis,
    slots: []Value,
    scratch: []Value,
    branch: structures.FunctionBranch,
    executor: anytype,
    gpa: std.mem.Allocator,
    storage: std.mem.Allocator,
) !Step {
    const target = body.blocks[@backingInt(branch.target)];
    const arguments = body.branch_arguments[branch.arguments.start..branch.arguments.end];
    std.debug.assert(arguments.len == target.argument_end - target.argument_start);
    for (arguments, scratch[0..arguments.len], body.block_arguments[target.argument_start..target.argument_end]) |argument, *temporary, parameter| {
        if (parameter.representation == .storage or try executor.argumentPassing(parameter.type_id) == .indirect) {
            std.debug.assert(argument.coerce_to == null);
            temporary.* = .{ .place = try storageCell(body, slots, argument.value, storage) };
            continue;
        }
        switch (try valueUse(body, slots, argument, executor, gpa)) {
            .returned => |value| temporary.* = value,
            else => |result| return .{ .result = result },
        }
    }
    @memcpy(slots[target.argument_start..target.argument_end], scratch[0..arguments.len]);
    return .{ .next = branch.target };
}

fn storageCursor(body: *const structures.FunctionBodyAnalysis, slots: []Value, operation: structures.BorrowOperation, executor: anytype, storage: std.mem.Allocator) !Result {
    if (body.valueType(operation.source) == .static_data) return .{ .returned = .{ .runtime = .{ .storage_cursor = .{ .type_id = operation.type_id, .data = scalar(slots, operation.source).static_data } } } };
    const owner = try storageCell(body, slots, operation.source, storage);
    if (owner.contents != .allocation and !try expandFields(owner, executor)) return .unavailable;
    const cell = try storage.create(Cell);
    cell.* = .{ .type_id = operation.type_id, .storage = storage, .contents = .{ .storage_cursor = .{ .owner = owner, .offset = 0 } } };
    return .{ .returned = .{ .place = cell } };
}

fn offsetStorageCursor(source: Value, type_id: structures.TypeId, offset: u32, storage: std.mem.Allocator) !Value {
    switch (source) {
        .runtime => |runtime| {
            var cursor = runtime.storage_cursor;
            cursor.type_id = type_id;
            cursor.offset = std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge;
            return .{ .runtime = .{ .storage_cursor = cursor } };
        },
        .place => |cell| {
            if (cell.contents == .value) return offsetStorageCursor(.{ .runtime = cell.contents.value }, type_id, offset, storage);
            var cursor = cell.contents.storage_cursor;
            cursor.offset = std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge;
            const result = try storage.create(Cell);
            result.* = .{ .type_id = type_id, .storage = storage, .contents = .{ .storage_cursor = cursor } };
            return .{ .place = result };
        },
        .type, .initializer => unreachable,
    }
}

fn storageCursorElement(source: Value, type_id: structures.TypeId, offset: u32, storage: std.mem.Allocator) !Value {
    switch (source) {
        .runtime => return offsetStorageCursor(source, type_id, offset, storage),
        .place => |cell| {
            if (cell.contents == .value) return storageCursorElement(.{ .runtime = cell.contents.value }, type_id, offset, storage);
            const cursor = cell.contents.storage_cursor;
            const index = std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge;
            const element = if (cursor.owner.contents == .allocation)
                try cursor.owner.contents.allocation.element(index)
            else
                &cursor.owner.contents.fields[index];
            return referenceValue(type_id, element, storage);
        },
        .type, .initializer => unreachable,
    }
}

fn readStaticReference(source: Value, executor: anytype) !?Value {
    switch (source) {
        .runtime => |runtime| {
            if (runtime != .storage_cursor) return null;
            const cursor = runtime.storage_cursor;
            const bytes = try executor.byteString(cursor.data orelse unreachable);
            return .{ .runtime = .{ .byte = bytes[cursor.offset] } };
        },
        .place => |cell| return if (cell.contents == .value) readStaticReference(.{ .runtime = cell.contents.value }, executor) else null,
        .type, .initializer => unreachable,
    }
}

pub fn allocationRecord(value: Value) *Allocation {
    std.debug.assert(value == .place);
    const cell = value.place;
    if (cell.contents == .fields) {
        std.debug.assert(cell.contents.fields.len == 1);
        return allocationRecord(.{ .place = &cell.contents.fields[0] });
    }
    std.debug.assert(cell.contents == .allocation);
    return cell.contents.allocation;
}

pub fn allocationValue(type_id: structures.TypeId, allocation: *Allocation, storage: std.mem.Allocator) !Value {
    const cell = try storage.create(Cell);
    cell.* = .{ .type_id = type_id, .storage = storage, .contents = .{ .allocation = allocation } };
    return .{ .place = cell };
}
