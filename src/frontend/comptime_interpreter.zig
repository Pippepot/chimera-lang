const std = @import("std");
const structures = @import("../structures.zig");

pub const ExecutionErrorReason = union(enum) {
    call_cycle,
    division_by_zero,
    integer_overflow,
    invalid_shift_count,
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
};

pub const Allocation = struct {
    identity: usize,
    element_type: structures.TypeId,
    capacity: u32,
    released: bool = false,
    backing: std.heap.ArenaAllocator,
    identities: std.mem.Allocator,
    elements: std.AutoHashMapUnmanaged(u32, *Cell) = .empty,
    views: std.AutoHashMapUnmanaged(StorageViewKey, *Cell) = .empty,
    source: ?*Cell = null,
    byte_offset: u32 = 0,
    element_size: u32 = 1,

    pub fn element(self: *Allocation, index: u32) anyerror!*Cell {
        std.debug.assert(!self.released);
        std.debug.assert(index < self.capacity);
        if (self.source) |source| {
            const offset = try std.math.add(u32, self.byte_offset, try std.math.mul(u32, index, self.element_size));
            if (self.element_type == .byte) return elementCell(source, offset);
            const key: StorageViewKey = .{ .offset = offset, .type_id = self.element_type, .zero_index = if (self.element_size == 0) index else 0 };
            const views = if (source.contents == .allocation) &source.contents.allocation.views else &source.views;
            const storage = if (source.contents == .allocation) source.contents.allocation.identities else source.storage;
            if (views.get(key)) |cell| return cell;
            const cell = try Cell.create(storage, self.element_type, .uninitialized);
            cell.memory = .{ .source = source, .offset = offset };
            try views.put(storage, key, cell);
            return cell;
        }
        if (self.elements.get(index)) |cell| return cell;
        const cell = try Cell.create(self.identities, self.element_type, .uninitialized);
        try self.elements.put(self.backing.allocator(), index, cell);
        return cell;
    }

    pub fn release(self: *Allocation) void {
        if (self.released) return;
        var cells = self.elements.valueIterator();
        while (cells.next()) |cell| cell.*.invalidate();
        var views = self.views.valueIterator();
        while (views.next()) |view| view.*.invalidate();
        self.views.deinit(self.identities);
        self.views = .empty;
        self.elements = .empty;
        self.backing.deinit();
        self.released = true;
    }
};

pub const Value = union(enum) {
    runtime: structures.CompileTimeValue.RuntimeValue,
    type: structures.TypeId,
    place: *Cell,
    initializer: struct { body: *const structures.FunctionBodyAnalysis, captures: []Value },
};

const StorageViewKey = struct { offset: u32, type_id: structures.TypeId, zero_index: u32 = 0 };
const MemoryView = struct { source: *Cell, offset: u32 };

const CallableHandle = struct {
    invocation: structures.InstanceId,
    payload: union(enum) { none, receiver: *Cell, function: structures.FunctionReference, environment: *Cell },
};

