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

pub const BodyResult = union(enum) {
    success: structures.FunctionBodyAnalysis,
    unsupported: Issue,
};

pub const EntryBodyResult = union(enum) {
    empty,
    direct_call: structures.SourceSpan,
    unsupported: Issue,
};

const unsupported_entry_message = "runtime top-level statements are not supported yet";
const literal_return_message = "function body must contain one integer literal return";

pub fn analyzeEntryBody(ast: *const structures.Ast, declaration: u32) EntryBodyResult {
    const root = ast.nodes[declaration];
    std.debug.assert(root.tag == .block);

    var direct_call: ?structures.SourceSpan = null;
    for (root.data.ref.start..root.data.ref.end) |ref_index| {
        const child_index = ast.node_refs[ref_index];
        const child = ast.nodes[child_index.index()];
        if (child.tag == .comptime_binding) continue;
        if (child.tag != .call or direct_call != null or child.data.node_node.b != .null) {
            return .{ .unsupported = issueAt(ast, child_index.index(), unsupported_entry_message) };
        }

        const callee_index = child.data.node_node.a.unwrap() orelse unreachable;
        const callee = ast.nodes[callee_index.index()];
        if (callee.tag != .identifier) {
            return .{ .unsupported = issueAt(ast, child_index.index(), unsupported_entry_message) };
        }
        const token = ast.tokens[callee.token_index];
        direct_call = .{ .start = token.loc.start, .end = token.loc.end };
    }
    return if (direct_call) |call| .{ .direct_call = call } else .empty;
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

pub fn analyzeFunctionBody(ast: *const structures.Ast, source: []const u8, declaration: u32) BodyResult {
    const parts = functionParts(ast, declaration);
    const body = ast.nodes[parts.body.index()];
    const return_index: structures.Node.Index = switch (body.tag) {
        .return_expr => parts.body,
        .block => blk: {
            if (body.data.ref.end - body.data.ref.start != 1) {
                return .{ .unsupported = issueAt(ast, parts.body.index(), literal_return_message) };
            }
            break :blk ast.node_refs[body.data.ref.start];
        },
        else => return .{ .unsupported = issueAt(ast, parts.body.index(), literal_return_message) },
    };

    const return_node = ast.nodes[return_index.index()];
    if (return_node.tag != .return_expr) {
        return .{ .unsupported = issueAt(ast, return_index.index(), literal_return_message) };
    }
    const value_index = return_node.data.node.unwrap() orelse
        return .{ .unsupported = issueAt(ast, return_index.index(), "function must return an integer literal") };
    const value = ast.nodes[value_index.index()];
    if (value.tag != .number_literal) {
        return .{ .unsupported = issueAt(ast, value_index.index(), "function must return an integer literal") };
    }

    const token = ast.tokens[value.token_index];
    const literal = source[token.loc.start..token.loc.end];
    for (literal) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return .{ .unsupported = issueAt(ast, value_index.index(), "only decimal integer literals are supported yet") };
        }
    }
    const return_value = std.fmt.parseInt(i32, literal, 10) catch
        return .{ .unsupported = issueAt(ast, value_index.index(), "integer literal does not fit i32") };
    return .{ .success = .{ .integer_return = return_value } };
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
