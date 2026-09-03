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

pub const UnresolvedBody = struct {
    block_argument_count: u32,
    branch_arguments: []ValueId,
    call_arguments: []ValueId,
    instructions: []Instruction,
    joins: []Join,
    type_expectations: []TypeExpectation,
    blocks: []Block,

    pub const ValueId = union(enum) {
        block_argument: u32,
        instruction: u32,
    };

    pub const BinaryOperands = struct {
        lhs: ValueId,
        rhs: ValueId,
    };

    pub const Instruction = struct {
        operation: Operation,
        span: structures.SourceSpan,

        pub const Operation = union(enum) {
            consti: i32,
            const_unit,
            const_none,
            variant_coerce: struct {
                operand: ValueId,
                target_type: structures.TypeId,
            },
            call: struct {
                target: structures.SourceSpan,
                /// Borrowed from the source given to buildUnresolvedBody;
                /// the unresolvedBody must not outlive that source.
                name: []const u8,
                arguments: structures.FunctionValueRange,
            },
            negi: ValueId,
            addi: BinaryOperands,
            subi: BinaryOperands,
            muli: BinaryOperands,
            divsi: BinaryOperands,
        };
    };

    pub const Join = struct {
        argument: u32,
        incoming: [2]ValueId,
        span: structures.SourceSpan,
        instruction_count: u32,
    };

    pub const TypeExpectation = struct {
        value: ValueId,
        expected: structures.TypeId,
        span: structures.SourceSpan,
        instruction_count: u32,
    };

    pub const Branch = struct {
        target: structures.FunctionBlockId,
        arguments: structures.FunctionValueRange,
    };

    pub const PredicateOperation = enum { lt, gt, le, ge, eq, ne };

    pub const Terminator = union(enum) {
        branch: Branch,
        predicate_branch: struct {
            operation: PredicateOperation,
            operands: BinaryOperands,
            then_branch: Branch,
            else_branch: Branch,
            span: structures.SourceSpan,
        },
        return_unit: structures.SourceSpan,
        return_value: struct {
            value: ValueId,
            span: structures.SourceSpan,
        },
    };

    pub const Block = struct {
        argument_start: u32,
        argument_end: u32,
        instruction_start: u32 = undefined,
        instruction_end: u32 = undefined,
        terminator: ?Terminator = null,
    };

    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        gpa.free(self.branch_arguments);
        gpa.free(self.call_arguments);
        gpa.free(self.instructions);
        gpa.free(self.joins);
        gpa.free(self.type_expectations);
        gpa.free(self.blocks);
        self.* = undefined;
    }
};

pub const UnresolvedBodyResult = SemanticResult(UnresolvedBody);

