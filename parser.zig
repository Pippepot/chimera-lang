const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const AstNode = ast.AstNode;
const IfNode = ast.IfNode;
const VarNode = ast.VarNode;
const ConstNode = ast.ConstNode;
const ReturnNode = ast.ReturnNode;
const CallNode = ast.CallNode;
const BlockNode = ast.BlockNode;
const Module = ast.Module;
const Decl = ast.Decl;
const FuncDecl = ast.FuncDecl;
const StructDecl = ast.StructDecl;
const ParamNode = ast.ParamNode;
const FieldNode = ast.FieldNode;
const TypeNode = ast.TypeNode;
const FuncTypeNode = ast.FuncTypeNode;
const FieldInit = ast.FieldInit;
const StructInitNode = ast.StructInitNode;
const FieldAccessNode = ast.FieldAccessNode;

pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedToken,
    ExpectedDeclaration,
    ExpectedExpression,
    ExpectedIdentifier,
    ExpectedAssign,
    ExpectedRParen,
    ExpectedLParen,
    ExpectedColon,
    ExpectedComma,
    ExpectedType,
    ExpectedIndent,
    InvalidArgIndex,
    IntegerOverflow,
    FloatOverflow,
    TrailingInput,
    UnterminatedString,
    InvalidEscape,
};

