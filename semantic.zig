const std = @import("std");
const structures = @import("structures.zig");

pub const Issue = struct {
    span: structures.SourceSpan,
    message: []const u8,
};

pub const SignatureResult = union(enum) {
    success: structures.FunctionSignature,
    unsupported: Issue,
};

pub const UnresolvedBody = struct {
    call_arguments: []ValueId,
    instructions: []Instruction,
    type_expectations: []TypeExpectation,
    block: Block,

    pub const ValueId = structures.FunctionValueId;
    pub const Instruction = struct {
        operation: Operation,
        span: structures.SourceSpan,

        pub const Operation = union(enum) {
            consti: i32,
            call: struct {
                target: structures.SourceSpan,
                arguments: structures.FunctionValueRange,
            },
            negi: ValueId,
            addi: structures.BinaryOperands,
            subi: structures.BinaryOperands,
            muli: structures.BinaryOperands,
            divsi: structures.BinaryOperands,
        };
    };

    pub const TypeExpectation = struct {
        value: ValueId,
        expected: structures.Type,
        span: structures.SourceSpan,
        instruction_count: u32,
    };

    pub const Terminator = union(enum) {
        return_unit,
        return_value: ValueId,
    };

    pub const Block = struct {
        terminator: Terminator,
        return_span: structures.SourceSpan,
    };

    pub fn deinit(self: *UnresolvedBody, gpa: std.mem.Allocator) void {
        gpa.free(self.call_arguments);
        gpa.free(self.instructions);
        gpa.free(self.type_expectations);
        self.* = undefined;
    }
};

pub const UnresolvedBodyResult = union(enum) {
    success: UnresolvedBody,
    unsupported: Issue,
};

const unsupported_entry_message = "runtime top-level statements are not supported yet";
const body_shape_message = "function body must end in one return; preceding statements must be const bindings or calls";
const return_value_message = "function return expression is not supported yet";
const expression_message = "expression is not supported yet";

pub fn buildUnresolvedEntryBody(ast: *const structures.Ast, source: []const u8, declaration: u32, gpa: std.mem.Allocator) !UnresolvedBodyResult {
    const root = ast.nodes[declaration];
    std.debug.assert(root.tag == .block);

    var instructions: std.ArrayList(UnresolvedBody.Instruction) = .empty;
    defer instructions.deinit(gpa);
    var type_expectations: std.ArrayList(UnresolvedBody.TypeExpectation) = .empty;
    defer type_expectations.deinit(gpa);
    var call_arguments: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer call_arguments.deinit(gpa);
    var expression_scratch: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer expression_scratch.deinit(gpa);
    var locals = std.StringHashMap(UnresolvedBody.ValueId).init(gpa);
    defer locals.deinit();
    var expression_builder: UnresolvedExpressionBuilder = .{
        .ast = ast,
        .source = source,
        .parameter_count = 0,
        .locals = &locals,
        .instructions = &instructions,
        .call_arguments = &call_arguments,
        .scratch = &expression_scratch,
        .gpa = gpa,
    };
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const child_index = ast.node_refs[ref_index];
        const child = ast.nodes[child_index.index()];
        if (child.tag == .static_binding) continue;
        if (child.tag != .call) {
            return .{ .unsupported = issueAt(ast, child_index.index(), unsupported_entry_message) };
        }
        switch (try expression_builder.append(child_index)) {
            .success => {},
            .unsupported => |issue| return .{ .unsupported = issue },
        }
    }
    const owned_call_arguments = try call_arguments.toOwnedSlice(gpa);
    errdefer gpa.free(owned_call_arguments);
    const owned_type_expectations = try type_expectations.toOwnedSlice(gpa);
    errdefer gpa.free(owned_type_expectations);
    return .{ .success = .{
        .call_arguments = owned_call_arguments,
        .instructions = try instructions.toOwnedSlice(gpa),
        .type_expectations = owned_type_expectations,
        .block = .{
            .terminator = .return_unit,
            .return_span = tokenSpan(ast, root.token_index),
        },
    } };
}