/// Builds one unresolved body for either callable kind. Entries accept const
/// bindings and bare calls, and skip static bindings under a synthetic
/// zero-parameter signature; declared functions must end in a return.
pub fn buildUnresolvedBody(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    kind: structures.ItemKind,
    parameter_types: []const structures.TypeId,
    return_type: structures.TypeId,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) !UnresolvedBodyResult {
    var branch_arguments: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer branch_arguments.deinit(gpa);
    var instructions: std.ArrayList(UnresolvedBody.Instruction) = .empty;
    defer instructions.deinit(gpa);
    var joins: std.ArrayList(UnresolvedBody.Join) = .empty;
    defer joins.deinit(gpa);
    var type_expectations: std.ArrayList(UnresolvedBody.TypeExpectation) = .empty;
    defer type_expectations.deinit(gpa);
    var call_arguments: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer call_arguments.deinit(gpa);
    var expression_scratch: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer expression_scratch.deinit(gpa);
    var blocks: std.ArrayList(UnresolvedBody.Block) = .empty;
    defer blocks.deinit(gpa);
    var locals = std.StringHashMap(UnresolvedBody.ValueId).init(gpa);
    defer locals.deinit();
    try blocks.append(gpa, .{
        .argument_start = 0,
        .argument_end = @intCast(parameter_types.len),
        .instruction_start = 0,
    });
    var expression_builder: UnresolvedExpressionBuilder = .{
        .ast = ast,
        .source = source,
        .block_argument_count = @intCast(parameter_types.len),
        .locals = &locals,
        .branch_arguments = &branch_arguments,
        .instructions = &instructions,
        .joins = &joins,
        .call_arguments = &call_arguments,
        .scratch = &expression_scratch,
        .blocks = &blocks,
        .gpa = gpa,
    };

    const body_result: SemanticResult(void) = switch (kind) {
        .top_level_entry => try buildEntryBlock(ast, source, declaration, &locals, &type_expectations, &expression_builder, type_interner, gpa),
        .function => try buildFunctionBlock(ast, source, declaration, parameter_types, return_type, &locals, &type_expectations, &expression_builder, type_interner, gpa),
    };
    switch (body_result) {
        .unsupported => |issue| return .{ .unsupported = issue },
        .success => {},
    }

    const owned_branch_arguments = try branch_arguments.toOwnedSlice(gpa);
    errdefer gpa.free(owned_branch_arguments);
    const owned_call_arguments = try call_arguments.toOwnedSlice(gpa);
    errdefer gpa.free(owned_call_arguments);
    const owned_joins = try joins.toOwnedSlice(gpa);
    errdefer gpa.free(owned_joins);
    const owned_type_expectations = try type_expectations.toOwnedSlice(gpa);
    errdefer gpa.free(owned_type_expectations);
    const owned_blocks = try blocks.toOwnedSlice(gpa);
    errdefer gpa.free(owned_blocks);
    return .{ .success = .{
        .block_argument_count = expression_builder.block_argument_count,
        .branch_arguments = owned_branch_arguments,
        .call_arguments = owned_call_arguments,
        .instructions = try instructions.toOwnedSlice(gpa),
        .joins = owned_joins,
        .type_expectations = owned_type_expectations,
        .blocks = owned_blocks,
    } };
}

fn buildEntryBlock(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    locals: *std.StringHashMap(UnresolvedBody.ValueId),
    type_expectations: *std.ArrayList(UnresolvedBody.TypeExpectation),
    expression_builder: *UnresolvedExpressionBuilder,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) anyerror!SemanticResult(void) {
    const root = ast.nodes[declaration];
    std.debug.assert(root.tag == .block);
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const child_index = ast.node_refs[ref_index];
        const child = ast.nodes[child_index.index()];
        switch (child.tag) {
            .static_binding => continue,
            .const_binding => switch (try appendConstBinding(ast, source, child_index, locals, type_expectations, expression_builder, type_interner, gpa)) {
                .success => {},
                .unsupported => |issue| return .{ .unsupported = issue },
            },
            .call => switch (try expression_builder.append(child_index)) {
                .success => {},
                .unsupported => |issue| return .{ .unsupported = issue },
            },
            else => return .{ .unsupported = issueAt(ast, child_index.index(), .entry_statement_not_supported) },
        }
    }
    expression_builder.terminate(.{ .return_unit = tokenSpan(ast, root.token_index) });
    return .{ .success = {} };
}

