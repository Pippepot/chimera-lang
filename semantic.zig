const std = @import("std");
const structures = @import("structures.zig");

pub const Issue = struct {
    span: structures.SourceSpan,
    kind: structures.Diagnostic.Kind,
};

fn SemanticResult(comptime Success: type) type {
    return union(enum) {
        success: Success,
        unsupported: Issue,
    };
}

pub const SignatureResult = SemanticResult(structures.FunctionSignature);

/// Query-local source graph after syntax and lexical validation. Parameters
/// precede expressions in the value namespace. Blocks and statements preserve
/// evaluation order; references to an earlier binding reuse its value. Source
/// names are borrowed only until typing finishes. Loop-control edges remain
/// structural until typing; CFG blocks belong to typed IR.
pub const UnresolvedBody = struct {
    parameter_count: u32,
    expressions: []Expression,
    blocks: []Block,
    statements: []Statement,
    call_arguments: []ValueUse,
    conditional_outputs: []ConditionalOutput,
    loop_values: []ValueId,
    root_block: BlockId,

    pub const ValueId = enum(u32) { _ };
    pub const BlockId = enum(u32) { _ };
    pub const ValueUse = struct { value: ValueId, span: structures.SourceSpan };
    pub const BinaryOperands = struct { lhs: ValueUse, rhs: ValueUse };
    pub const StatementRange = struct { start: u32, end: u32 };
    pub const ConditionalOutputRange = struct { start: u32, end: u32 };
    pub const Block = struct {
        statements: StatementRange,
        result: ?ValueId,
        span: structures.SourceSpan,
    };
    pub const Statement = union(enum) {
        discard: ValueId,
        break_loop: struct { value: ValueId, arguments: structures.FunctionValueRange },
        continue_loop: structures.FunctionValueRange,
        return_nothing: structures.SourceSpan,
        return_value: ValueUse,
    };
    pub const PredicateOperation = enum { lt, gt, le, ge, eq, ne };
    pub const Condition = struct {
        operation: PredicateOperation,
        operands: BinaryOperands,
    };
    pub const AssignmentOperation = enum { replace, add, subtract, multiply, divide };
    pub const ConditionalOutput = struct {
        then_value: ValueId,
        else_value: ValueId,
        result: ValueId,
    };
    pub const Expression = struct {
        operation: Operation,
        span: structures.SourceSpan,

        pub const Operation = union(enum) {
            integer: i32,
            unit,
            none,
            annotation: struct { value: ValueUse, type_id: structures.TypeId },
            assignment: struct { target: ValueUse, value: ValueUse, operation: AssignmentOperation },
            call: struct { name: []const u8, arguments: structures.FunctionValueRange },
            negate: ValueUse,
            add: BinaryOperands,
            subtract: BinaryOperands,
            multiply: BinaryOperands,
            divide: BinaryOperands,
            if_else: struct {
                condition: Condition,
                then_block: BlockId,
                else_block: BlockId,
                outputs: ConditionalOutputRange,
            },
            conditional_output: ValueId,
            loop: struct {
                body: BlockId,
                initial_values: structures.FunctionValueRange,
                input_values: structures.FunctionValueRange,
                output_values: structures.FunctionValueRange,
                repeat_values: structures.FunctionValueRange,
            },
            loop_input: ValueId,
            loop_output: ValueId,
        };
    };

    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        gpa.free(self.expressions);
        gpa.free(self.blocks);
        gpa.free(self.statements);
        gpa.free(self.call_arguments);
        gpa.free(self.conditional_outputs);
        gpa.free(self.loop_values);
        self.* = undefined;
    }
};

