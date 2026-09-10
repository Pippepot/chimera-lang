const std = @import("std");
const structures = @import("structures.zig");
const semantic = @import("semantic.zig");

pub fn emitSemanticIssue(ctx: anytype, file_id: structures.FileId, issue: semantic.Issue) !void {
    try ctx.emit(structures.Diagnostic, .{ .file_id = file_id, .span = issue.span, .kind = issue.kind });
}

pub fn resolveAndTypeBody(
    ctx: anytype,
    comptime ModuleScopeQuery: type,
    comptime FunctionSignatureQuery: type,
    file_id: structures.FileId,
    parameter_types: []const structures.TypeId,
    return_type: structures.TypeId,
    type_interner: anytype,
    unresolved: semantic.UnresolvedBody,
) !?structures.FunctionBodyAnalysis {
    var builder: BodyBuilder(@TypeOf(ctx), ModuleScopeQuery, FunctionSignatureQuery, @TypeOf(type_interner)) = .{
        .ctx = ctx,
        .type_interner = type_interner,
        .file_id = file_id,
        .unresolved = unresolved,
        .return_type = return_type,
    };
    defer builder.deinit();
    try builder.init(parameter_types);
    builder.build() catch |err| switch (err) {
        error.SourceRejected, error.Unavailable => return null,
        else => return err,
    };
    return try builder.finish();
}

