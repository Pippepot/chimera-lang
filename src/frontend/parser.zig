const std = @import("std");
const structures = @import("../structures.zig");
const tokenizer = @import("tokenizer.zig");
const Tokenizer = tokenizer.Tokenizer;
pub const Token = structures.Token;
pub const Node = structures.Node;
pub const Ast = structures.Ast;

const ParseDiagnostic = struct {
    kind: structures.Diagnostic.Kind,
    token_index: u32,
};

const ParseError = std.mem.Allocator.Error || error{ParseError};

const DeclarationName = struct {
    namespace: Node.Index,
    token_index: u32,
};

pub const ParseReport = struct {
    ast: ?Ast,
    diagnostics: []structures.Diagnostic,

    pub fn deinit(self: *ParseReport, gpa: std.mem.Allocator) void {
        if (self.ast) |*parsed| parsed.deinit(gpa);
        gpa.free(self.diagnostics);
        self.* = undefined;
    }
};

const ParserState = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    tokens: []Token,
    index: u32,
    nodes: std.ArrayList(Node),
    node_refs: std.ArrayList(Node.Index),
    scratch_stack: std.ArrayList(Node.Index),
    errors: std.ArrayList(ParseDiagnostic),

    pub fn deinit(self: *@This()) void {
        self.gpa.free(self.tokens);
        self.nodes.deinit(self.gpa);
        self.node_refs.deinit(self.gpa);
        self.scratch_stack.deinit(self.gpa);
        self.errors.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn intoAst(self: *@This(), file_id: structures.FileId) !Ast {
        const tokens = self.tokens;
        self.tokens = &.{};
        errdefer self.gpa.free(tokens);
        const nodes = try self.nodes.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(nodes);
        const node_refs = try self.node_refs.toOwnedSlice(self.gpa);
        return .{
            .file_id = file_id,
            .tokens = tokens,
            .nodes = nodes,
            .node_refs = node_refs,
        };
    }

    pub fn addNode(self: *@This(), node: Node) !Node.Index {
        const idx: Node.Index = @enumFromInt(self.nodes.items.len);
        try self.nodes.append(self.gpa, node);
        return idx;
    }

    pub fn reserveNode(self: *@This()) !Node.Index {
        const index: Node.Index = @enumFromInt(self.nodes.items.len);
        try self.nodes.resize(self.gpa, self.nodes.items.len + 1);
        return index;
    }

    pub fn setNode(self: *@This(), i: Node.Index, node: Node) Node.Index {
        self.nodes.items[@intFromEnum(i)] = node;
        return i;
    }

    pub fn eat(self: *@This(), token: Token.Tag) ?Token {
        const tok = self.tokens[self.index];
        if (tok.tag == token) {
            self.index += 1;
            return tok;
        }
        return null;
    }

    pub fn eatAny(self: *@This(), tokens: []const Token.Tag) ?Token {
        const tok = self.tokens[self.index];
        for (tokens) |token| {
            if (tok.tag == token) {
                self.index += 1;
                return tok;
            }
        }
        return null;
    }

    pub fn expect(self: *@This(), token: Token.Tag) !Token {
        const tok = self.tokens[self.index];
        if (tok.tag == token) {
            self.index += 1;
            return tok;
        }
        try self.addError(.{ .expected_token = .{ .expected = token, .found = tok.tag } });
        return error.ParseError;
    }

    pub fn listToSpan(parser: *@This(), list: []const Node.Index) !Node.Data {
        try parser.node_refs.appendSlice(parser.gpa, list);
        return .{ .ref = .{
            .start = @intCast(parser.node_refs.items.len - list.len),
            .end = @intCast(parser.node_refs.items.len),
        } };
    }

    pub fn addError(self: *@This(), kind: structures.Diagnostic.Kind) !void {
        try self.errors.append(self.gpa, .{ .kind = kind, .token_index = self.index });
    }
};

fn parseState(gpa: std.mem.Allocator, source: []const u8) !ParserState {
    var tok = try Tokenizer.init(gpa, source);
    defer tok.deinit();

    const estimated_token_count = source.len / 8;
    var tokens = try std.ArrayList(Token).initCapacity(gpa, estimated_token_count);
    errdefer tokens.deinit(gpa);

    while (true) {
        const token = try tok.next();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }

    var parser: ParserState = .{
        .gpa = gpa,
        .source = source,
        .tokens = try tokens.toOwnedSlice(gpa),
        .index = 0,
        .nodes = .empty,
        .node_refs = .empty,
        .scratch_stack = .empty,
        .errors = .empty,
    };
    errdefer parser.deinit();

    try parser.nodes.ensureTotalCapacity(gpa, parser.tokens.len / 2);
    try parser.node_refs.ensureTotalCapacity(gpa, parser.tokens.len / 4);

    parseDocument(&parser) catch |err| switch (err) {
        error.ParseError => {
            std.debug.assert(parser.errors.items.len != 0);
            return parser;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return parser;
}

fn parseDocument(parser: *ParserState) ParseError!void {
    _ = try parseBlock(parser);
    _ = try parser.expect(.eof);
}

pub fn parseReport(gpa: std.mem.Allocator, file_id: structures.FileId, source: []const u8) !ParseReport {
    var parser = try parseState(gpa, source);
    defer parser.deinit();

    const diagnostics = try parserDiagnostics(gpa, file_id, &parser);
    errdefer gpa.free(diagnostics);

    if (diagnostics.len != 0) return .{ .ast = null, .diagnostics = diagnostics };

    const parsed = try parser.intoAst(file_id);
    return .{ .ast = parsed, .diagnostics = diagnostics };
}

fn parseBlock(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    const reserved_idx = try parser.reserveNode();
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.dedent) != null) break;
        if (parser.tokens[parser.index].tag == .eof) break;
        if (parser.tokens[parser.index].tag == .indent) {
            try parser.addError(.unexpected_indented_block);
            return error.ParseError;
        }

        const expr = try parseExpression(parser);
        if (expr == .null) break;

        try parser.scratch_stack.append(parser.gpa, expr);
    }
    return parser.setNode(reserved_idx, .{ .tag = .block, .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseExpression(parser: *ParserState) ParseError!Node.Index {
    if (isBorrowBinding(parser)) return try parseBinding(parser);
    return switch (parser.tokens[parser.index].tag) {
        .keyword_comptime => try parseComptime(parser),
        .keyword_const, .keyword_var, .keyword_static => try parseBinding(parser),
        .keyword_pub => try parsePublic(parser),
        .keyword_import => try parseImport(parser),
        .keyword_func, .keyword_fallible, .keyword_extern => try parseFunction(parser),
        .keyword_return => try parseReturn(parser),
        .keyword_break => try parseBreak(parser),
        .keyword_continue => try parseTokenNode(parser, .keyword_continue, .continue_expr),
        .number_literal,
        .keyword_true,
        .keyword_false,
        .keyword_none,
        .keyword_if,
        .keyword_loop,
        .keyword_sizeof,
        .keyword_struct,
        .identifier,
        .l_paren,
        .keyword_not,
        .minus,
        => {
            const expr = try parseExpressionPrecedence(parser, 0);
            if (isAssignmentToken(parser.tokens[parser.index].tag)) return try parseAssign(parser, expr);
            return expr;
        },
        else => .null,
    };
}

fn parseBody(parser: *ParserState) !Node.Index {
    if (parser.eat(.arrow) != null) return try parseRequiredExpression(parser);
    _ = try parser.expect(.indent);
    return try parseBlock(parser);
}

fn parseCallableBody(parser: *ParserState) !Node.Index {
    if (parser.eat(.arrow) == null) {
        _ = try parser.expect(.indent);
        return parseBlock(parser);
    }

    const expression = try parseRequiredExpression(parser);
    if (parser.tokens[parser.index].tag == .indent) {
        try parser.addError(.indented_block_after_inline_body);
        return error.ParseError;
    }
    return switch (parser.nodes.items[expression.index()].tag) {
        .break_nothing, .break_expr, .continue_expr, .return_nothing, .return_expr => expression,
        else => parser.addNode(.{
            .tag = .return_expr,
            .token_index = parser.nodes.items[expression.index()].token_index,
            .data = .{ .node = expression },
        }),
    };
}

fn parseReturn(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const return_token = try parser.expect(.keyword_return);
    const next_token = parser.tokens[parser.index];
    std.debug.assert(return_token.loc.end <= next_token.loc.start);
    if (std.mem.indexOfScalar(u8, parser.source[return_token.loc.end..next_token.loc.start], '\n') != null) {
        return try parser.addNode(.{ .tag = .return_nothing, .token_index = token_index, .data = .{ .none = {} } });
    }
    if ((try parseExpression(parser)).unwrap()) |expr| {
        return try parser.addNode(.{ .tag = .return_expr, .token_index = token_index, .data = .{ .node = expr } });
    }
    return try parser.addNode(.{ .tag = .return_nothing, .token_index = token_index, .data = .{ .none = {} } });
}

fn parseBreak(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const break_token = try parser.expect(.keyword_break);
    const next_token = parser.tokens[parser.index];
    std.debug.assert(break_token.loc.end <= next_token.loc.start);
    if (std.mem.indexOfScalar(u8, parser.source[break_token.loc.end..next_token.loc.start], '\n') != null) {
        return try parser.addNode(.{ .tag = .break_nothing, .token_index = token_index, .data = .{ .none = {} } });
    }
    if ((try parseExpression(parser)).unwrap()) |expr| {
        return try parser.addNode(.{ .tag = .break_expr, .token_index = token_index, .data = .{ .node = expr } });
    }
    return try parser.addNode(.{ .tag = .break_nothing, .token_index = token_index, .data = .{ .none = {} } });
}

fn parseLoop(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_loop);
    const body = try parseBody(parser);
    return try parser.addNode(.{ .tag = .loop, .token_index = token_index, .data = .{ .node = body } });
}

fn parseComptime(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_comptime);
    const body = try parseBody(parser);
    return try parser.addNode(.{ .tag = .comptime_expr, .token_index = token_index, .data = .{ .node = body } });
}

