const std = @import("std");
const structures = @import("structures.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = @import("tokenizer.zig").Token;

pub const Node = struct {
    tag: Tag,
    token_index: u32,
    data: Data,

    const Index = enum(u32) {
        null = 0,
        _,

        fn unwrap(self: @This()) ?Index {
            return if (self == .null) return null else self;
        }

        fn index(self: @This()) u32 {
            return @intFromEnum(self);
        }
    };

    pub const Tag = enum(u8) {
        add, // node_node: lhs, rhs
        sub, // node_node: lhs, rhs
        mul, // node_node: lhs, rhs
        div, // node_node: lhs, rhs
        eq, // node_node: lhs, rhs
        ne, // node_node: lhs, rhs
        lt, // node_node: lhs, rhs
        gt, // node_node: lhs, rhs
        le, // node_node: lhs, rhs
        ge, // node_node: lhs, rhs
        is, // node_node: lhs, type
        as, // node_node: lhs, type
        @"if", // node_node: condition, then expr
        if_else, // ref: condition, then expr, else expr
        @"and", // node_node: lhs, rhs
        @"or", // node_node: lhs, rhs
        not, // node: operand
        neg, // node: operand
        access, // token_index: parameter access modifier
        assign, // node_node: target, value
        block, // ref: statements
        bool_literal, // token_index: bool literal
        call, // node_node: callee, arg_list
        call_arg_list_small, // node_node: first arg, second arg
        call_arg_list, // ref: argument nodes
        const_binding, // node_node: type_annotation, value
        var_binding, // node_node: type_annotation, value
        comptime_binding, // node_node: type_annotation, value
        comptime_expr, // node: body
        field_access, // token_index: field name; node: target
        func, // node_node: signature, body
        identifier, // token_index: standalone identifier; bindings use their own token_index
        none_literal, // token_index: none literal
        number_literal, // token_index: number literal
        param, // token_index: identifier; node_node: access, type
        param_list_small, // node_node: first param, second param
        param_list, // ref: parameter nodes
        query_op, // node: operand
        move_expr, // node: operand
        return_nothing, // none
        return_expr, // node: returned expression
        signature, // node_node: param_list, return_type
        sizeof_expr, // node: type
        @"struct", // ref: fields
        struct_field, // token_index: identifier; node: type
        struct_init, // ref: target, fields
        struct_init_field, // token_index: identifier; node: value
        type, // token_index: type name
        type_func, // node_node: param_type_list, return_type
        type_list_small, // node_node: first type, second type
        type_list, // ref: type nodes
        type_variant_small, // node_node: first type, second type
        type_variant, // ref: member type nodes
        _, // future tag fallback
    };

    pub const Data = union {
        none: void,
        node: Index,
        node_node: struct {
            a: Index,
            b: Index,
        },
        ref: struct {
            start: u32,
            end: u32,
        },
    };
};

pub fn renderAst(ast: *const ParserState, source: []const u8, writer: *std.Io.Writer) !void {
    std.debug.assert(ast.nodes.items[0].tag == .block);
    const seen = try ast.gpa.alloc(bool, ast.nodes.items.len);
    defer ast.gpa.free(seen);
    const block_ref = ast.nodes.items[0].data.ref;
    for (block_ref.start..block_ref.end) |i| {
        try renderNode(ast.node_refs.items[i], ast, source, writer, seen, "", i == block_ref.end - 1, true);
    }
}

fn renderNode(node_index: Node.Index, ast: *const ParserState, source: []const u8, writer: *std.Io.Writer, seen: []bool, indent: []const u8, is_last: bool, at_root: bool) !void {
    const node = ast.nodes.items[node_index.index()];
    try writer.writeAll(indent);
    if (!at_root) try writer.writeAll(if (is_last) "└─" else "├─");
    try writer.print("{s}", .{@tagName(node.tag)});

    if (seen[node_index.index()]) {
        try writer.writeAll(" ...\n");
        return;
    }

    seen[node_index.index()] = true;
    const new_indent = if (at_root) "" else try std.mem.concat(ast.gpa, u8, &.{ indent, if (is_last) "  " else "│ " });
    defer ast.gpa.free(new_indent);
    switch (node.tag) {
        .return_nothing => {},
        .access, .bool_literal, .identifier, .none_literal, .type, .number_literal => {
            const loc = ast.tokens[node.token_index].loc;
            try writer.print(" : {s}\n", .{source[loc.start..loc.end]});
        },
        .return_expr, .not, .neg, .query_op, .move_expr, .comptime_expr, .sizeof_expr, .field_access, .struct_field, .struct_init_field => {
            if (node.tag == .field_access or node.tag == .struct_field or node.tag == .struct_init_field) {
                const loc = ast.tokens[node.token_index].loc;
                try writer.print(" : {s}", .{source[loc.start..loc.end]});
            }
            try writer.writeByte('\n');
            try renderNode(node.data.node, ast, source, writer, seen, new_indent, true, false);
        },
        .add, .sub, .mul, .div, .eq, .ne, .lt, .gt, .le, .ge, .is, .as, .@"and", .@"or", .assign, .call, .call_arg_list_small, .const_binding, .var_binding, .comptime_binding, .func, .param, .param_list_small, .signature, .type_func, .type_list_small, .type_variant_small, .@"if" => {
            if (node.tag == .param) {
                const loc = ast.tokens[node.token_index].loc;
                try writer.print(" : {s}", .{source[loc.start..loc.end]});
            }
            try writer.writeByte('\n');
            const b_node = node.data.node_node.b.unwrap();
            if (node.data.node_node.a.unwrap()) |a| {
                try renderNode(a, ast, source, writer, seen, new_indent, b_node == null, false);
            }
            if (b_node) |b| {
                try renderNode(b, ast, source, writer, seen, new_indent, true, false);
            }
        },
        .block, .call_arg_list, .param_list, .type_list, .type_variant, .if_else, .@"struct", .struct_init => {
            try writer.writeByte('\n');
            for (node.data.ref.start..node.data.ref.end) |i| {
                try renderNode(ast.node_refs.items[i], ast, source, writer, seen, new_indent, i == node.data.ref.end - 1, false);
            }
        },
        else => try writer.print("Not implemented {}\n", .{node.tag}),
    }
}

const LineInfo = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

// TODO: add start offset such that we don't traverse the entire source for each error. Errors are in ascending line order
fn lineInfoForOffset(source: []const u8, offset: usize) LineInfo {
    var line: usize = 1;
    var column: usize = 1;
    var line_start: usize = 0;

    var idx: usize = 0;
    const safe_offset = if (offset > source.len) source.len else offset;
    while (idx < safe_offset) : (idx += 1) {
        if (source[idx] == '\n') {
            line += 1;
            column = 1;
            line_start = idx + 1;
        } else {
            column += 1;
        }
    }

    var line_end = source.len;
    idx = line_start;
    while (idx < source.len) : (idx += 1) {
        if (source[idx] == '\n') {
            line_end = idx;
            break;
        }
    }

    return .{
        .line = line,
        .column = column,
        .line_start = line_start,
        .line_end = line_end,
    };
}

pub fn renderDiagnostics(w: *std.Io.Writer, ast: *ParserState, source_path: []const u8, source: []const u8, diags: []const Diagnostic) !void {
    for (diags) |diag| {
        const source_location = ast.tokens[diag.token_index].loc;
        const info = lineInfoForOffset(source, source_location.start);
        try w.print("\x1b[31merror:\x1b[0m {s}:{d}:{d}: ", .{ source_path, info.line, info.column });
        try diag.render(ast, w);
        try w.writeByte('\n');

        try w.writeAll(source[info.line_start..info.line_end]);
        try w.writeByte('\n');

        const caret_indent = if (info.column > 0) info.column - 1 else 0;
        try w.splatByteAll(' ', caret_indent);
        try w.writeByte('^');

        const extra = @min(source_location.end, info.line_end) - @max(source_location.start, info.line_start);
        if (extra > 1) try w.splatByteAll('~', extra - 1);
        try w.writeByte('\n');
    }
}

const ParseError = std.mem.Allocator.Error || error{ParseError};
const Diagnostic = struct {
    tag: Tag,
    token_index: u32,
    extra: Extra,

    const Extra = union {
        none: void,
        token_tag: Token.Tag,
    };

    const Tag = enum(u8) {
        expectedToken,
        invalid_expression,
        _,
    };

    pub fn render(self: @This(), ast: *ParserState, w: *std.Io.Writer) !void {
        try switch (self.tag) {
            .expectedToken => w.print("expected {}, found {}", .{ self.extra.token_tag, ast.tokens[self.token_index].tag }),
            .invalid_expression => w.print("{} is not a vaild expression", .{ast.tokens[self.token_index].tag}),
            else => w.print("{}", .{self.tag}),
        };
    }
};

pub const ParserState = struct {
    gpa: std.mem.Allocator,
    tokens: []Token,
    index: u32,
    nodes: std.ArrayList(Node),
    node_refs: std.ArrayList(Node.Index),
    scratch_stack: std.ArrayList(Node.Index),
    errors: std.ArrayList(Diagnostic),

    pub fn init(gpa: std.mem.Allocator, tokens: []Token) !ParserState {
        return .{
            .gpa = gpa,
            .tokens = tokens,
            .index = 0,
            .nodes = try std.ArrayList(Node).initCapacity(gpa, tokens.len / 2),
            .node_refs = try std.ArrayList(Node.Index).initCapacity(gpa, tokens.len / 4),
            .scratch_stack = .empty,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.gpa.free(self.tokens);
        self.nodes.deinit(self.gpa);
        self.node_refs.deinit(self.gpa);
        self.scratch_stack.deinit(self.gpa);
        self.errors.deinit(self.gpa);
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

    // pub fn addRef(self: *@This(), layout: anytype) !u32 {
    //     const fields = std.meta.fields(@TypeOf(layout));
    //     try self.node_refs.ensureUnusedCapacity(self.gpa, fields.len);

    //     const idx: u32 = @intCast(self.node_refs.items.len);
    //     inline for (fields) |field| {
    //         self.node_refs.appendAssumeCapacity(@field(layout, field.name));
    //     }
    //     return idx;
    // }

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
        try self.addError(.expectedToken, .{ .token_tag = token });
        return ParseError.ParseError;
    }

    pub fn listToSpan(parser: *@This(), list: []const Node.Index) !Node.Data {
        try parser.node_refs.appendSlice(parser.gpa, @ptrCast(list));
        return .{ .ref = .{
            .start = @intCast(parser.node_refs.items.len - list.len),
            .end = @intCast(parser.node_refs.items.len),
        } };
    }

    pub fn addError(self: *@This(), tag: Diagnostic.Tag, extra: Diagnostic.Extra) !void {
        try self.errors.append(self.gpa, .{ .tag = tag, .token_index = self.index, .extra = extra });
    }
};

pub fn parse(gpa: std.mem.Allocator, source: [:0]const u8) !ParserState {
    var tok = try Tokenizer.init(gpa, source);
    defer tok.deinit();

    const estimated_token_count = source.len / 8;
    var tokens = try std.ArrayList(Token).initCapacity(gpa, estimated_token_count);

    while (true) {
        const token = try tok.next();
        try tokens.append(gpa, token);
        if (token.tag == .eof) break;
    }

    var parser = try ParserState.init(gpa, try tokens.toOwnedSlice(gpa));
    _ = parseBlock(&parser) catch return parser;
    _ = parser.expect(.eof) catch return parser;
    return parser;
}

fn parseBlock(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    const reserved_idx = try parser.reserveNode();
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.dedent) != null) break;
        if (parser.tokens[parser.index].tag == .eof) break;

        const expr = parseExpression(parser) catch break;
        if (expr == .null) break;

        try parser.scratch_stack.append(parser.gpa, expr);
    }
    return parser.setNode(reserved_idx, .{ .tag = .block, .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseExpression(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.tokens[parser.index].tag) {
        .keyword_comptime => return parseComptime(parser) catch return .null,
        .keyword_const, .keyword_var => return parseBinding(parser) catch return .null,
        .keyword_func => return parseFunction(parser) catch return .null,
        .keyword_return => return parseReturn(parser) catch return .null,
        else => {
            const expr = try parseExpressionPrecedence(parser, 0);
            if (parser.tokens[parser.index].tag == .equal) return parseAssign(parser, expr) catch return .null;
            return expr;
        },
    };
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
    const tag: Node.Tag = switch (parser.tokens[parser.index].tag) {
        .keyword_not => .not,
        .minus => .neg,
        else => return parsePostfix(parser),
    };

    const token_index = parser.index;
    parser.index += 1;
    const operand = try parseUnary(parser);
    return parser.addNode(.{ .tag = tag, .token_index = token_index, .data = .{ .node = operand } });
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
        .number_literal => return parseTokenNode(parser, .number_literal, .number_literal) catch return .null,
        .keyword_true => return parseTokenNode(parser, .keyword_true, .bool_literal) catch return .null,
        .keyword_false => return parseTokenNode(parser, .keyword_false, .bool_literal) catch return .null,
        .keyword_none => return parseTokenNode(parser, .keyword_none, .none_literal) catch return .null,
        .keyword_if => return parseIfExpr(parser) catch return .null,
        .keyword_comptime => return parseComptime(parser) catch return .null,
        .keyword_sizeof => return parseSizeof(parser) catch return .null,
        .keyword_struct => return parseStruct(parser) catch return .null,
        .identifier => return parseTokenNode(parser, .identifier, .identifier) catch return .null,
        .l_paren => {
            _ = parser.eat(.l_paren);
            const expr = try parseExpressionPrecedence(parser, 0);
            _ = parser.expect(.r_paren) catch return .null;
            return expr;
        },
        else => {
            try parser.addError(.invalid_expression, .{ .none = {} });
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

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .call_arg_list_small, .call_arg_list);
}

fn parseStruct(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_struct);
    _ = try parser.expect(.indent);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.dedent) != null) break;
        if (parser.tokens[parser.index].tag == .eof) break;

        const field = try parseStructField(parser);
        try parser.scratch_stack.append(parser.gpa, field);
    }

    return try parser.addNode(.{ .tag = .@"struct", .token_index = token_index, .data = try parser.listToSpan(parser.scratch_stack.items[stack_top..]) });
}