fn BodyBuilder(comptime Context: type, comptime ModuleScopeQuery: type, comptime FunctionSignatureQuery: type, comptime TypeInterner: type) type {
    return struct {
        const Self = @This();
        const Value = struct { id: structures.FunctionValueId, type_id: structures.TypeId };
        const Expression = semantic.UnresolvedBody.Expression;

        ctx: Context,
        type_interner: TypeInterner,
        file_id: structures.FileId,
        unresolved: semantic.UnresolvedBody,
        return_type: structures.TypeId,
        scope: ?structures.ModuleScope = null,
        values: []?Value = &.{},
        block_argument_types: std.ArrayList(structures.TypeId) = .empty,
        call_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        instructions: std.ArrayList(structures.FunctionInstruction) = .empty,
        blocks: std.ArrayList(structures.FunctionBlock) = .empty,
        current_block: ?structures.FunctionBlockId = null,

        fn init(self: *Self, parameter_types: []const structures.TypeId) !void {
            std.debug.assert(parameter_types.len == self.unresolved.parameter_count);
            self.values = try self.ctx.allocator().alloc(?Value, parameter_types.len + self.unresolved.expressions.len);
            @memset(self.values, null);
            for (parameter_types, 0..) |type_id, index| self.values[index] = .{ .id = @enumFromInt(index), .type_id = type_id };
            try self.block_argument_types.appendSlice(self.ctx.allocator(), parameter_types);
            const entry = try self.newBlock(0, @intCast(parameter_types.len));
            self.enterBlock(entry);
        }

        fn deinit(self: *Self) void {
            const gpa = self.ctx.allocator();
            gpa.free(self.values);
            self.block_argument_types.deinit(gpa);
            self.call_arguments.deinit(gpa);
            self.branch_arguments.deinit(gpa);
            self.instructions.deinit(gpa);
            self.blocks.deinit(gpa);
        }

        fn reject(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind) anyerror {
            try emitSemanticIssue(self.ctx, self.file_id, .{ .span = span, .kind = kind });
            return error.SourceRejected;
        }

        fn build(self: *Self) !void {
            _ = try self.block(self.unresolved.root_block);
            if (self.current_block == null) return;
            const root = self.unresolved.blocks[@intFromEnum(self.unresolved.root_block)];
            if (self.return_type == .unit) {
                self.terminate(.return_unit);
            } else {
                return self.reject(root.span, .{ .missing_return_value = self.return_type });
            }
        }

        fn block(self: *Self, block_id: semantic.UnresolvedBody.BlockId) !?Value {
            const unresolved_block = self.unresolved.blocks[@intFromEnum(block_id)];
            for (self.unresolved.statements[unresolved_block.statements.start..unresolved_block.statements.end]) |statement| {
                if (self.current_block == null) return null;
                switch (statement) {
                    .discard => |value_id| _ = try self.value(value_id),
                    .return_nothing => |span| try self.returnNothing(span),
                    .return_value => |returned| try self.returnValue(try self.value(returned.value), returned.span),
                }
            }
            if (self.current_block == null) return null;
            const result = if (unresolved_block.result) |result_id| try self.value(result_id) else return null;
            return if (self.current_block == null) null else result;
        }

        fn returnNothing(self: *Self, span: structures.SourceSpan) !void {
            if (self.return_type == .unit) {
                self.terminate(.return_unit);
                return;
            }
            const unit = try self.appendInstruction(.const_unit);
            const use = try coerceValue(self.type_interner, unit.id, .unit, self.return_type) orelse
                return self.reject(span, .{ .missing_return_value = self.return_type });
            self.terminate(.{ .return_value = use });
        }

        fn returnValue(self: *Self, value_to_return: Value, span: structures.SourceSpan) !void {
            if (value_to_return.type_id == .never) {
                std.debug.assert(self.current_block == null);
                return;
            }
            const use = try coerceValue(self.type_interner, value_to_return.id, value_to_return.type_id, self.return_type) orelse
                return self.reject(span, .return_type_mismatch);
            self.terminate(if (self.return_type == .unit) .return_unit else .{ .return_value = use });
        }

        fn value(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!Value {
            const index = @intFromEnum(id);
            if (self.values[index]) |resolved| return resolved;
            std.debug.assert(index >= self.unresolved.parameter_count);
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            const resolved: Value = switch (expression.operation) {
                .integer => |integer| try self.appendInstruction(.{ .consti = integer }),
                .unit => try self.appendInstruction(.const_unit),
                .none => try self.appendInstruction(.const_none),
                .annotation => |annotation| try self.annotate(annotation, expression.span),
                .assignment => try self.assignment(expression),
                .call => |call| try self.callFunction(call, expression.span),
                .negate => |operand| try self.negate(operand, expression.span),
                .add, .subtract, .multiply, .divide => try self.binary(expression),
                .if_else => |expression_if| try self.conditional(expression_if),
                .conditional_output => |conditional_id| return self.conditionalOutput(id, conditional_id),
            };
            self.values[index] = resolved;
            return resolved;
        }

        fn annotate(self: *Self, annotation: @FieldType(Expression.Operation, "annotation"), span: structures.SourceSpan) !Value {
            const operand = try self.value(annotation.value);
            if (operand.type_id == .never) return operand;
            const use = try coerceValue(self.type_interner, operand.id, operand.type_id, annotation.type_id) orelse
                return self.reject(span, .local_type_mismatch);
            if (use.coerce_to == null) return operand;
            return self.appendInstruction(.{ .variant_coerce = .{ .operand = operand.id, .target_type = annotation.type_id } });
        }

        fn assignment(self: *Self, expression: Expression) !Value {
            const assignment_value = expression.operation.assignment;
            const target = try self.value(assignment_value.target);
            if (target.type_id == .never) return target;
            const operand = try self.value(assignment_value.value);
            if (operand.type_id == .never) return operand;
            if (assignment_value.operation == .replace) {
                const use = try coerceValue(self.type_interner, operand.id, operand.type_id, target.type_id) orelse
                    return self.reject(expression.span, .assignment_type_mismatch);
                if (use.coerce_to == null) return operand;
                return self.appendInstruction(.{ .variant_coerce = .{ .operand = operand.id, .target_type = target.type_id } });
            }
            if (target.type_id != .int or operand.type_id != .int) return self.reject(expression.span, .arithmetic_operands_not_int);
            const operands: structures.BinaryOperands = .{ .lhs = target.id, .rhs = operand.id };
            return self.appendInstruction(switch (assignment_value.operation) {
                .replace => unreachable,
                .add => .{ .addi = operands },
                .subtract => .{ .subi = operands },
                .multiply => .{ .muli = operands },
                .divide => .{ .divsi = operands },
            });
        }

        fn conditionalOutput(self: *Self, id: semantic.UnresolvedBody.ValueId, conditional_id: semantic.UnresolvedBody.ValueId) !Value {
            _ = try self.value(conditional_id);
            return self.values[@intFromEnum(id)] orelse unreachable;
        }

        fn negate(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan) !Value {
            const operand = try self.value(id);
            if (operand.type_id == .never) return operand;
            if (operand.type_id != .int) return self.reject(span, .negation_operand_not_int);
            return self.appendInstruction(.{ .negi = operand.id });
        }

        fn binary(self: *Self, expression: Expression) !Value {
            const raw = switch (expression.operation) {
                .add, .subtract, .multiply, .divide => |operands| operands,
                else => unreachable,
            };
            const lhs = try self.value(raw.lhs);
            if (lhs.type_id == .never) return lhs;
            const rhs = try self.value(raw.rhs);
            if (rhs.type_id == .never) return rhs;
            if (lhs.type_id != .int or rhs.type_id != .int) return self.reject(expression.span, .arithmetic_operands_not_int);
            const operands: structures.BinaryOperands = .{ .lhs = lhs.id, .rhs = rhs.id };
            const instruction: structures.FunctionInstruction = switch (expression.operation) {
                .add => .{ .addi = operands },
                .subtract => .{ .subi = operands },
                .multiply => .{ .muli = operands },
                .divide => .{ .divsi = operands },
                else => unreachable,
            };
            return self.appendInstruction(instruction);
        }

        fn callFunction(self: *Self, call: @FieldType(Expression.Operation, "call"), span: structures.SourceSpan) !Value {
            const raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
            // Resolve nested argument expressions before the callee, preserving
            // source evaluation and diagnostic order. Later reads reuse values.
            for (raw_arguments) |argument| {
                const resolved = try self.value(argument);
                if (resolved.type_id == .never) return resolved;
            }
            var target: ?structures.ItemId = null;
            var signature: structures.FunctionSignature = .{ .parameter_types = &.{.int}, .return_type = .never };
            if (!std.mem.eql(u8, call.name, "exit")) {
                if (self.scope == null) self.scope = (try self.ctx.get(ModuleScopeQuery, self.file_id)).* orelse return error.Unavailable;
                target = self.scope.?.resolve(call.name) orelse return self.reject(span, .unknown_function);
                signature = (try self.ctx.get(FunctionSignatureQuery, target.?)).* orelse return error.Unavailable;
            }
            if (raw_arguments.len != signature.parameter_types.len) return self.reject(span, .call_argument_count_mismatch);
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            var intrinsic_argument: ?structures.FunctionValueId = null;
            for (raw_arguments, signature.parameter_types) |raw, expected| {
                const operand = self.values[@intFromEnum(raw)].?;
                const argument = try coerceValue(self.type_interner, operand.id, operand.type_id, expected) orelse
                    return self.reject(self.argumentSpan(raw, span), .call_argument_type_mismatch);
                if (target != null) {
                    try self.call_arguments.append(self.ctx.allocator(), argument);
                } else {
                    std.debug.assert(intrinsic_argument == null);
                    intrinsic_argument = argument.value;
                }
            }
            const arguments: structures.FunctionValueRange = .{ .start = argument_start, .end = @intCast(self.call_arguments.items.len) };
            const result = if (target) |item|
                try self.appendInstruction(.{ .call = .{ .target = item, .arguments = arguments, .return_type = signature.return_type } })
            else
                try self.appendInstruction(.{ .exit = intrinsic_argument.? });
            if (signature.return_type == .never) self.terminate(.diverge);
            return result;
        }

        fn argumentSpan(self: *const Self, argument: semantic.UnresolvedBody.ValueId, call_span: structures.SourceSpan) structures.SourceSpan {
            const index = @intFromEnum(argument);
            if (index < self.unresolved.parameter_count) return call_span;
            return self.unresolved.expressions[index - self.unresolved.parameter_count].span;
        }

        fn conditional(self: *Self, expression: @FieldType(Expression.Operation, "if_else")) !Value {
            const condition = expression.condition;
            const lhs = try self.value(condition.operands.lhs);
            if (lhs.type_id == .never) return lhs;
            const rhs = try self.value(condition.operands.rhs);
            if (rhs.type_id == .never) return rhs;
            if (lhs.type_id != .int or rhs.type_id != .int) return self.reject(condition.span, .comparison_operands_not_int);
            const branch_argument_start: u32 = @intCast(self.block_argument_types.items.len);
            const then_block = try self.newBlock(branch_argument_start, branch_argument_start);
            const else_block = try self.newBlock(branch_argument_start, branch_argument_start);
            self.terminate(.{ .predicate_branch = .{
                .operation = switch (condition.operation) {
                    .lt => .lti,
                    .gt => .gti,
                    .le => .lei,
                    .ge => .gei,
                    .eq => .eqi,
                    .ne => .nei,
                },
                .operands = .{ .lhs = lhs.id, .rhs = rhs.id },
                .then_branch = self.emptyBranch(then_block),
                .else_branch = self.emptyBranch(else_block),
            } });

            const outputs = self.unresolved.conditional_outputs[expression.outputs.start..expression.outputs.end];
            var then_outputs: std.ArrayList(Value) = .empty;
            defer then_outputs.deinit(self.ctx.allocator());
            self.enterBlock(then_block);
            const then_value = try self.block(expression.then_block);
            if (then_value != null) {
                for (outputs) |output| try then_outputs.append(self.ctx.allocator(), try self.value(output.then_value));
            }

            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            try self.block_argument_types.append(self.ctx.allocator(), .never);
            for (outputs) |_| try self.block_argument_types.append(self.ctx.allocator(), .never);
            const merge_block = try self.newBlock(argument_start, @intCast(self.block_argument_types.items.len));
            const then_branch = if (then_value) |then_result| blk: {
                const branch = try self.resultAndOutputsBranch(merge_block, then_result, then_outputs.items);
                self.terminate(.{ .branch = branch });
                break :blk branch;
            } else null;

            var else_outputs: std.ArrayList(Value) = .empty;
            defer else_outputs.deinit(self.ctx.allocator());
            self.enterBlock(else_block);
            const else_value = try self.block(expression.else_block);
            if (then_value == null and else_value == null) {
                self.enterBlock(merge_block);
                self.terminate(.diverge);
                for (outputs, 0..) |output, output_index| {
                    self.values[@intFromEnum(output.result)] = .{
                        .id = @enumFromInt(argument_start + 1 + @as(u32, @intCast(output_index))),
                        .type_id = .never,
                    };
                }
                return .{ .id = @enumFromInt(argument_start), .type_id = .never };
            }

            const else_branch = if (else_value) |else_result| blk: {
                for (outputs) |output| try else_outputs.append(self.ctx.allocator(), try self.value(output.else_value));
                const branch = try self.resultAndOutputsBranch(merge_block, else_result, else_outputs.items);
                self.terminate(.{ .branch = branch });
                break :blk branch;
            } else null;

            const joined = if (then_value) |then_result|
                if (else_value) |else_result|
                    try joinTypes(self.type_interner, then_result.type_id, else_result.type_id, self.ctx.allocator())
                else
                    then_result.type_id
            else
                else_value.?.type_id;
            self.block_argument_types.items[argument_start] = joined;
            if (then_value) |then_result| {
                const branch = then_branch.?;
                self.branch_arguments.items[branch.arguments.start] = (try coerceValue(self.type_interner, then_result.id, then_result.type_id, joined)) orelse unreachable;
            }
            if (else_value) |else_result| {
                const branch = else_branch.?;
                self.branch_arguments.items[branch.arguments.start] = (try coerceValue(self.type_interner, else_result.id, else_result.type_id, joined)) orelse unreachable;
            }
            for (outputs, 0..) |output, output_index| {
                const then_output: ?Value = if (then_value != null) then_outputs.items[output_index] else null;
                const else_output: ?Value = if (else_value != null) else_outputs.items[output_index] else null;
                const output_type = if (then_output) |output_value| output_value.type_id else else_output.?.type_id;
                if (then_output) |output_value| std.debug.assert(output_value.type_id == output_type);
                if (else_output) |output_value| std.debug.assert(output_value.type_id == output_type);
                const block_argument = argument_start + 1 + @as(u32, @intCast(output_index));
                self.block_argument_types.items[block_argument] = output_type;
                self.values[@intFromEnum(output.result)] = .{ .id = @enumFromInt(block_argument), .type_id = output_type };
            }
            self.enterBlock(merge_block);
            return .{ .id = @enumFromInt(argument_start), .type_id = joined };
        }

        fn appendInstruction(self: *Self, instruction: structures.FunctionInstruction) !Value {
            std.debug.assert(self.current_block != null);
            const instruction_index = std.math.cast(u31, self.instructions.items.len) orelse return error.AnalysisTooLarge;
            // The final block-argument count is known only after CFG construction.
            // Temporary high-bit IDs keep instruction and argument values distinct;
            // finish() rewrites them into the published contiguous namespace.
            const id: structures.FunctionValueId = @enumFromInt(@as(u32, 1) << 31 | @as(u32, instruction_index));
            try self.instructions.append(self.ctx.allocator(), instruction);
            return .{ .id = id, .type_id = instruction.resultType() };
        }

        fn newBlock(self: *Self, argument_start: u32, argument_end: u32) !structures.FunctionBlockId {
            const id: structures.FunctionBlockId = @enumFromInt(self.blocks.items.len);
            try self.blocks.append(self.ctx.allocator(), .{
                .argument_start = argument_start,
                .argument_end = argument_end,
                .instruction_start = undefined,
                .instruction_end = undefined,
                .terminator = undefined,
            });
            return id;
        }

        fn enterBlock(self: *Self, block_id: structures.FunctionBlockId) void {
            std.debug.assert(self.current_block == null);
            self.blocks.items[@intFromEnum(block_id)].instruction_start = @intCast(self.instructions.items.len);
            self.current_block = block_id;
        }

        fn terminate(self: *Self, terminator: structures.FunctionTerminator) void {
            const current = &self.blocks.items[@intFromEnum(self.current_block.?)];
            current.instruction_end = @intCast(self.instructions.items.len);
            current.terminator = terminator;
            self.current_block = null;
        }

        fn emptyBranch(self: *const Self, target: structures.FunctionBlockId) structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            return .{ .target = target, .arguments = .{ .start = start, .end = start } };
        }

        fn resultAndOutputsBranch(self: *Self, target: structures.FunctionBlockId, result: Value, outputs: []const Value) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            try self.branch_arguments.append(self.ctx.allocator(), .{ .value = result.id });
            for (outputs) |output| try self.branch_arguments.append(self.ctx.allocator(), .{ .value = output.id });
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn finish(self: *Self) !structures.FunctionBodyAnalysis {
            std.debug.assert(self.current_block == null);
            const gpa = self.ctx.allocator();
            const argument_count: u32 = @intCast(std.math.cast(u31, self.block_argument_types.items.len) orelse return error.AnalysisTooLarge);
            normalizeInstructions(self.instructions.items, argument_count);
            normalizeValueUses(self.call_arguments.items, argument_count);
            normalizeValueUses(self.branch_arguments.items, argument_count);
            normalizeTerminators(self.blocks.items, argument_count);
            const block_argument_types = try self.block_argument_types.toOwnedSlice(gpa);
            errdefer gpa.free(block_argument_types);
            const call_arguments = try self.call_arguments.toOwnedSlice(gpa);
            errdefer gpa.free(call_arguments);
            const instructions = try self.instructions.toOwnedSlice(gpa);
            errdefer gpa.free(instructions);
            const blocks = try self.blocks.toOwnedSlice(gpa);
            errdefer gpa.free(blocks);
            const branches = try self.branch_arguments.toOwnedSlice(gpa);
            const body: structures.FunctionBodyAnalysis = .{
                .return_type = self.return_type,
                .block_argument_types = block_argument_types,
                .call_arguments = call_arguments,
                .branch_arguments = branches,
                .instructions = instructions,
                .blocks = blocks,
                .entry = @enumFromInt(0),
            };
            return body;
        }
    };
}

