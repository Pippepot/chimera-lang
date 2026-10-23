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
    /// Parsing stops at its first error.
    failure: ?ParseDiagnostic = null,
    continuation_dedents: std.DynamicBitSetUnmanaged,
    match_arm_header: ?u32 = null,

    pub fn deinit(self: *@This()) void {
        self.gpa.free(self.tokens);
        self.nodes.deinit(self.gpa);
        self.node_refs.deinit(self.gpa);
        self.scratch_stack.deinit(self.gpa);
        self.continuation_dedents.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn intoAst(self: *@This(), file_id: structures.FileId) !Ast {
        var parsed: Ast = .{ .file_id = file_id, .tokens = self.tokens };
        self.tokens = &.{};
        errdefer parsed.deinit(self.gpa);
        parsed.nodes = try self.nodes.toOwnedSlice(self.gpa);
        parsed.node_refs = try self.node_refs.toOwnedSlice(self.gpa);
        return parsed;
    }

    pub fn addNode(self: *@This(), node: Node) !Node.Index {
        const idx: Node.Index = @fromBackingInt(@intCast(self.nodes.items.len));
        try self.nodes.append(self.gpa, node);
        return idx;
    }

    pub fn reserveNode(self: *@This()) !Node.Index {
        const index: Node.Index = @fromBackingInt(@intCast(self.nodes.items.len));
        try self.nodes.resize(self.gpa, self.nodes.items.len + 1);
        return index;
    }

    pub fn setNode(self: *@This(), i: Node.Index, node: Node) Node.Index {
        self.nodes.items[@backingInt(i)] = node;
        return i;
    }

    pub fn current(self: *@This()) Token {
        while (self.continuation_dedents.isSet(self.index)) self.index += 1;
        return self.tokens[self.index];
    }

    pub fn skipContinuationIndent(self: *@This()) void {
        while (self.current().tag == .indent) {
            self.suppressMatchingDedent(self.index);
            self.index += 1;
        }
    }

    pub fn matchingDedent(self: *@This(), indent_index: u32) u32 {
        std.debug.assert(self.tokens[indent_index].tag == .indent);
        var depth: usize = 1;
        var end = indent_index + 1;
        while (depth != 0) : (end += 1) {
            switch (self.tokens[end].tag) {
                .indent => depth += 1,
                .dedent => depth -= 1,
                else => {},
            }
        }
        return end - 1;
    }

    pub fn suppressMatchingDedent(self: *@This(), indent_index: u32) void {
        // A delimiter may close its continuation or an expression body on the
        // same line. Preserve token indexes and skip the later physical dedent.
        self.continuation_dedents.set(self.matchingDedent(indent_index));
    }

    fn lineIndent(self: *@This(), token_index: u32) usize {
        const offset = self.tokens[token_index].loc.start;
        const start = if (std.mem.lastIndexOfScalar(u8, self.source[0..offset], '\n')) |newline| newline + 1 else 0;
        var end = start;
        while (end < self.source.len and self.source[end] == ' ') end += 1;
        return end - start;
    }

    fn activeIndent(self: *@This()) ?u32 {
        var cursor = self.index;
        var depth: usize = 0;
        while (cursor != 0) {
            cursor -= 1;
            switch (self.tokens[cursor].tag) {
                .dedent => depth += 1,
                .indent => {
                    if (depth == 0) return cursor;
                    depth -= 1;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn eatBodyIndent(self: *@This(), header_index: u32) ?u32 {
        if (self.eat(.indent) != null) return self.index - 1;
        // When a delimiter closes on its final item line, the following body
        // can have the same physical indentation as that continuation. Claim
        // its existing indentation scope for the new body instead.
        if (self.lineIndent(self.index) > self.lineIndent(header_index) and self.index != 0 and self.currentStartsLine()) {
            if (self.activeIndent()) |indent| {
                const end = self.matchingDedent(indent);
                if (self.continuation_dedents.isSet(end)) {
                    self.continuation_dedents.unset(end);
                    return indent;
                }
            }
        }
        return null;
    }

    pub fn expectBodyIndent(self: *@This(), header_index: u32) !u32 {
        if (self.eatBodyIndent(header_index)) |indent| return indent;
        _ = try self.expect(.indent);
        unreachable;
    }

    pub fn eat(self: *@This(), token: Token.Tag) ?Token {
        const tok = self.current();
        if (tok.tag == token) {
            self.index += 1;
            return tok;
        }
        return null;
    }

    pub fn eatAny(self: *@This(), tokens: []const Token.Tag) ?Token {
        const tok = self.current();
        for (tokens) |token| {
            if (tok.tag == token) {
                self.index += 1;
                return tok;
            }
        }
        return null;
    }

    pub fn expect(self: *@This(), token: Token.Tag) !Token {
        if (self.eat(token)) |matched| return matched;
        return self.fail(.{ .expected_token = .{ .expected = token, .found = self.current().tag } });
    }

    pub fn listToSpan(parser: *@This(), list: []const Node.Index) !Node.Data {
        try parser.node_refs.appendSlice(parser.gpa, list);
        return .{ .ref = .{
            .start = @intCast(parser.node_refs.items.len - list.len),
            .end = @intCast(parser.node_refs.items.len),
        } };
    }

    pub fn fail(self: *@This(), kind: structures.Diagnostic.Kind) error{ParseError} {
        std.debug.assert(self.failure == null);
        self.failure = .{ .kind = kind, .token_index = self.index };
        return error.ParseError;
    }

    /// Whether a line break separates the previous token from the current one.
    pub fn currentStartsLine(self: *@This()) bool {
        const previous_end = self.tokens[self.index - 1].loc.end;
        return std.mem.indexOfScalar(u8, self.source[previous_end..self.current().loc.start], '\n') != null;
    }

    fn atMatchArmBoundary(self: *@This()) bool {
        const header = self.match_arm_header orelse return false;
        const token = self.current();
        if (self.lineIndent(self.index) > self.lineIndent(header)) return false;
        var previous = self.index;
        while (previous != 0 and (self.tokens[previous - 1].tag == .indent or self.tokens[previous - 1].tag == .dedent)) previous -= 1;
        if (previous == 0) return false;
        return std.mem.indexOfScalar(u8, self.source[self.tokens[previous - 1].loc.end..token.loc.start], '\n') != null;
    }
};

fn parseState(gpa: std.mem.Allocator, source: []const u8) !ParserState {
    // Keep tokenizer scratch before the token buffer to preserve arena reuse.
    var tokens = blk: {
        var tok = try Tokenizer.init(gpa, source);
        defer tok.deinit();
        var buffer = try std.ArrayList(Token).initCapacity(gpa, source.len / 8);
        errdefer buffer.deinit(gpa);
        while (true) {
            const token = try tok.next();
            try buffer.append(gpa, token);
            if (token.tag == .eof) break;
        }
        break :blk buffer;
    };
    errdefer tokens.deinit(gpa);

    var parser: ParserState = .{
        .gpa = gpa,
        .source = source,
        .tokens = &.{},
        .index = 0,
        .nodes = .empty,
        .node_refs = .empty,
        .scratch_stack = .empty,
        .continuation_dedents = try .initEmpty(gpa, tokens.items.len),
    };
    errdefer parser.deinit();
    parser.tokens = try tokens.toOwnedSlice(gpa);

    try parser.nodes.ensureTotalCapacity(gpa, parser.tokens.len / 2);
    try parser.node_refs.ensureTotalCapacity(gpa, parser.tokens.len / 4);

    parseDocument(&parser) catch |err| switch (err) {
        error.ParseError => {
            std.debug.assert(parser.failure != null);
            return parser;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return parser;
}

fn parseDocument(parser: *ParserState) ParseError!void {
    const root = try parseBlock(parser, null);
    for (parser.nodes.items, 0..) |node, node_index| {
        if (!node.is_converter) continue;
        var top_level = false;
        const block = parser.nodes.items[root.index()];
        for (parser.node_refs.items[block.data.ref.start..block.data.ref.end]) |declaration| {
            const outer = parser.nodes.items[declaration.index()];
            const binding = if (outer.tag == .@"pub") parser.nodes.items[outer.data.node.index()] else outer;
            if (binding.tag == .static_binding and binding.data.node_node.b.index() == node_index) top_level = true;
        }
        if (!top_level) {
            parser.index = node.token_index;
            return parser.fail(.invalid_converter);
        }
    }
    _ = try parser.expect(.eof);
}

pub fn parseEmbedded(comptime source: []const u8) Ast {
    return comptime blk: {
        @setEvalBranchQuota(100_000_000);
        const tokens = Tokenizer.tokenizeComptime(source);
        var nodes: [tokens.len * 2]Node = undefined;
        var references: [tokens.len * 4]Node.Index = undefined;
        var scratch: [tokens.len * 2]Node.Index = undefined;
        const mask_count = std.math.divCeil(usize, tokens.len, @bitSizeOf(usize)) catch unreachable;
        var dedents = std.mem.zeroes([mask_count]usize);
        var parser: ParserState = .{
            .gpa = std.heap.page_allocator,
            .source = source,
            .tokens = @constCast(tokens),
            .index = 0,
            .nodes = .initBuffer(&nodes),
            .node_refs = .initBuffer(&references),
            .scratch_stack = .initBuffer(&scratch),
            .continuation_dedents = .{ .bit_length = tokens.len, .masks = &dedents },
        };
        parseDocument(&parser) catch |err| @compileError(@errorName(err));
        const parsed_nodes = parser.nodes.items[0..parser.nodes.items.len].*;
        const parsed_references = parser.node_refs.items[0..parser.node_refs.items.len].*;
        break :blk .{
            .file_id = 0,
            .tokens = @constCast(tokens),
            .nodes = @constCast(&parsed_nodes),
            .node_refs = @constCast(&parsed_references),
        };
    };
}

pub fn parseReport(gpa: std.mem.Allocator, file_id: structures.FileId, source: []const u8) !ParseReport {
    var parser = try parseState(gpa, source);
    defer parser.deinit();
    const failure = parser.failure orelse return .{ .ast = try parser.intoAst(file_id), .diagnostics = &.{} };
    const token = parser.tokens[failure.token_index];
    const diagnostics = try gpa.alloc(structures.Diagnostic, 1);
    diagnostics[0] = .{ .file_id = file_id, .span = .{ .start = token.loc.start, .end = token.loc.end }, .kind = failure.kind };
    return .{ .ast = null, .diagnostics = diagnostics };
}

fn parseBlock(parser: *ParserState, indent_index: ?u32) ParseError!Node.Index {
    const token_index = parser.index;
    const reserved_idx = try parser.reserveNode();
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.dedent) != null) break;
        if (parser.current().tag == .eof) break;
        if (parser.current().tag == .indent) return parser.fail(.unexpected_indented_block);

        const expr = try parseExpression(parser);
        if (expr == .null) {
            if (indent_index) |indent| _ = closesIndentedBody(parser, indent);
            break;
        }

        try parser.scratch_stack.append(parser.gpa, expr);
    }
    return parser.setNode(reserved_idx, .{ .tag = .block, .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

/// A delimiter may close an enclosing list on the last line of an indented
/// body; the body then ends there and its later dedent is skipped.
fn closesIndentedBody(parser: *ParserState, indent_index: u32) bool {
    switch (parser.current().tag) {
        .comma, .r_paren, .r_bracket, .r_brace => {
            parser.suppressMatchingDedent(indent_index);
            return true;
        },
        else => return false,
    }
}

fn parseExpression(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.current().tag) {
        .keyword_comptime => try parseKeywordBody(parser, .keyword_comptime, .comptime_expr),
        .keyword_const, .keyword_var, .keyword_ref, .keyword_static => try parseBinding(parser),
        .keyword_pub => try parsePublic(parser),
        .keyword_import => try parseImport(parser),
        .keyword_func, .keyword_fallible, .keyword_extern => try parseFunction(parser),
        .keyword_converter => try parseConverter(parser),
        .keyword_overload => try parseOverload(parser),
        .keyword_return, .keyword_break => try parseReturnOrBreak(parser),
        .keyword_panic => try parsePanic(parser),
        .keyword_fail => try parseTokenNode(parser, .keyword_fail, .fail_expr),
        .keyword_continue => try parseTokenNode(parser, .keyword_continue, .continue_expr),
        .number_literal,
        .string_literal,
        .keyword_true,
        .keyword_false,
        .keyword_none,
        .keyword_if,
        .keyword_match,
        .keyword_loop,
        .keyword_for,
        .keyword_sizeof,
        .keyword_struct,
        .identifier,
        .l_paren,
        .l_bracket,
        .ellipsis2,
        .keyword_not,
        .minus,
        .caret,
        => {
            const expr = try parseExpressionPrecedence(parser, 0);
            const tag = assignmentTag(parser.current().tag) orelse return expr;
            return parseAssign(parser, expr, tag);
        },
        else => .null,
    };
}

fn parsePanic(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = parser.eat(.keyword_panic).?;
    const message = try parseSameLineExpression(parser);
    return parser.addNode(.{ .tag = .panic_expr, .token_index = token_index, .data = .{ .node = message } });
}

/// An operand is optional after keywords such as `return`; it must start on the keyword's line.
fn parseSameLineExpression(parser: *ParserState) !Node.Index {
    if (parser.currentStartsLine()) return .null;
    return parseExpression(parser);
}

fn parseBody(parser: *ParserState, header_index: u32) !Node.Index {
    if (parser.eat(.arrow) != null) return try parseRequiredExpression(parser);
    return parseBlock(parser, try parser.expectBodyIndent(header_index));
}

fn parseCallableBody(parser: *ParserState, header_index: u32) !Node.Index {
    if (parser.eat(.arrow) == null) return parseBlock(parser, try parser.expectBodyIndent(header_index));
    const expression = try parseRequiredExpression(parser);
    if (parser.current().tag == .indent) return parser.fail(.indented_block_after_inline_body);
    return switch (parser.nodes.items[expression.index()].tag) {
        .break_nothing, .break_expr, .continue_expr, .return_nothing, .return_expr, .fail_expr => expression,
        else => parser.addNode(.{
            .tag = .return_expr,
            .token_index = parser.nodes.items[expression.index()].token_index,
            .data = .{ .node = expression },
        }),
    };
}

fn parseReturnOrBreak(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const keyword = parser.eatAny(&.{ .keyword_return, .keyword_break }).?;
    const expression = try parseSameLineExpression(parser);
    const tag: Node.Tag = switch (keyword.tag) {
        .keyword_return => if (expression == .null) .return_nothing else .return_expr,
        .keyword_break => if (expression == .null) .break_nothing else .break_expr,
        else => unreachable,
    };
    return parser.addNode(.{ .tag = tag, .token_index = token_index, .data = if (expression == .null) .{ .none = {} } else .{ .node = expression } });
}

/// Parses `loop` and `comptime`, whose node wraps only the following body.
fn parseKeywordBody(parser: *ParserState, keyword: Token.Tag, tag: Node.Tag) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(keyword);
    const body = try parseBody(parser, token_index);
    return try parser.addNode(.{ .tag = tag, .token_index = token_index, .data = .{ .node = body } });
}

fn parseFor(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_for);
    const binding = try parseForBinding(parser);
    const source = try parseRequiredExpression(parser);
    const body = try parseBody(parser, token_index);
    return parser.addNode(.{ .tag = .for_loop, .token_index = token_index, .data = try parser.listToSpan(&.{ binding, source, body }) });
}

fn parseForBinding(parser: *ParserState) ParseError!Node.Index {
    const binding = try parseBindingPattern(parser, null);
    _ = try parser.expect(.keyword_in);
    return binding;
}

fn parseBindingPattern(parser: *ParserState, inherited_access: ?Token.Tag) ParseError!Node.Index {
    const mode = parser.eatAny(&.{ .keyword_const, .keyword_var, .keyword_ref });
    const access = if (mode) |token| token.tag else inherited_access;
    const token_index = parser.index;
    var pattern: Node.Index = undefined;
    if (parser.eatAny(&.{ .l_paren, .l_bracket })) |open| {
        const close: Token.Tag = if (open.tag == .l_paren) .r_paren else .r_bracket;
        const stack_top = parser.scratch_stack.items.len;
        defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
        parser.skipContinuationIndent();
        var comma = false;
        while (parser.current().tag != close) {
            const child = try parseBindingPattern(parser, access);
            try parser.scratch_stack.append(parser.gpa, child);
            parser.skipContinuationIndent();
            if (parser.eat(.comma) == null) break;
            comma = true;
            parser.skipContinuationIndent();
        }
        _ = try parser.expect(close);
        const children = parser.scratch_stack.items[stack_top..];
        pattern = if (open.tag == .l_paren and children.len == 1 and !comma)
            children[0]
        else
            try parser.addNode(.{ .tag = if (open.tag == .l_paren) .binding_tuple else .binding_sequence, .token_index = token_index, .data = try parser.listToSpan(children) });
        if (parser.eat(.colon) != null) {
            const annotation = try parseType(parser);
            pattern = try parser.addNode(.{ .tag = .binding_annotation, .token_index = token_index, .data = .{ .node_node = .{ .a = pattern, .b = annotation } } });
        }
    } else {
        _ = try parser.expect(.identifier);
        const annotation = try parseTypeAnnotation(parser);
        pattern = try parser.addNode(.{ .tag = .param, .token_index = token_index, .data = .{ .parameter = .{ .access = access, .annotation = annotation } } });
    }
    return pattern;
}

fn parseBinding(parser: *ParserState) !Node.Index {
    if (parser.current().tag == .keyword_static and parser.tokens[parser.index + 1].tag == .keyword_struct)
        return parseStruct(parser);
    const binding_keyword = parser.eatAny(&.{ .keyword_const, .keyword_var, .keyword_ref, .keyword_static }) orelse return .null;
    if (binding_keyword.tag != .keyword_static and (parser.current().tag == .l_paren or parser.current().tag == .l_bracket)) {
        const pattern = try parseBindingPattern(parser, binding_keyword.tag);
        _ = try parser.expect(.equal);
        const value = try parseRequiredExpression(parser);
        return parser.addNode(.{ .tag = .destructure_binding, .token_index = parser.nodes.items[pattern.index()].token_index, .data = .{ .node_node = .{ .a = pattern, .b = value } } });
    }
    const name = try parseDeclarationName(parser, binding_keyword.tag == .keyword_static);
    const type_annotation = try parseTypeAnnotation(parser);
    _ = try parser.expect(.equal);
    const explicit_type_value = if (type_annotation.unwrap()) |annotation| blk: {
        const node = parser.nodes.items[annotation.index()];
        const token = parser.tokens[node.token_index];
        break :blk node.tag == .type and std.mem.eql(u8, parser.source[token.loc.start..token.loc.end], "type");
    } else false;
    const value = if (binding_keyword.tag == .keyword_static and
        explicit_type_value and
        parser.current().tag != .keyword_struct)
        try parseType(parser)
    else
        try parseRequiredExpression(parser);
    const tag: Node.Tag = switch (binding_keyword.tag) {
        .keyword_const => .const_binding,
        .keyword_var => .var_binding,
        .keyword_ref => .ref_binding,
        .keyword_static => .static_binding,
        else => unreachable,
    };

    const binding = try parser.addNode(.{ .tag = tag, .token_index = name.token_index, .data = .{ .node_node = .{ .a = type_annotation, .b = value } } });
    return finishQualifiedDeclaration(parser, name, binding);
}

fn parseDeclarationName(parser: *ParserState, allow_qualified: bool) !DeclarationName {
    var name: DeclarationName = .{ .namespace = .null, .token_index = try parseMemberName(parser) };
    if (!allow_qualified or parser.eat(.period) == null) return name;

    name.namespace = try parser.addNode(.{ .tag = .identifier, .token_index = name.token_index, .data = .{ .none = {} } });
    while (true) {
        name.token_index = try parseMemberName(parser);
        if (parser.eat(.period) == null) return name;
        name.namespace = try parser.addNode(.{ .tag = .field_access, .token_index = name.token_index, .data = .{ .node = name.namespace } });
    }
}

fn isOperationName(tag: Token.Tag) bool {
    return switch (tag) {
        .plus, .minus, .asterisk, .slash, .percent, .equal_equal, .angle_bracket_left_angle_bracket_right, .angle_bracket_left, .angle_bracket_right, .angle_bracket_left_equal, .angle_bracket_right_equal, .keyword_not, .l_bracket => true,
        else => false,
    };
}

fn parseMemberName(parser: *ParserState) !u32 {
    const token_index = parser.index;
    if (isOperationName(parser.tokens[token_index].tag)) {
        parser.index += 1;
        if (parser.tokens[token_index].tag == .l_bracket) {
            _ = try parser.expect(.r_bracket);
            _ = parser.eat(.equal);
        }
    } else {
        _ = try parser.expect(.identifier);
    }
    return token_index;
}

fn parsePublic(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_pub);
    const inner = switch (parser.current().tag) {
        .keyword_const, .keyword_var, .keyword_ref, .keyword_static => try parseBinding(parser),
        .keyword_func, .keyword_fallible, .keyword_extern => try parseFunction(parser),
        .keyword_converter => try parseConverter(parser),
        .keyword_overload => try parseOverload(parser),
        .keyword_struct => try parseStruct(parser),
        .keyword_import => try parseImport(parser),
        else => return parser.fail(.{ .invalid_expression = parser.current().tag }),
    };
    return parser.addNode(.{ .tag = .@"pub", .token_index = token_index, .data = .{ .node = inner } });
}

fn parseImport(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_import);
    var target = try parseTokenNode(parser, .identifier, .identifier);
    while (parser.current().tag == .period and parser.tokens[parser.index + 1].tag != .l_brace)
        target = try parseFieldAccess(parser, target);
    const aliased = parser.current().tag == .keyword_as;
    target = try parseImportAlias(parser, target);
    const selective = !aliased and parser.eat(.period) != null;
    const data = if (selective)
        try parseDelimitedList(parser, .l_brace, .r_brace, &.{target}, parseImportName, .{})
    else
        try parser.listToSpan(&.{target});
    return parser.addNode(.{ .tag = if (selective) .selective_import else .import, .token_index = token_index, .data = data });
}

fn parseImportName(parser: *ParserState) !Node.Index {
    return parseImportAlias(parser, try parseTokenNode(parser, .identifier, .identifier));
}

fn parseImportAlias(parser: *ParserState, target: Node.Index) !Node.Index {
    if (parser.eat(.keyword_as) == null) return target;
    const as_index = parser.index - 1;
    const alias = try parseTokenNode(parser, .identifier, .identifier);
    return parser.addNode(.{ .tag = .as, .token_index = as_index, .data = .{ .node_node = .{ .a = target, .b = alias } } });
}

fn parseAssign(parser: *ParserState, target: Node.Index, tag: Node.Tag) !Node.Index {
    const token_index = parser.index;
    parser.index += 1;
    const value = try parseRequiredExpression(parser);
    return try parser.addNode(.{ .tag = tag, .token_index = token_index, .data = .{ .node_node = .{ .a = target, .b = value } } });
}

fn assignmentTag(token: Token.Tag) ?Node.Tag {
    return switch (token) {
        .equal => .assign,
        .plus_equal => .add_assign,
        .minus_equal => .sub_assign,
        .asterisk_equal => .mul_assign,
        .slash_equal => .div_assign,
        .percent_equal => .rem_assign,
        else => null,
    };
}

fn parseIfExpr(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_if);

    const condition = try parseRequiredExpression(parser);
    const then_body = try parseBody(parser, token_index);
    if (parser.eat(.keyword_else) != null) {
        const else_body = if (parser.eat(.indent) != null) try parseBlock(parser, parser.index - 1) else try parseRequiredExpression(parser);
        return parser.addNode(.{ .tag = .if_else, .token_index = token_index, .data = try parser.listToSpan(&.{ condition, then_body, else_body }) });
    }
    return try parser.addNode(.{ .tag = .@"if", .token_index = token_index, .data = .{ .node_node = .{ .a = condition, .b = then_body } } });
}