fn parseStructField(parser: *ParserState) ParseError!Node.Index {
    const identifier_index = parser.index;
    _ = try parser.expect(.identifier);
    _ = try parser.expect(.colon);
    const field_type = try parseType(parser);
    return try parser.addNode(.{ .tag = .struct_field, .token_index = identifier_index, .data = .{ .node = field_type } });
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
    const value = try parseExpression(parser);
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

fn addNodeList(parser: *ParserState, token_index: u32, items: []const Node.Index, small_tag: Node.Tag, list_tag: Node.Tag) !Node.Index {
    if (items.len == 0) return .null;

    if (items.len <= 2) {
        return try parser.addNode(.{
            .tag = small_tag,
            .token_index = token_index,
            .data = .{ .node_node = .{
                .a = items[0],
                .b = if (items.len > 1) items[1] else .null,
            } },
        });
    }

    return try parser.addNode(.{ .tag = list_tag, .token_index = token_index, .data = try parser.listToSpan(items) });
}

fn parseIfExpr(parser: *ParserState) ParseError!Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_if);

    const condition = try parseExpression(parser);
    const then_body = try parseBody(parser);
    if (parser.eat(.keyword_else) != null) {
        const else_body = if (parser.eat(.indent) != null) try parseBlock(parser) else try parseExpression(parser);
        const ref_start: u32 = @intCast(parser.node_refs.items.len);
        try parser.node_refs.appendSlice(parser.gpa, &.{ condition, then_body, else_body });
        const ref_end: u32 = @intCast(parser.node_refs.items.len);
        return try parser.addNode(.{ .tag = .if_else, .token_index = token_index, .data = .{ .ref = .{ .start = ref_start, .end = ref_end } } });
    }
    return try parser.addNode(.{ .tag = .@"if", .token_index = token_index, .data = .{ .node_node = .{ .a = condition, .b = then_body } } });
}

