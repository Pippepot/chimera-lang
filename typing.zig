const std = @import("std");
const structures = @import("structures.zig");
const semantic = @import("semantic.zig");

// Specialized body-typing logic behind the AnalyzeFunctionBody publication
// boundary. Query definitions live in query_structures.zig and delegate here;
// this module owns how unresolved bodies become typed instructions. The query
// types it demands arrive as comptime parameters so typing stays decoupled
// from the query catalogue while ctx.get keeps recording real dependencies.

pub fn emitSemanticIssue(ctx: anytype, file_id: structures.FileId, issue: semantic.Issue) !void {
    try ctx.emit(structures.Diagnostic, .{
        .file_id = file_id,
        .span = issue.span,
        .message = issue.message,
    });
}

pub fn resolveAndTypeBody(
    ctx: anytype,
    comptime ModuleScopeQuery: type,
    comptime FunctionSignatureQuery: type,
    file_id: structures.FileId,
    source: []const u8,
    parameter_types: []const structures.Type,
    return_type: structures.Type,
    unresolved: semantic.UnresolvedBody,
) !?structures.FunctionBodyAnalysis {
    const instructions = try ctx.allocator().alloc(structures.FunctionBodyAnalysis.Instruction, unresolved.instructions.len);
    var owns_instructions = true;
    defer if (owns_instructions) ctx.allocator().free(instructions);

    const block_argument_types = try ctx.allocator().alloc(structures.Type, unresolved.block_argument_count);
    var owns_block_arguments = true;
    defer if (owns_block_arguments) ctx.allocator().free(block_argument_types);
    @memcpy(block_argument_types[0..parameter_types.len], parameter_types);

    const branch_arguments = try resolveValues(ctx.allocator(), unresolved.branch_arguments, unresolved.block_argument_count);
    var owns_branch_arguments = true;
    defer if (owns_branch_arguments) ctx.allocator().free(branch_arguments);

    const call_arguments = try resolveValues(ctx.allocator(), unresolved.call_arguments, unresolved.block_argument_count);
    var owns_call_arguments = true;
    defer if (owns_call_arguments) ctx.allocator().free(call_arguments);

    const value_types = try ctx.allocator().alloc(structures.Type, unresolved.block_argument_count + unresolved.instructions.len);
    defer ctx.allocator().free(value_types);
    @memcpy(value_types[0..parameter_types.len], parameter_types);
    const known_types = try ctx.allocator().alloc(bool, value_types.len);
    defer ctx.allocator().free(known_types);
    @memset(known_types, false);
    @memset(known_types[0..parameter_types.len], true);

    var scope: ?structures.ModuleScope = null;
    var join_index: usize = 0;
    var expectation_index: usize = 0;
    if (!try resolveConstraints(ctx, file_id, unresolved, value_types, known_types, block_argument_types, 0, &join_index, &expectation_index)) return null;
    for (unresolved.instructions, instructions, 0..) |instruction, *resolved, instruction_index| {
        const instruction_type: structures.Type = switch (instruction.operation) {
            .consti => |value| blk: {
                resolved.* = .{ .consti = value };
                break :blk .int;
            },
            .call => |call| blk: {
                break :blk try resolveAndTypeCall(
                    ctx,
                    ModuleScopeQuery,
                    FunctionSignatureQuery,
                    file_id,
                    source,
                    unresolved,
                    value_types,
                    known_types,
                    call_arguments,
                    call,
                    &scope,
                    resolved,
                ) orelse return null;
            },
            .negi => |operand| blk: {
                const resolved_operand = resolveValue(operand, unresolved.block_argument_count);
                const operand_index = @intFromEnum(resolved_operand);
                std.debug.assert(known_types[operand_index]);
                if (value_types[operand_index] != .int) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = instruction.span, .message = "integer negation requires an int operand" });
                    return null;
                }
                resolved.* = .{ .negi = resolved_operand };
                break :blk .int;
            },
            .addi, .subi, .muli, .divsi => |operands| blk: {
                const resolved_operands = resolveOperands(operands, unresolved.block_argument_count);
                const lhs_index = @intFromEnum(resolved_operands.lhs);
                const rhs_index = @intFromEnum(resolved_operands.rhs);
                std.debug.assert(known_types[lhs_index]);
                std.debug.assert(known_types[rhs_index]);
                if (value_types[lhs_index] != .int or value_types[rhs_index] != .int) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = instruction.span, .message = "integer operation requires int operands" });
                    return null;
                }
                resolved.* = switch (instruction.operation) {
                    .addi => .{ .addi = resolved_operands },
                    .subi => .{ .subi = resolved_operands },
                    .muli => .{ .muli = resolved_operands },
                    .divsi => .{ .divsi = resolved_operands },
                    else => unreachable,
                };
                break :blk .int;
            },
        };
        const value_index = unresolved.block_argument_count + instruction_index;
        value_types[value_index] = instruction_type;
        known_types[value_index] = true;
        const completed_instruction_count = instruction_index + 1;
        if (!try resolveConstraints(ctx, file_id, unresolved, value_types, known_types, block_argument_types, completed_instruction_count, &join_index, &expectation_index)) return null;
    }
    std.debug.assert(join_index == unresolved.joins.len);
    std.debug.assert(expectation_index == unresolved.type_expectations.len);

    const blocks = try ctx.allocator().alloc(structures.FunctionBodyAnalysis.Block, unresolved.blocks.len);
    var owns_blocks = true;
    defer if (owns_blocks) ctx.allocator().free(blocks);
    for (unresolved.blocks, blocks) |block, *resolved| {
        const unresolved_terminator = block.terminator orelse unreachable;
        const terminator: structures.FunctionBodyAnalysis.Terminator = switch (unresolved_terminator) {
            .branch => |branch| .{ .branch = resolveBranch(branch) },
            .predicate_branch => |predicate| blk: {
                const operands = resolveOperands(predicate.operands, unresolved.block_argument_count);
                const lhs_index = @intFromEnum(operands.lhs);
                const rhs_index = @intFromEnum(operands.rhs);
                std.debug.assert(known_types[lhs_index]);
                std.debug.assert(known_types[rhs_index]);
                if (value_types[lhs_index] != .int or value_types[rhs_index] != .int) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = predicate.span, .message = "fallible comparison requires int operands" });
                    return null;
                }
                break :blk .{ .predicate_branch = .{
                    .operation = switch (predicate.operation) {
                        .lt => .lti,
                        .gt => .gti,
                        .le => .lei,
                        .ge => .gei,
                        .eq => .eqi,
                        .ne => .nei,
                    },
                    .operands = operands,
                    .then_branch = resolveBranch(predicate.then_branch),
                    .else_branch = resolveBranch(predicate.else_branch),
                } };
            },
            .return_unit => |span| if (return_type == .unit)
                .return_unit
            else {
                try emitSemanticIssue(ctx, file_id, .{ .span = span, .message = "function returning int must return a value" });
                return null;
            },
            .return_value => |return_value| blk: {
                const value = resolveValue(return_value.value, unresolved.block_argument_count);
                const value_index = @intFromEnum(value);
                std.debug.assert(known_types[value_index]);
                if (value_types[value_index] != return_type) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = return_value.span, .message = "return type does not match function signature" });
                    return null;
                }
                break :blk if (return_type == .unit) .return_unit else .{ .return_value = value };
            },
        };
        resolved.* = .{
            .argument_start = block.argument_start,
            .argument_end = block.argument_end,
            .instruction_start = block.instruction_start,
            .instruction_end = block.instruction_end,
            .terminator = terminator,
        };
    }
    validateEdges(blocks, block_argument_types, branch_arguments, value_types);
    owns_instructions = false;
    owns_block_arguments = false;
    owns_branch_arguments = false;
    owns_call_arguments = false;
    owns_blocks = false;
    return .{
        .block_argument_types = block_argument_types,
        .branch_arguments = branch_arguments,
        .call_arguments = call_arguments,
        .instructions = instructions,
        .blocks = blocks,
        .entry = @enumFromInt(0),
    };
}