fn parseMatchExpr(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_match);
    const subject = try parseRequiredExpression(parser);
    const indent = try parser.expectBodyIndent(token_index);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    try parser.scratch_stack.append(parser.gpa, subject);
    while (parser.eat(.dedent) == null and parser.current().tag != .eof) {
        if (closesIndentedBody(parser, indent)) break;
        const arm_index = parser.index;
        var pattern = try parseMatchPattern(parser);
        if (parser.eat(.keyword_and) != null) {
            pattern = try parser.addNode(.{ .tag = .match_guard, .token_index = arm_index, .data = .{ .node_node = .{ .a = pattern, .b = try parseRequiredExpression(parser) } } });
        }
        _ = try parser.expect(.arrow);
        const body = try parseMatchArmBody(parser, arm_index);
        try parser.scratch_stack.append(parser.gpa, try parser.addNode(.{
            .tag = .match_arm,
            .token_index = arm_index,
            .data = .{ .node_node = .{ .a = pattern, .b = body } },
        }));
    }
    if (parser.scratch_stack.items.len == stack_top + 1) return parser.fail(.match_requires_arm);
    return parser.addNode(.{ .tag = .match_expr, .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseMatchArmBody(parser: *ParserState, header: u32) ParseError!Node.Index {
    const parent = parser.match_arm_header;
    parser.match_arm_header = header;
    defer parser.match_arm_header = parent;
    if (parser.current().tag == .indent) return parseBlock(parser, try parser.expectBodyIndent(header));
    if (parser.atMatchArmBoundary()) return parser.fail(.{ .invalid_expression = parser.current().tag });
    return parseRequiredExpression(parser);
}

fn parseMatchCapture(parser: *ParserState) ParseError!Node.Index {
    const mode = parser.eatAny(&.{ .keyword_ref, .keyword_var });
    if (mode != null and mode.?.tag == .keyword_var) return parser.fail(.match_capture_must_be_immutable);
    const name_index = parser.index;
    _ = try parser.expect(.identifier);
    return parser.addNode(.{ .tag = .param, .token_index = name_index, .data = .{ .parameter = .{ .access = if (mode) |token| token.tag else null } } });
}

fn parseMatchPattern(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    var pattern = switch (parser.current().tag) {
        .keyword_is => type_pattern: {
            parser.index += 1;
            break :type_pattern try parser.addNode(.{ .tag = .match_type, .token_index = token_index, .data = .{ .node = try parseType(parser) } });
        },
        .identifier, .keyword_ref, .keyword_var => try parseMatchCapture(parser),
        .number_literal => try parseTokenNode(parser, .number_literal, .number_literal),
        .string_literal => try parseTokenNode(parser, .string_literal, .string_literal),
        .keyword_true, .keyword_false => literal: {
            parser.index += 1;
            break :literal try parser.addNode(.{ .tag = .bool_literal, .token_index = token_index, .data = .{ .none = {} } });
        },
        .keyword_none => try parseTokenNode(parser, .keyword_none, .none_literal),
        .minus => negative: {
            parser.index += 1;
            const number = try parseTokenNode(parser, .number_literal, .number_literal);
            break :negative try parser.addNode(.{ .tag = .neg, .token_index = token_index, .data = .{ .node = number } });
        },
        .l_paren => try parseMatchTuple(parser),
        else => return parser.fail(.{ .invalid_expression = parser.current().tag }),
    };
    if (parser.eat(.keyword_as) != null) {
        if (parser.nodes.items[pattern.index()].tag == .match_tuple) return parser.fail(.{ .unsupported_syntax = .keyword_as });
        const capture = try parseMatchCapture(parser);
        if (parser.nodes.items[pattern.index()].tag == .param) {
            const token = parser.tokens[parser.nodes.items[pattern.index()].token_index];
            if (!std.mem.eql(u8, parser.source[token.loc.start..token.loc.end], "_"))
                return parser.fail(.match_multiple_captures);
        }
        pattern = try parser.addNode(.{ .tag = .match_capture, .token_index = token_index, .data = .{ .node_node = .{ .a = pattern, .b = capture } } });
    }
    if (parser.current().tag == .keyword_as) return parser.fail(.match_multiple_captures);
    return pattern;
}

fn parseMatchTuple(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_paren);
    if (parser.eat(.r_paren) != null)
        return parser.addNode(.{ .tag = .unit_literal, .token_index = token_index, .data = .{ .none = {} } });
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    var comma = false;
    while (true) {
        parser.skipContinuationIndent();
        try parser.scratch_stack.append(parser.gpa, try parseMatchPattern(parser));
        parser.skipContinuationIndent();
        if (parser.eat(.comma) == null) break;
        comma = true;
        parser.skipContinuationIndent();
        if (parser.current().tag == .r_paren) break;
    }
    _ = try parser.expect(.r_paren);
    const children = parser.scratch_stack.items[stack_top..];
    if (children.len == 1 and !comma) return children[0];
    return parser.addNode(.{ .tag = .match_tuple, .token_index = token_index, .data = try parser.listToSpan(children) });
}

fn parseFunction(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const external = parser.eat(.keyword_extern) != null;
    // Only `extern` can reach here without a function keyword.
    if (parser.eatAny(&.{ .keyword_func, .keyword_fallible }) == null) _ = try parser.expect(.keyword_func);
    const name: ?DeclarationName = if (external or parser.current().tag == .identifier or isOperationName(parser.current().tag))
        try parseDeclarationName(parser, true)
    else
        null;
    const signature = try parseFuncSignature(parser);
    const body = if (external) Node.Index.null else try parseCallableBody(parser, token_index);
    const value = try parser.addNode(.{ .tag = .func, .token_index = token_index, .data = .{ .node_node = .{ .a = signature, .b = body } } });
    const declared_name = name orelse return value;
    const declaration = try finishNamedDeclaration(parser, declared_name.token_index, value);
    return finishQualifiedDeclaration(parser, declared_name, declaration);
}

fn parseOverload(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_overload);
    const name = try parseDeclarationName(parser, true);
    const candidates = try parseDelimitedList(parser, .l_paren, .r_paren, &.{}, parseExpressionPrecedence, .{@as(u8, 0)});
    if (candidates.ref.start == candidates.ref.end) return parser.fail(.empty_overload);
    const value = try parser.addNode(.{ .tag = .overload, .token_index = token_index, .data = candidates });
    const declaration = try finishNamedDeclaration(parser, name.token_index, value);
    return finishQualifiedDeclaration(parser, name, declaration);
}

