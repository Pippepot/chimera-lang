const std = @import("std");
const structures = @import("structures.zig");

pub const UnsupportedReason = enum {
    instruction,
    coercion,
    call_cycle,
    division_by_zero,
    integer_overflow,
    resource_limit,
};

pub const Unsupported = struct {
    reason: UnsupportedReason,
    instruction_index: ?u32 = null,
};

pub const Result = union(enum) {
    returned: structures.CompileTimeValue.RuntimeValue,
    failure,
    exit: i32,
    unsupported: Unsupported,
    unavailable,
};

const default_block_fuel: u32 = 1_000_000;
const default_aggregate_fuel: u32 = 1_000_000;

/// Execute the supported subset of a typed body. Slots are dense and frame-local;
/// aggregate components are interned only when they cross value boundaries.
pub fn execute(
    body: *const structures.FunctionBodyAnalysis,
    arguments: []structures.CompileTimeValue.RuntimeValue,
    executor: anytype,
    gpa: std.mem.Allocator,
) !Result {
    const slot_count = body.valueCount();
    const branch_scratch_count = body.block_argument_types.len;
    const frame = try gpa.alloc(
        structures.CompileTimeValue.RuntimeValue,
        slot_count + branch_scratch_count + body.call_arguments.len,
    );
    defer gpa.free(frame);
    const slots = frame[0..slot_count];
    const scratch = frame[slot_count .. slot_count + branch_scratch_count];
    const call_scratch = frame[slot_count + branch_scratch_count ..];
    @memset(slots, .unit);

    var block_id = body.entry;
    const entry = body.blocks[@intFromEnum(block_id)];
    std.debug.assert(entry.argument_start == 0);
    std.debug.assert(entry.argument_end == arguments.len);
    @memcpy(slots[entry.argument_start..entry.argument_end], arguments);
    var fuel = default_block_fuel;
    var aggregate_fuel = default_aggregate_fuel;
    while (true) {
        if (fuel == 0) return .{ .unsupported = .{ .reason = .resource_limit } };
        fuel -= 1;

        const block = body.blocks[@intFromEnum(block_id)];
        for (block.instruction_start..block.instruction_end) |instruction_index| {
            const instruction = body.instructions[instruction_index];
            const destination = @intFromEnum(body.instructionValue(instruction_index));
            switch (instruction) {
                .consti => |value| slots[destination] = .{ .int = value },
                .constb => |value| slots[destination] = .{ .bool = value },
                .const_unit => slots[destination] = .unit,
                .const_none => slots[destination] = .none,
                .function_ref => |reference| slots[destination] = .{ .function_ref = reference },
                .callable_coerce => |operation| {
                    var reference = slots[@intFromEnum(operation.operand)].function_ref;
                    reference.type_id = operation.target_type;
                    slots[destination] = .{ .function_ref = reference };
                },
                .negi => |operand| slots[destination] = .{ .int = -%integer(slots, operand) },
                .addi => |operands| slots[destination] = .{ .int = integer(slots, operands.lhs) +% integer(slots, operands.rhs) },
                .subi => |operands| slots[destination] = .{ .int = integer(slots, operands.lhs) -% integer(slots, operands.rhs) },
                .muli => |operands| slots[destination] = .{ .int = integer(slots, operands.lhs) *% integer(slots, operands.rhs) },
                .divsi => |operands| {
                    const lhs = integer(slots, operands.lhs);
                    const rhs = integer(slots, operands.rhs);
                    if (rhs == 0) return unsupported(.division_by_zero, instruction_index);
                    if (lhs == std.math.minInt(i32) and rhs == -1) return unsupported(.integer_overflow, instruction_index);
                    slots[destination] = .{ .int = @divTrunc(lhs, rhs) };
                },
                .exit => |operand| return .{ .exit = integer(slots, operand) },
                .call => |call| if (try executeReturningCall(body, slots, call_scratch, destination, instruction_index, call.instance(), call.arguments, executor, &aggregate_fuel)) |result| return result,
                .indirect_call => |call| {
                    const reference = slots[@intFromEnum(call.target)].function_ref;
                    if (try executeReturningCall(body, slots, call_scratch, destination, instruction_index, .{ .item = reference.target }, call.arguments, executor, &aggregate_fuel)) |result| return result;
                },
                .variant_tag => |operand| switch (try variantTag(body, slots[@intFromEnum(operand)], operand, executor)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atInstruction(result, instruction_index),
                },
                .variant_coerce => |operation| switch (try coerceVariant(body, slots[@intFromEnum(operation.operand)], operation, executor, &aggregate_fuel)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atInstruction(result, instruction_index),
                },
                .variant_extract => |operation| switch (try extractVariant(body, slots[@intFromEnum(operation.operand)], operation, executor, &aggregate_fuel)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atInstruction(result, instruction_index),
                },
                .struct_init => |operation| switch (try initializeStruct(body, slots, operation, executor, gpa, &aggregate_fuel)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atInstruction(result, instruction_index),
                },
                .field_access => |operation| switch (try accessField(slots[@intFromEnum(operation.operand)], operation, executor)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atInstruction(result, instruction_index),
                },
                .field_update => |operation| switch (try updateField(body, slots, operation, executor, gpa, &aggregate_fuel)) {
                    .returned => |value| slots[destination] = value,
                    else => |result| return atInstruction(result, instruction_index),
                },
                .mut_parameter_write => |operation| {
                    std.debug.assert(operation.parameter_index < arguments.len);
                    arguments[operation.parameter_index] = slots[@intFromEnum(operation.value)];
                    slots[destination] = .unit;
                },
                .call_mut_argument => |operation| {
                    const index = operation.arguments.start + operation.argument_index;
                    std.debug.assert(index < operation.arguments.end);
                    slots[destination] = call_scratch[index];
                },
            }
        }

        switch (block.terminator) {
            .branch => |branch| switch (try branchTarget(body, slots, scratch, branch, executor, &aggregate_fuel)) {
                .next => |next| block_id = next,
                .result => |result| return result,
            },
            .predicate_branch => |predicate| {
                const branch = if (predicateValue(slots, predicate.operation, predicate.operands))
                    predicate.then_branch
                else
                    predicate.else_branch;
                switch (try branchTarget(body, slots, scratch, branch, executor, &aggregate_fuel)) {
                    .next => |next| block_id = next,
                    .result => |result| return result,
                }
            },
            .return_unit => return .{ .returned = .unit },
            .return_value => |value_use| return valueUse(body, slots, value_use, executor, &aggregate_fuel),
            .return_failure => return .failure,
            .diverge => return .{ .unsupported = .{ .reason = .instruction } },
            .fallible_call => |fallible| switch (try executeFallibleCall(body, slots, call_scratch, fallible.call.instance(), fallible.call.arguments, fallible.success, fallible.failure, executor, &aggregate_fuel)) {
                .next => |next| block_id = next,
                .result => |result| return result,
            },
            .fallible_indirect_call => |fallible| {
                const reference = slots[@intFromEnum(fallible.call.target)].function_ref;
                switch (try executeFallibleCall(body, slots, call_scratch, .{ .item = reference.target }, fallible.call.arguments, fallible.success, fallible.failure, executor, &aggregate_fuel)) {
                    .next => |next| block_id = next,
                    .result => |result| return result,
                }
            },
        }
    }
}

