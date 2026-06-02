const std = @import("std");
const ast = @import("ast.zig");
const db = @import("db.zig");

const AstNode = ast.Node;
const Tag = ast.Tag;
const NodeIdx = ast.NodeIdx;
const IdentIdx = ast.IdentIdx;
const Span = ast.Span;

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
    OutOfMemory,
};

const TokenTag = enum {
    eof,
    int_lit,
    float_lit,
    kw_if,
    kw_else,
    kw_const,
    kw_var,
    kw_read,
    kw_mut,
    kw_deinit,
    kw_return,
    kw_print,
    kw_arg,
    kw_true,
    kw_false,
    kw_comptime,
    kw_func,
    kw_struct,
    kw_is,
    kw_as,
    kw_and,
    kw_or,
    kw_not,
    kw_none,
    kw_sizeof,
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
    pipe,
    caret,
    question,
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
        if (std.mem.eql(u8, word, "read")) return .{ .tag = .kw_read, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "mut")) return .{ .tag = .kw_mut, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "deinit")) return .{ .tag = .kw_deinit, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "return")) return .{ .tag = .kw_return, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "print")) return .{ .tag = .kw_print, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "arg")) return .{ .tag = .kw_arg, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "true")) return .{ .tag = .kw_true, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "false")) return .{ .tag = .kw_false, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "comptime")) return .{ .tag = .kw_comptime, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "func")) return .{ .tag = .kw_func, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "struct")) return .{ .tag = .kw_struct, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "is")) return .{ .tag = .kw_is, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "as")) return .{ .tag = .kw_as, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "and")) return .{ .tag = .kw_and, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "or")) return .{ .tag = .kw_or, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "not")) return .{ .tag = .kw_not, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "none")) return .{ .tag = .kw_none, .start = start, .end = self.index };
        if (std.mem.eql(u8, word, "sizeof")) return .{ .tag = .kw_sizeof, .start = start, .end = self.index };
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
            '|' => .{ .tag = .pipe, .start = start, .end = self.index },
            '^' => .{ .tag = .caret, .start = start, .end = self.index },
            '?' => .{ .tag = .question, .start = start, .end = self.index },
            '#' => {
                while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.index += 1;
                }
                if (self.index < self.source.len) {
                    self.index += 1;
                    self.at_line_start = true;
                }
                return self.next();
            },
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

pub const AstBuilder = struct {
    gpa: std.mem.Allocator,
    temp_arena: std.heap.ArenaAllocator,

    nodes: std.ArrayList(ast.Node),
    extra: std.ArrayList(u32),
    ident_bytes: std.ArrayList(u8),
    ident_offsets: std.ArrayList(u32),
    ident_map: std.StringHashMap(IdentIdx),
    spans: std.ArrayList(ast.Span),
    decls: std.ArrayList(NodeIdx),

    pub fn init(gpa: std.mem.Allocator) AstBuilder {
        return .{
            .gpa = gpa,
            .temp_arena = std.heap.ArenaAllocator.init(gpa),
            .nodes = .empty,
            .extra = .empty,
            .ident_bytes = .empty,
            .ident_offsets = .empty,
            .ident_map = std.StringHashMap(IdentIdx).init(gpa),
            .spans = .empty,
            .decls = .empty,
        };
    }

    pub fn deinit(self: *AstBuilder) void {
        self.nodes.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.ident_bytes.deinit(self.gpa);
        self.ident_offsets.deinit(self.gpa);
        self.ident_map.deinit();
        self.spans.deinit(self.gpa);
        self.decls.deinit(self.gpa);
        self.temp_arena.deinit();
    }

    pub fn internIdent(self: *AstBuilder, s: []const u8) !IdentIdx {
        if (self.ident_map.get(s)) |idx| return idx;
        const idx: IdentIdx = @intCast(self.ident_offsets.items.len);
        try self.ident_offsets.append(self.gpa, @intCast(self.ident_bytes.items.len));
        try self.ident_bytes.appendSlice(self.gpa, s);
        const owned = try self.temp_arena.allocator().dupe(u8, s);
        try self.ident_map.put(owned, idx);
        return idx;
    }

    pub fn allocNode(self: *AstBuilder, tag: Tag, data0: u32, data1: u32, span: ast.Span) !NodeIdx {
        const idx: NodeIdx = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{ .tag = tag, ._pad = .{ 0, 0, 0 }, .data0 = data0, .data1 = data1 });
        try self.spans.append(self.gpa, span);
        return idx;
    }

    pub fn identOf(self: *const AstBuilder, idx: IdentIdx) []const u8 {
        const start = self.ident_offsets.items[idx];
        const end = if (idx + 1 < self.ident_offsets.items.len)
            self.ident_offsets.items[idx + 1]
        else
            @as(u32, @intCast(self.ident_bytes.items.len));
        return self.ident_bytes.items[start..end];
    }

    pub fn allocExtraSingle(self: *AstBuilder, value: u32) !u32 {
        const idx: u32 = @intCast(self.extra.items.len);
        try self.extra.append(self.gpa, value);
        return idx;
    }

    pub fn allocExtraSlice(self: *AstBuilder, values: []const u32) !u32 {
        const idx: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.gpa, values);
        return idx;
    }

    pub fn allocExtraPair(self: *AstBuilder, a: u32, b: u32) !u32 {
        const idx: u32 = @intCast(self.extra.items.len);
        try self.extra.append(self.gpa, a);
        try self.extra.append(self.gpa, b);
        return idx;
    }

    pub fn seal(self: *AstBuilder, entry: NodeIdx) !ast.Ast {
        const decls_slice = try self.decls.toOwnedSlice(self.gpa);
        defer self.gpa.free(decls_slice);
        const nodes = try self.nodes.toOwnedSlice(self.gpa);
        defer self.gpa.free(nodes);
        const extra = try self.extra.toOwnedSlice(self.gpa);
        defer self.gpa.free(extra);
        const ident_bytes = try self.ident_bytes.toOwnedSlice(self.gpa);
        defer self.gpa.free(ident_bytes);
        const ident_offsets = try self.ident_offsets.toOwnedSlice(self.gpa);
        defer self.gpa.free(ident_offsets);
        const spans = try self.spans.toOwnedSlice(self.gpa);
        defer self.gpa.free(spans);

        const layout = ast.Ast.computedSize(
            @intCast(nodes.len), @intCast(extra.len),
            @intCast(ident_bytes.len), @intCast(ident_offsets.len),
            @intCast(spans.len), @intCast(decls_slice.len),
        );

        const backing = try self.gpa.alloc(u8, layout.total);
        errdefer self.gpa.free(backing);
        @memset(backing, 0);
        const hdr: *ast.Ast.Header = @ptrCast(@alignCast(backing.ptr));
        hdr.* = .{
            .nodes_len = @intCast(nodes.len),
            .extra_len = @intCast(extra.len),
            .str_bytes_len = @intCast(ident_bytes.len),
            .str_offs_len = @intCast(ident_offsets.len),
            .spans_len = @intCast(spans.len),
            .decls_len = @intCast(decls_slice.len),
            .entry = entry,
        };

        @memcpy(backing[layout.nodes_off..][0..nodes.len * @sizeOf(ast.Node)], std.mem.sliceAsBytes(nodes));
        @memcpy(backing[layout.extra_off..][0..extra.len * 4], std.mem.sliceAsBytes(extra));
        @memcpy(backing[layout.str_bytes_off..][0..ident_bytes.len], ident_bytes);
        @memcpy(backing[layout.str_offs_off..][0..ident_offsets.len * 4], std.mem.sliceAsBytes(ident_offsets));
        @memcpy(backing[layout.spans_off..][0..spans.len * @sizeOf(ast.Span)], std.mem.sliceAsBytes(spans));
        @memcpy(backing[layout.decls_off..][0..decls_slice.len * 4], std.mem.sliceAsBytes(decls_slice));

        var name_map = std.StringHashMap(ast.NodeIdx).init(self.gpa);
        errdefer name_map.deinit();
        {
            const ast_nodes = @as([*]ast.Node, @ptrCast(@alignCast(backing.ptr + layout.nodes_off)))[0..nodes.len];
            const str_offs = @as([*]u32, @ptrCast(@alignCast(backing.ptr + layout.str_offs_off)))[0..ident_offsets.len];
            const decls = @as([*]ast.NodeIdx, @ptrCast(@alignCast(backing.ptr + layout.decls_off)))[0..decls_slice.len];
            for (decls) |decl_idx| {
                const name_idx = ast_nodes[decl_idx].data0;
                const start = str_offs[name_idx];
                const end = if (name_idx + 1 < ident_offsets.len) str_offs[name_idx + 1] else @as(u32, @intCast(ident_bytes.len));
                const name = backing[layout.str_bytes_off..][start..end];
                try name_map.put(name, decl_idx);
            }
        }

        return ast.Ast{
            .backing = backing,
            .nodes = @as([*]ast.Node, @ptrCast(@alignCast(backing.ptr + layout.nodes_off)))[0..nodes.len],
            .extra = @as([*]u32, @ptrCast(@alignCast(backing.ptr + layout.extra_off)))[0..extra.len],
            .ident_bytes = backing[layout.str_bytes_off..][0..ident_bytes.len],
            .ident_offsets = @as([*]u32, @ptrCast(@alignCast(backing.ptr + layout.str_offs_off)))[0..ident_offsets.len],
            .spans = @as([*]ast.Span, @ptrCast(@alignCast(backing.ptr + layout.spans_off)))[0..spans.len],
            .decls = @as([*]ast.NodeIdx, @ptrCast(@alignCast(backing.ptr + layout.decls_off)))[0..decls_slice.len],
            .entry = entry,
            .name_map = name_map,
        };
    }
};

