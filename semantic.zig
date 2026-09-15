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
/// evaluation order. Immutable references reuse their value; mutable references
/// retain a stable local identity whose current SSA value is owned by typing.
/// Source names are borrowed only until typing finishes. Control-flow edges
/// remain structural until typing; CFG blocks belong to typed IR.
pub const UnresolvedBody = struct {
    parameter_count: u32,
    local_count: u32,
    expressions: []Expression,
    conditions: []Condition,
    blocks: []Block,
    statements: []Statement,
    call_arguments: []ValueUse,
    struct_field_values: []StructFieldValue,
    assignment_fields: []FieldName,
    root_block: BlockId,

    pub const ValueId = enum(u32) { _ };
    pub const LocalId = enum(u32) { _ };
    pub const ConditionId = enum(u32) { _ };
    pub const BlockId = enum(u32) { _ };
    pub const ValueUse = struct { value: ValueId, span: structures.SourceSpan };
    pub const BinaryOperands = struct { lhs: ValueUse, rhs: ValueUse };
    pub const StructFieldValue = struct {
        name: []const u8,
        name_span: structures.SourceSpan,
        value: ValueUse,
    };
    pub const FieldName = struct {
        name: []const u8,
        span: structures.SourceSpan,
    };
    pub const ConditionBinding = struct {
        local: LocalId,
        annotation_type: ?structures.TypeId,
        span: structures.SourceSpan,
    };
    pub const StatementRange = struct { start: u32, end: u32 };
    pub const Block = struct {
        statements: StatementRange,
        result: ?ValueId,
        span: structures.SourceSpan,
    };
    pub const Statement = union(enum) {
        discard: ValueUse,
        lifetime_extend: ValueUse,
        propagate: struct { condition: ConditionId, span: structures.SourceSpan },
        bind_local: struct {
            local: LocalId,
            value: ValueId,
            span: structures.SourceSpan,
            mutable: bool,
        },
        break_loop: ValueId,
        continue_loop: structures.SourceSpan,
        return_nothing: structures.SourceSpan,
        return_value: ValueUse,
    };
    pub const PredicateOperation = enum { lt, gt, le, ge, eq, ne };
    pub const Call = struct {
        target: Target,
        arguments: structures.FunctionValueRange,
        span: structures.SourceSpan,

        pub const Target = union(enum) {
            direct: []const u8,
            value: ValueUse,
        };
    };
    pub const Condition = union(enum) {
        comparison: struct {
            operation: PredicateOperation,
            operands: BinaryOperands,
        },
        variant_membership: struct {
            operand: ValueUse,
            target_type: structures.TypeId,
            binding: ?ConditionBinding = null,
        },
        conjunction: struct { lhs: ConditionId, rhs: ConditionId },
        disjunction: struct { lhs: ConditionId, rhs: ConditionId },
        negation: ConditionId,
        call: Call,
    };
    pub const AssignmentOperation = enum { replace, add, subtract, multiply, divide };
    pub const Expression = struct {
        operation: Operation,
        span: structures.SourceSpan,

        pub const Operation = union(enum) {
            integer: i32,
            boolean: bool,
            unit,
            none,
            function_ref: structures.FunctionReference,
            local_read: LocalId,
            local_transfer: LocalId,
            annotation: struct { value: ValueUse, type_id: structures.TypeId },
            struct_init: struct { type_id: structures.TypeId, fields: structures.FunctionValueRange },
            field_access: struct { operand: ValueUse, name: []const u8 },
            assignment: struct {
                target: LocalId,
                target_span: structures.SourceSpan,
                fields: structures.FunctionValueRange,
                value: ValueUse,
                operation: AssignmentOperation,
            },
            call: Call,
            negate: ValueUse,
            add: BinaryOperands,
            subtract: BinaryOperands,
            multiply: BinaryOperands,
            divide: BinaryOperands,
            if_else: struct {
                condition: ConditionId,
                then_block: BlockId,
                else_block: BlockId,
            },
            loop: BlockId,
        };
    };

    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        gpa.free(self.expressions);
        gpa.free(self.conditions);
        gpa.free(self.blocks);
        gpa.free(self.statements);
        gpa.free(self.call_arguments);
        gpa.free(self.struct_field_values);
        gpa.free(self.assignment_fields);
        self.* = undefined;
    }
};