fn unsupported(reason: UnsupportedReason, instruction_index: usize) Result {
    return .{ .unsupported = .{
        .reason = reason,
        .instruction_index = @intCast(instruction_index),
    } };
}

fn integer(slots: []const structures.CompileTimeValue.RuntimeValue, value: structures.FunctionValueId) i32 {
    return slots[@intFromEnum(value)].int;
}

fn predicateValue(
    slots: []const structures.CompileTimeValue.RuntimeValue,
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
        .eqb => slots[@intFromEnum(operands.lhs)].bool == slots[@intFromEnum(operands.rhs)].bool,
        .neb => slots[@intFromEnum(operands.lhs)].bool != slots[@intFromEnum(operands.rhs)].bool,
    };
}

fn executeCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const structures.CompileTimeValue.RuntimeValue,
    scratch: []structures.CompileTimeValue.RuntimeValue,
    instance: structures.InstanceId,
    argument_range: structures.FunctionValueRange,
    executor: anytype,
    aggregate_fuel: *u32,
) !Result {
    const arguments = body.call_arguments[argument_range.start..argument_range.end];
    const interpreted = scratch[argument_range.start..argument_range.end];
    for (arguments, interpreted) |argument, *destination| {
        switch (try valueUse(body, slots, argument, executor, aggregate_fuel)) {
            .returned => |value| destination.* = value,
            else => |result| return result,
        }
    }
    return executor.call(instance, interpreted);
}

