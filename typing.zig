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
        block_argument_types: []structures.TypeId = &.{},
        next_argument: u32 = 0,
        call_arguments: []structures.FunctionValueUse = &.{},
        branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        instructions: std.ArrayList(structures.FunctionInstruction) = .empty,
        blocks: std.ArrayList(structures.FunctionBlock) = .empty,
        current_block: ?structures.FunctionBlockId = null,

        fn init(self: *Self, parameter_types: []const structures.TypeId) !void {
            std.debug.assert(parameter_types.len == self.unresolved.parameter_count);
            self.values = try self.ctx.allocator().alloc(?Value, parameter_types.len + self.unresolved.expressions.len);
            @memset(self.values, null);
            for (parameter_types, 0..) |type_id, index| self.values[index] = .{ .id = @enumFromInt(index), .type_id = type_id };
            var argument_count = parameter_types.len;
            for (self.unresolved.expressions) |expression| {
                if (expression.operation == .if_else) argument_count += 1;
            }
            self.block_argument_types = try self.ctx.allocator().alloc(structures.TypeId, argument_count);
            @memcpy(self.block_argument_types[0..parameter_types.len], parameter_types);
            self.next_argument = @intCast(parameter_types.len);
            self.call_arguments = try self.ctx.allocator().alloc(structures.FunctionValueUse, self.unresolved.call_arguments.len);
            const entry = try self.newBlock(0, self.next_argument);
            self.enterBlock(entry);
        }

        fn deinit(self: *Self) void {
            const gpa = self.ctx.allocator();
            gpa.free(self.values);
            gpa.free(self.block_argument_types);
            gpa.free(self.call_arguments);
            self.branch_arguments.deinit(gpa);
            self.instructions.deinit(gpa);
            self.blocks.deinit(gpa);
        }

        fn reject(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind) anyerror {
            try emitSemanticIssue(self.ctx, self.file_id, .{ .span = span, .kind = kind });
            return error.SourceRejected;
        }

        fn build(self: *Self) !void {
            for (self.unresolved.statements) |statement| {
                // A discarded statement still evaluates its initializer or call.
                _ = try self.value(statement);
            }
            if (self.unresolved.return_value) |returned| {
                try self.returnValue(try self.value(returned));
            } else if (self.return_type == .unit) {
                self.terminate(.return_unit);
            } else if (try self.type_interner.variantMembers(self.return_type) != null) {
                try self.returnValue(try self.appendInstruction(.const_unit));
            } else {
                return self.reject(self.unresolved.return_span, .{ .missing_return_value = self.return_type });
            }
            std.debug.assert(self.next_argument == self.block_argument_types.len);
        }

        fn returnValue(self: *Self, value_to_return: Value) !void {
            const use = try coerceValue(self.type_interner, value_to_return.id, value_to_return.type_id, self.return_type) orelse
                return self.reject(self.unresolved.return_span, .return_type_mismatch);
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
                .call => |call| try self.callFunction(call, expression.span),
                .negate => |operand| try self.negate(operand, expression.span),
                .add, .subtract, .multiply, .divide => try self.binary(expression),
                .if_else => |expression_if| try self.conditional(expression_if),
            };
            self.values[index] = resolved;
            return resolved;
        }

        fn annotate(self: *Self, annotation: @FieldType(Expression.Operation, "annotation"), span: structures.SourceSpan) !Value {
            const operand = try self.value(annotation.value);
            const use = try coerceValue(self.type_interner, operand.id, operand.type_id, annotation.type_id) orelse
                return self.reject(span, .local_type_mismatch);
            if (use.coerce_to == null) return operand;
            return self.appendInstruction(.{ .variant_coerce = .{ .operand = operand.id, .target_type = annotation.type_id } });
        }

        fn negate(self: *Self, id: semantic.UnresolvedBody.ValueId, span: structures.SourceSpan) !Value {
            const operand = try self.value(id);
            if (operand.type_id != .int) return self.reject(span, .negation_operand_not_int);
            return self.appendInstruction(.{ .negi = operand.id });
        }

        fn binary(self: *Self, expression: Expression) !Value {
            const raw = switch (expression.operation) {
                .add, .subtract, .multiply, .divide => |operands| operands,
                else => unreachable,
            };
            const lhs = try self.value(raw.lhs);
            const rhs = try self.value(raw.rhs);
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
            for (raw_arguments) |argument| _ = try self.value(argument);
            var target: ?structures.ItemId = null;
            var signature: structures.FunctionSignature = .{ .parameter_types = &.{.int}, .return_type = .unit };
            if (!std.mem.eql(u8, call.name, "exit")) {
                if (self.scope == null) self.scope = (try self.ctx.get(ModuleScopeQuery, self.file_id)).* orelse return error.Unavailable;
                target = self.scope.?.resolve(call.name) orelse return self.reject(span, .unknown_function);
                signature = (try self.ctx.get(FunctionSignatureQuery, target.?)).* orelse return error.Unavailable;
            }
            if (raw_arguments.len != signature.parameter_types.len) return self.reject(span, .call_argument_count_mismatch);
            const arguments = self.call_arguments[call.arguments.start..call.arguments.end];
            for (raw_arguments, arguments, signature.parameter_types) |raw, *argument, expected| {
                const operand = self.values[@intFromEnum(raw)].?;
                argument.* = try coerceValue(self.type_interner, operand.id, operand.type_id, expected) orelse
                    return self.reject(self.argumentSpan(raw, span), .call_argument_type_mismatch);
            }
            if (target) |item| {
                return self.appendInstruction(.{ .call = .{ .target = item, .arguments = call.arguments, .return_type = signature.return_type } });
            }
            return self.appendInstruction(.{ .exit = arguments[0].value });
        }

        fn argumentSpan(self: *const Self, argument: semantic.UnresolvedBody.ValueId, call_span: structures.SourceSpan) structures.SourceSpan {
            const index = @intFromEnum(argument);
            if (index < self.unresolved.parameter_count) return call_span;
            return self.unresolved.expressions[index - self.unresolved.parameter_count].span;
        }

        fn conditional(self: *Self, expression: @FieldType(Expression.Operation, "if_else")) !Value {
            const then_block = try self.newBlock(self.next_argument, self.next_argument);
            const else_block = try self.newBlock(self.next_argument, self.next_argument);
            const condition = expression.condition;
            const lhs = try self.value(condition.operands.lhs);
            const rhs = try self.value(condition.operands.rhs);
            if (lhs.type_id != .int or rhs.type_id != .int) return self.reject(condition.span, .comparison_operands_not_int);
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
            self.enterBlock(then_block);
            const then_value = try self.value(expression.then_value);
            const argument = self.next_argument;
            self.next_argument += 1;
            const merge_block = try self.newBlock(argument, argument + 1);
            const then_branch = try self.valueBranch(merge_block, .{ .value = then_value.id });
            self.terminate(.{ .branch = then_branch });

            self.enterBlock(else_block);
            const else_value = try self.value(expression.else_value);
            const joined = try joinTypes(self.type_interner, then_value.type_id, else_value.type_id, self.ctx.allocator());
            self.block_argument_types[argument] = joined;
            self.branch_arguments.items[then_branch.arguments.start] = (try coerceValue(self.type_interner, then_value.id, then_value.type_id, joined)) orelse unreachable;
            const else_use = (try coerceValue(self.type_interner, else_value.id, else_value.type_id, joined)) orelse unreachable;
            self.terminate(.{ .branch = try self.valueBranch(merge_block, else_use) });
            self.enterBlock(merge_block);
            return .{ .id = @enumFromInt(argument), .type_id = joined };
        }

        fn appendInstruction(self: *Self, instruction: structures.FunctionInstruction) !Value {
            std.debug.assert(self.current_block != null);
            const id = structures.functionInstructionValue(self.block_argument_types.len, self.instructions.items.len);
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
            const block = &self.blocks.items[@intFromEnum(self.current_block.?)];
            block.instruction_end = @intCast(self.instructions.items.len);
            block.terminator = terminator;
            self.current_block = null;
        }

        fn emptyBranch(self: *const Self, target: structures.FunctionBlockId) structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            return .{ .target = target, .arguments = .{ .start = start, .end = start } };
        }

        fn valueBranch(self: *Self, target: structures.FunctionBlockId, use: structures.FunctionValueUse) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            try self.branch_arguments.append(self.ctx.allocator(), use);
            return .{ .target = target, .arguments = .{ .start = start, .end = start + 1 } };
        }

        fn finish(self: *Self) !structures.FunctionBodyAnalysis {
            std.debug.assert(self.current_block == null);
            const gpa = self.ctx.allocator();
            const instructions = try self.instructions.toOwnedSlice(gpa);
            errdefer gpa.free(instructions);
            const blocks = try self.blocks.toOwnedSlice(gpa);
            errdefer gpa.free(blocks);
            const branches = try self.branch_arguments.toOwnedSlice(gpa);
            const body: structures.FunctionBodyAnalysis = .{
                .return_type = self.return_type,
                .block_argument_types = self.block_argument_types,
                .call_arguments = self.call_arguments,
                .branch_arguments = branches,
                .instructions = instructions,
                .blocks = blocks,
                .entry = @enumFromInt(0),
            };
            self.block_argument_types = &.{};
            self.call_arguments = &.{};
            return body;
        }
    };
}

fn joinTypes(type_interner: anytype, left: structures.TypeId, right: structures.TypeId, gpa: std.mem.Allocator) !structures.TypeId {
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