pub const Cell = struct {
    type_id: structures.TypeId,
    storage: std.mem.Allocator,
    memory: ?MemoryView = null,
    views: std.AutoHashMapUnmanaged(StorageViewKey, *Cell) = .empty,
    contents: union(enum) {
        uninitialized,
        value: structures.CompileTimeValue.RuntimeValue,
        fields: []Cell,
        variant_payload: *Cell,
        reference: *Cell,
        opaque_reference: *Cell,
        erased_callable: CallableHandle,
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
            .uninitialized, .value, .reference, .opaque_reference, .erased_callable, .storage_cursor, .allocation => {},
        }
        var views = self.views.valueIterator();
        while (views.next()) |view| view.*.invalidate();
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
            snapshot.* = .{ .type_id = cell.type_id, .storage = self.storage, .contents = switch (cell.contents) {
                .uninitialized, .value => cell.contents,
                .fields => |fields| .{ .fields = try self.cloneFields(fields) },
                .storage_cursor => |pointer| .{ .storage_cursor = .{ .owner = try self.cloneCell(pointer.owner), .offset = pointer.offset } },
                inline .variant_payload, .reference, .opaque_reference => |target, tag| @unionInit(@FieldType(Cell, "contents"), @tagName(tag), try self.cloneCell(target)),
                .erased_callable => |callable| .{ .erased_callable = .{
                    .invocation = callable.invocation,
                    .payload = switch (callable.payload) {
                        .receiver => |target| .{ .receiver = try self.cloneCell(target) },
                        .environment => |owner| .{ .environment = try self.cloneCell(owner) },
                        .none, .function => callable.payload,
                    },
                } },
                .allocation => |allocation| .{ .allocation = try self.cloneAllocation(allocation) },
            } };
            var views = cell.views.iterator();
            while (views.next()) |view| try snapshot.views.put(self.storage, view.key_ptr.*, try self.cloneCell(view.value_ptr.*));
            if (cell.memory) |memory| snapshot.memory = .{ .source = try self.cloneCell(memory.source), .offset = memory.offset };
        }

        fn cloneAllocation(self: *@This(), allocation: *const Allocation) anyerror!*Allocation {
            if (self.allocations.get(allocation)) |copy| return copy;
            const copy = try self.storage.create(Allocation);
            copy.* = .{
                .identity = allocation.identity,
                .element_type = allocation.element_type,
                .capacity = allocation.capacity,
                .source = if (allocation.source) |source| try self.cloneCell(source) else null,
                .byte_offset = allocation.byte_offset,
                .element_size = allocation.element_size,
                .released = allocation.released,
                .backing = .init(self.storage),
                .identities = self.storage,
            };
            try self.allocations.put(self.storage, allocation, copy);
            var entries = allocation.elements.iterator();
            while (entries.next()) |entry| try copy.elements.put(self.storage, entry.key_ptr.*, try self.cloneCell(entry.value_ptr.*));
            var views = allocation.views.iterator();
            while (views.next()) |view| try copy.views.put(self.storage, view.key_ptr.*, try self.cloneCell(view.value_ptr.*));
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
            if (left.memory) |memory| {
                const other = right.memory orelse return false;
                if (memory.offset != other.offset or !try self.sameCell(memory.source, other.source)) return false;
            } else if (right.memory != null) return false;
            if (!try self.sameCells(left.views, right.views)) return false;
            switch (left.contents) {
                .uninitialized => return true,
                .value => |value| return std.meta.eql(value, right.contents.value),
                .fields => |fields| return self.sameFields(fields, right.contents.fields),
                .variant_payload => |payload| return self.sameCell(payload, right.contents.variant_payload),
                .storage_cursor => return self.sameStorageCursor(left, right),
                inline .reference, .opaque_reference => |target, tag| return self.sameTarget(target, @field(right.contents, @tagName(tag))),
                .erased_callable => |callable| {
                    const other = right.contents.erased_callable;
                    if (!std.meta.eql(callable.invocation, other.invocation) or std.meta.activeTag(callable.payload) != std.meta.activeTag(other.payload)) return false;
                    switch (callable.payload) {
                        .none => return true,
                        .function => |function| return std.meta.eql(function, other.payload.function),
                        .receiver => |target| return self.sameTarget(target, other.payload.receiver),
                        .environment => |owner| return self.sameCell(owner, other.payload.environment),
                    }
                },
                .allocation => |allocation| return self.sameAllocation(allocation, right.contents.allocation),
            }
        }

        /// A pointer denotes the same original cell and equal contents on both sides.
        fn sameTarget(self: *@This(), left: *const Cell, right: *const Cell) anyerror!bool {
            return self.left.sourceCell(left) == self.right.sourceCell(right) and try self.sameCell(left, right);
        }

        /// Whether two cell maps hold equal cells under equal keys.
        fn sameCells(self: *@This(), left: anytype, right: anytype) anyerror!bool {
            if (left.count() != right.count()) return false;
            var entries = left.iterator();
            while (entries.next()) |entry| {
                const other = right.get(entry.key_ptr.*) orelse return false;
                if (!try self.sameCell(entry.value_ptr.*, other)) return false;
            }
            return true;
        }

        fn sameStorageCursor(self: *@This(), left: *const Cell, right: *const Cell) anyerror!bool {
            const first = left.contents.storage_cursor;
            const second = right.contents.storage_cursor;
            if (first.offset != second.offset) return false;
            // Copied allocation descriptors still denote the same allocation;
            // inline arrays retain the identity of their original storage cell.
            if (first.owner.contents == .allocation and second.owner.contents == .allocation)
                return self.sameAllocation(first.owner.contents.allocation, second.owner.contents.allocation);
            return self.sameTarget(first.owner, second.owner);
        }

        fn sameAllocation(self: *@This(), left: *const Allocation, right: *const Allocation) anyerror!bool {
            if (left.identity != right.identity or left.element_type != right.element_type or left.capacity != right.capacity or left.released != right.released or left.byte_offset != right.byte_offset or left.element_size != right.element_size) return false;
            if (left.source) |source| {
                if (right.source == null or !try self.sameCell(source, right.source.?)) return false;
            } else if (right.source != null) return false;
            return try self.sameCells(left.elements, right.elements) and try self.sameCells(left.views, right.views);
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
        const published = try publishCell(argument.place, executor, gpa);
        if (published != .returned) return published;
        argument.* = published.returned;
    }
    return switch (result.returned) {
        .place => |cell| publishCell(cell, executor, gpa),
        .initializer => executionError(.escaping_storage, null),
        .runtime, .type => result,
    };
}

/// A value leaving its evaluation must not retain evaluation-owned storage.
fn publishCell(cell: *Cell, executor: anytype, gpa: std.mem.Allocator) !Result {
    if (containsReference(cell)) return executionError(.escaping_storage, null);
    const runtime = (try materialize(cell, executor, gpa)) orelse return executionError(.unsupported_operation, null);
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
    @memset(slots, .{ .runtime = .unit });

    const execution: ExecutionFrame(@TypeOf(executor)) = .{
        .body = body,
        .slots = slots,
        .scratch = frame[slot_count .. slot_count + branch_scratch_count],
        .call_scratch = frame[slot_count + branch_scratch_count ..],
        .executor = executor,
        .gpa = gpa,
        .storage = storage,
    };
    const entry = body.blocks[@backingInt(body.entry)];
    std.debug.assert(entry.argument_start == 0);
    @memcpy(slots[entry.argument_start..entry.argument_end], arguments);
    for (body.block_arguments[entry.argument_start..entry.argument_end], arguments, 0..) |parameter, *argument, index| {
        if (parameter.representation != .storage or argument.* != .runtime) continue;
        argument.* = .{ .place = try execution.storageCell(@fromBackingInt(@intCast(index))) };
    }
    return execution.run();
}