fn parseBinding(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const binding_keyword = parser.eat(.keyword_const) orelse parser.eat(.keyword_var) orelse parser.eat(.keyword_comptime) orelse return .null;
    _ = try parser.expect(.identifier);
    const type_annotation = try parseTypeAnnotation(parser);
    _ = try parser.expect(.equal);
    const value = try parseExpression(parser);
    const tag: Node.Tag = if (binding_keyword.tag == .keyword_const) .const_binding else if (binding_keyword.tag == .keyword_var) .var_binding else .comptime_binding;

    return parser.addNode(.{ .tag = tag, .token_index = token_index, .data = .{ .node_node = .{ .a = type_annotation, .b = value } } });
}

fn parseAssign(parser: *ParserState, target: Node.Index) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.equal);
    const value = try parseExpression(parser);
    return try parser.addNode(.{ .tag = .assign, .token_index = token_index, .data = .{ .node_node = .{ .a = target, .b = value } } });
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

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .type_variant_small, .type_variant);
}

fn parseTypePrimary(parser: *ParserState) ParseError!Node.Index {
    return switch (parser.tokens[parser.index].tag) {
        .identifier => return parseTokenNode(parser, .identifier, .type) catch return .null,
        .keyword_none => return parseTokenNode(parser, .keyword_none, .type) catch return .null,
        .keyword_func => return parseFunctionType(parser) catch return .null,
        else => {
            try parser.addError(.invalid_expression, .{ .none = {} });
            return error.ParseError;
        },
    };
}