fn executeReturningCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []structures.CompileTimeValue.RuntimeValue,
    scratch: []structures.CompileTimeValue.RuntimeValue,
    destination: usize,
    instruction_index: usize,
    instance: structures.InstanceId,
    argument_range: structures.FunctionValueRange,
    executor: anytype,
    aggregate_fuel: *u32,
) !?Result {
    return switch (atInstruction(
        try executeCall(body, slots, scratch, instance, argument_range, executor, aggregate_fuel),
        instruction_index,
    )) {
        .returned => |value| blk: {
            slots[destination] = value;
            break :blk null;
        },
        .failure => unsupported(.instruction, instruction_index),
        .exit => |status| .{ .exit = status },
        .unsupported => |value| .{ .unsupported = value },
        .unavailable => .unavailable,
    };
}

const FallibleCallStep = union(enum) {
    next: structures.FunctionBlockId,
    result: Result,
};

fn executeFallibleCall(
    body: *const structures.FunctionBodyAnalysis,
    slots: []structures.CompileTimeValue.RuntimeValue,
    scratch: []structures.CompileTimeValue.RuntimeValue,
    instance: structures.InstanceId,
    argument_range: structures.FunctionValueRange,
    success_id: structures.FunctionBlockId,
    failure_id: structures.FunctionBlockId,
    executor: anytype,
    aggregate_fuel: *u32,
) !FallibleCallStep {
    return switch (try executeCall(body, slots, scratch, instance, argument_range, executor, aggregate_fuel)) {
        .returned => |value| blk: {
            const success = body.blocks[@intFromEnum(success_id)];
            std.debug.assert(success.argument_end - success.argument_start == 1);
            slots[success.argument_start] = value;
            break :blk .{ .next = success_id };
        },
        .failure => .{ .next = failure_id },
        .exit => |status| .{ .result = .{ .exit = status } },
        .unsupported => |value| .{ .result = .{ .unsupported = value } },
        .unavailable => .{ .result = .unavailable },
    };
}

fn valueType(body: *const structures.FunctionBodyAnalysis, value: structures.FunctionValueId) structures.TypeId {
    const index = @intFromEnum(value);
    if (index < body.block_argument_types.len) return body.block_argument_types[index];
    return body.instructions[index - body.block_argument_types.len].resultType();
}

fn chargeAggregate(fuel: *u32, amount: usize) bool {
    const charged = std.math.cast(u32, amount) orelse return false;
    if (fuel.* < charged) return false;
    fuel.* -= charged;
    return true;
}

fn initializeStruct(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const structures.CompileTimeValue.RuntimeValue,
    operation: structures.StructOperation,
    executor: anytype,
    gpa: std.mem.Allocator,
    aggregate_fuel: *u32,
) !Result {
    const fields = body.struct_field_values[operation.fields.start..operation.fields.end];
    if (!chargeAggregate(aggregate_fuel, fields.len + 1)) return .{ .unsupported = .{ .reason = .resource_limit } };
    const values = try gpa.alloc(structures.CompileTimeValueId, fields.len);
    defer gpa.free(values);
    for (fields) |field| {
        std.debug.assert(field.field_index < values.len);
        values[field.field_index] = try executor.internRuntime(valueType(body, field.value), slots[@intFromEnum(field.value)]);
    }
    return .{ .returned = .{ .structure = try executor.internTuple(values) } };
}