const FunctionParts = struct {
    signature: structures.Node.Index,
    body: structures.Node.Index,
};

pub fn analyzeFunctionSignature(ast: *const structures.Ast, source: []const u8, declaration: u32, gpa: std.mem.Allocator) !SignatureResult {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];

    var parameter_types: std.ArrayList(structures.Type) = .empty;
    defer parameter_types.deinit(gpa);
    var names = std.StringHashMap(void).init(gpa);
    defer names.deinit();
    var parameters = AstNodeListIterator.init(ast, signature.data.node_node.a, .param_list_small, .param_list);
    while (parameters.next()) |parameter_index| {
        const parameter = ast.nodes[parameter_index.index()];
        std.debug.assert(parameter.tag == .param);
        if (parameter.data.node_node.a.unwrap()) |access| {
            return .{ .unsupported = issueAt(ast, access.index(), "parameter modes are not supported yet") };
        }
        const name_span = tokenSpan(ast, parameter.token_index);
        const name = source[name_span.start..name_span.end];
        if (names.contains(name)) {
            return .{ .unsupported = .{ .span = name_span, .message = "duplicate parameter" } };
        }
        try names.put(name, {});
        const annotation = parameter.data.node_node.b.unwrap() orelse
            return .{ .unsupported = .{ .span = name_span, .message = "function parameters must declare type int" } };
        if (analyzeType(ast, source, annotation) != .int) {
            return .{ .unsupported = issueAt(ast, annotation.index(), "only int parameters are supported yet") };
        }
        try parameter_types.append(gpa, .int);
    }

    const return_type_index = signature.data.node_node.b.unwrap() orelse
        return .{ .unsupported = issueAt(ast, parts.signature.index(), "function must declare return type int or unit") };
    const return_type = analyzeType(ast, source, return_type_index) orelse
        return .{ .unsupported = issueAt(ast, return_type_index.index(), "only int and unit return types are supported yet") };

    return .{ .success = .{ .parameter_types = try parameter_types.toOwnedSlice(gpa), .return_type = return_type } };
}