pub fn buildUnresolvedBody(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    kind: structures.ItemKind,
    parameters: []const structures.CallableParameter,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(UnresolvedBody) {
    var builder: ExpressionBuilder(@TypeOf(type_interner)) = .{
        .ast = ast,
        .source = source,
        .parameters = parameters,
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
        const Local = union(enum) {
            value: ValueId,
            place: struct {
                id: UnresolvedBody.LocalId,
                mutable: bool,
            },
        };

        ast: *const structures.Ast,
        source: []const u8,
        parameters: []const structures.CallableParameter,
        type_interner: TypeInterner,
        gpa: std.mem.Allocator,
        local_count: u32 = 0,
        locals: std.StringHashMapUnmanaged(Local) = .empty,
        local_names: std.ArrayList([]const u8) = .empty,
        expressions: std.ArrayList(UnresolvedBody.Expression) = .empty,
        conditions: std.ArrayList(UnresolvedBody.Condition) = .empty,
        blocks: std.ArrayList(UnresolvedBody.Block) = .empty,
        statements: std.ArrayList(UnresolvedBody.Statement) = .empty,
        call_arguments: std.ArrayList(UnresolvedBody.ValueUse) = .empty,
        struct_field_values: std.ArrayList(UnresolvedBody.StructFieldValue) = .empty,
        assignment_fields: std.ArrayList(UnresolvedBody.FieldName) = .empty,
        loop_depth: u32 = 0,
        can_return: bool = false,
        scratch: std.ArrayList(ValueId) = .empty,
        root_block: ?UnresolvedBody.BlockId = null,
        issue: ?Issue = null,

        fn deinit(self: *Self) void {
            self.locals.deinit(self.gpa);
            self.local_names.deinit(self.gpa);
            self.expressions.deinit(self.gpa);
            self.conditions.deinit(self.gpa);
            self.blocks.deinit(self.gpa);
            self.statements.deinit(self.gpa);
            self.call_arguments.deinit(self.gpa);
            self.struct_field_values.deinit(self.gpa);
            self.assignment_fields.deinit(self.gpa);
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
                .function => {
                    self.can_return = true;
                    try self.buildFunction(declaration);
                },
                .static, .structure => unreachable,
            }
        }

        fn buildEntry(self: *Self, declaration: u32) !void {
            const root = self.ast.nodes[declaration];
            std.debug.assert(root.tag == .block);
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            for (self.ast.node_refs[root.data.ref.start..root.data.ref.end]) |child| {
                if (self.ast.nodes[child.index()].tag == .static_binding) continue;
                try body_statements.append(self.gpa, try self.buildStatement(child));
            }
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, root.token_index));
        }

        fn buildFunction(self: *Self, declaration: u32) !void {
            const function = self.ast.nodes[declaration];
            const parts = functionParts(self.ast, declaration);
            const signature = self.ast.nodes[parts.signature.index()];
            const parameters = self.ast.nodeList(signature.data.node_node.a);
            std.debug.assert(parameters.len == self.parameters.len);
            for (parameters, 0..) |parameter_index, index| {
                const span = tokenSpan(self.ast, self.ast.nodes[parameter_index.index()].token_index);
                const name = self.source[span.start..span.end];
                const local: Local = switch (self.parameters[index].mode) {
                    .imm => .{ .value = @enumFromInt(index) },
                    .mut, .@"var", .deinit => blk: {
                        const id: UnresolvedBody.LocalId = @enumFromInt(self.local_count);
                        self.local_count += 1;
                        break :blk .{ .place = .{ .id = id, .mutable = true } };
                    },
                    .static => unreachable,
                };
                try self.locals.put(self.gpa, name, local);
                try self.local_names.append(self.gpa, name);
            }

            const body = self.ast.nodes[parts.body.index()];
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            if (body.tag == .block) {
                for (self.ast.node_refs[body.data.ref.start..body.data.ref.end]) |statement| {
                    try body_statements.append(self.gpa, try self.buildStatement(statement));
                }
            } else {
                try body_statements.append(self.gpa, try self.buildStatement(parts.body));
            }
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, function.token_index));
        }

        fn buildStatement(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            return switch (node.tag) {
                .const_binding, .var_binding => try self.buildBinding(index),
                .return_nothing => if (!self.can_return)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_nothing = span },
                .return_expr => if (!self.can_return)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_value = try self.appendUse(node.data.node) },
                .break_nothing, .break_expr => try self.buildBreak(index),
                .continue_expr => try self.buildContinue(index),
                .assign => if (self.isDiscardAssignment(index))
                    .{ .lifetime_extend = try self.appendUse(node.data.node_node.b) }
                else
                    .{ .discard = try self.appendUse(index) },
                else => if (isFallibleExpression(node.tag))
                    .{ .propagate = .{ .condition = try self.buildCondition(index), .span = span } }
                else
                    .{ .discard = try self.appendUse(index) },
            };
        }

        fn isDiscardAssignment(self: *const Self, index: structures.Node.Index) bool {
            const target_index = self.ast.nodes[index.index()].data.node_node.a;
            const target = self.ast.nodes[target_index.index()];
            if (target.tag != .identifier) return false;
            const span = tokenSpan(self.ast, target.token_index);
            return std.mem.eql(u8, self.source[span.start..span.end], "_");
        }

        fn buildBreak(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            if (self.loop_depth == 0) return self.reject(index, .break_outside_loop);
            const node = self.ast.nodes[index.index()];
            const value = if (node.tag == .break_expr)
                try self.append(node.data.node)
            else
                try self.appendExpression(index, .unit);
            return .{ .break_loop = value };
        }

        fn buildContinue(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            if (self.loop_depth == 0) return self.reject(index, .continue_outside_loop);
            return .{ .continue_loop = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index) };
        }

        fn nameIsVisible(self: *Self, name: []const u8) !bool {
            return self.locals.contains(name) or try self.type_interner.resolveItem(name) != null;
        }

        fn buildBinding(self: *Self, index: structures.Node.Index) anyerror!UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            const annotation = node.data.node_node.a.unwrap();
            const expected = if (annotation) |type_node| try self.bindingType(type_node) else null;
            var value = try self.append(node.data.node_node.b);
            if (expected) |type_id| {
                value = try self.appendExpression(annotation.?, .{ .annotation = .{ .value = .{
                    .value = value,
                    .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                }, .type_id = type_id } });
            }
            const local: UnresolvedBody.LocalId = @enumFromInt(self.local_count);
            self.local_count += 1;
            try self.locals.put(self.gpa, name, .{ .place = .{
                .id = local,
                .mutable = node.tag == .var_binding,
            } });
            try self.local_names.append(self.gpa, name);
            return .{ .bind_local = .{
                .local = local,
                .value = value,
                .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                .mutable = node.tag == .var_binding,
            } };
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
                .bool_literal => return self.appendExpression(index, .{ .boolean = self.ast.tokens[node.token_index].tag == .keyword_true }),
                .unit_literal => return self.appendExpression(index, .unit),
                .none_literal => return self.appendExpression(index, .none),
                .call => return self.appendCall(index),
                .struct_init => return self.appendStructInit(index),
                .field_access => return self.appendFieldAccess(index),
                .identifier => {
                    const span = tokenSpan(self.ast, node.token_index);
                    const name = self.source[span.start..span.end];
                    if (self.locals.get(name)) |local| return switch (local) {
                        .value => |value| value,
                        .place => |place| self.appendExpression(index, .{ .local_read = place.id }),
                    };
                    if (std.mem.eql(u8, name, "unit")) return self.appendExpression(index, .unit);
                    const resolved = self.type_interner.resolveStatic(name) catch |err| switch (err) {
                        error.QueryCycle => return self.reject(index, .declaration_cycle),
                        error.Unavailable => return error.Unavailable,
                        else => return err,
                    };
                    const static_value = resolved orelse {
                        const function = self.type_interner.functionReference(name) catch |err| switch (err) {
                            error.Unavailable => return error.Unavailable,
                            else => return err,
                        };
                        return self.appendExpression(index, .{ .function_ref = function orelse return self.reject(index, .unknown_value) });
                    };
                    return switch (static_value) {
                        .type => self.reject(index, .type_value_used_as_runtime_value),
                        .runtime => |runtime| blk: {
                            const primitive = switch (runtime.value) {
                                .int => |value| try self.appendExpression(index, .{ .integer = value }),
                                .bool => |value| try self.appendExpression(index, .{ .boolean = value }),
                                .unit => try self.appendExpression(index, .unit),
                                .none => try self.appendExpression(index, .none),
                                .function_ref => |reference| try self.appendExpression(index, .{ .function_ref = reference }),
                            };
                            if (runtime.type_id == runtime.value.typeId()) break :blk primitive;
                            break :blk try self.appendExpression(index, .{ .annotation = .{
                                .value = .{ .value = primitive, .span = span },
                                .type_id = runtime.type_id,
                            } });
                        },
                    };
                },
                .neg => return self.appendExpression(index, .{ .negate = try self.appendUse(node.data.node) }),
                .add, .sub, .mul, .div => return self.appendBinary(index),
                .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => return self.appendAssignment(index),
                .@"if", .if_else => return self.appendIf(index),
                .loop => return self.appendLoop(index),
                .static_binding => return self.reject(index, .nested_declaration_not_supported),
                .move_expr => return self.appendTransfer(index),
                else => return self.reject(index, .expression_not_supported),
            }
        }

        fn appendTransfer(self: *Self, index: structures.Node.Index) !ValueId {
            const operand_index = self.ast.nodes[index.index()].data.node;
            const operand = self.ast.nodes[operand_index.index()];
            if (operand.tag != .identifier) return self.reject(index, .ownership_transfer_requires_place);
            const span = tokenSpan(self.ast, operand.token_index);
            const name = self.source[span.start..span.end];
            const local = self.locals.get(name) orelse return self.reject(operand_index, .unknown_value);
            return switch (local) {
                .value => self.reject(index, .ownership_transfer_requires_owned_place),
                .place => |place| self.appendExpression(index, .{ .local_transfer = place.id }),
            };
        }

        fn appendStructInit(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const parts = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
            std.debug.assert(parts.len >= 1);
            const type_id = switch (try analyzeType(self.ast, self.source, parts[0], self.type_interner, self.gpa, .local_type_not_supported)) {
                .success => |resolved| resolved,
                .unsupported => |issue| {
                    self.issue = issue;
                    return error.SourceRejected;
                },
            };
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            for (parts[1..]) |field_index| {
                const field = self.ast.nodes[field_index.index()];
                std.debug.assert(field.tag == .struct_init_field);
                try self.scratch.append(self.gpa, try self.append(field.data.node));
            }
            const start: u32 = @intCast(self.struct_field_values.items.len);
            for (parts[1..], self.scratch.items[scratch_start..]) |field_index, value| {
                const field = self.ast.nodes[field_index.index()];
                const name_span = tokenSpan(self.ast, field.token_index);
                try self.struct_field_values.append(self.gpa, .{
                    .name = self.source[name_span.start..name_span.end],
                    .name_span = name_span,
                    .value = .{
                        .value = value,
                        .span = nodeFocusSpan(self.ast, field.data.node),
                    },
                });
            }
            return self.appendExpression(index, .{ .struct_init = .{
                .type_id = type_id,
                .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
            } });
        }

        fn appendFieldAccess(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const name_span = tokenSpan(self.ast, node.token_index);
            return self.appendExpression(index, .{ .field_access = .{
                .operand = try self.appendUse(node.data.node),
                .name = self.source[name_span.start..name_span.end],
            } });
        }

        fn appendUse(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            return .{
                .value = try self.append(index),
                .span = nodeFocusSpan(self.ast, index),
            };
        }

        fn appendLoop(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            const body = try self.buildBranch(node.data.node);
            return self.appendExpression(index, .{ .loop = body });
        }

        fn appendInteger(self: *Self, index: structures.Node.Index) !ValueId {
            const span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index);
            const literal = self.source[span.start..span.end];
            return switch (parseIntegerLiteral(literal)) {
                .value => |value| self.appendExpression(index, .{ .integer = value }),
                .unsupported => |kind| self.reject(index, kind),
            };
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
            const field_start: u32 = @intCast(self.assignment_fields.items.len);
            var target_index = node.data.node_node.a;
            var target_node = self.ast.nodes[target_index.index()];
            while (target_node.tag == .field_access) {
                const field_span = tokenSpan(self.ast, target_node.token_index);
                try self.assignment_fields.append(self.gpa, .{
                    .name = self.source[field_span.start..field_span.end],
                    .span = field_span,
                });
                target_index = target_node.data.node;
                target_node = self.ast.nodes[target_index.index()];
            }
            std.mem.reverse(UnresolvedBody.FieldName, self.assignment_fields.items[field_start..]);
            if (target_node.tag != .identifier) return self.reject(node.data.node_node.a, .assignment_target_not_local);
            const span = tokenSpan(self.ast, target_node.token_index);
            const name = self.source[span.start..span.end];
            const local = self.locals.get(name) orelse return self.reject(target_index, .unknown_value);
            const target = switch (local) {
                .value => return self.reject(target_index, .assignment_to_immutable),
                .place => |place| if (place.mutable) place.id else return self.reject(target_index, .assignment_to_immutable),
            };
            const field_end: u32 = @intCast(self.assignment_fields.items.len);
            const value = try self.append(node.data.node_node.b);
            return self.appendExpression(index, .{ .assignment = .{
                .target = target,
                .target_span = span,
                .fields = .{ .start = field_start, .end = field_end },
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
            const condition_scope = self.local_names.items.len;
            defer self.restoreScope(condition_scope);
            const condition = try self.buildIfCondition(condition_index);
            const then_block = try self.buildBranch(then_index);
            self.restoreScope(condition_scope);
            const else_block = if (else_index) |explicit_else|
                try self.buildBranch(explicit_else)
            else
                try self.buildUnitBranch(index);
            return self.appendExpression(index, .{ .if_else = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            } });
        }

        fn buildIfCondition(self: *Self, index: structures.Node.Index) !UnresolvedBody.ConditionId {
            const node = self.ast.nodes[index.index()];
            if (node.tag != .const_binding and node.tag != .var_binding) return self.buildCondition(index);
            if (node.tag == .var_binding) return self.reject(index, .condition_binding_must_be_immutable);

            const value_index = node.data.node_node.b;
            const value_node = self.ast.nodes[value_index.index()];
            if (value_node.tag != .as) return self.rejectCondition(index);

            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            const local: UnresolvedBody.LocalId = @enumFromInt(self.local_count);
            self.local_count += 1;
            const annotation_type = if (node.data.node_node.a.unwrap()) |annotation| try self.bindingType(annotation) else null;
            const condition = try self.buildVariantMembership(value_node, .{
                .local = local,
                .annotation_type = annotation_type,
                .span = nodeFocusSpan(self.ast, value_index),
            });

            try self.locals.put(self.gpa, name, .{ .place = .{ .id = local, .mutable = false } });
            try self.local_names.append(self.gpa, name);
            return condition;
        }

        fn buildCondition(self: *Self, index: structures.Node.Index) !UnresolvedBody.ConditionId {
            const node = self.ast.nodes[index.index()];
            return switch (node.tag) {
                .lt, .gt, .le, .ge, .eq, .ne => self.appendCondition(.{ .comparison = .{
                    .operation = comparisonOperation(node.tag),
                    .operands = .{ .lhs = try self.appendUse(node.data.node_node.a), .rhs = try self.appendUse(node.data.node_node.b) },
                } }),
                .is, .as => self.buildVariantMembership(node, null),
                .@"and", .@"or" => {
                    const lhs = try self.buildCondition(node.data.node_node.a);
                    const rhs = try self.buildCondition(node.data.node_node.b);
                    return self.appendCondition(if (node.tag == .@"and")
                        .{ .conjunction = .{ .lhs = lhs, .rhs = rhs } }
                    else
                        .{ .disjunction = .{ .lhs = lhs, .rhs = rhs } });
                },
                .not => self.appendCondition(.{ .negation = try self.buildCondition(node.data.node) }),
                .call => self.appendCondition(.{ .call = try self.buildCall(index) }),
                else => self.rejectCondition(index),
            };
        }

        fn buildVariantMembership(self: *Self, node: structures.Node, binding: ?UnresolvedBody.ConditionBinding) !UnresolvedBody.ConditionId {
            const target_type = switch (try analyzeType(self.ast, self.source, node.data.node_node.b, self.type_interner, self.gpa, .inspection_type_not_supported)) {
                .success => |type_id| type_id,
                .unsupported => |issue| {
                    self.issue = issue;
                    return error.SourceRejected;
                },
            };
            return self.appendCondition(.{ .variant_membership = .{
                .operand = try self.appendUse(node.data.node_node.a),
                .target_type = target_type,
                .binding = binding,
            } });
        }

        fn comparisonOperation(tag: structures.Node.Tag) UnresolvedBody.PredicateOperation {
            return switch (tag) {
                .lt => .lt,
                .gt => .gt,
                .le => .le,
                .ge => .ge,
                .eq => .eq,
                .ne => .ne,
                else => unreachable,
            };
        }

        fn appendCondition(self: *Self, condition: UnresolvedBody.Condition) !UnresolvedBody.ConditionId {
            const id: UnresolvedBody.ConditionId = @enumFromInt(self.conditions.items.len);
            try self.conditions.append(self.gpa, condition);
            return id;
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
                    var statements = [_]UnresolvedBody.Statement{try self.buildStatement(index)};
                    return self.finishBlock(&statements, null, tokenSpan(self.ast, node.token_index));
                }
                return self.finishBlock(&.{}, try self.append(index), tokenSpan(self.ast, node.token_index));
            }

            const children = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
            if (children.len == 0) return self.buildUnitBranch(index);

            var statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer statements.deinit(self.gpa);
            for (children[0 .. children.len - 1]) |statement| {
                try statements.append(self.gpa, try self.buildStatement(statement));
            }
            const last = children[children.len - 1];
            const last_node = self.ast.nodes[last.index()];
            const result: ?ValueId = switch (last_node.tag) {
                .const_binding, .var_binding, .return_nothing, .return_expr, .break_nothing, .break_expr, .continue_expr => blk: {
                    try statements.append(self.gpa, try self.buildStatement(last));
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
            return self.appendExpression(node.data.node_node.a, .{ .call = try self.buildCall(index) });
        }

        fn buildCall(self: *Self, index: structures.Node.Index) !UnresolvedBody.Call {
            const node = self.ast.nodes[index.index()];
            const callee_index = node.data.node_node.a;
            const callee = self.ast.nodes[callee_index.index()];
            const span = nodeFocusSpan(self.ast, callee_index);
            const target: UnresolvedBody.Call.Target = if (callee.tag == .identifier) target_blk: {
                const name = self.source[span.start..span.end];
                if (std.mem.eql(u8, name, "exit")) break :target_blk .{ .direct = name };
                if (self.locals.contains(name)) break :target_blk .{ .value = try self.appendUse(callee_index) };
                const function = self.type_interner.resolveFunction(name) catch |err| switch (err) {
                    error.Unavailable => return error.Unavailable,
                    else => return err,
                };
                if (function != null) break :target_blk .{ .direct = name };
                const static_value = self.type_interner.resolveStatic(name) catch |err| switch (err) {
                    error.QueryCycle => return self.reject(callee_index, .declaration_cycle),
                    error.Unavailable => return error.Unavailable,
                    else => return err,
                };
                if (static_value) |value| switch (value) {
                    .runtime => |runtime| switch (runtime.value) {
                        .function_ref => |reference| {
                            const expression = try self.appendExpression(callee_index, .{ .function_ref = reference });
                            const target = if (runtime.type_id == reference.type_id)
                                expression
                            else
                                try self.appendExpression(callee_index, .{ .annotation = .{
                                    .value = .{ .value = expression, .span = span },
                                    .type_id = runtime.type_id,
                                } });
                            break :target_blk .{ .value = .{ .value = target, .span = span } };
                        },
                        .int, .bool, .unit, .none => {},
                    },
                    .type => {},
                };
                break :target_blk .{ .direct = name };
            } else .{ .value = try self.appendUse(callee_index) };
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
            return .{
                .target = target,
                .arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) },
                .span = span,
            };
        }

        fn appendExpression(self: *Self, index: structures.Node.Index, operation: UnresolvedBody.Expression.Operation) !ValueId {
            const value: ValueId = @enumFromInt(self.parameters.len + self.expressions.items.len);
            try self.expressions.append(self.gpa, .{ .operation = operation, .span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index) });
            return value;
        }

        fn finish(self: *Self) !UnresolvedBody {
            const expressions = try self.expressions.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(expressions);
            const conditions = try self.conditions.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(conditions);
            const blocks = try self.blocks.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(blocks);
            const statements = try self.statements.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(statements);
            const call_arguments = try self.call_arguments.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(call_arguments);
            const struct_field_values = try self.struct_field_values.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(struct_field_values);
            const assignment_fields = try self.assignment_fields.toOwnedSlice(self.gpa);
            return .{
                .parameter_count = @intCast(self.parameters.len),
                .local_count = self.local_count,
                .expressions = expressions,
                .conditions = conditions,
                .blocks = blocks,
                .statements = statements,
                .call_arguments = call_arguments,
                .struct_field_values = struct_field_values,
                .assignment_fields = assignment_fields,
                .root_block = self.root_block.?,
            };
        }
    };
}