fn normalizeValue(value: structures.FunctionValueId, argument_count: u32) structures.FunctionValueId {
    const instruction_mask: u32 = 1 << 31;
    const raw = @intFromEnum(value);
    if (raw & instruction_mask == 0) return value;
    return @enumFromInt(argument_count + (raw & ~instruction_mask));
}

fn normalizeValueUse(value_use: *structures.FunctionValueUse, argument_count: u32) void {
    value_use.value = normalizeValue(value_use.value, argument_count);
}

fn normalizeValueUses(value_uses: []structures.FunctionValueUse, argument_count: u32) void {
    for (value_uses) |*value_use| normalizeValueUse(value_use, argument_count);
}

fn normalizeInstructions(instructions: []structures.FunctionInstruction, argument_count: u32) void {
    for (instructions) |*instruction| switch (instruction.*) {
        .consti, .const_unit, .const_none => {},
        .variant_coerce => |*coercion| coercion.operand = normalizeValue(coercion.operand, argument_count),
        .call => {},
        .exit, .negi => |*operand| operand.* = normalizeValue(operand.*, argument_count),
        .addi, .subi, .muli, .divsi => |*operands| {
            operands.lhs = normalizeValue(operands.lhs, argument_count);
            operands.rhs = normalizeValue(operands.rhs, argument_count);
        },
    };
}