fn buildFunctionBlock(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    parameter_types: []const structures.TypeId,
    return_type: structures.TypeId,
    locals: *std.StringHashMap(UnresolvedBody.ValueId),
    type_expectations: *std.ArrayList(UnresolvedBody.TypeExpectation),
    expression_builder: *UnresolvedExpressionBuilder,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) anyerror!SemanticResult(void) {
    const parts = functionParts(ast, declaration);
    const function_signature = ast.nodes[parts.signature.index()];
    var parameters = AstNodeListIterator.init(ast, function_signature.data.node_node.a, .param_list_small, .param_list);
    var parameter_index: usize = 0;
    while (parameters.next()) |parameter_node_index| : (parameter_index += 1) {
        const parameter = ast.nodes[parameter_node_index.index()];
        const name_span = tokenSpan(ast, parameter.token_index);
        try locals.put(source[name_span.start..name_span.end], .{ .block_argument = @intCast(parameter_index) });
    }
    std.debug.assert(parameter_index == parameter_types.len);

    const body = ast.nodes[parts.body.index()];
    const return_index: structures.Node.Index = if (body.tag == .return_expr or body.tag == .return_nothing)
        parts.body
    else if (body.tag == .block) blk: {
        if (body.data.ref.start == body.data.ref.end) {
            return .{ .unsupported = issueAt(ast, parts.body.index(), .body_shape_not_supported) };
        }
        const return_ref = body.data.ref.end - 1;
        for (body.data.ref.start..return_ref) |ref_index| {
            const statement_index = ast.node_refs[ref_index];
            const statement = ast.nodes[statement_index.index()];
            switch (statement.tag) {
                .const_binding => switch (try appendConstBinding(ast, source, statement_index, locals, type_expectations, expression_builder, type_interner, gpa)) {
                    .success => {},
                    .unsupported => |issue| return .{ .unsupported = issue },
                },
                .call => switch (try expression_builder.append(statement_index)) {
                    .success => {},
                    .unsupported => |issue| return .{ .unsupported = issue },
                },
                else => return .{ .unsupported = issueAt(ast, statement_index.index(), .body_shape_not_supported) },
            }
        }
        break :blk ast.node_refs[return_ref];
    } else {
        return .{ .unsupported = issueAt(ast, parts.body.index(), .body_shape_not_supported) };
    };

    const return_node = ast.nodes[return_index.index()];
    const return_is_variant = try type_interner.variantMembers(return_type) != null;
    const terminator: UnresolvedBody.Terminator = switch (return_node.tag) {
        .return_nothing => if (!return_is_variant)
            .{ .return_unit = tokenSpan(ast, return_node.token_index) }
        else blk: {
            const unit_value = switch (try expression_builder.appendInstruction(return_index, .const_unit)) {
                .success => |value| value,
                .unsupported => unreachable,
            };
            break :blk .{ .return_value = .{
                .value = unit_value,
                .span = tokenSpan(ast, return_node.token_index),
            } };
        },
        .return_expr => blk: {
            const value_index = return_node.data.node.unwrap() orelse unreachable;
            const return_value = switch (try expression_builder.append(value_index)) {
                .success => |value| value,
                .unsupported => |issue| return .{ .unsupported = issue },
            };
            break :blk .{ .return_value = .{
                .value = return_value,
                .span = tokenSpan(ast, return_node.token_index),
            } };
        },
        else => return .{ .unsupported = issueAt(ast, return_index.index(), .body_shape_not_supported) },
    };
    expression_builder.terminate(terminator);
    return .{ .success = {} };
}

