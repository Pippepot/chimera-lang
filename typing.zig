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
    is_fallible: bool,
    type_interner: anytype,
    unresolved: semantic.UnresolvedBody,
) !?structures.FunctionBodyAnalysis {
    var builder: BodyBuilder(@TypeOf(ctx), ModuleScopeQuery, FunctionSignatureQuery, @TypeOf(type_interner)) = .{
        .ctx = ctx,
        .type_interner = type_interner,
        .file_id = file_id,
        .unresolved = unresolved,
        .return_type = return_type,
        .is_fallible = is_fallible,
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
        const StateId = enum(u32) { _ };
        const PendingExtraction = struct {
            result: semantic.UnresolvedBody.ValueId,
            operand: Value,
            target_type: structures.TypeId,
            annotation_type: ?structures.TypeId,
            span: structures.SourceSpan,
        };
        const FlowExit = struct {
            block: structures.FunctionBlockId,
            state: StateId,
            extraction: ?PendingExtraction = null,
        };
        const ValueExit = struct {
            block: structures.FunctionBlockId,
            state: StateId,
            value: Value,
        };
        const ConditionFlow = struct {
            success: ?FlowExit,
            failure: ?FlowExit,
            diverged: ?Value = null,
        };
        const LoopContext = struct {
            header: structures.FunctionBlockId,
            exit: structures.FunctionBlockId,
            baseline: StateId,
            state_type_start: u32,
            state_type_end: u32,
            exit_state_start: u32,
        };
        const LoopBreak = struct { branch: structures.FunctionBranch, value: Value };

        ctx: Context,
        type_interner: TypeInterner,
        file_id: structures.FileId,
        unresolved: semantic.UnresolvedBody,
        return_type: structures.TypeId,
        is_fallible: bool,
        scope: ?structures.ModuleScope = null,
        values: []?Value = &.{},
        local_values: []?Value = &.{},
        states: std.ArrayList([]?Value) = .empty,
        block_argument_types: std.ArrayList(structures.TypeId) = .empty,
        call_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        instructions: std.ArrayList(structures.FunctionInstruction) = .empty,
        blocks: std.ArrayList(structures.FunctionBlock) = .empty,
        loop_stack: std.ArrayList(LoopContext) = .empty,
        loop_breaks: std.ArrayList(LoopBreak) = .empty,
        current_block: ?structures.FunctionBlockId = null,

        fn init(self: *Self, parameter_types: []const structures.TypeId) !void {
            std.debug.assert(parameter_types.len == self.unresolved.parameter_count);
            self.values = try self.ctx.allocator().alloc(?Value, parameter_types.len + self.unresolved.expressions.len);
            @memset(self.values, null);
            self.local_values = try self.ctx.allocator().alloc(?Value, self.unresolved.mutable_local_count);
            @memset(self.local_values, null);
            for (parameter_types, 0..) |type_id, index| self.values[index] = .{ .id = @enumFromInt(index), .type_id = type_id };
            try self.block_argument_types.appendSlice(self.ctx.allocator(), parameter_types);
            const entry = try self.newBlock(0, @intCast(parameter_types.len));
            self.enterBlock(entry);
        }

        fn deinit(self: *Self) void {
            const gpa = self.ctx.allocator();
            gpa.free(self.values);
            gpa.free(self.local_values);
            for (self.states.items) |state| gpa.free(state);
            self.states.deinit(gpa);
            self.block_argument_types.deinit(gpa);
            self.call_arguments.deinit(gpa);
            self.branch_arguments.deinit(gpa);
            self.instructions.deinit(gpa);
            self.blocks.deinit(gpa);
            self.loop_stack.deinit(gpa);
            self.loop_breaks.deinit(gpa);
        }

        fn reject(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind) anyerror {
            try emitSemanticIssue(self.ctx, self.file_id, .{ .span = span, .kind = kind });
            return error.SourceRejected;
        }

        fn describeType(self: *Self, type_id: structures.TypeId) !structures.Diagnostic.TypeDescription {
            var description: structures.Diagnostic.TypeDescription = .{};
            if (type_id.isPrimitive()) {
                addTypeToDescription(&description, type_id);
                return description;
            }
            const members = try self.type_interner.variantMembers(type_id) orelse unreachable;
            for (members) |member| addTypeToDescription(&description, member);
            return description;
        }

        fn typeMismatch(self: *Self, expected: structures.TypeId, found: structures.TypeId) !structures.Diagnostic.TypeMismatch {
            return .{
                .expected = try self.describeType(expected),
                .found = try self.describeType(found),
            };
        }

        fn build(self: *Self) !void {
            _ = try self.block(self.unresolved.root_block);
            if (self.current_block == null) return;
            const root = self.unresolved.blocks[@intFromEnum(self.unresolved.root_block)];
            if (self.return_type == .unit) {
                self.terminate(.return_unit);
            } else {
                return self.reject(root.span, .{ .missing_return_value = try self.describeType(self.return_type) });
            }
        }

        fn block(self: *Self, block_id: semantic.UnresolvedBody.BlockId) !?Value {
            const unresolved_block = self.unresolved.blocks[@intFromEnum(block_id)];
            for (self.unresolved.statements[unresolved_block.statements.start..unresolved_block.statements.end]) |statement| {
                if (self.current_block == null) return null;
                switch (statement) {
                    .discard => |value_id| _ = try self.value(value_id),
                    .propagate => |propagation| try self.propagateCondition(propagation.condition, propagation.span),
                    .bind_mutable => |binding| try self.bindMutable(binding),
                    .break_loop => |value_id| try self.breakLoop(value_id),
                    .continue_loop => try self.continueLoop(),
                    .return_nothing => |span| try self.returnNothing(span),
                    .return_value => |returned| try self.returnValue(try self.value(returned.value), returned.span),
                }
            }
            if (self.current_block == null) return null;
            const result = if (unresolved_block.result) |result_id| try self.value(result_id) else return null;
            return if (self.current_block == null) null else result;
        }

        fn bindMutable(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_mutable")) !void {
            const bound_value = try self.value(binding.value);
            if (bound_value.type_id == .never) return;
            const index = @intFromEnum(binding.local);
            std.debug.assert(self.local_values[index] == null);
            self.local_values[index] = bound_value;
        }

        fn breakLoop(self: *Self, value_id: semantic.UnresolvedBody.ValueId) !void {
            const value_to_break = try self.value(value_id);
            if (value_to_break.type_id == .never) return;
            const context = self.loop_stack.getLast();
            const branch = try self.loopBranch(context, context.exit, value_to_break);
            self.terminate(.{ .branch = branch });
            try self.loop_breaks.append(self.ctx.allocator(), .{ .branch = branch, .value = value_to_break });
        }

        fn continueLoop(self: *Self) !void {
            const context = self.loop_stack.getLast();
            const branch = try self.loopBranch(context, context.header, null);
            self.terminate(.{ .branch = branch });
        }

        fn returnNothing(self: *Self, span: structures.SourceSpan) !void {
            if (self.return_type == .unit) {
                self.terminate(.return_unit);
                return;
            }
            const unit = try self.appendInstruction(.const_unit);
            const use = try coerceValue(self.type_interner, unit.id, .unit, self.return_type) orelse
                return self.reject(span, .{ .missing_return_value = try self.describeType(self.return_type) });
            self.terminate(.{ .return_value = use });
        }

        fn returnValue(self: *Self, value_to_return: Value, span: structures.SourceSpan) !void {
            if (value_to_return.type_id == .never) {
                std.debug.assert(self.current_block == null);
                return;
            }
            const use = try coerceValue(self.type_interner, value_to_return.id, value_to_return.type_id, self.return_type) orelse
                return self.reject(span, .{ .return_type_mismatch = try self.typeMismatch(self.return_type, value_to_return.type_id) });
            self.terminate(if (self.return_type == .unit) .return_unit else .{ .return_value = use });
        }

        fn propagateCondition(self: *Self, condition_id: semantic.UnresolvedBody.ConditionId, span: structures.SourceSpan) !void {
            if (!self.is_fallible) return self.reject(span, .fallible_expression_outside_fallible_function);
            const flow = try self.condition(condition_id);
            if (flow.failure) |failure| {
                try self.enterFlowExit(failure);
                self.terminate(.return_failure);
            }
            if (flow.success) |success| {
                try self.enterFlowExit(success);
            }
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
                .local_read => |local| self.local_values[@intFromEnum(local)] orelse unreachable,
                .condition_extract => unreachable,
                .annotation => |annotation| try self.annotate(annotation),
                .assignment => try self.assignment(expression),
                .call => |call| try self.callFunction(call, expression.span),
                .negate => |operand| try self.negate(operand),
                .add, .subtract, .multiply, .divide => try self.binary(expression),
                .if_else => |expression_if| try self.conditional(expression_if),
                .loop => |body| try self.loop(body),
            };
            self.values[index] = resolved;
            return resolved;
        }

        fn captureState(self: *Self) !StateId {
            const state = try self.ctx.allocator().dupe(?Value, self.local_values);
            errdefer self.ctx.allocator().free(state);
            return self.appendState(state);
        }

        fn appendState(self: *Self, state: []?Value) !StateId {
            const id: StateId = @enumFromInt(self.states.items.len);
            try self.states.append(self.ctx.allocator(), state);
            return id;
        }

        fn restoreState(self: *Self, id: StateId) void {
            @memcpy(self.local_values, self.states.items[@intFromEnum(id)]);
        }

        fn activeStateValues(self: *Self, id: StateId) !std.ArrayList(Value) {
            var values: std.ArrayList(Value) = .empty;
            errdefer values.deinit(self.ctx.allocator());
            for (self.states.items[@intFromEnum(id)]) |value_in_state| {
                if (value_in_state) |value_to_append| try values.append(self.ctx.allocator(), value_to_append);
            }
            return values;
        }

        fn stateWithArguments(self: *Self, baseline: StateId, argument_start: u32) !StateId {
            const state = try self.ctx.allocator().dupe(?Value, self.states.items[@intFromEnum(baseline)]);
            errdefer self.ctx.allocator().free(state);
            var argument = argument_start;
            for (state) |*value_in_state| {
                if (value_in_state.* == null) continue;
                value_in_state.* = .{ .id = @enumFromInt(argument), .type_id = self.block_argument_types.items[argument] };
                argument += 1;
            }
            return self.appendState(state);
        }

        fn loop(self: *Self, body: semantic.UnresolvedBody.BlockId) !Value {
            const baseline = try self.captureState();
            var initial_values = try self.activeStateValues(baseline);
            defer initial_values.deinit(self.ctx.allocator());

            const state_type_start: u32 = @intCast(self.block_argument_types.items.len);
            for (initial_values.items) |initial| try self.block_argument_types.append(self.ctx.allocator(), initial.type_id);
            const state_type_end: u32 = @intCast(self.block_argument_types.items.len);
            const header = try self.newBlock(state_type_start, state_type_end);
            const initial_branch = try self.valuesBranch(header, initial_values.items);
            self.terminate(.{ .branch = initial_branch });

            const exit_argument_start: u32 = @intCast(self.block_argument_types.items.len);
            try self.block_argument_types.append(self.ctx.allocator(), .never);
            for (state_type_start..state_type_end) |type_index| {
                try self.block_argument_types.append(self.ctx.allocator(), self.block_argument_types.items[type_index]);
            }
            const exit = try self.newBlock(exit_argument_start, @intCast(self.block_argument_types.items.len));

            const header_state = try self.stateWithArguments(baseline, state_type_start);

            const break_start: u32 = @intCast(self.loop_breaks.items.len);
            try self.loop_stack.append(self.ctx.allocator(), .{
                .header = header,
                .exit = exit,
                .baseline = baseline,
                .state_type_start = state_type_start,
                .state_type_end = state_type_end,
                .exit_state_start = exit_argument_start + 1,
            });
            self.enterBlock(header);
            self.restoreState(header_state);
            const body_value = try self.block(body);
            if (body_value != null) {
                const repeat = try self.loopBranch(self.loop_stack.getLast(), header, null);
                self.terminate(.{ .branch = repeat });
            }
            _ = self.loop_stack.pop();

            const breaks = self.loop_breaks.items[break_start..];
            if (breaks.len == 0) {
                self.enterBlock(exit);
                self.terminate(.diverge);
                self.loop_breaks.shrinkRetainingCapacity(break_start);
                return .{ .id = @enumFromInt(exit_argument_start), .type_id = .never };
            }

            var joined = breaks[0].value.type_id;
            for (breaks[1..]) |break_edge| joined = try joinTypes(self.type_interner, joined, break_edge.value.type_id, self.ctx.allocator());
            self.block_argument_types.items[exit_argument_start] = joined;
            for (breaks) |break_edge| {
                self.branch_arguments.items[break_edge.branch.arguments.start] =
                    (try coerceValue(self.type_interner, break_edge.value.id, break_edge.value.type_id, joined)) orelse unreachable;
            }
            self.loop_breaks.shrinkRetainingCapacity(break_start);

            const output_state = try self.stateWithArguments(baseline, exit_argument_start + 1);
            self.enterBlock(exit);
            self.restoreState(output_state);
            return .{ .id = @enumFromInt(exit_argument_start), .type_id = joined };
        }

        fn valuesBranch(self: *Self, target: structures.FunctionBlockId, values: []const Value) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            for (values) |value_to_pass| try self.branch_arguments.append(self.ctx.allocator(), .{ .value = value_to_pass.id });
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn loopBranch(
            self: *Self,
            context: LoopContext,
            target: structures.FunctionBlockId,
            result: ?Value,
        ) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            if (result) |result_value| try self.branch_arguments.append(self.ctx.allocator(), .{ .value = result_value.id });
            const type_start = if (target == context.header)
                context.state_type_start
            else if (target == context.exit)
                context.exit_state_start
            else
                unreachable;
            var type_index = type_start;
            for (self.states.items[@intFromEnum(context.baseline)], self.local_values) |initial, current| {
                if (initial == null) continue;
                const state = current.?;
                const use = (try coerceValue(self.type_interner, state.id, state.type_id, self.block_argument_types.items[type_index])) orelse unreachable;
                try self.branch_arguments.append(self.ctx.allocator(), use);
                type_index += 1;
            }
            std.debug.assert(type_index == type_start + context.state_type_end - context.state_type_start);
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn annotate(self: *Self, annotation: @FieldType(Expression.Operation, "annotation")) !Value {
            const operand = try self.value(annotation.value.value);
            if (operand.type_id == .never) return operand;
            const use = try coerceValue(self.type_interner, operand.id, operand.type_id, annotation.type_id) orelse
                return self.reject(annotation.value.span, .{ .local_type_mismatch = try self.typeMismatch(annotation.type_id, operand.type_id) });
            if (use.coerce_to == null) return operand;
            return self.appendInstruction(.{ .variant_coerce = .{ .operand = operand.id, .target_type = annotation.type_id } });
        }

        fn assignment(self: *Self, expression: Expression) !Value {
            const assignment_value = expression.operation.assignment;
            const local_index = @intFromEnum(assignment_value.target);
            const target = self.local_values[local_index].?;
            const operand = try self.value(assignment_value.value.value);
            if (operand.type_id == .never) return operand;
            const result = if (assignment_value.operation == .replace) blk: {
                const use = try coerceValue(self.type_interner, operand.id, operand.type_id, target.type_id) orelse
                    return self.reject(assignment_value.value.span, .{ .assignment_type_mismatch = try self.typeMismatch(target.type_id, operand.type_id) });
                break :blk if (use.coerce_to == null)
                    operand
                else
                    try self.appendInstruction(.{ .variant_coerce = .{ .operand = operand.id, .target_type = target.type_id } });
            } else blk: {
                if (target.type_id != .int) return self.reject(assignment_value.target_span, .{ .arithmetic_operand_not_int = try self.describeType(target.type_id) });
                if (operand.type_id != .int) return self.reject(assignment_value.value.span, .{ .arithmetic_operand_not_int = try self.describeType(operand.type_id) });
                const operands: structures.BinaryOperands = .{ .lhs = target.id, .rhs = operand.id };
                break :blk try self.appendInstruction(switch (assignment_value.operation) {
                    .replace => unreachable,
                    .add => .{ .addi = operands },
                    .subtract => .{ .subi = operands },
                    .multiply => .{ .muli = operands },
                    .divide => .{ .divsi = operands },
                });
            };
            self.local_values[local_index] = result;
            return result;
        }

        fn negate(self: *Self, operand_use: semantic.UnresolvedBody.ValueUse) !Value {
            const operand = try self.value(operand_use.value);
            if (operand.type_id == .never) return operand;
            if (operand.type_id != .int) return self.reject(operand_use.span, .{ .negation_operand_not_int = try self.describeType(operand.type_id) });
            return self.appendInstruction(.{ .negi = operand.id });
        }

        fn binary(self: *Self, expression: Expression) !Value {
            const raw = switch (expression.operation) {
                .add, .subtract, .multiply, .divide => |operands| operands,
                else => unreachable,
            };
            const lhs = try self.value(raw.lhs.value);
            if (lhs.type_id == .never) return lhs;
            const rhs = try self.value(raw.rhs.value);
            if (rhs.type_id == .never) return rhs;
            if (lhs.type_id != .int) return self.reject(raw.lhs.span, .{ .arithmetic_operand_not_int = try self.describeType(lhs.type_id) });
            if (rhs.type_id != .int) return self.reject(raw.rhs.span, .{ .arithmetic_operand_not_int = try self.describeType(rhs.type_id) });
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

        const ResolvedCall = union(enum) {
            diverged: Value,
            direct: struct {
                call: structures.FunctionCall,
                is_fallible: bool,
            },
        };

        fn resolveCall(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan) !ResolvedCall {
            const raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
            // Resolve nested argument expressions before the callee, preserving
            // source evaluation and diagnostic order. Later reads reuse values.
            for (raw_arguments) |argument| {
                const resolved = try self.value(argument.value);
                if (resolved.type_id == .never) return .{ .diverged = resolved };
            }
            var target: ?structures.ItemId = null;
            var signature: structures.FunctionSignature = .{ .parameter_types = &.{.int}, .return_type = .never };
            if (!std.mem.eql(u8, call.name, "exit")) {
                if (self.scope == null) self.scope = (try self.ctx.get(ModuleScopeQuery, self.file_id)).* orelse return error.Unavailable;
                target = self.scope.?.resolveFunction(call.name) orelse {
                    if (self.scope.?.resolve(call.name) != null) return self.reject(span, .value_not_callable);
                    return self.reject(span, .unknown_function);
                };
                signature = (try self.ctx.get(FunctionSignatureQuery, target.?)).* orelse return error.Unavailable;
            }
            if (raw_arguments.len != signature.parameter_types.len) return self.reject(span, .{ .call_argument_count_mismatch = .{
                .expected = @intCast(signature.parameter_types.len),
                .found = @intCast(raw_arguments.len),
            } });
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            var intrinsic_argument: ?structures.FunctionValueId = null;
            for (raw_arguments, signature.parameter_types) |raw, expected| {
                const operand = self.values[@intFromEnum(raw.value)].?;
                const argument = try coerceValue(self.type_interner, operand.id, operand.type_id, expected) orelse
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = try self.typeMismatch(expected, operand.type_id) });
                if (target != null) {
                    try self.call_arguments.append(self.ctx.allocator(), argument);
                } else {
                    std.debug.assert(intrinsic_argument == null);
                    intrinsic_argument = argument.value;
                }
            }
            const arguments: structures.FunctionValueRange = .{ .start = argument_start, .end = @intCast(self.call_arguments.items.len) };
            if (target) |item| return .{ .direct = .{
                .call = .{ .target = item, .arguments = arguments, .return_type = signature.return_type },
                .is_fallible = signature.is_fallible,
            } };
            const result = try self.appendInstruction(.{ .exit = intrinsic_argument.? });
            self.terminate(.diverge);
            return .{ .diverged = result };
        }

        fn callFunction(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan) !Value {
            const resolved = try self.resolveCall(call, span);
            return switch (resolved) {
                .diverged => |value_to_return| value_to_return,
                .direct => |direct| if (direct.is_fallible) blk: {
                    if (!self.is_fallible) return self.reject(span, .fallible_expression_outside_fallible_function);
                    const flow = try self.lowerFallibleCall(direct.call);
                    try self.enterFlowExit(flow.failure.?);
                    self.terminate(.return_failure);
                    try self.enterFlowExit(flow.success.?);
                    const success_block = self.blocks.items[@intFromEnum(flow.success.?.block)];
                    const value_to_return: Value = .{
                        .id = @enumFromInt(success_block.argument_start),
                        .type_id = direct.call.return_type,
                    };
                    if (value_to_return.type_id == .never) self.terminate(.diverge);
                    break :blk value_to_return;
                } else blk: {
                    const value_to_return = try self.appendInstruction(.{ .call = direct.call });
                    if (value_to_return.type_id == .never) self.terminate(.diverge);
                    break :blk value_to_return;
                },
            };
        }

        fn lowerFallibleCall(self: *Self, call: structures.FunctionCall) !ConditionFlow {
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            try self.block_argument_types.append(self.ctx.allocator(), call.return_type);
            const success = try self.newBlock(argument_start, argument_start + 1);
            const failure = try self.newBlock(argument_start + 1, argument_start + 1);
            self.terminate(.{ .fallible_call = .{ .call = call, .success = success, .failure = failure } });
            const state = try self.captureState();
            return .{
                .success = .{ .block = success, .state = state },
                .failure = .{ .block = failure, .state = state },
            };
        }

        fn condition(self: *Self, id: semantic.UnresolvedBody.ConditionId) anyerror!ConditionFlow {
            const condition_data = self.unresolved.conditions[@intFromEnum(id)];
            return switch (condition_data) {
                .comparison => |comparison| self.comparisonCondition(comparison),
                .variant_membership => |membership| self.variantMembershipCondition(membership),
                .conjunction => |logical| self.conjunctionCondition(logical),
                .disjunction => |logical| self.disjunctionCondition(logical),
                .negation => |operand| self.negatedCondition(operand),
                .call => |call| self.callCondition(call),
            };
        }

        fn callCondition(self: *Self, call: semantic.UnresolvedBody.Call) !ConditionFlow {
            const resolved = try self.resolveCall(call, call.span);
            return switch (resolved) {
                .diverged => |value_to_return| .{ .success = null, .failure = null, .diverged = value_to_return },
                .direct => |direct| if (direct.is_fallible)
                    self.lowerFallibleCall(direct.call)
                else
                    self.reject(call.span, .if_condition_not_fallible),
            };
        }

        fn comparisonCondition(self: *Self, comparison: @FieldType(semantic.UnresolvedBody.Condition, "comparison")) !ConditionFlow {
            const lhs = try self.value(comparison.operands.lhs.value);
            if (lhs.type_id == .never) return .{ .success = null, .failure = null, .diverged = lhs };
            const rhs = try self.value(comparison.operands.rhs.value);
            if (rhs.type_id == .never) return .{ .success = null, .failure = null, .diverged = rhs };
            if (lhs.type_id != .int) return self.reject(comparison.operands.lhs.span, .{ .comparison_operand_not_int = try self.describeType(lhs.type_id) });
            if (rhs.type_id != .int) return self.reject(comparison.operands.rhs.span, .{ .comparison_operand_not_int = try self.describeType(rhs.type_id) });
            const branch_argument_start: u32 = @intCast(self.block_argument_types.items.len);
            const success = try self.newBlock(branch_argument_start, branch_argument_start);
            const failure = try self.newBlock(branch_argument_start, branch_argument_start);
            self.terminate(.{ .predicate_branch = .{
                .operation = switch (comparison.operation) {
                    .lt => .lti,
                    .gt => .gti,
                    .le => .lei,
                    .ge => .gei,
                    .eq => .eqi,
                    .ne => .nei,
                },
                .operands = .{ .lhs = lhs.id, .rhs = rhs.id },
                .then_branch = self.emptyBranch(success),
                .else_branch = self.emptyBranch(failure),
            } });
            const state = try self.captureState();
            return .{
                .success = .{ .block = success, .state = state },
                .failure = .{ .block = failure, .state = state },
            };
        }

        fn variantMembershipCondition(
            self: *Self,
            membership: @FieldType(semantic.UnresolvedBody.Condition, "variant_membership"),
        ) !ConditionFlow {
            const operand = try self.value(membership.operand.value);
            if (operand.type_id == .never) return .{ .success = null, .failure = null, .diverged = operand };
            const source_members = try self.type_interner.variantMembers(operand.type_id) orelse {
                return self.reject(membership.operand.span, .{ .variant_inspection_operand_not_variant = try self.describeType(operand.type_id) });
            };
            const target_members = try self.type_interner.variantMembers(membership.target_type);
            var matching_count: usize = 0;
            for (source_members) |member| {
                if (includesType(membership.target_type, target_members, member)) matching_count += 1;
            }
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            const success = try self.newBlock(argument_start, argument_start);
            const failure = try self.newBlock(argument_start, argument_start);
            if (matching_count == 0 or matching_count == source_members.len) {
                self.terminate(.{ .branch = self.emptyBranch(if (matching_count == 0) failure else success) });
            } else {
                const tag = try self.appendInstruction(.{ .variant_tag = operand.id });
                var remaining = matching_count;
                for (source_members, 0..) |member, member_index| {
                    if (!includesType(membership.target_type, target_members, member)) continue;
                    remaining -= 1;
                    const next_failure = if (remaining == 0)
                        failure
                    else
                        try self.newBlock(argument_start, argument_start);
                    const expected = try self.appendInstruction(.{ .consti = @intCast(member_index) });
                    self.terminate(.{ .predicate_branch = .{
                        .operation = .eqi,
                        .operands = .{ .lhs = tag.id, .rhs = expected.id },
                        .then_branch = self.emptyBranch(success),
                        .else_branch = self.emptyBranch(next_failure),
                    } });
                    if (remaining != 0) self.enterBlock(next_failure);
                }
            }
            const state = try self.captureState();
            const extraction: ?PendingExtraction = if (membership.binding) |binding| .{
                .result = binding.result,
                .operand = operand,
                .target_type = try intersectTypes(self.type_interner, source_members, membership.target_type, self.ctx.allocator()),
                .annotation_type = binding.annotation_type,
                .span = binding.span,
            } else null;
            return .{
                .success = .{ .block = success, .state = state, .extraction = extraction },
                .failure = .{ .block = failure, .state = state },
            };
        }

        fn conjunctionCondition(
            self: *Self,
            logical: @FieldType(semantic.UnresolvedBody.Condition, "conjunction"),
        ) !ConditionFlow {
            const lhs = try self.condition(logical.lhs);
            const rhs = if (lhs.success) |success| blk: {
                try self.enterFlowExit(success);
                break :blk try self.condition(logical.rhs);
            } else ConditionFlow{ .success = null, .failure = null };
            return .{
                .success = rhs.success,
                .failure = try self.mergeFlowExits(lhs.failure, rhs.failure),
                .diverged = rhs.diverged orelse lhs.diverged,
            };
        }

        fn disjunctionCondition(
            self: *Self,
            logical: @FieldType(semantic.UnresolvedBody.Condition, "disjunction"),
        ) !ConditionFlow {
            const lhs = try self.condition(logical.lhs);
            const rhs = if (lhs.failure) |failure| blk: {
                try self.enterFlowExit(failure);
                break :blk try self.condition(logical.rhs);
            } else ConditionFlow{ .success = null, .failure = null };
            return .{
                .success = try self.mergeFlowExits(lhs.success, rhs.success),
                .failure = rhs.failure,
                .diverged = rhs.diverged orelse lhs.diverged,
            };
        }

        fn negatedCondition(self: *Self, operand: semantic.UnresolvedBody.ConditionId) !ConditionFlow {
            const flow = try self.condition(operand);
            return .{ .success = flow.failure, .failure = flow.success, .diverged = flow.diverged };
        }

        fn enterFlowExit(self: *Self, exit: FlowExit) !void {
            self.enterBlock(exit.block);
            self.restoreState(exit.state);
            if (exit.extraction) |extraction| {
                const index = @intFromEnum(extraction.result);
                std.debug.assert(self.values[index] == null);
                var extracted = try self.appendInstruction(.{ .variant_extract = .{
                    .operand = extraction.operand.id,
                    .target_type = extraction.target_type,
                } });
                if (extraction.target_type != .never and extraction.annotation_type != null) {
                    const expected = extraction.annotation_type.?;
                    const use = try coerceValue(self.type_interner, extracted.id, extracted.type_id, expected) orelse
                        return self.reject(extraction.span, .{ .local_type_mismatch = try self.typeMismatch(expected, extracted.type_id) });
                    if (use.coerce_to != null) {
                        extracted = try self.appendInstruction(.{ .variant_coerce = .{ .operand = extracted.id, .target_type = expected } });
                    }
                }
                self.values[index] = extracted;
                if (extraction.target_type == .never) self.terminate(.diverge);
            }
        }

        fn mergeFlowExits(self: *Self, first_exit: ?FlowExit, second_exit: ?FlowExit) !?FlowExit {
            const first = first_exit orelse return second_exit;
            const second = second_exit orelse return first;
            std.debug.assert(first.extraction == null and second.extraction == null);
            const first_state = self.states.items[@intFromEnum(first.state)];
            const second_state = self.states.items[@intFromEnum(second.state)];
            std.debug.assert(first_state.len == second_state.len);

            var first_values: std.ArrayList(Value) = .empty;
            defer first_values.deinit(self.ctx.allocator());
            var second_values: std.ArrayList(Value) = .empty;
            defer second_values.deinit(self.ctx.allocator());
            var changed_slots: std.ArrayList(u32) = .empty;
            defer changed_slots.deinit(self.ctx.allocator());
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            for (first_state, second_state, 0..) |first_value, second_value, slot| {
                std.debug.assert((first_value == null) == (second_value == null));
                const left = first_value orelse continue;
                const right = second_value.?;
                std.debug.assert(left.type_id == right.type_id);
                if (left.id == right.id) continue;
                try first_values.append(self.ctx.allocator(), left);
                try second_values.append(self.ctx.allocator(), right);
                try changed_slots.append(self.ctx.allocator(), @intCast(slot));
                try self.block_argument_types.append(self.ctx.allocator(), left.type_id);
            }

            const merged = try self.newBlock(argument_start, @intCast(self.block_argument_types.items.len));
            self.enterBlock(first.block);
            self.terminate(.{ .branch = try self.valuesBranch(merged, first_values.items) });
            self.enterBlock(second.block);
            self.terminate(.{ .branch = try self.valuesBranch(merged, second_values.items) });

            const state = try self.ctx.allocator().dupe(?Value, first_state);
            errdefer self.ctx.allocator().free(state);
            for (changed_slots.items, argument_start..) |slot, argument| {
                state[slot] = .{ .id = @enumFromInt(argument), .type_id = self.block_argument_types.items[argument] };
            }
            const state_id = try self.appendState(state);
            return .{ .block = merged, .state = state_id };
        }

        fn conditional(self: *Self, expression: @FieldType(Expression.Operation, "if_else")) !Value {
            const baseline = try self.captureState();
            const flow = try self.condition(expression.condition);
            if (flow.success == null and flow.failure == null) {
                std.debug.assert(flow.diverged != null);
                return flow.diverged.?;
            }

            const then_exit = if (flow.success) |success| blk: {
                try self.enterFlowExit(success);
                break :blk try self.valueExit(try self.block(expression.then_block));
            } else null;
            const else_exit = if (flow.failure) |failure| blk: {
                try self.enterFlowExit(failure);
                break :blk try self.valueExit(try self.block(expression.else_block));
            } else null;

            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            if (then_exit == null and else_exit == null) {
                try self.block_argument_types.append(self.ctx.allocator(), .never);
                const merge_block = try self.newBlock(argument_start, argument_start + 1);
                self.enterBlock(merge_block);
                self.terminate(.diverge);
                return .{ .id = @enumFromInt(argument_start), .type_id = .never };
            }

            const joined = if (then_exit) |then_result|
                if (else_exit) |else_result|
                    try joinTypes(self.type_interner, then_result.value.type_id, else_result.value.type_id, self.ctx.allocator())
                else
                    then_result.value.type_id
            else
                else_exit.?.value.type_id;
            try self.block_argument_types.append(self.ctx.allocator(), joined);
            var changed_slots = try self.changedStateSlots(baseline, then_exit, else_exit);
            defer changed_slots.deinit(self.ctx.allocator());
            for (changed_slots.items) |slot| {
                const source = if (then_exit) |exit| self.states.items[@intFromEnum(exit.state)][slot].? else self.states.items[@intFromEnum(else_exit.?.state)][slot].?;
                try self.block_argument_types.append(self.ctx.allocator(), source.type_id);
            }
            const merge_block = try self.newBlock(argument_start, @intCast(self.block_argument_types.items.len));
            if (then_exit) |exit| self.setBlockTerminator(exit.block, .{ .branch = try self.conditionalBranch(merge_block, exit, joined, changed_slots.items) });
            if (else_exit) |exit| self.setBlockTerminator(exit.block, .{ .branch = try self.conditionalBranch(merge_block, exit, joined, changed_slots.items) });

            const output_state = try self.conditionalState(baseline, then_exit, else_exit, changed_slots.items, argument_start + 1);
            self.enterBlock(merge_block);
            self.restoreState(output_state);
            return .{ .id = @enumFromInt(argument_start), .type_id = joined };
        }

        fn valueExit(self: *Self, result: ?Value) !?ValueExit {
            const value_to_exit = result orelse return null;
            const state = try self.captureState();
            return .{ .block = self.suspendBlock(), .state = state, .value = value_to_exit };
        }

        fn changedStateSlots(
            self: *Self,
            baseline: StateId,
            first: ?ValueExit,
            second: ?ValueExit,
        ) !std.ArrayList(u32) {
            var slots: std.ArrayList(u32) = .empty;
            errdefer slots.deinit(self.ctx.allocator());
            if (first == null or second == null) return slots;
            const baseline_state = self.states.items[@intFromEnum(baseline)];
            const first_state = self.states.items[@intFromEnum(first.?.state)];
            const second_state = self.states.items[@intFromEnum(second.?.state)];
            for (baseline_state, first_state, second_state, 0..) |initial, left, right, slot| {
                if (initial == null) continue;
                std.debug.assert(left != null and right != null);
                std.debug.assert(left.?.type_id == right.?.type_id);
                if (left.?.id != right.?.id) try slots.append(self.ctx.allocator(), @intCast(slot));
            }
            return slots;
        }

        fn conditionalBranch(
            self: *Self,
            target: structures.FunctionBlockId,
            exit: ValueExit,
            result_type: structures.TypeId,
            changed_slots: []const u32,
        ) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            const result = (try coerceValue(self.type_interner, exit.value.id, exit.value.type_id, result_type)) orelse unreachable;
            try self.branch_arguments.append(self.ctx.allocator(), result);
            const state = self.states.items[@intFromEnum(exit.state)];
            for (changed_slots) |slot| try self.branch_arguments.append(self.ctx.allocator(), .{ .value = state[slot].?.id });
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn conditionalState(
            self: *Self,
            baseline: StateId,
            first: ?ValueExit,
            second: ?ValueExit,
            changed_slots: []const u32,
            argument_start: u32,
        ) !StateId {
            const source = if (first) |exit| exit.state else second.?.state;
            const state = try self.ctx.allocator().dupe(?Value, self.states.items[@intFromEnum(baseline)]);
            errdefer self.ctx.allocator().free(state);
            const source_state = self.states.items[@intFromEnum(source)];
            for (state, source_state) |*output, value_on_path| {
                if (output.* != null) output.* = value_on_path.?;
            }
            for (changed_slots, argument_start..) |slot, argument| {
                state[slot] = .{ .id = @enumFromInt(argument), .type_id = self.block_argument_types.items[argument] };
            }
            return self.appendState(state);
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
            self.setBlockTerminator(self.suspendBlock(), terminator);
        }

        fn suspendBlock(self: *Self) structures.FunctionBlockId {
            const block_id = self.current_block.?;
            self.blocks.items[@intFromEnum(block_id)].instruction_end = @intCast(self.instructions.items.len);
            self.current_block = null;
            return block_id;
        }

        fn setBlockTerminator(self: *Self, block_id: structures.FunctionBlockId, terminator: structures.FunctionTerminator) void {
            self.blocks.items[@intFromEnum(block_id)].terminator = terminator;
        }

        fn emptyBranch(self: *const Self, target: structures.FunctionBlockId) structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            return .{ .target = target, .arguments = .{ .start = start, .end = start } };
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
                .is_fallible = self.is_fallible,
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
        .variant_coerce, .variant_extract => |*operation| operation.operand = normalizeValue(operation.operand, argument_count),
        .call => {},
        .variant_tag, .exit, .negi => |*operand| operand.* = normalizeValue(operand.*, argument_count),
        .addi, .subi, .muli, .divsi => |*operands| {
            operands.lhs = normalizeValue(operands.lhs, argument_count);
            operands.rhs = normalizeValue(operands.rhs, argument_count);
        },
    };
}