pub const ParsedAst = struct {
    arena: std.heap.ArenaAllocator,
    ast: ast.Ast,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.ast.deinit(gpa);
        self.arena.deinit();
    }

    pub fn spanOfNode(self: *const @This(), idx: NodeIdx) ?ast.Span {
        return self.ast.spanOf(idx);
    }
};

const Parser = struct {
    builder: *AstBuilder,
    lexer: Lexer,
    current: Token,
    scratch_arena: std.heap.ArenaAllocator,
    inline_hook_counter: u32,

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
        @"and",
        @"or",
    };

    fn init(source: []const u8, builder: *AstBuilder) ParseError!Parser {
        var lexer = Lexer.init(source);
        const current = try lexer.next();
        return .{
            .builder = builder,
            .lexer = lexer,
            .current = current,
            .scratch_arena = std.heap.ArenaAllocator.init(builder.gpa),
            .inline_hook_counter = 0,
        };
    }

    fn deinit(self: *@This()) void {
        self.scratch_arena.deinit();
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

    fn coverSpans(start: ast.Span, end: ast.Span) ast.Span {
        return .{ .start = start.start, .end = end.end };
    }

    fn allocNode(self: *@This(), tag: Tag, data0: u32, data1: u32, span: ast.Span) !NodeIdx {
        return self.builder.allocNode(tag, data0, data1, span);
    }

    fn internName(self: *@This(), name: []const u8) !u32 {
        return self.builder.internIdent(name);
    }

    fn makeBlockNode(self: *@This(), items: []const NodeIdx) !NodeIdx {
        const count: u32 = @intCast(items.len);
        if (count == 0) {
            const span = ast.Span{ .start = self.lexer.index, .end = self.lexer.index };
            return self.allocNode(.unit_lit, 0, 0, span);
        }
        const span = if (items.len == 0)
            ast.Span{ .start = self.lexer.index, .end = self.lexer.index }
        else
            coverSpans(try self.spanOf(items[0]), try self.spanOf(items[items.len - 1]));
        const extra_idx = try self.builder.allocExtraSlice(items);
        return self.allocNode(.block, extra_idx, count, span);
    }

    fn makeUnitTypeNode(self: *@This(), span: ast.Span) !NodeIdx {
        const unit_name = try self.internName("unit");
        return self.allocNode(.type_name, unit_name, 0, span);
    }

    fn spanOf(self: *const @This(), idx: NodeIdx) !ast.Span {
        if (idx < self.builder.spans.items.len) return self.builder.spans.items[idx];
        return ast.Span{ .start = 0, .end = 0 };
    }

    fn makeBindingNode(self: *@This(), tag: Tag, name: []const u8, ty: ?NodeIdx, value: NodeIdx, span: ast.Span) !NodeIdx {
        const name_idx = try self.internName(name);
        if (ty) |type_idx| {
            const extra_idx = try self.builder.allocExtraPair(type_idx, value);
            return self.allocNode(tag, name_idx, extra_idx | 0x80000000, span);
        }
        return self.allocNode(tag, name_idx, value, span);
    }

    fn makeAssignNode(self: *@This(), name: []const u8, value: NodeIdx, span: ast.Span) !NodeIdx {
        const name_idx = try self.internName(name);
        return self.allocNode(.assign, name_idx, value, span);
    }

    fn makeReturnNode(self: *@This(), value: NodeIdx, span: ast.Span) !NodeIdx {
        return self.allocNode(.return_stmt, value, 0, span);
    }

    fn makeCallNode(self: *@This(), callee: NodeIdx, args: []const NodeIdx, span: ast.Span) !NodeIdx {
        const extra_idx = try self.builder.allocExtraSingle(@intCast(args.len));
        for (args) |arg| {
            try self.builder.extra.append(self.builder.gpa, arg);
        }
        return self.allocNode(.call, callee, extra_idx, span);
    }

    const FieldInfo = struct { name: []const u8, value: NodeIdx };

    fn makeStructInitNode(self: *@This(), struct_name: []const u8, fields: []const FieldInfo, span: ast.Span) !NodeIdx {
        const name_idx = try self.internName(struct_name);
        const count: u32 = @intCast(fields.len);
        try self.builder.extra.append(self.builder.gpa, count);
        for (fields) |f| {
            try self.builder.extra.append(self.builder.gpa, try self.internName(f.name));
            try self.builder.extra.append(self.builder.gpa, f.value);
        }
        const extra_idx: u32 = @intCast(self.builder.extra.items.len - 1 - count * 2);
        return self.allocNode(.struct_init, name_idx, extra_idx, span);
    }

    fn makeFieldAccessNode(self: *@This(), target: NodeIdx, field: []const u8, span: ast.Span) !NodeIdx {
        const field_idx = try self.internName(field);
        return self.allocNode(.field_access, target, field_idx, span);
    }

    fn makeIsNode(self: *@This(), lhs: NodeIdx, rhs_type: ast.TypeIdx) !NodeIdx {
        const span = coverSpans(try self.spanOf(lhs), try self.spanOf(rhs_type));
        return self.allocNode(.is, lhs, rhs_type, span);
    }

    fn makeAsNode(self: *@This(), lhs: NodeIdx, rhs_type: ast.TypeIdx) !NodeIdx {
        const span = coverSpans(try self.spanOf(lhs), try self.spanOf(rhs_type));
        return self.allocNode(.as, lhs, rhs_type, span);
    }

    fn makeBinop(self: *@This(), tag: BinTag, left: NodeIdx, right: NodeIdx) !NodeIdx {
        const node_tag: Tag = switch (tag) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            .@"and" => .@"and",
            .@"or" => .@"or",
        };
        const span = coverSpans(try self.spanOf(left), try self.spanOf(right));
        return self.allocNode(node_tag, left, right, span);
    }

    fn makeVariantTypeNode(self: *@This(), members: []const ast.TypeIdx) !NodeIdx {
        const extra_idx = try self.builder.allocExtraSlice(members);
        const span = coverSpans(try self.spanOf(members[0]), try self.spanOf(members[members.len - 1]));
        return self.allocNode(.type_variant, extra_idx, @intCast(members.len), span);
    }

    fn makeTypeUnionNode(self: *@This(), members: []const NodeIdx) !NodeIdx {
        const extra_idx = try self.builder.allocExtraSlice(members);
        const span = coverSpans(try self.spanOf(members[0]), try self.spanOf(members[members.len - 1]));
        return self.allocNode(.type_union, extra_idx, @intCast(members.len), span);
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

    fn parseIndentedBlock(self: *@This(), err: ParseError) ParseError!NodeIdx {
        try self.consumeNewlines();
        try self.expect(.indent, err);
        const body = try self.parseBlockUntil();
        try self.consumeNewlines();
        try self.expect(.dedent, err);
        return body;
    }

    fn parseOptionalIndentedBlock(self: *@This()) ParseError!NodeIdx {
        try self.consumeNewlines();
        if (self.current.tag == .indent) {
            try self.advance();
            const body = try self.parseBlockUntil();
            try self.consumeNewlines();
            try self.expect(.dedent, error.ExpectedExpression);
            return body;
        }
        return self.parseStatement();
    }

    fn expectStatementTerminated(self: *@This(), stmt_end: usize) ParseError!void {
        switch (self.current.tag) {
            .newline, .eof, .dedent, .r_paren, .kw_else => {},
            else => {
                const cursor_start = if (self.current.start > self.lexer.source.len) self.lexer.source.len else self.current.start;
                if (cursor_start <= stmt_end) return error.UnexpectedToken;
                if (std.mem.indexOfScalar(u8, self.lexer.source[stmt_end..cursor_start], '\n') == null) {
                    return error.UnexpectedToken;
                }
            },
        }
    }

    fn parseProgram(self: *@This()) ParseError!NodeIdx {
        try self.consumeNewlines();
        const entry = try self.parseBlockUntil();
        try self.consumeNewlines();
        if (self.current.tag != .eof) return error.TrailingInput;
        return entry;
    }

    fn parseDeclaration(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag != .kw_comptime) return error.ExpectedDeclaration;
        const decl_start = tokenSpan(self.current);
        try self.advance();

        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const name = self.current.ident;
        try self.advance();

        var binding_ty: ?NodeIdx = null;
        if (self.current.tag == .colon) {
            try self.advance();
            binding_ty = try self.parseType();
        }

        try self.expect(.assign, error.ExpectedAssign);

        if (self.current.tag == .kw_func) {
            return self.parseComptimeFunc(name, binding_ty, decl_start);
        }
        if (self.current.tag == .kw_struct) {
            return self.parseComptimeStruct(name, binding_ty, decl_start);
        }
        return self.parseComptimeValueDecl(name, binding_ty, decl_start);
    }

    fn parseComptimeValueDecl(self: *@This(), name: []const u8, binding_ty: ?NodeIdx, decl_start: ast.Span) ParseError!NodeIdx {
        const name_idx = try self.internName(name);
        const value = try self.parseExpression();
        const span = coverSpans(decl_start, try self.spanOf(value));
        if (binding_ty) |ty| {
            const extra_idx = try self.builder.allocExtraPair(ty, value);
            return self.allocNode(.comptime_value_decl, name_idx, extra_idx | 0x80000000, span);
        }
        return self.allocNode(.comptime_value_decl, name_idx, value, span);
    }

    fn parseComptimeExprAfterKeyword(self: *@This(), start_span: ast.Span) ParseError!NodeIdx {
        const body = if (self.current.tag == .arrow) body: {
            try self.advance();
            break :body try self.parseExpression();
        } else try self.parseIndentedBlock(error.ExpectedExpression);

        const span = coverSpans(start_span, try self.spanOf(body));
        return self.allocNode(.comptime_expr, body, 0, span);
    }

    fn parseComptimeStatement(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag != .kw_comptime) return error.UnexpectedToken;
        const kw_span = tokenSpan(self.current);
        try self.advance();

        if (self.current.tag == .ident) {
            const name = self.current.ident;
            try self.advance();

            var binding_ty: ?NodeIdx = null;
            if (self.current.tag == .colon) {
                try self.advance();
                binding_ty = try self.parseType();
            }

            try self.expect(.assign, error.ExpectedAssign);

            if (self.current.tag == .kw_func) {
                const decl = try self.parseComptimeFunc(name, binding_ty, kw_span);
                try self.builder.decls.append(self.builder.gpa, decl);
                return decl;
            }
            if (self.current.tag == .kw_struct) {
                const decl = try self.parseComptimeStruct(name, binding_ty, kw_span);
                try self.builder.decls.append(self.builder.gpa, decl);
                return decl;
            }

            const decl = try self.parseComptimeValueDecl(name, binding_ty, kw_span);
            try self.builder.decls.append(self.builder.gpa, decl);
            return decl;
        }

        return self.parseComptimeExprAfterKeyword(kw_span);
    }

    const ParsedFnParam = struct {
        name: u32,
        ty: u32,
        is_comptime: bool,
        access_mode: ast.ParamAccessMode,
    };

    fn parseFnParam(self: *@This()) ParseError!ParsedFnParam {
        var is_comptime = false;
        if (self.current.tag == .kw_comptime) {
            is_comptime = true;
            try self.advance();
        }

        var access_mode: ast.ParamAccessMode = .read;
        switch (self.current.tag) {
            .kw_read => {
                access_mode = .read;
                try self.advance();
            },
            .kw_mut => {
                access_mode = .mut;
                try self.advance();
            },
            .kw_var => {
                access_mode = .var_mode;
                try self.advance();
            },
            .kw_deinit => {
                access_mode = .deinit;
                try self.advance();
            },
            else => {},
        }

        if (is_comptime and access_mode != .read) return error.UnexpectedToken;
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const param_name = try self.internName(self.current.ident);
        try self.advance();
        try self.expect(.colon, error.ExpectedColon);
        const ty = try self.parseType();
        return .{
            .name = param_name,
            .ty = ty,
            .is_comptime = is_comptime,
            .access_mode = access_mode,
        };
    }

    fn parseComptimeFunc(self: *@This(), name: []const u8, binding_ty: ?NodeIdx, decl_start: ast.Span) ParseError!NodeIdx {
        try self.expect(.kw_func, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);

        const name_idx = try self.internName(name);

        var param_names = std.ArrayList(u32).empty;
        var param_types = std.ArrayList(u32).empty;
        var comptime_mask: u32 = 0;
        var mut_mask: u32 = 0;
        var var_mask: u32 = 0;
        var deinit_mask: u32 = 0;
        var param_index: u32 = 0;
        while (self.current.tag != .r_paren) {
            const param = try self.parseFnParam();
            try param_names.append(self.scratch_arena.allocator(), param.name);
            try param_types.append(self.scratch_arena.allocator(), param.ty);
            if (param.is_comptime) comptime_mask |= @as(u32, 1) << @intCast(param_index);
            switch (param.access_mode) {
                .read => {},
                .mut => mut_mask |= @as(u32, 1) << @intCast(param_index),
                .var_mode => var_mask |= @as(u32, 1) << @intCast(param_index),
                .deinit => deinit_mask |= @as(u32, 1) << @intCast(param_index),
            }
            param_index += 1;

            if (self.current.tag == .comma) {
                try self.advance();
            } else if (self.current.tag != .r_paren) {
                return error.ExpectedComma;
            }
        }

        try self.expect(.r_paren, error.ExpectedRParen);
        const ret_ty: ast.NodeIdx = if (self.current.tag == .ident or self.current.tag == .kw_func)
            try self.parseType()
        else
            ast.FN_NO_RET_TYPE;

        const body = if (self.current.tag == .arrow) body: {
            try self.advance();
            break :body try self.parseStatement();
        } else try self.parseIndentedBlock(error.ExpectedIndent);

        const param_count: u32 = @intCast(param_names.items.len);
        const extra_start = self.builder.extra.items.len;
        try self.builder.extra.append(self.builder.gpa, param_count);
        try self.builder.extra.append(self.builder.gpa, comptime_mask);
        try self.builder.extra.append(self.builder.gpa, mut_mask);
        try self.builder.extra.append(self.builder.gpa, var_mask);
        try self.builder.extra.append(self.builder.gpa, deinit_mask);
        var i: u32 = 0;
        while (i < param_count) : (i += 1) {
            try self.builder.extra.append(self.builder.gpa, param_names.items[i]);
            try self.builder.extra.append(self.builder.gpa, param_types.items[i]);
        }
        try self.builder.extra.append(self.builder.gpa, ret_ty);
        try self.builder.extra.append(self.builder.gpa, body);
        if (binding_ty) |annot| {
            try self.builder.extra.append(self.builder.gpa, annot);
        }
        const extra_idx: u32 = @intCast(extra_start);
        const data1 = if (binding_ty != null) extra_idx | 0x80000000 else extra_idx;
        const body_span = try self.spanOf(body);
        const span = coverSpans(decl_start, body_span);
        return self.allocNode(.comptime_fn, name_idx, data1, span);
    }

    const StructFields = struct { names: std.ArrayList(u32), types: std.ArrayList(u32) };

    const ParsedStructBody = struct {
        fields: StructFields,
        move_kind: ast.StructMoveKind,
        move_hook: ?u32,
        copy_kind: ast.StructCopyKind,
        copy_hook: ?u32,
        drop_kind: ast.StructDropKind,
        drop_hook: ?u32,
        explicit_mask: u32,
    };

    fn parseStructFields(self: *@This()) ParseError!StructFields {
        try self.consumeNewlines();
        if (self.current.tag != .indent) return error.ExpectedIndent;
        try self.advance();

        var names = std.ArrayList(u32).empty;
        var types = std.ArrayList(u32).empty;
        while (self.current.tag != .dedent and self.current.tag != .eof) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const fname = try self.internName(self.current.ident);
            try self.advance();
            try self.expect(.colon, error.ExpectedColon);
            const fty = try self.parseType();
            try names.append(self.scratch_arena.allocator(), fname);
            try types.append(self.scratch_arena.allocator(), fty);
            if (self.current.tag == .newline) {
                try self.consumeNewlines();
            } else if (self.current.tag != .dedent) {
                return error.UnexpectedToken;
            }
        }
        try self.expect(.dedent, error.ExpectedIndent);
        return .{ .names = names, .types = types };
    }

    fn makeInlineHookName(self: *@This(), struct_name: []const u8, property_name: []const u8) ParseError![]const u8 {
        const n = self.inline_hook_counter;
        self.inline_hook_counter += 1;
        return std.fmt.allocPrint(self.scratch_arena.allocator(), "$hook_{s}_{s}_{d}", .{ struct_name, property_name, n }) catch return error.OutOfMemory;
    }

    fn parseOwnershipHookRef(self: *@This(), struct_name: []const u8, property_name: []const u8, line_start: ast.Span) ParseError!u32 {
        if (self.current.tag == .kw_func) {
            const generated_name = try self.makeInlineHookName(struct_name, property_name);
            const decl = try self.parseComptimeFunc(generated_name, null, line_start);
            try self.builder.decls.append(self.builder.gpa, decl);
            return self.internName(generated_name);
        }
        if (self.current.tag != .ident) return error.UnexpectedToken;
        const hook_name = self.current.ident;
        try self.advance();
        return self.internName(hook_name);
    }

    const PolicyProperty = enum { move, copy, drop };

    fn parsePolicyRhs(self: *@This(), body: *ParsedStructBody, prop: PolicyProperty, struct_name: []const u8, line_start: ast.Span) ParseError!void {
        const is_drop = prop == .drop;
        if (self.current.tag == .ident) {
            const rhs = self.current.ident;
            if (std.mem.eql(u8, rhs, "trivial")) {
                if (is_drop) { body.drop_kind = .trivial; body.drop_hook = null; }
                else if (prop == .move) { body.move_kind = .trivial; body.move_hook = null; }
                else { body.copy_kind = .trivial; body.copy_hook = null; }
                try self.advance(); return;
            }
            if (std.mem.eql(u8, rhs, "fieldwise")) {
                if (is_drop) { body.drop_kind = .fieldwise; body.drop_hook = null; }
                else if (prop == .move) { body.move_kind = .fieldwise; body.move_hook = null; }
                else { body.copy_kind = .fieldwise; body.copy_hook = null; }
                try self.advance(); return;
            }
            if (!is_drop and std.mem.eql(u8, rhs, "none")) {
                if (prop == .move) { body.move_kind = .none; body.move_hook = null; }
                else { body.copy_kind = .none; body.copy_hook = null; }
                try self.advance(); return;
            }
            if (is_drop and std.mem.eql(u8, rhs, "explicit")) {
                body.drop_kind = .explicit; body.drop_hook = null;
                try self.advance(); return;
            }
        }
        if (!is_drop and self.current.tag == .kw_none) {
            if (prop == .move) { body.move_kind = .none; body.move_hook = null; }
            else { body.copy_kind = .none; body.copy_hook = null; }
            try self.advance(); return;
        }
        const hook = try self.parseOwnershipHookRef(struct_name, @tagName(prop), line_start);
        if (is_drop) { body.drop_kind = .func; body.drop_hook = hook; }
        else if (prop == .move) { body.move_kind = .func; body.move_hook = hook; }
        else { body.copy_kind = .func; body.copy_hook = hook; }
    }

    fn parseComptimeStructBody(self: *@This(), struct_name: []const u8) ParseError!ParsedStructBody {
        try self.consumeNewlines();
        if (self.current.tag != .indent) return error.ExpectedIndent;
        try self.advance();

        const names = std.ArrayList(u32).empty;
        const types = std.ArrayList(u32).empty;
        var body = ParsedStructBody{
            .fields = .{ .names = names, .types = types },
            .move_kind = .fieldwise,
            .move_hook = null,
            .copy_kind = .none,
            .copy_hook = null,
            .drop_kind = .trivial,
            .drop_hook = null,
            .explicit_mask = 0,
        };
        var saw_move = false;
        var saw_copy = false;
        var saw_drop = false;
        while (self.current.tag != .dedent and self.current.tag != .eof) {
            try self.consumeNewlines();
            if (self.current.tag == .dedent or self.current.tag == .eof) break;
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const key = self.current.ident;
            const key_span = tokenSpan(self.current);
            try self.advance();

            if (std.mem.eql(u8, key, "move") or std.mem.eql(u8, key, "copy") or std.mem.eql(u8, key, "drop")) {
                try self.expect(.assign, error.UnexpectedToken);
                const prop: PolicyProperty = if (std.mem.eql(u8, key, "move")) .move else if (std.mem.eql(u8, key, "copy")) .copy else .drop;
                const saw_ptr: *bool = switch (prop) { .move => &saw_move, .copy => &saw_copy, .drop => &saw_drop };
                if (saw_ptr.*) return error.UnexpectedToken;
                saw_ptr.* = true;
                body.explicit_mask |= switch (prop) { .move => 0b001, .copy => 0b010, .drop => 0b100 };
                try self.parsePolicyRhs(&body, prop, struct_name, key_span);
            } else {
                const fname = try self.internName(key);
                try self.expect(.colon, error.ExpectedColon);
                const fty = try self.parseType();
                try body.fields.names.append(self.scratch_arena.allocator(), fname);
                try body.fields.types.append(self.scratch_arena.allocator(), fty);
            }

            if (self.current.tag == .newline or self.current.tag == .ident or self.current.tag == .kw_comptime) {
                try self.consumeNewlines();
            }
        }
        try self.expect(.dedent, error.ExpectedIndent);
        return body;
    }

    fn parseComptimeStruct(self: *@This(), name: []const u8, binding_ty: ?NodeIdx, decl_start: ast.Span) ParseError!NodeIdx {
        try self.expect(.kw_struct, error.UnexpectedToken);
        const name_idx = try self.internName(name);
        const body = try self.parseComptimeStructBody(name);

        const field_count: u32 = @intCast(body.fields.names.items.len);
        const extra_start = self.builder.extra.items.len;
        try self.builder.extra.append(self.builder.gpa, field_count);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(body.move_kind));
        try self.builder.extra.append(self.builder.gpa, body.move_hook orelse ast.no_hook_ident);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(body.copy_kind));
        try self.builder.extra.append(self.builder.gpa, body.copy_hook orelse ast.no_hook_ident);
        try self.builder.extra.append(self.builder.gpa, @intFromEnum(body.drop_kind));
        try self.builder.extra.append(self.builder.gpa, body.drop_hook orelse ast.no_hook_ident);
        try self.builder.extra.append(self.builder.gpa, body.explicit_mask);
        for (0..@intCast(field_count)) |i| {
            try self.builder.extra.append(self.builder.gpa, body.fields.names.items[i]);
            try self.builder.extra.append(self.builder.gpa, body.fields.types.items[i]);
        }
        if (binding_ty) |annot| {
            try self.builder.extra.append(self.builder.gpa, annot);
        }
        const extra_idx: u32 = @intCast(extra_start);
        const data1 = if (binding_ty != null) extra_idx | 0x80000000 else extra_idx;
        const span = if (field_count > 0)
            coverSpans(decl_start, try self.spanOf(body.fields.types.items[field_count - 1]))
        else
            decl_start;
        return self.allocNode(.comptime_struct, name_idx, data1, span);
    }

    fn parseTypePrimary(self: *@This()) ParseError!u32 {
        switch (self.current.tag) {
            .ident, .kw_none => {
                const span = tokenSpan(self.current);
                const name = if (self.current.tag == .kw_none) "none" else self.current.ident;
                try self.advance();
                return self.allocNode(.type_name, try self.internName(name), 0, span);
            },
            .kw_func => {
                const fn_span = tokenSpan(self.current);
                try self.advance();
                try self.expect(.l_paren, error.ExpectedLParen);

                var params = std.ArrayList(u32).empty;
                while (self.current.tag != .r_paren) {
                    const param_ty = try self.parseType();
                    try params.append(self.scratch_arena.allocator(), param_ty);
                    if (self.current.tag == .comma) {
                        try self.advance();
                    } else if (self.current.tag != .r_paren) {
                        return error.ExpectedComma;
                    }
                }
                const rp_span = tokenSpan(self.current);
                try self.expect(.r_paren, error.ExpectedRParen);

                const ret_ty = if (self.current.tag == .ident or self.current.tag == .kw_func)
                    try self.parseType()
                else
                    try self.makeUnitTypeNode(rp_span);

                const param_count: u32 = @intCast(params.items.len);
                const extra_idx = try self.builder.allocExtraSlice(params.items);
                try self.builder.extra.append(self.builder.gpa, ret_ty);

                const ret_span = try self.spanOf(ret_ty);
                const span = coverSpans(fn_span, ret_span);
                return self.allocNode(.type_func, extra_idx, param_count, span);
            },
            else => return error.ExpectedType,
        }
    }

    fn parseType(self: *@This()) ParseError!u32 {
        const first = try self.parseTypePrimary();
        if (self.current.tag != .pipe) return first;

        var members = std.ArrayList(u32).empty;
        try members.append(self.scratch_arena.allocator(), first);
        while (self.current.tag == .pipe) {
            try self.advance();
            const next_member = try self.parseTypePrimary();
            try members.append(self.scratch_arena.allocator(), next_member);
        }
        return self.makeVariantTypeNode(members.items);
    }

    const BindingKind = enum { const_kind, var_kind };

    fn parseStatement(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag == .kw_const) return self.parseBinding(.const_kind, true);
        if (self.current.tag == .kw_var) return self.parseBinding(.var_kind, true);
        if (self.current.tag == .kw_return) return self.parseReturn();
        if (self.current.tag == .kw_comptime) return self.parseComptimeStatement();
        return self.parseExpression();
    }

    fn bindCrossLineElse(self: *@This(), items: *const std.ArrayList(NodeIdx)) ParseError!void {
        if (items.items.len == 0) return error.ExpectedExpression;
        const last_idx = items.items.len - 1;
        const if_node_data = findIfWithoutElse(self.builder, items.items[last_idx]) orelse return error.ExpectedExpression;
        try self.advance();
        const else_expr = try self.parseOptionalIndentedBlock();

        const ei = self.builder.extra.items.len;
        try self.builder.extra.append(self.builder.gpa, if_node_data.then_);
        try self.builder.extra.append(self.builder.gpa, else_expr);
        const node = &self.builder.nodes.items[if_node_data.if_idx];
        node.data1 = @intCast(ei);

        if (self.current.tag == .newline) {
            try self.consumeNewlines();
        }
    }

    fn parseBlockUntil(self: *@This()) ParseError!NodeIdx {
        try self.consumeNewlines();
        var items = std.ArrayList(NodeIdx).empty;

        while (self.current.tag != .eof and self.current.tag != .r_paren and self.current.tag != .dedent) {
            if (self.current.tag == .kw_else) {
                try self.bindCrossLineElse(&items);
                continue;
            }

            const statement = try self.parseStatement();
            try items.append(self.scratch_arena.allocator(), statement);

            if (self.current.tag == .newline) {
                try self.consumeNewlines();
                continue;
            }
            if (self.current.tag == .eof or self.current.tag == .r_paren or self.current.tag == .dedent) break;
            if (self.current.tag == .kw_else) continue;

            try self.expectStatementTerminated((try self.spanOf(statement)).end);
            continue;
        }

        return self.makeBlockNode(items.items);
    }

    fn parseExpression(self: *@This()) ParseError!NodeIdx {
        const node = try self.parseTypeUnionExpr();
        if (self.current.tag == .assign) {
            const node_tag = self.builder.nodes.items[node].tag;
            if (node_tag == .var_ref) {
                const name_idx = self.builder.nodes.items[node].data0;
                const name = self.builder.identOf(name_idx);
                try self.advance();
                const value = try self.parseExpression();
                const span = coverSpans(try self.spanOf(node), try self.spanOf(value));
                return self.makeAssignNode(name, value, span);
            }
            if (node_tag == .field_access) {
                try self.advance();
                const value = try self.parseExpression();
                const span = coverSpans(try self.spanOf(node), try self.spanOf(value));
                return self.allocNode(.field_assign, node, value, span);
            }
            return error.UnexpectedToken;
        }
        return node;
    }

    fn parseTypeUnionExpr(self: *@This()) ParseError!NodeIdx {
        const first = try self.parseOr();
        if (self.current.tag != .pipe) return first;

        var members = std.ArrayList(NodeIdx).empty;
        try members.append(self.scratch_arena.allocator(), first);
        while (self.current.tag == .pipe) {
            try self.advance();
            const next_member = try self.parseOr();
            try members.append(self.scratch_arena.allocator(), next_member);
        }
        return self.makeTypeUnionNode(members.items);
    }

    fn parseReturn(self: *@This()) ParseError!NodeIdx {
        const ret_span = tokenSpan(self.current);
        try self.expect(.kw_return, error.UnexpectedToken);
        const value = try self.parseExpression();
        const span = coverSpans(ret_span, try self.spanOf(value));
        return self.makeReturnNode(value, span);
    }

    fn parseBinding(self: *@This(), kind: BindingKind, check_terminated: bool) ParseError!NodeIdx {
        const keyword_span = tokenSpan(self.current);
        const keyword_tag: TokenTag = switch (kind) {
            .const_kind => .kw_const,
            .var_kind => .kw_var,
        };
        try self.expect(keyword_tag, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const ident = self.current.ident;
        try self.advance();
        var binding_ty: ?u32 = null;
        if (self.current.tag == .colon) {
            try self.advance();
            binding_ty = try self.parseType();
        }
        try self.expect(.assign, error.ExpectedAssign);
        const value = try self.parseExpression();
        const value_span = try self.spanOf(value);
        if (check_terminated) try self.expectStatementTerminated(value_span.end);
        const end_span = if (binding_ty) |ty| coverSpans(try self.spanOf(ty), value_span) else value_span;
        const node_span = coverSpans(keyword_span, end_span);
        return self.makeBindingNode(switch (kind) { .const_kind => .const_decl, .var_kind => .var_decl }, ident, binding_ty, value, node_span);
    }

    const BinOpEntry = struct { token: TokenTag, tag: BinTag };

    fn parseBinary(self: *@This(), ops: []const BinOpEntry, next: *const fn (*Parser) ParseError!NodeIdx) ParseError!NodeIdx {
        var lhs = try next(self);
        while (true) {
            const found = for (ops) |op| {
                if (self.current.tag == op.token) break op.tag;
            } else null;
            const bin_tag = found orelse break;
            try self.advance();
            const rhs = try next(self);
            lhs = try self.makeBinop(bin_tag, lhs, rhs);
        }
        return lhs;
    }

    fn parseComparison(self: *@This()) ParseError!NodeIdx {
        var lhs = try self.parseAdditive();
        while (true) {
            switch (self.current.tag) {
                .lt, .gt, .le, .ge, .eq_eq, .ne => {
                    const op_tag: BinTag = switch (self.current.tag) {
                        .lt => .lt,
                        .gt => .gt,
                        .le => .le,
                        .ge => .ge,
                        .eq_eq => .eq,
                        .ne => .ne,
                        else => unreachable,
                    };
                    try self.advance();
                    const rhs = try self.parseAdditive();
                    lhs = try self.makeBinop(op_tag, lhs, rhs);
                },
                .kw_is, .kw_as => {
                    const is_tag = self.current.tag == .kw_is;
                    try self.advance();
                    lhs = if (is_tag) try self.makeIsNode(lhs, try self.parseType()) else try self.makeAsNode(lhs, try self.parseType());
                },
                else => break,
            }
        }
        return lhs;
    }

    fn parseAnd(self: *@This()) ParseError!NodeIdx {
        return self.parseBinary(&.{.{ .token = .kw_and, .tag = .@"and" }}, &Parser.parseNot);
    }

    fn parseOr(self: *@This()) ParseError!NodeIdx {
        return self.parseBinary(&.{.{ .token = .kw_or, .tag = .@"or" }}, &Parser.parseAnd);
    }

    fn parseNot(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag == .kw_not) {
            const not_span = tokenSpan(self.current);
            try self.advance();
            const inner = try self.parseComparison();
            const span = coverSpans(not_span, try self.spanOf(inner));
            return self.allocNode(.@"not", inner, 0, span);
        }
        return self.parseComparison();
    }

    fn parseAdditive(self: *@This()) ParseError!NodeIdx {
        return self.parseBinary(&.{ .{ .token = .plus, .tag = .add }, .{ .token = .minus, .tag = .sub } }, &Parser.parseMultiplicative);
    }

    fn parseMultiplicative(self: *@This()) ParseError!NodeIdx {
        return self.parseBinary(&.{ .{ .token = .star, .tag = .mul }, .{ .token = .slash, .tag = .div } }, &Parser.parseUnary);
    }

    fn parseUnary(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag == .minus) {
            const minus_span = tokenSpan(self.current);
            try self.advance();

            if (self.current.tag == .int_lit) {
                const value = try negatedIntFromToken(self.current);
                const int_span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.int_lit, @as(u32, @bitCast(value)), 0, coverSpans(minus_span, int_span));
            }

            if (self.current.tag == .float_lit) {
                const value = -self.current.float_value;
                const float_span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.float_lit, @as(u32, @bitCast(value)), 0, coverSpans(minus_span, float_span));
            }

            const operand = try self.parseUnary();
            const zero = try self.allocNode(.int_lit, 0, 0, minus_span);
            return self.makeBinop(.sub, zero, operand);
        }

        return self.parsePostfix();
    }

    fn parsePostfix(self: *@This()) ParseError!NodeIdx {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.current.tag == .l_paren) {
                const callee_span = try self.spanOf(expr);
                try self.advance();

                var args = std.ArrayList(NodeIdx).empty;
                while (self.current.tag != .r_paren) {
                    const arg = try self.parseExpression();
                    try args.append(self.scratch_arena.allocator(), arg);
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
                expr = try self.parseStructInitWithExpr(expr);
            } else if (self.current.tag == .dot) {
                expr = try self.parseFieldAccess(expr);
            } else if (self.current.tag == .caret) {
                const caret_span = tokenSpan(self.current);
                try self.advance();
                const expr_span = try self.spanOf(expr);
                expr = try self.allocNode(.move_expr, expr, 0, coverSpans(expr_span, caret_span));
            } else if (self.current.tag == .question) {
                const q_span = tokenSpan(self.current);
                try self.advance();
                const expr_span = try self.spanOf(expr);
                expr = try self.allocNode(.query_op, expr, 0, coverSpans(expr_span, q_span));
            } else {
                break;
            }
        }

        return expr;
    }

    fn parseStructInitWithExpr(self: *@This(), callee_expr: NodeIdx) ParseError!NodeIdx {
        const lbrace_span = tokenSpan(self.current);
        try self.expect(.l_brace, error.UnexpectedToken);

        var fields = std.ArrayList(FieldInfo).empty;
        while (self.current.tag != .r_brace) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const field_name = self.current.ident;
            try self.advance();
            try self.expect(.assign, error.ExpectedAssign);
            const value = try self.parseExpression();
            try fields.append(self.scratch_arena.allocator(), .{ .name = field_name, .value = value });

            if (self.current.tag == .comma) {
                try self.advance();
            } else if (self.current.tag != .r_brace) {
                return error.ExpectedComma;
            }
        }

        const end_span = tokenSpan(self.current);
        try self.expect(.r_brace, error.UnexpectedToken);
        const span = coverSpans(lbrace_span, end_span);
        const count: u32 = @intCast(fields.items.len);
        try self.builder.extra.append(self.builder.gpa, count);
        for (fields.items) |f| {
            try self.builder.extra.append(self.builder.gpa, try self.internName(f.name));
            try self.builder.extra.append(self.builder.gpa, f.value);
        }
        const extra_idx: u32 = @intCast(self.builder.extra.items.len - 1 - count * 2);
        return self.allocNode(.struct_init, callee_expr, extra_idx, span);
    }

    fn parseFieldAccess(self: *@This(), target: NodeIdx) ParseError!NodeIdx {
        const dot_span = tokenSpan(self.current);
        try self.expect(.dot, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const field_name_span = tokenSpan(self.current);
        const field_name = self.current.ident;
        try self.advance();
        return self.makeFieldAccessNode(target, field_name, coverSpans(dot_span, field_name_span));
    }

    fn parseStructExpr(self: *@This(), start_span: ast.Span) ParseError!NodeIdx {
        const fields = try self.parseStructFields();

        const field_count: u32 = @intCast(fields.names.items.len);
        const extra_idx = try self.builder.allocExtraSingle(field_count);
        for (0..@intCast(field_count)) |i| {
            try self.builder.extra.append(self.builder.gpa, fields.names.items[i]);
            try self.builder.extra.append(self.builder.gpa, fields.types.items[i]);
        }
        const span = if (field_count > 0)
            coverSpans(start_span, try self.spanOf(fields.types.items[field_count - 1]))
        else
            start_span;
        return self.allocNode(.struct_expr, extra_idx, field_count, span);
    }

    fn parsePrimary(self: *@This()) ParseError!NodeIdx {
        switch (self.current.tag) {
            .int_lit => {
                const lit_span = tokenSpan(self.current);
                const value = try intFromToken(self.current);
                try self.advance();
                return self.allocNode(.int_lit, @as(u32, @bitCast(value)), 0, lit_span);
            },
            .float_lit => {
                const lit_span = tokenSpan(self.current);
                const value = self.current.float_value;
                try self.advance();
                return self.allocNode(.float_lit, @as(u32, @bitCast(value)), 0, lit_span);
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
            .kw_comptime => {
                const kw_span = tokenSpan(self.current);
                try self.advance();
                return self.parseComptimeExprAfterKeyword(kw_span);
            },
            .kw_true => {
                const span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.bool_lit, 1, 0, span);
            },
            .kw_false => {
                const span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.bool_lit, 0, 0, span);
            },
            .kw_struct => {
                const s_span = tokenSpan(self.current);
                try self.advance();
                return self.parseStructExpr(s_span);
            },
            .kw_none => {
                const span = tokenSpan(self.current);
                try self.advance();
                return self.allocNode(.none_lit, 0, 0, span);
            },
            .kw_sizeof => {
                const sizeof_span = tokenSpan(self.current);
                try self.advance();
                try self.expect(.l_paren, error.ExpectedLParen);
                const type_node = try self.parseType();
                const end_span = tokenSpan(self.current);
                try self.expect(.r_paren, error.ExpectedRParen);
                const span = coverSpans(sizeof_span, end_span);
                return self.allocNode(.sizeof_expr, type_node, 0, span);
            },
            .ident => {
                const ident_span = tokenSpan(self.current);
                const name = self.current.ident;
                try self.advance();
                const name_idx = try self.internName(name);
                return self.allocNode(.var_ref, name_idx, 0, ident_span);
            },
            .kw_const => return self.parseBinding(.const_kind, true),
            .kw_var => return self.parseBinding(.var_kind, true),
            else => return error.ExpectedExpression,
        }
    }

    fn parsePrint(self: *@This()) ParseError!NodeIdx {
        const print_span = tokenSpan(self.current);
        try self.expect(.kw_print, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);
        const expr = try self.parseExpression();
        const end_span = tokenSpan(self.current);
        try self.expect(.r_paren, error.ExpectedRParen);
        const span = coverSpans(print_span, end_span);
        return self.allocNode(.print_stmt, expr, 0, span);
    }

    fn parseArg(self: *@This()) ParseError!NodeIdx {
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
        const span = coverSpans(arg_span, end_span);
        return self.allocNode(.arg, idx, 0, span);
    }

    fn findIfWithoutElse(builder: *AstBuilder, node: NodeIdx) ?struct { if_idx: NodeIdx, then_: NodeIdx } {
        const n = builder.nodes.items[node];
        if (n.tag == .if_stmt) {
            if (n.data1 == 0) return .{ .if_idx = node, .then_ = 0 };
            const ei = n.data1;
            const then_child = builder.extra.items[ei];
            const else_child = builder.extra.items[ei + 1];
            if (else_child == std.math.maxInt(u32)) return .{ .if_idx = node, .then_ = then_child };
        }
        return null;
    }

    fn parseIf(self: *@This()) ParseError!NodeIdx {
        const if_span = tokenSpan(self.current);
        try self.expect(.kw_if, error.UnexpectedToken);

        const cond = try self.parseIfCondition();

        const then_expr = if (self.current.tag == .arrow) then_body: {
            try self.advance();
            break :then_body try self.parseStatement();
        } else try self.parseIndentedBlock(error.ExpectedExpression);

        var else_expr: ?NodeIdx = null;
        if (self.current.tag == .kw_else) {
            try self.advance();
            else_expr = try self.parseOptionalIndentedBlock();
        }

        const end_span = if (else_expr) |e| try self.spanOf(e) else try self.spanOf(then_expr);
        const span = coverSpans(if_span, end_span);

        if (else_expr) |e| {
            const extra_idx = try self.builder.allocExtraPair(then_expr, e);
            return self.allocNode(.if_stmt, cond, extra_idx, span);
        }
        const extra_idx = try self.builder.allocExtraPair(then_expr, std.math.maxInt(u32));
        return self.allocNode(.if_stmt, cond, extra_idx, span);
    }

    fn parseIfCondition(self: *@This()) ParseError!NodeIdx {
        return switch (self.current.tag) {
            .kw_const => self.parseIfBindingCondition(.const_kind),
            .kw_var => self.parseIfBindingCondition(.var_kind),
            else => self.parseExpression(),
        };
    }

    fn parseIfBindingCondition(self: *@This(), kind: BindingKind) ParseError!NodeIdx {
        return self.parseBinding(kind, false);
    }
};

