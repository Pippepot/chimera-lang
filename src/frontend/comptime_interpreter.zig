const std = @import("std");
const structures = @import("../structures.zig");

pub const ExecutionErrorReason = union(enum) {
    call_cycle,
    division_by_zero,
    unsupported_operation,
    escaping_storage,
    panic: structures.ByteStringId,
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

    pub fn allocateValue(self: *Heap, type_id: structures.TypeId, element_type: structures.TypeId, element_size: u32, count: i32, storage: std.mem.Allocator) !?Value {
        if (allocationByteSize(element_size, count) == null) return null;
        return try allocationValue(type_id, try self.allocate(element_type, @intCast(count)), storage);
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
        const cell = try Cell.create(self.identities, self.element_type, .uninitialized);
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

    fn create(storage: std.mem.Allocator, type_id: structures.TypeId, contents: @FieldType(Cell, "contents")) !*Cell {
        const cell = try storage.create(Cell);
        cell.* = .{ .type_id = type_id, .storage = storage, .contents = contents };
        return cell;
    }

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
                .initializer => |initializer| return .{ .initializer = .{ .body = initializer.body, .captures = try self.cloneValues(initializer.captures) } },
            }
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
    if (result != .returned) return result;
    for (arguments, modes) |*argument, mode| {
        if ((mode != .mut and mode != .ref) or argument.* != .place) continue;
        const published = try publishCell(argument.place, executor, gpa, null);
        if (published != .returned) return published;
        argument.* = published.returned;
    }
    if (result == .returned and result.returned == .place) return publishCell(result.returned.place, executor, gpa, null);
    if (result == .returned and result.returned == .initializer) return executionError(.escaping_storage, null);
    return result;
}

/// A value leaving its evaluation must not retain evaluation-owned storage.
fn publishCell(cell: *const Cell, executor: anytype, gpa: std.mem.Allocator, span: ?structures.SourceSpan) !Result {
    if (containsReference(cell)) return executionError(.escaping_storage, span);
    const runtime = (try materialize(cell, executor, gpa)) orelse return executionError(.unsupported_operation, span);
    return .{ .returned = .{ .runtime = runtime } };
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

    const entry = body.blocks[@backingInt(body.entry)];
    std.debug.assert(entry.argument_start == 0);
    std.debug.assert(entry.argument_end == arguments.len);
    @memcpy(slots[entry.argument_start..entry.argument_end], arguments);
    for (body.block_arguments[entry.argument_start..entry.argument_end], arguments, 0..) |parameter, *argument, index| {
        if (parameter.representation != .storage or argument.* != .runtime) continue;
        argument.* = .{ .place = try storageCell(body, slots, @fromBackingInt(@intCast(index)), storage) };
    }
    const execution: ExecutionFrame(@TypeOf(executor)) = .{
        .body = body,
        .arguments = arguments,
        .slots = slots,
        .scratch = scratch,
        .call_scratch = call_scratch,
        .executor = executor,
        .gpa = gpa,
        .storage = storage,
    };
    return execution.run();
}

const Step = union(enum) {
    next: structures.FunctionBlockId,
    result: Result,
};

