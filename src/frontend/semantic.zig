const std = @import("std");
const text_literal = @import("text_literal.zig");
const structures = @import("../structures.zig");

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
    static_expression_count: u32 = 0,
    parameter_spans: []structures.SourceSpan,
    local_count: u32,
    expressions: []Expression,
    conditions: []Condition,
    blocks: []Block,
    statements: []Statement,
    call_arguments: []ValueUse,
    method_call_arguments: []MethodCallArgument,
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
    pub const MethodCallArgument = struct {
        node: structures.Node.Index,
        value: ValueUse,
        runtime_reference: ?structures.SourceSpan,
    };
    pub const ConditionBinding = struct {
        borrow_mode: ?bool = null,
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
        bind_borrow: struct { local: LocalId, source: ValueId, span: structures.SourceSpan, writable: bool },
        break_loop: ValueId,
        continue_loop: structures.SourceSpan,
        return_nothing: structures.SourceSpan,
        return_value: ValueUse,
        failure: structures.SourceSpan,
    };
    pub const PredicateOperation = enum { lt, gt, le, ge, eq, ne };
    pub const Call = struct {
        target: Target,
        arguments: structures.FunctionValueRange,
        span: structures.SourceSpan,
        fallible_syntax: bool = false,

        pub const Target = union(enum) {
            direct: structures.InstanceId,
            inferred: structures.InstanceId,
            operation: []const u8,
            unknown_function,
            value: ValueUse,
            member: MemberCall,
        };
    };
    pub const MemberCall = struct {
        receiver: ValueUse,
        name: []const u8,
    };
    pub const Condition = union(enum) {
        boolean: ValueUse,
        operation_not: ValueUse,
        comparison: struct {
            operation: PredicateOperation,
            operands: BinaryOperands,
        },
        static_membership: struct {
            operand: structures.Node.Index,
            target_type: structures.TypeId,
        },
        variant_membership: struct {
            operand: ValueUse,
            target_type: structures.TypeId,
            binding: ?ConditionBinding = null,
        },
        conjunction: struct { lhs: ConditionId, rhs: ConditionId, temporary: ?LocalId = null },
        disjunction: struct { lhs: ConditionId, rhs: ConditionId },
        negation: ConditionId,
        call: struct { target: Call, binding: ?ConditionBinding = null, allow_infallible: bool = false },
        initialization: struct { value: ValueUse, binding: ?ConditionBinding = null },
    };
    pub const StructInitTarget = union(enum) { concrete: structures.TypeId, inferred: structures.InstanceId };
    pub const Expression = struct {
        operation: Operation,
        span: structures.SourceSpan,
        source_node: structures.Node.Index = .null,

        pub const Operation = union(enum) {
            integer_literal: i64,
            int_literal_value: i64,
            string_literal: structures.ByteStringId,
            static_data: structures.ByteStringId,
            storage_cursor: structures.StaticStorageCursor,
            integer: i32,
            byte: u8,
            boolean: bool,
            type_value: structures.TypeId,
            unit,
            none,
            function_ref: structures.FunctionReference,
            overloaded_function: [2]structures.InstanceId,
            local_read: LocalId,
            local_transfer: LocalId,
            field_transfer: struct { target: LocalId, fields: structures.FunctionValueRange },
            annotation: struct { value: ValueUse, type_id: structures.TypeId },
            struct_init: struct {
                canonical: bool = false,
                target: StructInitTarget,
                type_span: structures.SourceSpan,
                fields: structures.FunctionValueRange,
            },
            array_init: struct { type_id: structures.TypeId, elements: structures.FunctionValueRange },
            collection_literal: structures.FunctionValueRange,
            field_access: struct { operand: ValueUse, name: []const u8 },
            dereference: ValueUse,
            index_snapshot: ValueUse,
            assignment: struct {
                target: LocalId,
                target_span: structures.SourceSpan,
                fields: structures.FunctionValueRange,
                value: ValueUse,
                replaces: bool,
            },
            borrow_assignment: struct {
                target: LocalId,
                target_span: structures.SourceSpan,
                fields: structures.FunctionValueRange,
                value: ValueUse,
            },
            reference_assignment: struct { reference: ValueUse, value: ValueUse },
            sequence: BinaryOperands,
            call: Call,
            if_else: struct {
                condition: ConditionId,
                then_block: BlockId,
                else_block: BlockId,
            },
            loop: BlockId,
        };
    };

    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        gpa.free(self.parameter_spans);
        gpa.free(self.expressions);
        gpa.free(self.conditions);
        gpa.free(self.blocks);
        gpa.free(self.statements);
        gpa.free(self.call_arguments);
        gpa.free(self.method_call_arguments);
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