fn parseBinding(parser: *ParserState) !Node.Index {
    const borrow_binding = isBorrowBinding(parser);
    const binding_keyword = parser.eat(.keyword_const) orelse parser.eat(.keyword_var) orelse parser.eat(.keyword_static) orelse
        (if (borrow_binding) parser.eat(.identifier) else null) orelse return .null;
    const writable_borrow = borrow_binding and parser.eat(.keyword_mut) != null;
    const name = try parseDeclarationName(parser, binding_keyword.tag == .keyword_static);
    const type_annotation = if (borrow_binding) Node.Index.null else try parseTypeAnnotation(parser);
    _ = try parser.expect(.equal);
    const explicit_type_value = if (type_annotation.unwrap()) |annotation| blk: {
        const node = parser.nodes.items[annotation.index()];
        const token = parser.tokens[node.token_index];
        break :blk node.tag == .type and std.mem.eql(u8, parser.source[token.loc.start..token.loc.end], "type");
    } else false;
    const inferred_variant_type = type_annotation == .null and
        (parser.tokens[parser.index].tag == .identifier or parser.tokens[parser.index].tag == .keyword_none) and
        parser.tokens[parser.index + 1].tag == .pipe;
    const value = if (binding_keyword.tag == .keyword_static and
        (explicit_type_value or inferred_variant_type) and
        parser.tokens[parser.index].tag != .keyword_struct)
        try parseType(parser)
    else
        try parseRequiredExpression(parser);
    const tag: Node.Tag = switch (binding_keyword.tag) {
        .keyword_const => .const_binding,
        .keyword_var => .var_binding,
        .keyword_static => .static_binding,
        .identifier => if (writable_borrow) .borrow_mut_binding else .borrow_binding,
        else => unreachable,
    };

    const binding = try parser.addNode(.{ .tag = tag, .token_index = name.token_index, .data = .{ .node_node = .{ .a = type_annotation, .b = value } } });
    return finishQualifiedDeclaration(parser, name, binding);
}

fn isBorrowBinding(parser: *ParserState) bool {
    const token = parser.tokens[parser.index];
    if (token.tag != .identifier or !std.mem.eql(u8, parser.source[token.loc.start..token.loc.end], "borrow")) return false;
    const name_index = parser.index + @as(u32, if (parser.tokens[parser.index + 1].tag == .keyword_mut) 2 else 1);
    return parser.tokens[name_index].tag == .identifier and parser.tokens[name_index + 1].tag == .equal;
}

fn parseDeclarationName(parser: *ParserState, allow_qualified: bool) !DeclarationName {
    _ = try parser.expect(.identifier);
    var name: DeclarationName = .{ .namespace = .null, .token_index = parser.index - 1 };
    if (!allow_qualified or parser.eat(.period) == null) return name;

    name.namespace = try parser.addNode(.{ .tag = .identifier, .token_index = name.token_index, .data = .{ .none = {} } });
    while (true) {
        _ = try parser.expect(.identifier);
        name.token_index = parser.index - 1;
        if (parser.eat(.period) == null) return name;
        name.namespace = try parser.addNode(.{ .tag = .field_access, .token_index = name.token_index, .data = .{ .node = name.namespace } });
    }
}

fn parsePublic(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_pub);
    const inner = switch (parser.tokens[parser.index].tag) {
        .keyword_const, .keyword_var, .keyword_static => try parseBinding(parser),
        .keyword_func, .keyword_fallible, .keyword_extern => try parseFunction(parser),
        .keyword_struct => try parseStruct(parser),
        .keyword_import => try parseImport(parser),
        else => {
            try parser.addError(.{ .invalid_expression = parser.tokens[parser.index].tag });
            return error.ParseError;
        },
    };
    return parser.addNode(.{ .tag = .@"pub", .token_index = token_index, .data = .{ .node = inner } });
}

fn parseImport(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_import);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    var target = try parseTokenNode(parser, .identifier, .identifier);
    while (parser.tokens[parser.index].tag == .period and parser.tokens[parser.index + 1].tag != .l_brace)
        target = try parseFieldAccess(parser, target);
    const aliased = parser.eat(.keyword_as) != null;
    if (aliased) {
        const as_index = parser.index - 1;
        const alias = try parseTokenNode(parser, .identifier, .identifier);
        target = try parser.addNode(.{ .tag = .as, .token_index = as_index, .data = .{ .node_node = .{ .a = target, .b = alias } } });
    }
    try parser.scratch_stack.append(parser.gpa, target);
    const selective = !aliased and parser.eat(.period) != null;
    if (selective) {
        _ = try parser.expect(.l_brace);
        while (true) {
            if (parser.eat(.r_brace) != null) break;
            try parser.scratch_stack.append(parser.gpa, try parseImportName(parser));
            if (parser.eat(.comma) != null) continue;
            _ = try parser.expect(.r_brace);
            break;
        }
    }
    return parser.addNode(.{ .tag = if (selective) .selective_import else .import, .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseImportName(parser: *ParserState) !Node.Index {
    var target = try parseTokenNode(parser, .identifier, .identifier);
    if (parser.eat(.keyword_as) != null) {
        const as_index = parser.index - 1;
        const alias = try parseTokenNode(parser, .identifier, .identifier);
        target = try parser.addNode(.{ .tag = .as, .token_index = as_index, .data = .{ .node_node = .{ .a = target, .b = alias } } });
    }
    return target;
}

fn parseAssign(parser: *ParserState, target: Node.Index) !Node.Index {
    const token_index = parser.index;
    const token = parser.tokens[parser.index];
    parser.index += 1;
    const value = try parseRequiredExpression(parser);
    const tag: Node.Tag = switch (token.tag) {
        .equal => .assign,
        .plus_equal => .add_assign,
        .minus_equal => .sub_assign,
        .asterisk_equal => .mul_assign,
        .slash_equal => .div_assign,
        else => unreachable,
    };
    return try parser.addNode(.{ .tag = tag, .token_index = token_index, .data = .{ .node_node = .{ .a = target, .b = value } } });
}

fn isAssignmentToken(tag: Token.Tag) bool {
    return switch (tag) {
        .equal, .plus_equal, .minus_equal, .asterisk_equal, .slash_equal => true,
        else => false,
    };
}

fn parseIfExpr(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_if);

    const condition = try parseRequiredExpression(parser);
    const then_body = try parseBody(parser);
    if (parser.eat(.keyword_else) != null) {
        const else_body = if (parser.eat(.indent) != null) try parseBlock(parser) else try parseRequiredExpression(parser);
        const ref_start: u32 = @intCast(parser.node_refs.items.len);
        try parser.node_refs.appendSlice(parser.gpa, &.{ condition, then_body, else_body });
        const ref_end: u32 = @intCast(parser.node_refs.items.len);
        return try parser.addNode(.{ .tag = .if_else, .token_index = token_index, .data = .{ .ref = .{ .start = ref_start, .end = ref_end } } });
    }
    return try parser.addNode(.{ .tag = .@"if", .token_index = token_index, .data = .{ .node_node = .{ .a = condition, .b = then_body } } });
}

fn parseFunction(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const external = parser.eat(.keyword_extern) != null;
    if (external) {
        if (parser.eatAny(&.{ .keyword_func, .keyword_fallible }) == null) {
            _ = try parser.expect(.keyword_func);
        }
    } else {
        _ = parser.eatAny(&.{ .keyword_func, .keyword_fallible }).?;
    }
    const name: ?DeclarationName = if (external or parser.tokens[parser.index].tag == .identifier)
        try parseDeclarationName(parser, true)
    else
        null;
    const signature = try parseFuncSignature(parser);
    const body = if (external) Node.Index.null else try parseCallableBody(parser);
    const value = try parser.addNode(.{ .tag = .func, .token_index = token_index, .data = .{ .node_node = .{ .a = signature, .b = body } } });
    const declared_name = name orelse return value;
    const declaration = try finishNamedDeclaration(parser, declared_name.token_index, value);
    return finishQualifiedDeclaration(parser, declared_name, declaration);
}

fn parseFuncSignature(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const params = try parseParamList(parser, false);
    const return_type: Node.Index = switch (parser.tokens[parser.index].tag) {
        .identifier, .keyword_func, .keyword_fallible, .keyword_none => try parseType(parser),
        else => .null,
    };
    var result = return_type;
    if (return_type != .null and parser.tokens[parser.index].tag == .identifier) {
        const origin_token = parser.tokens[parser.index];
        if (std.mem.eql(u8, parser.source[origin_token.loc.start..origin_token.loc.end], "from")) {
            const origin_token_index = parser.index;
            parser.index += 1;
            const origins = try parseCallArgList(parser);
            result = try parser.addNode(.{ .tag = .return_origins, .token_index = origin_token_index, .data = .{ .node_node = .{ .a = return_type, .b = origins } } });
        }
    }
    const where_token_index = parser.index;
    const where_start = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(where_start);
    while (parser.eat(.keyword_where) != null) {
        try parser.scratch_stack.append(parser.gpa, try parseExpressionPrecedence(parser, 0));
    }
    const clauses = if (where_start == parser.scratch_stack.items.len)
        Node.Index.null
    else
        try addNodeList(parser, where_token_index, parser.scratch_stack.items[where_start..], .where_clauses);
    return parser.addNode(.{ .tag = .signature, .token_index = token_index, .data = .{ .signature = .{
        .parameters = params,
        .return_type = result,
        .where_clauses = clauses,
    } } });
}

fn parseParamList(parser: *ParserState, parameters_are_static: bool) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_paren);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.r_paren) != null) break;

        const access_token_index = parser.index;
        const opt_access = if (parameters_are_static) null else parser.eatAny(&.{ .keyword_imm, .keyword_mut, .keyword_var, .keyword_deinit, .keyword_static });
        _ = try parser.expect(.identifier);
        const identifier_index = parser.index - 1;
        const type_annotation = try parseTypeAnnotation(parser);

        const access_idx: Node.Index = if (parameters_are_static)
            try parser.addNode(.{ .tag = .implicit_static, .token_index = access_token_index, .data = .{ .none = {} } })
        else if (opt_access != null)
            try parser.addNode(.{ .tag = .access, .token_index = access_token_index, .data = .{ .none = {} } })
        else
            .null;
        const param = try parser.addNode(.{ .tag = .param, .token_index = identifier_index, .data = .{ .node_node = .{ .a = access_idx, .b = type_annotation } } });

        try parser.scratch_stack.append(parser.gpa, param);

        if (parser.eat(.comma) != null) continue;
        _ = try parser.expect(.r_paren);
        break;
    }

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .param_list);
}