pub fn buildUnresolvedBody(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    kind: structures.ItemKind,
    parameter_count: usize,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(UnresolvedBody) {
    var builder: ExpressionBuilder(@TypeOf(type_interner)) = .{
        .ast = ast,
        .source = source,
        .parameter_count = @intCast(parameter_count),
        .type_interner = type_interner,
        .gpa = gpa,
    };
    defer builder.deinit();
    builder.build(declaration, kind) catch |err| switch (err) {
        error.SourceRejected => return .{ .unsupported = builder.issue.? },
        else => return err,
    };
    return .{ .success = try builder.finish() };
}

fn ExpressionBuilder(comptime TypeInterner: type) type {
    return struct {
        const Self = @This();
        const ValueId = UnresolvedBody.ValueId;
        const Local = struct {
            value: ValueId,
            mutable: bool,
        };
        const MutableState = struct {
            name: []const u8,
            incoming: ValueId,
            then_value: ValueId = undefined,
            else_value: ValueId = undefined,
        };
        const LoopContext = struct { name_start: u32, name_end: u32 };

        ast: *const structures.Ast,
        source: []const u8,
        parameter_count: u32,
        type_interner: TypeInterner,
        gpa: std.mem.Allocator,
        locals: std.StringHashMapUnmanaged(Local) = .empty,
        local_names: std.ArrayList([]const u8) = .empty,
        expressions: std.ArrayList(UnresolvedBody.Expression) = .empty,
        blocks: std.ArrayList(UnresolvedBody.Block) = .empty,
        statements: std.ArrayList(UnresolvedBody.Statement) = .empty,
        call_arguments: std.ArrayList(UnresolvedBody.ValueUse) = .empty,
        conditional_outputs: std.ArrayList(UnresolvedBody.ConditionalOutput) = .empty,
        loop_values: std.ArrayList(ValueId) = .empty,
        loop_state_names: std.ArrayList([]const u8) = .empty,
        loop_stack: std.ArrayList(LoopContext) = .empty,
        scratch: std.ArrayList(ValueId) = .empty,
        root_block: ?UnresolvedBody.BlockId = null,
        issue: ?Issue = null,

        fn deinit(self: *Self) void {
            self.locals.deinit(self.gpa);
            self.local_names.deinit(self.gpa);
            self.expressions.deinit(self.gpa);
            self.blocks.deinit(self.gpa);
            self.statements.deinit(self.gpa);
            self.call_arguments.deinit(self.gpa);
            self.conditional_outputs.deinit(self.gpa);
            self.loop_values.deinit(self.gpa);
            self.loop_state_names.deinit(self.gpa);
            self.loop_stack.deinit(self.gpa);
            self.scratch.deinit(self.gpa);
        }

        fn reject(self: *Self, node: structures.Node.Index, kind: structures.Diagnostic.Kind) error{SourceRejected} {
            std.debug.assert(self.issue == null);
            self.issue = issueAt(self.ast, node.index(), kind);
            return error.SourceRejected;
        }

        fn build(self: *Self, declaration: u32, kind: structures.ItemKind) anyerror!void {
            switch (kind) {
                .top_level_entry => try self.buildEntry(declaration),
                .function => try self.buildFunction(declaration),
            }
        }

        fn buildEntry(self: *Self, declaration: u32) !void {
            const root = self.ast.nodes[declaration];
            std.debug.assert(root.tag == .block);
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            for (self.ast.node_refs[root.data.ref.start..root.data.ref.end]) |child| {
                if (self.ast.nodes[child.index()].tag == .static_binding) continue;
                try body_statements.append(self.gpa, try self.buildStatement(child, true));
            }
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, root.token_index));
        }

        fn buildFunction(self: *Self, declaration: u32) !void {
            const binding = self.ast.nodes[declaration];
            const parts = functionParts(self.ast, declaration);
            const signature = self.ast.nodes[parts.signature.index()];
            const parameters = self.ast.nodeList(signature.data.node_node.a);
            std.debug.assert(parameters.len == self.parameter_count);
            for (parameters, 0..) |parameter_index, index| {
                const span = tokenSpan(self.ast, self.ast.nodes[parameter_index.index()].token_index);
                const name = self.source[span.start..span.end];
                try self.locals.put(self.gpa, name, .{ .value = @enumFromInt(index), .mutable = false });
                try self.local_names.append(self.gpa, name);
            }

            const body = self.ast.nodes[parts.body.index()];
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            if (body.tag == .block) {
                for (self.ast.node_refs[body.data.ref.start..body.data.ref.end]) |statement| {
                    try body_statements.append(self.gpa, try self.buildStatement(statement, false));
                }
            } else {
                try body_statements.append(self.gpa, try self.buildStatement(parts.body, false));
            }
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, binding.token_index));
        }

        fn buildStatement(self: *Self, index: structures.Node.Index, comptime is_entry: bool) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            return switch (node.tag) {
                .const_binding, .var_binding => .{ .discard = try self.appendBinding(index) },
                .return_nothing => if (is_entry)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_nothing = span },
                .return_expr => if (is_entry)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_value = try self.appendUse(node.data.node) },
                .break_nothing, .break_expr => try self.buildBreak(index),
                .continue_expr => try self.buildContinue(index),
                else => .{ .discard = try self.append(index) },
            };
        }

        fn buildBreak(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            if (self.loop_stack.items.len == 0) return self.reject(index, .break_outside_loop);
            const node = self.ast.nodes[index.index()];
            const value = if (node.tag == .break_expr)
                try self.append(node.data.node)
            else
                try self.appendExpression(index, .unit);
            return .{ .break_loop = .{
                .value = value,
                .arguments = try self.captureLoopValues(),
            } };
        }

        fn buildContinue(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            if (self.loop_stack.items.len == 0) return self.reject(index, .continue_outside_loop);
            return .{ .continue_loop = try self.captureLoopValues() };
        }

        fn captureLoopValues(self: *Self) !structures.FunctionValueRange {
            const context = self.loop_stack.getLast();
            const start: u32 = @intCast(self.loop_values.items.len);
            for (self.loop_state_names.items[context.name_start..context.name_end]) |name| {
                try self.loop_values.append(self.gpa, self.locals.get(name).?.value);
            }
            return .{ .start = start, .end = @intCast(self.loop_values.items.len) };
        }

        fn appendBinding(self: *Self, index: structures.Node.Index) anyerror!ValueId {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (self.locals.contains(name)) return self.reject(index, .duplicate_local_binding);
            const annotation = node.data.node_node.a.unwrap();
            const expected = if (annotation) |type_node| try self.bindingType(type_node) else null;
            var value = try self.append(node.data.node_node.b);
            if (expected) |type_id| {
                value = try self.appendExpression(annotation.?, .{ .annotation = .{ .value = .{
                    .value = value,
                    .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                }, .type_id = type_id } });
            }
            try self.locals.put(self.gpa, name, .{ .value = value, .mutable = node.tag == .var_binding });
            try self.local_names.append(self.gpa, name);
            return value;
        }

        fn bindingType(self: *Self, node: structures.Node.Index) !structures.TypeId {
            const result = try analyzeType(self.ast, self.source, node, self.type_interner, self.gpa, .local_type_not_supported);
            switch (result) {
                .success => |type_id| return type_id,
                .unsupported => |issue| {
                    self.issue = issue;
                    return error.SourceRejected;
                },
            }
        }

        fn append(self: *Self, index: structures.Node.Index) anyerror!ValueId {
            const node = self.ast.nodes[index.index()];
            switch (node.tag) {
                .number_literal => return self.appendInteger(index),
                .unit_literal => return self.appendExpression(index, .unit),
                .none_literal => return self.appendExpression(index, .none),
                .call => return self.appendCall(index),
                .identifier => {
                    const span = tokenSpan(self.ast, node.token_index);
                    const name = self.source[span.start..span.end];
                    if (self.locals.get(name)) |local| return local.value;
                    if (std.mem.eql(u8, name, "unit")) return self.appendExpression(index, .unit);
                    return self.reject(index, .unknown_value);
                },
                .neg => return self.appendExpression(index, .{ .negate = try self.appendUse(node.data.node) }),
                .add, .sub, .mul, .div => return self.appendBinary(index),
                .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => return self.appendAssignment(index),
                .@"if", .if_else => return self.appendIf(index),
                .loop => return self.appendLoop(index),
                else => return self.reject(index, .expression_not_supported),
            }
        }

        fn appendUse(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            return .{
                .value = try self.append(index),
                .span = nodeFocusSpan(self.ast, index),
            };
        }

        fn appendLoop(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const loop_id = try self.appendExpression(index, .{ .loop = undefined });

            var states: std.ArrayList(MutableState) = .empty;
            defer states.deinit(self.gpa);
            for (self.local_names.items) |name| {
                const local = self.locals.get(name).?;
                if (local.mutable) try states.append(self.gpa, .{ .name = name, .incoming = local.value });
            }

            const initial_start: u32 = @intCast(self.loop_values.items.len);
            for (states.items) |state| try self.loop_values.append(self.gpa, state.incoming);
            const initial_values: structures.FunctionValueRange = .{ .start = initial_start, .end = @intCast(self.loop_values.items.len) };

            const input_start: u32 = @intCast(self.loop_values.items.len);
            for (states.items) |state| {
                const input = try self.appendExpression(index, .{ .loop_input = loop_id });
                try self.loop_values.append(self.gpa, input);
                self.locals.getPtr(state.name).?.value = input;
            }
            const input_values: structures.FunctionValueRange = .{ .start = input_start, .end = @intCast(self.loop_values.items.len) };

            const name_mark = self.loop_state_names.items.len;
            defer self.loop_state_names.shrinkRetainingCapacity(name_mark);
            for (states.items) |state| try self.loop_state_names.append(self.gpa, state.name);
            try self.loop_stack.append(self.gpa, .{ .name_start = @intCast(name_mark), .name_end = @intCast(self.loop_state_names.items.len) });
            const body = try self.buildBranch(node.data.node);
            const repeat_values = try self.captureLoopValues();
            _ = self.loop_stack.pop();

            self.restoreMutableValues(states.items);
            const output_start: u32 = @intCast(self.loop_values.items.len);
            for (states.items) |state| {
                const output = try self.appendExpression(index, .{ .loop_output = loop_id });
                try self.loop_values.append(self.gpa, output);
                self.locals.getPtr(state.name).?.value = output;
            }
            const output_values: structures.FunctionValueRange = .{ .start = output_start, .end = @intCast(self.loop_values.items.len) };
            self.expressions.items[@intFromEnum(loop_id) - self.parameter_count].operation = .{ .loop = .{
                .body = body,
                .initial_values = initial_values,
                .input_values = input_values,
                .output_values = output_values,
                .repeat_values = repeat_values,
            } };
            return loop_id;
        }

        fn appendInteger(self: *Self, index: structures.Node.Index) !ValueId {
            const span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index);
            const literal = self.source[span.start..span.end];
            for (literal) |byte| {
                if (!std.ascii.isDigit(byte)) return self.reject(index, .integer_literal_not_decimal);
            }
            const value = std.fmt.parseInt(i32, literal, 10) catch return self.reject(index, .integer_literal_out_of_range);
            return self.appendExpression(index, .{ .integer = value });
        }

        fn appendBinary(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const operands: UnresolvedBody.BinaryOperands = .{
                .lhs = try self.appendUse(node.data.node_node.a),
                .rhs = try self.appendUse(node.data.node_node.b),
            };
            const operation: UnresolvedBody.Expression.Operation = switch (node.tag) {
                .add => .{ .add = operands },
                .sub => .{ .subtract = operands },
                .mul => .{ .multiply = operands },
                .div => .{ .divide = operands },
                else => unreachable,
            };
            return self.appendExpression(index, operation);
        }

        fn appendAssignment(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const target_node = self.ast.nodes[node.data.node_node.a.index()];
            if (target_node.tag != .identifier) return self.reject(node.data.node_node.a, .assignment_target_not_local);
            const span = tokenSpan(self.ast, target_node.token_index);
            const name = self.source[span.start..span.end];
            const local = self.locals.get(name) orelse return self.reject(node.data.node_node.a, .unknown_value);
            if (!local.mutable) return self.reject(node.data.node_node.a, .assignment_to_immutable);
            const value = try self.append(node.data.node_node.b);
            const assigned = try self.appendExpression(index, .{ .assignment = .{
                .target = .{ .value = local.value, .span = span },
                .value = .{ .value = value, .span = nodeFocusSpan(self.ast, node.data.node_node.b) },
                .operation = switch (node.tag) {
                    .assign => .replace,
                    .add_assign => .add,
                    .sub_assign => .subtract,
                    .mul_assign => .multiply,
                    .div_assign => .divide,
                    else => unreachable,
                },
            } });
            self.locals.getPtr(name).?.value = assigned;
            return assigned;
        }

        fn appendIf(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const condition_index, const then_index, const else_index = switch (node.tag) {
                .@"if" => .{ node.data.node_node.a, node.data.node_node.b, @as(?structures.Node.Index, null) },
                .if_else => blk: {
                    const parts = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
                    std.debug.assert(parts.len == 3);
                    break :blk .{ parts[0], parts[1], parts[2] };
                },
                else => unreachable,
            };
            const condition = try self.buildCondition(condition_index);
            var states: std.ArrayList(MutableState) = .empty;
            defer states.deinit(self.gpa);
            for (self.local_names.items) |name| {
                const local = self.locals.get(name).?;
                if (local.mutable) try states.append(self.gpa, .{ .name = name, .incoming = local.value });
            }
            const then_block = try self.buildBranch(then_index);
            for (states.items) |*state| state.then_value = self.locals.get(state.name).?.value;
            self.restoreMutableValues(states.items);
            const else_block = if (else_index) |explicit_else|
                try self.buildBranch(explicit_else)
            else
                try self.buildUnitBranch(index);
            for (states.items) |*state| state.else_value = self.locals.get(state.name).?.value;
            self.restoreMutableValues(states.items);

            const output_start: u32 = @intCast(self.conditional_outputs.items.len);
            for (states.items) |state| {
                if (state.then_value == state.incoming and state.else_value == state.incoming) continue;
                try self.conditional_outputs.append(self.gpa, .{
                    .then_value = state.then_value,
                    .else_value = state.else_value,
                    .result = undefined,
                });
            }
            const output_end: u32 = @intCast(self.conditional_outputs.items.len);
            const conditional = try self.appendExpression(index, .{ .if_else = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
                .outputs = .{ .start = output_start, .end = output_end },
            } });
            var output_index = output_start;
            for (states.items) |state| {
                if (state.then_value == state.incoming and state.else_value == state.incoming) continue;
                const output = try self.appendExpression(index, .{ .conditional_output = conditional });
                self.conditional_outputs.items[output_index].result = output;
                self.locals.getPtr(state.name).?.value = output;
                output_index += 1;
            }
            std.debug.assert(output_index == output_end);
            return conditional;
        }

        fn restoreMutableValues(self: *Self, states: []const MutableState) void {
            for (states) |state| self.locals.getPtr(state.name).?.value = state.incoming;
        }

        fn buildCondition(self: *Self, index: structures.Node.Index) !UnresolvedBody.Condition {
            const node = self.ast.nodes[index.index()];
            const operation: UnresolvedBody.PredicateOperation = switch (node.tag) {
                .lt => .lt,
                .gt => .gt,
                .le => .le,
                .ge => .ge,
                .eq => .eq,
                .ne => .ne,
                else => return self.rejectCondition(index),
            };
            return .{
                .operation = operation,
                .operands = .{ .lhs = try self.appendUse(node.data.node_node.a), .rhs = try self.appendUse(node.data.node_node.b) },
            };
        }

        fn rejectCondition(self: *Self, index: structures.Node.Index) error{SourceRejected} {
            const node = self.ast.nodes[index.index()];
            const form = if (node.tag == .const_binding or node.tag == .var_binding) node.data.node_node.b else index;
            const kind: structures.Diagnostic.Kind = if (isFallibleExpression(self.ast.nodes[form.index()].tag))
                .fallible_condition_not_supported
            else
                .if_condition_not_fallible;
            return self.reject(form, kind);
        }

        fn buildBranch(self: *Self, index: structures.Node.Index) !UnresolvedBody.BlockId {
            const scope_mark = self.local_names.items.len;
            defer self.restoreScope(scope_mark);

            const node = self.ast.nodes[index.index()];
            if (node.tag != .block) {
                if (node.tag == .return_nothing or node.tag == .return_expr or node.tag == .break_nothing or node.tag == .break_expr or node.tag == .continue_expr) {
                    var statements = [_]UnresolvedBody.Statement{try self.buildStatement(index, false)};
                    return self.finishBlock(&statements, null, tokenSpan(self.ast, node.token_index));
                }
                return self.finishBlock(&.{}, try self.append(index), tokenSpan(self.ast, node.token_index));
            }

            const children = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
            if (children.len == 0) return self.buildUnitBranch(index);

            var statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer statements.deinit(self.gpa);
            for (children[0 .. children.len - 1]) |statement| {
                try statements.append(self.gpa, try self.buildStatement(statement, false));
            }
            const last = children[children.len - 1];
            const last_node = self.ast.nodes[last.index()];
            const result: ?ValueId = switch (last_node.tag) {
                .const_binding, .var_binding, .return_nothing, .return_expr, .break_nothing, .break_expr, .continue_expr => blk: {
                    try statements.append(self.gpa, try self.buildStatement(last, false));
                    break :blk null;
                },
                else => try self.append(last),
            };
            if (result == null and (last_node.tag == .const_binding or last_node.tag == .var_binding)) {
                return self.finishBlock(statements.items, try self.appendExpression(index, .unit), tokenSpan(self.ast, node.token_index));
            }
            return self.finishBlock(statements.items, result, tokenSpan(self.ast, node.token_index));
        }

        fn buildUnitBranch(self: *Self, index: structures.Node.Index) !UnresolvedBody.BlockId {
            return self.finishBlock(&.{}, try self.appendExpression(index, .unit), tokenSpan(self.ast, self.ast.nodes[index.index()].token_index));
        }

        fn finishBlock(
            self: *Self,
            pending: []const UnresolvedBody.Statement,
            result: ?ValueId,
            span: structures.SourceSpan,
        ) !UnresolvedBody.BlockId {
            const start: u32 = @intCast(self.statements.items.len);
            try self.statements.appendSlice(self.gpa, pending);
            const id: UnresolvedBody.BlockId = @enumFromInt(self.blocks.items.len);
            try self.blocks.append(self.gpa, .{
                .statements = .{ .start = start, .end = @intCast(self.statements.items.len) },
                .result = result,
                .span = span,
            });
            return id;
        }

        fn restoreScope(self: *Self, mark: usize) void {
            while (self.local_names.items.len > mark) {
                const name = self.local_names.pop().?;
                std.debug.assert(self.locals.remove(name));
            }
        }

        fn appendCall(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const callee_index = node.data.node_node.a;
            const callee = self.ast.nodes[callee_index.index()];
            if (callee.tag != .identifier) return self.reject(index, .expression_not_supported);
            const span = tokenSpan(self.ast, callee.token_index);
            const name = self.source[span.start..span.end];
            if (!std.mem.eql(u8, name, "exit") and self.locals.contains(name)) return self.reject(callee_index, .value_not_callable);
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            for (self.ast.nodeList(node.data.node_node.b)) |argument| {
                const value = try self.append(argument);
                try self.scratch.append(self.gpa, value);
            }
            const start: u32 = @intCast(self.call_arguments.items.len);
            for (self.ast.nodeList(node.data.node_node.b), self.scratch.items[scratch_start..]) |argument, value| {
                try self.call_arguments.append(self.gpa, .{
                    .value = value,
                    .span = nodeFocusSpan(self.ast, argument),
                });
            }
            return self.appendExpression(callee_index, .{ .call = .{
                .name = name,
                .arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) },
            } });
        }

        fn appendExpression(self: *Self, index: structures.Node.Index, operation: UnresolvedBody.Expression.Operation) !ValueId {
            const value: ValueId = @enumFromInt(self.parameter_count + self.expressions.items.len);
            try self.expressions.append(self.gpa, .{ .operation = operation, .span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index) });
            return value;
        }

        fn finish(self: *Self) !UnresolvedBody {
            const expressions = try self.expressions.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(expressions);
            const blocks = try self.blocks.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(blocks);
            const statements = try self.statements.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(statements);
            const call_arguments = try self.call_arguments.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(call_arguments);
            const conditional_outputs = try self.conditional_outputs.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(conditional_outputs);
            const loop_values = try self.loop_values.toOwnedSlice(self.gpa);
            return .{
                .parameter_count = self.parameter_count,
                .expressions = expressions,
                .blocks = blocks,
                .statements = statements,
                .call_arguments = call_arguments,
                .conditional_outputs = conditional_outputs,
                .loop_values = loop_values,
                .root_block = self.root_block.?,
            };
        }
    };
}