const TokenTag = enum {
    eof,
    int_lit,
    float_lit,
    kw_if,
    kw_else,
    kw_const,
    kw_var,
    kw_return,
    kw_print,
    kw_arg,
    kw_true,
    kw_false,
    kw_comptime,
    kw_func,
    kw_struct,
    ident,
    l_paren,
    r_paren,
    newline,
    arrow,
    indent,
    dedent,
    assign,
    colon,
    comma,
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
    l_brace,
    r_brace,
    dot,
    string_lit,
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
    indent_levels: [64]usize,
    indent_len: usize,
    pending_dedent: usize,
    at_line_start: bool,

    fn init(source: []const u8) Lexer {
        var levels: [64]usize = undefined;
        levels[0] = 0;
        return .{
            .source = source,
            .index = 0,
            .indent_levels = levels,
            .indent_len = 1,
            .pending_dedent = 0,
            .at_line_start = true,
        };
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

    fn parseString(self: *@This()) ParseError!Token {
        const start = self.index - 1;
        const content_start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '"') {
            if (self.source[self.index] == '\\') {
                self.index += 1;
                if (self.index >= self.source.len) return error.UnterminatedString;
            }
            self.index += 1;
        }
        if (self.index >= self.source.len) return error.UnterminatedString;
        const ident = self.source[content_start..self.index];
        const end = self.index + 1;
        self.index += 1;
        return .{ .tag = .string_lit, .start = start, .end = end, .ident = ident };
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
        if (std.mem.eql(u8, word, "else")) return .{ .tag = .kw_else, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "const")) return .{ .tag = .kw_const, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "var")) return .{ .tag = .kw_var, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "return")) return .{ .tag = .kw_return, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "print")) return .{ .tag = .kw_print, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "arg")) return .{ .tag = .kw_arg, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "true")) return .{ .tag = .kw_true, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "false")) return .{ .tag = .kw_false, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "comptime")) return .{ .tag = .kw_comptime, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "func")) return .{ .tag = .kw_func, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "struct")) return .{ .tag = .kw_struct, .start = start, .end = self.index };
        return .{ .tag = .ident, .start = start, .end = self.index, .ident = word };
    }

    fn next(self: *@This()) ParseError!Token {
        if (self.pending_dedent > 0) {
            self.pending_dedent -= 1;
            return .{ .tag = .dedent, .start = self.index, .end = self.index };
        }

        if (self.at_line_start) {
            self.at_line_start = false;
            const start = self.index;
            while (self.index < self.source.len and self.source[self.index] == ' ') {
                self.index += 1;
            }
            const indent = self.index - start;

            if (self.index >= self.source.len) {
                if (self.indent_len > 1) {
                    self.indent_len -= 1;
                    self.pending_dedent = self.indent_len - 1;
                    return .{ .tag = .dedent, .start = self.source.len, .end = self.source.len };
                }
                return .{ .tag = .eof, .start = self.source.len, .end = self.source.len };
            }

            if (self.source[self.index] == '\n') {
                self.index += 1;
                self.at_line_start = true;
                return self.next();
            }

            const top = self.indent_levels[self.indent_len - 1];
            if (indent > top) {
                self.indent_levels[self.indent_len] = indent;
                self.indent_len += 1;
                return .{ .tag = .indent, .start = start, .end = self.index };
            }
            if (indent < top) {
                while (self.indent_len > 1 and indent < self.indent_levels[self.indent_len - 1]) {
                    self.indent_len -= 1;
                    self.pending_dedent += 1;
                }
                self.pending_dedent -= 1;
                return .{ .tag = .dedent, .start = start, .end = self.index };
            }
        }

        self.skipInlineWhitespace();
        if (self.index >= self.source.len) {
            if (self.indent_len > 1) {
                self.indent_len -= 1;
                self.pending_dedent = self.indent_len - 1;
                return .{ .tag = .dedent, .start = self.source.len, .end = self.source.len };
            }
            return .{ .tag = .eof, .start = self.source.len, .end = self.source.len };
        }

        const char = self.source[self.index];
        if (char == '\n') {
            const start = self.index;
            self.index += 1;
            self.at_line_start = true;
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
            '{' => .{ .tag = .l_brace, .start = start, .end = self.index },
            '}' => .{ .tag = .r_brace, .start = start, .end = self.index },
            ':' => .{ .tag = .colon, .start = start, .end = self.index },
            ',' => .{ .tag = .comma, .start = start, .end = self.index },
            '.' => .{ .tag = .dot, .start = start, .end = self.index },
            '"' => return self.parseString(),
            '+' => .{ .tag = .plus, .start = start, .end = self.index },
            '-' => if (self.index < self.source.len and self.source[self.index] == '>') arrow: {
                self.index += 1;
                break :arrow .{ .tag = .arrow, .start = start, .end = self.index };
            } else .{ .tag = .minus, .start = start, .end = self.index },
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
    root: *const Module,
    spans: std.AutoHashMap(usize, ast.Span),

    pub fn deinit(self: *@This()) void {
        self.spans.deinit();
        self.arena.deinit();
    }

    pub fn spanOfNode(self: *const @This(), node: *const AstNode) ?ast.Span {
        return self.spans.get(@intFromPtr(node));
    }

    pub fn spanOfAny(self: *const @This(), ptr_key: usize) ?ast.Span {
        return self.spans.get(ptr_key);
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

    fn spanOfAny(self: *const @This(), ptr: usize) ast.Span {
        return self.spans.get(ptr) orelse .{ .start = 0, .end = 0 };
    }

    fn spanOfNode(self: *const @This(), node: *const AstNode) ast.Span {
        return self.spanOfAny(@intFromPtr(node));
    }

    fn coverSpans(start: ast.Span, end: ast.Span) ast.Span {
        return .{ .start = start.start, .end = end.end };
    }

    fn putSpan(self: *@This(), ptr: usize, span: ast.Span) error{OutOfMemory}!void {
        try self.spans.put(ptr, span);
    }

    fn allocNode(self: *@This(), node: AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const ptr = try self.arena.create(AstNode);
        ptr.* = node;
        try self.putSpan(@intFromPtr(ptr), span);
        return ptr;
    }

    fn allocDecl(self: *@This(), decl: Decl, span: ast.Span) error{OutOfMemory}!*const Decl {
        const ptr = try self.arena.create(Decl);
        ptr.* = decl;
        try self.putSpan(@intFromPtr(ptr), span);
        return ptr;
    }

    fn allocType(self: *@This(), ty: TypeNode, span: ast.Span) error{OutOfMemory}!*const TypeNode {
        const ptr = try self.arena.create(TypeNode);
        ptr.* = ty;
        try self.putSpan(@intFromPtr(ptr), span);
        return ptr;
    }

    fn allocName(self: *@This(), name: []const u8) error{OutOfMemory}![]const u8 {
        return try self.arena.dupe(u8, name);
    }

    fn allocKids(self: *@This(), left: *const AstNode, right: *const AstNode) error{OutOfMemory}!*const [2]AstNode {
        const kids = try self.arena.create([2]AstNode);
        kids[0] = left.*;
        kids[1] = right.*;
        try self.putSpan(@intFromPtr(&kids[0]), self.spanOfNode(left));
        try self.putSpan(@intFromPtr(&kids[1]), self.spanOfNode(right));
        return kids;
    }

    fn makeBlockNode(self: *@This(), items: []const *const AstNode) error{OutOfMemory}!*const AstNode {
        const block = try self.arena.create(BlockNode);
        const owned_items = try self.arena.alloc(*const AstNode, items.len);
        @memcpy(owned_items, items);
        block.* = .{ .items = owned_items };

        const span = if (items.len == 0)
            ast.Span{ .start = self.lexer.index, .end = self.lexer.index }
        else
            coverSpans(self.spanOfNode(items[0]), self.spanOfNode(items[items.len - 1]));
        return self.allocNode(.{ .block = block }, span);
    }

    fn makeConstNode(self: *@This(), name: []const u8, ty: ?*const TypeNode, value: *const AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const data = try self.arena.create(ConstNode);
        data.* = .{
            .name = try self.allocName(name),
            .ty = ty,
            .value = value,
        };
        return self.allocNode(.{ .const_ = data }, span);
    }

    fn makeVarNode(self: *@This(), name: []const u8, ty: ?*const TypeNode, value: *const AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const data = try self.arena.create(VarNode);
        data.* = .{
            .name = try self.allocName(name),
            .ty = ty,
            .value = value,
        };
        return self.allocNode(.{ .var_ = data }, span);
    }

    fn makeAssignNode(self: *@This(), name: []const u8, value: *const AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const data = try self.arena.create(VarNode);
        data.* = .{ .name = try self.allocName(name), .ty = null, .value = value };
        return self.allocNode(.{ .assign = data }, span);
    }

    fn makeReturnNode(self: *@This(), value: *const AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const data = try self.arena.create(ReturnNode);
        data.* = .{ .value = value };
        return self.allocNode(.{ .return_ = data }, span);
    }

    fn makeCallNode(self: *@This(), callee: *const AstNode, args: []const *const AstNode, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const owned_args = try self.arena.alloc(*const AstNode, args.len);
        @memcpy(owned_args, args);
        const call = try self.arena.create(CallNode);
        call.* = .{ .callee = callee, .args = owned_args };
        return self.allocNode(.{ .call = call }, span);
    }

    fn makeStructInitNode(self: *@This(), struct_name: []const u8, fields: []const FieldInit, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const owned_name = try self.allocName(struct_name);
        const owned_fields = try self.arena.alloc(FieldInit, fields.len);
        for (fields, 0..) |f, i| {
            owned_fields[i] = .{ .name = try self.allocName(f.name), .value = f.value };
        }
        const data = try self.arena.create(StructInitNode);
        data.* = .{ .struct_name = owned_name, .fields = owned_fields };
        return self.allocNode(.{ .struct_init = data }, span);
    }

    fn makeFieldAccessNode(self: *@This(), target: *const AstNode, field: []const u8, span: ast.Span) error{OutOfMemory}!*const AstNode {
        const data = try self.arena.create(FieldAccessNode);
        data.* = .{ .target = target, .field = try self.allocName(field) };
        return self.allocNode(.{ .field_access = data }, span);
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

    fn consumeNewlines(self: *@This()) ParseError!void {
        while (self.current.tag == .newline) {
            try self.advance();
        }
    }

    fn parseProgram(self: *@This()) (ParseError || error{OutOfMemory})!*const Module {
        try self.consumeNewlines();

        var decls = std.ArrayList(*const Decl).empty;
        while (self.current.tag == .kw_comptime) {
            const decl = try self.parseDeclaration();
            try decls.append(self.arena, decl);
            try self.consumeNewlines();
        }
        const entry = try self.parseBlockUntil();
        try self.consumeNewlines();
        if (self.current.tag != .eof) return error.TrailingInput;

        const module = try self.arena.create(Module);
        const owned_decls = try self.arena.alloc(*const Decl, decls.items.len);
        @memcpy(owned_decls, decls.items);
        module.* = .{ .decls = owned_decls, .entry = entry };

        if (decls.items.len > 0) {
            const start_span = self.spanOfAny(@intFromPtr(decls.items[0]));
            const end_span = if (entry.* == .unit) self.spanOfAny(@intFromPtr(decls.items[decls.items.len - 1])) else self.spanOfNode(entry);
            try self.putSpan(@intFromPtr(module), coverSpans(start_span, end_span));
        } else {
            try self.putSpan(@intFromPtr(module), self.spanOfNode(entry));
        }

        return module;
    }

    fn parseDeclaration(self: *@This()) (ParseError || error{OutOfMemory})!*const Decl {
        if (self.current.tag != .kw_comptime) return error.ExpectedDeclaration;
        const decl_start = tokenSpan(self.current);
        try self.advance();

        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const name = try self.allocName(self.current.ident);
        try self.advance();

        try self.expect(.assign, error.ExpectedAssign);

        if (self.current.tag == .kw_func) {
            return self.parseComptimeFunc(name, decl_start);
        }
        if (self.current.tag == .kw_struct) {
            return self.parseComptimeStruct(name, decl_start);
        }
        return error.ExpectedDeclaration;
    }

    fn parseComptimeFunc(self: *@This(), name: []const u8, decl_start: ast.Span) (ParseError || error{OutOfMemory})!*const Decl {
        try self.expect(.kw_func, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);

        var params = std.ArrayList(ParamNode).empty;
        while (self.current.tag != .r_paren) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const param_name = try self.allocName(self.current.ident);
            const param_start = tokenSpan(self.current);
            try self.advance();
            try self.expect(.colon, error.ExpectedColon);
            const ty = try self.parseType();
            try params.append(self.arena, .{ .name = param_name, .ty = ty });

            if (self.current.tag == .comma) {
                try self.advance();
            } else if (self.current.tag != .r_paren) {
                return error.ExpectedComma;
            }
            const param_span = coverSpans(param_start, self.spanOfAny(@intFromPtr(ty)));
            try self.putSpan(@intFromPtr(&params.items[params.items.len - 1]), param_span);
        }

        try self.expect(.r_paren, error.ExpectedRParen);
        const ret_ty = try self.parseType();

        try self.consumeNewlines();
        if (self.current.tag != .indent) return error.ExpectedIndent;
        try self.advance();
        const body = try self.parseBlockUntil();
        try self.consumeNewlines();
        try self.expect(.dedent, error.ExpectedIndent);

        const owned_params = try self.arena.alloc(ParamNode, params.items.len);
        @memcpy(owned_params, params.items);

        const func = try self.arena.create(FuncDecl);
        func.* = .{
            .name = name,
            .params = owned_params,
            .ret_type = ret_ty,
            .body = body,
        };

        const span = coverSpans(decl_start, self.spanOfNode(body));
        try self.putSpan(@intFromPtr(func), span);
        return self.allocDecl(.{ .comptime_func = func }, span);
    }

    fn parseComptimeStruct(self: *@This(), name: []const u8, decl_start: ast.Span) (ParseError || error{OutOfMemory})!*const Decl {
        try self.expect(.kw_struct, error.UnexpectedToken);

        try self.consumeNewlines();
        if (self.current.tag != .indent) return error.ExpectedIndent;
        try self.advance();

        var fields = std.ArrayList(FieldNode).empty;
        while (self.current.tag != .dedent and self.current.tag != .eof) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const field_name = try self.allocName(self.current.ident);
            const field_start = tokenSpan(self.current);
            try self.advance();
            try self.expect(.colon, error.ExpectedColon);
            const field_ty = try self.parseType();
            try fields.append(self.arena, .{ .name = field_name, .ty = field_ty });
            const field_span = coverSpans(field_start, self.spanOfAny(@intFromPtr(field_ty)));
            try self.putSpan(@intFromPtr(&fields.items[fields.items.len - 1]), field_span);
            if (self.current.tag == .newline) {
                try self.consumeNewlines();
            } else if (self.current.tag != .dedent) {
                return error.UnexpectedToken;
            }
        }

        try self.expect(.dedent, error.ExpectedIndent);

        const owned_fields = try self.arena.alloc(FieldNode, fields.items.len);
        @memcpy(owned_fields, fields.items);

        const st = try self.arena.create(StructDecl);
        st.* = .{
            .name = name,
            .fields = owned_fields,
        };

        const struct_span = if (fields.items.len > 0)
            coverSpans(decl_start, self.spanOfAny(@intFromPtr(&fields.items[fields.items.len - 1])))
        else
            decl_start;
        try self.putSpan(@intFromPtr(st), struct_span);
        return self.allocDecl(.{ .comptime_struct = st }, struct_span);
    }

    fn parseType(self: *@This()) (ParseError || error{OutOfMemory})!*const TypeNode {
        switch (self.current.tag) {
            .ident => {
                const span = tokenSpan(self.current);
                const name = try self.allocName(self.current.ident);
                try self.advance();
                return self.allocType(.{ .name = name }, span);
            },
            .kw_func => {
                const fn_span = tokenSpan(self.current);
                try self.advance();
                try self.expect(.l_paren, error.ExpectedLParen);

                var params = std.ArrayList(*const TypeNode).empty;
                while (self.current.tag != .r_paren) {
                    const param_ty = try self.parseType();
                    try params.append(self.arena, param_ty);
                    if (self.current.tag == .comma) {
                        try self.advance();
                    } else if (self.current.tag != .r_paren) {
                        return error.ExpectedComma;
                    }
                }
                try self.expect(.r_paren, error.ExpectedRParen);

                const ret_ty = try self.parseType();

                const owned_params = try self.arena.alloc(*const TypeNode, params.items.len);
                @memcpy(owned_params, params.items);
                const fn_ty = try self.arena.create(FuncTypeNode);
                fn_ty.* = .{
                    .params = owned_params,
                    .ret = ret_ty,
                };
                const span = coverSpans(fn_span, self.spanOfAny(@intFromPtr(ret_ty)));
                try self.putSpan(@intFromPtr(fn_ty), span);
                return self.allocType(.{ .func = fn_ty }, span);
            },
            else => return error.ExpectedType,
        }
    }

    fn parseStatement(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        if (self.current.tag == .kw_const) return self.parseConstBinding();
        if (self.current.tag == .kw_var) return self.parseVarBinding();
        if (self.current.tag == .kw_return) return self.parseReturn();
        return self.parseExpression();
    }

    fn parseBlockUntil(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        try self.consumeNewlines();
        var items = std.ArrayList(*const AstNode).empty;

        while (self.current.tag != .eof and self.current.tag != .r_paren and self.current.tag != .dedent) {
            if (self.current.tag == .kw_else) {
                if (items.items.len == 0) return error.ExpectedExpression;
                const last_idx = items.items.len - 1;
                if (findIfWithoutElse(items.items[last_idx])) |if_node| {
                    try self.advance();
                    try self.consumeNewlines();
                    if (self.current.tag == .indent) {
                        try self.advance();
                        if_node.else_ = try self.parseBlockUntil();
                        try self.consumeNewlines();
                        try self.expect(.dedent, error.ExpectedExpression);
                    } else {
                        if_node.else_ = try self.parseExpression();
                    }
                    if (self.current.tag == .newline) {
                        try self.consumeNewlines();
                    }
                    continue;
                }
                return error.ExpectedExpression;
            }

            const statement = try self.parseStatement();
            try items.append(self.arena, statement);

            if (self.current.tag == .newline) {
                try self.consumeNewlines();
                continue;
            }
            if (self.current.tag == .eof or self.current.tag == .r_paren or self.current.tag == .dedent) break;
            if (self.current.tag == .kw_else) continue;

            const stmt_span = self.spanOfNode(statement);
            const cursor_start = if (self.current.start > self.lexer.source.len) self.lexer.source.len else self.current.start;
            if (cursor_start > stmt_span.end and std.mem.indexOfScalar(u8, self.lexer.source[stmt_span.end..cursor_start], '\n') != null) {
                continue;
            }
            return error.UnexpectedToken;
        }

        if (items.items.len == 0) {
            return self.allocNode(.{ .unit = {} }, .{ .start = self.lexer.index, .end = self.lexer.index });
        }
        return self.makeBlockNode(items.items);
    }

    fn parseExpression(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const node = try self.parseComparison();
        if (self.current.tag == .assign) {
            if (node.* != .var_ref) return error.UnexpectedToken;
            const name = node.var_ref;
            try self.advance();
            const value = try self.parseExpression();
            const span = coverSpans(self.spanOfNode(node), self.spanOfNode(value));
            return self.makeAssignNode(name, value, span);
        }
        return node;
    }

    fn parseReturn(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const ret_span = tokenSpan(self.current);
        try self.expect(.kw_return, error.UnexpectedToken);
        const value = try self.parseExpression();
        return self.makeReturnNode(value, coverSpans(ret_span, self.spanOfNode(value)));
    }

    fn parseConstBinding(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const const_span = tokenSpan(self.current);
        try self.expect(.kw_const, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const ident = self.current.ident;
        try self.advance();
        var binding_ty: ?*const TypeNode = null;
        if (self.current.tag == .colon) {
            try self.advance();
            binding_ty = try self.parseType();
        }
        try self.expect(.assign, error.ExpectedAssign);
        const value = try self.parseExpression();
        const value_span = self.spanOfNode(value);
        switch (self.current.tag) {
            .newline, .eof, .dedent, .r_paren, .kw_else => {},
            else => {
                const cursor_start = if (self.current.start > self.lexer.source.len) self.lexer.source.len else self.current.start;
                if (cursor_start <= value_span.end) return error.UnexpectedToken;
                if (std.mem.indexOfScalar(u8, self.lexer.source[value_span.end..cursor_start], '\n') == null) {
                    return error.UnexpectedToken;
                }
            },
        }
        const end_span = if (binding_ty) |ty| coverSpans(self.spanOfAny(@intFromPtr(ty)), value_span) else value_span;
        const const_node_span = coverSpans(const_span, end_span);
        return self.makeConstNode(ident, binding_ty, value, const_node_span);
    }

    fn parseVarBinding(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const var_span = tokenSpan(self.current);
        try self.expect(.kw_var, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const ident = self.current.ident;
        try self.advance();
        var binding_ty: ?*const TypeNode = null;
        if (self.current.tag == .colon) {
            try self.advance();
            binding_ty = try self.parseType();
        }
        try self.expect(.assign, error.ExpectedAssign);
        const value = try self.parseExpression();
        const value_span = self.spanOfNode(value);
        switch (self.current.tag) {
            .newline, .eof, .dedent, .r_paren, .kw_else => {},
            else => {
                const cursor_start = if (self.current.start > self.lexer.source.len) self.lexer.source.len else self.current.start;
                if (cursor_start <= value_span.end) return error.UnexpectedToken;
                if (std.mem.indexOfScalar(u8, self.lexer.source[value_span.end..cursor_start], '\n') == null) {
                    return error.UnexpectedToken;
                }
            },
        }
        const end_span = if (binding_ty) |ty| coverSpans(self.spanOfAny(@intFromPtr(ty)), value_span) else value_span;
        const var_node_span = coverSpans(var_span, end_span);
        return self.makeVarNode(ident, binding_ty, value, var_node_span);
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
                const value = -self.current.float_value;
                const float_span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.{ .float = value }, coverSpans(minus_span, float_span));
            }

            const operand = try self.parseUnary();
            const zero = try self.allocNode(.{ .int = 0 }, minus_span);
            return self.makeBinop(.sub, zero, operand);
        }

        return self.parsePostfix();
    }

    fn parsePostfix(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.current.tag == .l_paren) {
                const callee_span = self.spanOfNode(expr);
                try self.advance();

                var args = std.ArrayList(*const AstNode).empty;
                while (self.current.tag != .r_paren) {
                    const arg = try self.parseExpression();
                    try args.append(self.arena, arg);
                    if (self.current.tag == .comma) {
                        try self.advance();
                    } else if (self.current.tag != .r_paren) {
                        return error.ExpectedComma;
                    }
                }

                const end_span = tokenSpan(self.current);
                try self.expect(.r_paren, error.ExpectedRParen);
                expr = try self.makeCallNode(expr, args.items, coverSpans(callee_span, end_span));
            } else if (self.current.tag == .l_brace) {
                if (expr.* != .var_ref) return error.ExpectedIdentifier;
                const struct_name = expr.var_ref;
                expr = try self.parseStructInit(struct_name);
            } else if (self.current.tag == .dot) {
                expr = try self.parseFieldAccess(expr);
            } else {
                break;
            }
        }

        return expr;
    }

    fn parseStructInit(self: *@This(), struct_name: []const u8) (ParseError || error{OutOfMemory})!*const AstNode {
        const lbrace_span = tokenSpan(self.current);
        try self.expect(.l_brace, error.UnexpectedToken);

        var fields = std.ArrayList(FieldInit).empty;
        while (self.current.tag != .r_brace) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const field_name = self.current.ident;
            try self.advance();
            try self.expect(.assign, error.ExpectedAssign);
            const value = try self.parseExpression();
            try fields.append(self.arena, .{ .name = field_name, .value = value });

            if (self.current.tag == .comma) {
                try self.advance();
            } else if (self.current.tag != .r_brace) {
                return error.ExpectedComma;
            }
        }

        const end_span = tokenSpan(self.current);
        try self.expect(.r_brace, error.UnexpectedToken);
        const span = coverSpans(lbrace_span, end_span);
        return self.makeStructInitNode(struct_name, fields.items, span);
    }

    fn parseFieldAccess(self: *@This(), target: *const AstNode) (ParseError || error{OutOfMemory})!*const AstNode {
        const dot_span = tokenSpan(self.current);
        try self.expect(.dot, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const field_name = self.current.ident;
        try self.advance();
        const end_span = tokenSpan(self.current);
        return self.makeFieldAccessNode(target, field_name, coverSpans(dot_span, end_span));
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
            .string_lit => {
                const span = tokenSpan(self.current);
                const raw = self.current.ident;
                var final_len: usize = 0;
                var i: usize = 0;
                while (i < raw.len) : (i += 1) {
                    if (raw[i] == '\\') {
                        i += 1;
                        if (i >= raw.len) return error.UnterminatedString;
                    }
                    final_len += 1;
                }
                const final_str = try self.arena.alloc(u8, final_len);
                var j: usize = 0;
                i = 0;
                while (i < raw.len) : (i += 1) {
                    if (raw[i] == '\\') {
                        i += 1;
                        final_str[j] = switch (raw[i]) {
                            'n' => '\n',
                            't' => '\t',
                            '\\' => '\\',
                            '"' => '"',
                            '0' => 0,
                            else => return error.InvalidEscape,
                        };
                    } else {
                        final_str[j] = raw[i];
                    }
                    j += 1;
                }
                try self.advance();
                return self.allocNode(.{ .string = final_str }, span);
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

    fn findIfWithoutElse(node: *const AstNode) ?*ast.IfNode {
        return switch (node.*) {
            .if_ => |if_node| if (if_node.else_ == null) @constCast(if_node) else null,
            else => null,
        };
    }

    fn parseIf(self: *@This()) (ParseError || error{OutOfMemory})!*const AstNode {
        const if_span = tokenSpan(self.current);
        try self.expect(.kw_if, error.UnexpectedToken);

        const cond = try self.parseExpression();

        const then_expr = if (self.current.tag == .arrow) then_body: {
            try self.advance();
            break :then_body try self.parseExpression();
        } else then_body: {
            try self.consumeNewlines();
            try self.expect(.indent, error.ExpectedExpression);
            const body = try self.parseBlockUntil();
            try self.consumeNewlines();
            try self.expect(.dedent, error.ExpectedExpression);
            break :then_body body;
        };

        var else_expr: ?*const AstNode = null;
        if (self.current.tag == .kw_else) {
            try self.advance();
            try self.consumeNewlines();
            if (self.current.tag == .indent) {
                try self.advance();
                else_expr = try self.parseBlockUntil();
                try self.consumeNewlines();
                try self.expect(.dedent, error.ExpectedExpression);
            } else {
                else_expr = try self.parseExpression();
            }
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
        error.ExpectedDeclaration => "expected declaration",
        error.ExpectedExpression => "expected expression",
        error.ExpectedIdentifier => "expected identifier",
        error.ExpectedAssign => "expected '='",
        error.ExpectedRParen => "expected ')'",
        error.ExpectedLParen => "expected '('",
        error.ExpectedColon => "expected ':'",
        error.ExpectedComma => "expected ','",
        error.ExpectedType => "expected type",
        error.ExpectedIndent => "expected indented block",
        error.InvalidArgIndex => "invalid arg() index",
        error.IntegerOverflow => "integer literal out of range",
        error.FloatOverflow => "float literal out of range",
        error.TrailingInput => "trailing input after program",
        error.UnterminatedString => "unterminated string literal",
        error.InvalidEscape => "invalid escape sequence in string",
        error.OutOfMemory => "out of memory while parsing",
        else => "parse error",
    };
}

pub fn parseOwned(source: []const u8, gpa: std.mem.Allocator) (ParseError || error{OutOfMemory})!ParsedAst {
    const report = try parseReport(source, gpa);
    return report.parsed orelse error.ExpectedExpression;
}

const db = @import("db.zig");

pub const ParseMemo = db.Memo(ParsedAst);

pub fn computeParse(source: []const u8, gpa: std.mem.Allocator) error{OutOfMemory}!ParseMemo {
    const report = try parseReport(source, gpa);

    var diagnostics_list = try db.initDiagnosticList(gpa, &.{}, 1);
    errdefer diagnostics_list.deinit(gpa);
    if (report.diagnostic) |diag| {
        try diagnostics_list.append(gpa, diag);
    }

    return db.makeMemo(ParsedAst, report.parsed, diagnostics_list);
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