/// Borrows one dense frame and its call-lived storage. Instruction evaluation
/// produces a value or control result; this boundary owns result placement.
fn ExecutionFrame(comptime Executor: type) type {
    return struct {
        const Self = @This();
        body: *const structures.FunctionBodyAnalysis,
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
                const branch = switch (block.terminator) {
                    .branch => |branch| branch,
                    .predicate_branch => |predicate| if (predicateValue(self.slots, predicate.operation, predicate.operands)) predicate.then_branch else predicate.else_branch,
                    .return_unit => return .{ .returned = .{ .runtime = .unit } },
                    .return_value => |use| return self.evaluateUse(use),
                    .diverge => unreachable,
                };
                if (try self.enterBranch(branch)) |result| return result;
                block_id = branch.target;
            }
        }

        fn instructionValue(self: *const Self, instruction: structures.FunctionInstruction, span: ?structures.SourceSpan) anyerror!Result {
            const slots = self.slots;
            switch (instruction) {
                .type_union => |operands| return .{ .returned = .{ .type = (try self.executor.unionType(slots[@backingInt(operands.lhs)].type, slots[@backingInt(operands.rhs)].type, span)) orelse return .reported_error } },
                .const_numeric => |value| return .{ .returned = .{ .runtime = .{ .numeric = value.bits } } },
                .numeric_binary => |operation| return self.numericBinary(operation, span),
                .numeric_unary => |operation| return self.numericUnary(operation, span),
                .numeric_convert => |operation| return self.numericConvert(operation),
                .const_int => |value| return .{ .returned = .{ .runtime = .{ .int = value } } },
                .const_int_literal => |value| return .{ .returned = .{ .runtime = (try self.executor.lookupRuntime(value)).?.value } },
                .const_string_literal => |value| return .{ .returned = .{ .runtime = .{ .string_literal = value } } },
                .const_static_string => |constant| return .{ .returned = .{ .runtime = try self.executor.staticString(constant) } },
                .const_storage_cursor => |value| return .{ .returned = .{ .runtime = .{ .storage_cursor = value } } },
                .const_byte => |value| return .{ .returned = .{ .runtime = .{ .byte = value } } },
                .const_bool => |value| return .{ .returned = .{ .runtime = .{ .bool = value } } },
                .const_type => |type_id| return .{ .returned = .{ .type = type_id } },
                .const_unit => return .{ .returned = .{ .runtime = .unit } },
                .const_none => return .{ .returned = .{ .runtime = .none } },
                .function_ref => |reference| return .{ .returned = .{ .runtime = .{ .function_ref = reference } } },
                .erased_callable => |callable| return .{ .returned = try self.erasedCallable(callable) },
                .service_enter => |operation| {
                    if (comptime !@hasDecl(@typeInfo(@TypeOf(self.executor)).pointer.child, "enterService")) return executionError(.unsupported_operation, span);
                    if (!try self.executor.enterService(operation.key, try self.storageCell(operation.receiver), self.storage))
                        return executionError(.{ .panic = try self.executor.internBytes("service cycle") }, span);
                    return .{ .returned = .{ .runtime = .unit } };
                },
                .service_leave => {
                    if (comptime !@hasDecl(@typeInfo(@TypeOf(self.executor)).pointer.child, "leaveService")) return executionError(.unsupported_operation, span);
                    self.executor.leaveService();
                    return .{ .returned = .{ .runtime = .unit } };
                },
                .context_read => |operation| {
                    if (comptime !@hasDecl(@typeInfo(@TypeOf(self.executor)).pointer.child, "readContext")) return executionError(.unsupported_operation, span);
                    return self.executor.readContext(operation.entry, operation.type_id, self.storage);
                },
                .context_write => |operation| {
                    if (comptime !@hasDecl(@typeInfo(@TypeOf(self.executor)).pointer.child, "writeContext")) return executionError(.unsupported_operation, span);
                    try self.executor.writeContext(operation.entry, self.slots[@backingInt(operation.source)], self.body.valueType(operation.source));
                    return .{ .returned = .{ .runtime = .unit } };
                },
                .callable_payload => |operation| {
                    const cell = try self.storageCell(operation.source);
                    const payload: @FieldType(CallableHandle, "payload") = if (cell.contents == .fields) .{ .receiver = cell.contents.fields[0].contents.reference } else erasedHandle(cell).payload;
                    const element = try self.executor.borrowElement(operation.type_id);
                    if (element == null) {
                        var function = payload.function;
                        function.type_id = operation.type_id;
                        return .{ .returned = .{ .runtime = .{ .function_ref = function } } };
                    }
                    var target = switch (payload) {
                        .receiver => |receiver| receiver,
                        .environment => |owner| try (try allocationView(.{ .place = owner }, (try self.executor.allocationElement(owner.type_id)).?, self.executor, self.storage)).element(0),
                        .function => |function| try Cell.create(self.storage, function.type_id, .{ .value = .{ .function_ref = function } }),
                        .none => try Cell.create(self.storage, .unit, .{ .value = .unit }),
                    };
                    if (element.? == .unit and target.type_id != .unit)
                        target = try Cell.create(self.storage, .unit, .{ .opaque_reference = target });
                    return .{ .returned = try referenceValue(operation.type_id, target, self.storage) };
                },
                .callable_invoke => |operation| {
                    const cell = try self.storageCell(operation.source);
                    const target = erasedHandle(cell).invocation;
                    const invocation = if (operation.operation == .invoke) target else try self.executor.callableOwnershipAdapter(target, operation.operation, cell.type_id);
                    const reference: structures.FunctionReference = .{ .target = invocation.item, .specialization = invocation.specialization, .environment = invocation.environment, .type_id = operation.type_id };
                    return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
                },
                .callable_allocation => |operation| {
                    const handle = erasedHandle(try self.storageCell(operation.source));
                    return .{ .returned = try copyStoredValue(.{ .place = handle.payload.environment }, operation.type_id, self.executor, self.storage) };
                },
                .initializer_ref => |reference| return .{ .returned = try self.initializerValue(reference) },
                .storage_cursor => |operation| return self.storageCursor(operation),
                .cursor_offset => |operation| return .{ .returned = try offsetStorageCursor(slots[@backingInt(operation.cursor)], operation.type_id, @intCast(integer(slots, operation.index)), self.storage) },
                .cursor_element => |operation| return .{ .returned = try storageCursorElement(slots[@backingInt(operation.cursor)], operation.type_id, @intCast(integer(slots, operation.index)), self.storage) },
                .static_conversion => |conversion| return self.staticConversion(conversion, span),
                .negi => |operand| return .{ .returned = .{ .runtime = .{ .int = -%integer(slots, operand) } } },
                .addi, .subi, .muli, .divsi, .shli, .shrsi => |operands| {
                    const result = instruction.integerResult(integer(slots, operands.lhs), integer(slots, operands.rhs)) orelse return executionError(if (instruction == .divsi) .division_by_zero else .invalid_shift_count, span);
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

        fn numericBinary(self: *const Self, operation: structures.NumericBinary, span: ?structures.SourceSpan) !Result {
            const result = structures.numeric.binary(operation.type_id.numericType().?, operation.operation, operation.overflow, numericBits(scalar(self.slots, operation.operands.lhs)), numericBits(scalar(self.slots, operation.operands.rhs))) catch |err| return numericError(err, span);
            return .{ .returned = .{ .runtime = if (operation.operation.isComparison()) .{ .bool = result != 0 } else numericValue(operation.type_id, result) } };
        }
        fn numericUnary(self: *const Self, operation: structures.NumericUnary, span: ?structures.SourceSpan) !Result {
            const result = structures.numeric.unary(operation.type_id.numericType().?, operation.operation, operation.overflow, numericBits(scalar(self.slots, operation.operand))) catch |err| return numericError(err, span);
            return .{ .returned = .{ .runtime = numericValue(operation.type_id, result) } };
        }
        fn numericConvert(self: *const Self, operation: structures.NumericConversion) !Result {
            const source_type = self.body.valueType(operation.operand);
            const result = structures.numeric.convert(source_type.numericType().?, operation.destination_type.numericType().?, operation.policy, numericBits(scalar(self.slots, operation.operand)));
            if (operation.result_type == operation.destination_type) return .{ .returned = .{ .runtime = numericValue(operation.destination_type, result.?) } };
            return .{ .returned = try storedVariantValue(operation.result_type, if (result != null) operation.destination_type else .none, .{ .runtime = if (result) |bits| numericValue(operation.destination_type, bits) else .none }, self.executor) };
        }

        fn initializerValue(self: *const Self, reference: @FieldType(structures.FunctionInstruction, "initializer_ref")) !Value {
            const source = self.body.initializer_captures[reference.captures.start..reference.captures.end];
            const captures = try self.storage.alloc(Value, source.len);
            for (source, captures) |capture, *value| value.* = if (self.slots[@backingInt(capture)] == .initializer) self.slots[@backingInt(capture)] else .{ .place = try self.storageCell(capture) };
            return .{ .initializer = .{ .body = &self.body.initializer_regions[reference.region], .captures = captures } };
        }

        fn erasedCallable(self: *const Self, callable: @FieldType(structures.FunctionInstruction, "erased_callable")) !Value {
            var handle: CallableHandle = .{ .invocation = callable.invocation, .payload = .none };
            if (callable.owns_environment) {
                const owner = self.slots[@backingInt(callable.payload.?)];
                handle.payload = .{ .environment = (try copyStoredValue(owner, owner.place.type_id, self.executor, self.storage)).place };
                return .{ .place = try Cell.create(self.storage, callable.type_id, .{ .erased_callable = handle }) };
            }
            if (callable.payload) |payload| {
                const value = self.slots[@backingInt(payload)];
                handle.payload = if (referenceTarget(value)) |target| .{ .receiver = target } else .{ .function = scalar(self.slots, payload).function_ref };
            }
            return .{ .place = try Cell.create(self.storage, callable.type_id, .{ .erased_callable = handle }) };
        }

        fn projectArray(self: *const Self, operation: structures.ArrayElement) !Result {
            const cell = try self.storageCell(operation.array);
            const array = (try self.executor.arrayType(cell.type_id)) orelse return .unavailable;
            std.debug.assert(array.element_type == operation.type_id);
            const index = integer(self.slots, operation.index);
            std.debug.assert(@as(u32, @intCast(index)) < array.length);
            if (cell.contents != .allocation and !try expandFields(cell, self.executor)) return .unavailable;
            return .{ .returned = .{ .place = try elementCell(cell, @intCast(index)) } };
        }

        fn borrowAddress(self: *const Self, operation: structures.BorrowAddressOperation) !Result {
            if (operation.base_is_reference and operation.fields.start == operation.fields.end) {
                if (staticCursor(self.slots[@backingInt(operation.source)])) |static| {
                    var cursor = static;
                    cursor.type_id = operation.type_id;
                    return .{ .returned = .{ .runtime = .{ .storage_cursor = cursor } } };
                }
            }
            var target = if (operation.base_is_reference)
                referenceTarget(self.slots[@backingInt(operation.source)]) orelse return executionError(.unsupported_operation, null)
            else
                try self.storageCell(operation.source);
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
            const cell = try self.storageCell(operation.owner);
            switch (operation.projection) {
                .field => |index| {
                    if (!try expandFields(cell, self.executor)) return .unavailable;
                    const field = &cell.contents.fields[index];
                    std.debug.assert(field.type_id == .never or field.type_id == operation.type_id);
                    field.type_id = operation.type_id;
                    return .{ .returned = .{ .place = field } };
                },
                .variant => {
                    const active: ?ActiveVariant = switch (cell.contents) {
                        .uninitialized, .variant_payload => null,
                        .value => |owner| try self.activeVariant(.{ .runtime = owner }, operation.owner),
                        .fields, .reference, .opaque_reference, .erased_callable, .storage_cursor, .allocation => unreachable,
                    };
                    const payload = try selectVariantPayload(cell, operation.type_id);
                    if (active) |owner| if (owner.member_type == operation.type_id) try assignCell(payload, owner.payload, self.executor);
                    return .{ .returned = .{ .place = payload } };
                },
                .allocation_array => {
                    const array = (try self.executor.arrayType(operation.type_id)) orelse return .unavailable;
                    const allocation = try allocationView(.{ .place = cell }, array.element_type, self.executor, self.storage);
                    std.debug.assert(array.element_type == allocation.element_type);
                    std.debug.assert(array.length <= allocation.capacity);
                    return .{ .returned = try allocationValue(operation.type_id, allocation, self.storage) };
                },
            }
        }

        fn accessField(self: *const Self, value: Value, operation: structures.FieldAccessOperation) !Result {
            if (value == .place and value.place.memory != null and value.place.contents == .uninitialized)
                if (!try expandFields(value.place, self.executor)) return .unavailable;
            if (value == .place and value.place.contents == .fields) {
                const fields = value.place.contents.fields;
                const field = &fields[operation.field_index];
                std.debug.assert(field.type_id == operation.field_type);
                if (containsReference(field)) return .{ .returned = try copyStoredValue(.{ .place = field }, operation.field_type, self.executor, self.storage) };
                const field_value = (try materialize(field, self.executor, self.gpa)) orelse return .unavailable;
                return .{ .returned = .{ .runtime = field_value } };
            }
            const owner = if (value == .place) value.place.contents.value else value.runtime;
            const fields = try self.executor.lookupTuple(owner.structure);
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
            const tag = std.mem.indexOfScalar(structures.TypeId, members, active.member_type).?;
            return .{ .returned = .{ .runtime = .{ .int = @intCast(tag) } } };
        }

        fn convertVariant(self: *const Self, value: Value, operation: structures.VariantOperation) !Result {
            const active = try self.activeVariant(value, operation.operand);
            if (try self.executor.variantMembers(operation.target_type)) |target_members| {
                const source_type = self.body.valueType(operation.operand);
                const source_members = try self.executor.variantMembers(source_type);
                const source_tag = if (source_members) |members| std.mem.indexOfScalar(structures.TypeId, members, active.member_type).? else 0;
                const mapping = self.body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
                const target_tag = mapping[source_tag];
                std.debug.assert(target_tag != structures.invalid_variant_tag);
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
                return retypedFunction(payload.value, operation.target_type);
            }
            if (active.member_type == operation.target_type) return .{ .returned = try copyStoredValue(active.payload, operation.target_type, self.executor, self.storage) };
            return retypedFunction(active.payload.runtime, operation.target_type);
        }

        fn storageCursor(self: *const Self, operation: structures.BorrowOperation) !Result {
            var owner = try self.storageCell(operation.source);
            if (comptime @hasDecl(@typeInfo(@TypeOf(self.executor)).pointer.child, "allocationElement")) {
                if (try self.executor.allocationElement(owner.type_id)) |element| owner = (try allocationValue(owner.type_id, try allocationView(.{ .place = owner }, element, self.executor, self.storage), self.storage)).place;
            }
            if (owner.contents != .allocation and !try expandFields(owner, self.executor)) return .unavailable;
            const cell = try Cell.create(self.storage, operation.type_id, .{ .storage_cursor = .{ .owner = owner, .offset = 0 } });
            return .{ .returned = .{ .place = cell } };
        }

        fn staticConversion(self: *const Self, conversion: @FieldType(structures.FunctionInstruction, "static_conversion"), span: ?structures.SourceSpan) !Result {
            const source = (try self.read(conversion.operand)) orelse return .unavailable;
            // Reading materializes every place without references.
            if (source == .place) return executionError(.escaping_storage, span);
            return self.executor.convertStaticValue(self.body.valueType(conversion.operand), source.runtime, conversion.type_id, span, self.storage);
        }

        fn borrowRead(self: *const Self, operation: structures.BorrowOperation, span: ?structures.SourceSpan) !Result {
            if (staticCursor(self.slots[@backingInt(operation.source)])) |cursor| {
                const bytes = try self.executor.byteString(cursor.data.?);
                return .{ .returned = .{ .runtime = .{ .byte = bytes[cursor.offset] } } };
            }
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
            const allocation = try allocationView(self.slots[@backingInt(operation.allocation)], operation.type_id, self.executor, self.storage);
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
                    const cell = try self.storageCell(use.value);
                    destination.* = .{ .place = if (cell.contents == .opaque_reference) cell.contents.opaque_reference else cell };
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
            return switch (self.slots[@backingInt(value)]) {
                .place => |cell| if (containsReference(cell)) .{ .place = cell } else if (try materialize(cell, self.executor, self.gpa)) |runtime| .{ .runtime = runtime } else null,
                else => |ordinary| ordinary,
            };
        }

        /// The slot's storage cell, moving an immediate value into new storage.
        fn storageCell(self: *const Self, value: structures.FunctionValueId) !*Cell {
            const slot = &self.slots[@backingInt(value)];
            if (slot.* == .place) return slot.place;
            const cell = try Cell.create(self.storage, self.body.valueType(value), .{ .value = slot.runtime });
            slot.* = .{ .place = cell };
            return cell;
        }

        fn evaluateUse(self: *const Self, use: structures.FunctionValueUse) !Result {
            const value = (try self.read(use.value)) orelse return .unavailable;
            const target = use.coerce_to orelse return .{ .returned = value };
            if (use.variant_tag_mapping) |mapping| return self.convertVariant(value, .{
                .operand = use.value,
                .target_type = target,
                .tag_mapping = mapping,
            });
            return retypedFunction(value.runtime, target);
        }

        /// Binds the target's block arguments; a non-null result ends execution.
        fn enterBranch(self: *const Self, branch: structures.FunctionBranch) !?Result {
            const target = self.body.blocks[@backingInt(branch.target)];
            const arguments = self.body.branch_arguments[branch.arguments.start..branch.arguments.end];
            for (arguments, self.scratch[0..arguments.len], self.body.block_arguments[target.argument_start..target.argument_end]) |argument, *temporary, parameter| {
                if (parameter.representation == .storage or try self.executor.argumentPassing(parameter.type_id) == .indirect) {
                    std.debug.assert(argument.coerce_to == null);
                    temporary.* = .{ .place = try self.storageCell(argument.value) };
                    continue;
                }
                switch (try self.evaluateUse(argument)) {
                    .returned => |value| temporary.* = try copyStoredValue(value, parameter.type_id, self.executor, self.storage),
                    else => |result| return result,
                }
            }
            @memcpy(self.slots[target.argument_start..target.argument_end], self.scratch[0..arguments.len]);
            return null;
        }
    };
}

/// A callable value viewed at a widened function type.
fn retypedFunction(value: structures.CompileTimeValue.RuntimeValue, type_id: structures.TypeId) Result {
    var reference = value.function_ref;
    reference.type_id = type_id;
    return .{ .returned = .{ .runtime = .{ .function_ref = reference } } };
}

fn executionError(reason: ExecutionErrorReason, span: ?structures.SourceSpan) Result {
    return .{ .execution_error = .{ .reason = reason, .span = span } };
}

fn instructionSpan(body: *const structures.FunctionBodyAnalysis, instruction_index: usize) ?structures.SourceSpan {
    return if (body.instruction_spans.len == body.instructions.len) body.instruction_spans[instruction_index] else null;
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
        .place => |cell| memoryScalar(cell) orelse cell.contents.value,
        .type, .initializer => unreachable,
    };
}

