const std = @import("std");
const structures = @import("structures.zig");

pub const UnsupportedReason = enum {
    instruction,
    coercion,
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
};

const default_block_fuel: u32 = 1_000_000;

/// Execute the scalar subset of a typed zero-parameter body. Slots are dense
/// and frame-local; values are interned only by the query that receives the
/// final outcome.
pub fn execute(
    body: *const structures.FunctionBodyAnalysis,
    gpa: std.mem.Allocator,
) !Result {
    const slots = try gpa.alloc(structures.CompileTimeValue.RuntimeValue, body.valueCount());
    defer gpa.free(slots);
    @memset(slots, .unit);

    const scratch = try gpa.alloc(structures.CompileTimeValue.RuntimeValue, body.block_argument_types.len);
    defer gpa.free(scratch);

    var block_id = body.entry;
    var fuel = default_block_fuel;
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
                .variant_tag,
                .variant_coerce,
                .variant_extract,
                .callable_coerce,
                .struct_init,
                .field_access,
                .field_update,
                .mut_parameter_write,
                .call_mut_argument,
                .call,
                .indirect_call,
                => return unsupported(.instruction, instruction_index),
            }
        }

        switch (block.terminator) {
            .branch => |branch| block_id = branchTarget(body, slots, scratch, branch) orelse
                return .{ .unsupported = .{ .reason = .coercion } },
            .predicate_branch => |predicate| {
                const branch = if (predicateValue(slots, predicate.operation, predicate.operands))
                    predicate.then_branch
                else
                    predicate.else_branch;
                block_id = branchTarget(body, slots, scratch, branch) orelse
                    return .{ .unsupported = .{ .reason = .coercion } };
            },
            .return_unit => return .{ .returned = .unit },
            .return_value => |value_use| {
                if (value_use.coerce_to != null or value_use.variant_tag_mapping != null) {
                    return .{ .unsupported = .{ .reason = .coercion } };
                }
                return .{ .returned = slots[@intFromEnum(value_use.value)] };
            },
            .return_failure => return .failure,
            .diverge => return .{ .unsupported = .{ .reason = .instruction } },
            .fallible_call, .fallible_indirect_call => return .{ .unsupported = .{ .reason = .instruction } },
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

fn branchTarget(
    body: *const structures.FunctionBodyAnalysis,
    slots: []structures.CompileTimeValue.RuntimeValue,
    scratch: []structures.CompileTimeValue.RuntimeValue,
    branch: structures.FunctionBranch,
) ?structures.FunctionBlockId {
    const target = body.blocks[@intFromEnum(branch.target)];
    const arguments = body.branch_arguments[branch.arguments.start..branch.arguments.end];
    if (arguments.len != target.argument_end - target.argument_start) return null;
    for (arguments, scratch[0..arguments.len]) |argument, *temporary| {
        if (argument.coerce_to != null or argument.variant_tag_mapping != null) return null;
        temporary.* = slots[@intFromEnum(argument.value)];
    }
    @memcpy(slots[target.argument_start..target.argument_end], scratch[0..arguments.len]);
    return branch.target;
}