const FunctionParts = struct {
    function: structures.Node.Index,
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
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];

    var parameters: std.ArrayList(structures.CallableParameter) = .empty;
    defer parameters.deinit(gpa);
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    for (ast.nodeList(signature.data.node_node.a)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        std.debug.assert(parameter.tag == .param);
        const mode: structures.ParameterMode = if (parameter.data.node_node.a.unwrap()) |access| switch (ast.tokens[ast.nodes[access.index()].token_index].tag) {
            .keyword_imm => .imm,
            .keyword_mut => .mut,
            .keyword_var => .@"var",
            .keyword_deinit => .deinit,
            else => return .{ .unsupported = issueAt(ast, access.index(), .parameter_mode_not_supported) },
        } else .imm;
        const name_span = tokenSpan(ast, parameter.token_index);
        const name = source[name_span.start..name_span.end];
        if ((try names.getOrPut(name)).found_existing or try type_interner.resolveItem(name) != null) {
            return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_parameter } };
        }
        const annotation = parameter.data.node_node.b.unwrap() orelse
            return .{ .unsupported = .{ .span = name_span, .kind = .parameter_type_missing } };
        const parameter_type = switch (try analyzeType(ast, source, annotation, type_interner, gpa, .parameter_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        try parameters.append(gpa, .{ .mode = mode, .type_id = parameter_type });
    }

    const return_type = if (signature.data.node_node.b.unwrap()) |return_type_index|
        switch (try analyzeType(ast, source, return_type_index, type_interner, gpa, .return_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        }
    else
        .unit;

    const function = ast.nodes[parts.function.index()];
    const is_fallible = ast.tokens[function.token_index].tag == .keyword_fallible;
    const annotation = if (binding.tag == .static_binding) binding.data.node_node.a.unwrap() else null;
    if (annotation) |annotation_index| {
        const expected = switch (try analyzeType(ast, source, annotation_index, type_interner, gpa, .function_annotation_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        const actual = try type_interner.internCallable(.{
            .parameters = parameters.items,
            .return_type = return_type,
            .is_fallible = is_fallible,
        });
        if (expected != actual) return .{ .unsupported = .{
            .span = nodeFocusSpan(ast, parts.function),
            .kind = .{ .static_initializer_type_mismatch = .{
                .expected = expected,
                .found = actual,
            } },
        } };
    }
    return .{ .success = .{
        .parameters = try parameters.toOwnedSlice(gpa),
        .return_type = return_type,
        .is_fallible = is_fallible,
    } };
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
    if (node.tag == .type or node.tag == .identifier) {
        const span = tokenSpan(ast, node.token_index);
        const name = source[span.start..span.end];
        if (std.mem.eql(u8, name, "int")) return .{ .success = .int };
        if (std.mem.eql(u8, name, "bool")) return .{ .success = .bool };
        if (std.mem.eql(u8, name, "unit")) return .{ .success = .unit };
        if (std.mem.eql(u8, name, "none")) return .{ .success = .none };
        if (std.mem.eql(u8, name, "never")) return .{ .success = .never };
        if (std.mem.eql(u8, name, "float")) return .{ .unsupported = .{ .span = span, .kind = .float_type_not_supported } };
        const resolved = type_interner.resolveStatic(name) catch |err| switch (err) {
            error.QueryCycle => return .{ .unsupported = .{ .span = span, .kind = .declaration_cycle } },
            error.Unavailable => return error.Unavailable,
            else => return err,
        };
        const value = resolved orelse return .{ .unsupported = .{ .span = span, .kind = .unknown_type } };
        return switch (value) {
            .type => |type_id| .{ .success = type_id },
            .runtime => .{ .unsupported = .{ .span = span, .kind = .value_used_as_type } },
        };
    }
    if (node.tag == .type_func) {
        var parameters: std.ArrayList(structures.CallableParameter) = .empty;
        defer parameters.deinit(gpa);
        for (ast.nodeList(node.data.node_node.a)) |parameter_index| {
            const parameter_type = switch (try analyzeType(ast, source, parameter_index, type_interner, gpa, unsupported_kind)) {
                .success => |type_id| type_id,
                .unsupported => |issue| return .{ .unsupported = issue },
            };
            try parameters.append(gpa, .{ .mode = .imm, .type_id = parameter_type });
        }
        const return_type = switch (try analyzeType(ast, source, node.data.node_node.b, type_interner, gpa, unsupported_kind)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        return .{ .success = try type_interner.internCallable(.{
            .parameters = parameters.items,
            .return_type = return_type,
            .is_fallible = ast.tokens[node.token_index].tag == .keyword_fallible,
        }) };
    }
    if (node.tag != .type_variant) return .{ .unsupported = issueAt(ast, node_index.index(), unsupported_kind) };

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

pub fn analyzeStaticDeclaration(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.CompileTimeValue) {
    const binding = ast.nodes[declaration];
    std.debug.assert(binding.tag == .static_binding);
    const initializer = binding.data.node_node.b.unwrap() orelse unreachable;
    const annotation = binding.data.node_node.a.unwrap();
    if (annotation) |annotation_index| {
        if (isMetaTypeAnnotation(ast, source, annotation_index)) {
            return switch (try analyzeType(ast, source, initializer, type_interner, gpa, .static_initializer_not_supported)) {
                .success => |type_id| .{ .success = .{ .type = type_id } },
                .unsupported => |issue| .{ .unsupported = issue },
            };
        }
    }
    var value = switch (try analyzeStaticInitializer(ast, source, initializer, type_interner, gpa)) {
        .success => |resolved| resolved,
        .unsupported => |issue| return .{ .unsupported = issue },
    };
    const runtime_annotation = annotation orelse return .{ .success = value };
    const expected = switch (try analyzeType(ast, source, runtime_annotation, type_interner, gpa, .static_initializer_not_supported)) {
        .success => |type_id| type_id,
        .unsupported => |issue| return .{ .unsupported = issue },
    };
    const runtime = switch (value) {
        .type => return .{ .unsupported = issueAt(ast, initializer.index(), .static_initializer_not_supported) },
        .runtime => |runtime| runtime,
    };
    if (!try canWidenTo(type_interner, runtime.type_id, expected)) {
        return .{ .unsupported = .{
            .span = nodeFocusSpan(ast, initializer),
            .kind = .{ .static_initializer_type_mismatch = .{
                .expected = expected,
                .found = runtime.type_id,
            } },
        } };
    }
    value.runtime.type_id = expected;
    return .{ .success = value };
}

pub fn analyzeStructDefinition(
    ast: *const structures.Ast,
    source: []const u8,
    item_id: structures.ItemId,
    declaration: u32,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.StructDefinition) {
    const binding = ast.nodes[declaration];
    std.debug.assert(binding.tag == .static_binding);
    const initializer = binding.data.node_node.b.unwrap() orelse unreachable;
    const struct_node = ast.nodes[initializer.index()];
    std.debug.assert(struct_node.tag == .@"struct");
    if (binding.data.node_node.a.unwrap()) |annotation| {
        if (!isMetaTypeAnnotation(ast, source, annotation)) {
            return .{ .unsupported = issueAt(ast, annotation.index(), .static_initializer_not_supported) };
        }
    }

    var fields: std.ArrayList(structures.StructField) = .empty;
    defer {
        for (fields.items) |field| gpa.free(field.name);
        fields.deinit(gpa);
    }
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    var ownership: structures.StructOwnershipProperties = .{};

    for (ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
        const member = ast.nodes[member_index.index()];
        if (member.tag == .struct_property) {
            const property_span = tokenSpan(ast, member.token_index);
            const property_name = source[property_span.start..property_span.end];
            const operation = StructOwnershipOperation.fromName(property_name) orelse
                return .{ .unsupported = .{ .span = property_span, .kind = .unknown_struct_property } };
            if (operation.isDefined(ownership)) {
                return .{ .unsupported = .{ .span = property_span, .kind = .duplicate_struct_property } };
            }
            const value = ast.nodes[member.data.node.index()];
            const value_span = tokenSpan(ast, value.token_index);
            const value_name = source[value_span.start..value_span.end];
            if (value.tag == .func) {
                const self_type = try type_interner.structType(item_id);
                const mode: structures.ParameterMode, const return_type: structures.TypeId = switch (operation) {
                    .copy => .{ .imm, self_type },
                    .move => .{ .@"var", self_type },
                    .drop => .{ .deinit, .unit },
                };
                const hook = (try type_interner.ownedFunction(item_id, property_name)) orelse return error.Unavailable;
                const actual = (try type_interner.functionSignature(hook)) orelse return error.Unavailable;
                const expected_parameter = [_]structures.CallableParameter{.{ .mode = mode, .type_id = self_type }};
                const expected_type = try type_interner.internCallable(.{
                    .parameters = &expected_parameter,
                    .return_type = return_type,
                    .is_fallible = false,
                });
                const actual_type = try type_interner.internCallable(.{
                    .parameters = actual.parameters,
                    .return_type = actual.return_type,
                    .is_fallible = actual.is_fallible,
                });
                if (actual_type != expected_type) return .{ .unsupported = .{
                    .span = value_span,
                    .kind = .{ .struct_ownership_hook_signature_mismatch = .{
                        .expected = expected_type,
                        .found = actual_type,
                    } },
                } };
                switch (operation) {
                    .copy => ownership.copy = .{ .capability = .custom, .hook = hook, .span = property_span },
                    .move => ownership.move = .{ .capability = .custom, .hook = hook, .span = property_span },
                    .drop => ownership.drop = .{ .capability = .custom, .hook = hook, .span = property_span },
                }
                continue;
            }
            switch (operation) {
                .move => {
                    const capability: structures.MoveCapability = if (std.mem.eql(u8, value_name, "trivial"))
                        .trivial
                    else if (std.mem.eql(u8, value_name, "fieldwise"))
                        .fieldwise
                    else if (value.tag == .none_literal)
                        .none
                    else
                        return .{ .unsupported = .{ .span = value_span, .kind = .invalid_struct_property_value } };
                    ownership.move = .{ .capability = capability, .span = property_span };
                },
                .copy => {
                    const capability: structures.CopyCapability = if (std.mem.eql(u8, value_name, "trivial"))
                        .trivial
                    else if (std.mem.eql(u8, value_name, "fieldwise"))
                        .fieldwise
                    else if (value.tag == .none_literal)
                        .none
                    else
                        return .{ .unsupported = .{ .span = value_span, .kind = .invalid_struct_property_value } };
                    ownership.copy = .{ .capability = capability, .span = property_span };
                },
                .drop => {
                    const capability: structures.DropCapability = if (std.mem.eql(u8, value_name, "trivial"))
                        .trivial
                    else if (std.mem.eql(u8, value_name, "fieldwise"))
                        .fieldwise
                    else if (std.mem.eql(u8, value_name, "explicit"))
                        .explicit
                    else
                        return .{ .unsupported = .{ .span = value_span, .kind = .invalid_struct_property_value } };
                    ownership.drop = .{ .capability = capability, .span = property_span };
                },
            }
            continue;
        }
        if (member.tag != .struct_field) return .{ .unsupported = issueAt(ast, member_index.index(), .struct_member_not_supported) };

        const name_span = tokenSpan(ast, member.token_index);
        const name = source[name_span.start..name_span.end];
        if ((try names.getOrPut(name)).found_existing) {
            return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_struct_field } };
        }
        const field_type = switch (try analyzeType(ast, source, member.data.node, type_interner, gpa, .struct_field_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        try fields.ensureUnusedCapacity(gpa, 1);
        const owned_name = try gpa.dupe(u8, name);
        fields.appendAssumeCapacity(.{
            .name = owned_name,
            .type_id = field_type,
            .span = name_span,
        });
    }

    return .{ .success = .{ .fields = try fields.toOwnedSlice(gpa), .ownership = ownership } };
}

const StructOwnershipOperation = enum {
    move,
    copy,
    drop,

    fn fromName(name: []const u8) ?StructOwnershipOperation {
        if (std.mem.eql(u8, name, "move")) return .move;
        if (std.mem.eql(u8, name, "copy")) return .copy;
        if (std.mem.eql(u8, name, "drop")) return .drop;
        return null;
    }

    fn isDefined(operation: StructOwnershipOperation, ownership: structures.StructOwnershipProperties) bool {
        return switch (operation) {
            .move => ownership.move != null,
            .copy => ownership.copy != null,
            .drop => ownership.drop != null,
        };
    }
};

fn isMetaTypeAnnotation(ast: *const structures.Ast, source: []const u8, annotation: structures.Node.Index) bool {
    const node = ast.nodes[annotation.index()];
    const span = tokenSpan(ast, node.token_index);
    return node.tag == .type and std.mem.eql(u8, source[span.start..span.end], "type");
}

const IntegerLiteralResult = union(enum) {
    value: i32,
    unsupported: structures.Diagnostic.Kind,
};

fn parseIntegerLiteral(literal: []const u8) IntegerLiteralResult {
    const prefix = if (literal.len >= 2) literal[0..2] else "";
    const is_hex = std.ascii.eqlIgnoreCase(prefix, "0x");
    const is_other_base = std.ascii.eqlIgnoreCase(prefix, "0b") or std.ascii.eqlIgnoreCase(prefix, "0o");
    for (literal) |byte| {
        if (byte == '.' or (is_hex and (byte == 'p' or byte == 'P')) or
            (!is_hex and !is_other_base and (byte == 'e' or byte == 'E')))
        {
            return .{ .unsupported = .float_literal_not_supported };
        }
    }
    for (literal) |byte| {
        if (!std.ascii.isDigit(byte)) return .{ .unsupported = .integer_literal_not_decimal };
    }
    return .{ .value = std.fmt.parseInt(i32, literal, 10) catch return .{ .unsupported = .integer_literal_out_of_range } };
}

fn analyzeStaticInitializer(
    ast: *const structures.Ast,
    source: []const u8,
    initializer: structures.Node.Index,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.CompileTimeValue) {
    const node = ast.nodes[initializer.index()];
    return switch (node.tag) {
        .number_literal => blk: {
            const span = tokenSpan(ast, node.token_index);
            const literal = source[span.start..span.end];
            break :blk switch (parseIntegerLiteral(literal)) {
                .value => |value| .{ .success = .{ .runtime = .{ .type_id = .int, .value = .{ .int = value } } } },
                .unsupported => |kind| .{ .unsupported = .{ .span = span, .kind = kind } },
            };
        },
        .bool_literal => .{ .success = .{ .runtime = .{
            .type_id = .bool,
            .value = .{ .bool = ast.tokens[node.token_index].tag == .keyword_true },
        } } },
        .unit_literal => .{ .success = .{ .runtime = .{ .type_id = .unit, .value = .unit } } },
        .none_literal => .{ .success = .{ .runtime = .{ .type_id = .none, .value = .none } } },
        .type_variant => switch (try analyzeType(ast, source, initializer, type_interner, gpa, .static_initializer_not_supported)) {
            .success => |type_id| .{ .success = .{ .type = type_id } },
            .unsupported => |issue| .{ .unsupported = issue },
        },
        .identifier => blk: {
            const span = tokenSpan(ast, node.token_index);
            const name = source[span.start..span.end];
            if (std.mem.eql(u8, name, "int")) break :blk .{ .success = .{ .type = .int } };
            if (std.mem.eql(u8, name, "bool")) break :blk .{ .success = .{ .type = .bool } };
            if (std.mem.eql(u8, name, "never")) break :blk .{ .success = .{ .type = .never } };
            if (std.mem.eql(u8, name, "unit")) break :blk .{ .success = .{ .runtime = .{ .type_id = .unit, .value = .unit } } };
            const resolved = type_interner.resolveStatic(name) catch |err| switch (err) {
                error.QueryCycle => break :blk .{ .unsupported = .{ .span = span, .kind = .declaration_cycle } },
                error.Unavailable => return error.Unavailable,
                else => return err,
            };
            if (resolved) |value| break :blk .{ .success = value };
            const reference = type_interner.functionReference(name) catch |err| switch (err) {
                error.Unavailable => return error.Unavailable,
                else => return err,
            };
            break :blk if (reference) |value|
                .{ .success = .{ .runtime = .{ .type_id = value.type_id, .value = .{ .function_ref = value } } } }
            else
                .{ .unsupported = .{ .span = span, .kind = .unknown_value } };
        },
        else => .{ .unsupported = issueAt(ast, initializer.index(), .static_initializer_not_supported) },
    };
}

pub fn canWidenTo(type_interner: anytype, actual: structures.TypeId, expected: structures.TypeId) !bool {
    if (actual == expected or actual == .never) return true;
    if (try canWidenMember(type_interner, actual, expected)) return true;
    const expected_members = try type_interner.variantMembers(expected) orelse return false;
    const actual_members = try type_interner.variantMembers(actual) orelse {
        for (expected_members) |member| if (try canWidenMember(type_interner, actual, member)) return true;
        return false;
    };
    for (actual_members) |actual_member| {
        var found = false;
        for (expected_members) |expected_member| {
            if (try canWidenMember(type_interner, actual_member, expected_member)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn canWidenMember(type_interner: anytype, actual: structures.TypeId, expected: structures.TypeId) !bool {
    if (actual == expected) return true;
    const expected_callable = try type_interner.callable(expected) orelse return false;
    const actual_callable = try type_interner.callable(actual) orelse return false;
    return actual_callable.return_type == expected_callable.return_type and
        actual_callable.parametersEql(expected_callable) and
        (!actual_callable.is_fallible or expected_callable.is_fallible);
}

fn functionParts(ast: *const structures.Ast, declaration: u32) FunctionParts {
    std.debug.assert(declaration < ast.nodes.len);
    const declaration_node = ast.nodes[declaration];
    const function = if (declaration_node.tag == .static_binding) blk: {
        const value_index = declaration_node.data.node_node.b.unwrap() orelse unreachable;
        break :blk ast.nodes[value_index.index()];
    } else declaration_node;
    std.debug.assert(function.tag == .func);
    const signature = function.data.node_node.a.unwrap() orelse unreachable;
    const body = function.data.node_node.b.unwrap() orelse unreachable;
    std.debug.assert(ast.nodes[signature.index()].tag == .signature);
    return .{ .function = if (declaration_node.tag == .static_binding) declaration_node.data.node_node.b else @enumFromInt(declaration), .signature = signature, .body = body };
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
        const kind: structures.ItemKind = switch (ast.nodes[value.index()].tag) {
            .func => .function,
            .@"struct" => .structure,
            else => .static,
        };

        const token = ast.tokens[node.token_index];
        const name = source[token.loc.start..token.loc.end];
        const parent = try appendItem(gpa, &items, kind, ast.file_id, name, declaration.index(), null);
        if (kind == .structure) {
            const struct_node = ast.nodes[value.index()];
            var hook_names = std.StringHashMap(void).init(gpa);
            defer hook_names.deinit();
            for (ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
                const member = ast.nodes[member_index.index()];
                if (member.tag != .struct_property) continue;
                const property_value = member.data.node;
                if (ast.nodes[property_value.index()].tag != .func) continue;
                const property_token = ast.tokens[member.token_index];
                const property_name = source[property_token.loc.start..property_token.loc.end];
                // StructDefinition owns duplicate-property diagnostics. Keep
                // discovery indexable until that semantic boundary is demanded.
                if ((try hook_names.getOrPut(property_name)).found_existing) continue;
                _ = try appendItem(gpa, &items, .function, ast.file_id, property_name, property_value.index(), parent);
            }
        }
    }

    _ = try appendItem(gpa, &items, .top_level_entry, ast.file_id, "$entry", 0, null);
    return .{ .file_id = ast.file_id, .items = try items.toOwnedSlice(gpa) };
}

fn appendItem(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    kind: structures.ItemKind,
    file_id: structures.FileId,
    name: []const u8,
    declaration: u32,
    parent: ?u32,
) !u32 {
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const index: u32 = @intCast(items.items.len);
    try items.append(gpa, .{
        .loc = .{ .file_id = file_id, .kind = kind, .name = owned_name },
        .declaration = declaration,
        .parent = parent,
    });
    return index;
}

test "unresolved function body cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testUnresolvedFunctionBodyAllocations, .{});
}

test "discard assignment has distinct unresolved statement" {
    const parser = @import("ast_new.zig");
    const source = "func inspect(imm value: int)\n  _ = value";
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try buildUnresolvedBody(parsed, source, declaration.index(), .function, &.{.{
        .mode = .imm,
        .type_id = .int,
    }}, TestTypeInterner{}, std.testing.allocator);
    var unresolved = switch (result) {
        .success => |value| value,
        .unsupported => unreachable,
    };
    defer unresolved.deinit(std.testing.allocator);

    const root = unresolved.blocks[@intFromEnum(unresolved.root_block)];
    try std.testing.expectEqual(@as(u32, 1), root.statements.end - root.statements.start);
    const statement = unresolved.statements[root.statements.start];
    try std.testing.expectEqual(UnresolvedBody.ValueId, @TypeOf(statement.lifetime_extend.value));
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(statement.lifetime_extend.value));
}

test "function signature cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testFunctionSignatureAllocations, .{});
}

test "struct definition cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testStructDefinitionAllocations, .{});
}

fn testStructDefinitionAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("ast_new.zig");
    const source =
        \\static Record = struct
        \\  first: int
        \\  second: bool
        \\  third: none
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzeStructDefinition(parsed, source, @enumFromInt(0), declaration.index(), TestTypeInterner{}, gpa);
    switch (result) {
        .success => |definition_value| {
            var definition = definition_value;
            definition.deinit(gpa);
        },
        .unsupported => unreachable,
    }
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
        \\  const aggregate = int{field = first(a)}
        \\  var mutable_aggregate = aggregate
        \\  mutable_aggregate.field = first(a)
        \\  aggregate.field
        \\  var value: int = a
        \\  const selected: int = if a < b and (if a < b -> value = second(b, c) else value = third(c, b)) > 0 -> value + 1 else value
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
    const result = try buildUnresolvedBody(parsed, source, declaration.index(), .function, &.{
        .{ .mode = .imm, .type_id = .int },
        .{ .mode = .imm, .type_id = .int },
        .{ .mode = .imm, .type_id = .int },
    }, TestTypeInterner{}, gpa);
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

    pub fn internCallable(_: @This(), _: structures.CallableType) !structures.TypeId {
        unreachable;
    }

    pub fn variantMembers(_: @This(), _: structures.TypeId) !?[]const structures.TypeId {
        return null;
    }

    pub fn callable(_: @This(), _: structures.TypeId) !?structures.CallableType {
        return null;
    }

    pub fn ownedFunction(_: @This(), _: structures.ItemId, _: []const u8) !?structures.ItemId {
        unreachable;
    }

    pub fn functionSignature(_: @This(), _: structures.ItemId) !?structures.FunctionSignature {
        unreachable;
    }

    pub fn structType(_: @This(), _: structures.ItemId) !structures.TypeId {
        unreachable;
    }

    pub fn resolveStatic(_: @This(), _: []const u8) !?structures.CompileTimeValue {
        return null;
    }

    pub fn resolveFunction(_: @This(), _: []const u8) !?structures.ItemId {
        return null;
    }

    pub fn resolveItem(_: @This(), _: []const u8) !?structures.ItemId {
        return null;
    }

    pub fn functionReference(_: @This(), _: []const u8) !?structures.FunctionReference {
        return null;
    }
};
