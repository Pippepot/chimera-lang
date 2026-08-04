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

pub const BodyShape = struct {
    instructions: []Instruction,
    block: Block,

    pub const ValueId = enum(u32) { _ };

    pub const Instruction = union(enum) {
        integer_constant: i32,
        call: structures.SourceSpan,
    };

    pub const Terminator = union(enum) {
        return_unit,
        return_value: ValueId,
    };

    pub const Block = struct {
        terminator: Terminator,
    };

    pub fn deinit(self: *BodyShape, gpa: std.mem.Allocator) void {
        gpa.free(self.instructions);
        self.* = undefined;
    }
};

pub const BodyResult = union(enum) {
    success: BodyShape,
    unsupported: Issue,
};

const unsupported_entry_message = "runtime top-level statements are not supported yet";
const body_shape_message = "function body must contain calls followed by one return";
const return_value_message = "function must return an integer literal or zero-argument function call";

pub fn analyzeEntryBody(ast: *const structures.Ast, declaration: u32, gpa: std.mem.Allocator) !BodyResult {
    const root = ast.nodes[declaration];
    std.debug.assert(root.tag == .block);

    var instructions: std.ArrayList(BodyShape.Instruction) = .empty;
    defer instructions.deinit(gpa);
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const child_index = ast.node_refs[ref_index];
        const child = ast.nodes[child_index.index()];
        if (child.tag == .comptime_binding) continue;
        const name_span = callNameSpan(ast, child_index) orelse {
            return .{ .unsupported = issueAt(ast, child_index.index(), unsupported_entry_message) };
        };
        try instructions.append(gpa, .{ .call = name_span });
    }
    return .{ .success = .{
        .instructions = try instructions.toOwnedSlice(gpa),
        .block = .{ .terminator = .return_unit },
    } };
}

const FunctionParts = struct {
    signature: structures.Node.Index,
    body: structures.Node.Index,
};

pub fn analyzeFunctionSignature(ast: *const structures.Ast, source: []const u8, declaration: u32) SignatureResult {
    const parts = functionParts(ast, declaration);
    const signature = ast.nodes[parts.signature.index()];

    if (signature.data.node_node.a.unwrap()) |params| {
        return .{ .unsupported = issueAt(ast, params.index(), "function parameters are not supported yet") };
    }

    const return_type_index = signature.data.node_node.b.unwrap() orelse
        return .{ .unsupported = issueAt(ast, parts.signature.index(), "function must declare return type int") };
    const return_type = ast.nodes[return_type_index.index()];
    if (return_type.tag != .type) {
        return .{ .unsupported = issueAt(ast, return_type_index.index(), "only int return type is supported yet") };
    }
    const token = ast.tokens[return_type.token_index];
    if (!std.mem.eql(u8, source[token.loc.start..token.loc.end], "int")) {
        return .{ .unsupported = issueAt(ast, return_type_index.index(), "only int return type is supported yet") };
    }

    return .{ .success = .{ .parameter_count = 0, .return_type = .int } };
}