/// Borrows one dense frame and its call-lived storage. Instruction evaluation
/// produces a value or control result; this boundary owns result placement.
fn ExecutionFrame(comptime Executor: type) type {
    return struct {
        const Self = @This();
        body: *const structures.FunctionBodyAnalysis,
        arguments: []Value,
        slots: []Value,
        scratch: []Value,
        call_scratch: []Value,
        executor: Executor,
        gpa: std.mem.Allocator,
        storage: std.mem.Allocator,

        fn run(self: *const Self) anyerror!Result {
            var block_id = self.body.entry;
            while (true) {
                const block = self.body.blocks[@backingInt(block_id)];
                for (block.instruction_start..block.instruction_end) |index| {
                    const instruction = self.body.instructions[index];
                    const span = instructionSpan(self.body, index);
                    switch (try self.instructionValue(instruction, span)) {
                        .returned => |value| {
                            const destination = switch (instruction) {
                                inline .call, .value_copy, .variant_coerce, .variant_extract, .static_conversion => |operation| operation.destination,
                                else => null,
                            };
                            try self.store(@backingInt(self.body.instructionValue(index)), destination, value);
                        },
                        else => |result| return if (instruction == .static_conversion) result else atSpan(result, span),
                    }
                }
                var step: Step = undefined;
                switch (block.terminator) {
                    .branch => |branch| step = try self.enterBranch(branch),
                    .predicate_branch => |predicate| step = try self.enterBranch(if (predicateValue(self.slots, predicate.operation, predicate.operands)) predicate.then_branch else predicate.else_branch),
                    .return_unit => return .{ .returned = .{ .runtime = .unit } },
                    .return_value => |use| return self.evaluateUse(use),
                    .diverge => unreachable,
                }
                switch (step) {
                    .next => |next| block_id = next,
                    .result => |result| return result,
                }
            }
        }

        fn instructionValue(self: *const Self, instruction: structures.FunctionInstruction, span: ?structures.SourceSpan) anyerror!Result {
            const slots = self.slots;
            switch (instruction) {
                .const_int => |value| return .{ .returned = .{ .runtime = .{ .int = value } } },
                .const_int_literal => |value| return .{ .returned = .{ .runtime = .{ .int_literal = value } } },
                .const_string_literal => |value| return .{ .returned = .{ .runtime = .{ .string_literal = value } } },
                .const_static_string => |constant| return .{ .returned = .{ .runtime = try self.executor.staticString(constant) } },
                .const_storage_cursor => |value| return .{ .returned = .{ .runtime = .{ .storage_cursor = value } } },
                .const_byte => |value| return .{ .returned = .{ .runtime = .{ .byte = value } } },
                .const_bool => |value| return .{ .returned = .{ .runtime = .{ .bool = value } } },
                .const_type => |type_id| return .{ .returned = .{ .type = type_id } },
                .const_unit => return .{ .returned = .{ .runtime = .unit } },
                .const_none => return .{ .returned = .{ .runtime = .none } },
                .function_ref => |reference| return .{ .returned = .{ .runtime = .{ .function_ref = reference } } },
                .initializer_ref => |reference| return .{ .returned = try self.initializerValue(reference) },
                .storage_cursor => |operation| return self.storageCursor(operation),
                .cursor_offset => |operation| return .{ .returned = try offsetStorageCursor(slots[@backingInt(operation.cursor)], operation.type_id, @intCast(integer(slots, operation.index)), self.storage) },
                .cursor_element => |operation| return .{ .returned = try storageCursorElement(slots[@backingInt(operation.cursor)], operation.type_id, @intCast(integer(slots, operation.index)), self.storage) },
                .byte_to_int => |source| return .{ .returned = .{ .runtime = .{ .int = scalar(slots, source).byte } } },
                .static_conversion => |conversion| return self.staticConversion(conversion, span),
                .negi => |operand| return .{ .returned = .{ .runtime = .{ .int = -%integer(slots, operand) } } },
                .addi, .subi, .muli, .divsi => |operands| {
                    const result = instruction.integerResult(integer(slots, operands.lhs), integer(slots, operands.rhs)) orelse return executionError(.division_by_zero, span);
                    return .{ .returned = .{ .runtime = .{ .int = result } } };
                },
                .call => |call| return self.executeCall(call, span),
                .variant_tag => |operand| return self.variantTag((try self.read(operand)) orelse return .unavailable, operand),
                .variant_coerce, .variant_extract => |operation| return self.convertVariant((try self.read(operation.operand)) orelse return .unavailable, operation),
                .local_storage, .result_storage => |type_id| return .{ .returned = .{ .place = try Cell.create(self.storage, type_id, .uninitialized) } },
                .storage_projection => |operation| return self.projectStorage(operation),
                .array_element => |operation| return self.projectArray(operation),
                .borrow_address => |operation| return self.borrowAddress(operation),
                .borrow_read => |operation| return self.borrowRead(operation, span),
                .borrow_write => |operation| return self.borrowWrite(operation, span),
                .allocation_element => |operation| return self.allocationElement(operation),
                .value_copy => |operation| return self.copyValue(operation),
                .field_access => |operation| return self.accessField(slots[@backingInt(operation.operand)], operation),
                .compare => |comparison| return .{ .returned = .{ .runtime = .{ .bool = predicateValue(slots, comparison.operation, comparison.operands) } } },
                .select, .aggregate, .fill, .move => unreachable,
            }
        }

        fn initializerValue(self: *const Self, reference: @FieldType(structures.FunctionInstruction, "initializer_ref")) !Value {
            const source = self.body.initializer_captures[reference.captures.start..reference.captures.end];
            const captures = try self.storage.alloc(Value, source.len);
            for (source, captures) |capture, *value| value.* = if (self.slots[@backingInt(capture)] == .initializer) self.slots[@backingInt(capture)] else .{ .place = try storageCell(self.body, self.slots, capture, self.storage) };
            return .{ .initializer = .{ .body = &self.body.initializer_regions[reference.region], .captures = captures } };
        }

        fn projectArray(self: *const Self, operation: structures.ArrayElement) !Result {
            const cell = try storageCell(self.body, self.slots, operation.array, self.storage);
            const array = (try self.executor.arrayType(cell.type_id)) orelse return .unavailable;
            std.debug.assert(array.element_type == operation.type_id);
            const index = integer(self.slots, operation.index);
            std.debug.assert(index >= 0);
            std.debug.assert(@as(u32, @intCast(index)) < array.length);
            if (cell.contents == .allocation) return .{ .returned = .{ .place = try cell.contents.allocation.element(@intCast(index)) } };
            if (!try expandFields(cell, self.executor)) return .unavailable;
            return .{ .returned = .{ .place = &cell.contents.fields[@intCast(index)] } };
        }

        fn borrowAddress(self: *const Self, operation: structures.BorrowAddressOperation) !Result {
            if (operation.base_is_reference and operation.fields.start == operation.fields.end) {
                if (try readSlot(self.slots, operation.source, self.executor, self.storage)) |source| {
                    if (source == .runtime and source.runtime == .storage_cursor) {
                        var cursor = source.runtime.storage_cursor;
                        cursor.type_id = operation.type_id;
                        return .{ .returned = .{ .runtime = .{ .storage_cursor = cursor } } };
                    }
                }
            }
            var target = if (operation.base_is_reference)
                referenceTarget(self.slots[@backingInt(operation.source)]) orelse return executionError(.unsupported_operation, null)
            else
                try storageCell(self.body, self.slots, operation.source, self.storage);
            for (self.body.borrow_fields[operation.fields.start..operation.fields.end]) |projection| switch (projection) {
                .field => |index| {
                    if (!try expandFields(target, self.executor)) return .unavailable;
                    const field = &target.contents.fields[index];
                    if (field.type_id == .never) field.type_id = (try self.executor.structFieldType(target.type_id, index)) orelse return .unavailable;
                    target = field;
                },
                .variant => |member| target = (try borrowVariantCell(target, member, self.executor)) orelse return .unavailable,
            };
            return .{ .returned = try referenceValue(operation.type_id, target, self.storage) };
        }

        fn projectStorage(self: *const Self, operation: structures.StorageProjection) !Result {
            const cell = try storageCell(self.body, self.slots, operation.owner, self.storage);
            switch (operation.projection) {
                .field => |index| {
                    if (!try expandFields(cell, self.executor)) return .unavailable;
                    const field = &cell.contents.fields[index];
                    std.debug.assert(field.type_id == .never or field.type_id == operation.type_id);
                    field.type_id = operation.type_id;
                    return .{ .returned = .{ .place = field } };
                },
                .variant => {
                    switch (cell.contents) {
                        .uninitialized => {
                            const payload = try Cell.create(cell.storage, operation.type_id, .uninitialized);
                            cell.contents = .{ .variant_payload = payload };
                        },
                        .value => |owner| {
                            const active = try self.activeVariant(.{ .runtime = owner }, operation.owner);
                            const payload = try Cell.create(cell.storage, operation.type_id, .uninitialized);
                            if (active.member_type == operation.type_id)
                                try assignCell(payload, active.payload, self.executor);
                            cell.contents = .{ .variant_payload = payload };
                        },
                        .variant_payload => |payload| if (payload.type_id != operation.type_id) {
                            payload.* = .{ .type_id = operation.type_id, .storage = cell.storage, .contents = .uninitialized };
                        },
                        .fields, .reference, .storage_cursor, .allocation => unreachable,
                    }
                    return .{ .returned = .{ .place = cell.contents.variant_payload } };
                },
                .allocation_array => {
                    const allocation = allocationRecord(.{ .place = cell });
                    const array = (try self.executor.arrayType(operation.type_id)) orelse return .unavailable;
                    std.debug.assert(array.element_type == allocation.element_type);
                    std.debug.assert(array.length <= allocation.capacity);
                    return .{ .returned = try allocationValue(operation.type_id, allocation, self.storage) };
                },
            }
        }

        fn accessField(self: *const Self, value: Value, operation: structures.FieldAccessOperation) !Result {
            if (value == .place and value.place.contents == .fields) {
                const fields = value.place.contents.fields;
                std.debug.assert(operation.field_index < fields.len);
                const field = &fields[operation.field_index];
                std.debug.assert(field.type_id == operation.field_type);
                if (containsReference(field)) return .{ .returned = try copyStoredValue(.{ .place = field }, operation.field_type, self.executor, self.storage) };
                const field_value = (try materialize(field, self.executor, self.gpa)) orelse return .unavailable;
                return .{ .returned = .{ .runtime = field_value } };
            }
            const owner = if (value == .place) value.place.contents.value else value.runtime;
            const fields = try self.executor.lookupTuple(owner.structure);
            std.debug.assert(operation.field_index < fields.len);
            const field = (try self.executor.lookupRuntime(fields[operation.field_index])) orelse return .unavailable;
            std.debug.assert(field.type_id == operation.field_type);
            return .{ .returned = .{ .runtime = field.value } };
        }

        fn activeVariant(self: *const Self, value: Value, operand: structures.FunctionValueId) !ActiveVariant {
            if (value == .place and value.place.contents == .variant_payload) {
                const payload = value.place.contents.variant_payload;
                return .{ .member_type = payload.type_id, .payload = .{ .place = payload } };
            }
            if (value == .runtime and value.runtime == .variant) {
                const payload = (try self.executor.lookupRuntime(value.runtime.variant.payload)) orelse return error.Unavailable;
                return .{ .member_type = value.runtime.variant.member_type, .payload = .{ .runtime = payload.value } };
            }
            const source_type = self.body.valueType(operand);
            std.debug.assert(try self.executor.variantMembers(source_type) == null);
            return .{ .member_type = source_type, .payload = value };
        }

        fn variantTag(self: *const Self, value: Value, operand: structures.FunctionValueId) !Result {
            const active = try self.activeVariant(value, operand);
            const members = (try self.executor.variantMembers(self.body.valueType(operand))) orelse unreachable;
            for (members, 0..) |member, tag| if (member == active.member_type) return .{ .returned = .{ .runtime = .{ .int = @intCast(tag) } } };
            unreachable;
        }

        fn convertVariant(self: *const Self, value: Value, operation: structures.VariantOperation) !Result {
            const active = try self.activeVariant(value, operation.operand);
            if (try self.executor.variantMembers(operation.target_type)) |target_members| {
                const source_type = self.body.valueType(operation.operand);
                const source_members = try self.executor.variantMembers(source_type);
                const source_tag: usize = if (source_members) |members| blk: {
                    break :blk for (members, 0..) |member, tag| {
                        if (member == active.member_type) break tag;
                    } else unreachable;
                } else 0;
                const mapping = self.body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
                std.debug.assert(source_tag < mapping.len);
                const target_tag = mapping[source_tag];
                std.debug.assert(target_tag != structures.invalid_variant_tag);
                std.debug.assert(target_tag < target_members.len);
                if (value == .runtime) {
                    const payload = if (value.runtime == .variant) value.runtime.variant.payload else try self.executor.internRuntime(source_type, value.runtime);
                    return .{ .returned = .{ .runtime = variantValue(target_members[target_tag], payload) } };
                }
                return .{ .returned = try storedVariantValue(operation.target_type, target_members[target_tag], active.payload, self.executor) };
            }
            // Widened callable tags can retain payloads with their original type.
            if (value == .runtime and value.runtime == .variant) {
                const payload = (try self.executor.lookupRuntime(value.runtime.variant.payload)) orelse return .unavailable;
                if (payload.type_id == operation.target_type) return .{ .returned = .{ .runtime = payload.value } };
                var reference = payload.value.function_ref;
                reference.type_id = operation.target_type;
                return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
            }
            if (active.member_type == operation.target_type) return .{ .returned = try copyStoredValue(active.payload, operation.target_type, self.executor, self.storage) };
            var reference = active.payload.runtime.function_ref;
            reference.type_id = operation.target_type;
            return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
        }

        fn storageCursor(self: *const Self, operation: structures.BorrowOperation) !Result {
            const owner = try storageCell(self.body, self.slots, operation.source, self.storage);
            if (owner.contents != .allocation and !try expandFields(owner, self.executor)) return .unavailable;
            const cell = try Cell.create(self.storage, operation.type_id, .{ .storage_cursor = .{ .owner = owner, .offset = 0 } });
            return .{ .returned = .{ .place = cell } };
        }

        fn staticConversion(self: *const Self, conversion: @FieldType(structures.FunctionInstruction, "static_conversion"), span: ?structures.SourceSpan) !Result {
            const source = (try self.read(conversion.operand)) orelse return .unavailable;
            if (source == .place and containsReference(source.place)) return executionError(.escaping_storage, span);
            const runtime = switch (source) {
                .runtime => |value| value,
                .place => |cell| (try materialize(cell, self.executor, self.gpa)) orelse return executionError(.unsupported_operation, span),
                .type, .initializer => unreachable,
            };
            return self.executor.convertStaticValue(self.body.valueType(conversion.operand), runtime, conversion.type_id, span, self.storage);
        }

        fn borrowRead(self: *const Self, operation: structures.BorrowOperation, span: ?structures.SourceSpan) !Result {
            if (try readStaticReference(self.slots[@backingInt(operation.source)], self.executor)) |value| return .{ .returned = value };
            const target = referenceTarget(self.slots[@backingInt(operation.source)]) orelse return executionError(.unsupported_operation, span);
            std.debug.assert(target.type_id == operation.type_id);
            return .{ .returned = .{ .place = target } };
        }

        fn borrowWrite(self: *const Self, operation: structures.BorrowWriteOperation, span: ?structures.SourceSpan) !Result {
            const target = referenceTarget(self.slots[@backingInt(operation.reference)]) orelse return executionError(.unsupported_operation, span);
            std.debug.assert(target.type_id == operation.type_id);
            try assignCell(target, self.slots[@backingInt(operation.value)], self.executor);
            return .{ .returned = .{ .runtime = .unit } };
        }

        fn allocationElement(self: *const Self, operation: structures.AllocationElement) !Result {
            const allocation = allocationRecord(self.slots[@backingInt(operation.allocation)]);
            std.debug.assert(allocation.element_type == operation.type_id);
            return .{ .returned = .{ .place = try allocation.element(@intCast(integer(self.slots, operation.index))) } };
        }

        fn copyValue(self: *const Self, operation: structures.ValueCopy) !Result {
            var copied = (try self.read(operation.source)) orelse return .unavailable;
            if (copied == .runtime and copied.runtime == .storage_cursor) copied.runtime.storage_cursor.type_id = operation.type_id;
            if (operation.destination == null) copied = try copyStoredValue(copied, operation.type_id, self.executor, self.storage);
            return .{ .returned = copied };
        }

        fn executeCall(self: *const Self, call: structures.FunctionCall, call_span: ?structures.SourceSpan) anyerror!Result {
            if (call.target == .initializer) {
                const initializer = self.slots[@backingInt(call.target.initializer)].initializer;
                return executeInStorage(initializer.body, initializer.captures, self.executor, self.gpa, self.storage);
            }
            const instance = switch (call.target) {
                .direct => |instance| instance,
                .indirect => |value| scalar(self.slots, value).function_ref.instance(),
                .initializer => unreachable,
            };
            const arguments = self.body.call_arguments[call.arguments.start..call.arguments.end];
            const interpreted = self.call_scratch[call.arguments.start..call.arguments.end];
            for (arguments, interpreted) |argument, *destination| {
                if (argument == .initializer) {
                    destination.* = self.slots[@backingInt(argument.valueId())];
                    std.debug.assert(destination.* == .initializer);
                    continue;
                }
                const use = argument.valueUse();
                if (argument == .borrowed or argument == .deinit or (use.coerce_to == null and try self.executor.argumentPassing(self.body.valueType(use.value)) == .indirect)) {
                    destination.* = .{ .place = try storageCell(self.body, self.slots, use.value, self.storage) };
                    continue;
                }
                switch (try self.evaluateUse(use)) {
                    .returned => |value| destination.* = try copyStoredValue(value, use.coerce_to orelse self.body.valueType(use.value), self.executor, self.storage),
                    else => |result| return result,
                }
            }
            return self.executor.callInStorage(instance, interpreted, call_span, self.storage);
        }

        fn store(self: *const Self, own: usize, destination: ?structures.FunctionValueId, value: Value) !void {
            const target = destination orelse {
                self.slots[own] = value;
                return;
            };
            switch (self.slots[@backingInt(target)]) {
                .place => |cell| try assignCell(cell, value, self.executor),
                .runtime => self.slots[@backingInt(target)] = value,
                .type, .initializer => unreachable,
            }
            self.slots[own] = .{ .runtime = .unit };
        }

        fn read(self: *const Self, value: structures.FunctionValueId) !?Value {
            return readSlot(self.slots, value, self.executor, self.gpa);
        }

        fn evaluateUse(self: *const Self, use: structures.FunctionValueUse) !Result {
            const value = (try self.read(use.value)) orelse return .unavailable;
            const target = use.coerce_to orelse return .{ .returned = value };
            if (use.variant_tag_mapping) |mapping| return self.convertVariant(value, .{
                .operand = use.value,
                .target_type = target,
                .tag_mapping = mapping,
            });
            var reference = value.runtime.function_ref;
            reference.type_id = target;
            return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
        }

        fn enterBranch(self: *const Self, branch: structures.FunctionBranch) !Step {
            const target = self.body.blocks[@backingInt(branch.target)];
            const arguments = self.body.branch_arguments[branch.arguments.start..branch.arguments.end];
            std.debug.assert(arguments.len == target.argument_end - target.argument_start);
            for (arguments, self.scratch[0..arguments.len], self.body.block_arguments[target.argument_start..target.argument_end]) |argument, *temporary, parameter| {
                if (parameter.representation == .storage or try self.executor.argumentPassing(parameter.type_id) == .indirect) {
                    std.debug.assert(argument.coerce_to == null);
                    temporary.* = .{ .place = try storageCell(self.body, self.slots, argument.value, self.storage) };
                    continue;
                }
                switch (try self.evaluateUse(argument)) {
                    .returned => |value| temporary.* = try copyStoredValue(value, parameter.type_id, self.executor, self.storage),
                    else => |result| return .{ .result = result },
                }
            }
            @memcpy(self.slots[target.argument_start..target.argument_end], self.scratch[0..arguments.len]);
            return .{ .next = branch.target };
        }
    };
}