fn appendConstBinding(
    ast: *const structures.Ast,
    source: []const u8,
    statement_index: structures.Node.Index,
    locals: *std.StringHashMap(UnresolvedBody.ValueId),
    type_expectations: *std.ArrayList(UnresolvedBody.TypeExpectation),
    expression_builder: *UnresolvedExpressionBuilder,
    type_interner: anytype,
    gpa: std.mem.Allocator,
) anyerror!ExpressionResult {
    const statement = ast.nodes[statement_index.index()];
    const name_span = tokenSpan(ast, statement.token_index);
    const name = source[name_span.start..name_span.end];
    if (locals.contains(name)) {
        return .{ .unsupported = .{ .span = name_span, .kind = .duplicate_local_binding } };
    }
    const annotation = statement.data.node_node.a.unwrap();
    const expected_type = if (annotation) |type_node| blk: {
        const resolved = switch (try analyzeType(ast, source, type_node, type_interner, gpa, .local_type_not_supported)) {
            .success => |type_id| type_id,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        if (resolved == .none) {
            return .{ .unsupported = issueAt(ast, type_node.index(), .local_type_not_supported) };
        }
        break :blk resolved;
    } else null;
    const initializer = statement.data.node_node.b.unwrap() orelse unreachable;
    var value = switch (try expression_builder.append(initializer)) {
        .success => |value| value,
        .unsupported => |issue| return .{ .unsupported = issue },
    };
    if (expected_type) |expected| {
        const type_node = annotation.?;
        if (try type_interner.variantMembers(expected) != null) {
            value = switch (try expression_builder.appendInstruction(type_node, .{ .variant_coerce = .{
                .operand = value,
                .target_type = expected,
            } })) {
                .success => |coerced| coerced,
                .unsupported => unreachable,
            };
        } else {
            try type_expectations.append(gpa, .{
                .value = value,
                .expected = expected,
                .span = tokenSpan(ast, ast.nodes[type_node.index()].token_index),
                .instruction_count = @intCast(expression_builder.instructions.items.len),
            });
        }
    }
    try locals.put(name, value);
    // A binding evaluates to its bound value, mirroring the initializer.
    return .{ .success = value };
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
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];

    var parameter_types: std.ArrayList(structures.TypeId) = .empty;
    defer parameter_types.deinit(gpa);
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    var parameters = AstNodeListIterator.init(ast, signature.data.node_node.a, .param_list_small, .param_list);
    while (parameters.next()) |parameter_index| {
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
        if (parameter_type != .int and try type_interner.variantMembers(parameter_type) == null) {
            return .{ .unsupported = issueAt(ast, annotation.index(), .parameter_type_not_supported) };
        }
        try parameter_types.append(gpa, parameter_type);
    }

    const return_type_index = signature.data.node_node.b.unwrap() orelse
        return .{ .unsupported = issueAt(ast, parts.signature.index(), .return_type_missing) };
    const return_type = switch (try analyzeType(ast, source, return_type_index, type_interner, gpa, .return_type_not_supported)) {
        .success => |type_id| type_id,
        .unsupported => |issue| return .{ .unsupported = issue },
    };
    if (return_type != .int and return_type != .unit and try type_interner.variantMembers(return_type) == null) {
        return .{ .unsupported = issueAt(ast, return_type_index.index(), .return_type_not_supported) };
    }

    return .{ .success = .{ .parameter_types = try parameter_types.toOwnedSlice(gpa), .return_type = return_type } };
}

const ExpressionResult = SemanticResult(UnresolvedBody.ValueId);