fn parseConverter(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_converter);
    const signature = try parseFuncSignature(parser);
    const body = try parseCallableBody(parser, token_index);
    const function = try parser.addNode(.{
        .tag = .func,
        .token_index = token_index,
        .data = .{ .node_node = .{ .a = signature, .b = body } },
        .is_converter = true,
    });
    return finishNamedDeclaration(parser, token_index, function);
}

fn parseFuncSignature(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const params = try parseParenthesizedList(parser, .param_list, parseParameter, .{false});
    const return_type: Node.Index = switch (parser.current().tag) {
        .identifier, .keyword_func, .keyword_fallible, .keyword_none, .keyword_ref, .l_paren => try parseType(parser),
        else => .null,
    };
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
        .return_type = return_type,
        .where_clauses = clauses,
    } } });
}

/// A parenthesized list node, or null when the list is empty.
fn parseParenthesizedList(parser: *ParserState, tag: Node.Tag, comptime parse_item: anytype, arguments: anytype) ParseError!Node.Index {
    const token_index = parser.index;
    const data = try parseDelimitedList(parser, .l_paren, .r_paren, &.{}, parse_item, arguments);
    if (data.ref.start == data.ref.end) return .null;
    return parser.addNode(.{ .tag = tag, .token_index = token_index, .data = data });
}