/// Build one expression as a zero-parameter body. Its result type is inferred
/// by typing, so this graph is suitable for demand-driven compile-time thunks.
pub fn buildUnresolvedComptimeThunk(
    ast: *const structures.Ast,
    source: []const u8,
    expression: structures.Node.Index,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(UnresolvedBody) {
    var builder: ExpressionBuilder(@TypeOf(type_interner)) = .{
        .ast = ast,
        .source = source,
        .parameters = &.{},
        .type_interner = type_interner,
        .gpa = gpa,
    };
    defer builder.deinit();
    builder.buildComptimeThunk(expression) catch |err| switch (err) {
        error.SourceRejected => return .{ .unsupported = builder.issue.? },
        else => return err,
    };
    return .{ .success = try builder.finish() };
}

pub fn buildUnresolvedWhereCondition(
    ast: *const structures.Ast,
    source: []const u8,
    condition: structures.Node.Index,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(UnresolvedBody) {
    var builder: ExpressionBuilder(@TypeOf(type_interner)) = .{
        .ast = ast,
        .source = source,
        .parameters = &.{},
        .type_interner = type_interner,
        .gpa = gpa,
    };
    defer builder.deinit();
    builder.buildWhereCondition(condition) catch |err| switch (err) {
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
            static_value: structures.CompileTimeValueId,
            type_value: structures.TypeId,
            place: struct {
                id: UnresolvedBody.LocalId,
                mutable: bool,
            },
            borrow: struct { id: UnresolvedBody.LocalId, writable: bool },
        };

        ast: *const structures.Ast,
        source: []const u8,
        parameters: []const structures.CallableParameter,
        type_interner: TypeInterner,
        gpa: std.mem.Allocator,
        where_condition: bool = false,
        static_expression_count: u32 = 0,
        local_count: u32 = 0,
        locals: std.StringHashMapUnmanaged(Local) = .empty,
        local_names: std.ArrayList([]const u8) = .empty,
        parameter_spans: std.ArrayList(structures.SourceSpan) = .empty,
        expressions: std.ArrayList(UnresolvedBody.Expression) = .empty,
        conditions: std.ArrayList(UnresolvedBody.Condition) = .empty,
        blocks: std.ArrayList(UnresolvedBody.Block) = .empty,
        statements: std.ArrayList(UnresolvedBody.Statement) = .empty,
        call_arguments: std.ArrayList(UnresolvedBody.ValueUse) = .empty,
        method_call_arguments: std.ArrayList(UnresolvedBody.MethodCallArgument) = .empty,
        struct_field_values: std.ArrayList(UnresolvedBody.StructFieldValue) = .empty,
        assignment_fields: std.ArrayList(UnresolvedBody.FieldName) = .empty,
        loop_depth: u32 = 0,
        can_return: bool = false,
        returns_type: bool = false,
        scratch: std.ArrayList(ValueId) = .empty,
        root_block: ?UnresolvedBody.BlockId = null,
        issue: ?Issue = null,

        fn deinit(self: *Self) void {
            self.locals.deinit(self.gpa);
            self.local_names.deinit(self.gpa);
            self.parameter_spans.deinit(self.gpa);
            self.expressions.deinit(self.gpa);
            self.conditions.deinit(self.gpa);
            self.blocks.deinit(self.gpa);
            self.statements.deinit(self.gpa);
            self.call_arguments.deinit(self.gpa);
            self.method_call_arguments.deinit(self.gpa);
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
                .static, .structure, .primitive => unreachable,
            }
        }

        fn buildComptimeThunk(self: *Self, expression: structures.Node.Index) !void {
            const node = self.ast.nodes[expression.index()];
            const body = if (node.tag == .comptime_expr) node.data.node else expression;
            self.root_block = try self.buildBranch(body, false);
        }

        fn buildWhereCondition(self: *Self, expression: structures.Node.Index) !void {
            self.where_condition = true;
            const span = nodeFocusSpan(self.ast, expression);
            const condition = try self.buildCondition(expression);
            self.root_block = try self.finishBlock(&.{.{ .propagate = .{ .condition = condition, .span = span } }}, null, span);
        }

        fn buildEntry(self: *Self, declaration: u32) !void {
            const root = self.ast.nodes[declaration];
            std.debug.assert(root.tag == .block);
            var body_statements: std.ArrayList(UnresolvedBody.Statement) = .empty;
            defer body_statements.deinit(self.gpa);
            for (self.ast.node_refs[root.data.ref.start..root.data.ref.end]) |child| {
                const child_node = self.ast.nodes[child.index()];
                const inner = if (child_node.tag == .@"pub") self.ast.nodes[child_node.data.node.index()] else child_node;
                if (inner.tag == .static_binding or inner.tag == .namespace_declaration or inner.tag == .import or inner.tag == .selective_import) continue;
                try body_statements.append(self.gpa, try self.buildStatement(child, false));
            }
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, root.token_index));
        }

        fn buildFunction(self: *Self, declaration: u32) !void {
            const function = self.ast.nodes[declaration];
            const parts = functionParts(self.ast, declaration);
            const signature = self.ast.nodes[parts.signature.index()];
            self.returns_type = if (signature.data.signature.return_type.unwrap()) |return_type|
                isMetaTypeAnnotation(self.ast, self.source, return_type)
            else
                false;
            const parameters = self.ast.nodeList(signature.data.signature.parameters);
            var runtime_index: usize = 0;
            for (parameters) |parameter_index| {
                const parameter = self.ast.nodes[parameter_index.index()];
                const span = tokenSpan(self.ast, self.ast.nodes[parameter_index.index()].token_index);
                const name = self.source[span.start..span.end];
                const mode = parameterMode(self.ast, parameter) orelse unreachable;
                if (mode == .static) {
                    const value_id = (try self.type_interner.resolveStatic(name)) orelse unreachable;
                    const value = try self.type_interner.lookupCompileTimeValue(value_id);
                    const local: Local = switch (value) {
                        .type => |type_id| .{ .type_value = type_id },
                        .runtime => .{ .static_value = value_id },
                    };
                    try self.locals.put(self.gpa, name, local);
                    try self.local_names.append(self.gpa, name);
                    continue;
                }
                std.debug.assert(runtime_index < self.parameters.len);
                const parameter_value_index = runtime_index;
                const runtime_parameter = self.parameters[parameter_value_index];
                runtime_index += 1;
                try self.parameter_spans.append(self.gpa, span);
                const local: Local = switch (runtime_parameter.mode) {
                    .imm, .init => .{ .value = @fromBackingInt(@intCast(parameter_value_index)) },
                    .mut, .@"var", .deinit => blk: {
                        const id: UnresolvedBody.LocalId = @fromBackingInt(@intCast(self.local_count));
                        self.local_count += 1;
                        break :blk .{ .place = .{ .id = id, .mutable = true } };
                    },
                    .static => unreachable,
                };
                try self.locals.put(self.gpa, name, local);
                try self.local_names.append(self.gpa, name);
            }
            std.debug.assert(runtime_index == self.parameters.len);
            self.static_expression_count = @intCast(self.expressions.items.len);

            if (parts.body == .null) {
                std.debug.assert(isExternalFunction(self.ast, declaration));
                self.root_block = try self.finishBlock(&.{}, null, tokenSpan(self.ast, function.token_index));
                return;
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
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, function.token_index));
        }

        fn buildStatement(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            return switch (node.tag) {
                .const_binding, .var_binding => try self.buildBinding(index),
                .borrow_binding, .borrow_mut_binding => try self.buildBorrowBinding(index),
                .@"pub" => return self.reject(index, .misplaced_pub),
                .import, .selective_import => return self.reject(index, .import_outside_top_level),
                .return_nothing => if (!self.can_return)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_nothing = span },
                .return_expr => if (!self.can_return)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_value = try self.appendUse(node.data.node, self.returns_type) },
                .fail_expr => .{ .failure = span },
                .break_nothing, .break_expr => try self.buildBreak(index, result_is_type),
                .continue_expr => try self.buildContinue(index),
                .assign => if (self.isDiscardAssignment(index))
                    .{ .lifetime_extend = try self.appendUse(node.data.node_node.b, false) }
                else
                    .{ .discard = try self.appendUse(index, false) },
                else => if (isFallibleExpression(node.tag))
                    .{ .propagate = .{ .condition = try self.buildCondition(index), .span = span } }
                else
                    .{ .discard = try self.appendUse(index, false) },
            };
        }

        fn isDiscardAssignment(self: *const Self, index: structures.Node.Index) bool {
            const target_index = self.ast.nodes[index.index()].data.node_node.a;
            const target = self.ast.nodes[target_index.index()];
            if (target.tag != .identifier) return false;
            const span = tokenSpan(self.ast, target.token_index);
            return std.mem.eql(u8, self.source[span.start..span.end], "_");
        }

        fn buildBreak(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.Statement {
            if (self.loop_depth == 0) return self.reject(index, .break_outside_loop);
            const node = self.ast.nodes[index.index()];
            const value = if (node.tag == .break_expr)
                try self.append(node.data.node, result_is_type)
            else
                try self.appendExpression(index, .unit);
            return .{ .break_loop = value };
        }

        fn buildContinue(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            if (self.loop_depth == 0) return self.reject(index, .continue_outside_loop);
            return .{ .continue_loop = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index) };
        }

        fn nameIsVisible(self: *Self, name: []const u8) !bool {
            return self.locals.contains(name) or try self.type_interner.resolveLocalConflict(name) != null;
        }

        fn buildBinding(self: *Self, index: structures.Node.Index) anyerror!UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            const annotation = node.data.node_node.a.unwrap();
            const expected = if (annotation) |type_node| try self.bindingType(type_node) else null;
            var value = try self.append(node.data.node_node.b, false);
            if (expected) |type_id| {
                value = try self.appendExpression(annotation.?, .{ .annotation = .{ .value = .{
                    .value = value,
                    .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                }, .type_id = type_id } });
            }
            const local: UnresolvedBody.LocalId = @fromBackingInt(@intCast(self.local_count));
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

        fn buildBorrowBinding(self: *Self, index: structures.Node.Index) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            const source = try self.append(node.data.node_node.b, false);
            const local: UnresolvedBody.LocalId = @fromBackingInt(@intCast(self.local_count));
            self.local_count += 1;
            const writable = node.tag == .borrow_mut_binding;
            try self.locals.put(self.gpa, name, .{ .borrow = .{ .id = local, .writable = writable } });
            try self.local_names.append(self.gpa, name);
            return .{ .bind_borrow = .{
                .local = local,
                .source = source,
                .span = nodeFocusSpan(self.ast, node.data.node_node.b),
                .writable = writable,
            } };
        }

        fn bindingType(self: *Self, node: structures.Node.Index) !structures.TypeId {
            if (runtimeReference(self.ast, self.source, node, self)) |reference| return self.reject(reference, .value_used_as_type);
            const result = try analyzeType(self.ast, self.source, node, self.type_interner, self.gpa, .local_type_not_supported);
            switch (result) {
                .success => |type_id| if (type_id == .type) {
                    self.issue = issueAt(self.ast, node.index(), .local_type_not_supported);
                    return error.SourceRejected;
                } else return type_id,
                .unsupported => |issue| {
                    self.issue = issue;
                    return error.SourceRejected;
                },
            }
        }

        fn appendCompileTimeValue(self: *Self, index: structures.Node.Index, runtime: structures.CompileTimeValue.Runtime) !ValueId {
            const primitive = try switch (runtime.value) {
                .int => |integer| self.appendExpression(index, .{ .integer = integer }),
                .int_literal => |integer| self.appendExpression(index, .{ .int_literal_value = integer }),
                .string_literal => |data| self.appendExpression(index, .{ .string_literal = data }),
                .static_data => |data| self.appendExpression(index, .{ .static_data = data }),
                .storage_cursor => |cursor| self.appendExpression(index, .{ .storage_cursor = cursor }),
                .byte => |byte| self.appendExpression(index, .{ .byte = byte }),
                .bool => |boolean| self.appendExpression(index, .{ .boolean = boolean }),
                .unit => self.appendExpression(index, .unit),
                .none => self.appendExpression(index, .none),
                .function_ref => |reference| self.appendExpression(index, .{ .function_ref = reference }),
                .structure => |tuple_id| blk: {
                    if (try self.type_interner.arrayType(runtime.type_id)) |array|
                        break :blk try self.appendCompileTimeArray(index, runtime.type_id, array, tuple_id);
                    const definition = (try self.type_interner.structDefinition(runtime.type_id)) orelse return error.Unavailable;
                    const values = try self.type_interner.lookupCompileTimeTuple(tuple_id);
                    std.debug.assert(values.len == definition.fields.len);
                    var fields: std.ArrayList(UnresolvedBody.StructFieldValue) = .empty;
                    defer fields.deinit(self.gpa);
                    for (definition.fields, values) |field, value_id| {
                        const value = switch (try self.type_interner.lookupCompileTimeValue(value_id)) {
                            .runtime => |value| value,
                            .type => unreachable,
                        };
                        try fields.append(self.gpa, .{
                            .name = field.name,
                            .name_span = field.span,
                            .value = .{ .value = try self.appendCompileTimeValue(index, value), .span = nodeFocusSpan(self.ast, index) },
                        });
                    }
                    const start: u32 = @intCast(self.struct_field_values.items.len);
                    try self.struct_field_values.appendSlice(self.gpa, fields.items);
                    break :blk self.appendExpression(index, .{ .struct_init = .{
                        .canonical = true,
                        .target = .{ .concrete = runtime.type_id },
                        .type_span = nodeFocusSpan(self.ast, index),
                        .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
                    } });
                },
                .variant => |variant| blk: {
                    const payload = switch (try self.type_interner.lookupCompileTimeValue(variant.payload)) {
                        .runtime => |value| value,
                        .type => unreachable,
                    };
                    var value = try self.appendCompileTimeValue(index, payload);
                    if (payload.type_id != variant.member_type) value = try self.appendExpression(index, .{ .annotation = .{
                        .value = .{ .value = value, .span = nodeFocusSpan(self.ast, index) },
                        .type_id = variant.member_type,
                    } });
                    break :blk value;
                },
            };
            const representation_type = runtime.value.scalarTypeId() orelse switch (runtime.value) {
                .structure => runtime.type_id,
                .variant => |variant| variant.member_type,
                else => unreachable,
            };
            if (runtime.type_id == representation_type) return primitive;
            return self.appendExpression(index, .{ .annotation = .{
                .value = .{ .value = primitive, .span = nodeFocusSpan(self.ast, index) },
                .type_id = runtime.type_id,
            } });
        }

        fn appendTypeValue(self: *Self, index: structures.Node.Index) !ValueId {
            const result = try analyzeType(self.ast, self.source, index, self.type_interner, self.gpa, .type_value_used_as_runtime_value);
            return switch (result) {
                .success => |type_id| self.appendExpression(index, .{ .type_value = type_id }),
                .unsupported => |issue| {
                    self.issue = issue;
                    return error.SourceRejected;
                },
            };
        }

        fn appendCompileTimeArray(self: *Self, index: structures.Node.Index, type_id: structures.TypeId, array: structures.ArrayType, tuple_id: structures.CompileTimeValueTupleId) anyerror!ValueId {
            const values = try self.type_interner.lookupCompileTimeTuple(tuple_id);
            std.debug.assert(values.len == array.length);
            var elements: std.ArrayList(UnresolvedBody.ValueUse) = .empty;
            defer elements.deinit(self.gpa);
            for (values) |value_id| {
                const value = (try self.type_interner.lookupCompileTimeValue(value_id)).runtime;
                std.debug.assert(value.type_id == array.element_type);
                try elements.append(self.gpa, .{ .value = try self.appendCompileTimeValue(index, value), .span = nodeFocusSpan(self.ast, index) });
            }
            const start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.appendSlice(self.gpa, elements.items);
            return self.appendExpression(index, .{ .array_init = .{
                .type_id = type_id,
                .elements = .{ .start = start, .end = @intCast(self.call_arguments.items.len) },
            } });
        }

        fn appendCollectionLiteral(self: *Self, index: structures.Node.Index) !ValueId {
            var elements: std.ArrayList(UnresolvedBody.ValueUse) = .empty;
            defer elements.deinit(self.gpa);
            for (self.ast.nodeList(index)) |element| try elements.append(self.gpa, try self.appendUse(element, false));
            const start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.appendSlice(self.gpa, elements.items);
            return self.appendExpression(index, .{ .collection_literal = .{ .start = start, .end = @intCast(self.call_arguments.items.len) } });
        }

        fn append(self: *Self, index: structures.Node.Index, result_is_type: bool) anyerror!ValueId {
            const node = self.ast.nodes[index.index()];
            switch (node.tag) {
                .number_literal => return self.appendInteger(index),
                .string_literal => return self.appendString(index),
                .bool_literal => return self.appendExpression(index, .{ .boolean = self.ast.tokens[node.token_index].tag == .keyword_true }),
                .unit_literal => return self.appendExpression(index, if (result_is_type) .{ .type_value = .unit } else .unit),
                .none_literal => return self.appendExpression(index, if (result_is_type) .{ .type_value = .none } else .none),
                .type, .implicit_type, .type_func, .type_variant => return self.appendTypeValue(index),
                .comptime_expr => {
                    try self.rejectRuntimeCapture(index);
                    const value_id = self.type_interner.executeComptime(index) catch |err| switch (err) {
                        error.QueryCycle => return self.reject(index, .declaration_cycle),
                        error.Unavailable => return error.Unavailable,
                        else => return err,
                    } orelse return error.Unavailable;
                    const value = try self.type_interner.lookupCompileTimeValue(value_id);
                    return switch (value) {
                        .type => |type_id| self.appendExpression(index, .{ .type_value = type_id }),
                        .runtime => |runtime| blk: {
                            break :blk try self.appendCompileTimeValue(index, runtime);
                        },
                    };
                },
                .call => return self.appendCall(index),
                .struct_init => return self.appendStructInit(index),
                .collection_literal => return self.appendCollectionLiteral(index),
                .field_access => return self.appendFieldAccess(index),
                .deref => return self.appendExpression(index, .{ .dereference = try self.appendUse(node.data.node, false) }),
                .index_access => return self.appendExpression(index, .{ .call = try self.buildIndexCall(index) }),
                .@"struct" => return self.appendExpression(index, .{ .type_value = try self.type_interner.generatedStructType(index) }),
                .identifier => return self.appendIdentifier(index, result_is_type),
                .neg => {
                    const operand = self.ast.nodes[node.data.node.index()];
                    if (operand.tag == .number_literal) {
                        const span = tokenSpan(self.ast, operand.token_index);
                        return switch (parseIntegerLiteral(self.source[span.start..span.end], true)) {
                            .value => |integer| self.appendExpression(index, .{ .integer_literal = integer }),
                            .unsupported => |kind| self.reject(index, kind),
                        };
                    }
                    return self.appendOperationCall(index, "-", &.{try self.appendUse(node.data.node, false)});
                },
                .add, .sub, .mul, .div => return self.appendBinary(index),
                .eq, .ne, .lt, .gt, .le, .ge, .not, .@"and", .@"or" => return self.appendConditionValue(index),
                .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => return self.appendAssignment(index),
                .@"if", .if_else => return self.appendIf(index, result_is_type),
                .loop => return self.appendLoop(index, result_is_type),
                .static_binding, .namespace_declaration => return self.reject(index, .nested_declaration_not_supported),
                .move_expr => return self.appendTransfer(index),
                else => return self.reject(index, .expression_not_supported),
            }
        }

        fn appendIdentifier(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (std.mem.eql(u8, name, "int")) return self.appendExpression(index, .{ .type_value = .int });
            if (std.mem.eql(u8, name, "byte")) return self.appendExpression(index, .{ .type_value = .byte });
            if (std.mem.eql(u8, name, "bool")) return self.appendExpression(index, .{ .type_value = .bool });
            if (std.mem.eql(u8, name, "never")) return self.appendExpression(index, .{ .type_value = .never });
            if (std.mem.eql(u8, name, "type")) return self.appendExpression(index, .{ .type_value = .type });
            if (self.locals.get(name)) |local| return switch (local) {
                .value => |value| value,
                .static_value => |value| self.appendConstant(index, value),
                .type_value => |type_id| self.appendExpression(index, .{ .type_value = type_id }),
                .place => |place| self.appendExpression(index, .{ .local_read = place.id }),
                .borrow => |borrow| self.appendExpression(index, .{ .local_read = borrow.id }),
            };
            if (std.mem.eql(u8, name, "unit")) return self.appendExpression(index, if (result_is_type) .{ .type_value = .unit } else .unit);
            const reference = (try self.namedExpression(index)) orelse return self.reject(index, .unknown_value);
            return self.appendNamedReference(index, reference);
        }

        fn appendTransfer(self: *Self, index: structures.Node.Index) !ValueId {
            const operand_index = self.ast.nodes[index.index()].data.node;
            const field_start: u32 = @intCast(self.assignment_fields.items.len);
            var root_index = operand_index;
            var operand = self.ast.nodes[root_index.index()];
            while (operand.tag == .field_access) {
                const field_span = tokenSpan(self.ast, operand.token_index);
                try self.assignment_fields.append(self.gpa, .{
                    .name = self.source[field_span.start..field_span.end],
                    .span = field_span,
                });
                root_index = operand.data.node;
                operand = self.ast.nodes[root_index.index()];
            }
            std.mem.reverse(UnresolvedBody.FieldName, self.assignment_fields.items[field_start..]);
            if (operand.tag != .identifier) return self.reject(index, .ownership_transfer_requires_place);
            const span = tokenSpan(self.ast, operand.token_index);
            const name = self.source[span.start..span.end];
            const local = self.locals.get(name) orelse return self.reject(root_index, .unknown_value);
            return switch (local) {
                .value, .static_value, .type_value, .borrow => self.reject(index, .ownership_transfer_requires_owned_place),
                .place => |place| self.appendExpression(index, if (field_start == self.assignment_fields.items.len)
                    .{ .local_transfer = place.id }
                else
                    .{ .field_transfer = .{ .target = place.id, .fields = .{
                        .start = field_start,
                        .end = @intCast(self.assignment_fields.items.len),
                    } } }),
            };
        }

        fn appendStructInit(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const parts = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
            std.debug.assert(parts.len >= 1);
            if (runtimeReference(self.ast, self.source, parts[0], self)) |reference| return self.reject(reference, .value_used_as_type);
            const target: UnresolvedBody.StructInitTarget = target_blk: {
                if (try self.namedExpression(parts[0])) |reference| {
                    if (reference == .declaration and try self.type_interner.isGenericStruct(reference.declaration.item))
                        break :target_blk .{ .inferred = reference.declaration };
                }
                const type_id = switch (try analyzeType(self.ast, self.source, parts[0], self.type_interner, self.gpa, .local_type_not_supported)) {
                    .success => |resolved| resolved,
                    .unsupported => |issue| {
                        self.issue = issue;
                        return error.SourceRejected;
                    },
                };
                break :target_blk .{ .concrete = type_id };
            };
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            for (parts[1..]) |field_index| {
                const field = self.ast.nodes[field_index.index()];
                std.debug.assert(field.tag == .struct_init_field);
                try self.scratch.append(self.gpa, try self.append(field.data.node, false));
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
                .target = target,
                .type_span = nodeFocusSpan(self.ast, parts[0]),
                .fields = .{ .start = start, .end = @intCast(self.struct_field_values.items.len) },
            } });
        }

        fn namedExpression(self: *Self, index: structures.Node.Index) !?structures.NameReference {
            return self.namedExpressionWithOperands(index, null);
        }

        fn namedExpressionWithOperands(self: *Self, index: structures.Node.Index, operands: ?usize) !?structures.NameReference {
            if (runtimeReference(self.ast, self.source, index, self) != null) return null;
            return resolveNamedExpressionWithOperands(self.ast, self.source, index, self.type_interner, operands) catch |err| switch (err) {
                error.QueryCycle => return self.reject(index, .declaration_cycle),
                error.PublicFieldPrivateType => return self.reject(index, .public_field_private_type),
                else => return err,
            };
        }

        fn runtimeName(self: *Self, name: []const u8) bool {
            const local = self.locals.get(name) orelse return false;
            return local == .value or local == .place or local == .borrow;
        }

        fn rejectRuntimeCapture(self: *Self, index: structures.Node.Index) !void {
            if (runtimeReference(self.ast, self.source, index, self)) |reference|
                return self.reject(reference, .comptime_runtime_capture);
        }

        fn appendNamedReference(self: *Self, index: structures.Node.Index, reference: structures.NameReference) !ValueId {
            switch (reference) {
                .namespace => return self.reject(index, .namespace_used_as_value),
                .constant => |value| return self.appendConstant(index, value),
                .declaration => |instance| return self.appendDeclarationReference(index, instance),
                .overloaded_function => |choices| return self.appendExpression(index, .{ .overloaded_function = choices }),
            }
        }

        fn appendDeclarationReference(self: *Self, index: structures.Node.Index, instance: structures.InstanceId) !ValueId {
            if (try self.type_interner.functionShape(instance.item)) |shape| {
                for (shape.parameters) |parameter| {
                    if (parameter.mode == .static) return self.reject(index, .static_parameter_requires_specialization);
                }
                const function = (try self.type_interner.functionItemReference(instance)) orelse return self.reject(index, .unknown_value);
                return self.appendExpression(index, .{ .function_ref = function });
            }
            const value = (self.type_interner.staticItem(instance) catch |err| switch (err) {
                error.QueryCycle => return self.reject(index, .declaration_cycle),
                else => return err,
            }) orelse return self.reject(index, .unknown_value);
            return self.appendConstant(index, value);
        }

        fn appendConstant(self: *Self, index: structures.Node.Index, value: structures.CompileTimeValueId) !ValueId {
            return switch (try self.type_interner.lookupCompileTimeValue(value)) {
                .type => |type_id| self.appendExpression(index, .{ .type_value = type_id }),
                .runtime => |runtime| self.appendCompileTimeValue(index, runtime),
            };
        }

        fn appendFieldAccess(self: *Self, index: structures.Node.Index) !ValueId {
            if (try self.namedExpression(index)) |reference| return self.appendNamedReference(index, reference);
            const node = self.ast.nodes[index.index()];
            const name_span = tokenSpan(self.ast, node.token_index);
            return self.appendExpression(index, .{ .field_access = .{
                .operand = try self.appendUse(node.data.node, false),
                .name = self.source[name_span.start..name_span.end],
            } });
        }

        fn appendUse(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.ValueUse {
            return .{
                .value = try self.append(index, result_is_type),
                .span = nodeFocusSpan(self.ast, index),
            };
        }

        fn appendLoop(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
            const node = self.ast.nodes[index.index()];
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            const body = try self.buildBranch(node.data.node, result_is_type);
            return self.appendExpression(index, .{ .loop = body });
        }

        fn appendString(self: *Self, index: structures.Node.Index) !ValueId {
            const span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index);
            const decoded = try text_literal.decode(self.gpa, self.source[span.start..span.end]);
            switch (decoded) {
                .bytes => |bytes| {
                    defer self.gpa.free(bytes);
                    return self.appendExpression(index, .{ .string_literal = try self.type_interner.internByteString(bytes) });
                },
                .invalid => |issue| {
                    self.issue = .{ .span = .{ .start = span.start + issue.offset, .end = span.start + issue.offset + 1 }, .kind = issue.kind };
                    return error.SourceRejected;
                },
            }
        }

        fn appendInteger(self: *Self, index: structures.Node.Index) !ValueId {
            const span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index);
            const literal = self.source[span.start..span.end];
            return switch (parseIntegerLiteral(literal, false)) {
                .value => |value| self.appendExpression(index, .{ .integer_literal = value }),
                .unsupported => |kind| self.reject(index, kind),
            };
        }

        fn appendBinary(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const operands: UnresolvedBody.BinaryOperands = .{
                .lhs = try self.appendUse(node.data.node_node.a, false),
                .rhs = try self.appendUse(node.data.node_node.b, false),
            };
            const name: []const u8 = switch (node.tag) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
                else => unreachable,
            };
            return self.appendOperationCall(index, name, &.{ operands.lhs, operands.rhs });
        }

        fn appendOperationCall(self: *Self, index: structures.Node.Index, name: []const u8, operands: []const UnresolvedBody.ValueUse) !ValueId {
            const start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.appendSlice(self.gpa, operands);
            return self.appendExpression(index, .{ .call = .{
                .target = .{ .operation = name },
                .arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) },
                .span = nodeFocusSpan(self.ast, index),
            } });
        }

        fn buildIndexCall(self: *Self, index: structures.Node.Index) !UnresolvedBody.Call {
            const node = self.ast.nodes[index.index()];
            const receiver = try self.appendUse(node.data.node_node.a, false);
            const offset = try self.appendIndexOffset(node.data.node_node.b);
            const start: u32 = @intCast(self.call_arguments.items.len);
            try self.call_arguments.appendSlice(self.gpa, &.{ receiver, offset });
            return .{ .target = .{ .operation = "[]" }, .arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) }, .span = nodeFocusSpan(self.ast, index) };
        }

        fn appendIndexOffset(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            return .{ .value = try self.appendExpression(index, .{ .index_snapshot = try self.appendUse(index, false) }), .span = nodeFocusSpan(self.ast, index) };
        }

        fn appendAssignment(self: *Self, index: structures.Node.Index) !ValueId {
            const node = self.ast.nodes[index.index()];
            const target_node_value = self.ast.nodes[node.data.node_node.a.index()];
            if (target_node_value.tag == .index_access) {
                const receiver = try self.appendUse(target_node_value.data.node_node.a, false);
                const offset = try self.appendIndexOffset(target_node_value.data.node_node.b);
                var value = try self.appendUse(node.data.node_node.b, false);
                var old: ?UnresolvedBody.ValueUse = null;
                if (node.tag != .assign) {
                    old = .{ .value = try self.appendOperationCall(index, "[]", &.{ receiver, offset }), .span = nodeFocusSpan(self.ast, index) };
                    value.value = try self.appendOperationCall(index, assignmentOperationName(node.tag), &.{ old.?, value });
                }
                const setter = try self.appendOperationCall(index, "[]=", &.{ receiver, offset, value });
                return if (old) |previous| self.appendExpression(index, .{ .sequence = .{
                    .lhs = previous,
                    .rhs = .{ .value = setter, .span = nodeFocusSpan(self.ast, index) },
                } }) else setter;
            }
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
            if (target_node.tag == .deref and field_start == self.assignment_fields.items.len) {
                const reference = try self.appendUse(target_node.data.node, false);
                const value = try self.assignmentOperand(index);
                return self.appendExpression(index, .{ .reference_assignment = .{ .reference = reference, .value = value } });
            }
            if (target_node.tag != .identifier) return self.reject(node.data.node_node.a, .assignment_target_not_local);
            const span = tokenSpan(self.ast, target_node.token_index);
            const name = self.source[span.start..span.end];
            const local = self.locals.get(name) orelse return self.reject(target_index, .unknown_value);
            const target = switch (local) {
                .value, .static_value, .type_value => return self.reject(target_index, .assignment_to_immutable),
                .place => |place| if (place.mutable) place.id else return self.reject(target_index, .assignment_to_immutable),
                .borrow => |borrow| {
                    if (!borrow.writable) return self.reject(target_index, .assignment_to_immutable);
                    const value = try self.assignmentOperand(index);
                    return self.appendExpression(index, .{ .borrow_assignment = .{
                        .target = borrow.id,
                        .target_span = span,
                        .fields = .{ .start = field_start, .end = @intCast(self.assignment_fields.items.len) },
                        .value = value,
                    } });
                },
            };
            const field_end: u32 = @intCast(self.assignment_fields.items.len);
            const value = try self.assignmentOperand(index);
            return self.appendExpression(index, .{ .assignment = .{
                .target = target,
                .target_span = span,
                .fields = .{ .start = field_start, .end = field_end },
                .value = value,
                .replaces = node.tag == .assign,
            } });
        }

        fn assignmentOperationName(tag: structures.Node.Tag) []const u8 {
            return switch (tag) {
                .add_assign => "+",
                .sub_assign => "-",
                .mul_assign => "*",
                .div_assign => "/",
                else => unreachable,
            };
        }

        fn assignmentOperand(self: *Self, index: structures.Node.Index) !UnresolvedBody.ValueUse {
            const node = self.ast.nodes[index.index()];
            var value = try self.appendUse(node.data.node_node.b, false);
            if (node.tag != .assign) value.value = try self.appendOperationCall(index, assignmentOperationName(node.tag), &.{
                try self.appendUse(node.data.node_node.a, false), value,
            });
            return value;
        }

        fn appendIf(self: *Self, index: structures.Node.Index, result_is_type: bool) !ValueId {
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
            const then_block = try self.buildBranch(then_index, result_is_type);
            self.restoreScope(condition_scope);
            const else_block = if (else_index) |explicit_else|
                try self.buildBranch(explicit_else, result_is_type)
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
            if (node.tag != .const_binding and node.tag != .var_binding and node.tag != .borrow_binding and node.tag != .borrow_mut_binding) return self.buildCondition(index);
            if (node.tag == .var_binding) return self.reject(index, .condition_binding_must_be_immutable);

            const value_index = node.data.node_node.b;
            const value_node = self.ast.nodes[value_index.index()];
            const borrow_mode: ?bool = switch (node.tag) {
                .borrow_binding => false,
                .borrow_mut_binding => true,
                else => null,
            };
            if (borrow_mode != null and value_node.tag != .as) return self.reject(index, .borrow_requires_place);

            const span = tokenSpan(self.ast, node.token_index);
            const name = self.source[span.start..span.end];
            if (try self.nameIsVisible(name)) return self.reject(index, .duplicate_local_binding);
            const local: UnresolvedBody.LocalId = @fromBackingInt(@intCast(self.local_count));
            self.local_count += 1;
            const annotation_type = if (node.data.node_node.a.unwrap()) |annotation| try self.bindingType(annotation) else null;
            const binding: UnresolvedBody.ConditionBinding = .{
                .borrow_mode = borrow_mode,
                .local = local,
                .annotation_type = annotation_type,
                .span = nodeFocusSpan(self.ast, value_index),
            };
            const condition = if (value_node.tag == .as)
                try self.buildVariantMembership(value_node, binding)
            else if (value_node.tag == .call)
                try self.appendCondition(.{ .call = .{ .target = try self.buildCall(value_index, true), .binding = binding } })
            else if (value_node.tag == .index_access)
                try self.appendCondition(.{ .call = .{ .target = try self.buildIndexCall(value_index), .binding = binding } })
            else
                try self.appendCondition(.{ .initialization = .{ .value = try self.appendUse(value_index, false), .binding = binding } });

            try self.locals.put(self.gpa, name, if (borrow_mode) |writable| .{ .borrow = .{ .id = local, .writable = writable } } else .{ .place = .{ .id = local, .mutable = false } });
            try self.local_names.append(self.gpa, name);
            return condition;
        }

        fn appendConditionValue(self: *Self, index: structures.Node.Index) !ValueId {
            const condition = try self.buildCondition(index);
            const then_value = try self.appendExpression(index, .{ .boolean = true });
            const else_value = try self.appendExpression(index, .{ .boolean = false });
            return self.appendExpression(index, .{ .if_else = .{
                .condition = condition,
                .then_block = try self.finishBlock(&.{}, then_value, nodeFocusSpan(self.ast, index)),
                .else_block = try self.finishBlock(&.{}, else_value, nodeFocusSpan(self.ast, index)),
            } });
        }

        fn buildCondition(self: *Self, index: structures.Node.Index) !UnresolvedBody.ConditionId {
            const node = self.ast.nodes[index.index()];
            return switch (node.tag) {
                .lt, .gt, .le, .ge, .eq, .ne => self.appendCondition(.{ .comparison = .{
                    .operation = comparisonOperation(node.tag),
                    .operands = .{
                        .lhs = try self.appendUse(node.data.node_node.a, false),
                        .rhs = try self.appendUse(node.data.node_node.b, false),
                    },
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
                .not => self.buildNotCondition(node.data.node),
                .call => self.appendCondition(.{ .call = .{ .target = try self.buildCall(index, true) } }),
                .index_access => self.appendCondition(.{ .call = .{ .target = try self.buildIndexCall(index) } }),
                .assign, .add_assign, .sub_assign, .mul_assign, .div_assign => self.buildIndexedAssignmentCondition(index),
                .collection_literal, .struct_init => self.appendCondition(.{ .initialization = .{ .value = try self.appendUse(index, false) } }),
                .identifier, .bool_literal, .field_access, .deref => self.appendCondition(.{ .boolean = try self.appendUse(index, false) }),
                else => self.rejectCondition(index),
            };
        }

        fn buildIndexedAssignmentCondition(self: *Self, index: structures.Node.Index) anyerror!UnresolvedBody.ConditionId {
            const node = self.ast.nodes[index.index()];
            if (self.ast.nodes[node.data.node_node.a.index()].tag != .index_access) return self.rejectCondition(index);
            const value = try self.appendAssignment(index);
            if (node.tag == .assign) return self.appendCondition(.{ .call = .{ .target = self.expressions.items[@backingInt(value) - self.parameters.len].operation.call } });
            const sequence = self.expressions.items[@backingInt(value) - self.parameters.len].operation.sequence;
            const previous_index = @backingInt(sequence.lhs.value) - self.parameters.len;
            const getter = self.expressions.items[previous_index].operation.call;
            const local: UnresolvedBody.LocalId = @fromBackingInt(@intCast(self.local_count));
            self.local_count += 1;
            self.expressions.items[previous_index].operation = .{ .local_read = local };
            const before = try self.appendCondition(.{ .call = .{
                .target = getter,
                .binding = .{ .local = local, .annotation_type = null, .span = sequence.lhs.span },
                .allow_infallible = true,
            } });
            const after = try self.appendCondition(.{ .call = .{ .target = self.expressions.items[@backingInt(sequence.rhs.value) - self.parameters.len].operation.call } });
            return self.appendCondition(.{ .conjunction = .{ .lhs = before, .rhs = after, .temporary = local } });
        }

        fn buildNotCondition(self: *Self, index: structures.Node.Index) anyerror!UnresolvedBody.ConditionId {
            return switch (self.ast.nodes[index.index()].tag) {
                .is, .as => self.appendCondition(.{ .negation = try self.buildCondition(index) }),
                .call => self.appendCondition(.{ .operation_not = .{
                    .value = try self.appendExpression(index, .{ .call = try self.buildCall(index, true) }),
                    .span = nodeFocusSpan(self.ast, index),
                } }),
                else => self.appendCondition(.{ .operation_not = try self.appendUse(index, false) }),
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
            if (self.where_condition and node.tag == .is) return self.appendCondition(.{ .static_membership = .{
                .operand = node.data.node_node.a,
                .target_type = target_type,
            } });
            return self.appendCondition(.{ .variant_membership = .{
                .operand = try self.appendUse(node.data.node_node.a, false),
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
            const id: UnresolvedBody.ConditionId = @fromBackingInt(@intCast(self.conditions.items.len));
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

        fn buildBranch(self: *Self, index: structures.Node.Index, result_is_type: bool) !UnresolvedBody.BlockId {
            const scope_mark = self.local_names.items.len;
            defer self.restoreScope(scope_mark);

            const node = self.ast.nodes[index.index()];
            if (node.tag != .block) {
                if (node.tag == .return_nothing or node.tag == .return_expr or node.tag == .break_nothing or node.tag == .break_expr or node.tag == .continue_expr or node.tag == .fail_expr) {
                    var statements = [_]UnresolvedBody.Statement{try self.buildStatement(index, result_is_type)};
                    return self.finishBlock(&statements, null, tokenSpan(self.ast, node.token_index));
                }
                return self.finishBlock(&.{}, try self.append(index, result_is_type), tokenSpan(self.ast, node.token_index));
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
                .const_binding, .var_binding, .borrow_binding, .borrow_mut_binding, .return_nothing, .return_expr, .break_nothing, .break_expr, .continue_expr, .fail_expr => blk: {
                    try statements.append(self.gpa, try self.buildStatement(last, result_is_type));
                    break :blk null;
                },
                else => try self.append(last, result_is_type),
            };
            if (result == null and (last_node.tag == .const_binding or last_node.tag == .var_binding or last_node.tag == .borrow_binding or last_node.tag == .borrow_mut_binding)) {
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
            const id: UnresolvedBody.BlockId = @fromBackingInt(@intCast(self.blocks.items.len));
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
            const operation: UnresolvedBody.Expression.Operation = if (try self.conversionTarget(node.data.node_node.a)) |target| operation: {
                if (self.ast.tokens[node.token_index].tag == .question_mark) return self.reject(index, .fallible_call_not_fallible);
                const arguments = self.ast.nodeList(node.data.node_node.b);
                if (arguments.len != 1) return self.reject(index, .{ .call_argument_count_mismatch = .{ .expected = 1, .found = @intCast(arguments.len) } });
                break :operation .{ .annotation = .{ .value = try self.appendUse(arguments[0], false), .type_id = target } };
            } else .{ .call = try self.buildCall(index, false) };
            const result = try self.appendExpression(node.data.node_node.a, operation);
            self.expressions.items[self.expressions.items.len - 1].source_node = index;
            return result;
        }

        fn conversionTarget(self: *Self, index: structures.Node.Index) !?structures.TypeId {
            const node = self.ast.nodes[index.index()];
            if (node.tag == .identifier) {
                const span = tokenSpan(self.ast, node.token_index);
                const name = self.source[span.start..span.end];
                if (std.meta.stringToEnum(structures.TypeId, name)) |primitive| return primitive;
                if (self.locals.get(name)) |local| {
                    return if (local == .type_value) local.type_value else null;
                }
            }
            const reference = (try self.namedExpression(index)) orelse return null;
            const value_id = switch (reference) {
                .namespace, .overloaded_function => return null,
                .constant => |value| value,
                .declaration => |instance| blk: {
                    if (try self.type_interner.functionShape(instance.item) != null) return null;
                    break :blk (try self.type_interner.staticItem(instance)) orelse return null;
                },
            };
            const value = try self.type_interner.lookupCompileTimeValue(value_id);
            return if (value == .type) value.type else null;
        }

        fn buildCall(self: *Self, index: structures.Node.Index, requires_fallible: bool) !UnresolvedBody.Call {
            const node = self.ast.nodes[index.index()];
            const callee_index = node.data.node_node.a;
            const callee = self.ast.nodes[callee_index.index()];
            const span = nodeFocusSpan(self.ast, callee_index);
            const fallible_syntax = self.ast.tokens[node.token_index].tag == .question_mark;
            const DirectTarget = struct {
                instance: structures.InstanceId,
                shape: structures.FunctionShape,
            };
            const PendingTarget = union(enum) {
                direct: DirectTarget,
                unknown_function,
                value: UnresolvedBody.ValueUse,
            };
            const pending_target: PendingTarget = target: {
                if (try self.namedExpressionWithOperands(callee_index, self.ast.nodeList(node.data.node_node.b).len)) |reference| {
                    if (reference == .declaration) {
                        if (try self.type_interner.functionShape(reference.declaration.item)) |shape|
                            break :target .{ .direct = .{ .instance = reference.declaration, .shape = shape } };
                    }
                    const value = try self.appendNamedReference(callee_index, reference);
                    break :target .{ .value = .{ .value = value, .span = span } };
                }
                if (callee.tag == .field_access) return self.buildMemberCall(node, callee);
                if (callee.tag == .identifier and !self.runtimeName(self.source[span.start..span.end]))
                    break :target .unknown_function;
                break :target .{ .value = try self.appendUse(callee_index, false) };
            };
            if (pending_target == .direct) {
                if (callSyntaxIssue(fallible_syntax, pending_target.direct.shape.is_fallible, requires_fallible)) |kind|
                    return self.reject(callee_index, kind);
            }
            const argument_nodes = self.ast.nodeList(node.data.node_node.b);
            const parameter_shapes: ?[]const structures.FunctionParameterShape = switch (pending_target) {
                .direct => |direct| direct.shape.parameters,
                .unknown_function, .value => null,
            };
            var infer_static = if (pending_target == .direct)
                try self.type_interner.needsInheritedInference(pending_target.direct.instance)
            else
                false;
            if (parameter_shapes) |parameters| {
                var runtime_count: usize = 0;
                for (parameters) |parameter| if (parameter.mode != .static) {
                    runtime_count += 1;
                };
                if (argument_nodes.len == runtime_count and runtime_count != parameters.len) {
                    infer_static = true;
                } else if (infer_static and argument_nodes.len != runtime_count) {
                    return self.reject(callee_index, .static_argument_cannot_be_inferred);
                } else if (argument_nodes.len != parameters.len and runtime_count != parameters.len) {
                    return self.reject(callee_index, .{ .call_argument_count_mismatch = .{
                        .expected = @intCast(parameters.len),
                        .found = @intCast(argument_nodes.len),
                    } });
                }
            }
            const scratch_start = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_start);
            var static_arguments: std.ArrayList(structures.CompileTimeValueId) = .empty;
            defer static_arguments.deinit(self.gpa);
            for (argument_nodes, 0..) |argument, argument_index| {
                if (parameter_shapes) |parameters| if (!infer_static and argument_index < parameters.len and parameters[argument_index].mode == .static) {
                    try self.rejectRuntimeCapture(argument);
                    const result = if (parameters[argument_index].is_meta_type)
                        try analyzeStaticTypeArgument(self.ast, self.source, argument, self.type_interner, self.gpa)
                    else result_blk: {
                        const instance = pending_target.direct.instance;
                        const expected_type = try self.type_interner.staticParameterType(instance, argument_index, static_arguments.items);
                        const value_id = self.type_interner.executeComptimeWithType(argument, expected_type) catch |err| switch (err) {
                            error.QueryCycle => return self.reject(argument, .declaration_cycle),
                            error.Unavailable => return error.Unavailable,
                            else => return err,
                        } orelse return error.Unavailable;
                        break :result_blk SemanticResult(structures.CompileTimeValue){
                            .success = try self.type_interner.lookupCompileTimeValue(value_id),
                        };
                    };
                    const value = switch (result) {
                        .success => |value| value,
                        .unsupported => |issue| return self.reject(argument, issue.kind),
                    };
                    switch (value) {
                        .runtime => |runtime| if (runtime.value == .function_ref) return self.reject(argument, .static_argument_not_supported),
                        .type => {},
                    }
                    try static_arguments.append(self.gpa, try self.type_interner.internCompileTimeValue(value));
                    continue;
                };
                const value = try self.append(argument, false);
                try self.scratch.append(self.gpa, value);
            }
            const start: u32 = @intCast(self.call_arguments.items.len);
            var runtime_index: usize = 0;
            for (argument_nodes, 0..) |argument, argument_index| {
                if (parameter_shapes) |parameters| if (!infer_static and argument_index < parameters.len and parameters[argument_index].mode == .static) continue;
                const value = self.scratch.items[scratch_start + runtime_index];
                runtime_index += 1;
                try self.call_arguments.append(self.gpa, .{
                    .value = value,
                    .span = nodeFocusSpan(self.ast, argument),
                });
            }
            const target: UnresolvedBody.Call.Target = switch (pending_target) {
                .unknown_function => .unknown_function,
                .value => |value| .{ .value = value },
                .direct => |direct| if (infer_static)
                    .{ .inferred = direct.instance }
                else
                    .{ .direct = try self.type_interner.specializeFunction(direct.instance, static_arguments.items) },
            };
            return .{
                .target = target,
                .arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) },
                .span = span,
                .fallible_syntax = fallible_syntax,
            };
        }

        fn buildMemberCall(self: *Self, call: structures.Node, callee: structures.Node) !UnresolvedBody.Call {
            const receiver = try self.appendUse(callee.data.node, false);
            const argument_nodes = self.ast.nodeList(call.data.node_node.b);
            var arguments: std.ArrayList(UnresolvedBody.MethodCallArgument) = .empty;
            defer arguments.deinit(self.gpa);
            for (argument_nodes) |argument| {
                try arguments.append(self.gpa, .{
                    .node = argument,
                    .value = try self.appendUse(argument, false),
                    .runtime_reference = if (runtimeReference(self.ast, self.source, argument, self)) |reference|
                        nodeFocusSpan(self.ast, reference)
                    else
                        null,
                });
            }
            const start: u32 = @intCast(self.method_call_arguments.items.len);
            try self.method_call_arguments.appendSlice(self.gpa, arguments.items);
            const name_span = tokenSpan(self.ast, callee.token_index);
            return .{
                .target = .{ .member = .{
                    .receiver = receiver,
                    .name = self.source[name_span.start..name_span.end],
                } },
                .arguments = .{ .start = start, .end = @intCast(self.method_call_arguments.items.len) },
                .span = name_span,
                .fallible_syntax = self.ast.tokens[call.token_index].tag == .question_mark,
            };
        }

        fn appendExpression(self: *Self, index: structures.Node.Index, operation: UnresolvedBody.Expression.Operation) !ValueId {
            const value: ValueId = @fromBackingInt(@intCast(self.parameters.len + self.expressions.items.len));
            try self.expressions.append(self.gpa, .{ .operation = operation, .span = tokenSpan(self.ast, self.ast.nodes[index.index()].token_index), .source_node = index });
            return value;
        }

        fn finish(self: *Self) !UnresolvedBody {
            const parameter_spans = try self.parameter_spans.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(parameter_spans);
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
            const method_call_arguments = try self.method_call_arguments.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(method_call_arguments);
            const struct_field_values = try self.struct_field_values.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(struct_field_values);
            const assignment_fields = try self.assignment_fields.toOwnedSlice(self.gpa);
            return .{
                .parameter_count = @intCast(self.parameters.len),
                .static_expression_count = self.static_expression_count,
                .parameter_spans = parameter_spans,
                .local_count = self.local_count,
                .expressions = expressions,
                .conditions = conditions,
                .blocks = blocks,
                .statements = statements,
                .call_arguments = call_arguments,
                .method_call_arguments = method_call_arguments,
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

pub fn isExternalFunction(ast: *const structures.Ast, declaration: u32) bool {
    const parts = functionParts(ast, declaration);
    return parts.body == .null;
}

pub fn analyzeFunctionSignature(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SignatureResult {
    return analyzeFunctionInstanceSignature(ast, source, declaration, &.{}, type_interner, gpa);
}

pub fn analyzeFunctionShape(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.FunctionShape) {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    var parameters: std.ArrayList(structures.FunctionParameterShape) = .empty;
    defer parameters.deinit(gpa);
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    for (ast.nodeList(signature.data.signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        std.debug.assert(parameter.tag == .param);
        const mode = parameterMode(ast, parameter) orelse
            return .{ .unsupported = issueAt(ast, parameter.data.node_node.a.unwrap().?.index(), .parameter_mode_not_supported) };
        const name_span = tokenSpan(ast, parameter.token_index);
        const name = source[name_span.start..name_span.end];
        if ((try names.getOrPut(name)).found_existing) {
            return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_parameter } };
        }
        const annotation = parameter.data.node_node.b.unwrap() orelse {
            return .{ .unsupported = .{ .span = name_span, .kind = .parameter_type_missing } };
        };
        try parameters.append(gpa, .{
            .mode = mode,
            .is_meta_type = mode == .static and isMetaTypeAnnotation(ast, source, annotation),
        });
    }
    return .{ .success = .{
        .parameters = try parameters.toOwnedSlice(gpa),
        .returns_type = if (signature.data.signature.return_type.unwrap()) |annotation| isMetaTypeAnnotation(ast, source, annotation) else false,
        .is_fallible = declaredFallibility(ast, ast.nodes[parts.function.index()]),
    } };
}

pub fn parameterizedStructSite(ast: *const structures.Ast, declaration: u32) ?i64 {
    const binding = ast.nodes[declaration];
    if (binding.tag != .static_binding) return null;
    const function = ast.nodes[binding.data.node_node.b.index()];
    if (function.tag != .func) return null;
    const signature = ast.nodes[function.data.node_node.a.index()];
    if (ast.nodes[signature.data.signature.return_type.index()].tag != .implicit_type) return null;
    const body = ast.nodes[function.data.node_node.b.index()];
    if (body.tag != .return_expr or ast.nodes[body.data.node.index()].tag != .@"struct") return null;
    return @as(i64, body.data.node.index()) - @as(i64, declaration);
}

pub fn isDirectlyReturnedStructSite(ast: *const structures.Ast, declaration: u32, node_offset: i64) bool {
    const binding = ast.nodes[declaration];
    if (binding.tag != .static_binding) return false;
    const function = ast.nodes[binding.data.node_node.b.index()];
    if (function.tag != .func) return false;
    const body = ast.nodes[function.data.node_node.b.index()];
    const statements: []const structures.Node.Index = if (body.tag == .block)
        ast.node_refs[body.data.ref.start..body.data.ref.end]
    else
        &.{function.data.node_node.b};
    for (statements) |statement_index| {
        const statement = ast.nodes[statement_index.index()];
        if (statement.tag != .return_expr) continue;
        const value = statement.data.node;
        if (ast.nodes[value.index()].tag == .@"struct" and
            @as(i64, value.index()) - @as(i64, declaration) == node_offset) return true;
    }
    return false;
}

pub const StaticInference = union(enum) {
    arguments: []structures.CompileTimeValueId,
    missing,
    conflict,
};

const InferredParameter = struct {
    name: []const u8,
    is_meta_type: bool,
    value: ?structures.CompileTimeValueId = null,

    fn bind(self: *@This(), value: structures.CompileTimeValueId) bool {
        if (self.value) |existing| return existing == value;
        self.value = value;
        return true;
    }
};

pub fn inferStaticArguments(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    argument_types: []const structures.TypeId,
    type_interner: anytype,
    gpa: std.mem.Allocator,
    inherited_from: ?u32,
) !StaticInference {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const parameters = ast.nodeList(signature.data.signature.parameters);
    var inferred: std.ArrayList(InferredParameter) = .empty;
    defer inferred.deinit(gpa);
    if (inherited_from) |owner| {
        const owner_parts = functionParts(ast, owner);
        const owner_signature = ast.nodes[owner_parts.signature.index()];
        try appendInferredStaticParameters(ast, source, ast.nodeList(owner_signature.data.signature.parameters), &inferred, gpa);
    }
    try appendInferredStaticParameters(ast, source, parameters, &inferred, gpa);

    var runtime_index: usize = 0;
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? == .static) continue;
        const actual_type = argument_types[runtime_index];
        runtime_index += 1;
        const annotation = parameter.data.node_node.b.unwrap().?;
        if (!try bindInferredType(ast, source, inferred.items, annotation, actual_type, type_interner)) return .conflict;
    }
    std.debug.assert(runtime_index == argument_types.len);
    return finishStaticInference(inferred.items, gpa);
}

pub fn inferStructArguments(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    fields: []const UnresolvedBody.StructFieldValue,
    field_types: []const structures.TypeId,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !StaticInference {
    std.debug.assert(fields.len == field_types.len);
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const parameters = ast.nodeList(signature.data.signature.parameters);
    var inferred: std.ArrayList(InferredParameter) = .empty;
    defer inferred.deinit(gpa);
    try appendInferredStaticParameters(ast, source, parameters, &inferred, gpa);
    for (fields, field_types) |field, actual_type| {
        const annotation = structFactoryFieldAnnotation(ast, source, declaration, field.name) orelse continue;
        if (!try bindInferredType(ast, source, inferred.items, annotation, actual_type, type_interner)) return .conflict;
    }
    return finishStaticInference(inferred.items, gpa);
}

pub fn validateConverterDeclaration(ast: *const structures.Ast, source: []const u8, declaration: u32, type_interner: anytype) !SemanticResult(void) {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const target = signature.data.signature.return_type.unwrap() orelse return .{ .unsupported = issueAt(ast, declaration, .invalid_converter) };
    var value_annotation: ?structures.Node.Index = null;
    for (ast.nodeList(signature.data.signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        const annotation = parameter.data.node_node.b.unwrap() orelse return .{ .unsupported = issueAt(ast, parameter_index.index(), .parameter_type_missing) };
        const mode = parameterMode(ast, parameter).?;
        if (mode == .static and isMetaTypeAnnotation(ast, source, annotation)) continue;
        const collection_source = try type_interner.isCollectionConverterAnnotation(annotation);
        if (mode == .init) {
            if (!collection_source or value_annotation != null) return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
            value_annotation = annotation;
            continue;
        }
        if (collection_source) return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
        const static_source = try type_interner.isStaticConverterAnnotation(annotation);
        const dependent = converterAnnotationDependsOnStaticParameters(ast, source, declaration, annotation);
        const name_span = tokenSpan(ast, parameter.token_index);
        const inferred_from_target = annotationInfersParameter(ast, source, target, source[name_span.start..name_span.end]);
        if (mode == .static and !static_source and (!dependent or inferred_from_target)) continue;
        if ((!dependent and static_source and mode != .static) or (!dependent and !static_source and mode != .imm) or
            (dependent and mode != .static and mode != .imm) or value_annotation != null)
            return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
        value_annotation = annotation;
    }
    const value = value_annotation orelse return .{ .unsupported = issueAt(ast, declaration, .invalid_converter) };
    for (ast.nodeList(signature.data.signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? != .static or parameter.data.node_node.b == value) continue;
        const span = tokenSpan(ast, parameter.token_index);
        const name = source[span.start..span.end];
        if (!annotationInfersParameter(ast, source, value, name) and !annotationInfersParameter(ast, source, target, name))
            return .{ .unsupported = issueAt(ast, parameter_index.index(), .invalid_converter) };
    }
    const module = try type_interner.currentModule();
    if (try type_interner.converterAnnotationOwner(value) != module and try type_interner.converterAnnotationOwner(target) != module)
        return .{ .unsupported = issueAt(ast, declaration, .invalid_converter_owner) };
    return .{ .success = {} };
}

pub fn converterAnnotationDependsOnStaticParameters(ast: *const structures.Ast, source: []const u8, declaration: u32, annotation: structures.Node.Index) bool {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const scope: ParameterScope = .{ .ast = ast, .source = source, .parameters = ast.nodeList(signature.data.signature.parameters), .static_only = true };
    return runtimeReference(ast, source, annotation, scope) != null;
}

fn annotationInfersParameter(ast: *const structures.Ast, source: []const u8, annotation: structures.Node.Index, name: []const u8) bool {
    const node = ast.nodes[annotation.index()];
    if (node.tag == .identifier or node.tag == .type) {
        const span = tokenSpan(ast, node.token_index);
        return std.mem.eql(u8, source[span.start..span.end], name);
    }
    if (node.tag != .call) return false;
    for (ast.nodeList(node.data.node_node.b)) |argument| {
        if (annotationInfersParameter(ast, source, argument, name)) return true;
    }
    return false;
}

pub fn inferConverterArguments(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    source_type: ?structures.TypeId,
    target_type: structures.TypeId,
    source_value: ?structures.CompileTimeValueId,
    collection_length: ?u32,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !StaticInference {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const parameters = ast.nodeList(signature.data.signature.parameters);
    var inferred: std.ArrayList(InferredParameter) = .empty;
    defer inferred.deinit(gpa);
    try appendInferredStaticParameters(ast, source, parameters, &inferred, gpa);
    var value_count: usize = 0;
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? == .static) continue;
        value_count += 1;
        const annotation = parameter.data.node_node.b.unwrap().?;
        if (source_type) |actual_type| {
            if (!try bindInferredType(ast, source, inferred.items, annotation, actual_type, type_interner)) return .conflict;
        } else if (parameterMode(ast, parameter).? == .init and ast.nodes[annotation.index()].tag == .call) {
            const arguments = ast.nodeList(ast.nodes[annotation.index()].data.node_node.b);
            if (arguments.len == 2) if (inferredParameter(ast, source, inferred.items, arguments[1], false)) |count| {
                const value = try type_interner.internCompileTimeValue(.{ .runtime = .{ .type_id = .int, .value = .{ .int = @intCast(collection_length.?) } } });
                if (!count.bind(value)) return .conflict;
            };
        }
    }
    const target = signature.data.signature.return_type.unwrap() orelse return .missing;
    if (!try bindInferredType(ast, source, inferred.items, target, target_type, type_interner)) return .conflict;
    if (value_count == 0) {
        const value = source_value orelse return .missing;
        var source_parameter: ?*InferredParameter = null;
        for (parameters) |parameter_index| {
            const candidate = ast.nodes[parameter_index.index()];
            const annotation = candidate.data.node_node.b.unwrap().?;
            const span = tokenSpan(ast, candidate.token_index);
            if (parameterMode(ast, candidate).? != .static or isMetaTypeAnnotation(ast, source, annotation)) continue;
            if (!try type_interner.isStaticConverterAnnotation(annotation) and
                (!converterAnnotationDependsOnStaticParameters(ast, source, declaration, annotation) or annotationInfersParameter(ast, source, target, source[span.start..span.end]))) continue;
            if (source_parameter != null) return .missing;
            for (inferred.items) |*parameter| {
                if (std.mem.eql(u8, source[span.start..span.end], parameter.name)) source_parameter = parameter;
            }
            if (!try bindInferredType(ast, source, inferred.items, annotation, source_type.?, type_interner)) return .conflict;
        }
        const parameter = source_parameter orelse return .missing;
        if (!parameter.bind(value)) return .conflict;
    } else if (value_count != 1) return .missing;
    return finishStaticInference(inferred.items, gpa);
}

pub fn analyzeIndependentStructFieldType(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    name: []const u8,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(?structures.TypeId) {
    const annotation = structFactoryFieldAnnotation(ast, source, declaration, name) orelse return .{ .success = null };
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const parameters = ast.nodeList(signature.data.signature.parameters);
    const static_parameters: ParameterScope = .{ .ast = ast, .source = source, .parameters = parameters, .static_only = true };
    if (runtimeReference(ast, source, annotation, static_parameters) != null or ast.nodes[annotation.index()].tag == .call)
        return .{ .success = null };
    return switch (try analyzeType(ast, source, annotation, type_interner, gpa, .struct_field_type_not_supported)) {
        .success => |type_id| .{ .success = type_id },
        .unsupported => |issue| .{ .unsupported = issue },
    };
}

fn structFactoryFieldAnnotation(ast: *const structures.Ast, source: []const u8, declaration: u32, name: []const u8) ?structures.Node.Index {
    std.debug.assert(parameterizedStructSite(ast, declaration) != null);
    const parts = functionParts(ast, declaration);
    const body = ast.nodes[parts.body.index()];
    const struct_node = ast.nodes[body.data.node.index()];
    for (ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
        const item = ast.nodes[member_index.index()];
        const member = if (item.tag == .@"pub") ast.nodes[item.data.node.index()] else item;
        if (member.tag != .struct_field) continue;
        const span = tokenSpan(ast, member.token_index);
        if (std.mem.eql(u8, name, source[span.start..span.end])) return member.data.node;
    }
    return null;
}

fn appendInferredStaticParameters(ast: *const structures.Ast, source: []const u8, parameters: []const structures.Node.Index, inferred: *std.ArrayList(InferredParameter), gpa: std.mem.Allocator) !void {
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? != .static) continue;
        const name_span = tokenSpan(ast, parameter.token_index);
        try inferred.append(gpa, .{
            .name = source[name_span.start..name_span.end],
            .is_meta_type = isMetaTypeAnnotation(ast, source, parameter.data.node_node.b.unwrap().?),
        });
    }
}

fn bindInferredType(ast: *const structures.Ast, source: []const u8, inferred: []InferredParameter, annotation: structures.Node.Index, actual_type: structures.TypeId, type_interner: anytype) !bool {
    const annotated = ast.nodes[annotation.index()];
    if (inferredParameter(ast, source, inferred, annotation, true)) |target| {
        const value = try type_interner.internCompileTimeValue(.{ .type = actual_type });
        return target.bind(value);
    }
    if (annotated.tag != .call) return true;
    const factory = (try resolveNamedExpression(ast, source, annotated.data.node_node.a, type_interner)) orelse return true;
    if (factory != .declaration) return true;
    const values = (try type_interner.structFactoryArguments(factory.declaration, actual_type)) orelse return true;
    const factory_arguments = ast.nodeList(annotated.data.node_node.b);
    if (factory_arguments.len != values.len) return true;
    for (factory_arguments, values) |argument, value| {
        const target = inferredParameter(ast, source, inferred, argument, false) orelse continue;
        if (!target.bind(value)) return false;
    }
    return true;
}

fn finishStaticInference(inferred: []const InferredParameter, gpa: std.mem.Allocator) !StaticInference {
    for (inferred) |parameter| {
        if (parameter.value == null) return .missing;
    }
    const arguments = try gpa.alloc(structures.CompileTimeValueId, inferred.len);
    for (inferred, arguments) |parameter, *argument| {
        argument.* = parameter.value.?;
    }
    return .{ .arguments = arguments };
}

fn inferredParameter(
    ast: *const structures.Ast,
    source: []const u8,
    parameters: []InferredParameter,
    name_index: structures.Node.Index,
    type_only: bool,
) ?*InferredParameter {
    const node = ast.nodes[name_index.index()];
    if (node.tag != .identifier and node.tag != .type) return null;
    const span = tokenSpan(ast, node.token_index);
    const name = source[span.start..span.end];
    for (parameters) |*parameter| {
        if ((!type_only or parameter.is_meta_type) and std.mem.eql(u8, name, parameter.name)) return parameter;
    }
    return null;
}

pub fn analyzeIndependentParameterType(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    runtime_index: usize,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(?structures.TypeId) {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const parameters = ast.nodeList(signature.data.signature.parameters);
    var current: usize = 0;
    for (parameters) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? == .static) continue;
        if (current == runtime_index) {
            const annotation = parameter.data.node_node.b.unwrap().?;
            const static_parameters: ParameterScope = .{ .ast = ast, .source = source, .parameters = parameters, .static_only = true };
            if (runtimeReference(ast, source, annotation, static_parameters) != null) return .{ .success = null };
            if (ast.nodes[annotation.index()].tag == .call) return .{ .success = null };
            return switch (try analyzeType(ast, source, annotation, type_interner, gpa, .parameter_type_not_supported)) {
                .success => |type_id| .{ .success = type_id },
                .unsupported => |issue| .{ .unsupported = issue },
            };
        }
        current += 1;
    }
    unreachable;
}

pub fn analyzeStaticParameterType(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    parameter_index: usize,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.TypeId) {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    const parameters = ast.nodeList(signature.data.signature.parameters);
    std.debug.assert(parameter_index < parameters.len);
    const parameter = ast.nodes[parameters[parameter_index].index()];
    std.debug.assert(parameterMode(ast, parameter).? == .static);
    const annotation = parameter.data.node_node.b.unwrap() orelse unreachable;
    const runtime_parameters: ParameterScope = .{ .ast = ast, .source = source, .parameters = parameters };
    if (runtimeReference(ast, source, annotation, runtime_parameters)) |reference|
        return .{ .unsupported = issueAt(ast, reference.index(), .value_used_as_type) };
    return analyzeType(ast, source, annotation, type_interner, gpa, .parameter_type_not_supported);
}

pub fn analyzeFunctionInstanceSignature(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    specialization: []const structures.CompileTimeValueId,
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
    const runtime_parameters: ParameterScope = .{ .ast = ast, .source = source, .parameters = ast.nodeList(signature.data.signature.parameters) };
    var specialization_index: usize = 0;
    for (ast.nodeList(signature.data.signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        std.debug.assert(parameter.tag == .param);
        const mode = parameterMode(ast, parameter) orelse
            return .{ .unsupported = issueAt(ast, parameter.data.node_node.a.unwrap().?.index(), .parameter_mode_not_supported) };
        const name_span = tokenSpan(ast, parameter.token_index);
        const name = source[name_span.start..name_span.end];
        const named = try names.getOrPut(name);
        if (named.found_existing or try type_interner.resolveLocalConflict(name) != null) {
            return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_parameter } };
        }
        const annotation = parameter.data.node_node.b.unwrap() orelse
            return .{ .unsupported = .{ .span = name_span, .kind = .parameter_type_missing } };
        if (runtimeReference(ast, source, annotation, runtime_parameters)) |reference|
            return .{ .unsupported = issueAt(ast, reference.index(), .value_used_as_type) };
        if (mode == .static) {
            if (specialization_index >= specialization.len) {
                return .{ .unsupported = .{ .span = name_span, .kind = .static_parameter_requires_specialization } };
            }
            const argument = try type_interner.lookupCompileTimeValue(specialization[specialization_index]);
            specialization_index += 1;
            if (isMetaTypeAnnotation(ast, source, annotation)) {
                if (argument != .type) return .{ .unsupported = .{
                    .span = name_span,
                    .kind = .static_argument_type_mismatch,
                } };
            } else {
                const expected = switch (try analyzeType(ast, source, annotation, type_interner, gpa, .parameter_type_not_supported)) {
                    .success => |type_id| type_id,
                    .unsupported => |issue| return .{ .unsupported = issue },
                };
                if (expected == .never or expected == .type) return .{ .unsupported = .{
                    .span = name_span,
                    .kind = .static_argument_type_mismatch,
                } };
                const runtime = switch (argument) {
                    .type => return .{ .unsupported = .{ .span = name_span, .kind = .static_argument_type_mismatch } },
                    .runtime => |runtime| runtime,
                };
                if (runtime.type_id != expected) return .{ .unsupported = .{
                    .span = name_span,
                    .kind = .static_argument_type_mismatch,
                } };
            }
            continue;
        }
        const parameter_type = switch (try analyzeType(ast, source, annotation, type_interner, gpa, .parameter_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        if (parameter_type == .type) return .{ .unsupported = issueAt(ast, annotation.index(), .parameter_type_not_supported) };
        try parameters.append(gpa, .{ .mode = mode, .type_id = parameter_type });
    }
    if (specialization_index != specialization.len) unreachable;

    for (ast.nodeList(signature.data.signature.where_clauses)) |condition| {
        if (runtimeReference(ast, source, condition, runtime_parameters)) |reference|
            return .{ .unsupported = issueAt(ast, reference.index(), .comptime_runtime_capture) };
    }

    const return_annotation = signature.data.signature.return_type;
    if (runtimeReference(ast, source, return_annotation, runtime_parameters)) |reference|
        return .{ .unsupported = issueAt(ast, reference.index(), .value_used_as_type) };
    const return_type = if (return_annotation.unwrap()) |return_type_index|
        switch (try analyzeType(ast, source, return_type_index, type_interner, gpa, .return_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        }
    else
        .unit;

    const function = ast.nodes[parts.function.index()];
    const is_fallible = declaredFallibility(ast, function);
    const annotation = if (binding.tag == .static_binding) binding.data.node_node.a.unwrap() else null;
    if (annotation) |annotation_index| {
        const expected = switch (try analyzeType(ast, source, annotation_index, type_interner, gpa, .function_annotation_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        const actual = try type_interner.facts().internCallable(.{
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
    const owned_parameters = try parameters.toOwnedSlice(gpa);
    errdefer gpa.free(owned_parameters);
    return .{ .success = .{
        .parameters = owned_parameters,
        .return_type = return_type,
        .is_fallible = is_fallible,
    } };
}

fn declaredFallibility(ast: *const structures.Ast, function: structures.Node) bool {
    return ast.tokens[function.token_index].tag == .keyword_fallible or
        (ast.tokens[function.token_index].tag == .keyword_extern and
            ast.tokens[function.token_index + 1].tag == .keyword_fallible);
}

pub fn callSyntaxIssue(fallible_syntax: bool, is_fallible: bool, requires_fallible: bool) ?structures.Diagnostic.Kind {
    if (fallible_syntax and !is_fallible) return .fallible_call_not_fallible;
    if (is_fallible and !requires_fallible and !fallible_syntax) return .fallible_call_requires_marker;
    return null;
}

fn parameterMode(ast: *const structures.Ast, parameter: structures.Node) ?structures.ParameterMode {
    const access = parameter.data.node_node.a.unwrap() orelse return .imm;
    if (ast.nodes[access.index()].tag == .implicit_static) return .static;
    return switch (ast.tokens[ast.nodes[access.index()].token_index].tag) {
        .keyword_imm => .imm,
        .keyword_static => .static,
        .keyword_mut => .mut,
        .keyword_var => .@"var",
        .keyword_deinit => .deinit,
        .keyword_init => .init,
        else => null,
    };
}

fn isFallibleExpression(tag: structures.Node.Tag) bool {
    return switch (tag) {
        .lt, .gt, .le, .ge, .eq, .ne, .is, .as, .@"and", .@"or", .not => true,
        else => false,
    };
}

fn runtimeReference(ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, scope: anytype) ?structures.Node.Index {
    const present = index.unwrap() orelse return null;
    const node = ast.nodes[present.index()];
    if (node.tag == .identifier or node.tag == .type) {
        const span = tokenSpan(ast, node.token_index);
        return if (scope.runtimeName(source[span.start..span.end])) present else null;
    }
    var children = node.children(ast.node_refs);
    for (children.slice()) |child| {
        if (runtimeReference(ast, source, child, scope)) |reference| return reference;
    }
    return null;
}

const ParameterScope = struct {
    ast: *const structures.Ast,
    source: []const u8,
    parameters: []const structures.Node.Index,
    static_only: bool = false,

    fn runtimeName(self: @This(), name: []const u8) bool {
        for (self.parameters) |index| {
            const parameter = self.ast.nodes[index.index()];
            if ((parameterMode(self.ast, parameter) == .static) != self.static_only) continue;
            const span = tokenSpan(self.ast, parameter.token_index);
            if (std.mem.eql(u8, name, self.source[span.start..span.end])) return true;
        }
        return false;
    }
};

pub fn resolveNamedExpression(ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, type_interner: anytype) anyerror!?structures.NameReference {
    return resolveNamedExpressionWithOperands(ast, source, index, type_interner, null);
}

fn resolveNamedExpressionWithOperands(ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, type_interner: anytype, operands: ?usize) anyerror!?structures.NameReference {
    const node = ast.nodes[index.index()];
    const span = tokenSpan(ast, node.token_index);
    switch (node.tag) {
        .identifier, .type => return annotationReference(try type_interner.resolveName(source[span.start..span.end]), type_interner),
        .field_access => {
            const left = (try resolveNamedExpression(ast, source, node.data.node, type_interner)) orelse return null;
            return annotationReference(try type_interner.resolveMemberWithOperands(left, source[span.start..span.end], span, operands), type_interner);
        },
        .call => {
            const callee = (try resolveNamedExpressionWithOperands(ast, source, node.data.node_node.a, type_interner, ast.nodeList(node.data.node_node.b).len)) orelse return null;
            if (callee != .declaration) return null;
            const shape = (try type_interner.functionShape(callee.declaration.item)) orelse return null;
            if (!shape.returns_type) return null;
            const value = (try type_interner.executeComptime(index)) orelse return error.Unavailable;
            return .{ .constant = value };
        },
        else => return null,
    }
}

fn annotationReference(reference: ?structures.NameReference, type_interner: anytype) !?structures.NameReference {
    if (reference) |resolved| {
        if (type_interner.public_annotation and !try type_interner.isPublicAnnotationReference(resolved))
            return error.PublicFieldPrivateType;
    }
    return reference;
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
    if (node.tag == .implicit_type) return .{ .success = .type };
    if (node.tag == .call) {
        const value_id = type_interner.executeComptime(node_index) catch |err| switch (err) {
            error.QueryCycle => return .{ .unsupported = issueAt(ast, node_index.index(), .declaration_cycle) },
            error.Unavailable => return error.Unavailable,
            else => return err,
        } orelse return error.Unavailable;
        return switch (try type_interner.lookupCompileTimeValue(value_id)) {
            .type => |type_id| .{ .success = type_id },
            .runtime => .{ .unsupported = issueAt(ast, node_index.index(), .value_used_as_type) },
        };
    }
    if (node.tag == .type or node.tag == .identifier) {
        const span = tokenSpan(ast, node.token_index);
        const name = source[span.start..span.end];
        if (std.meta.stringToEnum(structures.TypeId, name)) |type_id| return .{ .success = type_id };
        if (std.mem.eql(u8, name, "float")) return .{ .unsupported = .{ .span = span, .kind = .float_type_not_supported } };
    }
    if (node.tag == .type or node.tag == .identifier or node.tag == .field_access) {
        const reference = resolveNamedExpression(ast, source, node_index, type_interner) catch |err| switch (err) {
            error.QueryCycle => return .{ .unsupported = issueAt(ast, node_index.index(), .declaration_cycle) },
            error.PublicFieldPrivateType => return .{ .unsupported = issueAt(ast, node_index.index(), .public_field_private_type) },
            else => return err,
        };
        const target = reference orelse return .{ .unsupported = issueAt(ast, node_index.index(), .unknown_type) };
        const value_id = switch (target) {
            .namespace => return .{ .unsupported = issueAt(ast, node_index.index(), .namespace_used_as_value) },
            .overloaded_function => return .{ .unsupported = issueAt(ast, node_index.index(), .value_used_as_type) },
            .constant => |value| value,
            .declaration => |item| (type_interner.staticItem(item) catch |err| switch (err) {
                error.QueryCycle => return .{ .unsupported = issueAt(ast, node_index.index(), .declaration_cycle) },
                else => return err,
            }) orelse {
                const shape = try type_interner.functionShape(item.item);
                if (shape != null and shape.?.returns_type) return .{ .unsupported = issueAt(ast, node_index.index(), if (try type_interner.isGenericStruct(item.item)) .generic_struct_requires_specialization else .type_factory_requires_call) };
                return .{ .unsupported = issueAt(ast, node_index.index(), .value_used_as_type) };
            },
        };
        return switch (try type_interner.lookupCompileTimeValue(value_id)) {
            .type => |type_id| .{ .success = type_id },
            .runtime => .{ .unsupported = issueAt(ast, node_index.index(), .value_used_as_type) },
        };
    }
    if (node.tag == .type_func) {
        var parameters: std.ArrayList(structures.CallableParameter) = .empty;
        defer parameters.deinit(gpa);
        for (ast.nodeList(node.data.node_node.a)) |parameter_index| {
            const parameter = ast.nodes[parameter_index.index()];
            const explicit_mode = parameter.tag == .param;
            const type_index = if (explicit_mode) parameter.data.node_node.b else parameter_index;
            const parameter_type = switch (try analyzeType(ast, source, type_index, type_interner, gpa, unsupported_kind)) {
                .success => |type_id| type_id,
                .unsupported => |issue| return .{ .unsupported = issue },
            };
            if (parameter_type == .type) return .{ .unsupported = issueAt(ast, parameter_index.index(), unsupported_kind) };
            try parameters.append(gpa, .{ .mode = if (explicit_mode) parameterMode(ast, parameter).? else .imm, .type_id = parameter_type });
        }
        const return_type = switch (try analyzeType(ast, source, node.data.node_node.b, type_interner, gpa, unsupported_kind)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        return .{ .success = try type_interner.facts().internCallable(.{
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
        if (member_type == .type) return .{ .unsupported = issueAt(ast, member_index.index(), unsupported_kind) };
        try member_types.append(gpa, member_type);
    }
    std.debug.assert(member_types.items.len >= 2);

    return switch (try type_interner.facts().internVariant(member_types.items)) {
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

pub const StaticInitializerPlan = union(enum) {
    type_value: structures.TypeId,
    interpret: ?structures.TypeId,
};

pub fn analyzeStaticDeclaration(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(StaticInitializerPlan) {
    const binding = ast.nodes[declaration];
    std.debug.assert(binding.tag == .static_binding);
    const initializer = binding.data.node_node.b.unwrap() orelse unreachable;
    const annotation = binding.data.node_node.a.unwrap() orelse return .{ .success = .{ .interpret = null } };
    if (isMetaTypeAnnotation(ast, source, annotation)) {
        return switch (try analyzeType(ast, source, initializer, type_interner, gpa, .static_initializer_not_supported)) {
            .success => |type_id| .{ .success = .{ .type_value = type_id } },
            .unsupported => |issue| .{ .unsupported = issue },
        };
    }
    const expected = switch (try analyzeType(ast, source, annotation, type_interner, gpa, .static_initializer_not_supported)) {
        .success => |type_id| type_id,
        .unsupported => |issue| return .{ .unsupported = issue },
    };
    if (expected == .type) {
        return .{ .unsupported = issueAt(ast, annotation.index(), .static_initializer_not_supported) };
    }
    return .{ .success = .{ .interpret = expected } };
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
    if (binding.data.node_node.a.unwrap()) |annotation| {
        if (!isMetaTypeAnnotation(ast, source, annotation)) {
            return .{ .unsupported = issueAt(ast, annotation.index(), .static_initializer_not_supported) };
        }
    }
    return analyzeStructMembers(ast, source, initializer, .{ .declared = item_id }, type_interner, gpa);
}

pub fn analyzeGeneratedStructDefinition(
    ast: *const structures.Ast,
    source: []const u8,
    struct_index: structures.Node.Index,
    identity: structures.GeneratedStructIdentity,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.StructDefinition) {
    return analyzeStructMembers(ast, source, struct_index, .{ .generated = identity }, type_interner, gpa);
}

pub fn validateStructNamespace(ast: *const structures.Ast, source: []const u8, struct_index: structures.Node.Index, gpa: std.mem.Allocator) !?Issue {
    var names = structures.Name.Set.init(gpa);
    defer names.deinit();
    const node = ast.nodes[struct_index.index()];
    std.debug.assert(node.tag == .@"struct");
    for (ast.node_refs[node.data.ref.start..node.data.ref.end]) |index| {
        const item = ast.nodes[index.index()];
        const member_index = if (item.tag == .@"pub") item.data.node else index;
        const member = ast.nodes[member_index.index()];
        if (member.tag == .struct_property) continue;
        if (member.tag != .struct_field and member.tag != .static_binding)
            return issueAt(ast, index.index(), .struct_member_not_supported);
        const span = tokenSpan(ast, member.token_index);
        if (std.meta.stringToEnum(structures.OwnershipMember, source[span.start..span.end]) != null)
            return .{ .span = span, .kind = .reserved_ownership_member };
        if ((try names.getOrPut(declarationName(ast, source[span.start..span.end], member_index.index()))).found_existing)
            return .{ .span = span, .kind = .duplicate_struct_member };
    }
    return null;
}

fn analyzeStructMembers(
    ast: *const structures.Ast,
    source: []const u8,
    struct_index: structures.Node.Index,
    identity: structures.StructIdentity,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.StructDefinition) {
    const struct_node = ast.nodes[struct_index.index()];
    std.debug.assert(struct_node.tag == .@"struct");

    var fields: std.ArrayList(structures.StructField) = .empty;
    defer {
        for (fields.items) |field| gpa.free(field.name);
        fields.deinit(gpa);
    }
    if (try validateStructNamespace(ast, source, struct_index, gpa)) |issue| return .{ .unsupported = issue };
    var ownership: structures.StructOwnershipProperties = .{};

    for (ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |member_index| {
        const item = ast.nodes[member_index.index()];
        const member = if (item.tag == .@"pub") ast.nodes[item.data.node.index()] else item;
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
            const value_name = if (value.tag == .identifier) source[value_span.start..value_span.end] else "";
            if (value.tag == .func) {
                const self_type = try type_interner.structIdentityType(identity);
                const mode: structures.ParameterMode, const return_type: structures.TypeId = switch (operation) {
                    .copy => .{ .imm, self_type },
                    .move => .{ .deinit, self_type },
                    .drop => .{ .deinit, .unit },
                };
                const hook = (try type_interner.ownedFunction(identity, property_name)) orelse return error.Unavailable;
                const actual = (try type_interner.functionSignature(hook)) orelse return error.Unavailable;
                const expected_parameter = [_]structures.CallableParameter{.{ .mode = mode, .type_id = self_type }};
                const expected_type = try type_interner.facts().internCallable(.{
                    .parameters = &expected_parameter,
                    .return_type = return_type,
                    .is_fallible = false,
                });
                const actual_type = try type_interner.facts().internCallable(.{
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
                        return .{ .unsupported = .{ .span = value_span, .kind = .{ .invalid_struct_property_value = .move } } };
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
                        return .{ .unsupported = .{ .span = value_span, .kind = .{ .invalid_struct_property_value = .copy } } };
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
                        return .{ .unsupported = .{ .span = value_span, .kind = .{ .invalid_struct_property_value = .drop } } };
                    ownership.drop = .{ .capability = capability, .span = property_span };
                },
            }
            continue;
        }
        if (member.tag == .static_binding) continue;
        std.debug.assert(member.tag == .struct_field);

        const name_span = tokenSpan(ast, member.token_index);
        const name = source[name_span.start..name_span.end];
        var field_interner = type_interner;
        field_interner.public_annotation = item.tag == .@"pub";
        const field_type = switch (try analyzeType(ast, source, member.data.node, field_interner, gpa, .struct_field_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        if (field_type == .type) return .{ .unsupported = issueAt(ast, member.data.node.index(), .struct_field_type_not_supported) };
        if (item.tag == .@"pub") {
            if (!try type_interner.isPublicType(field_type))
                return .{ .unsupported = issueAt(ast, member.data.node.index(), .public_field_private_type) };
        }
        try fields.ensureUnusedCapacity(gpa, 1);
        const owned_name = try gpa.dupe(u8, name);
        fields.appendAssumeCapacity(.{
            .name = owned_name,
            .type_id = field_type,
            .span = name_span,
            .is_public = item.tag == .@"pub",
        });
    }

    return .{ .success = .{ .fields = try fields.toOwnedSlice(gpa), .ownership = ownership, .is_static = struct_node.is_static_struct } };
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
    if (node.tag == .implicit_type) return true;
    const span = tokenSpan(ast, node.token_index);
    return node.tag == .type and std.mem.eql(u8, source[span.start..span.end], "type");
}

const IntegerLiteralResult = union(enum) {
    value: i64,
    unsupported: structures.Diagnostic.Kind,
};

fn parseIntegerLiteral(literal: []const u8, negative: bool) IntegerLiteralResult {
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
    const magnitude = std.fmt.parseInt(u64, literal, 10) catch return .{ .unsupported = .integer_literal_out_of_range };
    if (negative and magnitude == @as(u64, std.math.maxInt(i64)) + 1) return .{ .value = std.math.minInt(i64) };
    const value = std.math.cast(i64, magnitude) orelse return .{ .unsupported = .integer_literal_out_of_range };
    return .{ .value = if (negative) -value else value };
}

pub fn analyzeStaticTypeArgument(
    ast: *const structures.Ast,
    source: []const u8,
    argument: structures.Node.Index,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !SemanticResult(structures.CompileTimeValue) {
    const node = ast.nodes[argument.index()];
    if (node.tag == .unit_literal) return .{ .success = .{ .type = .unit } };
    if (node.tag == .none_literal) return .{ .success = .{ .type = .none } };
    return switch (try analyzeType(ast, source, argument, type_interner, gpa, .static_argument_not_supported)) {
        .success => |type_id| .{ .success = .{ .type = type_id } },
        .unsupported => |issue| .{ .unsupported = issue },
    };
}

pub fn canWidenTo(type_interner: anytype, actual: structures.TypeId, expected: structures.TypeId) !bool {
    if (actual == expected or actual == .never) return true;
    if (try canWidenMember(type_interner, actual, expected)) return true;
    const expected_members = try type_interner.facts().variantMembers(expected) orelse return false;
    const actual_members = try type_interner.facts().variantMembers(actual) orelse &.{actual};
    for (actual_members) |member| {
        if (try widenedVariantTag(type_interner, member, expected_members) == null) return false;
    }
    return true;
}

/// Exact members take precedence over callable widening, regardless of tag order.
pub fn widenedVariantTag(type_interner: anytype, actual: structures.TypeId, members: []const structures.TypeId) !?u32 {
    if (std.mem.indexOfScalar(structures.TypeId, members, actual)) |index| return @intCast(index);
    for (members, 0..) |member, index| {
        if (try canWidenMember(type_interner, actual, member)) return @intCast(index);
    }
    return null;
}

fn canWidenMember(type_interner: anytype, actual: structures.TypeId, expected: structures.TypeId) !bool {
    if (actual == expected) return true;
    const expected_callable = try type_interner.facts().callable(expected) orelse return false;
    const actual_callable = try type_interner.facts().callable(actual) orelse return false;
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
    const body = function.data.node_node.b;
    std.debug.assert(ast.nodes[signature.index()].tag == .signature);
    return .{ .function = if (declaration_node.tag == .static_binding) declaration_node.data.node_node.b else @fromBackingInt(@intCast(declaration)), .signature = signature, .body = body };
}

pub fn functionWhereConditions(ast: *const structures.Ast, declaration: u32) []const structures.Node.Index {
    const parts = functionParts(ast, declaration);
    return ast.nodeList(ast.nodes[parts.signature.index()].data.signature.where_clauses);
}

pub fn resolveSpecializationArgument(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    arguments: []const structures.CompileTimeValueId,
    name: []const u8,
) ?structures.CompileTimeValueId {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];
    var static_index: usize = 0;
    for (ast.nodeList(signature.data.signature.parameters)) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        if (parameterMode(ast, parameter).? != .static) continue;
        if (static_index == arguments.len) break;
        const span = tokenSpan(ast, parameter.token_index);
        if (std.mem.eql(u8, source[span.start..span.end], name)) return arguments[static_index];
        static_index += 1;
    }
    std.debug.assert(static_index == arguments.len);
    return null;
}

fn issueAt(ast: *const structures.Ast, node_index: u32, kind: structures.Diagnostic.Kind) Issue {
    return .{ .span = tokenSpan(ast, ast.nodes[node_index].token_index), .kind = kind };
}

fn tokenSpan(ast: *const structures.Ast, token_index: u32) structures.SourceSpan {
    return ast.tokenSpan(token_index);
}

fn nodeFocusSpan(ast: *const structures.Ast, node_index: structures.Node.Index) structures.SourceSpan {
    const node = ast.nodes[node_index.index()];
    if (node.tag == .call) return nodeFocusSpan(ast, node.data.node_node.a);
    return tokenSpan(ast, node.token_index);
}

pub fn collectImports(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8) !structures.ImportDeclarations {
    var imports: std.ArrayList(structures.ImportDeclaration) = .empty;
    errdefer {
        for (imports.items) |*entry| entry.deinit(gpa);
        imports.deinit(gpa);
    }
    const root = ast.nodes[0];
    std.debug.assert(root.tag == .block);
    for (ast.node_refs[root.data.ref.start..root.data.ref.end]) |statement| {
        const node = ast.nodes[statement.index()];
        const is_public = node.tag == .@"pub";
        const target = if (is_public) node.data.node else statement;
        const tag = ast.nodes[target.index()].tag;
        if (tag != .import and tag != .selective_import) continue;
        var entry = try collectImport(gpa, ast, source, target, is_public);
        errdefer entry.deinit(gpa);
        try imports.append(gpa, entry);
    }
    return .{ .entries = try imports.toOwnedSlice(gpa) };
}

fn ownedImportName(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, node: structures.Node.Index) !structures.ImportName {
    const span = tokenSpan(ast, ast.nodes[node.index()].token_index);
    return .{ .spelling = try gpa.dupe(u8, source[span.start..span.end]), .span = span };
}

fn collectImport(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, index: structures.Node.Index, is_public: bool) !structures.ImportDeclaration {
    const node = ast.nodes[index.index()];
    const parts = ast.node_refs[node.data.ref.start..node.data.ref.end];
    var cursor = parts[0];
    var alias: ?structures.ImportName = null;
    errdefer if (alias) |name| gpa.free(name.spelling);
    if (ast.nodes[cursor.index()].tag == .as) {
        const target = ast.nodes[cursor.index()];
        alias = try ownedImportName(gpa, ast, source, target.data.node_node.b);
        cursor = target.data.node_node.a;
    }
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);
    var path_span = tokenSpan(ast, ast.nodes[cursor.index()].token_index);
    while (true) {
        const segment = ast.nodes[cursor.index()];
        const span = tokenSpan(ast, segment.token_index);
        try segments.append(gpa, source[span.start..span.end]);
        if (segment.tag == .identifier) {
            path_span.start = span.start;
            break;
        }
        std.debug.assert(segment.tag == .field_access);
        cursor = segment.data.node;
    }
    std.mem.reverse([]const u8, segments.items);
    const path = try std.mem.join(gpa, ".", segments.items);
    errdefer gpa.free(path);
    var selections: std.ArrayList(structures.ImportDeclaration.Selection) = .empty;
    errdefer {
        for (selections.items) |item| {
            gpa.free(item.original.spelling);
            gpa.free(item.bound.spelling);
        }
        selections.deinit(gpa);
    }
    for (parts[1..]) |item_index| {
        const item = ast.nodes[item_index.index()];
        const original = try ownedImportName(gpa, ast, source, if (item.tag == .as) item.data.node_node.a else item_index);
        errdefer gpa.free(original.spelling);
        const bound = try ownedImportName(gpa, ast, source, if (item.tag == .as) item.data.node_node.b else item_index);
        errdefer gpa.free(bound.spelling);
        try selections.append(gpa, .{ .original = original, .bound = bound });
    }
    return .{
        .path = .{ .spelling = path, .span = path_span },
        .alias = alias,
        .selective = if (node.tag == .selective_import) try selections.toOwnedSlice(gpa) else null,
        .is_public = is_public,
    };
}

pub fn discoverItems(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, module: structures.ModuleId) !structures.ItemTree {
    var items: std.ArrayList(structures.DiscoveredItem) = .empty;
    errdefer {
        for (items.items) |*item| {
            item.loc.name.deinit(gpa);
            if (item.qualified_owner) |owner| gpa.free(owner);
        }
        items.deinit(gpa);
    }

    const root = ast.nodes[0];
    std.debug.assert(root.tag == .block);
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const declaration = ast.node_refs[ref_index];
        const node = ast.nodes[declaration.index()];
        var target = if (node.tag == .@"pub") node.data.node else declaration;
        var target_node = ast.nodes[target.index()];
        const namespace = if (target_node.tag == .namespace_declaration) target_node.data.node_node.a else .null;
        if (namespace != .null) {
            target = target_node.data.node_node.b;
            target_node = ast.nodes[target.index()];
        }

        if (target_node.tag != .static_binding) continue;
        const value = target_node.data.node_node.b.unwrap() orelse unreachable;
        const kind: structures.ItemKind = switch (ast.nodes[value.index()].tag) {
            .func => .function,
            .@"struct" => .structure,
            else => .static,
        };

        const synthetic_name = if (ast.nodes[value.index()].is_converter)
            try gpa.print("$converter{d}_{d}", .{ ast.file_id, items.items.len })
        else
            null;
        defer if (synthetic_name) |allocated| gpa.free(allocated);
        const name_span = tokenSpan(ast, target_node.token_index);
        const name = synthetic_name orelse source[name_span.start..name_span.end];
        const parent = try appendItem(gpa, &items, kind, ast.file_id, module, declarationName(ast, name, target.index()), target.index(), node.tag == .@"pub", null, null);
        if (namespace != .null) items.items[parent].qualified_owner = try qualifiedName(gpa, ast, source, namespace);
        if (kind == .structure) {
            try discoverStructItems(gpa, &items, ast, source, module, value, parent, null);
        } else {
            try discoverGeneratedStructItems(gpa, &items, ast, source, module, target, parent);
        }
    }

    _ = try appendItem(gpa, &items, .top_level_entry, ast.file_id, module, .{ .identifier = "$entry" }, 0, false, null, null);
    return .{ .file_id = ast.file_id, .items = try items.toOwnedSlice(gpa) };
}

fn qualifiedName(gpa: std.mem.Allocator, ast: *const structures.Ast, source: []const u8, index: structures.Node.Index) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(gpa);
    var current = index;
    while (true) {
        const node = ast.nodes[current.index()];
        const token = ast.tokens[node.token_index];
        try segments.append(gpa, source[token.loc.start..token.loc.end]);
        if (node.tag == .identifier) break;
        std.debug.assert(node.tag == .field_access);
        current = node.data.node;
    }
    std.mem.reverse([]const u8, segments.items);
    return std.mem.join(gpa, ".", segments.items);
}

fn discoverGeneratedStructItems(gpa: std.mem.Allocator, items: *std.ArrayList(structures.DiscoveredItem), ast: *const structures.Ast, source: []const u8, module: structures.ModuleId, declaration: structures.Node.Index, parent: u32) anyerror!void {
    // Traverse only this declaration, stopping at structs whose member
    // declarations establish their own owners and source-relative sites.
    var pending: std.ArrayList(structures.Node.Index) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, declaration);
    while (pending.pop()) |index| {
        const node = ast.nodes[index.index()];
        if (node.tag == .@"struct") {
            const site = @as(i64, index.index()) - @as(i64, declaration.index());
            try discoverStructItems(gpa, items, ast, source, module, index, parent, site);
            continue;
        }
        var children = node.children(ast.node_refs);
        const nodes = children.slice();
        var end = nodes.len;
        while (end > 0) {
            end -= 1;
            if (nodes[end].unwrap()) |child| try pending.append(gpa, child);
        }
    }
}

fn discoverStructItems(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    ast: *const structures.Ast,
    source: []const u8,
    module: structures.ModuleId,
    struct_index: structures.Node.Index,
    parent: u32,
    source_site: ?i64,
) !void {
    const struct_node = ast.nodes[struct_index.index()];
    std.debug.assert(struct_node.tag == .@"struct");
    var hook_names = std.StringHashMap(void).init(gpa);
    defer hook_names.deinit();
    var declaration_names = structures.Name.Set.init(gpa);
    defer declaration_names.deinit();
    for (ast.node_refs[struct_node.data.ref.start..struct_node.data.ref.end]) |item_index| {
        const item = ast.nodes[item_index.index()];
        const member_index = if (item.tag == .@"pub") item.data.node else item_index;
        const member = ast.nodes[member_index.index()];
        const span = tokenSpan(ast, member.token_index);
        const name = source[span.start..span.end];
        if (member.tag == .struct_property and ast.nodes[member.data.node.index()].tag == .func) {
            // Semantic analysis diagnoses duplicates; discovery remains indexable.
            if ((try hook_names.getOrPut(name)).found_existing) continue;
            const child = try appendItem(gpa, items, .function, ast.file_id, module, .{ .identifier = name }, member.data.node.index(), false, parent, source_site);
            items.items[child].loc.is_hook = true;
            try discoverGeneratedStructItems(gpa, items, ast, source, module, member.data.node, child);
        } else if (member.tag == .static_binding) {
            const member_name = declarationName(ast, name, member_index.index());
            if ((try declaration_names.getOrPut(member_name)).found_existing) continue;
            const value = member.data.node_node.b;
            const kind: structures.ItemKind = switch (ast.nodes[value.index()].tag) {
                .func => .function,
                .@"struct" => .structure,
                else => .static,
            };
            const child = try appendItem(gpa, items, kind, ast.file_id, module, member_name, member_index.index(), item.tag == .@"pub", parent, source_site);
            if (kind == .structure) {
                try discoverStructItems(gpa, items, ast, source, module, value, child, null);
            } else {
                try discoverGeneratedStructItems(gpa, items, ast, source, module, member_index, child);
            }
        }
    }
}

fn declarationName(ast: *const structures.Ast, name: []const u8, declaration: u32) structures.Name {
    const node = ast.nodes[declaration];
    if (node.tag != .static_binding or ast.nodes[node.data.node_node.b.index()].tag != .func)
        return .{ .identifier = name };
    const parts = functionParts(ast, declaration);
    var count: usize = 0;
    for (ast.nodeList(ast.nodes[parts.signature.index()].data.signature.parameters)) |parameter|
        if (parameterMode(ast, ast.nodes[parameter.index()]) != .static) {
            count += 1;
        };
    return .fromText(name, count);
}

fn appendItem(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    kind: structures.ItemKind,
    file_id: structures.FileId,
    module: structures.ModuleId,
    name: structures.Name,
    declaration: u32,
    is_public: bool,
    parent: ?u32,
    source_site: ?i64,
) !u32 {
    var owned_name = try name.clone(gpa);
    errdefer owned_name.deinit(gpa);
    const index: u32 = @intCast(items.items.len);
    try items.append(gpa, .{
        .loc = .{ .origin = if (kind == .top_level_entry) .{ .entry = file_id } else .{ .module = module }, .source_site = source_site, .kind = kind, .name = owned_name },
        .declaration = declaration,
        .parent = parent,
        .is_public = is_public,
    });
    return index;
}

test "unresolved function body cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testUnresolvedFunctionBodyAllocations, .{});
}

test "qualified namespace discovery cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    const parser = @import("parser.zig");
    const source =
        \\struct S
        \\  value: int
        \\static S.read = func(imm self: S) int -> return self.value
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testQualifiedNamespaceDiscoveryAllocations, .{ &report.ast.?, source });
}

fn testQualifiedNamespaceDiscoveryAllocations(gpa: std.mem.Allocator, parsed: *const structures.Ast, source: []const u8) !void {
    var tree = try discoverItems(gpa, parsed, source, @fromBackingInt(@intCast(0)));
    defer tree.deinit(gpa);
}

test "discard assignment has distinct unresolved statement" {
    const parser = @import("parser.zig");
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

    const root = unresolved.blocks[@backingInt(unresolved.root_block)];
    try std.testing.expectEqual(@as(u32, 1), root.statements.end - root.statements.start);
    const statement = unresolved.statements[root.statements.start];
    try std.testing.expectEqual(UnresolvedBody.ValueId, @TypeOf(statement.lifetime_extend.value));
    try std.testing.expectEqual(@as(u32, 0), @backingInt(statement.lifetime_extend.value));
}

test "fail has terminal unresolved statements in function and branch bodies" {
    const parser = @import("parser.zig");
    const cases = [_]struct { source: []const u8, failure_count: usize }{
        .{ .source = "fallible reject() int -> fail", .failure_count = 1 },
        .{
            .source =
            \\fallible reject() int
            \\  if 1 < 2 -> fail else fail
            ,
            .failure_count = 2,
        },
        .{
            .source =
            \\fallible reject() int
            \\  if 1 < 2
            \\    fail
            \\  else
            \\    fail
            ,
            .failure_count = 2,
        },
    };
    for (cases) |case| {
        var report = try parser.parseReport(std.testing.allocator, 1, case.source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
        const parsed = &report.ast.?;
        const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
        const result = try buildUnresolvedBody(parsed, case.source, declaration.index(), .function, &.{}, TestTypeInterner{}, std.testing.allocator);
        var unresolved = switch (result) {
            .success => |value| value,
            .unsupported => unreachable,
        };
        defer unresolved.deinit(std.testing.allocator);

        var failure_count: usize = 0;
        for (unresolved.blocks) |block| {
            for (unresolved.statements[block.statements.start..block.statements.end]) |statement| {
                switch (statement) {
                    .failure => |span| {
                        failure_count += 1;
                        try std.testing.expectEqualStrings("fail", case.source[span.start..span.end]);
                        try std.testing.expectEqual(@as(?UnresolvedBody.ValueId, null), block.result);
                    },
                    else => {},
                }
            }
        }
        try std.testing.expectEqual(case.failure_count, failure_count);
    }
}

test "function signature cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testFunctionSignatureAllocations, .{});
}

test "struct definition cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testStructDefinitionAllocations, .{});
}

test "struct factory independent inference unwraps public fields" {
    const parser = @import("parser.zig");
    const source =
        \\struct Factory(T: type)
        \\  pub value: T
        \\  pub amount: int
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    const parsed = &report.ast.?;
    const wrapped = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const declaration = if (parsed.nodes[wrapped.index()].tag == .@"pub") parsed.nodes[wrapped.index()].data.node else wrapped;
    const annotation = structFactoryFieldAnnotation(parsed, source, declaration.index(), "value").?;
    const span = tokenSpan(parsed, parsed.nodes[annotation.index()].token_index);
    try std.testing.expectEqualStrings("T", source[span.start..span.end]);
    const independent = try analyzeIndependentStructFieldType(parsed, source, declaration.index(), "amount", TestTypeInterner{}, std.testing.allocator);
    switch (independent) {
        .success => |type_id| try std.testing.expectEqual(@as(?structures.TypeId, .int), type_id),
        .unsupported => return error.UnexpectedSemanticIssue,
    }
}

fn testStructDefinitionAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("parser.zig");
    const source =
        \\static Record = struct
        \\  pub first: int
        \\  second: bool
        \\  third: none
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzeStructDefinition(parsed, source, @fromBackingInt(@intCast(0)), declaration.index(), TestTypeInterner{}, gpa);
    switch (result) {
        .success => |definition_value| {
            var definition = definition_value;
            definition.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}

fn testFunctionSignatureAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("parser.zig");
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
    const parser = @import("parser.zig");
    const source =
        \\static target = func(a: int, b: int, c: int) int
        \\  first(a)
        \\  const aggregate = int{field = first(a)}
        \\  var mutable_aggregate = aggregate
        \\  mutable_aggregate.field = first(a)
        \\  aggregate.field
        \\  aggregate.callback(aggregate.callback(a))
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
    pub fn internByteString(_: @This(), _: []const u8) !structures.ByteStringId {
        unreachable;
    }
    public_annotation: bool = false,
    pub fn facts(self: @This()) @This() {
        return self;
    }

    pub fn internVariant(_: @This(), _: []const structures.TypeId) !structures.InternVariantResult {
        unreachable;
    }

    pub fn internCallable(_: @This(), _: structures.CallableType) !structures.TypeId {
        unreachable;
    }

    pub fn variantMembers(_: @This(), _: structures.TypeId) !?[]const structures.TypeId {
        return null;
    }

    pub fn evaluateWhereMembership(_: @This(), _: structures.Node.Index, _: structures.TypeId) !?bool {
        unreachable;
    }

    pub fn containsBorrow(_: @This(), _: structures.TypeId) !bool {
        unreachable;
    }

    pub fn callable(_: @This(), _: structures.TypeId) !?structures.CallableType {
        return null;
    }

    pub fn structDefinition(_: @This(), _: structures.TypeId) !?structures.StructDefinition {
        return null;
    }

    pub fn arrayType(_: @This(), _: structures.TypeId) !?structures.ArrayType {
        return null;
    }

    pub fn generatedStructType(_: @This(), _: structures.Node.Index) !structures.TypeId {
        unreachable;
    }

    pub fn structIdentityType(_: @This(), _: structures.StructIdentity) !structures.TypeId {
        unreachable;
    }

    pub fn ownedFunction(_: @This(), _: structures.StructIdentity, _: []const u8) !?structures.InstanceId {
        unreachable;
    }

    pub fn functionSignature(_: @This(), _: structures.InstanceId) !?structures.FunctionSignature {
        unreachable;
    }

    pub fn functionShape(_: @This(), _: structures.ItemId) !?structures.FunctionShape {
        unreachable;
    }

    pub fn needsInheritedInference(_: @This(), _: structures.InstanceId) !bool {
        unreachable;
    }

    pub fn isGenericStruct(_: @This(), _: structures.ItemId) !bool {
        unreachable;
    }

    pub fn specializeFunction(_: @This(), _: structures.InstanceId, _: []const structures.CompileTimeValueId) !structures.InstanceId {
        unreachable;
    }

    pub fn internCompileTimeValue(_: @This(), _: structures.CompileTimeValue) !structures.CompileTimeValueId {
        unreachable;
    }

    pub fn lookupCompileTimeValue(_: @This(), _: structures.CompileTimeValueId) !structures.CompileTimeValue {
        unreachable;
    }

    pub fn lookupCompileTimeTuple(_: @This(), _: structures.CompileTimeValueTupleId) ![]const structures.CompileTimeValueId {
        unreachable;
    }

    pub fn executeComptime(_: @This(), _: structures.Node.Index) !?structures.CompileTimeValueId {
        unreachable;
    }

    pub fn executeComptimeWithType(_: @This(), _: structures.Node.Index, _: ?structures.TypeId) !?structures.CompileTimeValueId {
        unreachable;
    }

    pub fn staticParameterType(_: @This(), _: structures.InstanceId, _: usize, _: []const structures.CompileTimeValueId) !structures.TypeId {
        unreachable;
    }

    pub fn structType(_: @This(), _: structures.ItemId) !structures.TypeId {
        unreachable;
    }

    pub fn resolveName(_: @This(), _: []const u8) !?structures.NameReference {
        return null;
    }
    pub fn isPublicAnnotationReference(_: @This(), _: structures.NameReference) !bool {
        return true;
    }
    pub fn isPublicType(_: @This(), type_id: structures.TypeId) !bool {
        return type_id.isPrimitive();
    }
    pub fn resolveMember(_: @This(), _: structures.NameReference, _: []const u8, _: structures.SourceSpan) !?structures.NameReference {
        return null;
    }
    pub fn resolveMemberWithOperands(_: @This(), _: structures.NameReference, _: []const u8, _: structures.SourceSpan, _: ?usize) !?structures.NameReference {
        return null;
    }
    pub fn staticItem(_: @This(), _: structures.InstanceId) !?structures.CompileTimeValueId {
        return null;
    }
    pub fn functionItemReference(_: @This(), _: structures.InstanceId) !?structures.FunctionReference {
        return null;
    }
    pub fn resolveLocalConflict(_: @This(), _: []const u8) !?structures.ItemId {
        return null;
    }

    pub fn resolveStatic(_: @This(), _: []const u8) !?structures.CompileTimeValueId {
        return null;
    }
};