const UnresolvedExpressionBuilder = struct {
    ast: *const structures.Ast,
    source: []const u8,
    block_argument_count: u32,
    locals: *const std.StringHashMap(UnresolvedBody.ValueId),
    branch_arguments: *std.ArrayList(UnresolvedBody.ValueId),
    instructions: *std.ArrayList(UnresolvedBody.Instruction),
    joins: *std.ArrayList(UnresolvedBody.Join),
    call_arguments: *std.ArrayList(UnresolvedBody.ValueId),
    scratch: *std.ArrayList(UnresolvedBody.ValueId),
    blocks: *std.ArrayList(UnresolvedBody.Block),
    current_block: structures.FunctionBlockId = @enumFromInt(0),
    gpa: std.mem.Allocator,

    fn append(self: *UnresolvedExpressionBuilder, node_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const node = self.ast.nodes[node_index.index()];
        switch (node.tag) {
            .number_literal => return self.appendIntegerLiteral(node_index),
            .none_literal => return self.appendInstruction(node_index, .const_none),
            .call => return self.appendCall(node_index),
            .identifier => {
                const name_span = tokenSpan(self.ast, node.token_index);
                const value = self.locals.get(self.source[name_span.start..name_span.end]) orelse
                    return .{ .unsupported = .{ .span = name_span, .kind = .unknown_value } };
                return .{ .success = value };
            },
            .neg => {
                const operand = switch (try self.append(node.data.node)) {
                    .success => |operand| operand,
                    .unsupported => |issue| return .{ .unsupported = issue },
                };
                return self.appendInstruction(node_index, .{ .negi = operand });
            },
            .add, .sub, .mul, .div => return self.appendBinary(node_index),
            .if_else => return self.appendIf(node_index),
            else => return .{ .unsupported = issueAt(self.ast, node_index.index(), .expression_not_supported) },
        }
    }

    fn appendIntegerLiteral(self: *UnresolvedExpressionBuilder, node_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const node = self.ast.nodes[node_index.index()];
        const token = self.ast.tokens[node.token_index];
        const literal = self.source[token.loc.start..token.loc.end];
        for (literal) |byte| {
            if (!std.ascii.isDigit(byte)) {
                return .{ .unsupported = issueAt(self.ast, node_index.index(), .integer_literal_not_decimal) };
            }
        }
        const integer = std.fmt.parseInt(i32, literal, 10) catch
            return .{ .unsupported = issueAt(self.ast, node_index.index(), .integer_literal_out_of_range) };
        return self.appendInstruction(node_index, .{ .consti = integer });
    }

    fn appendBinary(self: *UnresolvedExpressionBuilder, node_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const node = self.ast.nodes[node_index.index()];
        const lhs = switch (try self.append(node.data.node_node.a)) {
            .success => |operand| operand,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        const rhs = switch (try self.append(node.data.node_node.b)) {
            .success => |operand| operand,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        const operation: UnresolvedBody.Instruction.Operation = switch (node.tag) {
            .add => .{ .addi = .{ .lhs = lhs, .rhs = rhs } },
            .sub => .{ .subi = .{ .lhs = lhs, .rhs = rhs } },
            .mul => .{ .muli = .{ .lhs = lhs, .rhs = rhs } },
            .div => .{ .divsi = .{ .lhs = lhs, .rhs = rhs } },
            else => unreachable,
        };
        return self.appendInstruction(node_index, operation);
    }

    fn appendIf(self: *UnresolvedExpressionBuilder, node_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const node = self.ast.nodes[node_index.index()];
        std.debug.assert(node.tag == .if_else);
        std.debug.assert(node.data.ref.end - node.data.ref.start == 3);
        const parts = self.ast.node_refs[node.data.ref.start..node.data.ref.end];
        const then_block = try self.newBlock(0);
        const else_block = try self.newBlock(0);
        switch (try self.appendCondition(parts[0], then_block, else_block)) {
            .success => {},
            .unsupported => |issue| return .{ .unsupported = issue },
        }

        self.enterBlock(then_block);
        const then_value = switch (try self.appendBranchValue(parts[1])) {
            .success => |value| value,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        const merge_block = try self.newBlock(1);
        const merge_argument = self.blocks.items[@intFromEnum(merge_block)].argument_start;
        self.terminate(.{ .branch = try self.branch(merge_block, &.{then_value}) });

        self.enterBlock(else_block);
        const else_value = switch (try self.appendBranchValue(parts[2])) {
            .success => |value| value,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        self.terminate(.{ .branch = try self.branch(merge_block, &.{else_value}) });
        try self.joins.append(self.gpa, .{
            .argument = merge_argument,
            .incoming = .{ then_value, else_value },
            .span = tokenSpan(self.ast, node.token_index),
            .instruction_count = @intCast(self.instructions.items.len),
        });
        self.enterBlock(merge_block);
        return .{ .success = .{ .block_argument = merge_argument } };
    }

    fn appendCondition(
        self: *UnresolvedExpressionBuilder,
        node_index: structures.Node.Index,
        then_block: structures.FunctionBlockId,
        else_block: structures.FunctionBlockId,
    ) std.mem.Allocator.Error!SemanticResult(void) {
        const node = self.ast.nodes[node_index.index()];
        const operation: UnresolvedBody.PredicateOperation = switch (node.tag) {
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            else => {
                const form_index = if (node.tag == .const_binding or node.tag == .var_binding) node.data.node_node.b else node_index;
                const kind: structures.Diagnostic.Kind = if (isFallibleExpression(self.ast.nodes[form_index.index()].tag))
                    .fallible_condition_not_supported
                else
                    .if_condition_not_fallible;
                return .{ .unsupported = issueAt(self.ast, form_index.index(), kind) };
            },
        };
        const lhs = switch (try self.append(node.data.node_node.a)) {
            .success => |value| value,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        const rhs = switch (try self.append(node.data.node_node.b)) {
            .success => |value| value,
            .unsupported => |issue| return .{ .unsupported = issue },
        };
        self.terminate(.{ .predicate_branch = .{
            .operation = operation,
            .operands = .{ .lhs = lhs, .rhs = rhs },
            .then_branch = try self.branch(then_block, &.{}),
            .else_branch = try self.branch(else_block, &.{}),
            .span = tokenSpan(self.ast, node.token_index),
        } });
        return .{ .success = {} };
    }

    fn appendBranchValue(self: *UnresolvedExpressionBuilder, node_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const node = self.ast.nodes[node_index.index()];
        if (node.tag != .block) return self.append(node_index);
        if (node.data.ref.end - node.data.ref.start != 1) {
            return .{ .unsupported = issueAt(self.ast, node_index.index(), .if_branch_shape_not_supported) };
        }
        return self.append(self.ast.node_refs[node.data.ref.start]);
    }

    fn appendCall(self: *UnresolvedExpressionBuilder, call_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const call = self.ast.nodes[call_index.index()];
        const callee_index = call.data.node_node.a.unwrap() orelse unreachable;
        const callee = self.ast.nodes[callee_index.index()];
        if (callee.tag != .identifier) {
            return .{ .unsupported = issueAt(self.ast, call_index.index(), .expression_not_supported) };
        }
        const name_span = tokenSpan(self.ast, callee.token_index);
        const name = self.source[name_span.start..name_span.end];
        const is_exit_intrinsic = std.mem.eql(u8, name, "exit");
        if (!is_exit_intrinsic and self.locals.contains(name)) {
            return .{ .unsupported = .{ .span = name_span, .kind = .value_not_callable } };
        }

        const scratch_start = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_start);
        var arguments = AstNodeListIterator.init(self.ast, call.data.node_node.b, .call_arg_list_small, .call_arg_list);
        while (arguments.next()) |argument_index| {
            const argument = switch (try self.append(argument_index)) {
                .success => |value| value,
                .unsupported => |issue| return .{ .unsupported = issue },
            };
            try self.scratch.append(self.gpa, argument);
        }

        const argument_start: u32 = @intCast(self.call_arguments.items.len);
        try self.call_arguments.appendSlice(self.gpa, self.scratch.items[scratch_start..]);
        const argument_end: u32 = @intCast(self.call_arguments.items.len);
        return self.appendInstruction(call_index, .{ .call = .{
            .target = name_span,
            .name = name,
            .arguments = .{ .start = argument_start, .end = argument_end },
        } });
    }

    fn appendInstruction(
        self: *UnresolvedExpressionBuilder,
        node_index: structures.Node.Index,
        operation: UnresolvedBody.Instruction.Operation,
    ) std.mem.Allocator.Error!ExpressionResult {
        try self.instructions.append(self.gpa, .{
            .operation = operation,
            .span = tokenSpan(self.ast, self.ast.nodes[node_index.index()].token_index),
        });
        return .{ .success = .{ .instruction = @intCast(self.instructions.items.len - 1) } };
    }

    fn newBlock(self: *UnresolvedExpressionBuilder, argument_count: u32) std.mem.Allocator.Error!structures.FunctionBlockId {
        const argument_start = self.block_argument_count;
        self.block_argument_count += argument_count;
        const block_index: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(self.gpa, .{
            .argument_start = argument_start,
            .argument_end = argument_start + argument_count,
        });
        return @enumFromInt(block_index);
    }

    fn enterBlock(self: *UnresolvedExpressionBuilder, block_id: structures.FunctionBlockId) void {
        const block = &self.blocks.items[@intFromEnum(block_id)];
        std.debug.assert(block.terminator == null);
        block.instruction_start = @intCast(self.instructions.items.len);
        self.current_block = block_id;
    }

    fn terminate(self: *UnresolvedExpressionBuilder, terminator: UnresolvedBody.Terminator) void {
        const block = &self.blocks.items[@intFromEnum(self.current_block)];
        std.debug.assert(block.terminator == null);
        block.instruction_end = @intCast(self.instructions.items.len);
        block.terminator = terminator;
    }

    fn branch(
        self: *UnresolvedExpressionBuilder,
        target: structures.FunctionBlockId,
        arguments: []const UnresolvedBody.ValueId,
    ) std.mem.Allocator.Error!UnresolvedBody.Branch {
        const start: u32 = @intCast(self.branch_arguments.items.len);
        try self.branch_arguments.appendSlice(self.gpa, arguments);
        return .{
            .target = target,
            .arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) },
        };
    }
};

const AstNodeListIterator = struct {
    ast: *const structures.Ast,
    inline_nodes: [2]structures.Node.Index = .{ .null, .null },
    end: u32 = 0,
    next_index: u32 = 0,
    uses_refs: bool = false,

    fn init(
        ast: *const structures.Ast,
        list_index: structures.Node.Index,
        small_tag: structures.Node.Tag,
        list_tag: structures.Node.Tag,
    ) AstNodeListIterator {
        const index = list_index.unwrap() orelse return .{ .ast = ast };
        const node = ast.nodes[index.index()];
        if (node.tag == small_tag) {
            return .{
                .ast = ast,
                .inline_nodes = .{ node.data.node_node.a, node.data.node_node.b },
                .end = if (node.data.node_node.b == .null) 1 else 2,
            };
        }
        std.debug.assert(node.tag == list_tag);
        return .{
            .ast = ast,
            .end = node.data.ref.end,
            .next_index = node.data.ref.start,
            .uses_refs = true,
        };
    }

    fn next(self: *AstNodeListIterator) ?structures.Node.Index {
        if (self.next_index == self.end) return null;
        const index = self.next_index;
        self.next_index += 1;
        return if (self.uses_refs) self.ast.node_refs[index] else self.inline_nodes[index];
    }
};

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
        return .{ .unsupported = .{ .span = span, .kind = unsupported_kind } };
    }
    if (node.tag != .type_variant_small and node.tag != .type_variant) {
        return .{ .unsupported = issueAt(ast, node_index.index(), unsupported_kind) };
    }

    var member_types: std.ArrayList(structures.TypeId) = .empty;
    defer member_types.deinit(gpa);
    var members = AstNodeListIterator.init(ast, node_index, .type_variant_small, .type_variant);
    while (members.next()) |member_index| {
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
            var member_index: usize = 0;
            var duplicate_members = AstNodeListIterator.init(ast, node_index, .type_variant_small, .type_variant);
            while (duplicate_members.next()) |duplicate_member| : (member_index += 1) {
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
    var function_disambiguators = std.StringHashMap(u32).init(gpa);
    defer function_disambiguators.deinit();

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
        const entry = try function_disambiguators.getOrPut(name);
        const disambiguator = if (entry.found_existing) entry.value_ptr.* else 0;
        entry.value_ptr.* = disambiguator + 1;
        try appendItem(gpa, &items, .function, ast.file_id, name, disambiguator, declaration.index());
    }

    try appendItem(gpa, &items, .top_level_entry, ast.file_id, "$entry", 0, 0);
    return .{ .file_id = ast.file_id, .items = try items.toOwnedSlice(gpa) };
}

fn appendItem(
    gpa: std.mem.Allocator,
    items: *std.ArrayList(structures.DiscoveredItem),
    kind: structures.ItemKind,
    file_id: structures.FileId,
    name: []const u8,
    disambiguator: u32,
    declaration: u32,
) !void {
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    try items.append(gpa, .{
        .loc = .{ .file_id = file_id, .kind = kind, .name = owned_name, .disambiguator = disambiguator },
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
    const result = try buildUnresolvedBody(parsed, source, declaration.index(), .function, &.{ .int, .int, .int }, .int, TestTypeInterner{}, gpa);
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