fn executionError(reason: ExecutionErrorReason, span: ?structures.SourceSpan) Result {
    return .{ .execution_error = .{ .reason = reason, .span = span } };
}

fn instructionSpan(body: *const structures.FunctionBodyAnalysis, instruction_index: usize) ?structures.SourceSpan {
    return if (body.instruction_spans.len == body.instructions.len) body.instruction_spans[instruction_index] else null;
}

fn terminatorSpan(body: *const structures.FunctionBodyAnalysis, block_id: structures.FunctionBlockId) ?structures.SourceSpan {
    return if (body.terminator_spans.len == body.blocks.len) body.terminator_spans[@backingInt(block_id)] else null;
}

fn integer(slots: []const Value, value: structures.FunctionValueId) i32 {
    return scalar(slots, value).int;
}

fn scalar(slots: []const Value, value: structures.FunctionValueId) structures.CompileTimeValue.RuntimeValue {
    return storedRuntime(slots[@backingInt(value)]);
}

/// A runtime value, either immediate or held whole by a storage cell.
inline fn storedRuntime(value: Value) structures.CompileTimeValue.RuntimeValue {
    return switch (value) {
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
    return operation.holds(switch (operation) {
        .lti, .gti, .lei, .gei, .eqi, .nei => std.math.order(predicateInteger(slots, operands.lhs), predicateInteger(slots, operands.rhs)),
        .eqb, .neb => std.math.order(@intFromBool(scalar(slots, operands.lhs).bool), @intFromBool(scalar(slots, operands.rhs).bool)),
        .eqt, .net => if (slots[@backingInt(operands.lhs)].type == slots[@backingInt(operands.rhs)].type) .eq else .lt,
    });
}

fn predicateInteger(slots: []const Value, value: structures.FunctionValueId) i64 {
    return switch (scalar(slots, value)) {
        .int => |integer_value| integer_value,
        .int_literal => |literal| literal,
        else => unreachable,
    };
}

fn readSlot(slots: []const Value, value: structures.FunctionValueId, executor: anytype, gpa: std.mem.Allocator) !?Value {
    return switch (slots[@backingInt(value)]) {
        .place => |cell| if (containsReference(cell)) .{ .place = cell } else if (try materialize(cell, executor, gpa)) |runtime| .{ .runtime = runtime } else null,
        else => |ordinary| ordinary,
    };
}

fn copyStoredValue(value: Value, type_id: structures.TypeId, executor: anytype, storage: std.mem.Allocator) !Value {
    if (value != .place) return value;
    const copy = try Cell.create(storage, type_id, .uninitialized);
    try assignCell(copy, value, executor);
    return .{ .place = copy };
}

fn storageCell(body: *const structures.FunctionBodyAnalysis, slots: []Value, value: structures.FunctionValueId, storage: std.mem.Allocator) !*Cell {
    const slot = &slots[@backingInt(value)];
    if (slot.* == .place) return slot.place;
    std.debug.assert(slot.* == .runtime);
    const cell = try Cell.create(storage, body.valueType(value), .{ .value = slot.runtime });
    slot.* = .{ .place = cell };
    return cell;
}

pub fn containsReference(cell: *const Cell) bool {
    return switch (cell.contents) {
        .reference, .storage_cursor, .allocation => true,
        .fields => |fields| for (fields) |*field| {
            if (containsReference(field)) break true;
        } else false,
        .variant_payload => |payload| containsReference(payload),
        .uninitialized, .value => false,
    };
}

pub fn referenceTarget(value: Value) ?*Cell {
    if (value != .place or value.place.contents != .reference) return null;
    return value.place.contents.reference;
}

pub fn referenceValue(type_id: structures.TypeId, target: *Cell, storage: std.mem.Allocator) !Value {
    return .{ .place = try Cell.create(storage, type_id, .{ .reference = target }) };
}

pub fn assignCell(destination: *Cell, source: Value, executor: anytype) anyerror!void {
    if (source == .place and destination == source.place) return;
    if (destination.contents == .allocation) {
        if (try executor.arrayType(destination.type_id)) |array| {
            const allocation = destination.contents.allocation;
            std.debug.assert(array.element_type == allocation.element_type);
            std.debug.assert(array.length <= allocation.capacity);
            for (0..array.length) |index| try assignCell(try allocation.element(@intCast(index)), try aggregateElement(source, index, executor), executor);
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
                    if (try executor.arrayType(cell.type_id)) |array| {
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
                .variant_payload => |payload| try assignCell(try selectVariantPayload(destination, payload.type_id), .{ .place = payload }, executor),
            }
        },
        .type, .initializer => unreachable,
    }
}

/// Element `index` of inline fields, an allocation, or an interned tuple.
fn aggregateElement(aggregate: Value, index: usize, executor: anytype) !Value {
    if (aggregate == .place and aggregate.place.contents == .fields) return .{ .place = &aggregate.place.contents.fields[index] };
    if (aggregate == .place and aggregate.place.contents == .allocation) return .{ .place = try aggregate.place.contents.allocation.element(@intCast(index)) };
    const values = try executor.lookupTuple(storedRuntime(aggregate).structure);
    const value = (try executor.lookupRuntime(values[index])) orelse return error.Unavailable;
    return .{ .runtime = value.value };
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
        const value = (try executor.lookupRuntime(runtime.variant.payload)) orelse return error.Unavailable;
        try assignRuntime(try selectVariantPayload(destination, value.type_id), value.value, executor);
        return;
    }
    destination.contents = .{ .value = runtime };
}

