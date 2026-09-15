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
    item_id: structures.ItemId,
    file_id: structures.FileId,
    parameters: []const structures.CallableParameter,
    return_type: structures.TypeId,
    is_fallible: bool,
    type_interner: anytype,
    unresolved: semantic.UnresolvedBody,
) !?structures.FunctionBodyAnalysis {
    var builder: BodyBuilder(@TypeOf(ctx), ModuleScopeQuery, FunctionSignatureQuery, @TypeOf(type_interner)) = .{
        .ctx = ctx,
        .type_interner = type_interner,
        .item_id = item_id,
        .file_id = file_id,
        .unresolved = unresolved,
        .return_type = return_type,
        .is_fallible = is_fallible,
    };
    defer builder.deinit();
    try builder.init(parameters);
    builder.build() catch |err| switch (err) {
        error.SourceRejected, error.Unavailable => return null,
        else => return err,
    };
    return try builder.finish();
}

fn BodyBuilder(comptime Context: type, comptime ModuleScopeQuery: type, comptime FunctionSignatureQuery: type, comptime TypeInterner: type) type {
    return struct {
        const Self = @This();
        const Value = struct {
            id: structures.FunctionValueId,
            type_id: structures.TypeId,
            // `borrow_condition` is true on paths where ownership still belongs
            // to `borrowed_type`; `borrow_root` is the youngest possible local
            // source and therefore the first lexical lifetime that can end.
            borrowed_type: ?structures.TypeId = null,
            borrow_condition: ?structures.FunctionValueId = null,
            borrow_root: ?semantic.UnresolvedBody.LocalId = null,
            explicit_transfer: bool = false,
        };
        const Availability = enum { unbound, available, transferred, maybe_transferred };
        const State = struct {
            values: []?Value,
            availability: []Availability,
        };
        const Expression = semantic.UnresolvedBody.Expression;
        const StateId = enum(u32) { _ };
        const PendingExtraction = struct {
            local: semantic.UnresolvedBody.LocalId,
            operand: Value,
            target_type: structures.TypeId,
            annotation_type: ?structures.TypeId,
            span: structures.SourceSpan,
        };
        const FlowExit = struct {
            block: structures.FunctionBlockId,
            state: StateId,
            extraction: ?PendingExtraction = null,
            temporary: ?Value = null,
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
        const LoopBreak = struct { branch: structures.FunctionBranch, state: StateId, value: Value };
        const PlaceField = struct {
            index: u32,
            type_id: structures.TypeId,
        };
        const ArgumentPlace = struct {
            local: semantic.UnresolvedBody.LocalId,
            fields: structures.FunctionValueRange,
        };
        const PendingMutArgument = struct {
            place: ArgumentPlace,
            argument_index: u32,
        };
        const BuildInstruction = struct {
            id: u31,
            operation: structures.FunctionInstruction,
        };
        const BuildBlock = struct {
            argument_start: u32,
            argument_end: u32,
            instructions: std.ArrayList(BuildInstruction) = .empty,
            layout_index: ?u32 = null,
            terminator: ?structures.FunctionTerminator = null,
        };

        ctx: Context,
        type_interner: TypeInterner,
        item_id: structures.ItemId,
        file_id: structures.FileId,
        unresolved: semantic.UnresolvedBody,
        return_type: structures.TypeId,
        is_fallible: bool,
        scope: ?structures.ModuleScope = null,
        values: []?Value = &.{},
        local_values: []?Value = &.{},
        local_mutable: []bool = &.{},
        local_can_deinit: []bool = &.{},
        local_mut_parameter: []?u32 = &.{},
        local_availability: []Availability = &.{},
        states: std.ArrayList(State) = .empty,
        block_argument_types: std.ArrayList(structures.TypeId) = .empty,
        variant_coercion_tags: std.ArrayList(u32) = .empty,
        struct_field_values: std.ArrayList(structures.StructFieldValue) = .empty,
        call_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        call_temporary_drops: std.ArrayList(Value) = .empty,
        // Values constructed inside the expression currently being evaluated.
        // A propagated failure ends them before it ends named locals.
        pending_temporaries: std.ArrayList(Value) = .empty,
        mut_argument_fields: std.ArrayList(PlaceField) = .empty,
        pending_mut_arguments: std.ArrayList(PendingMutArgument) = .empty,
        branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
        blocks: std.ArrayList(BuildBlock) = .empty,
        loop_stack: std.ArrayList(LoopContext) = .empty,
        loop_breaks: std.ArrayList(LoopBreak) = .empty,
        current_block: ?structures.FunctionBlockId = null,
        instruction_count: u32 = 0,
        block_layout_count: u32 = 0,

        fn init(self: *Self, parameters: []const structures.CallableParameter) !void {
            std.debug.assert(parameters.len == self.unresolved.parameter_count);
            self.values = try self.ctx.allocator().alloc(?Value, parameters.len + self.unresolved.expressions.len);
            @memset(self.values, null);
            self.local_values = try self.ctx.allocator().alloc(?Value, self.unresolved.local_count);
            @memset(self.local_values, null);
            self.local_mutable = try self.ctx.allocator().alloc(bool, self.unresolved.local_count);
            @memset(self.local_mutable, false);
            self.local_can_deinit = try self.ctx.allocator().alloc(bool, self.unresolved.local_count);
            @memset(self.local_can_deinit, false);
            self.local_mut_parameter = try self.ctx.allocator().alloc(?u32, self.unresolved.local_count);
            @memset(self.local_mut_parameter, null);
            self.local_availability = try self.ctx.allocator().alloc(Availability, self.unresolved.local_count);
            @memset(self.local_availability, .unbound);
            try self.block_argument_types.ensureUnusedCapacity(self.ctx.allocator(), parameters.len);
            var parameter_local: usize = 0;
            for (parameters, 0..) |parameter, index| {
                const entry_value: Value = .{ .id = @enumFromInt(index), .type_id = parameter.type_id };
                switch (parameter.mode) {
                    .imm => self.values[index] = .{
                        .id = entry_value.id,
                        .type_id = entry_value.type_id,
                        .borrowed_type = entry_value.type_id,
                    },
                    .mut, .@"var", .deinit => {
                        self.local_values[parameter_local] = entry_value;
                        self.local_mutable[parameter_local] = true;
                        self.local_can_deinit[parameter_local] = parameter.mode == .deinit;
                        if (parameter.mode == .mut) self.local_mut_parameter[parameter_local] = @intCast(index);
                        self.local_availability[parameter_local] = .available;
                        parameter_local += 1;
                    },
                    .static => unreachable,
                }
                self.block_argument_types.appendAssumeCapacity(parameter.type_id);
            }
            const entry = try self.newBlock(0, @intCast(parameters.len));
            self.enterBlock(entry);
        }

        fn deinit(self: *Self) void {
            const gpa = self.ctx.allocator();
            gpa.free(self.values);
            gpa.free(self.local_values);
            gpa.free(self.local_mutable);
            gpa.free(self.local_can_deinit);
            gpa.free(self.local_mut_parameter);
            gpa.free(self.local_availability);
            for (self.states.items) |state| {
                gpa.free(state.values);
                gpa.free(state.availability);
            }
            self.states.deinit(gpa);
            self.block_argument_types.deinit(gpa);
            self.variant_coercion_tags.deinit(gpa);
            self.struct_field_values.deinit(gpa);
            self.call_arguments.deinit(gpa);
            self.call_temporary_drops.deinit(gpa);
            self.pending_temporaries.deinit(gpa);
            self.mut_argument_fields.deinit(gpa);
            self.pending_mut_arguments.deinit(gpa);
            self.branch_arguments.deinit(gpa);
            for (self.blocks.items) |*block_value| block_value.instructions.deinit(gpa);
            self.blocks.deinit(gpa);
            self.loop_stack.deinit(gpa);
            self.loop_breaks.deinit(gpa);
        }

        fn reject(self: *Self, span: structures.SourceSpan, kind: structures.Diagnostic.Kind) anyerror {
            try emitSemanticIssue(self.ctx, self.file_id, .{ .span = span, .kind = kind });
            return error.SourceRejected;
        }

        fn typeMismatch(_: *Self, expected: structures.TypeId, found: structures.TypeId) structures.Diagnostic.TypeMismatch {
            return .{ .expected = expected, .found = found };
        }

        fn build(self: *Self) !void {
            _ = try self.block(self.unresolved.root_block);
            if (self.current_block == null) return;
            const root = self.unresolved.blocks[@intFromEnum(self.unresolved.root_block)];
            if (self.return_type == .unit) {
                try self.finishFunctionExit(root.span, .return_unit);
            } else {
                return self.reject(root.span, .{ .missing_return_value = self.return_type });
            }
        }

        fn block(self: *Self, block_id: semantic.UnresolvedBody.BlockId) !?Value {
            const unresolved_block = self.unresolved.blocks[@intFromEnum(block_id)];
            const baseline = try self.captureState();
            for (self.unresolved.statements[unresolved_block.statements.start..unresolved_block.statements.end]) |statement| {
                if (self.current_block == null) return null;
                switch (statement) {
                    .discard => |value_use| try self.discardValue(try self.value(value_use.value), value_use.span),
                    .propagate => |propagation| try self.propagateCondition(propagation.condition, propagation.span),
                    .bind_local => |binding| try self.bindLocal(binding),
                    .break_loop => |value_id| try self.breakLoop(value_id),
                    .continue_loop => |span| try self.continueLoop(span),
                    .return_nothing => |span| try self.returnNothing(span),
                    .return_value => |returned| try self.returnValue(try self.value(returned.value), returned.span),
                }
            }
            if (self.current_block == null) return null;
            var result = if (unresolved_block.result) |result_id| try self.value(result_id) else null;
            if (self.current_block == null) return null;
            if (result) |value_to_exit| result = try self.ownValueEscapingSince(value_to_exit, baseline, unresolved_block.span);
            try self.endLocalsSince(baseline, unresolved_block.span);
            return result;
        }

        fn bindLocal(self: *Self, binding: @FieldType(semantic.UnresolvedBody.Statement, "bind_local")) !void {
            const bound_value = try self.ownValue(try self.value(binding.value), binding.span);
            if (bound_value.type_id == .never) return;
            const index = @intFromEnum(binding.local);
            std.debug.assert(self.local_values[index] == null);
            self.local_values[index] = bound_value;
            self.local_mutable[index] = binding.mutable;
            self.local_availability[index] = .available;
        }

        fn discardValue(self: *Self, value_to_discard: Value, span: structures.SourceSpan) !void {
            try self.endTemporary(try self.borrowValue(value_to_discard, span), span);
        }

        fn breakLoop(self: *Self, value_id: semantic.UnresolvedBody.ValueId) !void {
            var value_to_break = try self.value(value_id);
            if (value_to_break.type_id == .never) return;
            const context = self.loop_stack.getLast();
            value_to_break = try self.ownValueEscapingSince(value_to_break, context.baseline, self.unresolved.blocks[@intFromEnum(self.unresolved.root_block)].span);
            try self.endLocalsSince(context.baseline, self.unresolved.blocks[@intFromEnum(self.unresolved.root_block)].span);
            const branch = try self.loopBranch(context, context.exit, value_to_break);
            self.terminate(.{ .branch = branch });
            try self.loop_breaks.append(self.ctx.allocator(), .{ .branch = branch, .state = try self.captureState(), .value = value_to_break });
        }

        fn continueLoop(self: *Self, span: structures.SourceSpan) !void {
            const context = self.loop_stack.getLast();
            try self.endLocalsSince(context.baseline, span);
            try self.validateLoopBackedge(context, span);
            const branch = try self.loopBranch(context, context.header, null);
            self.terminate(.{ .branch = branch });
        }

        fn returnNothing(self: *Self, span: structures.SourceSpan) !void {
            if (self.return_type == .unit) {
                try self.finishFunctionExit(span, .return_unit);
                return;
            }
            const unit = try self.appendInstruction(.const_unit);
            const use = try self.coerceValue(unit.id, .unit, self.return_type) orelse
                return self.reject(span, .{ .missing_return_value = self.return_type });
            try self.finishFunctionExit(span, .{ .return_value = use });
        }

        fn returnValue(self: *Self, value_to_return: Value, span: structures.SourceSpan) !void {
            if (value_to_return.type_id == .never) {
                std.debug.assert(self.current_block == null);
                return;
            }
            var use = try self.coerceValue(value_to_return.id, value_to_return.type_id, self.return_type) orelse
                return self.reject(span, .{ .return_type_mismatch = self.typeMismatch(self.return_type, value_to_return.type_id) });
            const owned = try self.ownValue(value_to_return, span);
            use.value = owned.id;
            try self.finishFunctionExit(span, if (self.return_type == .unit) .return_unit else .{ .return_value = use });
        }

        fn propagateCondition(self: *Self, condition_id: semantic.UnresolvedBody.ConditionId, span: structures.SourceSpan) !void {
            if (!self.is_fallible) return self.reject(span, .fallible_expression_outside_fallible_function);
            const flow = try self.condition(condition_id);
            if (flow.failure) |failure| {
                try self.enterFlowExit(failure);
                try self.finishFunctionExit(span, .return_failure);
            }
            if (flow.success) |success| {
                try self.enterFlowExit(success);
            }
        }

        fn endLocalsSince(self: *Self, baseline: StateId, span: structures.SourceSpan) !void {
            const initial = self.states.items[@intFromEnum(baseline)].availability;
            var index = self.local_availability.len;
            while (index > 0) {
                index -= 1;
                if (initial[index] == .unbound and self.local_availability[index] != .unbound) try self.endLocal(index, span);
            }
        }

        fn endAllLocals(self: *Self, span: structures.SourceSpan) !void {
            var index = self.local_availability.len;
            while (index > 0) {
                index -= 1;
                if (self.local_availability[index] != .unbound) try self.endLocal(index, span);
            }
        }

        fn finishFunctionExit(self: *Self, span: structures.SourceSpan, terminator: structures.FunctionTerminator) !void {
            try self.writeMutParameters();
            try self.endPendingTemporaries(span);
            try self.endAllLocals(span);
            self.terminate(terminator);
        }

        fn ownValueEscapingSince(self: *Self, result: Value, baseline: StateId, span: structures.SourceSpan) !Value {
            const root = result.borrow_root orelse return result;
            if (self.states.items[@intFromEnum(baseline)].availability[@intFromEnum(root)] != .unbound) return result;
            return self.ownValue(result, span);
        }

        fn endLocal(self: *Self, index: usize, span: structures.SourceSpan) !void {
            const availability = self.local_availability[index];
            const capabilities = (try self.type_interner.ownershipCapabilities(self.local_values[index].?.type_id)) orelse return error.Unavailable;
            if (availability == .maybe_transferred and capabilities.needs_automatic_drop) {
                return self.reject(span, .possibly_transferred);
            }
            if (availability != .transferred and self.local_mut_parameter[index] == null) {
                try self.dropValue(self.local_values[index].?, self.local_can_deinit[index], span);
            }
            self.local_values[index] = null;
            self.local_availability[index] = .unbound;
        }

        fn value(self: *Self, id: semantic.UnresolvedBody.ValueId) anyerror!Value {
            const index = @intFromEnum(id);
            if (self.values[index]) |resolved| return resolved;
            std.debug.assert(index >= self.unresolved.parameter_count);
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            const resolved: Value = switch (expression.operation) {
                .integer => |integer| try self.appendInstruction(.{ .consti = integer }),
                .boolean => |boolean| try self.appendInstruction(.{ .constb = boolean }),
                .unit => try self.appendInstruction(.const_unit),
                .none => try self.appendInstruction(.const_none),
                .function_ref => |reference| try self.appendInstruction(.{ .function_ref = reference }),
                .local_read => |local| try self.readLocal(local, expression.span),
                .local_transfer => |local| try self.transferLocal(local, expression.span),
                .annotation => |annotation| try self.annotate(annotation),
                .struct_init => try self.structInit(expression),
                .field_access => try self.fieldAccess(expression),
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

        fn readLocal(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !Value {
            const index = @intFromEnum(local);
            switch (self.local_availability[index]) {
                .unbound => unreachable,
                .available => {},
                .transferred => return self.reject(span, .use_after_transfer),
                .maybe_transferred => return self.reject(span, .possibly_transferred),
            }
            var value_to_read = self.local_values[index].?;
            value_to_read.borrowed_type = value_to_read.type_id;
            value_to_read.borrow_root = local;
            return value_to_read;
        }

        fn transferLocal(self: *Self, local: semantic.UnresolvedBody.LocalId, span: structures.SourceSpan) !Value {
            if (self.local_mut_parameter[@intFromEnum(local)] != null) return self.reject(span, .ownership_transfer_requires_owned_place);
            const value_to_transfer = try self.readLocal(local, span);
            const capabilities = (try self.type_interner.ownershipCapabilities(value_to_transfer.type_id)) orelse return error.Unavailable;
            if (capabilities.move == .none) return self.reject(span, .{ .type_not_movable = value_to_transfer.type_id });
            self.local_availability[@intFromEnum(local)] = .transferred;
            var transferred = try self.moveValue(withoutOwnershipSource(value_to_transfer));
            transferred.explicit_transfer = true;
            return transferred;
        }

        fn writeMutParameters(self: *Self) !void {
            for (self.local_mut_parameter, self.local_values) |parameter_index, local_value| {
                const index = parameter_index orelse continue;
                const value_to_write = local_value.?;
                _ = try self.appendInstruction(.{ .mut_parameter_write = .{
                    .parameter_index = index,
                    .value = value_to_write.id,
                    .type_id = value_to_write.type_id,
                } });
            }
        }

        fn ownValue(self: *Self, value_to_own: Value, span: structures.SourceSpan) !Value {
            if (try self.nonCopyableBorrow(value_to_own)) |source_type| return self.reject(span, .{ .type_not_copyable = source_type });
            if (value_to_own.borrowed_type == null) return withoutOwnershipSource(value_to_own);
            const source = withoutOwnershipSource(value_to_own);
            return if (value_to_own.borrow_condition) |borrow_predicate|
                self.copyValueConditionally(source, borrow_predicate)
            else
                self.copyValue(source);
        }

        fn copyValueConditionally(self: *Self, source: Value, borrow_predicate: structures.FunctionValueId) !Value {
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            try self.block_argument_types.append(self.ctx.allocator(), source.type_id);
            const copy_block = try self.newBlock(argument_start, argument_start);
            const owned_block = try self.newBlock(argument_start, argument_start);
            const join = try self.newBlock(argument_start, argument_start + 1);
            const expected = try self.appendInstruction(.{ .constb = true });
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = borrow_predicate, .rhs = expected.id },
                .then_branch = self.emptyBranch(copy_block),
                .else_branch = self.emptyBranch(owned_block),
            } });
            self.enterBlock(copy_block);
            const copied = try self.copyValueAcrossJoin(source);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{copied}) });
            self.enterBlock(owned_block);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{source}) });
            self.enterBlock(join);
            return .{ .id = @enumFromInt(argument_start), .type_id = source.type_id };
        }

        fn copyValueAcrossJoin(self: *Self, source: Value) !Value {
            const capabilities = (try self.type_interner.ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            if (capabilities.copy != .none) return self.copyValue(source);
            const members = (try self.type_interner.variantMembers(source.type_id)) orelse unreachable;
            return self.mapVariantMember(source, members, .copy);
        }

        fn copyValue(self: *Self, source: Value) anyerror!Value {
            const capabilities = (try self.type_interner.ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            return switch (capabilities.copy) {
                .trivial => source,
                .none => unreachable,
                .custom => self.callOwnershipHook(source, .copy),
                .fieldwise => if (capabilities.needs_custom_copy) self.copyStructFields(source) else source,
            };
        }

        fn moveValue(self: *Self, source: Value) anyerror!Value {
            const capabilities = (try self.type_interner.ownershipCapabilities(source.type_id)) orelse return error.Unavailable;
            return switch (capabilities.move) {
                .trivial => source,
                .none => unreachable,
                .custom => self.callOwnershipHook(source, .move),
                .fieldwise => if (capabilities.needs_custom_move) self.moveStructFields(source) else source,
            };
        }

        const OwnershipOperation = enum { copy, move, drop };

        fn callOwnershipHook(self: *Self, source: Value, operation: OwnershipOperation) !Value {
            const definition = (try self.type_interner.structDefinition(source.type_id)) orelse unreachable;
            const hook = switch (operation) {
                .copy => definition.ownership.copy.?.hook.?,
                .move => definition.ownership.move.?.hook.?,
                .drop => definition.ownership.drop.?.hook.?,
            };
            if (hook == self.item_id) return source;
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.append(self.ctx.allocator(), .{ .value = source.id });
            return self.appendInstruction(.{ .call = .{
                .target = hook,
                .arguments = .{ .start = argument_start, .end = argument_start + 1 },
                .return_type = if (operation == .drop) .unit else source.type_id,
            } });
        }

        fn copyStructFields(self: *Self, source: Value) anyerror!Value {
            const definition = (try self.type_interner.structDefinition(source.type_id)) orelse {
                const members = (try self.type_interner.variantMembers(source.type_id)) orelse return source;
                return self.mapVariantMember(source, members, .copy);
            };
            return self.mapStructFields(source, definition, .copy);
        }

        fn moveStructFields(self: *Self, source: Value) anyerror!Value {
            const definition = (try self.type_interner.structDefinition(source.type_id)) orelse {
                const members = (try self.type_interner.variantMembers(source.type_id)) orelse return source;
                return self.mapVariantMember(source, members, .move);
            };
            return self.mapStructFields(source, definition, .move);
        }

        fn mapStructFields(
            self: *Self,
            source: Value,
            definition: structures.StructDefinition,
            operation: OwnershipOperation,
        ) anyerror!Value {
            var fields: std.ArrayList(structures.StructFieldValue) = .empty;
            defer fields.deinit(self.ctx.allocator());
            for (definition.fields, 0..) |field, index| {
                const extracted = try self.appendInstruction(.{ .field_access = .{
                    .operand = source.id,
                    .field_index = @intCast(index),
                    .field_type = field.type_id,
                } });
                const owned = switch (operation) {
                    .copy => try self.copyValue(extracted),
                    .move => try self.moveValue(extracted),
                    .drop => unreachable,
                };
                try fields.append(self.ctx.allocator(), .{
                    .field_index = @intCast(index),
                    .value = owned.id,
                });
            }
            const field_start: u32 = @intCast(self.struct_field_values.items.len);
            try self.struct_field_values.appendSlice(self.ctx.allocator(), fields.items);
            return self.appendInstruction(.{ .struct_init = .{
                .fields = .{ .start = field_start, .end = @intCast(self.struct_field_values.items.len) },
                .type_id = source.type_id,
            } });
        }

        fn mapVariantMember(
            self: *Self,
            source: Value,
            members: []const structures.TypeId,
            operation: OwnershipOperation,
        ) anyerror!Value {
            return (try self.operateOnVariantMember(source, members, switch (operation) {
                .copy => .copy,
                .move => .move,
                .drop => unreachable,
            })).?;
        }

        fn mapExtractedVariantMember(self: *Self, source: Value, member: structures.TypeId, operation: OwnershipOperation) anyerror!Value {
            const extracted = try self.appendInstruction(.{ .variant_extract = .{
                .operand = source.id,
                .target_type = member,
            } });
            const owned = switch (operation) {
                .copy => blk: {
                    const capabilities = (try self.type_interner.ownershipCapabilities(member)) orelse return error.Unavailable;
                    break :blk if (capabilities.copy == .none) extracted else try self.copyValue(extracted);
                },
                .move => try self.moveValue(extracted),
                .drop => unreachable,
            };
            const use = (try self.coerceValue(owned.id, member, source.type_id)) orelse unreachable;
            return if (use.coerce_to == null) owned else self.appendCoercion(use);
        }

        fn dropVariantMember(
            self: *Self,
            source: Value,
            members: []const structures.TypeId,
            can_deinit: bool,
            span: structures.SourceSpan,
        ) anyerror!void {
            _ = try self.operateOnVariantMember(source, members, .{ .drop = .{
                .can_deinit = can_deinit,
                .span = span,
            } });
        }

        const VariantOwnershipOperation = union(enum) {
            copy,
            move,
            drop: struct {
                can_deinit: bool,
                span: structures.SourceSpan,
            },
        };

        fn operateOnVariantMember(
            self: *Self,
            source: Value,
            members: []const structures.TypeId,
            operation: VariantOwnershipOperation,
        ) anyerror!?Value {
            std.debug.assert(members.len != 0);
            const tag = try self.appendInstruction(.{ .variant_tag = source.id });
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            switch (operation) {
                .copy, .move => try self.block_argument_types.append(self.ctx.allocator(), source.type_id),
                .drop => {},
            }
            const join = try self.newBlock(argument_start, @intCast(self.block_argument_types.items.len));

            for (members, 0..) |member, member_index| {
                const case = try self.newBlock(argument_start, argument_start);
                const next = if (member_index + 1 == members.len)
                    null
                else
                    try self.newBlock(argument_start, argument_start);
                if (next) |next_block| {
                    const expected = try self.appendInstruction(.{ .consti = @intCast(member_index) });
                    self.terminate(.{ .predicate_branch = .{
                        .operation = .eqi,
                        .operands = .{ .lhs = tag.id, .rhs = expected.id },
                        .then_branch = self.emptyBranch(case),
                        .else_branch = self.emptyBranch(next_block),
                    } });
                } else {
                    self.terminate(.{ .branch = self.emptyBranch(case) });
                }
                self.enterBlock(case);
                switch (operation) {
                    .drop => |drop| {
                        const extracted = try self.appendInstruction(.{ .variant_extract = .{
                            .operand = source.id,
                            .target_type = member,
                        } });
                        try self.dropValue(extracted, drop.can_deinit, drop.span);
                        self.terminate(.{ .branch = self.emptyBranch(join) });
                    },
                    .copy => {
                        const result = try self.mapExtractedVariantMember(source, member, .copy);
                        self.terminate(.{ .branch = try self.valuesBranch(join, &.{result}) });
                    },
                    .move => {
                        const result = try self.mapExtractedVariantMember(source, member, .move);
                        self.terminate(.{ .branch = try self.valuesBranch(join, &.{result}) });
                    },
                }
                if (next) |next_block| self.enterBlock(next_block);
            }
            self.enterBlock(join);
            return switch (operation) {
                .drop => null,
                .copy, .move => .{ .id = @enumFromInt(argument_start), .type_id = source.type_id },
            };
        }

        fn dropValue(self: *Self, value_to_drop: Value, can_deinit: bool, span: structures.SourceSpan) anyerror!void {
            const capabilities = (try self.type_interner.ownershipCapabilities(value_to_drop.type_id)) orelse return error.Unavailable;
            switch (capabilities.drop) {
                .trivial => {},
                .explicit => if (!can_deinit) return self.reject(span, .{ .value_requires_explicit_drop = value_to_drop.type_id }),
                .custom => _ = try self.callOwnershipHook(value_to_drop, .drop),
                .fieldwise => {
                    if (!capabilities.needs_automatic_drop and !capabilities.requires_explicit_drop) return;
                    const definition = (try self.type_interner.structDefinition(value_to_drop.type_id)) orelse {
                        const members = (try self.type_interner.variantMembers(value_to_drop.type_id)) orelse return;
                        try self.dropVariantMember(value_to_drop, members, can_deinit, span);
                        return;
                    };
                    var field_index = definition.fields.len;
                    while (field_index > 0) {
                        field_index -= 1;
                        const field = definition.fields[field_index];
                        const field_value = try self.appendInstruction(.{ .field_access = .{
                            .operand = value_to_drop.id,
                            .field_index = @intCast(field_index),
                            .field_type = field.type_id,
                        } });
                        try self.dropValue(field_value, can_deinit, span);
                    }
                },
            }
        }

        fn nonCopyableBorrow(self: *Self, value_to_check: Value) !?structures.TypeId {
            const source_type = value_to_check.borrowed_type orelse return null;
            const capabilities = (try self.type_interner.ownershipCapabilities(source_type)) orelse return error.Unavailable;
            return if (capabilities.copy == .none) source_type else null;
        }

        fn borrowValue(self: *Self, borrowed: Value, span: structures.SourceSpan) !Value {
            if (borrowed.explicit_transfer) return self.reject(span, .ownership_transfer_requires_owning_context);
            const capabilities = (try self.type_interner.ownershipCapabilities(borrowed.type_id)) orelse return error.Unavailable;
            if (borrowed.borrowed_type == null and capabilities.requires_explicit_drop) {
                return self.reject(span, .{ .value_requires_explicit_drop = borrowed.type_id });
            }
            return borrowed;
        }

        fn withoutOwnershipSource(resolved: Value) Value {
            return .{ .id = resolved.id, .type_id = resolved.type_id };
        }

        fn laterBorrowRoot(left: ?semantic.UnresolvedBody.LocalId, right: ?semantic.UnresolvedBody.LocalId) ?semantic.UnresolvedBody.LocalId {
            const left_id = left orelse return right;
            const right_id = right orelse return left;
            return if (@intFromEnum(left_id) >= @intFromEnum(right_id)) left_id else right_id;
        }

        fn endTemporary(self: *Self, temporary: Value, span: structures.SourceSpan) !void {
            if (temporary.borrowed_type == null) return self.dropValue(temporary, false, span);
            const predicate = temporary.borrow_condition orelse return;
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            const borrowed = try self.newBlock(argument_start, argument_start);
            const owned = try self.newBlock(argument_start, argument_start);
            const join = try self.newBlock(argument_start, argument_start);
            const expected = try self.appendInstruction(.{ .constb = true });
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = predicate, .rhs = expected.id },
                .then_branch = self.emptyBranch(borrowed),
                .else_branch = self.emptyBranch(owned),
            } });
            self.enterBlock(borrowed);
            self.terminate(.{ .branch = self.emptyBranch(join) });
            self.enterBlock(owned);
            try self.dropValue(withoutOwnershipSource(temporary), false, span);
            self.terminate(.{ .branch = self.emptyBranch(join) });
            self.enterBlock(join);
        }

        fn endPendingTemporaries(self: *Self, span: structures.SourceSpan) !void {
            var index = self.pending_temporaries.items.len;
            while (index > 0) {
                index -= 1;
                try self.endTemporary(self.pending_temporaries.items[index], span);
            }
        }

        fn structInit(self: *Self, expression: Expression) !Value {
            const initializer = expression.operation.struct_init;
            const definition = (try self.type_interner.structDefinition(initializer.type_id)) orelse
                return self.reject(expression.span, .{ .struct_initializer_not_struct = initializer.type_id });
            if (try self.type_interner.structLayout(initializer.type_id) == null) return error.Unavailable;

            const seen = try self.ctx.allocator().alloc(bool, definition.fields.len);
            defer self.ctx.allocator().free(seen);
            @memset(seen, false);
            var fields: std.ArrayList(structures.StructFieldValue) = .empty;
            defer fields.deinit(self.ctx.allocator());
            const pending_start = self.pending_temporaries.items.len;
            defer self.pending_temporaries.shrinkRetainingCapacity(pending_start);
            const source_fields = self.unresolved.struct_field_values[initializer.fields.start..initializer.fields.end];
            for (source_fields) |source_field| {
                const field = definition.resolveField(source_field.name) orelse
                    return self.reject(source_field.name_span, .unknown_struct_field);
                if (seen[field.index]) return self.reject(source_field.name_span, .duplicate_struct_initializer_field);
                seen[field.index] = true;

                const operand = try self.value(source_field.value.value);
                if (operand.type_id == .never) return operand;
                var use = try self.coerceValue(operand.id, operand.type_id, field.type_id) orelse
                    return self.reject(source_field.value.span, .{ .struct_initializer_field_type_mismatch = self.typeMismatch(field.type_id, operand.type_id) });
                const owned = try self.ownValue(operand, source_field.value.span);
                try self.pending_temporaries.append(self.ctx.allocator(), owned);
                use.value = owned.id;
                const field_value = if (use.coerce_to) |_| try self.appendCoercion(use) else owned;
                try fields.append(self.ctx.allocator(), .{
                    .field_index = field.index,
                    .value = field_value.id,
                });
            }
            for (seen) |was_seen| if (!was_seen) return self.reject(expression.span, .missing_struct_initializer_field);
            const start: u32 = @intCast(self.struct_field_values.items.len);
            try self.struct_field_values.appendSlice(self.ctx.allocator(), fields.items);
            return self.appendInstruction(.{ .struct_init = .{
                .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
                .type_id = initializer.type_id,
            } });
        }

        fn fieldAccess(self: *Self, expression: Expression) !Value {
            const access = expression.operation.field_access;
            const operand = try self.borrowValue(try self.value(access.operand.value), access.operand.span);
            if (operand.type_id == .never) return operand;
            const definition = (try self.type_interner.structDefinition(operand.type_id)) orelse
                return self.reject(access.operand.span, .{ .field_access_not_struct = operand.type_id });
            if (try self.type_interner.structLayout(operand.type_id) == null) return error.Unavailable;
            const field = definition.resolveField(access.name) orelse return self.reject(expression.span, .unknown_field);
            var result = try self.appendInstruction(.{ .field_access = .{
                .operand = operand.id,
                .field_index = field.index,
                .field_type = field.type_id,
            } });
            if (operand.borrowed_type != null) {
                result.borrowed_type = field.type_id;
                result.borrow_root = operand.borrow_root;
                if (operand.borrow_condition) |borrow_condition| {
                    return self.accessConditionalTemporary(operand, result, borrow_condition, expression.span);
                }
            } else if ((try self.type_interner.ownershipCapabilities(operand.type_id) orelse return error.Unavailable).needs_automatic_drop) {
                result.borrowed_type = field.type_id;
                result = try self.ownValue(result, expression.span);
                try self.dropValue(operand, false, access.operand.span);
            }
            return result;
        }

        fn accessConditionalTemporary(
            self: *Self,
            operand: Value,
            field: Value,
            borrow_condition: structures.FunctionValueId,
            span: structures.SourceSpan,
        ) !Value {
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            try self.block_argument_types.append(self.ctx.allocator(), field.type_id);
            const borrowed = try self.newBlock(argument_start, argument_start);
            const owned = try self.newBlock(argument_start, argument_start);
            const join = try self.newBlock(argument_start, argument_start + 1);
            const expected = try self.appendInstruction(.{ .constb = true });
            self.terminate(.{ .predicate_branch = .{
                .operation = .eqb,
                .operands = .{ .lhs = borrow_condition, .rhs = expected.id },
                .then_branch = self.emptyBranch(borrowed),
                .else_branch = self.emptyBranch(owned),
            } });
            self.enterBlock(borrowed);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{field}) });
            self.enterBlock(owned);
            const capabilities = (try self.type_interner.ownershipCapabilities(operand.type_id)) orelse return error.Unavailable;
            const owned_field = if (capabilities.needs_automatic_drop or capabilities.requires_explicit_drop) blk: {
                const copied = try self.ownValue(.{
                    .id = field.id,
                    .type_id = field.type_id,
                    .borrowed_type = field.borrowed_type,
                    .borrow_root = field.borrow_root,
                }, span);
                try self.dropValue(withoutOwnershipSource(operand), false, span);
                break :blk copied;
            } else withoutOwnershipSource(field);
            self.terminate(.{ .branch = try self.valuesBranch(join, &.{owned_field}) });
            self.enterBlock(join);
            return .{
                .id = @enumFromInt(argument_start),
                .type_id = field.type_id,
                .borrowed_type = field.type_id,
                .borrow_condition = borrow_condition,
                .borrow_root = field.borrow_root,
            };
        }

        fn captureState(self: *Self) !StateId {
            const values = try self.ctx.allocator().dupe(?Value, self.local_values);
            errdefer self.ctx.allocator().free(values);
            const availability = try self.ctx.allocator().dupe(Availability, self.local_availability);
            errdefer self.ctx.allocator().free(availability);
            return self.appendState(.{ .values = values, .availability = availability });
        }

        fn appendState(self: *Self, state: State) !StateId {
            std.debug.assert(state.values.len == state.availability.len);
            std.debug.assert(state.values.len == self.local_values.len);
            const id: StateId = @enumFromInt(self.states.items.len);
            try self.states.append(self.ctx.allocator(), state);
            return id;
        }

        fn restoreState(self: *Self, id: StateId) void {
            const state = self.states.items[@intFromEnum(id)];
            @memcpy(self.local_values, state.values);
            @memcpy(self.local_availability, state.availability);
        }

        fn activeStateValues(self: *Self, id: StateId) !std.ArrayList(Value) {
            var values: std.ArrayList(Value) = .empty;
            errdefer values.deinit(self.ctx.allocator());
            for (self.states.items[@intFromEnum(id)].values, self.local_mutable) |value_in_state, mutable| {
                if (mutable) if (value_in_state) |value_to_append| try values.append(self.ctx.allocator(), value_to_append);
            }
            return values;
        }

        fn stateWithArguments(self: *Self, baseline: StateId, argument_start: u32) !StateId {
            const baseline_state = self.states.items[@intFromEnum(baseline)];
            const values = try self.ctx.allocator().dupe(?Value, baseline_state.values);
            errdefer self.ctx.allocator().free(values);
            const availability = try self.ctx.allocator().dupe(Availability, baseline_state.availability);
            errdefer self.ctx.allocator().free(availability);
            var argument = argument_start;
            for (values, self.local_mutable) |*value_in_state, mutable| {
                if (!mutable or value_in_state.* == null) continue;
                value_in_state.* = .{ .id = @enumFromInt(argument), .type_id = self.block_argument_types.items[argument] };
                argument += 1;
            }
            return self.appendState(.{ .values = values, .availability = availability });
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
            try self.block_argument_types.append(self.ctx.allocator(), .bool);
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
                .exit_state_start = exit_argument_start + 2,
            });
            self.enterBlock(header);
            self.restoreState(header_state);
            const body_value = try self.block(body);
            if (body_value != null) {
                try self.validateLoopBackedge(self.loop_stack.getLast(), self.unresolved.blocks[@intFromEnum(body)].span);
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
                    (try self.coerceValue(break_edge.value.id, break_edge.value.type_id, joined)) orelse unreachable;
            }
            const output_state = try self.stateWithArguments(baseline, exit_argument_start + 2);
            for (self.states.items[@intFromEnum(output_state)].availability, 0..) |*availability, index| {
                if (self.states.items[@intFromEnum(baseline)].availability[index] == .unbound) continue;
                availability.* = self.states.items[@intFromEnum(breaks[0].state)].availability[index];
                for (breaks[1..]) |break_edge| {
                    availability.* = joinAvailability(availability.*, self.states.items[@intFromEnum(break_edge.state)].availability[index]);
                }
            }
            var any_borrowed = false;
            var all_borrowed = true;
            var has_conditional_borrow = false;
            var contains_transfer = false;
            var borrow_root: ?semantic.UnresolvedBody.LocalId = null;
            var borrowed_source: ?structures.TypeId = null;
            for (breaks) |break_edge| {
                any_borrowed = any_borrowed or break_edge.value.borrowed_type != null;
                all_borrowed = all_borrowed and break_edge.value.borrowed_type != null;
                has_conditional_borrow = has_conditional_borrow or break_edge.value.borrow_condition != null;
                if (break_edge.value.borrowed_type != null) {
                    if (borrowed_source) |source_type| {
                        if (source_type != break_edge.value.borrowed_type.?) borrowed_source = joined;
                    } else {
                        borrowed_source = break_edge.value.borrowed_type.?;
                    }
                    borrow_root = laterBorrowRoot(borrow_root, break_edge.value.borrow_root);
                }
                contains_transfer = contains_transfer or break_edge.value.explicit_transfer;
            }
            const needs_borrow_condition = any_borrowed and (has_conditional_borrow or !all_borrowed);
            self.loop_breaks.shrinkRetainingCapacity(break_start);
            self.enterBlock(exit);
            self.restoreState(output_state);
            return .{
                .id = @enumFromInt(exit_argument_start),
                .type_id = joined,
                .borrowed_type = borrowed_source,
                .borrow_condition = if (needs_borrow_condition)
                    @enumFromInt(exit_argument_start + 1)
                else
                    null,
                .borrow_root = borrow_root,
                .explicit_transfer = contains_transfer,
            };
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
            if (result) |result_value| {
                try self.branch_arguments.append(self.ctx.allocator(), .{ .value = result_value.id });
                const borrowed_on_path = result_value.borrow_condition orelse (try self.appendInstruction(.{
                    .constb = result_value.borrowed_type != null,
                })).id;
                try self.branch_arguments.append(self.ctx.allocator(), .{ .value = borrowed_on_path });
            }
            const type_start = if (target == context.header)
                context.state_type_start
            else if (target == context.exit)
                context.exit_state_start
            else
                unreachable;
            var type_index = type_start;
            for (self.states.items[@intFromEnum(context.baseline)].values, self.local_values, self.local_mutable) |initial, current, mutable| {
                if (!mutable or initial == null) continue;
                const state = current.?;
                const use = (try self.coerceValue(state.id, state.type_id, self.block_argument_types.items[type_index])) orelse unreachable;
                try self.branch_arguments.append(self.ctx.allocator(), use);
                type_index += 1;
            }
            std.debug.assert(type_index == type_start + context.state_type_end - context.state_type_start);
            return .{ .target = target, .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) } };
        }

        fn validateLoopBackedge(self: *Self, context: LoopContext, span: structures.SourceSpan) !void {
            const baseline = self.states.items[@intFromEnum(context.baseline)].availability;
            for (baseline, self.local_availability) |initial, current| {
                if (initial == .available and current != .available) {
                    return self.reject(span, .transferred_value_not_restored_before_loop_backedge);
                }
            }
        }

        fn annotate(self: *Self, annotation: @FieldType(Expression.Operation, "annotation")) !Value {
            const operand = try self.value(annotation.value.value);
            if (operand.type_id == .never) return operand;
            const use = try self.coerceValue(operand.id, operand.type_id, annotation.type_id) orelse
                return self.reject(annotation.value.span, .{ .local_type_mismatch = self.typeMismatch(annotation.type_id, operand.type_id) });
            if (use.coerce_to == null) return operand;
            var result = try self.appendCoercion(use);
            result.borrowed_type = operand.borrowed_type;
            result.borrow_condition = operand.borrow_condition;
            result.borrow_root = operand.borrow_root;
            return result;
        }

        fn appendCoercion(self: *Self, use: structures.FunctionValueUse) !Value {
            const target_type = use.coerce_to.?;
            const operation: structures.FunctionInstruction = if (try self.type_interner.callable(target_type) != null)
                .{ .callable_coerce = .{ .operand = use.value, .target_type = target_type } }
            else
                .{ .variant_coerce = .{
                    .operand = use.value,
                    .target_type = target_type,
                    .tag_mapping = use.variant_tag_mapping.?,
                } };
            return self.appendInstruction(operation);
        }

        fn coerceValue(
            self: *Self,
            value_id: structures.FunctionValueId,
            actual_type: structures.TypeId,
            target_type: structures.TypeId,
        ) !?structures.FunctionValueUse {
            if (actual_type == target_type) return .{ .value = value_id };
            if (actual_type == .never or !try semantic.canWidenTo(self.type_interner, actual_type, target_type)) return null;
            const target_members = try self.type_interner.variantMembers(target_type) orelse
                return .{ .value = value_id, .coerce_to = target_type };
            const mapping_start: u32 = @intCast(self.variant_coercion_tags.items.len);
            if (try self.type_interner.variantMembers(actual_type)) |actual_members| {
                for (actual_members) |actual_member| try self.appendVariantTag(target_members, actual_member);
            } else {
                try self.appendVariantTag(target_members, actual_type);
            }
            return .{
                .value = value_id,
                .coerce_to = target_type,
                .variant_tag_mapping = .{
                    .start = mapping_start,
                    .end = @intCast(self.variant_coercion_tags.items.len),
                },
            };
        }

        fn appendVariantTag(self: *Self, target_members: []const structures.TypeId, actual_member: structures.TypeId) !void {
            for (target_members, 0..) |target_member, target_tag| {
                if (actual_member == target_member) {
                    try self.variant_coercion_tags.append(self.ctx.allocator(), @intCast(target_tag));
                    return;
                }
            }
            for (target_members, 0..) |target_member, target_tag| {
                if (try semantic.canWidenTo(self.type_interner, actual_member, target_member)) {
                    try self.variant_coercion_tags.append(self.ctx.allocator(), @intCast(target_tag));
                    return;
                }
            }
            unreachable;
        }

        fn appendExtractionTagMapping(
            self: *Self,
            source_type: structures.TypeId,
            target_type: structures.TypeId,
        ) !?structures.FunctionValueRange {
            const target_members = try self.type_interner.variantMembers(target_type) orelse return null;
            const source_members = (try self.type_interner.variantMembers(source_type)).?;
            const start: u32 = @intCast(self.variant_coercion_tags.items.len);
            for (source_members) |source_member| {
                const target_tag: u32 = for (target_members, 0..) |target_member, index| {
                    if (source_member == target_member) break @intCast(index);
                } else structures.invalid_variant_tag;
                try self.variant_coercion_tags.append(self.ctx.allocator(), target_tag);
            }
            return .{ .start = start, .end = @intCast(self.variant_coercion_tags.items.len) };
        }

        fn assignment(self: *Self, expression: Expression) !Value {
            const assignment_value = expression.operation.assignment;
            const local_index = @intFromEnum(assignment_value.target);
            if (self.local_availability[local_index] != .available and (assignment_value.fields.start != assignment_value.fields.end or assignment_value.operation != .replace)) {
                return self.reject(assignment_value.target_span, if (self.local_availability[local_index] == .maybe_transferred) .possibly_transferred else .use_after_transfer);
            }
            const root = self.local_values[local_index].?;
            var fields: std.ArrayList(PlaceField) = .empty;
            defer fields.deinit(self.ctx.allocator());
            const source_fields = self.unresolved.assignment_fields[assignment_value.fields.start..assignment_value.fields.end];
            var target_type = root.type_id;
            for (source_fields, 0..) |source_field, index| {
                const definition = (try self.type_interner.structDefinition(target_type)) orelse
                    return self.reject(if (index == 0) assignment_value.target_span else source_fields[index - 1].span, .{ .field_access_not_struct = target_type });
                if (try self.type_interner.structLayout(target_type) == null) return error.Unavailable;
                const field = definition.resolveField(source_field.name) orelse return self.reject(source_field.span, .unknown_field);
                try fields.append(self.ctx.allocator(), .{
                    .index = field.index,
                    .type_id = field.type_id,
                });
                target_type = field.type_id;
            }
            var target = root;
            for (fields.items) |field| {
                target = try self.appendInstruction(.{ .field_access = .{
                    .operand = target.id,
                    .field_index = field.index,
                    .field_type = field.type_id,
                } });
            }
            const target_span = if (source_fields.len == 0) assignment_value.target_span else source_fields[source_fields.len - 1].span;
            const raw_operand = try self.value(assignment_value.value.value);
            const operand = if (assignment_value.operation == .replace)
                raw_operand
            else
                try self.borrowValue(raw_operand, assignment_value.value.span);
            if (operand.type_id == .never) return operand;
            if (fields.items.len != 0 and self.local_availability[local_index] != .available) {
                return self.reject(assignment_value.target_span, if (self.local_availability[local_index] == .maybe_transferred) .possibly_transferred else .use_after_transfer);
            }
            const result = if (assignment_value.operation == .replace) blk: {
                var latest_target = self.local_values[local_index].?;
                for (fields.items) |field| {
                    latest_target = try self.appendInstruction(.{ .field_access = .{
                        .operand = latest_target.id,
                        .field_index = field.index,
                        .field_type = field.type_id,
                    } });
                }
                var use = try self.coerceValue(operand.id, operand.type_id, target_type) orelse
                    return self.reject(assignment_value.value.span, .{ .assignment_type_mismatch = self.typeMismatch(target_type, operand.type_id) });
                const owned = try self.ownValue(operand, assignment_value.value.span);
                use.value = owned.id;
                if (fields.items.len != 0 or self.local_availability[local_index] != .transferred) {
                    const target_capabilities = (try self.type_interner.ownershipCapabilities(latest_target.type_id)) orelse return error.Unavailable;
                    if (self.local_availability[local_index] == .maybe_transferred and target_capabilities.needs_automatic_drop) {
                        return self.reject(target_span, .possibly_transferred);
                    }
                    try self.dropValue(latest_target, self.local_can_deinit[local_index], target_span);
                }
                break :blk if (use.coerce_to == null)
                    owned
                else
                    try self.appendCoercion(use);
            } else blk: {
                if (target_type != .int) return self.reject(target_span, .{ .arithmetic_operand_not_int = target_type });
                if (operand.type_id != .int) return self.reject(assignment_value.value.span, .{ .arithmetic_operand_not_int = operand.type_id });
                const operands: structures.BinaryOperands = .{ .lhs = target.id, .rhs = operand.id };
                break :blk try self.appendInstruction(switch (assignment_value.operation) {
                    .replace => unreachable,
                    .add => .{ .addi = operands },
                    .subtract => .{ .subi = operands },
                    .multiply => .{ .muli = operands },
                    .divide => .{ .divsi = operands },
                });
            };
            const updated = try self.updateFields(self.local_values[local_index].?, fields.items, result);
            self.local_values[local_index] = withoutOwnershipSource(updated);
            self.local_availability[local_index] = .available;
            return .{
                .id = result.id,
                .type_id = result.type_id,
                .borrowed_type = result.type_id,
                .borrow_root = assignment_value.target,
            };
        }

        fn negate(self: *Self, operand_use: semantic.UnresolvedBody.ValueUse) !Value {
            const operand = try self.borrowValue(try self.value(operand_use.value), operand_use.span);
            if (operand.type_id == .never) return operand;
            if (operand.type_id != .int) return self.reject(operand_use.span, .{ .negation_operand_not_int = operand.type_id });
            return self.appendInstruction(.{ .negi = operand.id });
        }

        fn binary(self: *Self, expression: Expression) !Value {
            const raw = switch (expression.operation) {
                .add, .subtract, .multiply, .divide => |operands| operands,
                else => unreachable,
            };
            const lhs = try self.borrowValue(try self.value(raw.lhs.value), raw.lhs.span);
            if (lhs.type_id == .never) return lhs;
            const rhs = try self.borrowValue(try self.value(raw.rhs.value), raw.rhs.span);
            if (rhs.type_id == .never) return rhs;
            if (lhs.type_id != .int) return self.reject(raw.lhs.span, .{ .arithmetic_operand_not_int = lhs.type_id });
            if (rhs.type_id != .int) return self.reject(raw.rhs.span, .{ .arithmetic_operand_not_int = rhs.type_id });
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

        const CallOperation = union(enum) {
            direct: structures.FunctionCall,
            indirect: structures.IndirectFunctionCall,
        };
        const ResolvedCall = union(enum) {
            diverged: Value,
            callable: struct {
                operation: CallOperation,
                is_fallible: bool,
                temporary_drops: structures.FunctionValueRange,
                mut_arguments: structures.FunctionValueRange,
            },
        };

        fn resolveArgumentPlace(
            self: *Self,
            value_id: semantic.UnresolvedBody.ValueId,
            fields: *std.ArrayList(PlaceField),
        ) !?ArgumentPlace {
            const start: u32 = @intCast(fields.items.len);
            const local = (try self.appendArgumentPlaceFields(value_id, fields)) orelse {
                fields.shrinkRetainingCapacity(start);
                return null;
            };
            return .{
                .local = local,
                .fields = .{ .start = start, .end = @intCast(fields.items.len) },
            };
        }

        fn appendArgumentPlaceFields(
            self: *Self,
            value_id: semantic.UnresolvedBody.ValueId,
            fields: *std.ArrayList(PlaceField),
        ) !?semantic.UnresolvedBody.LocalId {
            const index = @intFromEnum(value_id);
            if (index < self.unresolved.parameter_count) return null;
            const expression = self.unresolved.expressions[index - self.unresolved.parameter_count];
            return switch (expression.operation) {
                .local_read => |local| local,
                .field_access => |access| blk: {
                    const local = (try self.appendArgumentPlaceFields(access.operand.value, fields)) orelse return null;
                    const parent = self.values[@intFromEnum(access.operand.value)].?;
                    const definition = (try self.type_interner.structDefinition(parent.type_id)) orelse unreachable;
                    const field = definition.resolveField(access.name) orelse unreachable;
                    try fields.append(self.ctx.allocator(), .{ .index = field.index, .type_id = field.type_id });
                    break :blk local;
                },
                else => null,
            };
        }

        fn placesOverlap(fields: []const PlaceField, left: ArgumentPlace, right: ArgumentPlace) bool {
            if (left.local != right.local) return false;
            const left_fields = fields[left.fields.start..left.fields.end];
            const right_fields = fields[right.fields.start..right.fields.end];
            const shared_length = @min(left_fields.len, right_fields.len);
            for (left_fields[0..shared_length], right_fields[0..shared_length]) |left_field, right_field| {
                if (left_field.index != right_field.index) return false;
            }
            return true;
        }

        fn resolveCall(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan) !ResolvedCall {
            const raw_arguments = self.unresolved.call_arguments[call.arguments.start..call.arguments.end];
            const Target = union(enum) { intrinsic, direct: structures.ItemId, indirect: structures.FunctionValueId };
            var target: Target = undefined;
            var signature: structures.CallableType = undefined;
            switch (call.target) {
                .direct => |name| {
                    if (std.mem.eql(u8, name, "exit")) {
                        target = .intrinsic;
                        signature = .{ .parameters = &.{.{ .mode = .imm, .type_id = .int }}, .return_type = .never, .is_fallible = false };
                    } else {
                        if (self.scope == null) self.scope = (try self.ctx.get(ModuleScopeQuery, self.file_id)).* orelse return error.Unavailable;
                        const item = self.scope.?.resolveFunction(name) orelse {
                            if (self.scope.?.resolve(name) != null) return self.reject(span, .value_not_callable);
                            return self.reject(span, .unknown_function);
                        };
                        target = .{ .direct = item };
                        const resolved_signature = (try self.ctx.get(FunctionSignatureQuery, item)).* orelse return error.Unavailable;
                        signature = .{
                            .parameters = resolved_signature.parameters,
                            .return_type = resolved_signature.return_type,
                            .is_fallible = resolved_signature.is_fallible,
                        };
                    }
                },
                .value => |target_use| {
                    const callee = try self.borrowValue(try self.value(target_use.value), target_use.span);
                    if (callee.type_id == .never) return .{ .diverged = callee };
                    signature = try self.type_interner.callable(callee.type_id) orelse
                        return self.reject(target_use.span, .value_not_callable);
                    target = .{ .indirect = callee.id };
                },
            }
            if (raw_arguments.len != signature.parameters.len) return self.reject(span, .{ .call_argument_count_mismatch = .{
                .expected = @intCast(signature.parameters.len),
                .found = @intCast(raw_arguments.len),
            } });
            var place_fields: std.ArrayList(PlaceField) = .empty;
            defer place_fields.deinit(self.ctx.allocator());
            var argument_places: std.ArrayList(?ArgumentPlace) = .empty;
            defer argument_places.deinit(self.ctx.allocator());
            var arguments_to_publish: std.ArrayList(structures.FunctionValueUse) = .empty;
            defer arguments_to_publish.deinit(self.ctx.allocator());
            var temporary_drops_to_publish: std.ArrayList(Value) = .empty;
            defer temporary_drops_to_publish.deinit(self.ctx.allocator());
            var mut_arguments_to_publish: std.ArrayList(PendingMutArgument) = .empty;
            defer mut_arguments_to_publish.deinit(self.ctx.allocator());
            const pending_start = self.pending_temporaries.items.len;
            defer self.pending_temporaries.shrinkRetainingCapacity(pending_start);

            // Finish each argument before evaluating the next one. Nested copy
            // hooks may publish their own calls, so the outer operands stay in
            // local storage until their complete contiguous range is known.
            for (raw_arguments, signature.parameters, 0..) |raw, expected, argument_index| {
                const raw_operand = try self.value(raw.value);
                if (raw_operand.type_id == .never) return .{ .diverged = raw_operand };
                const maybe_place = if (expected.mode == .imm or expected.mode == .mut)
                    try self.resolveArgumentPlace(raw.value, &place_fields)
                else
                    null;
                try argument_places.append(self.ctx.allocator(), maybe_place);
                const operand = switch (expected.mode) {
                    .imm => try self.borrowValue(raw_operand, raw.span),
                    .mut, .@"var", .deinit => raw_operand,
                    .static => unreachable,
                };
                if (expected.mode == .mut and operand.type_id != expected.type_id) {
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, operand.type_id) });
                }
                var argument = try self.coerceValue(operand.id, operand.type_id, expected.type_id) orelse
                    return self.reject(raw.span, .{ .call_argument_type_mismatch = self.typeMismatch(expected.type_id, operand.type_id) });
                if (expected.mode == .@"var" or expected.mode == .deinit) {
                    const owned = try self.ownValue(operand, raw.span);
                    argument.value = owned.id;
                    try self.pending_temporaries.append(self.ctx.allocator(), owned);
                } else if (expected.mode == .mut) {
                    const place = maybe_place orelse return self.reject(raw.span, .mutable_argument_requires_place);
                    const field_start: u32 = @intCast(self.mut_argument_fields.items.len);
                    try self.mut_argument_fields.appendSlice(self.ctx.allocator(), place_fields.items[place.fields.start..place.fields.end]);
                    try mut_arguments_to_publish.append(self.ctx.allocator(), .{
                        .place = .{
                            .local = place.local,
                            .fields = .{ .start = field_start, .end = @intCast(self.mut_argument_fields.items.len) },
                        },
                        .argument_index = @intCast(argument_index),
                    });
                } else if (operand.borrowed_type == null or operand.borrow_condition != null) {
                    try temporary_drops_to_publish.append(self.ctx.allocator(), operand);
                    try self.pending_temporaries.append(self.ctx.allocator(), operand);
                }
                try arguments_to_publish.append(self.ctx.allocator(), argument);
            }
            for (raw_arguments, signature.parameters, argument_places.items, 0..) |raw, parameter, maybe_place, argument_index| {
                if (parameter.mode != .mut) continue;
                const place = maybe_place orelse return self.reject(raw.span, .mutable_argument_requires_place);
                const local_index = @intFromEnum(place.local);
                if (!self.local_mutable[local_index]) return self.reject(raw.span, .mutable_argument_requires_mutable_place);
                switch (self.local_availability[local_index]) {
                    .unbound => unreachable,
                    .available => {},
                    .transferred => return self.reject(raw.span, .use_after_transfer),
                    .maybe_transferred => return self.reject(raw.span, .possibly_transferred),
                }
                for (signature.parameters, argument_places.items, 0..) |other_parameter, other_place, other_index| {
                    if (argument_index == other_index or (other_parameter.mode != .imm and other_parameter.mode != .mut)) continue;
                    if (other_place) |resolved_other| {
                        if (placesOverlap(place_fields.items, place, resolved_other)) {
                            return self.reject(raw.span, .overlapping_mutable_arguments);
                        }
                    }
                }
            }
            const argument_start: u32 = @intCast(self.call_arguments.items.len);
            switch (target) {
                .intrinsic => {},
                .direct, .indirect => try self.call_arguments.appendSlice(self.ctx.allocator(), arguments_to_publish.items),
            }
            const arguments: structures.FunctionValueRange = .{ .start = argument_start, .end = @intCast(self.call_arguments.items.len) };
            const temporary_drop_start: u32 = @intCast(self.call_temporary_drops.items.len);
            try self.call_temporary_drops.appendSlice(self.ctx.allocator(), temporary_drops_to_publish.items);
            const temporary_drops: structures.FunctionValueRange = .{
                .start = temporary_drop_start,
                .end = @intCast(self.call_temporary_drops.items.len),
            };
            const mut_argument_start: u32 = @intCast(self.pending_mut_arguments.items.len);
            try self.pending_mut_arguments.appendSlice(self.ctx.allocator(), mut_arguments_to_publish.items);
            const mut_arguments: structures.FunctionValueRange = .{
                .start = mut_argument_start,
                .end = @intCast(self.pending_mut_arguments.items.len),
            };
            return switch (target) {
                .direct => |item| .{ .callable = .{
                    .operation = .{ .direct = .{ .target = item, .arguments = arguments, .return_type = signature.return_type } },
                    .is_fallible = signature.is_fallible,
                    .temporary_drops = temporary_drops,
                    .mut_arguments = mut_arguments,
                } },
                .indirect => |callee| .{ .callable = .{
                    .operation = .{ .indirect = .{ .target = callee, .arguments = arguments, .return_type = signature.return_type } },
                    .is_fallible = signature.is_fallible,
                    .temporary_drops = temporary_drops,
                    .mut_arguments = mut_arguments,
                } },
                .intrinsic => blk: {
                    const result = try self.appendInstruction(.{ .exit = arguments_to_publish.items[0].value });
                    self.terminate(.diverge);
                    break :blk .{ .diverged = result };
                },
            };
        }

        fn callFunction(self: *Self, call: semantic.UnresolvedBody.Call, span: structures.SourceSpan) !Value {
            const resolved = try self.resolveCall(call, span);
            return switch (resolved) {
                .diverged => |value_to_return| value_to_return,
                .callable => |callable| if (callable.is_fallible) blk: {
                    if (!self.is_fallible) return self.reject(span, .fallible_expression_outside_fallible_function);
                    var flow = try self.lowerFallibleCall(callable.operation);
                    try self.finishCallExits(&flow, callable, span);
                    try self.enterFlowExit(flow.failure.?);
                    try self.finishFunctionExit(span, .return_failure);
                    try self.enterFlowExit(flow.success.?);
                    const success_block = self.blocks.items[@intFromEnum(flow.success.?.block)];
                    const value_to_return: Value = .{
                        .id = @enumFromInt(success_block.argument_start),
                        .type_id = callReturnType(callable.operation),
                    };
                    if (value_to_return.type_id == .never) self.terminate(.diverge);
                    break :blk value_to_return;
                } else blk: {
                    const value_to_return = try self.appendCall(callable.operation);
                    if (value_to_return.type_id == .never) {
                        self.terminate(.diverge);
                    } else {
                        try self.applyCallMutArguments(callable.operation, callable.mut_arguments);
                        try self.dropCallTemporaries(callable.temporary_drops, span);
                    }
                    break :blk value_to_return;
                },
            };
        }

        fn dropCallTemporaries(self: *Self, range: structures.FunctionValueRange, span: structures.SourceSpan) !void {
            var index = @as(usize, range.end);
            while (index > range.start) {
                index -= 1;
                try self.endTemporary(self.call_temporary_drops.items[index], span);
            }
        }

        fn finishCallExits(
            self: *Self,
            flow: *ConditionFlow,
            callable: @FieldType(ResolvedCall, "callable"),
            span: structures.SourceSpan,
        ) !void {
            if (flow.success) |*success| try self.finishCallExit(success, callable, span);
            if (flow.failure) |*failure| try self.finishCallExit(failure, callable, span);
        }

        fn finishCallExit(
            self: *Self,
            flow_exit: *FlowExit,
            callable: @FieldType(ResolvedCall, "callable"),
            span: structures.SourceSpan,
        ) !void {
            try self.enterFlowExit(flow_exit.*);
            try self.applyCallMutArguments(callable.operation, callable.mut_arguments);
            try self.dropCallTemporaries(callable.temporary_drops, span);
            flow_exit.state = try self.captureState();
            const source = self.blocks.items[@intFromEnum(flow_exit.block)];
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            var values: std.ArrayList(Value) = .empty;
            defer values.deinit(self.ctx.allocator());
            for (source.argument_start..source.argument_end) |argument_index| {
                const type_id = self.block_argument_types.items[argument_index];
                try self.block_argument_types.append(self.ctx.allocator(), type_id);
                try values.append(self.ctx.allocator(), .{ .id = @enumFromInt(argument_index), .type_id = type_id });
            }
            const continuation = try self.newBlock(argument_start, @intCast(self.block_argument_types.items.len));
            self.terminate(.{ .branch = try self.valuesBranch(continuation, values.items) });
            flow_exit.block = continuation;
            flow_exit.extraction = null;
        }

        fn appendCall(self: *Self, call: CallOperation) !Value {
            return switch (call) {
                .direct => |direct| self.appendInstruction(.{ .call = direct }),
                .indirect => |indirect| self.appendInstruction(.{ .indirect_call = indirect }),
            };
        }

        fn applyCallMutArguments(self: *Self, call: CallOperation, range: structures.FunctionValueRange) !void {
            const arguments = switch (call) {
                inline else => |operation| operation.arguments,
            };
            const return_type = callReturnType(call);
            for (self.pending_mut_arguments.items[range.start..range.end]) |pending| {
                const fields = self.mut_argument_fields.items[pending.place.fields.start..pending.place.fields.end];
                const leaf_type = if (fields.len == 0)
                    self.local_values[@intFromEnum(pending.place.local)].?.type_id
                else
                    fields[fields.len - 1].type_id;
                const updated_leaf = try self.appendInstruction(.{ .call_mut_argument = .{
                    .arguments = arguments,
                    .return_type = return_type,
                    .argument_index = pending.argument_index,
                    .type_id = leaf_type,
                } });
                try self.updateMutArgumentPlace(pending.place, updated_leaf);
            }
        }

        fn updateMutArgumentPlace(self: *Self, place: ArgumentPlace, updated_leaf: Value) !void {
            const local_index = @intFromEnum(place.local);
            const fields = self.mut_argument_fields.items[place.fields.start..place.fields.end];
            self.local_values[local_index] = withoutOwnershipSource(try self.updateFields(self.local_values[local_index].?, fields, updated_leaf));
        }

        fn updateFields(self: *Self, root: Value, fields: []const PlaceField, updated_leaf: Value) !Value {
            if (fields.len == 0) return updated_leaf;

            var parents: std.ArrayList(Value) = .empty;
            defer parents.deinit(self.ctx.allocator());
            var current = root;
            for (fields) |field| {
                try parents.append(self.ctx.allocator(), current);
                current = try self.appendInstruction(.{ .field_access = .{
                    .operand = current.id,
                    .field_index = field.index,
                    .field_type = field.type_id,
                } });
            }
            var updated = updated_leaf;
            var field_index = fields.len;
            while (field_index > 0) {
                field_index -= 1;
                updated = try self.appendInstruction(.{ .field_update = .{
                    .operand = parents.items[field_index].id,
                    .value = updated.id,
                    .field_index = fields[field_index].index,
                    .type_id = parents.items[field_index].type_id,
                } });
            }
            return updated;
        }

        fn callReturnType(call: CallOperation) structures.TypeId {
            return switch (call) {
                inline else => |operation| operation.return_type,
            };
        }

        fn lowerFallibleCall(self: *Self, call: CallOperation) !ConditionFlow {
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            try self.block_argument_types.append(self.ctx.allocator(), callReturnType(call));
            const success = try self.newBlock(argument_start, argument_start + 1);
            const failure = try self.newBlock(argument_start + 1, argument_start + 1);
            self.terminate(switch (call) {
                .direct => |direct| .{ .fallible_call = .{ .call = direct, .success = success, .failure = failure } },
                .indirect => |indirect| .{ .fallible_indirect_call = .{ .call = indirect, .success = success, .failure = failure } },
            });
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
                .callable => |callable| if (callable.is_fallible) blk: {
                    var flow = try self.lowerFallibleCall(callable.operation);
                    try self.finishCallExits(&flow, callable, call.span);
                    if (flow.success) |*success| {
                        const success_block = self.blocks.items[@intFromEnum(success.block)];
                        success.temporary = .{
                            .id = @enumFromInt(success_block.argument_start),
                            .type_id = callReturnType(callable.operation),
                        };
                    }
                    break :blk flow;
                } else self.reject(call.span, .if_condition_not_fallible),
            };
        }

        fn comparisonCondition(self: *Self, comparison: @FieldType(semantic.UnresolvedBody.Condition, "comparison")) !ConditionFlow {
            const lhs = try self.borrowValue(try self.value(comparison.operands.lhs.value), comparison.operands.lhs.span);
            if (lhs.type_id == .never) return .{ .success = null, .failure = null, .diverged = lhs };
            const rhs = try self.borrowValue(try self.value(comparison.operands.rhs.value), comparison.operands.rhs.span);
            if (rhs.type_id == .never) return .{ .success = null, .failure = null, .diverged = rhs };
            const operation: structures.PredicateOperation = switch (comparison.operation) {
                .lt, .gt, .le, .ge => blk: {
                    if (lhs.type_id != .int) return self.reject(comparison.operands.lhs.span, .{ .comparison_operand_not_int = lhs.type_id });
                    if (rhs.type_id != .int) return self.reject(comparison.operands.rhs.span, .{ .comparison_operand_not_int = rhs.type_id });
                    break :blk switch (comparison.operation) {
                        .lt => .lti,
                        .gt => .gti,
                        .le => .lei,
                        .ge => .gei,
                        .eq, .ne => unreachable,
                    };
                },
                .eq, .ne => blk: {
                    if (lhs.type_id != .int and lhs.type_id != .bool) {
                        return self.reject(comparison.operands.lhs.span, .{ .equality_operand_not_supported = lhs.type_id });
                    }
                    if (rhs.type_id != lhs.type_id) {
                        return self.reject(comparison.operands.rhs.span, .{ .equality_operand_type_mismatch = self.typeMismatch(lhs.type_id, rhs.type_id) });
                    }
                    break :blk switch (lhs.type_id) {
                        .int => if (comparison.operation == .eq) .eqi else .nei,
                        .bool => if (comparison.operation == .eq) .eqb else .neb,
                        else => unreachable,
                    };
                },
            };
            const branch_argument_start: u32 = @intCast(self.block_argument_types.items.len);
            const success = try self.newBlock(branch_argument_start, branch_argument_start);
            const failure = try self.newBlock(branch_argument_start, branch_argument_start);
            self.terminate(.{ .predicate_branch = .{
                .operation = operation,
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
            const operand = try self.borrowValue(try self.value(membership.operand.value), membership.operand.span);
            if (operand.type_id == .never) return .{ .success = null, .failure = null, .diverged = operand };
            const source_members = try self.type_interner.variantMembers(operand.type_id) orelse {
                return self.reject(membership.operand.span, .{ .variant_inspection_operand_not_variant = operand.type_id });
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
                .local = binding.local,
                .operand = operand,
                .target_type = try intersectTypes(self.type_interner, source_members, membership.target_type, self.ctx.allocator()),
                .annotation_type = binding.annotation_type,
                .span = binding.span,
            } else null;
            const temporary = if (operand.borrowed_type == null or operand.borrow_condition != null) operand else null;
            return .{
                .success = .{ .block = success, .state = state, .extraction = extraction, .temporary = temporary },
                .failure = .{ .block = failure, .state = state, .temporary = temporary },
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
                const tag_mapping = try self.appendExtractionTagMapping(extraction.operand.type_id, extraction.target_type);
                var extracted = try self.appendInstruction(.{ .variant_extract = .{
                    .operand = extraction.operand.id,
                    .target_type = extraction.target_type,
                    .tag_mapping = tag_mapping,
                } });
                if (extraction.target_type != .never) {
                    extracted.borrowed_type = extracted.type_id;
                    extracted = try self.ownValue(extracted, extraction.span);
                }
                if (extraction.target_type != .never and extraction.annotation_type != null) {
                    const expected = extraction.annotation_type.?;
                    const use = try self.coerceValue(extracted.id, extracted.type_id, expected) orelse
                        return self.reject(extraction.span, .{ .local_type_mismatch = self.typeMismatch(expected, extracted.type_id) });
                    if (use.coerce_to != null) {
                        extracted = try self.appendCoercion(use);
                    }
                }
                const index = @intFromEnum(extraction.local);
                std.debug.assert(self.local_values[index] == null);
                self.local_values[index] = extracted;
                self.local_mutable[index] = false;
                self.local_availability[index] = .available;
                if (extraction.target_type == .never) self.terminate(.diverge);
            }
            if (self.current_block != null) if (exit.temporary) |temporary| {
                try self.endTemporary(temporary, self.unresolved.blocks[@intFromEnum(self.unresolved.root_block)].span);
            };
        }

        fn mergeFlowExits(self: *Self, first_exit: ?FlowExit, second_exit: ?FlowExit) !?FlowExit {
            var first = first_exit orelse return second_exit;
            var second = second_exit orelse return first;
            try self.finishFlowExitEffects(&first);
            try self.finishFlowExitEffects(&second);
            std.debug.assert(first.extraction == null and second.extraction == null);
            const first_state = self.states.items[@intFromEnum(first.state)];
            const second_state = self.states.items[@intFromEnum(second.state)];
            std.debug.assert(first_state.values.len == second_state.values.len);

            var first_values: std.ArrayList(Value) = .empty;
            defer first_values.deinit(self.ctx.allocator());
            var second_values: std.ArrayList(Value) = .empty;
            defer second_values.deinit(self.ctx.allocator());
            var changed_slots: std.ArrayList(u32) = .empty;
            defer changed_slots.deinit(self.ctx.allocator());
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            for (first_state.values, second_state.values, 0..) |first_value, second_value, slot| {
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

            const values = try self.ctx.allocator().dupe(?Value, first_state.values);
            errdefer self.ctx.allocator().free(values);
            const availability = try self.ctx.allocator().dupe(Availability, first_state.availability);
            errdefer self.ctx.allocator().free(availability);
            for (changed_slots.items, argument_start..) |slot, argument| {
                values[slot] = .{ .id = @enumFromInt(argument), .type_id = self.block_argument_types.items[argument] };
            }
            for (availability, second_state.availability) |*output, right| output.* = joinAvailability(output.*, right);
            const state_id = try self.appendState(.{ .values = values, .availability = availability });
            return .{ .block = merged, .state = state_id };
        }

        fn finishFlowExitEffects(self: *Self, flow_exit: *FlowExit) !void {
            if (flow_exit.temporary == null) return;
            std.debug.assert(flow_exit.extraction == null);
            try self.enterFlowExit(flow_exit.*);
            flow_exit.state = try self.captureState();
            flow_exit.block = self.suspendBlock();
            flow_exit.temporary = null;
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
                const result = try self.block(expression.then_block);
                if (self.current_block != null) if (success.extraction) |extraction| {
                    try self.endLocal(@intFromEnum(extraction.local), extraction.span);
                };
                break :blk try self.valueExit(result);
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
            const then_is_borrowed = if (then_exit) |exit| exit.value.borrowed_type != null else false;
            const else_is_borrowed = if (else_exit) |exit| exit.value.borrowed_type != null else false;
            const any_borrowed = then_is_borrowed or else_is_borrowed;
            const all_borrowed = (then_exit == null or then_is_borrowed) and (else_exit == null or else_is_borrowed);
            const has_conditional_borrow = (then_exit != null and then_exit.?.value.borrow_condition != null) or
                (else_exit != null and else_exit.?.value.borrow_condition != null);
            const needs_borrow_condition = any_borrowed and (has_conditional_borrow or !all_borrowed);
            try self.block_argument_types.append(self.ctx.allocator(), joined);
            if (needs_borrow_condition) try self.block_argument_types.append(self.ctx.allocator(), .bool);
            var changed_slots = try self.changedStateSlots(baseline, then_exit, else_exit);
            defer changed_slots.deinit(self.ctx.allocator());
            for (changed_slots.items) |slot| {
                const source = if (then_exit) |exit| self.states.items[@intFromEnum(exit.state)].values[slot].? else self.states.items[@intFromEnum(else_exit.?.state)].values[slot].?;
                try self.block_argument_types.append(self.ctx.allocator(), source.type_id);
            }
            const merge_block = try self.newBlock(argument_start, @intCast(self.block_argument_types.items.len));
            if (then_exit) |exit| try self.setConditionalTerminator(merge_block, exit, joined, changed_slots.items, needs_borrow_condition);
            if (else_exit) |exit| try self.setConditionalTerminator(merge_block, exit, joined, changed_slots.items, needs_borrow_condition);

            const output_state = try self.conditionalState(baseline, then_exit, else_exit, changed_slots.items, argument_start + 1 + @intFromBool(needs_borrow_condition));
            var contains_transfer = false;
            var borrow_root: ?semantic.UnresolvedBody.LocalId = null;
            var borrowed_source: ?structures.TypeId = null;
            if (then_exit) |exit| {
                contains_transfer = exit.value.explicit_transfer;
                if (exit.value.borrowed_type) |source_type| {
                    borrowed_source = source_type;
                    borrow_root = exit.value.borrow_root;
                }
            }
            if (else_exit) |exit| {
                contains_transfer = contains_transfer or exit.value.explicit_transfer;
                if (exit.value.borrowed_type) |source_type| {
                    if (borrowed_source) |previous| {
                        if (previous != source_type) borrowed_source = joined;
                    } else {
                        borrowed_source = source_type;
                    }
                    borrow_root = laterBorrowRoot(borrow_root, exit.value.borrow_root);
                }
            }
            self.enterBlock(merge_block);
            self.restoreState(output_state);
            return .{
                .id = @enumFromInt(argument_start),
                .type_id = joined,
                .borrowed_type = borrowed_source,
                .borrow_condition = if (needs_borrow_condition) @enumFromInt(argument_start + 1) else null,
                .borrow_root = borrow_root,
                .explicit_transfer = contains_transfer,
            };
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
            const baseline_state = self.states.items[@intFromEnum(baseline)].values;
            const first_state = self.states.items[@intFromEnum(first.?.state)].values;
            const second_state = self.states.items[@intFromEnum(second.?.state)].values;
            for (baseline_state, first_state, second_state, 0..) |initial, left, right, slot| {
                if (initial == null) continue;
                std.debug.assert(left != null and right != null);
                std.debug.assert(left.?.type_id == right.?.type_id);
                if (left.?.id != right.?.id) try slots.append(self.ctx.allocator(), @intCast(slot));
            }
            return slots;
        }

        fn setConditionalTerminator(
            self: *Self,
            target: structures.FunctionBlockId,
            exit: ValueExit,
            result_type: structures.TypeId,
            changed_slots: []const u32,
            include_borrow_condition: bool,
        ) !void {
            if (!include_borrow_condition) {
                self.setBlockTerminator(exit.block, .{ .branch = try self.conditionalBranch(target, exit, result_type, changed_slots, null) });
                return;
            }
            const argument_start: u32 = @intCast(self.block_argument_types.items.len);
            const edge = try self.newBlock(argument_start, argument_start);
            self.setBlockTerminator(exit.block, .{ .branch = self.emptyBranch(edge) });
            self.enterBlock(edge);
            const borrowed_on_path = exit.value.borrow_condition orelse (try self.appendInstruction(.{
                .constb = exit.value.borrowed_type != null,
            })).id;
            self.terminate(.{ .branch = try self.conditionalBranch(target, exit, result_type, changed_slots, borrowed_on_path) });
        }

        fn conditionalBranch(
            self: *Self,
            target: structures.FunctionBlockId,
            exit: ValueExit,
            result_type: structures.TypeId,
            changed_slots: []const u32,
            borrow_condition: ?structures.FunctionValueId,
        ) !structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            const result = (try self.coerceValue(exit.value.id, exit.value.type_id, result_type)) orelse unreachable;
            try self.branch_arguments.append(self.ctx.allocator(), result);
            if (borrow_condition) |borrow_predicate| try self.branch_arguments.append(self.ctx.allocator(), .{ .value = borrow_predicate });
            const state = self.states.items[@intFromEnum(exit.state)].values;
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
            const baseline_state = self.states.items[@intFromEnum(baseline)];
            const values = try self.ctx.allocator().dupe(?Value, baseline_state.values);
            errdefer self.ctx.allocator().free(values);
            const source_state = self.states.items[@intFromEnum(source)];
            for (values, source_state.values) |*output, value_on_path| {
                if (output.* != null) output.* = value_on_path.?;
            }
            for (changed_slots, argument_start..) |slot, argument| {
                values[slot] = .{ .id = @enumFromInt(argument), .type_id = self.block_argument_types.items[argument] };
            }
            const availability = try self.ctx.allocator().dupe(Availability, source_state.availability);
            errdefer self.ctx.allocator().free(availability);
            if (first != null and second != null) {
                const other = self.states.items[@intFromEnum(second.?.state)].availability;
                for (availability, other) |*output, right| output.* = joinAvailability(output.*, right);
            }
            return self.appendState(.{ .values = values, .availability = availability });
        }

        fn joinAvailability(left: Availability, right: Availability) Availability {
            if (left == right) return left;
            if (left == .unbound or right == .unbound) return .unbound;
            return .maybe_transferred;
        }

        fn appendInstruction(self: *Self, instruction: structures.FunctionInstruction) !Value {
            std.debug.assert(self.current_block != null);
            const instruction_id = std.math.cast(u31, self.instruction_count) orelse return error.AnalysisTooLarge;
            self.instruction_count += 1;
            try self.blocks.items[@intFromEnum(self.current_block.?)].instructions.append(self.ctx.allocator(), .{
                .id = instruction_id,
                .operation = instruction,
            });
            // The final block-argument count and instruction layout are known
            // only after CFG construction and transformation. Temporary
            // high-bit IDs remain stable while block instructions are edited;
            // finish() rewrites them into the published contiguous namespace.
            const id: structures.FunctionValueId = @enumFromInt(@as(u32, 1) << 31 | @as(u32, instruction_id));
            return .{ .id = id, .type_id = instruction.resultType() };
        }

        fn newBlock(self: *Self, argument_start: u32, argument_end: u32) !structures.FunctionBlockId {
            const id: structures.FunctionBlockId = @enumFromInt(self.blocks.items.len);
            try self.blocks.append(self.ctx.allocator(), .{
                .argument_start = argument_start,
                .argument_end = argument_end,
            });
            return id;
        }

        fn enterBlock(self: *Self, block_id: structures.FunctionBlockId) void {
            std.debug.assert(self.current_block == null);
            const block_value = &self.blocks.items[@intFromEnum(block_id)];
            std.debug.assert(block_value.layout_index == null);
            block_value.layout_index = self.block_layout_count;
            self.block_layout_count += 1;
            self.current_block = block_id;
        }

        fn terminate(self: *Self, terminator: structures.FunctionTerminator) void {
            self.setBlockTerminator(self.suspendBlock(), terminator);
        }

        fn suspendBlock(self: *Self) structures.FunctionBlockId {
            const block_id = self.current_block.?;
            self.current_block = null;
            return block_id;
        }

        fn setBlockTerminator(self: *Self, block_id: structures.FunctionBlockId, terminator: structures.FunctionTerminator) void {
            const block_value = &self.blocks.items[@intFromEnum(block_id)];
            std.debug.assert(block_value.terminator == null);
            block_value.terminator = terminator;
        }

        fn emptyBranch(self: *const Self, target: structures.FunctionBlockId) structures.FunctionBranch {
            const start: u32 = @intCast(self.branch_arguments.items.len);
            return .{ .target = target, .arguments = .{ .start = start, .end = start } };
        }

        fn finish(self: *Self) !structures.FunctionBodyAnalysis {
            std.debug.assert(self.current_block == null);
            const gpa = self.ctx.allocator();
            const argument_count: u32 = @intCast(std.math.cast(u31, self.block_argument_types.items.len) orelse return error.AnalysisTooLarge);
            const instruction_values = try gpa.alloc(structures.FunctionValueId, self.instruction_count);
            defer gpa.free(instruction_values);
            const block_layout = try gpa.alloc(structures.FunctionBlockId, self.blocks.items.len);
            defer gpa.free(block_layout);
            std.debug.assert(self.block_layout_count == self.blocks.items.len);
            for (self.blocks.items, 0..) |block_value, block_index| {
                const layout_index = block_value.layout_index orelse unreachable;
                block_layout[layout_index] = @enumFromInt(block_index);
            }
            const instructions = try gpa.alloc(structures.FunctionInstruction, self.instruction_count);
            errdefer gpa.free(instructions);
            const blocks = try gpa.alloc(structures.FunctionBlock, self.blocks.items.len);
            errdefer gpa.free(blocks);
            var instruction_index: u32 = 0;
            for (block_layout) |block_id| {
                const block_index = @intFromEnum(block_id);
                const build_block = self.blocks.items[block_index];
                const instruction_start = instruction_index;
                for (build_block.instructions.items) |build_instruction| {
                    instructions[instruction_index] = build_instruction.operation;
                    instruction_values[build_instruction.id] = @enumFromInt(argument_count + instruction_index);
                    instruction_index += 1;
                }
                blocks[block_index] = .{
                    .argument_start = build_block.argument_start,
                    .argument_end = build_block.argument_end,
                    .instruction_start = instruction_start,
                    .instruction_end = instruction_index,
                    .terminator = build_block.terminator orelse unreachable,
                };
            }
            std.debug.assert(instruction_index == self.instruction_count);
            normalizeInstructions(instructions, instruction_values);
            normalizeValueUses(self.call_arguments.items, instruction_values);
            for (self.struct_field_values.items) |*field| field.value = normalizeValue(field.value, instruction_values);
            normalizeValueUses(self.branch_arguments.items, instruction_values);
            normalizeTerminators(blocks, instruction_values);
            const block_argument_types = try self.block_argument_types.toOwnedSlice(gpa);
            errdefer gpa.free(block_argument_types);
            const variant_coercion_tags = try self.variant_coercion_tags.toOwnedSlice(gpa);
            errdefer gpa.free(variant_coercion_tags);
            const struct_field_values = try self.struct_field_values.toOwnedSlice(gpa);
            errdefer gpa.free(struct_field_values);
            const call_arguments = try self.call_arguments.toOwnedSlice(gpa);
            errdefer gpa.free(call_arguments);
            const branches = try self.branch_arguments.toOwnedSlice(gpa);
            const body: structures.FunctionBodyAnalysis = .{
                .return_type = self.return_type,
                .is_fallible = self.is_fallible,
                .block_argument_types = block_argument_types,
                .variant_coercion_tags = variant_coercion_tags,
                .struct_field_values = struct_field_values,
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

fn normalizeValue(value: structures.FunctionValueId, instruction_values: []const structures.FunctionValueId) structures.FunctionValueId {
    const instruction_mask: u32 = 1 << 31;
    const raw = @intFromEnum(value);
    if (raw & instruction_mask == 0) return value;
    return instruction_values[raw & ~instruction_mask];
}

fn normalizeValueUse(value_use: *structures.FunctionValueUse, instruction_values: []const structures.FunctionValueId) void {
    value_use.value = normalizeValue(value_use.value, instruction_values);
}

fn normalizeValueUses(value_uses: []structures.FunctionValueUse, instruction_values: []const structures.FunctionValueId) void {
    for (value_uses) |*value_use| normalizeValueUse(value_use, instruction_values);
}

fn normalizeInstructions(instructions: []structures.FunctionInstruction, instruction_values: []const structures.FunctionValueId) void {
    for (instructions) |*instruction| switch (instruction.*) {
        .consti, .constb, .const_unit, .const_none, .function_ref, .struct_init, .call_mut_argument => {},
        .variant_coerce, .variant_extract, .callable_coerce => |*operation| operation.operand = normalizeValue(operation.operand, instruction_values),
        .field_access => |*operation| operation.operand = normalizeValue(operation.operand, instruction_values),
        .field_update => |*operation| {
            operation.operand = normalizeValue(operation.operand, instruction_values);
            operation.value = normalizeValue(operation.value, instruction_values);
        },
        .mut_parameter_write => |*operation| operation.value = normalizeValue(operation.value, instruction_values),
        .call => {},
        .indirect_call => |*call| call.target = normalizeValue(call.target, instruction_values),
        .variant_tag, .exit, .negi => |*operand| operand.* = normalizeValue(operand.*, instruction_values),
        .addi, .subi, .muli, .divsi => |*operands| {
            operands.lhs = normalizeValue(operands.lhs, instruction_values);
            operands.rhs = normalizeValue(operands.rhs, instruction_values);
        },
    };
}

fn normalizeTerminators(blocks: []structures.FunctionBlock, instruction_values: []const structures.FunctionValueId) void {
    for (blocks) |*block_value| switch (block_value.terminator) {
        .branch, .fallible_call, .return_failure, .diverge => {},
        .fallible_indirect_call => |*fallible| fallible.call.target = normalizeValue(fallible.call.target, instruction_values),
        .predicate_branch => |*predicate| {
            predicate.operands.lhs = normalizeValue(predicate.operands.lhs, instruction_values);
            predicate.operands.rhs = normalizeValue(predicate.operands.rhs, instruction_values);
        },
        .return_unit => {},
        .return_value => |*value_use| normalizeValueUse(value_use, instruction_values),
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
    if (try semantic.canWidenTo(type_interner, left, right)) return right;
    if (try semantic.canWidenTo(type_interner, right, left)) return left;

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

fn containsType(types: []const structures.TypeId, needle: structures.TypeId) bool {
    for (types) |type_id| {
        if (type_id == needle) return true;
    }
    return false;
}