pub const ParseReport = struct {
    parsed: ?ParsedAst,
    diagnostic: ?db.Diagnostic,
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
        error.OutOfMemory => "out of memory while parsing",
        else => "parse error",
    };
}

pub fn parseOwned(source: []const u8, gpa: std.mem.Allocator) (ParseError || error{OutOfMemory})!ParsedAst {
    const report = try parseReport(source, gpa);
    return report.parsed orelse error.ExpectedExpression;
}


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
    var builder = AstBuilder.init(gpa);
    errdefer builder.deinit();

    var parser = Parser.init(source, &builder) catch |err| {
        builder.deinit();
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

    const entry = parser.parseProgram() catch |err| {
        const error_span = ast.Span{ .start = parser.current.start, .end = parser.current.end };
        parser.deinit();
        builder.deinit();
        return .{
            .parsed = null,
            .diagnostic = .{
                .stage = .parse,
                .span = error_span,
                .message = parseErrorMessage(err),
            },
        };
    };
    parser.deinit();

    var scratch_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer scratch_arena.deinit();

    const ast_value = builder.seal(entry) catch {
        builder.deinit();
        scratch_arena.deinit();
        return error.OutOfMemory;
    };
    builder.deinit();

    return .{
        .parsed = .{
            .arena = scratch_arena,
            .ast = ast_value,
        },
        .diagnostic = null,
    };
}