const FunctionParts = struct {
    signature: structures.Node.Index,
    body: structures.Node.Index,
};

pub fn analyzeFunctionSignature(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SignatureResult {
    const binding = ast.nodes[declaration];
    if (binding.data.node_node.a.unwrap()) |annotation| {
        return .{ .unsupported = issueAt(ast, annotation.index(), .function_annotation_not_supported) };
    }
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];

    var parameter_types: std.ArrayList(structures.TypeId) = .empty;
    defer parameter_types.deinit(gpa);
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    for (ast.nodeList(signature.data.node_node.a)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        std.debug.assert(parameter.tag == .param);
        if (parameter.data.node_node.a.unwrap()) |access| {
            return .{ .unsupported = issueAt(ast, access.index(), .parameter_mode_not_supported) };
        }
        const name_span = tokenSpan(ast, parameter.token_index);
        const name = source[name_span.start..name_span.end];
        if ((try names.getOrPut(name)).found_existing) {
            return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_parameter } };
        }
        const annotation = parameter.data.node_node.b.unwrap() orelse
            return .{ .unsupported = .{ .span = name_span, .kind = .parameter_type_missing } };
        const parameter_type = switch (try analyzeType(ast, source, annotation, type_interner, gpa, .parameter_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        try parameter_types.append(gpa, parameter_type);
    }

    const return_type = if (signature.data.node_node.b.unwrap()) |return_type_index|
        switch (try analyzeType(ast, source, return_type_index, type_interner, gpa, .return_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        }
    else
        .unit;

    return .{ .success = .{ .parameter_types = try parameter_types.toOwnedSlice(gpa), .return_type = return_type } };
}

fn isFallibleExpression(tag: structures.Node.Tag) bool {
    return switch (tag) {
        .lt, .gt, .le, .ge, .eq, .ne, .is, .as, .query_op, .@"and", .@"or", .not => true,
        else => false,
    };
}

fn analyzeType(
    ast: *const structures.Ast,
    source: []const u8,
    node_index: structures.Node.Index,
    type_interner: anytype,
    gpa: std.mem.Allocator,
    unsupported_kind: structures.Diagnostic.Kind,
) anyerror!SemanticResult(structures.TypeId) {
    const node = ast.nodes[node_index.index()];
    if (node.tag == .type) {
        const span = tokenSpan(ast, node.token_index);
        const name = source[span.start..span.end];
        if (std.mem.eql(u8, name, "int")) return .{ .success = .int };
        if (std.mem.eql(u8, name, "unit")) return .{ .success = .unit };
        if (std.mem.eql(u8, name, "none")) return .{ .success = .none };
        if (std.mem.eql(u8, name, "never")) return .{ .success = .never };
        return .{ .unsupported = .{ .span = span, .kind = unsupported_kind } };
    }
    if (node.tag != .type_variant) {
        return .{ .unsupported = issueAt(ast, node_index.index(), unsupported_kind) };
    }

    var member_types: std.ArrayList(structures.TypeId) = .empty;
    defer member_types.deinit(gpa);
    for (ast.nodeList(node_index)) |member_index| {
        const member_type = switch (try analyzeType(ast, source, member_index, type_interner, gpa, unsupported_kind)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        try member_types.append(gpa, member_type);
    }
    std.debug.assert(member_types.items.len >= 2);

    return switch (try type_interner.internVariant(member_types.items)) {
        .type_id => |type_id| .{ .success = type_id },
        .duplicate => |duplicate| blk: {
            var seen = false;
            for (ast.nodeList(node_index), 0..) |duplicate_member, member_index| {
                std.debug.assert(member_index < member_types.items.len);
                if (member_types.items[member_index] != duplicate) continue;
                if (seen) break :blk .{ .unsupported = issueAt(ast, duplicate_member.index(), .duplicate_variant_member_type) };
                seen = true;
            }
            break :blk .{ .unsupported = issueAt(ast, node_index.index(), .duplicate_variant_member_type) };
        },
    };
}

fn functionParts(ast: *const structures.Ast, declaration: u32) FunctionParts {
    std.debug.assert(declaration < ast.nodes.len);
    const binding = ast.nodes[declaration];
    std.debug.assert(binding.tag == .static_binding);
    const value_index = binding.data.node_node.b.unwrap() orelse unreachable;
    const function = ast.nodes[value_index.index()];
    std.debug.assert(function.tag == .func);
    const signature = function.data.node_node.a.unwrap() orelse unreachable;
    const body = function.data.node_node.b.unwrap() orelse unreachable;
    std.debug.assert(ast.nodes[signature.index()].tag == .signature);
    return .{ .signature = signature, .body = body };
}

fn issueAt(ast: *const structures.Ast, node_index: u32, kind: structures.Diagnostic.Kind) Issue {
    return .{ .span = tokenSpan(ast, ast.nodes[node_index].token_index), .kind = kind };
}

fn tokenSpan(ast: *const structures.Ast, token_index: u32) structures.SourceSpan {
    const token = ast.tokens[token_index];
    return .{ .start = token.loc.start, .end = token.loc.end };
}

fn nodeFocusSpan(ast: *const structures.Ast, node_index: structures.Node.Index) structures.SourceSpan {
    const node = ast.nodes[node_index.index()];
    if (node.tag == .call) return nodeFocusSpan(ast, node.data.node_node.a);
    return tokenSpan(ast, node.token_index);
}

pub fn discoverItems(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8) !structures.ItemTree {
    var items: std.ArrayList(structures.DiscoveredItem) = .empty;
    errdefer {
        for (items.items) |item| gpa.free(item.loc.name);
        items.deinit(gpa);
    }

    const root = ast.nodes[0];
    std.debug.assert(root.tag == .block);
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const declaration = ast.node_refs[ref_index];
        const node = ast.nodes[declaration.index()];

        if (node.tag != .static_binding) continue;
        const value = node.data.node_node.b.unwrap() orelse unreachable;
        if (ast.nodes[value.index()].tag != .func) continue;

        const token = ast.tokens[node.token_index];
        const name = source[token.loc.start..token.loc.end];
        try appendItem(gpa, &items, .function, ast.file_id, name, declaration.index());
    }

    try appendItem(gpa, &items, .top_level_entry, ast.file_id, "$entry", 0);
    return .{ .file_id = ast.file_id, .items = try items.toOwnedSlice(gpa) };
}

fn appendItem(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    kind: structures.ItemKind,
    file_id: structures.FileId,
    name: []const u8,
    declaration: u32,
) !void {
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    try items.append(gpa, .{
        .loc = .{ .file_id = file_id, .kind = kind, .name = owned_name },
        .declaration = declaration,
    });
}

test "unresolved function body cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testUnresolvedFunctionBodyAllocations, .{});
}