fn parseTypeAnnotation(parser: *ParserState) !Node.Index {
    if (parser.eat(.colon) != null) return try parseType(parser);
    return .null;
}

fn parseType(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    const first = try parseTypePrimary(parser);
    if (parser.tokens[parser.index].tag != .pipe) return first;

    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    try parser.scratch_stack.append(parser.gpa, first);

    while (parser.eat(.pipe) != null) {
        const member = try parseTypePrimary(parser);
        try parser.scratch_stack.append(parser.gpa, member);
    }

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .type_variant);
}

fn parseTypePrimary(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.tokens[parser.index].tag) {
        .identifier => blk: {
            const is_call = parser.tokens[parser.index + 1].tag == .l_paren;
            var value = try parseTokenNode(parser, .identifier, if (is_call) .identifier else .type);
            while (parser.tokens[parser.index].tag == .period) value = try parseFieldAccess(parser, value);
            if (parser.tokens[parser.index].tag == .l_paren) {
                const token_index = parser.index;
                const arguments = try parseCallArgList(parser);
                value = try parser.addNode(.{ .tag = .call, .token_index = token_index, .data = .{ .node_node = .{ .a = value, .b = arguments } } });
            }
            break :blk value;
        },
        .keyword_none => try parseTokenNode(parser, .keyword_none, .type),
        .keyword_func, .keyword_fallible => try parseFunctionType(parser),
        else => {
            try parser.addError(.{ .invalid_expression = parser.tokens[parser.index].tag });
            return error.ParseError;
        },
    };
}

fn parseFunctionType(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = parser.eatAny(&.{ .keyword_func, .keyword_fallible }).?;
    const params = try parseTypeList(parser);
    const return_type = try parseType(parser);
    return parser.addNode(.{ .tag = .type_func, .token_index = token_index, .data = .{ .node_node = .{ .a = params, .b = return_type } } });
}

fn parseTypeList(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_paren);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.r_paren) != null) break;

        const ty = try parseType(parser);
        try parser.scratch_stack.append(parser.gpa, ty);

        if (parser.eat(.comma) != null) continue;
        _ = try parser.expect(.r_paren);
        break;
    }

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .type_list);
}

const BinaryOpInfo = struct {
    tag: Node.Tag,
    precedence: u8,
    rhs: Rhs,

    const Rhs = enum {
        expression,
        type,
    };
};

fn binaryOpInfo(token: Token.Tag) ?BinaryOpInfo {
    return switch (token) {
        .keyword_or => .{ .tag = .@"or", .precedence = 1, .rhs = .expression },
        .keyword_and => .{ .tag = .@"and", .precedence = 2, .rhs = .expression },
        .equal_equal => .{ .tag = .eq, .precedence = 3, .rhs = .expression },
        .angle_bracket_left_angle_bracket_right => .{ .tag = .ne, .precedence = 3, .rhs = .expression },
        .angle_bracket_left => .{ .tag = .lt, .precedence = 3, .rhs = .expression },
        .angle_bracket_right => .{ .tag = .gt, .precedence = 3, .rhs = .expression },
        .angle_bracket_left_equal => .{ .tag = .le, .precedence = 3, .rhs = .expression },
        .angle_bracket_right_equal => .{ .tag = .ge, .precedence = 3, .rhs = .expression },
        .keyword_is => .{ .tag = .is, .precedence = 3, .rhs = .type },
        .keyword_as => .{ .tag = .as, .precedence = 3, .rhs = .type },
        .plus => .{ .tag = .add, .precedence = 4, .rhs = .expression },
        .minus => .{ .tag = .sub, .precedence = 4, .rhs = .expression },
        .asterisk => .{ .tag = .mul, .precedence = 5, .rhs = .expression },
        .slash => .{ .tag = .div, .precedence = 5, .rhs = .expression },
        else => null,
    };
}

fn parseExpressionPrecedence(parser: *ParserState, min_precedence: u8) ParseError!Node.Index {
    var lhs = try parseUnary(parser);

    while (binaryOpInfo(parser.tokens[parser.index].tag)) |op_info| {
        if (op_info.precedence < min_precedence) break;

        const token_index = parser.index;
        parser.index += 1;
        const rhs = switch (op_info.rhs) {
            .expression => try parseExpressionPrecedence(parser, op_info.precedence + 1),
            .type => try parseType(parser),
        };
        lhs = try parser.addNode(.{ .tag = op_info.tag, .token_index = token_index, .data = .{ .node_node = .{ .a = lhs, .b = rhs } } });
    }

    return lhs;
}

fn parseUnary(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    return switch (parser.tokens[parser.index].tag) {
        .keyword_not => {
            parser.index += 1;
            const operand = try parseExpressionPrecedence(parser, 3);
            return parser.addNode(.{ .tag = .not, .token_index = token_index, .data = .{ .node = operand } });
        },
        .minus => {
            parser.index += 1;
            const operand = try parseUnary(parser);
            return parser.addNode(.{ .tag = .neg, .token_index = token_index, .data = .{ .node = operand } });
        },
        else => parsePostfix(parser),
    };
}

fn parsePostfix(parser: *ParserState) ParseError!Node.Index {
    var lhs = try parsePrimary(parser);

    while (true) {
        switch (parser.tokens[parser.index].tag) {
            .l_paren => {
                const token_index = parser.index;
                const args = try parseCallArgList(parser);
                lhs = try parser.addNode(.{ .tag = .call, .token_index = token_index, .data = .{ .node_node = .{ .a = lhs, .b = args } } });
            },
            .l_brace => lhs = try parseStructInit(parser, lhs),
            .l_bracket => {
                const token_index = parser.index;
                parser.index += 1;
                _ = try parser.expect(.r_bracket);
                lhs = try parser.addNode(.{ .tag = .deref, .token_index = token_index, .data = .{ .node = lhs } });
            },
            .period => lhs = try parseFieldAccess(parser, lhs),
            .question_mark => lhs = try parsePostfixNode(parser, lhs, .query_op),
            .caret => lhs = try parsePostfixNode(parser, lhs, .move_expr),
            else => break,
        }
    }

    return lhs;
}