fn parseParameter(parser: *ParserState, parameters_are_static: bool) ParseError!Node.Index {
    const opt_access = if (parameters_are_static) null else parser.eatAny(&.{ .keyword_imm, .keyword_ref, .keyword_mut, .keyword_var, .keyword_deinit, .keyword_init, .keyword_static });
    _ = try parser.expect(.identifier);
    const identifier_index = parser.index - 1;
    const type_annotation = try parseTypeAnnotation(parser);
    const access: ?Token.Tag = if (parameters_are_static) .keyword_static else if (opt_access) |token| token.tag else null;
    return parser.addNode(.{ .tag = .param, .token_index = identifier_index, .data = .{ .parameter = .{ .access = access, .annotation = type_annotation } } });
}

fn parseTypeAnnotation(parser: *ParserState) !Node.Index {
    if (parser.eat(.colon) != null) return try parseType(parser);
    return .null;
}

fn parseType(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    const first = try parseTypePrimary(parser);
    if (parser.current().tag != .pipe) return first;
    return parseVariantMembers(parser, token_index, first, true);
}

/// Parses the `|`-separated members that follow the first member of a variant.
fn parseVariantMembers(parser: *ParserState, token_index: u32, first: Node.Index, comptime is_type: bool) ParseError!Node.Index {
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    try parser.scratch_stack.append(parser.gpa, first);
    while (parser.eat(.pipe) != null) {
        const member = if (is_type) try parseTypePrimary(parser) else try parseExpressionPrecedence(parser, 1);
        try parser.scratch_stack.append(parser.gpa, member);
    }
    return addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .type_variant);
}