fn accessField(
    value: structures.CompileTimeValue.RuntimeValue,
    operation: structures.FieldAccessOperation,
    executor: anytype,
) !Result {
    const fields = try executor.lookupTuple(value.structure);
    std.debug.assert(operation.field_index < fields.len);
    const field = (try executor.lookupRuntime(fields[operation.field_index])) orelse return .unavailable;
    std.debug.assert(field.type_id == operation.field_type);
    return .{ .returned = field.value };
}

fn updateField(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const structures.CompileTimeValue.RuntimeValue,
    operation: structures.FieldUpdateOperation,
    executor: anytype,
    gpa: std.mem.Allocator,
    aggregate_fuel: *u32,
) !Result {
    const source = try executor.lookupTuple(slots[@intFromEnum(operation.operand)].structure);
    if (!chargeAggregate(aggregate_fuel, source.len + 1)) return .{ .unsupported = .{ .reason = .resource_limit } };
    const fields = try gpa.dupe(structures.CompileTimeValueId, source);
    defer gpa.free(fields);
    std.debug.assert(operation.field_index < fields.len);
    fields[operation.field_index] = try executor.internRuntime(valueType(body, operation.value), slots[@intFromEnum(operation.value)]);
    return .{ .returned = .{ .structure = try executor.internTuple(fields) } };
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
) !?ActiveVariant {
    if (value == .variant) return .{ .member_type = value.variant.member_type, .payload = value.variant.payload };
    const source_type = valueType(body, operand);
    const representation_type = value.scalarTypeId() orelse return null;
    const members = (try executor.variantMembers(source_type)) orelse return null;
    const member_type = for (members) |member| {
        if (member == representation_type) break member;
    } else for (members) |member| {
        if (try executor.canWidenTo(representation_type, member)) break member;
    } else return null;
    return .{ .member_type = member_type, .payload = try executor.internRuntime(representation_type, value) };
}

fn variantTag(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operand: structures.FunctionValueId,
    executor: anytype,
) !Result {
    const active = (try activeVariant(body, value, operand, executor)) orelse return .{ .unsupported = .{ .reason = .coercion } };
    const members = (try executor.variantMembers(valueType(body, operand))) orelse return .{ .unsupported = .{ .reason = .coercion } };
    for (members, 0..) |member, tag| if (member == active.member_type) return .{ .returned = .{ .int = @intCast(tag) } };
    return .{ .unsupported = .{ .reason = .coercion } };
}

fn variantValue(member_type: structures.TypeId, payload: structures.CompileTimeValueId, executor: anytype) !?structures.CompileTimeValue.RuntimeValue {
    const runtime = (try executor.lookupRuntime(payload)) orelse return null;
    if (runtime.type_id == member_type and runtime.value.scalarTypeId() != null) return runtime.value;
    return .{ .variant = .{ .member_type = member_type, .payload = payload } };
}

fn coerceVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operation: structures.VariantOperation,
    executor: anytype,
    aggregate_fuel: *u32,
) !Result {
    const mapping = body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
    const source_type = valueType(body, operation.operand);
    const source_members = try executor.variantMembers(source_type);
    var payload: structures.CompileTimeValueId = undefined;
    const source_tag: usize = if (source_members) |members| blk: {
        const active = (try activeVariant(body, value, operation.operand, executor)) orelse return .{ .unsupported = .{ .reason = .coercion } };
        payload = active.payload;
        break :blk for (members, 0..) |member, tag| {
            if (member == active.member_type) break tag;
        } else return .{ .unsupported = .{ .reason = .coercion } };
    } else blk: {
        payload = try executor.internRuntime(source_type, value);
        break :blk 0;
    };
    std.debug.assert(source_tag < mapping.len);
    const target_tag = mapping[source_tag];
    if (target_tag == structures.invalid_variant_tag) return .{ .unsupported = .{ .reason = .coercion } };
    const target_members = (try executor.variantMembers(operation.target_type)) orelse return .{ .unsupported = .{ .reason = .coercion } };
    std.debug.assert(target_tag < target_members.len);
    if (!chargeAggregate(aggregate_fuel, 1)) return .{ .unsupported = .{ .reason = .resource_limit } };
    return .{ .returned = (try variantValue(target_members[target_tag], payload, executor)) orelse return .unavailable };
}