fn parsePrimary(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.tokens[parser.index].tag) {
        .number_literal => try parseTokenNode(parser, .number_literal, .number_literal),
        .keyword_true => try parseTokenNode(parser, .keyword_true, .bool_literal),
        .keyword_false => try parseTokenNode(parser, .keyword_false, .bool_literal),
        .keyword_none => try parseTokenNode(parser, .keyword_none, .none_literal),
        .keyword_if => try parseIfExpr(parser),
        .keyword_loop => try parseLoop(parser),
        .keyword_comptime => try parseComptime(parser),
        .keyword_sizeof => try parseSizeof(parser),
        .keyword_struct => try parseStruct(parser),
        .identifier => try parseTokenNode(parser, .identifier, .identifier),
        .l_paren => {
            const token_index = parser.index;
            _ = parser.eat(.l_paren);
            if (parser.eat(.r_paren) != null) {
                return parser.addNode(.{ .tag = .unit_literal, .token_index = token_index, .data = .{ .none = {} } });
            }
            const expr = try parseExpressionPrecedence(parser, 0);
            _ = try parser.expect(.r_paren);
            return expr;
        },
        else => {
            try parser.addError(.{ .invalid_expression = parser.tokens[parser.index].tag });
            return error.ParseError;
        },
    };
}

fn parseCallArgList(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_paren);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.r_paren) != null) break;

        const arg = try parseExpressionPrecedence(parser, 0);
        try parser.scratch_stack.append(parser.gpa, arg);

        if (parser.eat(.comma) != null) continue;
        _ = try parser.expect(.r_paren);
        break;
    }

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .call_arg_list);
}

fn parseStruct(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_struct);
    const name_token_index: ?u32 = if (parser.eat(.identifier) != null) parser.index - 1 else null;
    if (name_token_index != null and parser.tokens[parser.index].tag == .l_paren) {
        const parameters = try parseParamList(parser, true);
        const value = try parseStructValue(parser, token_index);
        const return_type = try parser.addNode(.{ .tag = .implicit_type, .token_index = token_index, .data = .{ .none = {} } });
        const signature = try parser.addNode(.{ .tag = .signature, .token_index = token_index, .data = .{ .signature = .{
            .parameters = parameters,
            .return_type = return_type,
            .where_clauses = .null,
        } } });
        const body = try parser.addNode(.{ .tag = .return_expr, .token_index = token_index, .data = .{ .node = value } });
        const function = try parser.addNode(.{ .tag = .func, .token_index = token_index, .data = .{ .node_node = .{ .a = signature, .b = body } } });
        return finishNamedDeclaration(parser, name_token_index, function);
    }
    const value = try parseStructValue(parser, token_index);
    return finishNamedDeclaration(parser, name_token_index, value);
}