fn parseFunctionType(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.keyword_func);
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

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .type_list_small, .type_list);
}

fn parseComptime(parser: *ParserState) !Node.Index {
    if (parser.tokens[parser.index + 1].tag == .identifier) {
        if ((try parseBinding(parser)).unwrap()) |binding| return binding;
    }

    const token_index = parser.index;
    _ = try parser.expect(.keyword_comptime);
    const body = try parseBody(parser);
    return try parser.addNode(.{ .tag = .comptime_expr, .token_index = token_index, .data = .{ .node = body } });
}

fn parseFunction(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = parser.eat(.keyword_func) orelse return .null;
    const signature = parseFuncSignature(parser) catch return .null;
    const body = if ((try parseBody(parser)).unwrap()) |b| b else return .null;
    return parser.addNode(.{ .tag = .func, .token_index = token_index, .data = .{ .node_node = .{ .a = signature, .b = body } } });
}

fn parseFuncSignature(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    const params = try parseParamList(parser);
    const return_type: Node.Index = switch (parser.tokens[parser.index].tag) {
        .identifier, .keyword_func, .keyword_none => try parseType(parser),
        else => .null,
    };
    return parser.addNode(.{ .tag = .signature, .token_index = token_index, .data = .{ .node_node = .{ .a = params, .b = return_type } } });
}