fn extractVariant(
    body: *const structures.FunctionBodyAnalysis,
    value: structures.CompileTimeValue.RuntimeValue,
    operation: structures.VariantOperation,
    executor: anytype,
    aggregate_fuel: *u32,
) !Result {
    const active = (try activeVariant(body, value, operation.operand, executor)) orelse return .{ .unsupported = .{ .reason = .coercion } };
    if (try executor.variantMembers(operation.target_type)) |target_members| {
        const source_members = (try executor.variantMembers(valueType(body, operation.operand))).?;
        const source_tag = for (source_members, 0..) |member, tag| {
            if (member == active.member_type) break tag;
        } else return .{ .unsupported = .{ .reason = .coercion } };
        const mapping = body.variant_coercion_tags[operation.tag_mapping.?.start..operation.tag_mapping.?.end];
        const target_tag = mapping[source_tag];
        if (target_tag == structures.invalid_variant_tag) return .{ .unsupported = .{ .reason = .coercion } };
        std.debug.assert(target_tag < target_members.len);
        if (!chargeAggregate(aggregate_fuel, 1)) return .{ .unsupported = .{ .reason = .resource_limit } };
        return .{ .returned = (try variantValue(target_members[target_tag], active.payload, executor)) orelse return .unavailable };
    }
    const payload = (try executor.lookupRuntime(active.payload)) orelse return .unavailable;
    if (payload.type_id == operation.target_type) return .{ .returned = payload.value };
    var reference = payload.value.function_ref;
    reference.type_id = operation.target_type;
    return .{ .returned = .{ .function_ref = reference } };
}

fn atInstruction(result: Result, instruction_index: usize) Result {
    return switch (result) {
        .unsupported => |value| if (value.instruction_index == null)
            unsupported(value.reason, instruction_index)
        else
            result,
        else => result,
    };
}

fn valueUse(
    body: *const structures.FunctionBodyAnalysis,
    slots: []const structures.CompileTimeValue.RuntimeValue,
    use: structures.FunctionValueUse,
    executor: anytype,
    aggregate_fuel: *u32,
) !Result {
    const value = slots[@intFromEnum(use.value)];
    const target = use.coerce_to orelse return .{ .returned = value };
    if (use.variant_tag_mapping) |mapping| return coerceVariant(body, value, .{
        .operand = use.value,
        .target_type = target,
        .tag_mapping = mapping,
    }, executor, aggregate_fuel);
    var reference = value.function_ref;
    reference.type_id = target;
    return .{ .returned = .{ .function_ref = reference } };
}

const BranchStep = union(enum) {
    next: structures.FunctionBlockId,
    result: Result,
};

fn branchTarget(
    body: *const structures.FunctionBodyAnalysis,
    slots: []structures.CompileTimeValue.RuntimeValue,
    scratch: []structures.CompileTimeValue.RuntimeValue,
    branch: structures.FunctionBranch,
    executor: anytype,
    aggregate_fuel: *u32,
) !BranchStep {
    const target = body.blocks[@intFromEnum(branch.target)];
    const arguments = body.branch_arguments[branch.arguments.start..branch.arguments.end];
    std.debug.assert(arguments.len == target.argument_end - target.argument_start);
    for (arguments, scratch[0..arguments.len]) |argument, *temporary| {
        switch (try valueUse(body, slots, argument, executor, aggregate_fuel)) {
            .returned => |value| temporary.* = value,
            else => |result| return .{ .result = result },
        }
    }
    @memcpy(slots[target.argument_start..target.argument_end], scratch[0..arguments.len]);
    return .{ .next = branch.target };
}
