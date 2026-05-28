const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const AstNode = ast.AstNode;
const IfNode = ast.IfNode;
const ConstNode = ast.ConstNode;

pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedToken,
    ExpectedExpression,
    ExpectedIdentifier,
    ExpectedAssign,
    ExpectedThen,
    ExpectedRParen,
    ExpectedLParen,
    InvalidArgIndex,
    IntegerOverflow,
    FloatOverflow,
    TrailingInput,
};

const TokenTag = enum {
    eof,
    int_lit,
    float_lit,
    kw_if,
    kw_const,
    kw_then,
    kw_else,
    kw_print,
    kw_arg,
    kw_true,
    kw_false,
    ident,
    l_paren,
    r_paren,
    newline,
    assign,
    plus,
    minus,
    star,
    slash,
    lt,
    gt,
    le,
    ge,
    eq_eq,
    ne,
};

const Token = struct {
    tag: TokenTag,
    start: usize,
    end: usize,
    int_value: u32 = 0,
    float_value: f32 = 0,
    ident: []const u8 = "",
};

const Lexer = struct {
    source: []const u8,
    index: usize,

    fn init(source: []const u8) Lexer {
        return .{ .source = source, .index = 0 };
    }

    fn skipInlineWhitespace(self: *@This()) void {
        while (self.index < self.source.len) {
            const char = self.source[self.index];
            if (char == '\n') break;
            if (!std.ascii.isWhitespace(char)) break;
            self.index += 1;
        }
    }

    fn parseInt(slice: []const u8) ParseError!u32 {
        var value: u64 = 0;
        const max_signed_plus_one = @as(u64, @intCast(std.math.maxInt(i32))) + 1;
        for (slice) |char| {
            const digit: u64 = char - '0';
            value = value * 10 + digit;
            if (value > max_signed_plus_one) return error.IntegerOverflow;
        }
        return @intCast(value);
    }

    fn parseNumber(self: *@This()) ParseError!Token {
        const start = self.index;
        var saw_dot = false;

        if (self.source[self.index] == '.') {
            saw_dot = true;
            self.index += 1;
        }

        while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) {
            self.index += 1;
        }

        if (self.index < self.source.len and self.source[self.index] == '.') {
            saw_dot = true;
            self.index += 1;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) {
                self.index += 1;
            }
        }

        const slice = self.source[start..self.index];
        if (saw_dot) {
            const value = std.fmt.parseFloat(f32, slice) catch return error.FloatOverflow;
            return .{ .tag = .float_lit, .start = start, .end = self.index, .float_value = value };
        }

        const value = try parseInt(slice);
        return .{ .tag = .int_lit, .start = start, .end = self.index, .int_value = value };
    }

    fn isIdentContinue(char: u8) bool {
        return std.ascii.isAlphanumeric(char) or char == '_';
    }

    fn parseKeywordOrIdent(self: *@This()) Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.index += 1;
        }

        const word = self.source[start..self.index];
        if (std.mem.eql(u8, word, "if")) return .{ .tag = .kw_if, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "const")) return .{ .tag = .kw_const, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "then")) return .{ .tag = .kw_then, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "else")) return .{ .tag = .kw_else, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "print")) return .{ .tag = .kw_print, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "arg")) return .{ .tag = .kw_arg, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "true")) return .{ .tag = .kw_true, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "false")) return .{ .tag = .kw_false, .start = start, .end = self.index };
        return .{ .tag = .ident, .start = start, .end = self.index, .ident = word };
    }

    fn next(self: *@This()) ParseError!Token {
        self.skipInlineWhitespace();
        if (self.index >= self.source.len) {
            return .{ .tag = .eof, .start = self.source.len, .end = self.source.len };
        }

        const char = self.source[self.index];
        if (char == '\n') {
            const start = self.index;
            self.index += 1;
            return .{ .tag = .newline, .start = start, .end = self.index };
        }

        const dot_prefixed_float = char == '.' and self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1]);
        if (std.ascii.isDigit(char) or dot_prefixed_float) return self.parseNumber();
        if (std.ascii.isAlphabetic(char) or char == '_') return self.parseKeywordOrIdent();

        const start = self.index;
        self.index += 1;
        return switch (char) {
            '(' => .{ .tag = .l_paren, .start = start, .end = self.index },
            ')' => .{ .tag = .r_paren, .start = start, .end = self.index },
            '+' => .{ .tag = .plus, .start = start, .end = self.index },
            '-' => .{ .tag = .minus, .start = start, .end = self.index },
            '*' => .{ .tag = .star, .start = start, .end = self.index },
            '/' => .{ .tag = .slash, .start = start, .end = self.index },
            '<' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .le, .start = start, .end = self.index };
            } else .{ .tag = .lt, .start = start, .end = self.index },
            '>' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .ge, .start = start, .end = self.index };
            } else .{ .tag = .gt, .start = start, .end = self.index },
            '=' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .eq_eq, .start = start, .end = self.index };
            } else .{ .tag = .assign, .start = start, .end = self.index },
            '!' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .ne, .start = start, .end = self.index };
            } else error.UnexpectedCharacter,
            else => error.UnexpectedCharacter,
        };
    }
};