fn parseParamList(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = try parser.expect(.l_paren);
    const stack_top = parser.scratch_stack.items.len;
    defer parser.scratch_stack.shrinkRetainingCapacity(stack_top);

    while (true) {
        if (parser.eat(.r_paren) != null) break;

        const access_token_index = parser.index;
        const opt_access = parser.eatAny(&.{ .keyword_read, .keyword_mut, .keyword_var, .keyword_deinit, .keyword_comptime });
        _ = parser.expect(.identifier) catch return .null;
        const identifier_index = parser.index - 1;
        const type_annotation = try parseTypeAnnotation(parser);

        const access_idx: Node.Index = if (opt_access != null) try parser.addNode(.{ .tag = .access, .token_index = access_token_index, .data = .{ .none = {} } }) else .null;
        const param = try parser.addNode(.{ .tag = .param, .token_index = identifier_index, .data = .{ .node_node = .{ .a = access_idx, .b = type_annotation } } });

        try parser.scratch_stack.append(parser.gpa, param);

        if (parser.eat(.comma) != null) continue;
        _ = try parser.expect(.r_paren);
        break;
    }

    return try addNodeList(parser, token_index, parser.scratch_stack.items[stack_top..], .param_list_small, .param_list);
}

fn parseBody(parser: *ParserState) !Node.Index {
    if (parser.eat(.arrow) != null) return try parseExpression(parser);
    _ = try parser.expect(.indent);
    return try parseBlock(parser);
}