fn parseTypePrimary(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.current().tag) {
        .identifier => blk: {
            const is_call = parser.tokens[parser.index + 1].tag == .l_paren or parser.tokens[parser.index + 1].tag == .question_mark;
            var value = try parseTokenNode(parser, .identifier, if (is_call) .identifier else .type);
            while (parser.current().tag == .period) value = try parseFieldAccess(parser, value);
            if (parser.current().tag == .l_paren or parser.current().tag == .question_mark)
                value = try parseCall(parser, value);
            break :blk value;
        },
        .keyword_none => try parseTokenNode(parser, .keyword_none, .type),
        .keyword_ref => try parseReferenceType(parser),
        .keyword_func, .keyword_fallible => try parseFunctionType(parser),
        .l_paren => try parseParenthesized(parser, true),
        else => return parser.fail(.{ .invalid_expression = parser.current().tag }),
    };
}

fn parseFunctionType(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = parser.eatAny(&.{ .keyword_func, .keyword_fallible }).?;
    const params = try parseParenthesizedList(parser, .type_list, parseTypeParameter, .{});
    const return_type = try parseType(parser);
    return parser.addNode(.{ .tag = .type_func, .token_index = token_index, .data = .{ .node_node = .{ .a = params, .b = return_type } } });
}

fn parseReferenceType(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_ref);
    const type_annotation = try parseTypePrimary(parser);
    return parser.addNode(.{ .tag = .reference_type, .token_index = token_index, .data = .{ .node = type_annotation } });
}

fn parseParenthesized(parser: *ParserState, comptime is_type: bool) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_paren);
    parser.skipContinuationIndent();
    if (parser.eat(.r_paren) != null)
        return parser.addNode(.{ .tag = .unit_literal, .token_index = token_index, .data = .{ .none = {} } });
    const first = if (is_type) try parseType(parser) else try parseExpressionPrecedence(parser, 0);
    parser.skipContinuationIndent();
    if (parser.eat(.comma) == null) {
        _ = try parser.expect(.r_paren);
        return first;
    }
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    try parser.scratch_stack.append(parser.gpa, first);
    parser.skipContinuationIndent();
    while (parser.current().tag != .r_paren) {
        parser.skipContinuationIndent();
        const member = if (is_type) try parseType(parser) else try parseExpressionPrecedence(parser, 0);
        try parser.scratch_stack.append(parser.gpa, member);
        parser.skipContinuationIndent();
        if (parser.eat(.comma) == null) break;
        parser.skipContinuationIndent();
        if (parser.current().tag == .r_paren) break;
    }
    _ = try parser.expect(.r_paren);
    return addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], if (is_type) .type_tuple else .tuple_literal);
}

fn parseTypeParameter(parser: *ParserState) ParseError!Node.Index {
    const access_token_index = parser.index;
    const access = parser.eatAny(&.{ .keyword_imm, .keyword_ref, .keyword_mut, .keyword_var, .keyword_deinit, .keyword_init });
    const ty = try parseType(parser);
    if (access == null) return ty;
    return parser.addNode(.{ .tag = .param, .token_index = access_token_index, .data = .{ .parameter = .{ .access = access.?.tag, .annotation = ty } } });
}

const BinaryOpInfo = struct {
    tag: Node.Tag,
    precedence: u8,
};

fn binaryOpInfo(token: Token.Tag) ?BinaryOpInfo {
    return switch (token) {
        .keyword_or => .{ .tag = .@"or", .precedence = 1 },
        .keyword_and => .{ .tag = .@"and", .precedence = 2 },
        .equal_equal => .{ .tag = .eq, .precedence = 3 },
        .angle_bracket_left_angle_bracket_right => .{ .tag = .ne, .precedence = 3 },
        .angle_bracket_left => .{ .tag = .lt, .precedence = 3 },
        .angle_bracket_right => .{ .tag = .gt, .precedence = 3 },
        .angle_bracket_left_equal => .{ .tag = .le, .precedence = 3 },
        .angle_bracket_right_equal => .{ .tag = .ge, .precedence = 3 },
        .keyword_is => .{ .tag = .is, .precedence = 3 },
        .keyword_as => .{ .tag = .as, .precedence = 3 },
        .ellipsis2 => .{ .tag = .range, .precedence = 4 },
        .plus => .{ .tag = .add, .precedence = 5 },
        .minus => .{ .tag = .sub, .precedence = 5 },
        .asterisk => .{ .tag = .mul, .precedence = 6 },
        .slash => .{ .tag = .div, .precedence = 6 },
        .percent => .{ .tag = .rem, .precedence = 6 },
        else => null,
    };
}

fn parseExpressionPrecedence(parser: *ParserState, min_precedence: u8) ParseError!Node.Index {
    const token_index = parser.index;
    var lhs = if (parser.current().tag == .ellipsis2 and min_precedence <= 4)
        try parseRange(parser, null)
    else
        try parseUnary(parser);

    while (binaryOpInfo(parser.current().tag)) |op_info| {
        if (parser.atMatchArmBoundary()) break;
        if (op_info.precedence < min_precedence) break;
        if (op_info.tag == .range) {
            lhs = try parseRange(parser, lhs);
            continue;
        }

        const operator_index = parser.index;
        parser.index += 1;
        const rhs = switch (op_info.tag) {
            .is, .as => try parseType(parser),
            else => try parseExpressionPrecedence(parser, op_info.precedence + 1),
        };
        lhs = try parser.addNode(.{ .tag = op_info.tag, .token_index = operator_index, .data = .{ .node_node = .{ .a = lhs, .b = rhs } } });
    }

    if (min_precedence == 0 and parser.current().tag == .pipe and !parser.atMatchArmBoundary()) return parseVariantMembers(parser, token_index, lhs, false);
    return lhs;
}

fn parseRange(parser: *ParserState, first: ?Node.Index) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.ellipsis2);
    const inclusive = parser.eat(.equal) != null;
    const start = first orelse try parser.addNode(.{ .tag = .none_literal, .token_index = token_index, .data = .{ .none = {} } });
    const omitted = parser.currentStartsLine() or switch (parser.current().tag) {
        .number_literal,
        .string_literal,
        .identifier,
        .keyword_true,
        .keyword_false,
        .keyword_none,
        .keyword_not,
        .keyword_panic,
        .keyword_if,
        .keyword_loop,
        .keyword_for,
        .keyword_comptime,
        .keyword_sizeof,
        .keyword_struct,
        .keyword_func,
        .keyword_fallible,
        .keyword_static,
        .l_paren,
        .l_bracket,
        .minus,
        .caret,
        => false,
        else => true,
    };
    if (omitted and inclusive) return parser.fail(.{ .invalid_expression = parser.current().tag });
    const limit = if (omitted and !inclusive)
        try parser.addNode(.{ .tag = .none_literal, .token_index = token_index, .data = .{ .none = {} } })
    else
        try parseExpressionPrecedence(parser, 5);
    return parser.addNode(.{ .tag = if (inclusive) .range_inclusive else .range, .token_index = token_index, .data = .{ .node_node = .{ .a = start, .b = limit } } });
}

fn parseUnary(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    return switch (parser.current().tag) {
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
        .caret => {
            parser.index += 1;
            const operand = try parseUnary(parser);
            return parser.addNode(.{ .tag = .from_end, .token_index = token_index, .data = .{ .node = operand } });
        },
        else => parsePostfix(parser),
    };
}

fn parsePostfix(parser: *ParserState) ParseError!Node.Index {
    var lhs = try parsePrimary(parser);

    while (true) {
        if (parser.atMatchArmBoundary()) break;
        switch (parser.current().tag) {
            .l_paren => lhs = try parseCall(parser, lhs),
            .question_mark => lhs = if (parser.tokens[parser.index + 1].tag == .l_paren)
                try parseCall(parser, lhs)
            else
                try parsePostfixNode(parser, lhs, .query),
            .l_brace => lhs = try parseStructInit(parser, lhs),
            .l_bracket => {
                const token_index = parser.index;
                parser.index += 1;
                parser.skipContinuationIndent();
                const index = try parseRequiredExpression(parser);
                parser.skipContinuationIndent();
                _ = try parser.expect(.r_bracket);
                lhs = try parser.addNode(.{ .tag = .index_access, .token_index = token_index, .data = .{ .node_node = .{ .a = lhs, .b = index } } });
            },
            .period => lhs = try parseFieldAccess(parser, lhs),
            .caret => lhs = try parsePostfixNode(parser, lhs, .move_expr),
            else => break,
        }
    }

    return lhs;
}