/// Makes `member_type` the active payload, discarding any other member's contents.
fn selectVariantPayload(cell: *Cell, member_type: structures.TypeId) !*Cell {
    if (cell.contents != .variant_payload) cell.contents = .{ .variant_payload = try Cell.create(cell.storage, member_type, .uninitialized) };
    const payload = cell.contents.variant_payload;
    if (payload.type_id != member_type) payload.* = .{ .type_id = member_type, .storage = cell.storage, .contents = .uninitialized };
    return payload;
}

fn expandFields(cell: *Cell, executor: anytype) !bool {
    switch (cell.contents) {
        .uninitialized => {
            const array = try executor.arrayType(cell.type_id);
            const count = if (array) |shape| shape.length else (try executor.structFieldCount(cell.type_id)) orelse return false;
            const fields = try cell.storage.alloc(Cell, count);
            for (fields) |*field| field.* = .{ .type_id = if (array) |shape| shape.element_type else .never, .storage = cell.storage, .contents = .uninitialized };
            cell.contents = .{ .fields = fields };
        },
        .value => |runtime| {
            std.debug.assert(runtime == .structure);
            const values = try executor.lookupTuple(runtime.structure);
            const array = try executor.arrayType(cell.type_id);
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

fn borrowVariantCell(target: *Cell, member: structures.TypeId, executor: anytype) !?*Cell {
    if (target.contents == .value) {
        const value = (try executor.lookupRuntime(target.contents.value.variant.payload)) orelse return null;
        std.debug.assert(value.type_id == member);
        const payload = try Cell.create(target.storage, member, .{ .value = value.value });
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
            const array = try executor.arrayType(cell.type_id);
            const count = if (array) |shape| shape.length else (try executor.structFieldCount(cell.type_id)) orelse return null;
            if (count != 0) return null;
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

const ActiveVariant = struct {
    member_type: structures.TypeId,
    payload: Value,
};

fn variantValue(member_type: structures.TypeId, payload: structures.CompileTimeValueId) structures.CompileTimeValue.RuntimeValue {
    return .{ .variant = .{ .member_type = member_type, .payload = payload } };
}

pub fn storedVariantValue(type_id: structures.TypeId, member_type: structures.TypeId, payload: Value, executor: anytype) !Value {
    if (payload == .runtime) return .{ .runtime = variantValue(member_type, try executor.internRuntime(member_type, payload.runtime)) };
    std.debug.assert(payload == .place);
    const storage = payload.place.storage;
    const member = try Cell.create(storage, member_type, .uninitialized);
    try assignCell(member, payload, executor);
    return .{ .place = try Cell.create(storage, type_id, .{ .variant_payload = member }) };
}

fn atSpan(result: Result, span: ?structures.SourceSpan) Result {
    if (result == .execution_error and result.execution_error.span == null) return executionError(result.execution_error.reason, span);
    return result;
}

fn offsetStorageCursor(source: Value, type_id: structures.TypeId, offset: u32, storage: std.mem.Allocator) !Value {
    if (source == .place and source.place.contents == .storage_cursor) {
        var cursor = source.place.contents.storage_cursor;
        cursor.offset = std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge;
        return .{ .place = try Cell.create(storage, type_id, .{ .storage_cursor = cursor }) };
    }
    var cursor = storedRuntime(source).storage_cursor;
    cursor.type_id = type_id;
    cursor.offset = std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge;
    return .{ .runtime = .{ .storage_cursor = cursor } };
}

fn storageCursorElement(source: Value, type_id: structures.TypeId, offset: u32, storage: std.mem.Allocator) !Value {
    if (source == .place and source.place.contents == .storage_cursor)
        return referenceValue(type_id, try storageCursorCell(source.place, offset), storage);
    return offsetStorageCursor(source, type_id, offset, storage);
}

fn storageCursorCell(cell: *Cell, offset: u32) !*Cell {
    const cursor = cell.contents.storage_cursor;
    const index = std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge;
    return if (cursor.owner.contents == .allocation)
        try cursor.owner.contents.allocation.element(index)
    else
        &cursor.owner.contents.fields[index];
}

/// Snapshot a validated StringView while its evaluation-local backing is alive.
pub fn panicMessage(message: Value, executor: anytype, gpa: std.mem.Allocator) !structures.ByteStringId {
    const bytes_view = try aggregateElement(message, 0, executor);
    const span = try aggregateElement(bytes_view, 0, executor);
    const cursor = try aggregateElement(span, 0, executor);
    const size = try aggregateElement(span, 1, executor);
    const count = integerValue(size);
    std.debug.assert(count >= 0);
    const bytes = try gpa.alloc(u8, @intCast(count));
    defer gpa.free(bytes);
    for (bytes, 0..) |*byte, index| {
        if (cursor == .place and cursor.place.contents == .storage_cursor) {
            byte.* = (try storageCursorCell(cursor.place, @intCast(index))).contents.value.byte;
        } else {
            const static_cursor = storedRuntime(cursor).storage_cursor;
            const data = try executor.byteString(static_cursor.data.?);
            byte.* = data[static_cursor.offset + index];
        }
    }
    return executor.internBytes(bytes);
}

fn readStaticReference(source: Value, executor: anytype) !?Value {
    if (source == .place and source.place.contents != .value) return null;
    const runtime = storedRuntime(source);
    if (runtime != .storage_cursor) return null;
    const bytes = try executor.byteString(runtime.storage_cursor.data orelse unreachable);
    return .{ .runtime = .{ .byte = bytes[runtime.storage_cursor.offset] } };
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
    return .{ .place = try Cell.create(storage, type_id, .{ .allocation = allocation }) };
}

pub fn integerValue(value: Value) i32 {
    return storedRuntime(value).int;
}

pub fn releaseAllocation(value: Value) void {
    allocationRecord(value).release();
}

pub fn allocationCount(value: Value) i32 {
    return @intCast(allocationRecord(value).capacity);
}