pub const ParsedAst = struct {
    arena: std.heap.ArenaAllocator,
    root: *const AstNode,
    spans: std.AutoHashMap(usize, ast.Span),

    pub fn deinit(self: *@This()) void {
        self.spans.deinit();
        self.arena.deinit();
    }

    pub fn spanOf(self: *const @This(), node: *const AstNode) ?ast.Span {
        return self.spans.get(@intFromPtr(node));
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    spans: std.AutoHashMap(usize, ast.Span),

    const BinTag = enum {
        add,
        sub,
        mul,
        div,
        lt,
        gt,
        le,
        ge,
        eq,
        ne,
    };

    fn init(source: []const u8, arena: std.mem.Allocator, spans_gpa: std.mem.Allocator) ParseError!Parser {
        var lexer = Lexer.init(source);
        const current = try lexer.next();
        return .{
            .arena = arena,
            .lexer = lexer,
            .current = current,
            .spans = std.AutoHashMap(usize, ast.Span).init(spans_gpa),
        };
    }

    fn advance(self: *@This()) ParseError!void {
        self.current = try self.lexer.next();
    }

    fn expect(self: *@This(), tag: TokenTag, err: ParseError) ParseError!void {
        if (self.current.tag != tag) return err;
        try self.advance();
    }

    fn tokenSpan(token: Token) ast.Span {
        return .{ .start = token.start, .end = token.end };
    }

    fn spanOfNode(self: *const @This(), node: *const AstNode) ast.Span {
        return self.spans.get(@intFromPtr(node)) orelse .{ .start = 0, .end = 0 };
    }

    fn coverSpans(start: ast.Span, end: ast.Span) ast.Span {
        return .{ .start = start.start, .end = end.end };
    }

    fn allocNode(self: *@This(), node: AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const ptr = try self.arena.create(AstNode);
        ptr.* = node;
        try self.spans.put(@intFromPtr(ptr), span);
        return ptr;
    }

    fn allocKids(self: *@This(), left: *const AstNode, right: *const AstNode) error{OutOfMemory}!*const [2]AstNode {
        const kids = try self.arena.create([2]AstNode);
        kids[0] = left.*;
        kids[1] = right.*;
        // Binary children are stored by value, so mirror span metadata for the copied nodes.
        try self.spans.put(@intFromPtr(&kids[0]), self.spanOfNode(left));
        try self.spans.put(@intFromPtr(&kids[1]), self.spanOfNode(right));
        return kids;
    }

    fn allocName(self: *@This(), name: []const u8) error{OutOfMemory}![]const u8 {
        return try self.arena.dupe(u8, name);
    }

    fn makeSeq(self: *@This(), left: *const AstNode, right: *const AstNode) error{OutOfMemory}!*const AstNode {
        const kids = try self.allocKids(left, right);
        const span = coverSpans(self.spanOfNode(left), self.spanOfNode(right));
        return self.allocNode(.{ .seq = kids }, span);
    }

    fn makeConstNode(self: *@This(), name: []const u8, value: *const AstNode, body: *const AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const data = try self.arena.create(ConstNode);
        data.* = .{
            .name = try self.allocName(name),
            .value = value,
            .body = body,
        };
        return self.allocNode(.{ .const_ = data }, span);
    }

    fn makeBinop(self: *@This(), tag: BinTag, left: *const AstNode, right: *const AstNode) error{OutOfMemory}!*const AstNode {
        const kids = try self.allocKids(left, right);
        const span = coverSpans(self.spanOfNode(left), self.spanOfNode(right));
        return switch (tag) {
            .add => self.allocNode(.{ .add = kids }, span),
            .sub => self.allocNode(.{ .sub = kids }, span),
            .mul => self.allocNode(.{ .mul = kids }, span),
            .div => self.allocNode(.{ .div = kids }, span),
            .lt => self.allocNode(.{ .lt = kids }, span),
            .gt => self.allocNode(.{ .gt = kids }, span),
            .le => self.allocNode(.{ .le = kids }, span),
            .ge => self.allocNode(.{ .ge = kids }, span),
            .eq => self.allocNode(.{ .eq = kids }, span),
            .ne => self.allocNode(.{ .ne = kids }, span),
        };
    }

    fn maxI32PlusOne() u32 {
        return @as(u32, @intCast(std.math.maxInt(i32))) + 1;
    }

    fn intFromToken(token: Token) ParseError!i32 {
        const max_i32_u32: u32 = @intCast(std.math.maxInt(i32));
        if (token.int_value > max_i32_u32) return error.IntegerOverflow;
        return @intCast(token.int_value);
    }

    fn negatedIntFromToken(token: Token) ParseError!i32 {
        const raw = token.int_value;
        if (raw == maxI32PlusOne()) return std.math.minInt(i32);
        const max_i32_u32: u32 = @intCast(std.math.maxInt(i32));
        if (raw > max_i32_u32) return error.IntegerOverflow;
        const positive: i32 = @intCast(raw);
        return -positive;
    }

    fn negatedFloatFromToken(token: Token) f32 {
        return -token.float_value;
    }

    fn parseProgram(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const root = try self.parseBlockExpression();
        if (self.current.tag != .eof) return error.TrailingInput;
        return root;
    }

    fn consumeNewlines(self: *@This()) ParseError!void {
        while (self.current.tag == .newline) {
            try self.advance();
        }
    }

    fn parseBlockExpression(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        try self.consumeNewlines();
        if (self.current.tag == .kw_const) return self.parseConstBinding();
        if (self.current.tag == .eof) return self.allocNode(.{ .unit = {} }, .{ .start = self.lexer.index, .end = self.lexer.index });

        var first = try self.parseExpression();
        while (self.current.tag == .newline) {
            try self.consumeNewlines();
            if (self.current.tag == .eof or self.current.tag == .r_paren) break;
            const next = try self.parseBlockExpression();
            first = try self.makeSeq(first, next);
            break;
        }
        return first;
    }

    fn parseExpression(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        return self.parseComparison();
    }

    fn parseConstBinding(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const const_span = tokenSpan(self.current);
        try self.expect(.kw_const, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const ident = self.current.ident;
        try self.advance();
        try self.expect(.assign, error.ExpectedAssign);
        const value = try self.parseExpression();
        if (self.current.tag != .newline) return error.UnexpectedToken;
        try self.consumeNewlines();
        const body = try self.parseBlockExpression();
        const const_node_span = coverSpans(const_span, self.spanOfNode(body));
        return self.makeConstNode(ident, value, body, const_node_span);
    }

    fn parseComparison(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        var lhs = try self.parseAdditive();

        while (true) {
            const bin_tag = switch (self.current.tag) {
                .lt => BinTag.lt,
                .gt => BinTag.gt,
                .le => BinTag.le,
                .ge => BinTag.ge,
                .eq_eq => BinTag.eq,
                .ne => BinTag.ne,
                else => break,
            };
            try self.advance();
            const rhs = try self.parseAdditive();
            lhs = try self.makeBinop(bin_tag, lhs, rhs);
        }

        return lhs;
    }

    fn parseAdditive(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        var lhs = try self.parseMultiplicative();

        while (true) {
            const bin_tag = switch (self.current.tag) {
                .plus => BinTag.add,
                .minus => BinTag.sub,
                else => break,
            };
            try self.advance();
            const rhs = try self.parseMultiplicative();
            lhs = try self.makeBinop(bin_tag, lhs, rhs);
        }

        return lhs;
    }

    fn parseMultiplicative(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        var lhs = try self.parseUnary();

        while (true) {
            const bin_tag = switch (self.current.tag) {
                .star => BinTag.mul,
                .slash => BinTag.div,
                else => break,
            };
            try self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.makeBinop(bin_tag, lhs, rhs);
        }

        return lhs;
    }

    fn parseUnary(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        if (self.current.tag == .minus) {
            const minus_span = tokenSpan(self.current);
            try self.advance();

            if (self.current.tag == .int_lit) {
                const value = try negatedIntFromToken(self.current);
                const int_span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.{ .int = value }, coverSpans(minus_span, int_span));
            }

            if (self.current.tag == .float_lit) {
                const value = negatedFloatFromToken(self.current);
                const float_span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.{ .float = value }, coverSpans(minus_span, float_span));
            }

            const operand = try self.parseUnary();
            const zero = try self.allocNode(.{ .int = 0 }, minus_span);
            return self.makeBinop(.sub, zero, operand);
        }

        return self.parsePrimary();
    }

    fn parsePrimary(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        switch (self.current.tag) {
            .int_lit => {
                const lit_span = tokenSpan(self.current);
                const value = try intFromToken(self.current);
                try self.advance();
                return self.allocNode(.{ .int = value }, lit_span);
            },
            .float_lit => {
                const lit_span = tokenSpan(self.current);
                const value = self.current.float_value;
                try self.advance();
                return self.allocNode(.{ .float = value }, lit_span);
            },
            .l_paren => {
                try self.advance();
                const expr = try self.parseExpression();
                try self.expect(.r_paren, error.ExpectedRParen);
                return expr;
            },
            .kw_print => return self.parsePrint(),
            .kw_arg => return self.parseArg(),
            .kw_if => return self.parseIf(),
            .kw_true => {
                const span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.{ .bool = true }, span);
            },
            .kw_false => {
                const span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.{ .bool = false }, span);
            },
            .ident => {
                const ident_span = tokenSpan(self.current);
                const name = try self.allocName(self.current.ident);
                try self.advance();
                return self.allocNode(.{ .var_ref = name }, ident_span);
            },
            else => return error.ExpectedExpression,
        }
    }

    fn parsePrint(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const print_span = tokenSpan(self.current);
        try self.expect(.kw_print, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);
        const expr = try self.parseExpression();
        const end_span = tokenSpan(self.current);
        try self.expect(.r_paren, error.ExpectedRParen);
        return self.allocNode(.{ .print = expr }, coverSpans(print_span, end_span));
    }

    fn parseArg(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const arg_span = tokenSpan(self.current);
        try self.expect(.kw_arg, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);

        if (self.current.tag != .int_lit) return error.InvalidArgIndex;
        const idx: u32 = self.current.int_value;
        const max_arg_index = std.math.maxInt(u32) / 8;
        if (idx > max_arg_index) return error.InvalidArgIndex;
        try self.advance();

        const end_span = tokenSpan(self.current);
        try self.expect(.r_paren, error.ExpectedRParen);
        return self.allocNode(.{ .arg = idx }, coverSpans(arg_span, end_span));
    }

    fn parseIf(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const if_span = tokenSpan(self.current);
        try self.expect(.kw_if, error.UnexpectedToken);

        const cond = try self.parseExpression();
        try self.expect(.kw_then, error.ExpectedThen);
        const then_expr = try self.parseExpression();

        var else_expr: ?*const AstNode = null;
        if (self.current.tag == .kw_else) {
            try self.advance();
            else_expr = try self.parseExpression();
        }

        const if_data = try self.arena.create(IfNode);
        if_data.* = .{
            .cond = cond,
            .then_ = then_expr,
            .else_ = else_expr,
        };
        const end_span = if (else_expr) |else_node| self.spanOfNode(else_node) else self.spanOfNode(then_expr);
        return self.allocNode(.{ .if_ = if_data }, coverSpans(if_span, end_span));
    }
};

