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

    const block_argument_types = try ctx.allocator().dupe(structures.Type, parameter_types);
    var owns_block_arguments = true;
    defer if (owns_block_arguments) ctx.allocator().free(block_argument_types);

    const call_arguments = try ctx.allocator().dupe(structures.FunctionValueId, unresolved.call_arguments);
    var owns_call_arguments = true;
    defer if (owns_call_arguments) ctx.allocator().free(call_arguments);

    const value_types = try ctx.allocator().alloc(structures.Type, parameter_types.len + unresolved.instructions.len);
    defer ctx.allocator().free(value_types);
    @memcpy(value_types[0..parameter_types.len], parameter_types);

    var scope: ?structures.ModuleScope = null;
    // Bindings record expectations in source order during unresolved
    // construction, so one forward pass merged against completed instructions
    // validates them all.
    var expectation_index: usize = 0;
    while (expectation_index < unresolved.type_expectations.len and unresolved.type_expectations[expectation_index].instruction_count == 0) : (expectation_index += 1) {
        if (!try validateTypeExpectation(ctx, file_id, unresolved.type_expectations[expectation_index], value_types, parameter_types.len)) return null;
    }
    for (unresolved.instructions, instructions, 0..) |instruction, *resolved, instruction_index| {
        const instruction_type: structures.Type = switch (instruction.operation) {
            .consti => |value| blk: {
                resolved.* = .{ .consti = value };
                break :blk .int;
            },
            .call => |call| blk: {
                const name_span = call.target;
                if (scope == null) scope = (try ctx.get(ModuleScopeQuery, file_id)).* orelse return null;
                const target = scope.?.resolve(source[name_span.start..name_span.end]) orelse {
                    try emitSemanticIssue(ctx, file_id, .{ .span = name_span, .message = "unknown function" });
                    return null;
                };
                const callee_signature = (try ctx.get(FunctionSignatureQuery, target)).* orelse return null;
                std.debug.assert(call.arguments.start <= call.arguments.end);
                std.debug.assert(call.arguments.end <= unresolved.call_arguments.len);
                const arguments = unresolved.call_arguments[call.arguments.start..call.arguments.end];
                if (arguments.len != callee_signature.parameter_types.len) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = name_span, .message = "call argument count does not match function signature" });
                    return null;
                }
                for (arguments, callee_signature.parameter_types) |argument, expected_type| {
                    const argument_index = @intFromEnum(argument);
                    std.debug.assert(argument_index < parameter_types.len + instruction_index);
                    if (value_types[argument_index] != expected_type) {
                        try emitSemanticIssue(ctx, file_id, .{
                            .span = argumentSpan(unresolved.instructions, parameter_types.len, argument, name_span),
                            .message = "call argument type does not match function signature",
                        });
                        return null;
                    }
                }
                resolved.* = .{ .call = .{
                    .target = target,
                    .arguments = call.arguments,
                    .return_type = callee_signature.return_type,
                } };
                break :blk callee_signature.return_type;
            },
            .negi => |operand| blk: {
                const operand_index = @intFromEnum(operand);
                std.debug.assert(operand_index < parameter_types.len + instruction_index);
                if (value_types[operand_index] != .int) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = instruction.span, .message = "integer negation requires an int operand" });
                    return null;
                }
                resolved.* = .{ .negi = operand };
                break :blk .int;
            },
            .addi, .subi, .muli, .divsi => |operands| blk: {
                const lhs_index = @intFromEnum(operands.lhs);
                const rhs_index = @intFromEnum(operands.rhs);
                std.debug.assert(lhs_index < parameter_types.len + instruction_index);
                std.debug.assert(rhs_index < parameter_types.len + instruction_index);
                if (value_types[lhs_index] != .int or value_types[rhs_index] != .int) {
                    try emitSemanticIssue(ctx, file_id, .{ .span = instruction.span, .message = "integer operation requires int operands" });
                    return null;
                }
                resolved.* = switch (instruction.operation) {
                    .addi => .{ .addi = operands },
                    .subi => .{ .subi = operands },
                    .muli => .{ .muli = operands },
                    .divsi => .{ .divsi = operands },
                    else => unreachable,
                };
                break :blk .int;
            },
        };
        value_types[parameter_types.len + instruction_index] = instruction_type;
        const completed_instruction_count = instruction_index + 1;
        while (expectation_index < unresolved.type_expectations.len and unresolved.type_expectations[expectation_index].instruction_count == completed_instruction_count) : (expectation_index += 1) {
            if (!try validateTypeExpectation(ctx, file_id, unresolved.type_expectations[expectation_index], value_types, parameter_types.len + completed_instruction_count)) return null;
        }
    }
    std.debug.assert(expectation_index == unresolved.type_expectations.len);

    const terminator: structures.FunctionBodyAnalysis.Terminator = switch (unresolved.block.terminator) {
        .return_unit => if (return_type == .unit)
            .return_unit
        else {
            try emitSemanticIssue(ctx, file_id, .{ .span = unresolved.block.return_span, .message = "function returning int must return a value" });
            return null;
        },
        .return_value => |value| blk: {
            const value_index = @intFromEnum(value);
            std.debug.assert(value_index < value_types.len);
            if (value_types[value_index] != return_type) {
                try emitSemanticIssue(ctx, file_id, .{ .span = unresolved.block.return_span, .message = "return type does not match function signature" });
                return null;
            }
            break :blk if (return_type == .unit) .return_unit else .{ .return_value = value };
        },
    };
    const blocks = try ctx.allocator().alloc(structures.FunctionBodyAnalysis.Block, 1);
    blocks[0] = .{
        .argument_start = 0,
        .argument_end = @intCast(parameter_types.len),
        .instruction_start = 0,
        .instruction_end = @intCast(instructions.len),
        .terminator = terminator,
    };
    owns_instructions = false;
    owns_block_arguments = false;
    owns_call_arguments = false;
    return .{
        .block_argument_types = block_argument_types,
        .call_arguments = call_arguments,
        .instructions = instructions,
        .blocks = blocks,
        .entry = @enumFromInt(0),
    };
}

fn validateTypeExpectation(
    ctx: anytype,
    file_id: structures.FileId,
    expectation: semantic.UnresolvedBody.TypeExpectation,
    value_types: []const structures.Type,
    available_value_count: usize,
) !bool {
    const value_index = @intFromEnum(expectation.value);
    std.debug.assert(value_index < available_value_count);
    std.debug.assert(available_value_count <= value_types.len);
    if (value_types[value_index] == expectation.expected) return true;
    try emitSemanticIssue(ctx, file_id, .{ .span = expectation.span, .message = "local binding type does not match initializer" });
    return false;
}

fn argumentSpan(
    instructions: []const semantic.UnresolvedBody.Instruction,
    parameter_count: usize,
    value: structures.FunctionValueId,
    call_site_span: structures.SourceSpan,
) structures.SourceSpan {
    const value_index = @intFromEnum(value);
    // Parameters have no defining instruction, so point at their use site.
    if (value_index < parameter_count) return call_site_span;
    const instruction_index = value_index - parameter_count;
    std.debug.assert(instruction_index < instructions.len);
    return instructions[instruction_index].span;
}
