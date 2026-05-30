const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const AstNode = ast.Node;
const Tag = ast.Tag;
const NodeIdx = ast.NodeIdx;
const StringIdx = ast.StringIdx;
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
    string_bytes: std.ArrayList(u8),
    string_offsets: std.ArrayList(u32),
    string_map: std.StringHashMap(StringIdx),
    spans: std.ArrayList(ast.Span),
    decls: std.ArrayList(NodeIdx),

    pub fn init(gpa: std.mem.Allocator) AstBuilder {
        return .{
            .gpa = gpa,
            .temp_arena = std.heap.ArenaAllocator.init(gpa),
            .nodes = .empty,
            .extra = .empty,
            .string_bytes = .empty,
            .string_offsets = .empty,
            .string_map = std.StringHashMap(StringIdx).init(gpa),
            .spans = .empty,
            .decls = .empty,
        };
    }

    pub fn deinit(self: *AstBuilder) void {
        self.nodes.deinit(self.gpa);
        self.extra.deinit(self.gpa);
        self.string_bytes.deinit(self.gpa);
        self.string_offsets.deinit(self.gpa);
        self.string_map.deinit();
        self.spans.deinit(self.gpa);
        self.decls.deinit(self.gpa);
        self.temp_arena.deinit();
    }

    pub fn internString(self: *AstBuilder, s: []const u8) !StringIdx {
        if (self.string_map.get(s)) |idx| return idx;
        const idx: StringIdx = @intCast(self.string_offsets.items.len);
        try self.string_offsets.append(self.gpa, @intCast(self.string_bytes.items.len));
        try self.string_bytes.appendSlice(self.gpa, s);
        const owned = try self.temp_arena.allocator().dupe(u8, s);
        try self.string_map.put(owned, idx);
        return idx;
    }

    pub fn allocNode(self: *AstBuilder, tag: Tag, data0: u32, data1: u32, span: ast.Span) !NodeIdx {
        const idx: NodeIdx = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{ .tag = tag, ._pad = .{ 0, 0, 0 }, .data0 = data0, .data1 = data1 });
        try self.spans.append(self.gpa, span);
        return idx;
    }

    pub fn stringOf(self: *const AstBuilder, idx: StringIdx) []const u8 {
        const start = self.string_offsets.items[idx];
        const end = if (idx + 1 < self.string_offsets.items.len)
            self.string_offsets.items[idx + 1]
        else
            @as(u32, @intCast(self.string_bytes.items.len));
        return self.string_bytes.items[start..end];
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

    fn alignForward(addr: usize, alignment: usize) usize {
        return (addr + (alignment - 1)) & ~(@as(usize, alignment) - 1);
    }

    pub fn seal(self: *AstBuilder, entry: NodeIdx) !ast.Ast {
        const decls_slice = try self.decls.toOwnedSlice(self.gpa);
        defer self.gpa.free(decls_slice);
        const nodes = try self.nodes.toOwnedSlice(self.gpa);
        defer self.gpa.free(nodes);
        const extra = try self.extra.toOwnedSlice(self.gpa);
        defer self.gpa.free(extra);
        const string_bytes = try self.string_bytes.toOwnedSlice(self.gpa);
        defer self.gpa.free(string_bytes);
        const string_offsets = try self.string_offsets.toOwnedSlice(self.gpa);
        defer self.gpa.free(string_offsets);
        const spans = try self.spans.toOwnedSlice(self.gpa);
        defer self.gpa.free(spans);

        const nodes_len = nodes.len;
        const extra_len = extra.len;
        const str_bytes_len = string_bytes.len;
        const str_offs_len = string_offsets.len;
        const spans_len = spans.len;
        const decls_len = decls_slice.len;

        const header_size = @sizeOf(ast.Ast.Header);
        const nodes_off = header_size;
        const nodes_bytes = nodes_len * @sizeOf(ast.Node);
        const extra_off = nodes_off + nodes_bytes;
        const extra_bytes = extra_len * 4;
        const str_bytes_off = extra_off + extra_bytes;
        const str_bytes_bytes = str_bytes_len;
        const str_offs_off = alignForward(str_bytes_off + str_bytes_bytes, 4);
        const str_offs_bytes = str_offs_len * 4;
        const spans_off = alignForward(str_offs_off + str_offs_bytes, @alignOf(ast.Span));
        const spans_bytes = spans_len * @sizeOf(ast.Span);
        const decls_off = spans_off + spans_bytes;
        const decls_bytes = decls_len * 4;
        const total_size = decls_off + decls_bytes;

        const backing = try self.gpa.alloc(u8, total_size);
        errdefer self.gpa.free(backing);
        @memset(backing, 0);
        const hdr: *ast.Ast.Header = @ptrCast(@alignCast(backing.ptr));
        hdr.* = .{
            .nodes_len = @intCast(nodes_len),
            .extra_len = @intCast(extra_len),
            .str_bytes_len = @intCast(str_bytes_len),
            .str_offs_len = @intCast(str_offs_len),
            .spans_len = @intCast(spans_len),
            .decls_len = @intCast(decls_len),
            .entry = entry,
        };

        @memcpy(backing[nodes_off..][0..nodes_bytes], std.mem.sliceAsBytes(nodes));
        @memcpy(backing[extra_off..][0..extra_bytes], std.mem.sliceAsBytes(extra));
        @memcpy(backing[str_bytes_off..][0..str_bytes_bytes], string_bytes);
        @memcpy(backing[str_offs_off..][0..str_offs_bytes], std.mem.sliceAsBytes(string_offsets));
        @memcpy(backing[spans_off..][0..spans_bytes], std.mem.sliceAsBytes(spans));
        @memcpy(backing[decls_off..][0..decls_bytes], std.mem.sliceAsBytes(decls_slice));

        var name_map = std.StringHashMap(ast.NodeIdx).init(self.gpa);
        errdefer name_map.deinit();
        {
            const ast_nodes = @as([*]ast.Node, @ptrCast(@alignCast(backing.ptr + nodes_off)))[0..nodes_len];
            const str_offs = @as([*]u32, @ptrCast(@alignCast(backing.ptr + str_offs_off)))[0..str_offs_len];
            const decls = @as([*]ast.NodeIdx, @ptrCast(@alignCast(backing.ptr + decls_off)))[0..decls_len];
            for (decls) |decl_idx| {
                const name_idx = ast_nodes[decl_idx].data0;
                const start = str_offs[name_idx];
                const end = if (name_idx + 1 < str_offs_len) str_offs[name_idx + 1] else @as(u32, @intCast(str_bytes_len));
                const name = backing[str_bytes_off..][start..end];
                try name_map.put(name, decl_idx);
            }
        }

        return ast.Ast{
            .backing = backing,
            .nodes = @as([*]ast.Node, @ptrCast(@alignCast(backing.ptr + nodes_off)))[0..nodes_len],
            .extra = @as([*]u32, @ptrCast(@alignCast(backing.ptr + extra_off)))[0..extra_len],
            .string_bytes = backing[str_bytes_off..][0..str_bytes_len],
            .string_offsets = @as([*]u32, @ptrCast(@alignCast(backing.ptr + str_offs_off)))[0..str_offs_len],
            .spans = @as([*]ast.Span, @ptrCast(@alignCast(backing.ptr + spans_off)))[0..spans_len],
            .decls = @as([*]ast.NodeIdx, @ptrCast(@alignCast(backing.ptr + decls_off)))[0..decls_len],
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

    pub fn spanOfAny(_: *const @This(), _: usize) ?ast.Span {
        return null;
    }
};

const Parser = struct {
    builder: *AstBuilder,
    lexer: Lexer,
    current: Token,
    scratch_arena: std.heap.ArenaAllocator,

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

    fn init(source: []const u8, builder: *AstBuilder) ParseError!Parser {
        var lexer = Lexer.init(source);
        const current = try lexer.next();
        return .{
            .builder = builder,
            .lexer = lexer,
            .current = current,
            .scratch_arena = std.heap.ArenaAllocator.init(builder.gpa),
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
        return self.builder.internString(name);
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

    fn spanOf(self: *const @This(), idx: NodeIdx) !ast.Span {
        if (idx < self.builder.spans.items.len) return self.builder.spans.items[idx];
        return ast.Span{ .start = 0, .end = 0 };
    }

    fn spanOfToken(_: *const @This(), token: Token) ast.Span {
        return tokenSpan(token);
    }

    fn makeConstNode(self: *@This(), name: []const u8, ty: ?NodeIdx, value: NodeIdx, span: ast.Span) !NodeIdx {
        const name_idx = try self.internName(name);
        if (ty) |type_idx| {
            const extra_idx = try self.builder.allocExtraPair(type_idx, value);
            return self.allocNode(.const_decl, name_idx, extra_idx | 0x80000000, span);
        }
        return self.allocNode(.const_decl, name_idx, value, span);
    }

    fn makeVarNode(self: *@This(), name: []const u8, ty: ?NodeIdx, value: NodeIdx, span: ast.Span) !NodeIdx {
        const name_idx = try self.internName(name);
        if (ty) |type_idx| {
            const extra_idx = try self.builder.allocExtraPair(type_idx, value);
            return self.allocNode(.var_decl, name_idx, extra_idx | 0x80000000, span);
        }
        return self.allocNode(.var_decl, name_idx, value, span);
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
        };
        const span = coverSpans(try self.spanOf(left), try self.spanOf(right));
        return self.allocNode(node_tag, left, right, span);
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

    fn parseProgram(self: *@This()) ParseError!NodeIdx {
        try self.consumeNewlines();

        var decls = std.ArrayList(NodeIdx).empty;
        while (self.current.tag == .kw_comptime) {
            const decl = try self.parseDeclaration();
            try decls.append(self.scratch_arena.allocator(), decl);
        }
        const entry = try self.parseBlockUntil();
        try self.consumeNewlines();
        if (self.current.tag != .eof) return error.TrailingInput;

        const owned_decls = try self.scratch_arena.allocator().alloc(NodeIdx, decls.items.len);
        @memcpy(owned_decls, decls.items);
        for (owned_decls) |d| try self.builder.decls.append(self.builder.gpa, d);

        return entry;
    }

    fn parseDeclaration(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag != .kw_comptime) return error.ExpectedDeclaration;
        const decl_start = tokenSpan(self.current);
        try self.advance();

        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const name = self.current.ident;
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

    fn parseComptimeFunc(self: *@This(), name: []const u8, decl_start: ast.Span) ParseError!NodeIdx {
        try self.expect(.kw_func, error.UnexpectedToken);
        try self.expect(.l_paren, error.ExpectedLParen);

        const name_idx = try self.internName(name);

        var param_names = std.ArrayList(u32).empty;
        var param_types = std.ArrayList(u32).empty;
        while (self.current.tag != .r_paren) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const param_name = try self.internName(self.current.ident);
            try self.advance();
            try self.expect(.colon, error.ExpectedColon);
            const ty = try self.parseType();
            try param_names.append(self.scratch_arena.allocator(), param_name);
            try param_types.append(self.scratch_arena.allocator(), ty);

            if (self.current.tag == .comma) {
                try self.advance();
            } else if (self.current.tag != .r_paren) {
                return error.ExpectedComma;
            }
        }

        try self.expect(.r_paren, error.ExpectedRParen);
        const ret_ty = try self.parseType();

        try self.consumeNewlines();
        if (self.current.tag != .indent) return error.ExpectedIndent;
        try self.advance();
        const body = try self.parseBlockUntil();
        try self.consumeNewlines();
        try self.expect(.dedent, error.ExpectedIndent);

        const param_count: u32 = @intCast(param_names.items.len);
        try self.builder.extra.append(self.builder.gpa, param_count);
        var i: u32 = 0;
        while (i < param_count) : (i += 1) {
            try self.builder.extra.append(self.builder.gpa, param_names.items[i]);
            try self.builder.extra.append(self.builder.gpa, param_types.items[i]);
        }
        try self.builder.extra.append(self.builder.gpa, ret_ty);
        try self.builder.extra.append(self.builder.gpa, body);
        const extra_idx: u32 = @intCast(self.builder.extra.items.len - 3 - param_count * 2);

        const body_span = try self.spanOf(body);
        const span = coverSpans(decl_start, body_span);
        return self.allocNode(.comptime_fn, name_idx, extra_idx, span);
    }

    fn parseComptimeStruct(self: *@This(), name: []const u8, decl_start: ast.Span) ParseError!NodeIdx {
        try self.expect(.kw_struct, error.UnexpectedToken);

        const name_idx = try self.internName(name);

        try self.consumeNewlines();
        if (self.current.tag != .indent) return error.ExpectedIndent;
        try self.advance();

        var field_names = std.ArrayList(u32).empty;
        var field_types = std.ArrayList(u32).empty;
        while (self.current.tag != .dedent and self.current.tag != .eof) {
            if (self.current.tag != .ident) return error.ExpectedIdentifier;
            const field_name = try self.internName(self.current.ident);
            try self.advance();
            try self.expect(.colon, error.ExpectedColon);
            const field_ty = try self.parseType();
            try field_names.append(self.scratch_arena.allocator(), field_name);
            try field_types.append(self.scratch_arena.allocator(), field_ty);
            if (self.current.tag == .newline) {
                try self.consumeNewlines();
            } else if (self.current.tag != .dedent) {
                return error.UnexpectedToken;
            }
        }

        try self.expect(.dedent, error.ExpectedIndent);

        const field_count: u32 = @intCast(field_names.items.len);
        try self.builder.extra.append(self.builder.gpa, field_count);
        var i: u32 = 0;
        while (i < field_count) : (i += 1) {
            try self.builder.extra.append(self.builder.gpa, field_names.items[i]);
            try self.builder.extra.append(self.builder.gpa, field_types.items[i]);
        }
        const extra_idx: u32 = @intCast(self.builder.extra.items.len - 1 - field_count * 2);

        const span = if (field_count > 0)
            coverSpans(decl_start, try self.spanOf(field_types.items[field_count - 1]))
        else
            decl_start;
        return self.allocNode(.comptime_struct, name_idx, extra_idx, span);
    }

    fn parseType(self: *@This()) ParseError!u32 {
        switch (self.current.tag) {
            .ident => {
                const span = tokenSpan(self.current);
                const name = self.current.ident;
                try self.advance();
                const name_idx = try self.internName(name);
                return self.allocNode(.type_name, name_idx, 0, span);
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
                try self.expect(.r_paren, error.ExpectedRParen);

                const ret_ty = try self.parseType();

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

    fn parseStatement(self: *@This()) ParseError!NodeIdx {
        if (self.current.tag == .kw_const) return self.parseConstBinding();
        if (self.current.tag == .kw_var) return self.parseVarBinding();
        if (self.current.tag == .kw_return) return self.parseReturn();
        return self.parseExpression();
    }

    fn parseBlockUntil(self: *@This()) ParseError!NodeIdx {
        try self.consumeNewlines();
        var items = std.ArrayList(NodeIdx).empty;

        while (self.current.tag != .eof and self.current.tag != .r_paren and self.current.tag != .dedent) {
            if (self.current.tag == .kw_else) {
                if (items.items.len == 0) return error.ExpectedExpression;
                const last_idx = items.items.len - 1;
                if (findIfWithoutElse(self.builder, items.items[last_idx])) |if_node_data| {
                    try self.advance();
                    try self.consumeNewlines();
                    const else_expr = if (self.current.tag == .indent) blk: {
                        try self.advance();
                        const body = try self.parseBlockUntil();
                        try self.consumeNewlines();
                        try self.expect(.dedent, error.ExpectedExpression);
                        break :blk body;
                    } else try self.parseExpression();

                    const ei = self.builder.extra.items.len;
                    try self.builder.extra.append(self.builder.gpa, if_node_data.then_);
                    try self.builder.extra.append(self.builder.gpa, else_expr);
                    const node = &self.builder.nodes.items[if_node_data.if_idx];
                    node.data1 = @intCast(ei);

                    if (self.current.tag == .newline) {
                        try self.consumeNewlines();
                    }
                    continue;
                }
                return error.ExpectedExpression;
            }

            const statement = try self.parseStatement();
            try items.append(self.scratch_arena.allocator(), statement);

            if (self.current.tag == .newline) {
                try self.consumeNewlines();
                continue;
            }
            if (self.current.tag == .eof or self.current.tag == .r_paren or self.current.tag == .dedent) break;
            if (self.current.tag == .kw_else) continue;

            const stmt_span = try self.spanOf(statement);
            const cursor_start = if (self.current.start > self.lexer.source.len) self.lexer.source.len else self.current.start;
            if (cursor_start > stmt_span.end and std.mem.indexOfScalar(u8, self.lexer.source[stmt_span.end..cursor_start], '\n') != null) {
                continue;
            }
            return error.UnexpectedToken;
        }

        return self.makeBlockNode(items.items);
    }

    fn parseExpression(self: *@This()) ParseError!NodeIdx {
        const node = try self.parseComparison();
        if (self.current.tag == .assign) {
            const node_tag = self.builder.nodes.items[node].tag;
            if (node_tag != .var_ref) return error.UnexpectedToken;
            const name_idx = self.builder.nodes.items[node].data0;
            const name = self.builder.stringOf(name_idx);
            try self.advance();
            const value = try self.parseExpression();
            const span = coverSpans(try self.spanOf(node), try self.spanOf(value));
            return self.makeAssignNode(name, value, span);
        }
        return node;
    }

    fn stringOf(self: *@This(), idx: u32) []const u8 {
        const start = if (idx < self.builder.string_offsets.items.len)
            self.builder.string_offsets.items[idx]
        else
            0;
        const end = if (idx + 1 < self.builder.string_offsets.items.len)
            self.builder.string_offsets.items[idx + 1]
        else
            @as(u32, @intCast(self.builder.string_bytes.items.len));
        return self.builder.string_bytes.items[start..end];
    }

    fn parseReturn(self: *@This()) ParseError!NodeIdx {
        const ret_span = tokenSpan(self.current);
        try self.expect(.kw_return, error.UnexpectedToken);
        const value = try self.parseExpression();
        const span = coverSpans(ret_span, try self.spanOf(value));
        return self.makeReturnNode(value, span);
    }

    fn parseConstBinding(self: *@This()) ParseError!NodeIdx {
        const const_span = tokenSpan(self.current);
        try self.expect(.kw_const, error.UnexpectedToken);
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
        const end_span = if (binding_ty) |ty| coverSpans(try self.spanOf(ty), value_span) else value_span;
        const const_node_span = coverSpans(const_span, end_span);
        return self.makeConstNode(ident, binding_ty, value, const_node_span);
    }

    fn parseVarBinding(self: *@This()) ParseError!NodeIdx {
        const var_span = tokenSpan(self.current);
        try self.expect(.kw_var, error.UnexpectedToken);
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
        const end_span = if (binding_ty) |ty| coverSpans(try self.spanOf(ty), value_span) else value_span;
        const var_node_span = coverSpans(var_span, end_span);
        return self.makeVarNode(ident, binding_ty, value, var_node_span);
    }

    fn parseComparison(self: *@This()) ParseError!NodeIdx {
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

    fn parseAdditive(self: *@This()) ParseError!NodeIdx {
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

    fn parseMultiplicative(self: *@This()) ParseError!NodeIdx {
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
                if (self.builder.nodes.items[expr].tag != .var_ref) return error.ExpectedIdentifier;
                const struct_name = self.builder.stringOf(self.builder.nodes.items[expr].data0);
                expr = try self.parseStructInit(struct_name);
            } else if (self.current.tag == .dot) {
                expr = try self.parseFieldAccess(expr);
            } else {
                break;
            }
        }

        return expr;
    }

    fn parseStructInit(self: *@This(), struct_name: []const u8) ParseError!NodeIdx {
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
        return self.makeStructInitNode(struct_name, fields.items, span);
    }

    fn parseFieldAccess(self: *@This(), target: NodeIdx) ParseError!NodeIdx {
        const dot_span = tokenSpan(self.current);
        try self.expect(.dot, error.UnexpectedToken);
        if (self.current.tag != .ident) return error.ExpectedIdentifier;
        const field_name = self.current.ident;
        try self.advance();
        const end_span = tokenSpan(self.current);
        return self.makeFieldAccessNode(target, field_name, coverSpans(dot_span, end_span));
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
            .ident => {
                const ident_span = tokenSpan(self.current);
                const name = self.current.ident;
                try self.advance();
                const name_idx = try self.internName(name);
                return self.allocNode(.var_ref, name_idx, 0, ident_span);
            },
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

        var else_expr: ?NodeIdx = null;
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

        const end_span = if (else_expr) |e| try self.spanOf(e) else try self.spanOf(then_expr);
        const span = coverSpans(if_span, end_span);

        if (else_expr) |e| {
            const extra_idx = try self.builder.allocExtraPair(then_expr, e);
            return self.allocNode(.if_stmt, cond, extra_idx, span);
        }
        const extra_idx = try self.builder.allocExtraPair(then_expr, std.math.maxInt(u32));
        return self.allocNode(.if_stmt, cond, extra_idx, span);
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
    var builder = AstBuilder.init(gpa);
    errdefer builder.deinit();

    const entry = parseSource(&builder, source) catch |err| {
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

fn parseSource(builder: *AstBuilder, source: []const u8) (ParseError || error{OutOfMemory})!NodeIdx {
    var parser = try Parser.init(source, builder);
    defer parser.deinit();

    const entry = try parser.parseProgram();
    return entry;
}