fn parseCall(parser: *ParserState, callee: Node.Index) ParseError!Node.Index {
    const token_index = parser.index;
    _ = parser.eat(.question_mark);
    const arguments = try parseParenthesizedList(parser, .call_arg_list, parseExpressionPrecedence, .{@as(u8, 0)});
    return parser.addNode(.{ .tag = .call, .token_index = token_index, .data = .{ .node_node = .{ .a = callee, .b = arguments } } });
}

fn parsePrimary(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.current().tag) {
        .number_literal => try parseTokenNode(parser, .number_literal, .number_literal),
        .string_literal => try parseTokenNode(parser, .string_literal, .string_literal),
        .keyword_true => try parseTokenNode(parser, .keyword_true, .bool_literal),
        .keyword_false => try parseTokenNode(parser, .keyword_false, .bool_literal),
        .keyword_none => try parseTokenNode(parser, .keyword_none, .none_literal),
        .keyword_panic => try parsePanic(parser),
        .keyword_ref => try parseReferenceType(parser),
        .keyword_if => try parseIfExpr(parser),
        .keyword_match => try parseMatchExpr(parser),
        .keyword_loop => try parseKeywordBody(parser, .keyword_loop, .loop),
        .keyword_for => try parseFor(parser),
        .keyword_comptime => try parseKeywordBody(parser, .keyword_comptime, .comptime_expr),
        .keyword_sizeof => try parseSizeof(parser),
        .keyword_struct => try parseStruct(parser),
        .keyword_func, .keyword_fallible => try parseFunctionType(parser),
        .keyword_static => try parseStruct(parser),
        .identifier => try parseTokenNode(parser, .identifier, .identifier),
        .l_bracket => try parseCollectionLiteral(parser),
        .l_paren => return parseParenthesized(parser, false),
        else => return parser.fail(.{ .invalid_expression = parser.current().tag }),
    };
}

fn parseCollectionLiteral(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    const data = try parseDelimitedList(parser, .l_bracket, .r_bracket, &.{}, parseCollectionItem, .{});
    return parser.addNode(.{ .tag = .collection_literal, .token_index = token_index, .data = data });
}

fn parseCollectionItem(parser: *ParserState) ParseError!Node.Index {
    const start = parser.index;
    const spread = parser.eat(.ellipsis2) != null;
    var item = try parseExpressionPrecedence(parser, 0);
    if (spread) item = try parser.addNode(.{ .tag = .collection_spread, .token_index = start, .data = .{ .node = item } });
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    while (true) {
        parser.skipContinuationIndent();
        const token_index = parser.index;
        const is_static = parser.eat(.keyword_static) != null;
        if (parser.eat(.keyword_for) != null) {
            const binding = try parseForBinding(parser);
            const source = try parseExpressionPrecedence(parser, 0);
            const clause = try parser.addNode(.{ .tag = .collection_for, .token_index = token_index, .data = try parser.listToSpan(&.{ binding, source, .null }) });
            try parser.scratch_stack.append(parser.gpa, clause);
        } else if (parser.eat(.keyword_if) != null) {
            const condition = try parseExpressionPrecedence(parser, 0);
            const clause = try parser.addNode(.{ .tag = .collection_if, .token_index = token_index, .data = .{ .node_node = .{ .a = condition, .b = .null } } });
            try parser.scratch_stack.append(parser.gpa, clause);
        } else {
            if (is_static) {
                _ = try parser.expect(.keyword_for);
                unreachable;
            }
            break;
        }
    }
    var end = parser.scratch_stack.items.len;
    while (end > stack_top) {
        end -= 1;
        const clause = parser.scratch_stack.items[end];
        const node = &parser.nodes.items[clause.index()];
        switch (node.tag) {
            .collection_for => parser.node_refs.items[node.data.ref.end - 1] = item,
            .collection_if => node.data.node_node.b = item,
            else => unreachable,
        }
        item = clause;
    }
    return item;
}

/// Freeze each list before releasing its scratch range; nested lists share the
/// stack while retaining their own delimiter and continuation handling.
fn parseDelimitedList(parser: *ParserState, opening: Token.Tag, closing: Token.Tag, prefix: []const Node.Index, comptime parse_item: anytype, arguments: anytype) ParseError!Node.Data {
    const argument_types = comptime @typeInfo(@TypeOf(arguments)).@"struct".field_types;
    const ItemArguments = @Tuple(&([_]type{*ParserState} ++ argument_types[0..argument_types.len].*));
    _ = try parser.expect(opening);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);
    try parser.scratch_stack.appendSlice(parser.gpa, prefix);
    while (true) {
        parser.skipContinuationIndent();
        if (parser.eat(closing) != null) break;
        var item_arguments: ItemArguments = undefined;
        item_arguments[0] = parser;
        inline for (arguments, 1..) |argument, index| item_arguments[index] = argument;
        const item = try @call(.auto, parse_item, item_arguments);
        try parser.scratch_stack.append(parser.gpa, item);
        parser.skipContinuationIndent();
        if (parser.eat(.comma) != null) continue;
        _ = try parser.expect(closing);
        break;
    }
    return parser.listToSpan(parser.scratch_stack.items[stack_top..]);
}

fn parseStruct(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    const is_static = parser.eat(.keyword_static) != null;
    _ = try parser.expect(.keyword_struct);
    const name_token_index: ?u32 = if (!parser.currentStartsLine() and parser.eat(.identifier) != null) parser.index - 1 else null;
    if (name_token_index != null and parser.current().tag == .l_paren) {
        const parameters = try parseParenthesizedList(parser, .param_list, parseParameter, .{true});
        const value = try parseStructValue(parser, token_index, is_static);
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
    const value = try parseStructValue(parser, token_index, is_static);
    return finishNamedDeclaration(parser, name_token_index, value);
}

fn parseStructValue(parser: *ParserState, token_index: u32, is_static: bool) ParseError!Node.Index {
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    if (parser.eatBodyIndent(token_index)) |indent_index| {
        while (true) {
            if (parser.eat(.dedent) != null) break;
            if (parser.current().tag == .eof) break;
            if (closesIndentedBody(parser, indent_index)) break;

            const item = try parseStructItem(parser);
            try parser.scratch_stack.append(parser.gpa, item);
        }
    }

    return parser.addNode(.{ .tag = .@"struct", .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]), .is_static_struct = is_static });
}

fn parseStructItem(parser: *ParserState) ParseError!Node.Index {
    const tag = parser.current().tag;
    const next = parser.tokens[parser.index + 1].tag;
    switch (tag) {
        .keyword_converter => return parser.fail(.invalid_converter),
        .keyword_ref => return parseStructField(parser),
        .keyword_const, .keyword_var, .keyword_static => return parseBinding(parser),
        .keyword_func, .keyword_fallible, .keyword_struct, .keyword_overload => return parseExpression(parser),
        .keyword_pub => {
            if (next != .keyword_ref and (next != .identifier or parser.tokens[parser.index + 2].tag != .colon))
                return parsePublic(parser);
            const token_index = parser.index;
            parser.index += 1;
            const field = try parseStructField(parser);
            return parser.addNode(.{ .tag = .@"pub", .token_index = token_index, .data = .{ .node = field } });
        },
        else => return if (next == .equal) parseStructProperty(parser) else parseStructField(parser),
    }
}

fn parseStructField(parser: *ParserState) ParseError!Node.Index {
    const kind: structures.MemberKind = if (parser.eat(.keyword_ref) != null) .reference else .owned;
    const identifier_index = parser.index;
    _ = try parser.expect(.identifier);
    _ = try parser.expect(.colon);
    const field_type = try parseType(parser);
    return try parser.addNode(.{ .tag = .struct_field, .token_index = identifier_index, .data = .{ .field = .{ .type_annotation = field_type, .kind = kind } } });
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
    const data = try parseDelimitedList(parser, .l_brace, .r_brace, &.{target}, parseStructInitField, .{});
    return parser.addNode(.{ .tag = .struct_init, .token_index = token_index, .data = data });
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
    const field_index = if (parser.current().tag == .number_literal) numeric: {
        const index = parser.index;
        parser.index += 1;
        break :numeric index;
    } else try parseMemberName(parser);
    return try parser.addNode(.{ .tag = .field_access, .token_index = field_index, .data = .{ .node = target } });
}