fn resolveConstraints(
    ctx: anytype,
    file_id: structures.FileId,
    unresolved: semantic.UnresolvedBody,
    value_types: []structures.Type,
    known_types: []bool,
    block_argument_types: []structures.Type,
    instruction_count: usize,
    join_index: *usize,
    expectation_index: *usize,
) !bool {
    while (join_index.* < unresolved.joins.len and unresolved.joins[join_index.*].instruction_count == instruction_count) : (join_index.* += 1) {
        const join = unresolved.joins[join_index.*];
        const lhs_index = @intFromEnum(resolveValue(join.incoming[0], unresolved.block_argument_count));
        const rhs_index = @intFromEnum(resolveValue(join.incoming[1], unresolved.block_argument_count));
        std.debug.assert(known_types[lhs_index]);
        std.debug.assert(known_types[rhs_index]);
        if (value_types[lhs_index] != value_types[rhs_index]) {
            try emitSemanticIssue(ctx, file_id, .{ .span = join.span, .message = "if branches must have the same type" });
            return false;
        }
        std.debug.assert(join.argument < block_argument_types.len);
        std.debug.assert(!known_types[join.argument]);
        block_argument_types[join.argument] = value_types[lhs_index];
        value_types[join.argument] = value_types[lhs_index];
        known_types[join.argument] = true;
    }
    while (expectation_index.* < unresolved.type_expectations.len and unresolved.type_expectations[expectation_index.*].instruction_count == instruction_count) : (expectation_index.* += 1) {
        if (!try validateTypeExpectation(ctx, file_id, unresolved.type_expectations[expectation_index.*], value_types, known_types, unresolved.block_argument_count)) return false;
    }
    return true;
}