fn parseStructValue(parser: *ParserState, token_index: u32) ParseError!Node.Index {
    _ = try parser.expect(.indent);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.dedent) != null) break;
        if (parser.tokens[parser.index].tag == .eof) break;

        const item = try parseStructItem(parser);
        try parser.scratch_stack.append(parser.gpa, item);
    }

    return parser.addNode(.{ .tag = .@"struct", .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseStructItem(parser: *ParserState) ParseError!Node.Index {
    if ((try parseBinding(parser)).unwrap()) |binding| return binding;
    if (parser.tokens[parser.index].tag == .keyword_pub) return parsePublic(parser);
    if (parser.tokens[parser.index].tag == .keyword_func or parser.tokens[parser.index].tag == .keyword_fallible or parser.tokens[parser.index].tag == .keyword_struct) {
        return parseExpression(parser);
    }
    return switch (parser.tokens[parser.index + 1].tag) {
        .equal => try parseStructProperty(parser),
        else => try parseStructField(parser),
    };
}

fn parseStructField(parser: *ParserState) ParseError!Node.Index {
    const identifier_index = parser.index;
    _ = try parser.expect(.identifier);
    _ = try parser.expect(.colon);
    const field_type = try parseType(parser);
    return try parser.addNode(.{ .tag = .struct_field, .token_index = identifier_index, .data = .{ .node = field_type } });
}

fn parseStructProperty(parser: *ParserState) ParseError!Node.Index {
    const identifier_index = parser.index;
    _ = try parser.expect(.identifier);
    _ = try parser.expect(.equal);
    const value = try parseRequiredExpression(parser);
    return try parser.addNode(.{ .tag = .struct_property, .token_index = identifier_index, .data = .{ .node = value } });
}

fn parseStructInit(parser: *ParserState, target: Node.Index) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_brace);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    try parser.scratch_stack.append(parser.gpa, target);
    while (true) {
        if (parser.eat(.r_brace) != null) break;

        const field = try parseStructInitField(parser);
        try parser.scratch_stack.append(parser.gpa, field);

        if (parser.eat(.comma) != null) continue;
        _ = try parser.expect(.r_brace);
        break;
    }

    return try parser.addNode(.{ .tag = .struct_init, .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseStructInitField(parser: *ParserState) ParseError!Node.Index {
    const identifier_index = parser.index;
    _ = try parser.expect(.identifier);
    _ = try parser.expect(.equal);
    const value = try parseRequiredExpression(parser);
    return try parser.addNode(.{ .tag = .struct_init_field, .token_index = identifier_index, .data = .{ .node = value } });
}

fn parseFieldAccess(parser: *ParserState, target: Node.Index) ParseError!Node.Index {
    _ = try parser.expect(.period);
    const field_index = parser.index;
    _ = try parser.expect(.identifier);
    return try parser.addNode(.{ .tag = .field_access, .token_index = field_index, .data = .{ .node = target } });
}

fn parseSizeof(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_sizeof);
    _ = try parser.expect(.l_paren);
    const ty = try parseType(parser);
    _ = try parser.expect(.r_paren);
    return try parser.addNode(.{ .tag = .sizeof_expr, .token_index = token_index, .data = .{ .node = ty } });
}

fn parsePostfixNode(parser: *ParserState, operand: Node.Index, tag: Node.Tag) ParseError!Node.Index {
    const token_index = parser.index;
    parser.index += 1;
    return try parser.addNode(.{ .tag = tag, .token_index = token_index, .data = .{ .node = operand } });
}

fn parseRequiredExpression(parser: *ParserState) ParseError!Node.Index {
    const expression = try parseExpression(parser);
    if (expression != .null) return expression;

    try parser.addError(.{ .invalid_expression = parser.tokens[parser.index].tag });
    return error.ParseError;
}

fn addNodeList(parser: *ParserState, token_index: u32, items: []const Node.Index, tag: Node.Tag) !Node.Index {
    if (items.len == 0) return .null;
    return parser.addNode(.{ .tag = tag, .token_index = token_index, .data = try parser.listToSpan(items) });
}

fn finishNamedDeclaration(parser: *ParserState, name_token_index: ?u32, value: Node.Index) !Node.Index {
    const token_index = name_token_index orelse return value;
    return parser.addNode(.{
        .tag = .static_binding,
        .token_index = token_index,
        .data = .{ .node_node = .{ .a = .null, .b = value } },
    });
}

fn finishQualifiedDeclaration(parser: *ParserState, name: DeclarationName, declaration: Node.Index) !Node.Index {
    if (name.namespace == .null) return declaration;
    return parser.addNode(.{
        .tag = .namespace_declaration,
        .token_index = name.token_index,
        .data = .{ .node_node = .{ .a = name.namespace, .b = declaration } },
    });
}

fn parseTokenNode(parser: *ParserState, token: Token.Tag, tag: Node.Tag) !Node.Index {
    _ = try parser.expect(token);
    return parser.addNode(.{ .tag = tag, .token_index = parser.index - 1, .data = .{ .none = {} } });
}

fn parserDiagnostics(gpa: std.mem.Allocator, file_id: structures.FileId, parser: *const ParserState) ![]structures.Diagnostic {
    const diagnostics = try gpa.alloc(structures.Diagnostic, parser.errors.items.len);
    errdefer gpa.free(diagnostics);

    for (parser.errors.items, diagnostics) |parse_diag, *out| {
        const token = parser.tokens[parse_diag.token_index];
        out.* = .{
            .file_id = file_id,
            .span = .{ .start = token.loc.start, .end = token.loc.end },
            .kind = parse_diag.kind,
        };
    }

    return diagnostics;
}

pub fn renderAst(gpa: std.mem.Allocator, ast: *const Ast, source: []const u8, writer: *std.Io.Writer) !void {
    std.debug.assert(ast.nodes[0].tag == .block);
    const seen = try gpa.alloc(bool, ast.nodes.len);
    defer gpa.free(seen);
    @memset(seen, false);
    const block_ref = ast.nodes[0].data.ref;
    for (block_ref.start..block_ref.end) |i| {
        try renderNode(gpa, ast.node_refs[i], ast, source, writer, seen, "", i == block_ref.end - 1, true);
    }
}

fn renderNode(gpa: std.mem.Allocator, node_index: Node.Index, ast: *const Ast, source: []const u8, writer: *std.Io.Writer, seen: []bool, indent: []const u8, is_last: bool, at_root: bool) !void {
    const node = ast.nodes[node_index.index()];
    try writer.writeAll(indent);
    if (!at_root) try writer.writeAll(if (is_last) "└─" else "├─");
    try writer.print("{s}", .{@tagName(node.tag)});

    if (seen[node_index.index()]) {
        try writer.writeAll(" ...\n");
        return;
    }

    seen[node_index.index()] = true;
    const new_indent = if (at_root) "" else try std.mem.concat(gpa, u8, &.{ indent, if (is_last) "  " else "│ " });
    defer if (!at_root) gpa.free(new_indent);
    switch (node.tag) {
        .break_nothing, .continue_expr, .return_nothing => try writer.writeByte('\n'),
        .access, .bool_literal, .identifier, .none_literal, .type, .number_literal => {
            const loc = ast.tokens[node.token_index].loc;
            try writer.print(" : {s}\n", .{source[loc.start..loc.end]});
        },
        .unit_literal => try writer.writeAll(" : ()\n"),
        .implicit_static, .implicit_type => try writer.writeByte('\n'),
        .break_expr, .return_expr, .loop, .not, .neg, .query_op, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .deref, .struct_field, .struct_property, .struct_init_field, .@"pub" => {
            if (node.tag == .field_access or node.tag == .struct_field or node.tag == .struct_property or node.tag == .struct_init_field) {
                const loc = ast.tokens[node.token_index].loc;
                try writer.print(" : {s}", .{source[loc.start..loc.end]});
            }
            try writer.writeByte('\n');
            try renderNode(gpa, node.data.node, ast, source, writer, seen, new_indent, true, false);
        },
        .add, .sub, .mul, .div, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .@"and", .@"or", .assign, .add_assign, .sub_assign, .mul_assign, .div_assign, .call, .const_binding, .var_binding, .borrow_binding, .borrow_mut_binding, .static_binding, .namespace_declaration, .func, .param, .return_origins, .type_func, .@"if" => {
            if (node.tag == .param) {
                const loc = ast.tokens[node.token_index].loc;
                try writer.print(" : {s}", .{source[loc.start..loc.end]});
            }
            try writer.writeByte('\n');
            const b_node = node.data.node_node.b.unwrap();
            if (node.data.node_node.a.unwrap()) |a| {
                try renderNode(gpa, a, ast, source, writer, seen, new_indent, b_node == null, false);
            }
            if (b_node) |b| {
                try renderNode(gpa, b, ast, source, writer, seen, new_indent, true, false);
            }
        },
        .signature => {
            try writer.writeByte('\n');
            const parts = node.data.signature;
            const last = if (parts.where_clauses != .null) parts.where_clauses else parts.return_type;
            if (parts.parameters.unwrap()) |parameters| try renderNode(gpa, parameters, ast, source, writer, seen, new_indent, last == .null, false);
            if (parts.return_type.unwrap()) |result| try renderNode(gpa, result, ast, source, writer, seen, new_indent, result == last, false);
            if (parts.where_clauses.unwrap()) |clauses| try renderNode(gpa, clauses, ast, source, writer, seen, new_indent, true, false);
        },
        .block, .call_arg_list, .param_list, .type_list, .type_variant, .where_clauses, .if_else, .@"struct", .struct_init, .import, .selective_import => {
            try writer.writeByte('\n');
            for (node.data.ref.start..node.data.ref.end) |i| {
                try renderNode(gpa, ast.node_refs[i], ast, source, writer, seen, new_indent, i == node.data.ref.end - 1, false);
            }
        },
        else => try writer.print("Not implemented {}\n", .{node.tag}),
    }
}

test "parse function no parameters" {
    try testParsing(
        \\static foo = func() int
        \\  return 1
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ └─type : int
        \\  └─block
        \\    └─return_expr
        \\      └─number_literal : 1
    );
}

test "parse inline function no parameters" {
    try testParsing(
        \\static foo = func() int -> return 1
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ └─type : int
        \\  └─return_expr
        \\    └─number_literal : 1
    );
}

test "parse named function declaration and implicit inline return" {
    try testParsing(
        \\func double(x: int) int -> x * 2
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ └─param : x
        \\  │ │   └─type : int
        \\  │ └─type : int
        \\  └─return_expr
        \\    └─mul
        \\      ├─identifier : x
        \\      └─number_literal : 2
    );
}

test "parse qualified named function declaration" {
    try testParsing(
        \\func S.id(imm self: S) int -> self.i
    ,
        \\namespace_declaration
        \\├─identifier : S
        \\└─static_binding
        \\  └─func
        \\    ├─signature
        \\    │ ├─param_list
        \\    │ │ └─param : self
        \\    │ │   ├─access : imm
        \\    │ │   └─type : S
        \\    │ └─type : int
        \\    └─return_expr
        \\      └─field_access : i
        \\        └─identifier : self
    );
}

test "parse fallible function declarations and callable types" {
    try testParsing(
        \\fallible checked(value: int) int -> value
        \\static typed: fallible(int) int = fallible(value: int) int -> value
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ └─param : value
        \\  │ │   └─type : int
        \\  │ └─type : int
        \\  └─return_expr
        \\    └─identifier : value
        \\static_binding
        \\├─type_func
        \\│ ├─type_list
        \\│ │ └─type : int
        \\│ └─type : int
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ └─param : value
        \\  │ │   └─type : int
        \\  │ └─type : int
        \\  └─return_expr
        \\    └─identifier : value
    );
}

test "parse unit value spellings" {
    try testParsing(
        \\const word = unit
        \\const punctuation = ()
    ,
        \\const_binding
        \\└─identifier : unit
        \\const_binding
        \\└─unit_literal : ()
    );
}

test "parse bare return" {
    try testParsing(
        \\static noop = func() unit
        \\  return
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ └─type : unit
        \\  └─block
        \\    └─return_nothing
    );
}

test "parse inline bare return before another declaration" {
    const source =
        \\static noop = func() unit -> return
        \\static value = func() int -> return 1
    ;
    var report = try parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    const root = parsed.nodes[0];
    try std.testing.expectEqual(@as(u32, 2), root.data.ref.end - root.data.ref.start);
    const first_binding = parsed.nodes[parsed.node_refs[root.data.ref.start].index()];
    const first_function = parsed.nodes[first_binding.data.node_node.b.index()];
    try std.testing.expectEqual(Node.Tag.return_nothing, parsed.nodes[first_function.data.node_node.b.index()].tag);
    try std.testing.expectEqual(Node.Tag.static_binding, parsed.nodes[parsed.node_refs[root.data.ref.start + 1].index()].tag);
}

test "parse function with parameters" {
    try testParsing(
        \\static add = func(x: int, y: int) int
        \\  return x + y
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ ├─param : x
        \\  │ │ │ └─type : int
        \\  │ │ └─param : y
        \\  │ │   └─type : int
        \\  │ └─type : int
        \\  └─block
        \\    └─return_expr
        \\      └─add
        \\        ├─identifier : x
        \\        └─identifier : y
    );
}

test "parse const var assignment" {
    try testParsing(
        \\const a = 1
        \\const b: int = 2
        \\var c = 2.5
        \\c = 3.5
        \\c += 1.0
        \\c -= 1.0
        \\c *= 2.0
        \\c /= 2.0
        \\const d = c = 4.5
    ,
        \\const_binding
        \\└─number_literal : 1
        \\const_binding
        \\├─type : int
        \\└─number_literal : 2
        \\var_binding
        \\└─number_literal : 2.5
        \\assign
        \\├─identifier : c
        \\└─number_literal : 3.5
        \\add_assign
        \\├─identifier : c
        \\└─number_literal : 1.0
        \\sub_assign
        \\├─identifier : c
        \\└─number_literal : 1.0
        \\mul_assign
        \\├─identifier : c
        \\└─number_literal : 2.0
        \\div_assign
        \\├─identifier : c
        \\└─number_literal : 2.0
        \\const_binding
        \\└─assign
        \\  ├─identifier : c
        \\  └─number_literal : 4.5
    );
}

test "parse variant type annotations" {
    try testParsing(
        \\const a: int | float = 1
        \\var b: int | float | none = none
    ,
        \\const_binding
        \\├─type_variant
        \\│ ├─type : int
        \\│ └─type : float
        \\└─number_literal : 1
        \\var_binding
        \\├─type_variant
        \\│ ├─type : int
        \\│ ├─type : float
        \\│ └─type : none
        \\└─none_literal : none
    );
}

test "parse static variant type value" {
    try testParsing(
        \\static Result = int | none
        \\static Empty: type = none
    ,
        \\static_binding
        \\└─type_variant
        \\  ├─type : int
        \\  └─type : none
        \\static_binding
        \\├─type : type
        \\└─type : none
    );
}

test "parse function type annotations" {
    try testParsing(
        \\const f: func(int, float) int = add
        \\const g: func() none = noop
        \\const h: func(int, float, bool) none = tri
    ,
        \\const_binding
        \\├─type_func
        \\│ ├─type_list
        \\│ │ ├─type : int
        \\│ │ └─type : float
        \\│ └─type : int
        \\└─identifier : add
        \\const_binding
        \\├─type_func
        \\│ └─type : none
        \\└─identifier : noop
        \\const_binding
        \\├─type_func
        \\│ ├─type_list
        \\│ │ ├─type : int
        \\│ │ ├─type : float
        \\│ │ └─type : bool
        \\│ └─type : none
        \\└─identifier : tri
    );
}

test "parse function signatures with compound types" {
    try testParsing(
        \\static apply = func(f: func(int) int, x: int | float) int | none
        \\  return none
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ ├─param : f
        \\  │ │ │ └─type_func
        \\  │ │ │   ├─type_list
        \\  │ │ │   │ └─type : int
        \\  │ │ │   └─type : int
        \\  │ │ └─param : x
        \\  │ │   └─type_variant
        \\  │ │     ├─type : int
        \\  │ │     └─type : float
        \\  │ └─type_variant
        \\  │   ├─type : int
        \\  │   └─type : none
        \\  └─block
        \\    └─return_expr
        \\      └─none_literal : none
    );
}

test "parse direct calls in type positions" {
    const source = "func use(value: choose(true)) int -> value";
    var report = try parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const ast = &report.ast.?;
    const binding = ast.nodes[ast.node_refs[ast.nodes[0].data.ref.start].index()];
    const function = ast.nodes[binding.data.node_node.b.index()];
    const signature = ast.nodes[function.data.node_node.a.index()];
    const parameters = ast.nodes[signature.data.signature.parameters.index()];
    const parameter = ast.nodes[ast.node_refs[parameters.data.ref.start].index()];
    const call = ast.nodes[parameter.data.node_node.b.index()];
    try std.testing.expectEqual(Node.Tag.call, call.tag);
    try std.testing.expectEqual(Node.Tag.identifier, ast.nodes[call.data.node_node.a.index()].tag);
    try std.testing.expectEqual(Node.Tag.bool_literal, ast.nodes[ast.node_refs[ast.nodes[call.data.node_node.b.index()].data.ref.start].index()].tag);
}

test "parse qualified types and factory calls" {
    const source = "func use(value: physics.Box(int)) physics.Body -> value";
    var report = try parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    const ast = &report.ast.?;
    const binding = ast.nodes[ast.node_refs[ast.nodes[0].data.ref.start].index()];
    const function = ast.nodes[binding.data.node_node.b.index()];
    const signature = ast.nodes[function.data.node_node.a.index()];
    const parameters = ast.nodes[signature.data.signature.parameters.index()];
    const parameter = ast.nodes[ast.node_refs[parameters.data.ref.start].index()];
    const call = ast.nodes[parameter.data.node_node.b.index()];
    try std.testing.expectEqual(Node.Tag.call, call.tag);
    try std.testing.expectEqual(Node.Tag.field_access, ast.nodes[call.data.node_node.a.index()].tag);
    try std.testing.expectEqual(Node.Tag.field_access, ast.nodes[signature.data.signature.return_type.index()].tag);
}

test "parse struct declaration" {
    try testParsing(
        \\static Vec2 = struct
        \\  x: int
        \\  y: float
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_field : x
        \\  │ └─type : int
        \\  └─struct_field : y
        \\    └─type : float
    );
}

test "parse struct properties" {
    try testParsing(
        \\static S = struct
        \\  move = none
        \\  copy = trivial
        \\  drop = explicit
        \\  debug = true
        \\  x: int
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_property : move
        \\  │ └─none_literal : none
        \\  ├─struct_property : copy
        \\  │ └─identifier : trivial
        \\  ├─struct_property : drop
        \\  │ └─identifier : explicit
        \\  ├─struct_property : debug
        \\  │ └─bool_literal : true
        \\  └─struct_field : x
        \\    └─type : int
    );
}

test "parse reserved-looking struct field names" {
    try testParsing(
        \\static S = struct
        \\  move: int
        \\  copy: int
        \\  drop: int
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_field : move
        \\  │ └─type : int
        \\  ├─struct_field : copy
        \\  │ └─type : int
        \\  └─struct_field : drop
        \\    └─type : int
    );
}

test "parse function defined inside struct" {
    try testParsing(
        \\static S = struct
        \\  x: int
        \\  static make = func(v: int) S
        \\    return S{x = v}
        \\  y: int
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_field : x
        \\  │ └─type : int
        \\  ├─static_binding
        \\  │ └─func
        \\  │   ├─signature
        \\  │   │ ├─param_list
        \\  │   │ │ └─param : v
        \\  │   │ │   └─type : int
        \\  │   │ └─type : S
        \\  │   └─block
        \\  │     └─return_expr
        \\  │       └─struct_init
        \\  │         ├─identifier : S
        \\  │         └─struct_init_field : x
        \\  │           └─identifier : v
        \\  └─struct_field : y
        \\    └─type : int
    );
}

test "parse public function inside struct" {
    const source =
        \\pub struct S
        \\  pub fallible new() S -> return S{}
    ;
    var report = try parseReport(std.testing.allocator, 0, source);
    defer report.deinit(std.testing.allocator);
    const ast = report.ast orelse return error.TestUnexpectedResult;
    var public_count: usize = 0;
    for (ast.nodes) |node| if (node.tag == .@"pub") {
        public_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), public_count);
}

test "parse qualified namespace declaration" {
    try testParsing(
        \\static S.id = func(imm self: S) int -> self.i
    ,
        \\namespace_declaration
        \\├─identifier : S
        \\└─static_binding
        \\  └─func
        \\    ├─signature
        \\    │ ├─param_list
        \\    │ │ └─param : self
        \\    │ │   ├─access : imm
        \\    │ │   └─type : S
        \\    │ └─type : int
        \\    └─return_expr
        \\      └─field_access : i
        \\        └─identifier : self
    );
}

test "parse struct ownership hook functions" {
    try testParsing(
        \\static Box = struct
        \\  x: int
        \\  copy = func(imm self: Box) Box -> Box{x = self.x + 1}
        \\  move = func(var self: Box) Box -> Box{x = self.x + 10}
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_field : x
        \\  │ └─type : int
        \\  ├─struct_property : copy
        \\  │ └─func
        \\  │   ├─signature
        \\  │   │ ├─param_list
        \\  │   │ │ └─param : self
        \\  │   │ │   ├─access : imm
        \\  │   │ │   └─type : Box
        \\  │   │ └─type : Box
        \\  │   └─return_expr
        \\  │     └─struct_init
        \\  │       ├─identifier : Box
        \\  │       └─struct_init_field : x
        \\  │         └─add
        \\  │           ├─field_access : x
        \\  │           │ └─identifier : self
        \\  │           └─number_literal : 1
        \\  └─struct_property : move
        \\    └─func
        \\      ├─signature
        \\      │ ├─param_list
        \\      │ │ └─param : self
        \\      │ │   ├─access : var
        \\      │ │   └─type : Box
        \\      │ └─type : Box
        \\      └─return_expr
        \\        └─struct_init
        \\          ├─identifier : Box
        \\          └─struct_init_field : x
        \\            └─add
        \\              ├─field_access : x
        \\              │ └─identifier : self
        \\              └─number_literal : 10
    );
}

test "parse named struct declaration through common declaration sugar" {
    try testParsing(
        \\struct Pair
        \\  left: int
        \\  right: int
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_field : left
        \\  │ └─type : int
        \\  └─struct_field : right
        \\    └─type : int
    );
}

test "parse parameterized struct declaration as a type factory" {
    try testParsing(
        \\struct Box(T: type, N: int)
        \\  value: T
        \\  count: int
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ ├─param : T
        \\  │ │ │ ├─implicit_static
        \\  │ │ │ └─type : type
        \\  │ │ └─param : N
        \\  │ │   ├─implicit_static
        \\  │ │   └─type : int
        \\  │ └─implicit_type
        \\  └─return_expr
        \\    └─struct
        \\      ├─struct_field : value
        \\      │ └─type : T
        \\      └─struct_field : count
        \\        └─type : int
    );
}

test "parse struct ownership hook indented body followed by field" {
    try testParsing(
        \\static D = struct
        \\  drop = func(deinit self: D) unit
        \\    print(99)
        \\  x: int
    ,
        \\static_binding
        \\└─struct
        \\  ├─struct_property : drop
        \\  │ └─func
        \\  │   ├─signature
        \\  │   │ ├─param_list
        \\  │   │ │ └─param : self
        \\  │   │ │   ├─access : deinit
        \\  │   │ │   └─type : D
        \\  │   │ └─type : unit
        \\  │   └─block
        \\  │     └─call
        \\  │       ├─identifier : print
        \\  │       └─call_arg_list
        \\  │         └─number_literal : 99
        \\  └─struct_field : x
        \\    └─type : int
    );
}

test "parse anonymous struct expression" {
    try testParsing(
        \\static Wrapper = func(static T: type) type
        \\  return struct
        \\    x: T
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ └─param : T
        \\  │ │   ├─access : static
        \\  │ │   └─type : type
        \\  │ └─type : type
        \\  └─block
        \\    └─return_expr
        \\      └─struct
        \\        └─struct_field : x
        \\          └─type : T
    );
}

test "parse struct init" {
    try testParsing(
        \\const p = Point{x = 3, y = 4}
    ,
        \\const_binding
        \\└─struct_init
        \\  ├─identifier : Point
        \\  ├─struct_init_field : x
        \\  │ └─number_literal : 3
        \\  └─struct_init_field : y
        \\    └─number_literal : 4
    );
}

test "parse nested struct init" {
    try testParsing(
        \\const o = Outer{inner = Inner{v = 1}, tag = 2}
    ,
        \\const_binding
        \\└─struct_init
        \\  ├─identifier : Outer
        \\  ├─struct_init_field : inner
        \\  │ └─struct_init
        \\  │   ├─identifier : Inner
        \\  │   └─struct_init_field : v
        \\  │     └─number_literal : 1
        \\  └─struct_init_field : tag
        \\    └─number_literal : 2
    );
}

test "parse struct init after call" {
    try testParsing(
        \\const val = Wrapper(float){x = 3.0}
    ,
        \\const_binding
        \\└─struct_init
        \\  ├─call
        \\  │ ├─identifier : Wrapper
        \\  │ └─call_arg_list
        \\  │   └─identifier : float
        \\  └─struct_init_field : x
        \\    └─number_literal : 3.0
    );
}

test "parse field access" {
    try testParsing(
        \\print(foo.x)
        \\const value = outer.inner.v
    ,
        \\call
        \\├─identifier : print
        \\└─call_arg_list
        \\  └─field_access : x
        \\    └─identifier : foo
        \\const_binding
        \\└─field_access : v
        \\  └─field_access : inner
        \\    └─identifier : outer
    );
}

test "parse field assignment" {
    try testParsing(
        \\p.x = val
        \\o.inner.v = p.y
    ,
        \\assign
        \\├─field_access : x
        \\│ └─identifier : p
        \\└─identifier : val
        \\assign
        \\├─field_access : v
        \\│ └─field_access : inner
        \\│   └─identifier : o
        \\└─field_access : y
        \\  └─identifier : p
    );
}

test "parse variant runtime operators" {
    try testParsing(
        \\if x is int | A -> print(1)
        \\if const i = b as int -> print(i)
    ,
        \\if
        \\├─is
        \\│ ├─identifier : x
        \\│ └─type_variant
        \\│   ├─type : int
        \\│   └─type : A
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─number_literal : 1
        \\if
        \\├─const_binding
        \\│ └─as
        \\│   ├─identifier : b
        \\│   └─type : int
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─identifier : i
    );
}

test "parse variant operator precedence" {
    try testParsing(
        \\if x is int or y is float and z is none -> print(1)
    ,
        \\if
        \\├─or
        \\│ ├─is
        \\│ │ ├─identifier : x
        \\│ │ └─type : int
        \\│ └─and
        \\│   ├─is
        \\│   │ ├─identifier : y
        \\│   │ └─type : float
        \\│   └─is
        \\│     ├─identifier : z
        \\│     └─type : none
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─number_literal : 1
    );
}

test "not binds below comparisons and above logical operators" {
    try testParsing(
        \\if not x < 1 and y > 2 or z == 3 -> print(1)
    ,
        \\if
        \\├─or
        \\│ ├─and
        \\│ │ ├─not
        \\│ │ │ └─lt
        \\│ │ │   ├─identifier : x
        \\│ │ │   └─number_literal : 1
        \\│ │ └─gt
        \\│ │   ├─identifier : y
        \\│ │   └─number_literal : 2
        \\│ └─eq
        \\│   ├─identifier : z
        \\│   └─number_literal : 3
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─number_literal : 1
    );
}

test "parse query and move postfix operators" {
    try testParsing(
        \\const a = value?
        \\const b = a^
        \\take(b^)
        \\if const v = maybe? -> print(v)
    ,
        \\const_binding
        \\└─query_op
        \\  └─identifier : value
        \\const_binding
        \\└─move_expr
        \\  └─identifier : a
        \\call
        \\├─identifier : take
        \\└─call_arg_list
        \\  └─move_expr
        \\    └─identifier : b
        \\if
        \\├─const_binding
        \\│ └─query_op
        \\│   └─identifier : maybe
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─identifier : v
    );
}

test "parse inline comptime expression" {
    try testParsing(
        \\const x = comptime -> 40 + 2
        \\print(comptime -> 1)
    ,
        \\const_binding
        \\└─comptime_expr
        \\  └─add
        \\    ├─number_literal : 40
        \\    └─number_literal : 2
        \\call
        \\├─identifier : print
        \\└─call_arg_list
        \\  └─comptime_expr
        \\    └─number_literal : 1
    );
}

test "parse block comptime expression" {
    try testParsing(
        \\const x = comptime
        \\  const a = 40
        \\  a + 2
    ,
        \\const_binding
        \\└─comptime_expr
        \\  └─block
        \\    ├─const_binding
        \\    │ └─number_literal : 40
        \\    └─add
        \\      ├─identifier : a
        \\      └─number_literal : 2
    );
}

test "parse deinit parameter mode" {
    try testParsing(
        \\static consume = func(deinit d: D) unit
        \\  print(d.x)
    ,
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list
        \\  │ │ └─param : d
        \\  │ │   ├─access : deinit
        \\  │ │   └─type : D
        \\  │ └─type : unit
        \\  └─block
        \\    └─call
        \\      ├─identifier : print
        \\      └─call_arg_list
        \\        └─field_access : x
        \\          └─identifier : d
    );
}

test "parse sizeof expression" {
    try testParsing(
        \\print(sizeof(int))
        \\print(sizeof(func(int) int))
        \\const s = sizeof(int | float)
    ,
        \\call
        \\├─identifier : print
        \\└─call_arg_list
        \\  └─sizeof_expr
        \\    └─type : int
        \\call
        \\├─identifier : print
        \\└─call_arg_list
        \\  └─sizeof_expr
        \\    └─type_func
        \\      ├─type_list
        \\      │ └─type : int
        \\      └─type : int
        \\const_binding
        \\└─sizeof_expr
        \\  └─type_variant
        \\    ├─type : int
        \\    └─type : float
    );
}

test "parse extra comparison operators" {
    try testParsing(
        \\if a <= b -> print(1)
        \\if b >= c -> print(2)
        \\if c <> d -> print(3)
    ,
        \\if
        \\├─le
        \\│ ├─identifier : a
        \\│ └─identifier : b
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─number_literal : 1
        \\if
        \\├─ge
        \\│ ├─identifier : b
        \\│ └─identifier : c
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─number_literal : 2
        \\if
        \\├─ne
        \\│ ├─identifier : c
        \\│ └─identifier : d
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list
        \\    └─number_literal : 3
    );
}

test "parse block if else" {
    try testParsing(
        \\if 3 < 4
        \\  print(11)
        \\else
        \\  print(22)
    ,
        \\if_else
        \\├─lt
        \\│ ├─number_literal : 3
        \\│ └─number_literal : 4
        \\├─block
        \\│ └─call
        \\│   ├─identifier : print
        \\│   └─call_arg_list
        \\│     └─number_literal : 11
        \\└─block
        \\  └─call
        \\    ├─identifier : print
        \\    └─call_arg_list
        \\      └─number_literal : 22
    );
}

test "parse inline if expression" {
    try testParsing(
        \\const x = if true -> 1 else 2
    ,
        \\const_binding
        \\└─if_else
        \\  ├─bool_literal : true
        \\  ├─number_literal : 1
        \\  └─number_literal : 2
    );
}

test "parse loop break and continue expressions" {
    try testParsing(
        \\var value = 0
        \\const result = loop
        \\  if value < 2 -> continue
        \\  if value > 4 -> break value
        \\  break
    ,
        \\var_binding
        \\└─number_literal : 0
        \\const_binding
        \\└─loop
        \\  └─block
        \\    ├─if
        \\    │ ├─lt
        \\    │ │ ├─identifier : value
        \\    │ │ └─number_literal : 2
        \\    │ └─continue_expr
        \\    ├─if
        \\    │ ├─gt
        \\    │ │ ├─identifier : value
        \\    │ │ └─number_literal : 4
        \\    │ └─break_expr
        \\    │   └─identifier : value
        \\    └─break_nothing
    );
}

test "parse else if chain" {
    try testParsing(
        \\if 1 < 2 -> print(1) else if 2 < 3 -> print(2) else print(3)
    ,
        \\if_else
        \\├─lt
        \\│ ├─number_literal : 1
        \\│ └─number_literal : 2
        \\├─call
        \\│ ├─identifier : print
        \\│ └─call_arg_list
        \\│   └─number_literal : 1
        \\└─if_else
        \\  ├─lt
        \\  │ ├─number_literal : 2
        \\  │ └─number_literal : 3
        \\  ├─call
        \\  │ ├─identifier : print
        \\  │ └─call_arg_list
        \\  │   └─number_literal : 2
        \\  └─call
        \\    ├─identifier : print
        \\    └─call_arg_list
        \\      └─number_literal : 3
    );
}

test "parse if condition binding" {
    try testParsing(
        \\if const v = value
        \\  print(v)
    ,
        \\if
        \\├─const_binding
        \\│ └─identifier : value
        \\└─block
        \\  └─call
        \\    ├─identifier : print
        \\    └─call_arg_list
        \\      └─identifier : v
    );
}

test "parse calls and literals" {
    try testParsing(
        \\foo()
        \\print(true)
        \\bar(false, none)
        \\baz(foo(1), bar(2, 3))
    ,
        \\call
        \\└─identifier : foo
        \\call
        \\├─identifier : print
        \\└─call_arg_list
        \\  └─bool_literal : true
        \\call
        \\├─identifier : bar
        \\└─call_arg_list
        \\  ├─bool_literal : false
        \\  └─none_literal : none
        \\call
        \\├─identifier : baz
        \\└─call_arg_list
        \\  ├─call
        \\  │ ├─identifier : foo
        \\  │ └─call_arg_list
        \\  │   └─number_literal : 1
        \\  └─call
        \\    ├─identifier : bar
        \\    └─call_arg_list
        \\      ├─number_literal : 2
        \\      └─number_literal : 3
    );
}

test "parse with precedence" {
    try testParsing(
        \\const result = -1 + 2 * -(3 - 4) / 2 == 5 or not (6 < 7 and 8 > 9)
    ,
        \\const_binding
        \\└─or
        \\  ├─eq
        \\  │ ├─add
        \\  │ │ ├─neg
        \\  │ │ │ └─number_literal : 1
        \\  │ │ └─div
        \\  │ │   ├─mul
        \\  │ │   │ ├─number_literal : 2
        \\  │ │   │ └─neg
        \\  │ │   │   └─sub
        \\  │ │   │     ├─number_literal : 3
        \\  │ │   │     └─number_literal : 4
        \\  │ │   └─number_literal : 2
        \\  │ └─number_literal : 5
        \\  └─not
        \\    └─and
        \\      ├─lt
        \\      │ ├─number_literal : 6
        \\      │ └─number_literal : 7
        \\      └─gt
        \\        ├─number_literal : 8
        \\        └─number_literal : 9
    );
}

test "parse module import" {
    try testParsing(
        \\import physics
    ,
        \\import
        \\└─identifier : physics
    );
}

test "parse nested module import" {
    try testParsing(
        \\import physics.collision
    ,
        \\import
        \\└─field_access : collision
        \\  └─identifier : physics
    );
}

test "parse selective module import" {
    try testParsing(
        \\import physics.{Body, World}
    ,
        \\selective_import
        \\├─identifier : physics
        \\├─identifier : Body
        \\└─identifier : World
    );
}

test "parse aliased module import" {
    try testParsing(
        \\import physics as phys
    ,
        \\import
        \\└─as
        \\  ├─identifier : physics
        \\  └─identifier : phys
    );
}

test "parse selective module import with alias" {
    try testParsing(
        \\import physics.{Body as PhysicsBody}
    ,
        \\selective_import
        \\├─identifier : physics
        \\└─as
        \\  ├─identifier : Body
        \\  └─identifier : PhysicsBody
    );
}

test "parse empty selective import" {
    try testParsing(
        \\import physics.{}
    ,
        \\selective_import
        \\└─identifier : physics
    );
}

test "parse public import" {
    try testParsing(
        \\pub import physics
    ,
        \\pub
        \\└─import
        \\  └─identifier : physics
    );
}

test "parse public static binding" {
    try testParsing(
        \\pub static gravity = 1
    ,
        \\pub
        \\└─static_binding
        \\  └─number_literal : 1
    );
}

test "diagnostic tag for malformed imports" {
    try testExpectDiagnosticTag(
        \\import 42
    , .{ .expected_token = .{ .expected = .identifier, .found = .number_literal } });
    try testExpectDiagnosticTag(
        \\pub 42
    , .{ .invalid_expression = .number_literal });
}

test "parse CRLF line endings" {
    try testParsing("static foo = func() int\r\n  return 1\r\n",
        \\static_binding
        \\└─func
        \\  ├─signature
        \\  │ └─type : int
        \\  └─block
        \\    └─return_expr
        \\      └─number_literal : 1
    );
    try testParsing("comptime\r\n  foo\r\n\r\n  bar\r\n",
        \\comptime_expr
        \\└─block
        \\  ├─identifier : foo
        \\  └─identifier : bar
    );
}

// Diagnostic failure cases

test "diagnostic tag for missing binding equals" {
    try testExpectDiagnosticTag(
        \\const x 1
    , .{ .expected_token = .{ .expected = .equal, .found = .number_literal } });
}

test "diagnostic tag for invalid call argument expression" {
    try testExpectDiagnosticTag(
        \\print(,)
    , .{ .invalid_expression = .comma });
}

test "diagnostic for an indented block following an inline function body" {
    const source = "func foo(static T: type, mut t: T) -> T\n  return t\n\nexit(foo(1))";
    var report = try parseReport(std.testing.allocator, 42, source);
    defer report.deinit(std.testing.allocator);

    try std.testing.expect(report.ast == null);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(structures.Diagnostic.Kind.indented_block_after_inline_body, report.diagnostics[0].kind);
    try std.testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "  return t").?)), report.diagnostics[0].span.?.start);
}

