const std = @import("std");
const x86 = @import("main.zig");
const AstNode = x86.AstNode;
const IfNode = x86.IfNode;

pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedToken,
    ExpectedExpression,
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
    kw_then,
    kw_else,
    kw_print,
    kw_arg,
    l_paren,
    r_paren,
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
    int_value: u32 = 0,
    float_value: f32 = 0,
};

const Lexer = struct {
    source: []const u8,
    index: usize,

    fn init(source: []const u8) Lexer {
        return .{ .source = source, .index = 0 };
    }

    fn skipWhitespace(self: *@This()) void {
        while (self.index < self.source.len and std.ascii.isWhitespace(self.source[self.index])) {
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
            return .{ .tag = .float_lit, .float_value = value };
        }

        const value = try parseInt(slice);
        return .{ .tag = .int_lit, .int_value = value };
    }

    fn isIdentContinue(char: u8) bool {
        return std.ascii.isAlphanumeric(char) or char == '_';
    }

    fn parseKeywordOrError(self: *@This()) ParseError!Token {
        const start = self.index;
        self.index += 1;
        while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
            self.index += 1;
        }

        const word = self.source[start..self.index];
        if (std.mem.eql(u8, word, "if")) return .{ .tag = .kw_if };
        if (std.mem.eql(u8, word, "then")) return .{ .tag = .kw_then };
        if (std.mem.eql(u8, word, "else")) return .{ .tag = .kw_else };
        if (std.mem.eql(u8, word, "print")) return .{ .tag = .kw_print };
        if (std.mem.eql(u8, word, "arg")) return .{ .tag = .kw_arg };

        return error.UnexpectedCharacter;
    }

    fn next(self: *@This()) ParseError!Token {
        self.skipWhitespace();
        if (self.index >= self.source.len) return .{ .tag = .eof };

        const char = self.source[self.index];

        const dot_prefixed_float = char == '.' and self.index + 1 < self.source.len and std.ascii.isDigit(self.source[self.index + 1]);
        if (std.ascii.isDigit(char) or dot_prefixed_float) return self.parseNumber();
        if (std.ascii.isAlphabetic(char) or char == '_') return self.parseKeywordOrError();

        self.index += 1;
        return switch (char) {
            '(' => .{ .tag = .l_paren },
            ')' => .{ .tag = .r_paren },
            '+' => .{ .tag = .plus },
            '-' => .{ .tag = .minus },
            '*' => .{ .tag = .star },
            '/' => .{ .tag = .slash },
            '<' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .le };
            } else .{ .tag = .lt },
            '>' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .ge };
            } else .{ .tag = .gt },
            '=' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .eq_eq };
            } else error.UnexpectedCharacter,
            '!' => if (self.index < self.source.len and self.source[self.index] == '=') tok: {
                self.index += 1;
                break :tok .{ .tag = .ne };
            } else error.UnexpectedCharacter,
            else => error.UnexpectedCharacter,
        };
    }
};

pub const ParsedAst = struct {
    arena: std.heap.ArenaAllocator,
    root: *const AstNode,

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    lexer: Lexer,
    current: Token,

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

    fn init(source: []const u8, arena: std.mem.Allocator) ParseError!Parser {
        var lexer = Lexer.init(source);
        const current = try lexer.next();
        return .{
            .arena = arena,
            .lexer = lexer,
            .current = current,
        };
    }

    fn advance(self: *@This()) ParseError!void {
        self.current = try self.lexer.next();
    }

    fn expect(self: *@This(), tag: TokenTag, err: ParseError) ParseError!void {
        if (self.current.tag != tag) return err;
        try self.advance();
    }

    fn allocNode(self: *@This(), node: AstNode) error{OutOfMemory}!*const AstNode {
        const ptr = try self.arena.create(AstNode);
        ptr.* = node;
        return ptr;
    }

    fn allocKids(self: *@This(), left: *const AstNode, right: *const AstNode) error{OutOfMemory}!*const [2]AstNode {
        const kids = try self.arena.create([2]AstNode);
        kids[0] = left.*;
        kids[1] = right.*;
        return kids;
    }

    fn makeBinop(self: *@This(), tag: BinTag, left: *const AstNode, right: *const AstNode) error{OutOfMemory}!*const AstNode {
        const kids = try self.allocKids(left, right);
        return switch (tag) {
            .add => self.allocNode(.{ .add = kids }),
            .sub => self.allocNode(.{ .sub = kids }),
            .mul => self.allocNode(.{ .mul = kids }),
            .div => self.allocNode(.{ .div = kids }),
            .lt => self.allocNode(.{ .lt = kids }),
            .gt => self.allocNode(.{ .gt = kids }),
            .le => self.allocNode(.{ .le = kids }),
            .ge => self.allocNode(.{ .ge = kids }),
            .eq => self.allocNode(.{ .eq = kids }),
            .ne => self.allocNode(.{ .ne = kids }),
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
        const root = try self.parseExpression();
        if (self.current.tag != .eof) return error.TrailingInput;
        return root;
    }

    fn parseExpression(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        return self.parseComparison();
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
            try self.advance();

            if (self.current.tag == .int_lit) {
                const value = try negatedIntFromToken(self.current);
                try self.advance();
                return self.allocNode(.{ .int = value });
            }

            if (self.current.tag == .float_lit) {
                const value = negatedFloatFromToken(self.current);
                try self.advance();
                return self.allocNode(.{ .float = value });
            }

            const operand = try self.parseUnary();
            const zero = try self.allocNode(.{ .int = 0 });
            return self.makeBinop(.sub, zero, operand);
        }

        return self.parsePrimary();
    }

    fn parsePrimary(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        switch (self.current.tag) {
            .int_lit => {
                const value = try intFromToken(self.current);
                try self.advance();
                return self.allocNode(.{ .int = value });
            },
            .float_lit => {
                const value = self.current.float_value;
                try self.advance();
                return self.allocNode(.{ .float = value });
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
            else => return error.ExpectedExpression,
        }
    }

    fn parsePrint(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        try self.expect(.kw_print, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);
        const expr = try self.parseExpression();
        try self.expect(.r_paren, error.ExpectedRParen);
        return self.allocNode(.{ .print = expr });
    }

    fn parseArg(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        try self.expect(.kw_arg, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);

        if (self.current.tag != .int_lit) return error.InvalidArgIndex;
        const idx: u32 = self.current.int_value;
        const max_arg_index = std.math.maxInt(u32) / 8;
        if (idx > max_arg_index) return error.InvalidArgIndex;
        try self.advance();

        try self.expect(.r_paren, error.ExpectedRParen);
        return self.allocNode(.{ .arg = idx });
    }

    fn parseIf(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
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
        return self.allocNode(.{ .if_ = if_data });
    }
};

pub fn parseOwned(source: []const u8, gpa: std.mem.Allocator) (ParseError || error{OutOfMemory})!ParsedAst {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var parser = try Parser.init(source, arena.allocator());
    const root = try parser.parseProgram();

    return .{
        .arena = arena,
        .root = root,
    };
}