fn resolveValues(
    gpa: std.mem.Allocator,
    values: []const semantic.UnresolvedBody.ValueId,
    block_argument_count: u32,
) ![]structures.FunctionValueId {
    const resolved = try gpa.alloc(structures.FunctionValueId, values.len);
    for (values, resolved) |value, *result| result.* = resolveValue(value, block_argument_count);
    return resolved;
}

fn resolveValue(value: semantic.UnresolvedBody.ValueId, block_argument_count: u32) structures.FunctionValueId {
    return switch (value) {
        .block_argument => |index| @enumFromInt(index),
        .instruction => |index| structures.functionInstructionValue(block_argument_count, index),
    };
}

fn resolveOperands(operands: semantic.UnresolvedBody.BinaryOperands, block_argument_count: u32) structures.BinaryOperands {
    return .{
        .lhs = resolveValue(operands.lhs, block_argument_count),
        .rhs = resolveValue(operands.rhs, block_argument_count),
    };
}

fn resolveBranch(branch: semantic.UnresolvedBody.Branch) structures.FunctionBranch {
    return .{ .target = branch.target, .arguments = branch.arguments };
}

fn validateEdges(
    blocks: []const structures.FunctionBodyAnalysis.Block,
    block_argument_types: []const structures.Type,
    branch_arguments: []const structures.FunctionValueId,
    value_types: []const structures.Type,
) void {
    for (blocks) |block| switch (block.terminator) {
        .branch => |branch| validateEdge(blocks, block_argument_types, branch_arguments, value_types, branch),
        .predicate_branch => |branch| {
            validateEdge(blocks, block_argument_types, branch_arguments, value_types, branch.then_branch);
            validateEdge(blocks, block_argument_types, branch_arguments, value_types, branch.else_branch);
        },
        .return_unit, .return_value => {},
    };
}

fn validateEdge(
    blocks: []const structures.FunctionBodyAnalysis.Block,
    block_argument_types: []const structures.Type,
    branch_arguments: []const structures.FunctionValueId,
    value_types: []const structures.Type,
    branch: structures.FunctionBranch,
) void {
    const target_index = @intFromEnum(branch.target);
    std.debug.assert(target_index < blocks.len);
    const target = blocks[target_index];
    std.debug.assert(target.argument_start <= target.argument_end);
    std.debug.assert(target.argument_end <= block_argument_types.len);
    std.debug.assert(branch.arguments.start <= branch.arguments.end);
    std.debug.assert(branch.arguments.end <= branch_arguments.len);
    const arguments = branch_arguments[branch.arguments.start..branch.arguments.end];
    const parameters = block_argument_types[target.argument_start..target.argument_end];
    std.debug.assert(arguments.len == parameters.len);
    for (arguments, parameters) |argument, parameter_type| {
        const value_index = @intFromEnum(argument);
        std.debug.assert(value_index < value_types.len);
        std.debug.assert(value_types[value_index] == parameter_type);
    }
}