pub const ParseReport = struct {
    parsed: ?ParsedAst,
    diagnostic: ?diagnostics.Diagnostic,
};

pub fn parseErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UnexpectedCharacter => "unexpected character",
        error.UnexpectedToken => "unexpected token",
        error.ExpectedExpression => "expected expression",
        error.ExpectedIdentifier => "expected identifier",
        error.ExpectedAssign => "expected '=' in const binding",
        error.ExpectedThen => "expected 'then' in if expression",
        error.ExpectedRParen => "expected ')'",
        error.ExpectedLParen => "expected '('",
        error.InvalidArgIndex => "invalid arg() index",
        error.IntegerOverflow => "integer literal out of range",
        error.FloatOverflow => "float literal out of range",
        error.TrailingInput => "trailing input after program",
        error.OutOfMemory => "out of memory while parsing",
        else => "parse error",
    };
}

pub fn parseOwned(source: []const u8, gpa: std.mem.Allocator) (ParseError || error{OutOfMemory})!ParsedAst {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var parser = try Parser.init(source, arena.allocator(), gpa);
    errdefer parser.spans.deinit();
    const root = try parser.parseProgram();

    return .{
        .arena = arena,
        .root = root,
        .spans = parser.spans,
    };
}

const db = @import("db.zig");