fn parseReturn(parser: *ParserState) !Node.Index {
    const token_index = parser.index;
    _ = parser.expect(.keyword_return) catch return .null;
    if ((try parseExpression(parser)).unwrap()) |expr| {
        return try parser.addNode(.{ .tag = .return_expr, .token_index = token_index, .data = .{ .node = expr } });
    }
    return try parser.addNode(.{ .tag = .return_nothing, .token_index = token_index, .data = .{ .none = {} } });
}

fn parseTokenNode(parser: *ParserState, token: Token.Tag, tag: Node.Tag) !Node.Index {
    _ = try parser.expect(token);
    return parser.addNode(.{ .tag = tag, .token_index = parser.index - 1, .data = .{ .none = {} } });
}

test "parse function no parameters" {
    try testParsing(
        \\comptime foo = func() int
        \\  return 1
    ,
        \\comptime_binding
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
        \\comptime foo = func() int -> return 1
    ,
        \\comptime_binding
        \\└─func
        \\  ├─signature
        \\  │ └─type : int
        \\  └─return_expr
        \\    └─number_literal : 1
    );
}

test "parse function with parameters" {
    try testParsing(
        \\comptime add = func(x: int, y: int) int
        \\  return x + y
    ,
        \\comptime_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list_small
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
        \\├─type_variant_small
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

test "parse function type annotations" {
    try testParsing(
        \\const f: func(int, float) int = add
        \\const g: func() none = noop
        \\const h: func(int, float, bool) none = tri
    ,
        \\const_binding
        \\├─type_func
        \\│ ├─type_list_small
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
        \\comptime apply = func(f: func(int) int, x: int | float) int | none
        \\  return none
    ,
        \\comptime_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list_small
        \\  │ │ ├─param : f
        \\  │ │ │ └─type_func
        \\  │ │ │   ├─type_list_small
        \\  │ │ │   │ └─type : int
        \\  │ │ │   └─type : int
        \\  │ │ └─param : x
        \\  │ │   └─type_variant_small
        \\  │ │     ├─type : int
        \\  │ │     └─type : float
        \\  │ └─type_variant_small
        \\  │   ├─type : int
        \\  │   └─type : none
        \\  └─block
        \\    └─return_expr
        \\      └─none_literal : none
    );
}

test "parse struct declaration" {
    try testParsing(
        \\comptime Vec2 = struct
        \\  x: int
        \\  y: float
    ,
        \\comptime_binding
        \\└─struct
        \\  ├─struct_field : x
        \\  │ └─type : int
        \\  └─struct_field : y
        \\    └─type : float
    );
}

test "parse anonymous struct expression" {
    try testParsing(
        \\comptime Wrapper = func(comptime T: type) type
        \\  return struct
        \\    x: T
    ,
        \\comptime_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list_small
        \\  │ │ └─param : T
        \\  │ │   ├─access : comptime
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
        \\  │ └─call_arg_list_small
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
        \\└─call_arg_list_small
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
        \\│ └─type_variant_small
        \\│   ├─type : int
        \\│   └─type : A
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list_small
        \\    └─number_literal : 1
        \\if
        \\├─const_binding
        \\│ └─as
        \\│   ├─identifier : b
        \\│   └─type : int
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list_small
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
        \\  └─call_arg_list_small
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
        \\└─call_arg_list_small
        \\  └─move_expr
        \\    └─identifier : b
        \\if
        \\├─const_binding
        \\│ └─query_op
        \\│   └─identifier : maybe
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list_small
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
        \\└─call_arg_list_small
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
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
    ,
        \\comptime_binding
        \\└─func
        \\  ├─signature
        \\  │ ├─param_list_small
        \\  │ │ └─param : d
        \\  │ │   ├─access : deinit
        \\  │ │   └─type : D
        \\  │ └─type : unit
        \\  └─block
        \\    └─call
        \\      ├─identifier : print
        \\      └─call_arg_list_small
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
        \\└─call_arg_list_small
        \\  └─sizeof_expr
        \\    └─type : int
        \\call
        \\├─identifier : print
        \\└─call_arg_list_small
        \\  └─sizeof_expr
        \\    └─type_func
        \\      ├─type_list_small
        \\      │ └─type : int
        \\      └─type : int
        \\const_binding
        \\└─sizeof_expr
        \\  └─type_variant_small
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
        \\  └─call_arg_list_small
        \\    └─number_literal : 1
        \\if
        \\├─ge
        \\│ ├─identifier : b
        \\│ └─identifier : c
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list_small
        \\    └─number_literal : 2
        \\if
        \\├─ne
        \\│ ├─identifier : c
        \\│ └─identifier : d
        \\└─call
        \\  ├─identifier : print
        \\  └─call_arg_list_small
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
        \\│   └─call_arg_list_small
        \\│     └─number_literal : 11
        \\└─block
        \\  └─call
        \\    ├─identifier : print
        \\    └─call_arg_list_small
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
        \\│ └─call_arg_list_small
        \\│   └─number_literal : 1
        \\└─if_else
        \\  ├─lt
        \\  │ ├─number_literal : 2
        \\  │ └─number_literal : 3
        \\  ├─call
        \\  │ ├─identifier : print
        \\  │ └─call_arg_list_small
        \\  │   └─number_literal : 2
        \\  └─call
        \\    ├─identifier : print
        \\    └─call_arg_list_small
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
        \\    └─call_arg_list_small
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
        \\└─call_arg_list_small
        \\  └─bool_literal : true
        \\call
        \\├─identifier : bar
        \\└─call_arg_list_small
        \\  ├─bool_literal : false
        \\  └─none_literal : none
        \\call
        \\├─identifier : baz
        \\└─call_arg_list_small
        \\  ├─call
        \\  │ ├─identifier : foo
        \\  │ └─call_arg_list_small
        \\  │   └─number_literal : 1
        \\  └─call
        \\    ├─identifier : bar
        \\    └─call_arg_list_small
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

fn testParsing(source: [:0]const u8, expected: []const u8) !void {
    var ast = try parse(std.testing.allocator, source);
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try renderDiagnostics(&buffer.writer, &ast, "test_path", source, ast.errors.items);

    defer buffer.deinit();
    defer ast.deinit();
    try renderAst(&ast, source, &buffer.writer);
    try std.testing.expectEqualStrings(expected, std.mem.trimEnd(u8, buffer.writer.buffered(), "\n"));
}