fn predicateValue(
    slots: []const Value,
    operation: structures.PredicateOperation,
    operands: structures.BinaryOperands,
) bool {
    return operation.holds(switch (operation) {
        .lti, .gti, .lei, .gei, .eqi, .nei => predicateIntegerOrder(scalar(slots, operands.lhs), scalar(slots, operands.rhs)),
        .eqb, .neb => std.math.order(@intFromBool(scalar(slots, operands.lhs).bool), @intFromBool(scalar(slots, operands.rhs).bool)),
        .eqt, .net => if (slots[@backingInt(operands.lhs)].type == slots[@backingInt(operands.rhs)].type) .eq else .lt,
    });
}

fn predicateIntegerOrder(left: structures.CompileTimeValue.RuntimeValue, right: structures.CompileTimeValue.RuntimeValue) std.math.Order {
    if (left == .int_literal and right == .int_literal) return left.int_literal.order(right.int_literal);
    if (left == .int_literal) return left.int_literal.big().orderAgainstScalar(right.int);
    if (right == .int_literal) return right.int_literal.big().orderAgainstScalar(left.int).invert();
    return std.math.order(left.int, right.int);
}

pub fn copyStoredValue(value: Value, type_id: structures.TypeId, executor: anytype, storage: std.mem.Allocator) !Value {
    if (value != .place) return value;
    const copy = try Cell.create(storage, type_id, .uninitialized);
    try assignCell(copy, value, executor);
    return .{ .place = copy };
}