pub fn buildUnresolvedFunctionBody(
    ast: *const structures.Ast,
    source: []const u8,
    declaration: u32,
    signature: structures.FunctionSignature,
    gpa: std.mem.Allocator,
) !UnresolvedBodyResult {
    const parts = functionParts(ast, declaration);
    const body = ast.nodes[parts.body.index()];
    var instructions: std.ArrayList(UnresolvedBody.Instruction) = .empty;
    defer instructions.deinit(gpa);
    var type_expectations: std.ArrayList(UnresolvedBody.TypeExpectation) = .empty;
    defer type_expectations.deinit(gpa);
    var call_arguments: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer call_arguments.deinit(gpa);
    var expression_scratch: std.ArrayList(UnresolvedBody.ValueId) = .empty;
    defer expression_scratch.deinit(gpa);
    var locals = std.StringHashMap(UnresolvedBody.ValueId).init(gpa);
    defer locals.deinit();

    const function_signature = ast.nodes[parts.signature.index()];
    var parameters = AstNodeListIterator.init(ast, function_signature.data.node_node.a, .param_list_small, .param_list);
    var parameter_index: usize = 0;
    while (parameters.next()) |parameter_node_index| : (parameter_index += 1) {
        const parameter = ast.nodes[parameter_node_index.index()];
        const name_span = tokenSpan(ast, parameter.token_index);
        try locals.put(source[name_span.start..name_span.end], @enumFromInt(parameter_index));
    }
    std.debug.assert(parameter_index == signature.parameter_types.len);

    var expression_builder: UnresolvedExpressionBuilder = .{
        .ast = ast,
        .source = source,
        .parameter_count = signature.parameter_types.len,
        .locals = &locals,
        .instructions = &instructions,
        .call_arguments = &call_arguments,
        .scratch = &expression_scratch,
        .gpa = gpa,
    };

    const return_index: structures.Node.Index = if (body.tag == .return_expr or body.tag == .return_nothing)
        parts.body
    else if (body.tag == .block) blk: {
        if (body.data.ref.start == body.data.ref.end) {
            return .{ .unsupported = issueAt(ast, parts.body.index(), body_shape_message) };
        }
        const return_ref = body.data.ref.end - 1;
        for (body.data.ref.start..return_ref) |ref_index| {
            const statement_index = ast.node_refs[ref_index];
            const statement = ast.nodes[statement_index.index()];
            switch (statement.tag) {
                .const_binding => {
                    const name_span = tokenSpan(ast, statement.token_index);
                    const name = source[name_span.start..name_span.end];
                    if (locals.contains(name)) {
                        return .{ .unsupported = .{ .span = name_span, .message = "duplicate local binding" } };
                    }
                    const annotation = statement.data.node_node.a.unwrap();
                    const expected_type = if (annotation) |type_node|
                        analyzeType(ast, source, type_node) orelse
                            return .{ .unsupported = issueAt(ast, type_node.index(), "only int and unit local bindings are supported yet") }
                    else
                        null;
                    const initializer = statement.data.node_node.b.unwrap() orelse unreachable;
                    const value = switch (try expression_builder.append(initializer)) {
                        .success => |value| value,
                        .unsupported => |issue| return .{ .unsupported = issue },
                    };
                    if (expected_type) |expected| {
                        const type_node = annotation.?;
                        try type_expectations.append(gpa, .{
                            .value = value,
                            .expected = expected,
                            .span = tokenSpan(ast, ast.nodes[type_node.index()].token_index),
                            .instruction_count = @intCast(instructions.items.len),
                        });
                    }
                    try locals.put(name, value);
                },
                .call => switch (try expression_builder.append(statement_index)) {
                    .success => {},
                    .unsupported => |issue| return .{ .unsupported = issue },
                },
                else => return .{ .unsupported = issueAt(ast, statement_index.index(), body_shape_message) },
            }
        }
        break :blk ast.node_refs[return_ref];
    } else {
        return .{ .unsupported = issueAt(ast, parts.body.index(), body_shape_message) };
    };

    const return_node = ast.nodes[return_index.index()];
    const terminator: UnresolvedBody.Terminator = switch (return_node.tag) {
        .return_nothing => .return_unit,
        .return_expr => blk: {
            const value_index = return_node.data.node.unwrap() orelse
                return .{ .unsupported = issueAt(ast, return_index.index(), return_value_message) };
            const return_value = switch (try expression_builder.append(value_index)) {
                .success => |value| value,
                .unsupported => |issue| return .{ .unsupported = issue },
            };
            break :blk .{ .return_value = return_value };
        },
        else => return .{ .unsupported = issueAt(ast, return_index.index(), body_shape_message) },
    };

    const owned_call_arguments = try call_arguments.toOwnedSlice(gpa);
    errdefer gpa.free(owned_call_arguments);
    const owned_type_expectations = try type_expectations.toOwnedSlice(gpa);
    errdefer gpa.free(owned_type_expectations);
    return .{ .success = .{
        .call_arguments = owned_call_arguments,
        .instructions = try instructions.toOwnedSlice(gpa),
        .type_expectations = owned_type_expectations,
        .block = .{
            .terminator = terminator,
            .return_span = tokenSpan(ast, return_node.token_index),
        },
    } };
}

const ExpressionResult = union(enum) {
    success: UnresolvedBody.ValueId,
    unsupported: Issue,
};