pub fn analyzeFunctionBody(ast: *const structures.Ast, source: []const u8, declaration: u32, gpa: std.mem.Allocator) !BodyResult {
    const parts = functionParts(ast, declaration);
    const body = ast.nodes[parts.body.index()];
    var instructions: std.ArrayList(BodyShape.Instruction) = .empty;
    defer instructions.deinit(gpa);

    const return_index: structures.Node.Index = if (body.tag == .return_expr)
        parts.body
    else if (body.tag == .block) blk: {
        if (body.data.ref.start == body.data.ref.end) {
            return .{ .unsupported = issueAt(ast, parts.body.index(), body_shape_message) };
        }
        const return_ref = body.data.ref.end - 1;
        for (body.data.ref.start..return_ref) |ref_index| {
            const statement_index = ast.node_refs[ref_index];
            const name_span = callNameSpan(ast, statement_index) orelse
                return .{ .unsupported = issueAt(ast, statement_index.index(), body_shape_message) };
            try instructions.append(gpa, .{ .call = name_span });
        }
        break :blk ast.node_refs[return_ref];
    } else {
        return .{ .unsupported = issueAt(ast, parts.body.index(), body_shape_message) };
    };

    const return_node = ast.nodes[return_index.index()];
    if (return_node.tag != .return_expr) {
        return .{ .unsupported = issueAt(ast, return_index.index(), body_shape_message) };
    }
    const value_index = return_node.data.node.unwrap() orelse
        return .{ .unsupported = issueAt(ast, return_index.index(), return_value_message) };
    const value = ast.nodes[value_index.index()];
    const return_value: BodyShape.ValueId = @enumFromInt(instructions.items.len);
    if (value.tag == .call) {
        const name_span = callNameSpan(ast, value_index) orelse
            return .{ .unsupported = issueAt(ast, value_index.index(), return_value_message) };
        try instructions.append(gpa, .{ .call = name_span });
    } else if (value.tag == .number_literal) {
        const token = ast.tokens[value.token_index];
        const literal = source[token.loc.start..token.loc.end];
        for (literal) |byte| {
            if (!std.ascii.isDigit(byte)) {
                return .{ .unsupported = issueAt(ast, value_index.index(), "only decimal integer literals are supported yet") };
            }
        }
        const integer = std.fmt.parseInt(i32, literal, 10) catch
            return .{ .unsupported = issueAt(ast, value_index.index(), "integer literal does not fit i32") };
        try instructions.append(gpa, .{ .integer_constant = integer });
    } else {
        return .{ .unsupported = issueAt(ast, value_index.index(), return_value_message) };
    }

    return .{ .success = .{
        .instructions = try instructions.toOwnedSlice(gpa),
        .block = .{ .terminator = .{ .return_value = return_value } },
    } };
}

fn callNameSpan(ast: *const structures.Ast, call_index: structures.Node.Index) ?structures.SourceSpan {
    const call = ast.nodes[call_index.index()];
    if (call.tag != .call or call.data.node_node.b != .null) return null;
    const callee_index = call.data.node_node.a.unwrap() orelse unreachable;
    const callee = ast.nodes[callee_index.index()];
    if (callee.tag != .identifier) return null;
    const token = ast.tokens[callee.token_index];
    return .{ .start = token.loc.start, .end = token.loc.end };
}

fn functionParts(ast: *const structures.Ast, declaration: u32) FunctionParts {
    std.debug.assert(declaration < ast.nodes.len);
    const binding = ast.nodes[declaration];
    std.debug.assert(binding.tag == .comptime_binding);
    const value_index = binding.data.node_node.b.unwrap() orelse unreachable;
    const function = ast.nodes[value_index.index()];
    std.debug.assert(function.tag == .func);
    const signature = function.data.node_node.a.unwrap() orelse unreachable;
    const body = function.data.node_node.b.unwrap() orelse unreachable;
    std.debug.assert(ast.nodes[signature.index()].tag == .signature);
    return .{ .signature = signature, .body = body };
}

fn issueAt(ast: *const structures.Ast, node_index: u32, message: []const u8) Issue {
    const token = ast.tokens[ast.nodes[node_index].token_index];
    return .{ .span = .{ .start = token.loc.start, .end = token.loc.end }, .message = message };
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

        if (node.tag != .comptime_binding) continue;
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

test "function body shape cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testFunctionBodyShapeAllocations, .{});
}

fn testFunctionBodyShapeAllocations(gpa: std.mem.Allocator) !void {
    const parser = @import("ast_new.zig");
    const source =
        \\comptime target = func() int
        \\  first()
        \\  second()
        \\  return third()
    ;
    var report = try parser.parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const declaration = parsed.node_refs[parsed.nodes[0].data.ref.start];
    const result = try analyzeFunctionBody(parsed, source, declaration.index(), gpa);
    switch (result) {
        .success => |body_value| {
            var body = body_value;
            body.deinit(gpa);
        },
        .unsupported => unreachable,
    }
}