test "diagnostic for an unexpected indented block" {
    try testExpectDiagnosticTag("exit(0)\n  exit(1)", .unexpected_indented_block);
}

test "diagnostic tag for stray carriage return" {
    try testExpectDiagnosticTag(
        "exit()\r",
        .{ .expected_token = .{ .expected = .eof, .found = .invalid } },
    );
    try testExpectDiagnosticTag(
        "static f = func() int\r  return 1\r",
        .{ .expected_token = .{ .expected = .indent, .found = .invalid } },
    );
}

test "diagnostic tag for malformed struct item" {
    try testExpectDiagnosticTag(
        \\static S = struct
        \\  x int
    , .{ .expected_token = .{ .expected = .colon, .found = .identifier } });
    try testExpectDiagnosticTag(
        \\static S = struct
        \\  pub x: int
    , .{ .invalid_expression = .identifier });
}

test "diagnostic tag for dotted selective imports" {
    try testExpectDiagnosticTag(
        \\import physics.{a.b}
    , .{ .expected_token = .{ .expected = .r_brace, .found = .period } });
}

test "external functions require a name" {
    try testExpectDiagnosticTag(
        "extern func (code: int) never",
        .{ .expected_token = .{ .expected = .identifier, .found = .l_paren } },
    );
}

test "external fallible declarations require a name" {
    try testExpectDiagnosticTag(
        "extern fallible (size: int) int",
        .{ .expected_token = .{ .expected = .identifier, .found = .l_paren } },
    );
}

