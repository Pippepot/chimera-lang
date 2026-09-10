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
/// names are borrowed only until typing finishes. CFG blocks belong to typed IR.
pub const UnresolvedBody = struct {
    parameter_count: u32,
    expressions: []Expression,
    blocks: []Block,
    statements: []Statement,
    call_arguments: []ValueId,
    root_block: BlockId,

    pub const ValueId = enum(u32) { _ };
    pub const BlockId = enum(u32) { _ };
    pub const BinaryOperands = struct { lhs: ValueId, rhs: ValueId };
    pub const StatementRange = struct { start: u32, end: u32 };
    pub const Block = struct {
        statements: StatementRange,
        result: ?ValueId,
        span: structures.SourceSpan,
    };
    pub const Statement = union(enum) {
        discard: ValueId,
        return_nothing: structures.SourceSpan,
        return_value: struct { value: ValueId, span: structures.SourceSpan },
    };
    pub const PredicateOperation = enum { lt, gt, le, ge, eq, ne };
    pub const Condition = struct {
        operation: PredicateOperation,
        operands: BinaryOperands,
        span: structures.SourceSpan,
    };
    pub const Expression = struct {
        operation: Operation,
        span: structures.SourceSpan,

        pub const Operation = union(enum) {
            integer: i32,
            unit,
            none,
            annotation: struct { value: ValueId, type_id: structures.TypeId },
            call: struct { name: []const u8, arguments: structures.FunctionValueRange },
            negate: ValueId,
            add: BinaryOperands,
            subtract: BinaryOperands,
            multiply: BinaryOperands,
            divide: BinaryOperands,
            if_else: struct { condition: Condition, then_block: BlockId, else_block: BlockId },
        };
    };

    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        gpa.free(self.expressions);
        gpa.free(self.blocks);
        gpa.free(self.statements);
        gpa.free(self.call_arguments);
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

        ast: *const structures.Ast,
        source: []const u8,
        parameter_count: u32,
        type_interner: TypeInterner,
        gpa: std.mem.Allocator,
        locals: std.StringHashMapUnmanaged(ValueId) = .empty,
        local_names: std.ArrayList([]const u8) = .empty,
        expressions: std.ArrayList(UnresolvedBody.Expression) = .empty,
        blocks: std.ArrayList(UnresolvedBody.Block) = .empty,
        statements: std.ArrayList(UnresolvedBody.Statement) = .empty,
        call_arguments: std.ArrayList(ValueId) = .empty,
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
            const parts = functionParts(self.ast, declaration);
            const signature = self.ast.nodes[parts.signature.index()];
            const parameters = self.ast.nodeList(signature.data.node_node.a);
            std.debug.assert(parameters.len == self.parameter_count);
            for (parameters, 0..) |parameter_index, index| {
                const span = tokenSpan(self.ast, self.ast.nodes[parameter_index.index()].token_index);
                const name = self.source[span.start..span.end];
                try self.locals.put(self.gpa, name, @enumFromInt(index));
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
            self.root_block = try self.finishBlock(body_statements.items, null, tokenSpan(self.ast, body.token_index));
        }

        fn buildStatement(self: *Self, index: structures.Node.Index, comptime is_entry: bool) !UnresolvedBody.Statement {
            const node = self.ast.nodes[index.index()];
            const span = tokenSpan(self.ast, node.token_index);
            return switch (node.tag) {
                .const_binding => .{ .discard = try self.appendBinding(index) },
                .return_nothing => if (is_entry)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_nothing = span },
                .return_expr => if (is_entry)
                    self.reject(index, .top_level_return)
                else
                    .{ .return_value = .{ .value = try self.append(node.data.node), .span = span } },
                else => .{ .discard = try self.append(index) },
            };
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
                value = try self.appendExpression(annotation.?, .{ .annotation = .{ .value = value, .type_id = type_id } });
            }
            try self.locals.put(self.gpa, name, value);
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
                    if (self.locals.get(name)) |value| return value;
                    if (std.mem.eql(u8, name, "unit")) return self.appendExpression(index, .unit);
                    return self.reject(index, .unknown_value);
                },
                .neg => return self.appendExpression(index, .{ .negate = try self.append(node.data.node) }),
                .add, .sub, .mul, .div => return self.appendBinary(index),
                .@"if", .if_else => return self.appendIf(index),
                else => return self.reject(index, .expression_not_supported),
            }
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
                .lhs = try self.append(node.data.node_node.a),
                .rhs = try self.append(node.data.node_node.b),
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
            const then_block = try self.buildBranch(then_index);
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
                .operands = .{ .lhs = try self.append(node.data.node_node.a), .rhs = try self.append(node.data.node_node.b) },
                .span = tokenSpan(self.ast, node.token_index),
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
                if (node.tag == .return_nothing or node.tag == .return_expr) {
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
                .const_binding, .return_nothing, .return_expr => blk: {
                    try statements.append(self.gpa, try self.buildStatement(last, false));
                    break :blk null;
                },
                else => try self.append(last),
            };
            if (result == null and last_node.tag == .const_binding) {
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
            try self.call_arguments.appendSlice(self.gpa, self.scratch.items[scratch_start..]);
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
            return .{
                .parameter_count = self.parameter_count,
                .expressions = expressions,
                .blocks = blocks,
                .statements = statements,
                .call_arguments = try self.call_arguments.toOwnedSlice(self.gpa),
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
        \\  const value: int = if a < b -> second(b, c) + 1 else third(c, b)
        \\  return third(value, a, b) + value * -c
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