pub const ParseMemo = struct {
    value: ?ParsedAst,
    diagnostics: std.ArrayList(diagnostics.Diagnostic),
    deps: std.ArrayList(db.Dependency),
    verified_at: db.Revision,
    changed_at: db.Revision,
    computing: bool,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        if (self.value) |*parsed| parsed.deinit();
        self.diagnostics.deinit(gpa);
        self.deps.deinit(gpa);
    }
};

pub fn computeParse(source: []const u8, gpa: std.mem.Allocator) error{OutOfMemory}!ParseMemo {
    const report = try parseReport(source, gpa);

    var diagnostics_list = try std.ArrayList(diagnostics.Diagnostic).initCapacity(gpa, 1);
    errdefer diagnostics_list.deinit(gpa);
    if (report.diagnostic) |diag| {
        try diagnostics_list.append(gpa, diag);
    }

    return .{
        .value = report.parsed,
        .diagnostics = diagnostics_list,
        .deps = .empty,
        .verified_at = 0,
        .changed_at = 0,
        .computing = false,
    };
}

pub fn parseReport(source: []const u8, gpa: std.mem.Allocator) error{OutOfMemory}!ParseReport {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var parser = Parser.init(source, arena.allocator(), gpa) catch |err| {
        arena.deinit();
        const end = if (source.len > 0) @as(usize, 1) else 0;
        return .{
            .parsed = null,
            .diagnostic = .{
                .stage = .parse,
                .span = .{ .start = 0, .end = end },
                .message = parseErrorMessage(err),
            },
        };
    };
    errdefer parser.spans.deinit();
    const root = parser.parseProgram() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const span = Parser.tokenSpan(parser.current);
            parser.spans.deinit();
            arena.deinit();
            return .{
                .parsed = null,
                .diagnostic = .{
                    .stage = .parse,
                    .span = span,
                    .message = parseErrorMessage(err),
                },
            };
        },
    };

    return .{
        .parsed = .{
            .arena = arena,
            .root = root,
            .spans = parser.spans,
        },
        .diagnostic = null,
    };
}