fn normalizeTerminators(blocks: []structures.FunctionBlock, argument_count: u32) void {
    for (blocks) |*block_value| switch (block_value.terminator) {
        .branch, .fallible_call, .return_failure, .diverge => {},
        .predicate_branch => |*predicate| {
            predicate.operands.lhs = normalizeValue(predicate.operands.lhs, argument_count);
            predicate.operands.rhs = normalizeValue(predicate.operands.rhs, argument_count);
        },
        .return_unit => {},
        .return_value => |*value_use| normalizeValueUse(value_use, argument_count),
    };
}

fn intersectTypes(
    type_interner: anytype,
    source_members: []const structures.TypeId,
    target_type: structures.TypeId,
    gpa: std.mem.Allocator,
) !structures.TypeId {
    const target_members = try type_interner.variantMembers(target_type);
    var intersection: std.ArrayList(structures.TypeId) = .empty;
    defer intersection.deinit(gpa);
    for (source_members) |member| {
        if (includesType(target_type, target_members, member)) try intersection.append(gpa, member);
    }
    return switch (intersection.items.len) {
        0 => .never,
        1 => intersection.items[0],
        else => switch (try type_interner.internVariant(intersection.items)) {
            .type_id => |type_id| type_id,
            .duplicate => unreachable,
        },
    };
}

fn includesType(container: structures.TypeId, members: ?[]const structures.TypeId, member: structures.TypeId) bool {
    return if (members) |variant_members| containsType(variant_members, member) else container == member;
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

fn addTypeToDescription(description: *structures.Diagnostic.TypeDescription, type_id: structures.TypeId) void {
    switch (type_id) {
        .int => description.int = true,
        .unit => description.unit = true,
        .none => description.none = true,
        .never => description.never = true,
        else => unreachable,
    }
}