fn normalizeTerminators(blocks: []structures.FunctionBlock, argument_count: u32) void {
    for (blocks) |*block_value| switch (block_value.terminator) {
        .branch, .diverge => {},
        .predicate_branch => |*predicate| {
            predicate.operands.lhs = normalizeValue(predicate.operands.lhs, argument_count);
            predicate.operands.rhs = normalizeValue(predicate.operands.rhs, argument_count);
        },
        .return_unit => {},
        .return_value => |*value_use| normalizeValueUse(value_use, argument_count),
    };
}

fn joinTypes(type_interner: anytype, left: structures.TypeId, right: structures.TypeId, gpa: std.mem.Allocator) !structures.TypeId {
    if (left == .never) return right;
    if (right == .never) return left;
    if (left == right) return left;

    const left_members = (try type_interner.variantMembers(left)) orelse &.{left};
    const right_members = (try type_interner.variantMembers(right)) orelse &.{right};
    var members: std.ArrayList(structures.TypeId) = .empty;
    defer members.deinit(gpa);
    try members.appendSlice(gpa, left_members);
    // Shared members are one inferred alternative, not duplicate source syntax.
    for (right_members) |member| {
        if (!containsType(left_members, member)) try members.append(gpa, member);
    }
    return switch (try type_interner.internVariant(members.items)) {
        .type_id => |type_id| type_id,
        .duplicate => unreachable,
    };
}

fn coerceValue(
    type_interner: anytype,
    value: structures.FunctionValueId,
    actual_type: structures.TypeId,
    target_type: structures.TypeId,
) !?structures.FunctionValueUse {
    if (actual_type == target_type) return .{ .value = value };
    const target_members = try type_interner.variantMembers(target_type) orelse return null;
    const actual_members = try type_interner.variantMembers(actual_type);
    if (actual_members == null) {
        return if (containsType(target_members, actual_type)) .{ .value = value, .coerce_to = target_type } else null;
    }
    for (actual_members.?) |member| {
        if (!containsType(target_members, member)) return null;
    }
    return .{ .value = value, .coerce_to = target_type };
}

fn containsType(types: []const structures.TypeId, needle: structures.TypeId) bool {
    for (types) |type_id| {
        if (type_id == needle) return true;
    }
    return false;
}
