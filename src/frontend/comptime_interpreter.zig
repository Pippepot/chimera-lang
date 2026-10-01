const std = @import("std");
const structures = @import("../structures.zig");

pub const ExecutionErrorReason = enum {
    call_cycle,
    division_by_zero,
    integer_overflow,
    unsupported_operation,
};

pub const ExecutionError = struct {
    reason: ExecutionErrorReason,
    span: ?structures.SourceSpan = null,
};

pub const Value = union(enum) {
    runtime: structures.CompileTimeValue.RuntimeValue,
    type: structures.TypeId,
    place: *Cell,
};

pub const Cell = struct {
    type_id: structures.TypeId,
    contents: union(enum) {
        uninitialized,
        value: structures.CompileTimeValue.RuntimeValue,
        fields: []Cell,
        variant_payload: *Cell,
    },
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
) !Result {
    const slot_count = body.valueCount();
    const branch_scratch_count = body.block_argument_types.len;
    const frame = try gpa.alloc(Value, slot_count + branch_scratch_count + body.call_arguments.len);
    defer gpa.free(frame);
    const slots = frame[0..slot_count];
    const scratch = frame[slot_count .. slot_count + branch_scratch_count];
    const call_scratch = frame[slot_count + branch_scratch_count ..];
    @memset(slots, .{ .runtime = .unit });
    var storage_arena: std.heap.ArenaAllocator = .init(gpa);
    defer storage_arena.deinit();
    const storage = storage_arena.allocator();

    var block_id = body.entry;
    const entry = body.blocks[@intFromEnum(block_id)];
    std.debug.assert(entry.argument_start == 0);
    std.debug.assert(entry.argument_end == arguments.len);
    @memcpy(slots[entry.argument_start..entry.argument_end], arguments);
    while (true) {
        const block = body.blocks[@intFromEnum(block_id)];
        for (block.instruction_start..block.instruction_end) |instruction_index| {
            const instruction = body.instructions[instruction_index];
            const destination = @intFromEnum(body.instructionValue(instruction_index));
            switch (instruction) {
                .const_int => |value| slots[destination] = .{ .runtime = .{ .int = value } },
                .const_byte => |value| slots[destination] = .{ .runtime = .{ .byte = value } },
                .const_bool => |value| slots[destination] = .{ .runtime = .{ .bool = value } },
                .const_type => |type_id| slots[destination] = .{ .type = type_id },
                .const_unit => slots[destination] = .{ .runtime = .unit },
                .const_none => slots[destination] = .{ .runtime = .none },
                .function_ref => |reference| slots[destination] = .{ .runtime = .{ .function_ref = reference } },
                .callable_coerce => |operation| {
                    var reference = slots[@intFromEnum(operation.operand)].runtime.function_ref;
                    reference.type_id = operation.target_type;
                    store(slots, destination, operation.destination, .{ .runtime = .{ .function_ref = reference } });
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
                .call => |call| if (try executeReturningCall(body, slots, call_scratch, destination, instruction_index, call, executor, gpa)) |result| return result,
                .variant_tag => |operand| switch (try variantTag(body, (try runtimeOperand(slots, operand, executor, gpa)) orelse return .unavailable, operand, executor)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .variant_coerce => |operation| switch (try coerceVariant(body, (try runtimeOperand(slots, operation.operand, executor, gpa)) orelse return .unavailable, operation, executor)) {
                    .returned => |value| store(slots, destination, operation.destination, value),
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .variant_extract => |operation| switch (try extractVariant(body, (try runtimeOperand(slots, operation.operand, executor, gpa)) orelse return .unavailable, operation, executor)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .struct_init => |operation| switch (try initializeStruct(body, slots, operation, executor, gpa)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .local_storage, .result_storage => |type_id| {
                    const cell = try storage.create(Cell);
                    cell.* = .{ .type_id = type_id, .contents = .uninitialized };
                    slots[destination] = .{ .place = cell };
                },
                .storage_projection => |operation| switch (try projectStorage(body, slots, operation, executor, storage)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .box_init, .allocation_element, .borrow_box, .borrow_address, .borrow_read, .borrow_write => return executionError(.unsupported_operation, instructionSpan(body, instruction_index)),
                .value_copy => |operation| store(slots, destination, operation.destination, (try readSlot(slots, operation.source, executor, gpa)) orelse return .unavailable),
                .field_access => |operation| switch (try accessField(slots[@intFromEnum(operation.operand)], operation, executor, gpa)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .field_update => |operation| switch (try updateField(body, slots, operation, executor, gpa)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atSpan(result, instructionSpan(body, instruction_index)),
                },
                .mut_parameter_write => |operation| {
                    std.debug.assert(operation.parameter_index < arguments.len);
                    arguments[operation.parameter_index] = (try readSlot(slots, operation.value, executor, gpa)) orelse return .unavailable;
                    slots[destination] = .{ .runtime = .unit };
                },
                .call_mut_argument => |operation| {
                    const index = operation.arguments.start + operation.argument_index;
                    std.debug.assert(index < operation.arguments.end);
                    store(slots, destination, operation.destination, call_scratch[index]);
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
            .fallible_call => |fallible| switch (try executeFallibleCall(body, slots, call_scratch, fallible.call, fallible.success, fallible.failure, terminatorSpan(body, block_id), executor, gpa)) {
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
    return if (body.terminator_spans.len == body.blocks.len) body.terminator_spans[@intFromEnum(block_id)] else null;
}

fn integer(slots: []const Value, value: structures.FunctionValueId) i32 {
    return slots[@intFromEnum(value)].runtime.int;
}

fn predicateValue(
    slots: []const Value,
    operation: structures.PredicateOperation,
    operands: structures.BinaryOperands,
) bool {
    return switch (operation) {
        .lti => integer(slots, operands.lhs) < integer(slots, operands.rhs),
        .gti => integer(slots, operands.lhs) > integer(slots, operands.rhs),
        .lei => integer(slots, operands.lhs) <= integer(slots, operands.rhs),
        .gei => integer(slots, operands.lhs) >= integer(slots, operands.rhs),
        .eqi => integer(slots, operands.lhs) == integer(slots, operands.rhs),
        .nei => integer(slots, operands.lhs) != integer(slots, operands.rhs),
        .eqb => slots[@intFromEnum(operands.lhs)].runtime.bool == slots[@intFromEnum(operands.rhs)].runtime.bool,
        .neb => slots[@intFromEnum(operands.lhs)].runtime.bool != slots[@intFromEnum(operands.rhs)].runtime.bool,
        .eqt => slots[@intFromEnum(operands.lhs)].type == slots[@intFromEnum(operands.rhs)].type,
        .net => slots[@intFromEnum(operands.lhs)].type != slots[@intFromEnum(operands.rhs)].type,
    };
}

fn executeCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const Value,
    scratch: []Value,
    call: structures.FunctionCall,
    call_span: ?structures.SourceSpan,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Result {
    const instance = switch (call.target) {
        .direct => |instance| instance,
        .indirect => |value| slots[@intFromEnum(value)].runtime.function_ref.instance(),
    };
    const arguments = body.call_arguments[call.arguments.start..call.arguments.end];
    const interpreted = scratch[call.arguments.start..call.arguments.end];
    for (arguments, interpreted) |argument, *destination| {
        switch (try valueUse(body, slots, argument.valueUse(), executor, gpa)) {
            .returned => |value| destination.* = value,
            else => |result| return result,
        }
    }
    return executor.call(instance, interpreted, call_span);
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
) !?Result {
    return switch (atSpan(
        try executeCall(body, slots, scratch, call, instructionSpan(body, instruction_index), executor, gpa),
        instructionSpan(body, instruction_index),
    )) {
        .returned => |value| blk: {
            store(slots, destination, call.destination, value);
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
    failure_id: structures.FunctionBlockId,
    call_span: ?structures.SourceSpan,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Step {
    return switch (try executeCall(body, slots, scratch, call, call_span, executor, gpa)) {
        .returned => |value| blk: {
            const success = body.blocks[@intFromEnum(success_id)];
            std.debug.assert(success.argument_end - success.argument_start == 1);
            store(slots, success.argument_start, call.destination, value);
            break :blk .{ .next = success_id };
        },
        .failure => .{ .next = failure_id },
        .exit => |status| .{ .result = .{ .exit = status } },
        .execution_error => |value| .{ .result = .{ .execution_error = value } },
        .reported_error => .{ .result = .reported_error },
        .unavailable => .{ .result = .unavailable },
    };
}

fn valueType(body: *const structures.FunctionBodyAnalysis, value: structures.FunctionValueId) structures.TypeId {
    const index = @intFromEnum(value);
    if (index < body.block_argument_types.len) return body.block_argument_types[index];
    return body.instructions[index - body.block_argument_types.len].resultType();
}

fn store(slots: []Value, own: usize, destination: ?structures.FunctionValueId, value: Value) void {
    const storage = destination orelse {
        slots[own] = value;
        return;
    };
    switch (slots[@intFromEnum(storage)]) {
        .place => |cell| cell.contents = .{ .value = value.runtime },
        .runtime => slots[@intFromEnum(storage)] = value,
        .type => unreachable,
    }
    slots[own] = .{ .runtime = .unit };
}

fn readSlot(slots: []const Value, value: structures.FunctionValueId, executor: anytype, gpa: std.mem.Allocator) !?Value {
    return switch (slots[@intFromEnum(value)]) {
        .place => |cell| if (try materialize(cell, executor, gpa)) |runtime| .{ .runtime = runtime } else null,
        else => |ordinary| ordinary,
    };
}

fn runtimeOperand(slots: []const Value, value: structures.FunctionValueId, executor: anytype, gpa: std.mem.Allocator) !?structures.CompileTimeValue.RuntimeValue {
    return if (try readSlot(slots, value, executor, gpa)) |read| read.runtime else null;
}

fn storageCell(body: *const structures.FunctionBodyAnalysis, slots: []Value, value: structures.FunctionValueId, storage: std.mem.Allocator) !*Cell {
    const slot = &slots[@intFromEnum(value)];
    if (slot.* == .place) return slot.place;
    std.debug.assert(slot.* == .runtime);
    const cell = try storage.create(Cell);
    cell.* = .{ .type_id = valueType(body, value), .contents = .{ .value = slot.runtime } };
    slot.* = .{ .place = cell };
    return cell;
}

fn materialize(cell: *const Cell, executor: anytype, gpa: std.mem.Allocator) !?structures.CompileTimeValue.RuntimeValue {
    switch (cell.contents) {
        .value => |value| return value,
        .uninitialized => {
            std.debug.assert(cell.type_id != .never);
            const field_count = (try executor.structFieldCount(cell.type_id)) orelse return null;
            std.debug.assert(field_count == 0);
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
    if (operation.projection == .dereference) return executionError(.unsupported_operation, null);
    const cell = try storageCell(body, slots, operation.owner, storage);
    switch (operation.projection) {
        .field => |index| {
            switch (cell.contents) {
                .uninitialized => {
                    const field_count = (try executor.structFieldCount(cell.type_id)) orelse return .unavailable;
                    const fields = try storage.alloc(Cell, field_count);
                    for (fields) |*field| field.* = .{ .type_id = .never, .contents = .uninitialized };
                    cell.contents = .{ .fields = fields };
                },
                .value => |owner| {
                    const values = try executor.lookupTuple(owner.structure);
                    const fields = try storage.alloc(Cell, values.len);
                    for (values, fields) |value_id, *field| {
                        const value = (try executor.lookupRuntime(value_id)) orelse return .unavailable;
                        field.* = .{ .type_id = value.type_id, .contents = .{ .value = value.value } };
                    }
                    cell.contents = .{ .fields = fields };
                },
                .fields => {},
                .variant_payload => unreachable,
            }
            const field = &cell.contents.fields[index];
            std.debug.assert(field.type_id == .never or field.type_id == operation.type_id);
            field.type_id = operation.type_id;
            return .{ .returned = .{ .place = field } };
        },
        .variant => {
            switch (cell.contents) {
                .uninitialized => {
                    const payload = try storage.create(Cell);
                    payload.* = .{ .type_id = operation.type_id, .contents = .uninitialized };
                    cell.contents = .{ .variant_payload = payload };
                },
                .value => |owner| {
                    const active = try activeVariant(body, owner, operation.owner, executor);
                    const payload = try storage.create(Cell);
                    payload.* = .{ .type_id = operation.type_id, .contents = .uninitialized };
                    if (active.member_type == operation.type_id)
                        payload.contents = .{ .value = ((try executor.lookupRuntime(active.payload)) orelse return .unavailable).value };
                    cell.contents = .{ .variant_payload = payload };
                },
                .variant_payload => |payload| if (payload.type_id != operation.type_id) {
                    payload.* = .{ .type_id = operation.type_id, .contents = .uninitialized };
                },
                .fields => unreachable,
            }
            return .{ .returned = .{ .place = cell.contents.variant_payload } };
        },
        .dereference => unreachable,
    }
}

fn initializeStruct(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const Value,
    operation: structures.StructOperation,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Result {
    const fields = body.struct_field_values[operation.fields.start..operation.fields.end];
    const values = try gpa.alloc(structures.CompileTimeValueId, fields.len);
    defer gpa.free(values);
    for (fields) |field| {
        std.debug.assert(field.field_index < values.len);
        const value = (try runtimeOperand(slots, field.value, executor, gpa)) orelse return .unavailable;
        values[field.field_index] = try executor.internRuntime(valueType(body, field.value), value);
    }
    return .{ .returned = .{ .runtime = .{ .structure = try executor.internTuple(values) } } };
}

fn accessField(
    value: Value,
    operation: structures.FieldAccessOperation,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Result {
    if (value == .place and value.place.contents == .fields) {
        const fields = value.place.contents.fields;
        std.debug.assert(operation.field_index < fields.len);
        const field = &fields[operation.field_index];
        std.debug.assert(field.type_id == operation.field_type);
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

fn updateField(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const Value,
    operation: structures.FieldUpdateOperation,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Result {
    const operand = (try runtimeOperand(slots, operation.operand, executor, gpa)) orelse return .unavailable;
    const updated = (try runtimeOperand(slots, operation.value, executor, gpa)) orelse return .unavailable;
    const source = try executor.lookupTuple(operand.structure);
    const fields = try gpa.dupe(structures.CompileTimeValueId, source);
    defer gpa.free(fields);
    std.debug.assert(operation.field_index < fields.len);
    fields[operation.field_index] = try executor.internRuntime(valueType(body, operation.value), updated);
    return .{ .returned = .{ .runtime = .{ .structure = try executor.internTuple(fields) } } };
}

const ActiveVariant = struct {
    member_type: structures.TypeId,
    payload: structures.CompileTimeValueId,
};

fn activeVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operand: structures.FunctionValueId,
    executor: anytype,
) !ActiveVariant {
    if (value == .variant) return .{ .member_type = value.variant.member_type, .payload = value.variant.payload };
    const source_type = valueType(body, operand);
    std.debug.assert(try executor.variantMembers(source_type) == null);
    return .{ .member_type = source_type, .payload = try executor.internRuntime(source_type, value) };
}

fn variantTag(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operand: structures.FunctionValueId,
    executor: anytype,
) !Result {
    const active = try activeVariant(body, value, operand, executor);
    const members = (try executor.variantMembers(valueType(body, operand))) orelse unreachable;
    for (members, 0..) |member, tag| if (member == active.member_type) return .{ .returned = .{ .runtime = .{ .int = @intCast(tag) } } };
    unreachable;
}

fn variantValue(member_type: structures.TypeId, payload: structures.CompileTimeValueId) structures.CompileTimeValue.RuntimeValue {
    return .{ .variant = .{ .member_type = member_type, .payload = payload } };
}

fn coerceVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operation: structures.VariantOperation,
    executor: anytype,
) !Result {
    const mapping = body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
    const source_type = valueType(body, operation.operand);
    const source_members = try executor.variantMembers(source_type);
    var payload: structures.CompileTimeValueId = undefined;
    const source_tag: usize = if (source_members) |members| blk: {
        const active = try activeVariant(body, value, operation.operand, executor);
        payload = active.payload;
        break :blk for (members, 0..) |member, tag| {
            if (member == active.member_type) break tag;
        } else unreachable;
    } else blk: {
        payload = try executor.internRuntime(source_type, value);
        break :blk 0;
    };
    std.debug.assert(source_tag < mapping.len);
    const target_tag = mapping[source_tag];
    std.debug.assert(target_tag != structures.invalid_variant_tag);
    const target_members = (try executor.variantMembers(operation.target_type)) orelse unreachable;
    std.debug.assert(target_tag < target_members.len);
    return .{ .returned = .{ .runtime = variantValue(target_members[target_tag], payload) } };
}

fn extractVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operation: structures.VariantOperation,
    executor: anytype,
) !Result {
    const active = try activeVariant(body, value, operation.operand, executor);
    if (try executor.variantMembers(operation.target_type)) |target_members| {
        const source_members = (try executor.variantMembers(valueType(body, operation.operand))).?;
        const source_tag = for (source_members, 0..) |member, tag| {
            if (member == active.member_type) break tag;
        } else unreachable;
        const mapping = body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
        const target_tag = mapping[source_tag];
        std.debug.assert(target_tag != structures.invalid_variant_tag);
        std.debug.assert(target_tag < target_members.len);
        return .{ .returned = .{ .runtime = variantValue(target_members[target_tag], active.payload) } };
    }
    const payload = (try executor.lookupRuntime(active.payload)) orelse return .unavailable;
    if (payload.type_id == operation.target_type) return .{ .returned = .{ .runtime = payload.value } };
    var reference = payload.value.function_ref;
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
    if (use.variant_tag_mapping) |mapping| return coerceVariant(body, value.runtime, .{
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
    const target = body.blocks[@intFromEnum(branch.target)];
    const arguments = body.branch_arguments[branch.arguments.start..branch.arguments.end];
    std.debug.assert(arguments.len == target.argument_end - target.argument_start);
    for (arguments, scratch[0..arguments.len], body.block_argument_types[target.argument_start..target.argument_end]) |argument, *temporary, type_id| {
        if (try executor.argumentPassing(type_id) == .indirect) {
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