test "required expression failures stop at one diagnostic" {
    const cases = [_]struct {
        source: [:0]const u8,
        kind: structures.Diagnostic.Kind,
    }{
        .{ .source = "const x =", .kind = .{ .invalid_expression = .eof } },
        .{ .source = "x =", .kind = .{ .invalid_expression = .eof } },
        .{ .source = "static f = func() int ->", .kind = .{ .invalid_expression = .eof } },
        .{ .source = "if", .kind = .{ .invalid_expression = .eof } },
        .{ .source = "if true -> 1 else", .kind = .{ .invalid_expression = .eof } },
        .{ .source = "static S = struct\n  x =", .kind = .{ .invalid_expression = .dedent } },
        .{ .source = "S{ x = }", .kind = .{ .invalid_expression = .r_brace } },
    };
    for (cases) |case| {
        try testExpectDiagnosticTag(case.source, case.kind);
    }
}

test "parse report cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParseReportAllocations, .{
        "static f = func(x: int, y: int) int\n  return x + y",
        null,
    });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParseReportAllocations, .{
        "const x 1",
        .{ .expected_token = .{ .expected = .equal, .found = .number_literal } },
    });
}

fn testExpectDiagnosticTag(source: [:0]const u8, expected: structures.Diagnostic.Kind) !void {
    var parser = try parseState(std.testing.allocator, source);
    defer parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), parser.errors.items.len);
    try std.testing.expectEqual(expected, parser.errors.items[0].kind);
}

fn testParseReportAllocations(gpa: std.mem.Allocator, source: []const u8, expected_kind: ?structures.Diagnostic.Kind) !void {
    var report = try parseReport(gpa, 42, source);
    defer report.deinit(gpa);

    if (expected_kind) |kind| {
        try std.testing.expect(report.ast == null);
        try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
        try std.testing.expectEqual(@as(structures.FileId, 42), report.diagnostics[0].file_id);
        try std.testing.expectEqual(structures.SourceSpan{ .start = 8, .end = 9 }, report.diagnostics[0].span.?);
        try std.testing.expectEqual(kind, report.diagnostics[0].kind);
    } else {
        try std.testing.expect(report.ast != null);
        try std.testing.expectEqual(@as(structures.FileId, 42), report.ast.?.file_id);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    }
}

fn testParsing(source: [:0]const u8, expected: []const u8) !void {
    var parser = try parseState(std.testing.allocator, source);
    defer parser.deinit();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var ast = try parser.intoAst(0);
    defer ast.deinit(std.testing.allocator);
    try renderAst(std.testing.allocator, &ast, source, &buffer.writer);
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, buffer.writer.buffered(), "\n"));
}