fn parseSizeof(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_sizeof);
    _ = try parser.expect(.l_paren);
    parser.skipContinuationIndent();
    const ty = try parseType(parser);
    parser.skipContinuationIndent();
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
    return parser.fail(.{ .invalid_expression = parser.current().tag });
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
        .bool_literal, .identifier, .none_literal, .type, .number_literal, .string_literal, .field_access, .struct_field, .struct_property, .struct_init_field, .param => {
            const loc = ast.tokens[node.token_index].loc;
            try writer.print(" : {s}", .{source[loc.start..loc.end]});
        },
        .unit_literal => try writer.writeAll(" : ()"),
        else => if (node.dataTag() == null) try writer.print("Not implemented {}", .{node.tag}),
    }
    if (node.tag == .param) if (node.data.parameter.access) |access|
        try writer.print(" ({s})", .{Token.spelling(access).?});
    try writer.writeByte('\n');
    var children = node.children(ast.node_refs);
    const nodes = children.slice();
    var end = nodes.len;
    while (end > 0 and nodes[end - 1] == .null) end -= 1;
    for (nodes[0..end], 0..) |child, index| {
        if (child.unwrap()) |present| try renderNode(gpa, present, ast, source, writer, seen, new_indent, index == end - 1, false);
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

test "parse explicit multiline overload declarations with trailing commas" {
    try testParsing(
        \\pub overload [](
        \\    get,
        \\    slice,
        \\)
    ,
        \\pub
        \\└─static_binding
        \\  └─overload
        \\    ├─identifier : get
        \\    └─identifier : slice
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
        \\    │ │ └─param : self (imm)
        \\    │ │   └─type : S
        \\    │ └─type : int
        \\    └─return_expr
        \\      └─field_access : i
        \\        └─identifier : self
    );
}

test "parse operation function declarations and explicit calls" {
    for ([_][]const u8{ "+", "-", "*", "/", "%", "==", "<>", "<", ">", "<=", ">=", "not", "[]", "[]=" }) |name| {
        const source = try std.testing.allocator.print("func S.{s}(left: int, right: int) int -> left\nS.{s}(1, 2)", .{ name, name });
        defer std.testing.allocator.free(source);
        var report = try parseReport(std.testing.allocator, 0, source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
        try std.testing.expect(report.ast != null);
    }
}

test "parse nested struct bodies inside multiline calls" {
    var report = try parseReport(std.testing.allocator, 0,
        \\const result = choose(
        \\    struct
        \\        value: int)
        \\exit(result)
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    try std.testing.expect(report.ast != null);
    const statements = report.ast.?.nodes[0].data.ref;
    try std.testing.expectEqual(@as(u32, 2), statements.end - statements.start);
}

test "parse string literals and indexed children preserve AST equality and rendering" {
    try testParsing(
        \\const text = "hi"
        \\const item = values[1]
    ,
        \\const_binding
        \\└─string_literal : "hi"
        \\const_binding
        \\└─index_access
        \\  ├─identifier : values
        \\  └─number_literal : 1
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

test "parse range endpoints after arithmetic" {
    try testParsing(
        \\const values = first + 1..last * 2
    ,
        \\const_binding
        \\└─range
        \\  ├─add
        \\  │ ├─identifier : first
        \\  │ └─number_literal : 1
        \\  └─mul
        \\    ├─identifier : last
        \\    └─number_literal : 2
    );
}

test "parse range inclusive endpoints and transferred endpoints" {
    try testParsing(
        \\const values = first^..=last
    ,
        \\const_binding
        \\└─range_inclusive
        \\  ├─move_expr
        \\  │ └─identifier : first
        \\  └─identifier : last
    );
}

test "parse range end relative endpoints independently of inclusivity and transfer" {
    try testParsing(
        \\const values = first^..=^last
        \\const prefix = ..^5
    ,
        \\const_binding
        \\└─range_inclusive
        \\  ├─move_expr
        \\  │ └─identifier : first
        \\  └─from_end
        \\    └─identifier : last
        \\const_binding
        \\└─range
        \\  ├─none_literal : ..
        \\  └─from_end
        \\    └─number_literal : 5
    );
}

test "parse for binding modes annotations and inline bodies" {
    for ([_][]const u8{ "value", "value: int", "const value", "var value: int", "ref value: int", "_" }) |binding| {
        const source = try std.testing.allocator.print("for {s} in 0..=3 -> use(value)", .{binding});
        defer std.testing.allocator.free(source);
        var report = try parseReport(std.testing.allocator, 0, source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
        const ast = report.ast.?;
        const loop_node = ast.nodes[ast.node_refs[ast.nodes[0].data.ref.start].index()];
        try std.testing.expectEqual(Node.Tag.for_loop, loop_node.tag);
        try std.testing.expectEqual(@as(usize, 3), ast.nodeList(ast.node_refs[ast.nodes[0].data.ref.start]).len);
    }
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

test "parse bare fail" {
    const source =
        \\fallible reject() int
        \\  fail
        \\  return 1
    ;
    var report = try parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    const parsed = report.ast.?;
    const binding = parsed.nodes[parsed.node_refs[parsed.nodes[0].data.ref.start].index()];
    const function = parsed.nodes[binding.data.node_node.b.index()];
    const body = parsed.nodes[function.data.node_node.b.index()];
    try std.testing.expectEqual(Node.Tag.block, body.tag);
    try std.testing.expectEqual(@as(u32, 2), body.data.ref.end - body.data.ref.start);
    const failure = parsed.nodes[parsed.node_refs[body.data.ref.start].index()];
    try std.testing.expectEqual(Node.Tag.fail_expr, failure.tag);
    try std.testing.expectEqual(Token.Tag.keyword_fail, parsed.tokens[failure.token_index].tag);
    try std.testing.expectEqual(Node.Tag.return_expr, parsed.nodes[parsed.node_refs[body.data.ref.start + 1].index()].tag);
    try std.testing.expect(Ast.eql(parsed, parsed));
}

test "parse inline bare fail before another declaration" {
    const source =
        \\fallible reject() int -> fail
        \\func value() int -> 1
    ;
    var report = try parseReport(std.testing.allocator, 1, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    const parsed = report.ast.?;
    const root = parsed.nodes[0];
    try std.testing.expectEqual(@as(u32, 2), root.data.ref.end - root.data.ref.start);
    const binding = parsed.nodes[parsed.node_refs[root.data.ref.start].index()];
    const function = parsed.nodes[binding.data.node_node.b.index()];
    try std.testing.expectEqual(Node.Tag.fail_expr, parsed.nodes[function.data.node_node.b.index()].tag);
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
        \\  ├─identifier : int
        \\  └─none_literal : none
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

test "parse fallible call syntax" {
    for ([_][]const u8{ "callee?(1)", "owner.method?(1)" }) |source| {
        var report = try parseReport(std.testing.allocator, 1, source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
        const ast = &report.ast.?;
        const call = ast.nodes[ast.node_refs[ast.nodes[0].data.ref.start].index()];
        try std.testing.expectEqual(Node.Tag.call, call.tag);
        try std.testing.expectEqual(Token.Tag.question_mark, ast.tokens[call.token_index].tag);
        try std.testing.expectEqual(Node.Tag.number_literal, ast.nodes[ast.nodeList(call.data.node_node.b)[0].index()].tag);
    }
}

test "parse query postfix independently from the fallible call marker" {
    for ([_][]const u8{ "value?", "callee()?", "1?", "callee??()", "callee?(1)?" }) |source| {
        var report = try parseReport(std.testing.allocator, 1, source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expect(report.ast != null);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    }
    var report = try parseReport(std.testing.allocator, 1, "callee?(1)?");
    defer report.deinit(std.testing.allocator);
    const ast = report.ast.?;
    var found = false;
    for (ast.nodes) |node| {
        if (node.tag != .query) continue;
        const call = ast.nodes[node.data.node.index()];
        try std.testing.expectEqual(Node.Tag.call, call.tag);
        try std.testing.expectEqual(Token.Tag.question_mark, ast.tokens[call.token_index].tag);
        found = true;
    }
    try std.testing.expect(found);
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
    const call = ast.nodes[parameter.data.parameter.annotation.index()];
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
    const call = ast.nodes[parameter.data.parameter.annotation.index()];
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

test "parse empty structs without indented bodies" {
    for ([_][]const u8{
        "struct Empty",
        "pub struct Empty\n# trailing comment\n",
        "struct Empty(T: type)",
        "pub struct Empty(\n  T: type,\n)",
        "static Empty = struct",
        "func Empty() type -> struct",
        "static struct Empty",
        "pub static struct Empty(T: type)",
        "static Empty = static struct",
        "func Empty() type -> static struct",
    }) |source| {
        var report = try parseReport(std.testing.allocator, 0, source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
        try std.testing.expect(report.ast != null);
    }
}

test "parse empty structs preserves following declarations and enclosing bodies" {
    try testParsing(
        \\static Empty = struct
        \\exit(0)
    ,
        \\static_binding
        \\└─struct
        \\call
        \\├─identifier : exit
        \\└─call_arg_list
        \\  └─number_literal : 0
    );
    try testParsing(
        \\struct Outer
        \\  struct Empty
        \\  value: int
        \\struct Next
    ,
        \\static_binding
        \\└─struct
        \\  ├─static_binding
        \\  │ └─struct
        \\  └─struct_field : value
        \\    └─type : int
        \\static_binding
        \\└─struct
    );
    var report = try parseReport(std.testing.allocator, 0,
        \\const result = choose(
        \\    struct,
        \\    static struct)
        \\exit(0)
    );
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    try std.testing.expect(report.ast != null);
    const statements = report.ast.?.nodes[0].data.ref;
    try std.testing.expectEqual(@as(u32, 2), statements.end - statements.start);
}

test "parse public declared and generated struct fields" {
    for ([_][:0]const u8{
        "struct S\n  pub x: int\n  y: int",
        "static Factory = func(static T: type) type\n  return struct\n    pub x: T\n    y: int",
    }) |source| {
        var report = try parseReport(std.testing.allocator, 1, source);
        defer report.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
        const ast = &report.ast.?;
        var public_fields: usize = 0;
        for (ast.nodes) |node| {
            if (node.tag == .@"pub" and ast.nodes[node.data.node.index()].tag == .struct_field)
                public_fields += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), public_fields);
    }
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
        \\    │ │ └─param : self (imm)
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
        \\  │   │ │ └─param : self (imm)
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
        \\      │ │ └─param : self (var)
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
        \\  │ │ ├─param : T (static)
        \\  │ │ │ └─type : type
        \\  │ │ └─param : N (static)
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
        \\  │   │ │ └─param : self (deinit)
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
        \\  │ │ └─param : T (static)
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

test "parse fallible calls and move postfix operators" {
    try testParsing(
        \\const a = value?()
        \\const b = a^
        \\take(b^)
        \\if const v = maybe?() -> print(v)
    ,
        \\const_binding
        \\└─call
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
        \\│ └─call
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
        \\  │ │ └─param : d (deinit)
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

test "delimited lists diagnose missing commas at their closing boundary" {
    const cases = [_]struct { source: [:0]const u8, closing: Token.Tag, found: Token.Tag }{
        .{ .source = "call(1 2)", .closing = .r_paren, .found = .number_literal },
        .{ .source = "[1 2]", .closing = .r_bracket, .found = .number_literal },
        .{ .source = "Point{x = 1 y = 2}", .closing = .r_brace, .found = .identifier },
        .{ .source = "import library.{first second}", .closing = .r_brace, .found = .identifier },
        .{ .source = "func f(value: int other: int) -> 1", .closing = .r_paren, .found = .identifier },
        .{ .source = "static Callback: type = func(int bool) int", .closing = .r_paren, .found = .identifier },
    };
    for (cases) |case| try testExpectDiagnosticTag(case.source, .{ .expected_token = .{ .expected = case.closing, .found = case.found } });
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
        \\  pub x int
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

test "parse report releases initial tokenization allocations on OOM" {
    for ([_]usize{ 0, 1 }) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, parseReport(failing.allocator(), 0, "const value = 123\n"));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "parse report cleans up every allocation failure" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParseReportAllocations, .{
        "static f = func(x: int, y: int) int\n  return x + y",
        null,
    });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParseReportAllocations, .{
        "const x 1",
        .{ .expected_token = .{ .expected = .equal, .found = .number_literal } },
    });
}

test "parse unnamed converter declarations" {
    const source =
        \\converter(value: int) byte -> value
        \\pub converter(static T: type, ref value: T) Ref(T) -> Ref(T){value = value}
    ;
    var report = try parseReport(std.testing.allocator, 0, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    var converters: usize = 0;
    for (report.ast.?.nodes) |node| {
        if (node.is_converter) {
            try std.testing.expectEqual(Node.Tag.func, node.tag);
            converters += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), converters);
}

test "parse static struct modifier through named generated and expression sugar" {
    const source =
        \\static struct Named
        \\  value: int
        \\pub static struct Generated(T: type)
        \\  value: T
        \\static Expression = static struct
        \\  value: int
        \\static Ordinary = struct
        \\  value: int
    ;
    var report = try parseReport(std.testing.allocator, 0, source);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    var marked: usize = 0;
    var ordinary: usize = 0;
    for (report.ast.?.nodes) |node| {
        if (node.tag != .@"struct") continue;
        if (node.is_static_struct) marked += 1 else ordinary += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), marked);
    try std.testing.expectEqual(@as(usize, 1), ordinary);
}

test "truncated multiline sources preserve parser error boundaries" {
    const sources = [_][]const u8{
        "ref value: Item = target.get?(index)",
        "import library.{\n  first as renamed,\n  second,\n}",
        "func calculate(\n  imm value: int | none,\n  init other: int,\n) int\n  if const result = value\n    return other\n  else return 0",
        "static struct Container(T: type)\n  value: T\n  func get(self: Self) T -> self.value",
        "const value = call(\n  [1, 2,\n    3],\n  Item{\n    field = 4,\n  },\n)",
        "static Callback: type = fallible(imm int | none, init int) int",
    };
    for (sources) |source| {
        for (0..source.len + 1) |length| {
            var report = try parseReport(std.testing.allocator, 0, source[0..length]);
            defer report.deinit(std.testing.allocator);
            try std.testing.expectEqual(report.ast == null, report.diagnostics.len != 0);
        }
    }
}

fn testExpectDiagnosticTag(source: [:0]const u8, expected: structures.Diagnostic.Kind) !void {
    var parser = try parseState(std.testing.allocator, source);
    defer parser.deinit();

    try std.testing.expect(parser.failure != null);
    try std.testing.expectEqual(expected, parser.failure.?.kind);
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
    try std.testing.expect(parser.failure == null);

    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    var ast = try parser.intoAst(0);
    defer ast.deinit(std.testing.allocator);
    try std.testing.expect(Ast.eql(ast, ast));
    try renderAst(std.testing.allocator, &ast, source, &buffer.writer);
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, buffer.writer.buffered(), "\n"));
}

test "parse collection clauses preserve nesting phase and open range spelling" {
    const source = "const values = [x static for x in 0..4 static if x > 0 for y in items, (..3), ..tail]";
    var report = try parseReport(std.testing.allocator, 0, source);
    defer report.deinit(std.testing.allocator);
    const parsed = &report.ast.?;
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len);
    const binding = parsed.nodes[parsed.node_refs[parsed.nodes[0].data.ref.start].index()];
    const items = parsed.nodeList(binding.data.node_node.b);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    const outer = parsed.nodes[items[0].index()];
    try std.testing.expectEqual(Node.Tag.collection_for, outer.tag);
    try std.testing.expectEqual(Token.Tag.keyword_static, parsed.tokens[outer.token_index].tag);
    const filter = parsed.nodes[parsed.nodeList(items[0])[2].index()];
    try std.testing.expectEqual(Node.Tag.collection_if, filter.tag);
    try std.testing.expectEqual(Token.Tag.keyword_static, parsed.tokens[filter.token_index].tag);
    const inner = parsed.nodes[filter.data.node_node.b.index()];
    try std.testing.expectEqual(Node.Tag.collection_for, inner.tag);
    try std.testing.expectEqual(Token.Tag.keyword_for, parsed.tokens[inner.token_index].tag);
    try std.testing.expectEqual(Node.Tag.range, parsed.nodes[items[1].index()].tag);
    try std.testing.expectEqual(Node.Tag.collection_spread, parsed.nodes[items[2].index()].tag);
}

test "where clauses use ordinary predicates and reject colon requirements" {
    const valid = "func filled(static T: type) int where T.copy is func(imm T) T -> 42";
    var accepted = try parseReport(std.testing.allocator, 0, valid);
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expect(accepted.ast != null);
    try std.testing.expectEqual(@as(usize, 0), accepted.diagnostics.len);

    const invalid = "func filled(static T: type) int where T.copy: func(imm T) T -> 42";
    var rejected = try parseReport(std.testing.allocator, 0, invalid);
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected.ast == null);
    try std.testing.expect(rejected.diagnostics.len != 0);
}