test "function signature cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testFunctionSignatureAllocations, .{});
}

fn testFunctionSignatureAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("ast_new.zig");
    const source = "static target = func(a: int, b: int, c: int) int -> return a";
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzeFunctionSignature(parsed, source, declaration.index(), TestTypeInterner{}, gpa);
    switch (result) {
        .success => |signature_value| {
            var signature = signature_value;
            signature.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}

fn testUnresolvedFunctionBodyAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("ast_new.zig");
    const source =
        \\static target = func(a: int, b: int, c: int) int
        \\  first(a)
        \\  var value: int = a
        \\  const selected: int = if a < b -> value = second(b, c) + 1 else value = third(c, b)
        \\  value = selected
        \\  const looped = loop
        \\    value += 1
        \\    if value < b -> continue
        \\    break value
        \\  return third(looped, a, b) + value * -c
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try buildUnresolvedBody(parsed, source, declaration.index(), .function, 3, TestTypeInterner{}, gpa);
    switch (result) {
        .success => |unresolved_value| {
            var unresolved = unresolved_value;
            unresolved.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}

const TestTypeInterner = struct {
    pub fn internVariant(_: @This(), _: []const structures.TypeId) !structures.InternVariantResult {
        unreachable;
    }

    pub fn variantMembers(_: @This(), _: structures.TypeId) !?[]const structures.TypeId {
        return null;
    }
};