fn resolveAndTypeCall(
    ctx: anytype,
    comptime ModuleScopeQuery: type,
    comptime FunctionSignatureQuery: type,
    file_id: structures.FileId,
    source: []const u8,
    unresolved: semantic.UnresolvedBody,
    value_types: []const structures.Type,
    known_types: []const bool,
    call_arguments: []const structures.FunctionValueId,
    call: anytype,
    scope: *?structures.ModuleScope,
    resolved: *structures.FunctionBodyAnalysis.Instruction,
) !?structures.Type {
    const name_span = call.target;
    const name = source[name_span.start..name_span.end];
    const Callee = union(enum) {
        exit,
        function: struct {
            target: structures.ItemId,
            signature: structures.FunctionSignature,
        },
    };
    const callee: Callee = if (std.mem.eql(u8, name, "exit"))
        .exit
    else blk: {
        if (scope.* == null) scope.* = (try ctx.get(ModuleScopeQuery, file_id)).* orelse return null;
        const target = scope.*.?.resolve(name) orelse {
            try emitSemanticIssue(ctx, file_id, .{ .span = name_span, .message = "unknown function" });
            return null;
        };
        const signature = (try ctx.get(FunctionSignatureQuery, target)).* orelse return null;
        break :blk .{ .function = .{ .target = target, .signature = signature } };
    };

    std.debug.assert(call.arguments.start <= call.arguments.end);
    std.debug.assert(call.arguments.end <= unresolved.call_arguments.len);
    const arguments = call_arguments[call.arguments.start..call.arguments.end];
    const parameter_types: []const structures.Type = switch (callee) {
        .exit => &.{.int},
        .function => |function| function.signature.parameter_types,
    };
    if (arguments.len != parameter_types.len) {
        try emitSemanticIssue(ctx, file_id, .{ .span = name_span, .message = "call argument count does not match function signature" });
        return null;
    }
    for (arguments, parameter_types, 0..) |argument, expected_type, argument_offset| {
        const argument_index = @intFromEnum(argument);
        std.debug.assert(known_types[argument_index]);
        if (value_types[argument_index] != expected_type) {
            try emitSemanticIssue(ctx, file_id, .{
                .span = argumentSpan(unresolved.instructions, unresolved.call_arguments[call.arguments.start + argument_offset], name_span),
                .message = "call argument type does not match function signature",
            });
            return null;
        }
    }

    return switch (callee) {
        .exit => blk: {
            resolved.* = .{ .exit = arguments[0] };
            break :blk .unit;
        },
        .function => |function| blk: {
            resolved.* = .{ .call = .{
                .target = function.target,
                .arguments = call.arguments,
                .return_type = function.signature.return_type,
            } };
            break :blk function.signature.return_type;
        },
    };
}

fn validateTypeExpectation(
    ctx: anytype,
    file_id: structures.FileId,
    expectation: semantic.UnresolvedBody.TypeExpectation,
    value_types: []const structures.Type,
    known_types: []const bool,
    block_argument_count: u32,
) !bool {
    const value_index = @intFromEnum(resolveValue(expectation.value, block_argument_count));
    std.debug.assert(known_types[value_index]);
    if (value_types[value_index] == expectation.expected) return true;
    try emitSemanticIssue(ctx, file_id, .{ .span = expectation.span, .message = "local binding type does not match initializer" });
    return false;
}

fn argumentSpan(
    instructions: []const semantic.UnresolvedBody.Instruction,
    value: semantic.UnresolvedBody.ValueId,
    call_site_span: structures.SourceSpan,
) structures.SourceSpan {
    return switch (value) {
        .instruction => |instruction_index| instructions[instruction_index].span,
        .block_argument => call_site_span,
    };
}