const UnresolvedExpressionBuilder = struct {
    ast: *const structures.Ast,
    source: []const u8,
    parameter_count: usize,
    locals: *const std.StringHashMap(UnresolvedBody.ValueId),
    instructions: *std.ArrayList(UnresolvedBody.Instruction),
    call_arguments: *std.ArrayList(UnresolvedBody.ValueId),
    scratch: *std.ArrayList(UnresolvedBody.ValueId),
    gpa: std.mem.Allocator,

    fn append(self: *UnresolvedExpressionBuilder, node_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const node = self.ast.nodes[node_index.index()];
        switch (node.tag) {
            .number_literal => {
                const token = self.ast.tokens[node.token_index];
                const literal = self.source[token.loc.start..token.loc.end];
                for (literal) |byte| {
                    if (!std.ascii.isDigit(byte)) {
                        return .{ .unsupported = issueAt(self.ast, node_index.index(), "only decimal integer literals are supported yet") };
                    }
                }
                const integer = std.fmt.parseInt(i32, literal, 10) catch
                    return .{ .unsupported = issueAt(self.ast, node_index.index(), "integer literal does not fit i32") };
                try self.appendInstruction(node_index, .{ .consti = integer });
            },
            .call => return self.appendCall(node_index),
            .identifier => {
                const name_span = tokenSpan(self.ast, node.token_index);
                const value = self.locals.get(self.source[name_span.start..name_span.end]) orelse
                    return .{ .unsupported = .{ .span = name_span, .message = "unknown value" } };
                return .{ .success = value };
            },
            .neg => {
                const operand = switch (try self.append(node.data.node)) {
                    .success => |operand| operand,
                    .unsupported => |issue| return .{ .unsupported = issue },
                };
                try self.appendInstruction(node_index, .{ .negi = operand });
            },
            .add, .sub, .mul, .div => {
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
                try self.appendInstruction(node_index, operation);
            },
            else => return .{ .unsupported = issueAt(self.ast, node_index.index(), expression_message) },
        }
        return .{ .success = structures.functionInstructionValue(self.parameter_count, self.instructions.items.len - 1) };
    }

    fn appendCall(self: *UnresolvedExpressionBuilder, call_index: structures.Node.Index) std.mem.Allocator.Error!ExpressionResult {
        const call = self.ast.nodes[call_index.index()];
        const callee_index = call.data.node_node.a.unwrap() orelse unreachable;
        const callee = self.ast.nodes[callee_index.index()];
        if (callee.tag != .identifier) {
            return .{ .unsupported = issueAt(self.ast, call_index.index(), expression_message) };
        }
        const name_span = tokenSpan(self.ast, callee.token_index);
        if (self.locals.contains(self.source[name_span.start..name_span.end])) {
            return .{ .unsupported = .{ .span = name_span, .message = "value is not callable" } };
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
        try self.appendInstruction(call_index, .{ .call = .{
            .target = name_span,
            .arguments = .{ .start = argument_start, .end = argument_end },
        } });
        return .{ .success = structures.functionInstructionValue(self.parameter_count, self.instructions.items.len - 1) };
    }

    fn appendInstruction(
        self: *UnresolvedExpressionBuilder,
        node_index: structures.Node.Index,
        operation: UnresolvedBody.Instruction.Operation,
    ) std.mem.Allocator.Error!void {
        try self.instructions.append(self.gpa, .{
            .operation = operation,
            .span = tokenSpan(self.ast, self.ast.nodes[node_index.index()].token_index),
        });
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

fn analyzeType(ast: *const structures.Ast, source: []const u8, node_index: structures.Node.Index) ?structures.Type {
    const node = ast.nodes[node_index.index()];
    if (node.tag != .type) return null;
    const span = tokenSpan(ast, node.token_index);
    const name = source[span.start..span.end];
    if (std.mem.eql(u8, name, "int")) return .int;
    if (std.mem.eql(u8, name, "unit")) return .unit;
    return null;
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

fn issueAt(ast: *const structures.Ast, node_index: u32, message: []const u8) Issue {
    return .{ .span = tokenSpan(ast, ast.nodes[node_index].token_index), .message = message };
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
        const value = node.data.node_node.b.unwrap() orelse continue;
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
    const result = try analyzeFunctionSignature(parsed, source, declaration.index(), gpa);
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
        \\  const value: int = second(b, c) + 1
        \\  return third(value, a, b) + value * -c
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try buildUnresolvedFunctionBody(parsed, source, declaration.index(), .{
        .parameter_types = &.{ .int, .int, .int },
        .return_type = .int,
    }, gpa);
    switch (result) {
        .success => |unresolved_value| {
            var unresolved = unresolved_value;
            unresolved.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}