fn erasedHandle(cell: *const Cell) CallableHandle {
    if (cell.contents == .erased_callable) return cell.contents.erased_callable;
    const constant = cell.contents.value.erased_callable;
    return .{ .invocation = constant.invocation, .payload = if (constant.payload) |function| .{ .function = function } else .none };
}

pub fn containsReference(cell: *const Cell) bool {
    return switch (cell.contents) {
        .reference, .opaque_reference, .storage_cursor, .allocation => true,
        .erased_callable => |callable| callable.payload == .receiver or callable.payload == .environment,
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
    try assignCellContents(destination, source, executor);
    if (destination.memory != null and destination.contents == .value and destination.contents.value == .structure)
        _ = try expandFields(destination, executor);
    try attachMemoryFields(destination, executor);
    try writeMemory(destination, executor);
}

fn assignCellContents(destination: *Cell, source: Value, executor: anytype) anyerror!void {
    if (source == .place and source.place.memory != null) {
        try refreshMemoryVariant(source.place, executor);
        if (memoryScalar(source.place)) |value| return assignRuntime(destination, value, executor);
        if (source.place.contents == .uninitialized) _ = try expandFields(source.place, executor);
    }
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
            switch (cell.contents) {
                .value => |runtime| try assignRuntime(destination, runtime, executor),
                .uninitialized, .storage_cursor, .reference, .opaque_reference, .erased_callable => destination.contents = cell.contents,
                .allocation => |allocation| {
                    if (try executor.arrayType(cell.type_id)) |array| {
                        const copied = try uninitializedCells(destination.storage, array.length, array.element_type);
                        for (copied, 0..) |*copy, index| try assignCell(copy, .{ .place = try allocation.element(@intCast(index)) }, executor);
                        destination.contents = .{ .fields = copied };
                    } else destination.contents = .{ .allocation = allocation };
                },
                .fields => |fields| {
                    if (destination.contents != .fields)
                        destination.contents = .{ .fields = try uninitializedCells(destination.storage, fields.len, .never) };
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

/// Fresh storage for `count` elements; `.never` leaves each type to its first write.
fn uninitializedCells(storage: std.mem.Allocator, count: usize, element_type: structures.TypeId) ![]Cell {
    const cells = try storage.alloc(Cell, count);
    @memset(cells, .{ .type_id = element_type, .storage = storage, .contents = .uninitialized });
    return cells;
}

/// Element `index` of inline fields, an allocation, or an interned tuple.
pub fn aggregateElement(aggregate: Value, index: usize, executor: anytype) !Value {
    if (aggregate == .place and (aggregate.place.contents == .fields or aggregate.place.contents == .allocation))
        return .{ .place = try elementCell(aggregate.place, @intCast(index)) };
    const values = try executor.lookupTuple(storedRuntime(aggregate).structure);
    const value = (try executor.lookupRuntime(values[index])) orelse return error.Unavailable;
    return .{ .runtime = value.value };
}

fn assignRuntime(destination: *Cell, runtime: structures.CompileTimeValue.RuntimeValue, executor: anytype) anyerror!void {
    if (destination.contents == .fields and runtime == .structure) {
        const values = try executor.lookupTuple(runtime.structure);
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
            const element_type = if (array) |shape| shape.element_type else .never;
            cell.contents = .{ .fields = try uninitializedCells(cell.storage, count, element_type) };
        },
        .value => |runtime| {
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
        .variant_payload, .reference, .opaque_reference, .erased_callable, .storage_cursor, .allocation => unreachable,
    }
    try attachMemoryFields(cell, executor);
    return true;
}

fn borrowVariantCell(target: *Cell, member: structures.TypeId, executor: anytype) !?*Cell {
    try refreshMemoryVariant(target, executor);
    if (target.contents == .value) {
        const value = (try executor.lookupRuntime(target.contents.value.variant.payload)) orelse return null;
        std.debug.assert(value.type_id == member);
        const payload = try Cell.create(target.storage, member, .{ .value = value.value });
        target.contents = .{ .variant_payload = payload };
    }
    std.debug.assert(target.contents.variant_payload.type_id == member);
    return target.contents.variant_payload;
}

fn materialize(cell: *Cell, executor: anytype, gpa: std.mem.Allocator) anyerror!?structures.CompileTimeValue.RuntimeValue {
    if (memoryScalar(cell)) |value| return value;
    try refreshMemoryVariant(cell, executor);
    if (cell.memory != null and cell.contents == .uninitialized) _ = try expandFields(cell, executor);
    switch (cell.contents) {
        .value => |value| return value,
        .reference, .opaque_reference, .storage_cursor, .allocation => return null,
        .erased_callable => |callable| {
            if (callable.payload == .receiver or callable.payload == .environment) return null;
            return .{ .erased_callable = .{ .invocation = callable.invocation, .payload = if (callable.payload == .function) callable.payload.function else null, .type_id = cell.type_id } };
        },
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

fn memoryScalar(cell: *const Cell) ?structures.CompileTimeValue.RuntimeValue {
    const memory = cell.memory orelse return null;
    const size: u32 = if (cell.type_id.numericType()) |numeric| numeric.width() / 8 else if (cell.type_id == .bool) 1 else return null;
    const bits = memoryBits(memory, size) orelse return null;
    return if (cell.type_id == .bool) .{ .bool = bits != 0 } else numericValue(cell.type_id, bits);
}

fn memoryByte(source: *const Cell, offset: u32) ?*const Cell {
    switch (source.contents) {
        .fields => |fields| return &fields[offset],
        .allocation => |allocation| {
            std.debug.assert(!allocation.released);
            if (allocation.source) |backing| return memoryByte(backing, allocation.byte_offset + offset);
            return allocation.elements.get(offset);
        },
        else => return null,
    }
}

fn attachMemoryFields(cell: *Cell, executor: anytype) anyerror!void {
    if (comptime !@hasDecl(@typeInfo(@TypeOf(executor)).pointer.child, "hostLayout")) return;
    const memory = cell.memory orelse return;
    if (comptime @hasDecl(@typeInfo(@TypeOf(executor)).pointer.child, "variantLayout")) {
        if (try executor.variantMembers(cell.type_id) != null) {
            if (cell.contents == .value and cell.contents.value == .variant) {
                const value = (try executor.lookupRuntime(cell.contents.value.variant.payload)).?;
                const payload = try selectVariantPayload(cell, value.type_id);
                try assignRuntime(payload, value.value, executor);
            }
            if (cell.contents == .variant_payload) {
                const layout = try executor.variantLayout(cell.type_id);
                cell.contents.variant_payload.memory = .{ .source = memory.source, .offset = memory.offset + layout.payload_offset };
                try attachMemoryFields(cell.contents.variant_payload, executor);
            }
            return;
        }
    }
    if (cell.contents != .fields) return;
    const array = try executor.arrayType(cell.type_id);
    if (array) |shape| {
        const layout = try executor.hostLayout(shape.element_type);
        for (cell.contents.fields, 0..) |*field, index| {
            field.memory = .{ .source = memory.source, .offset = memory.offset + @as(u32, @intCast(index)) * layout.byte_size };
            try attachMemoryFields(field, executor);
        }
        return;
    }
    if (comptime @hasDecl(@typeInfo(@TypeOf(executor)).pointer.child, "structLayout")) {
        const layout = (try executor.structLayout(cell.type_id)) orelse return;
        for (cell.contents.fields, layout.field_offsets, 0..) |*field, offset, index| {
            if (field.type_id == .never) field.type_id = (try executor.structFieldType(cell.type_id, index)).?;
            field.memory = .{ .source = memory.source, .offset = memory.offset + offset };
            try attachMemoryFields(field, executor);
        }
    }
}

fn refreshMemoryVariant(cell: *Cell, executor: anytype) anyerror!void {
    if (comptime !@hasDecl(@typeInfo(@TypeOf(executor)).pointer.child, "variantLayout")) return;
    const memory = cell.memory orelse return;
    const members = (try executor.variantMembers(cell.type_id)) orelse return;
    const layout = try executor.variantLayout(cell.type_id);
    const tag = memoryBits(memory, layout.tag_size) orelse return;
    if (tag >= members.len) return error.Unavailable;
    const payload = try selectVariantPayload(cell, members[@intCast(tag)]);
    payload.memory = .{ .source = memory.source, .offset = memory.offset + layout.payload_offset };
}

fn memoryBits(memory: MemoryView, size: u32) ?u64 {
    var bits: u64 = 0;
    for (0..size) |index| {
        const byte = memoryByte(memory.source, memory.offset + @as(u32, @intCast(index))) orelse return null;
        if (byte.contents != .value or byte.contents.value != .byte) return null;
        bits |= @as(u64, byte.contents.value.byte) << @intCast(index * 8);
    }
    return bits;
}

fn writeMemory(cell: *Cell, executor: anytype) anyerror!void {
    const memory = cell.memory orelse return;
    if (cell.contents == .fields) {
        for (cell.contents.fields) |*field| try writeMemory(field, executor);
        return;
    }
    if (comptime @hasDecl(@typeInfo(@TypeOf(executor)).pointer.child, "variantLayout")) {
        if (cell.contents == .variant_payload) {
            const layout = try executor.variantLayout(cell.type_id);
            const members = (try executor.variantMembers(cell.type_id)).?;
            const tag = std.mem.indexOfScalar(structures.TypeId, members, cell.contents.variant_payload.type_id).?;
            try writeMemoryBits(memory, layout.tag_size, tag);
            try writeMemory(cell.contents.variant_payload, executor);
            return;
        }
    }
    if (cell.contents != .value) return;
    const size: u32 = if (cell.type_id.numericType()) |numeric| numeric.width() / 8 else if (cell.type_id == .bool) 1 else return;
    const bits = if (cell.type_id == .bool) @as(u64, @intFromBool(cell.contents.value.bool)) else numericBits(cell.contents.value);
    try writeMemoryBits(memory, size, bits);
}

fn writeMemoryBits(memory: MemoryView, size: u32, bits: u64) anyerror!void {
    for (0..size) |index| {
        const byte = try elementCell(memory.source, memory.offset + @as(u32, @intCast(index)));
        byte.contents = .{ .value = .{ .byte = @truncate(bits >> @intCast(index * 8)) } };
    }
}

fn variantValue(member_type: structures.TypeId, payload: structures.CompileTimeValueId) structures.CompileTimeValue.RuntimeValue {
    return .{ .variant = .{ .member_type = member_type, .payload = payload } };
}

pub fn storedVariantValue(type_id: structures.TypeId, member_type: structures.TypeId, payload: Value, executor: anytype) !Value {
    if (payload == .runtime) return .{ .runtime = variantValue(member_type, try executor.internRuntime(member_type, payload.runtime)) };
    const member = try copyStoredValue(payload, member_type, executor, payload.place.storage);
    return .{ .place = try Cell.create(payload.place.storage, type_id, .{ .variant_payload = member.place }) };
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
    return elementCell(cursor.owner, std.math.add(u32, cursor.offset, offset) catch return error.TypeTooLarge);
}

/// Element `index` of expanded inline fields or of an allocation.
fn elementCell(aggregate: *Cell, index: u32) !*Cell {
    if (aggregate.contents == .allocation) return aggregate.contents.allocation.element(index);
    return &aggregate.contents.fields[index];
}

/// Snapshot a validated StringView while its evaluation-local backing is alive.
pub fn panicMessage(message: Value, executor: anytype, gpa: std.mem.Allocator) !structures.ByteStringId {
    const bytes_view = try aggregateElement(message, 0, executor);
    const span = try aggregateElement(bytes_view, 0, executor);
    const cursor = try aggregateElement(span, 0, executor);
    const size = try aggregateElement(span, 1, executor);
    const count = integerValue(size);
    const bytes = try gpa.alloc(u8, @intCast(count));
    defer gpa.free(bytes);
    for (bytes, 0..) |*byte, index| {
        if (staticCursor(cursor)) |static| {
            byte.* = (try executor.byteString(static.data.?))[static.offset + index];
        } else {
            byte.* = (try storageCursorCell(cursor.place, @intCast(index))).contents.value.byte;
        }
    }
    return executor.internBytes(bytes);
}

/// A cursor into static bytes, held immediately or whole by a cell.
fn staticCursor(value: Value) ?structures.StaticStorageCursor {
    if (value == .place and value.place.contents != .value) return null;
    const runtime = storedRuntime(value);
    return if (runtime == .storage_cursor) runtime.storage_cursor else null;
}

fn allocationView(value: Value, element_type: structures.TypeId, executor: anytype, storage: std.mem.Allocator) anyerror!*Allocation {
    if (value.place.contents == .allocation) return value.place.contents.allocation;
    if (comptime !@hasDecl(@typeInfo(@TypeOf(executor)).pointer.child, "allocationElement")) return allocationRecord(value);
    if (try executor.allocationElement(value.place.type_id) == null) return allocationRecord(value);
    const raw = try aggregateElement(value, 0, executor);
    var cursor = (try aggregateElement(raw, 0, executor)).place.contents.storage_cursor;
    while (cursor.owner.contents == .allocation) {
        const backing = cursor.owner.contents.allocation;
        const source = backing.source orelse break;
        std.debug.assert(backing.element_type == .byte);
        cursor.offset = try std.math.add(u32, backing.byte_offset, cursor.offset);
        cursor.owner = source;
    }
    const count = integerValue(try aggregateElement(value, 1, executor));
    const layout = try executor.hostLayout(element_type);
    const view = try storage.create(Allocation);
    view.* = .{
        .identity = @intFromPtr(cursor.owner),
        .element_type = element_type,
        .capacity = @intCast(count),
        .source = cursor.owner,
        .byte_offset = cursor.offset,
        .element_size = layout.byte_size,
        .backing = .init(storage),
        .identities = storage,
    };
    return view;
}

pub fn allocationRecord(value: Value) *Allocation {
    const cell = value.place;
    if (cell.contents == .fields) {
        return allocationRecord(.{ .place = &cell.contents.fields[0] });
    }
    if (cell.contents == .storage_cursor) return allocationRecord(.{ .place = cell.contents.storage_cursor.owner });
    const record = cell.contents.allocation;
    if (record.source) |source| return allocationRecord(.{ .place = source });
    return record;
}

pub fn allocationValue(type_id: structures.TypeId, allocation: *Allocation, storage: std.mem.Allocator) !Value {
    return .{ .place = try Cell.create(storage, type_id, .{ .allocation = allocation }) };
}

pub fn rawAllocationValue(type_id: structures.TypeId, cursor_type: structures.TypeId, layout_type: structures.TypeId, allocation: *Allocation, layout: Value, executor: anytype, storage: std.mem.Allocator) !Value {
    const backing = try Cell.create(storage, type_id, .{ .allocation = allocation });
    const fields = try uninitializedCells(storage, 2, .never);
    fields[0] = .{ .type_id = cursor_type, .storage = storage, .contents = .{ .storage_cursor = .{ .owner = backing, .offset = 0 } } };
    fields[1].type_id = layout_type;
    try assignCell(&fields[1], layout, executor);
    return .{ .place = try Cell.create(storage, type_id, .{ .fields = fields }) };
}

pub fn cursorAligned(cursor: Value, alignment: i32) bool {
    if (alignment <= 0) return false;
    if (cursor == .place and cursor.place.contents == .storage_cursor) return cursor.place.contents.storage_cursor.offset % @as(u32, @intCast(alignment)) == 0;
    return false;
}

pub fn integerValue(value: Value) i32 {
    return storedRuntime(value).int;
}

pub fn releaseAllocation(value: Value) void {
    allocationRecord(value).release();
}

pub fn numericBits(value: structures.CompileTimeValue.RuntimeValue) u64 {
    return switch (value) {
        .int => |integer_value| structures.numeric.encode(i32, integer_value),
        .byte => |byte| byte,
        .numeric => |bits| bits,
        else => unreachable,
    };
}
pub fn numericValue(type_id: structures.TypeId, bits: u64) structures.CompileTimeValue.RuntimeValue {
    return switch (type_id) {
        .int => .{ .int = structures.numeric.decode(i32, bits) },
        .byte => .{ .byte = @intCast(bits) },
        else => .{ .numeric = bits },
    };
}
fn numericError(err: structures.numeric.Error, span: ?structures.SourceSpan) Result {
    return executionError(switch (err) {
        error.Overflow => .integer_overflow,
        error.DivisionByZero => .division_by_zero,
        error.InvalidShift => .invalid_shift_count,
    }, span);
}
