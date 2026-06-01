const std = @import("std");

pub const NodeIdx = u32;
pub const IdentIdx = u32;
pub const ExtraIdx = u32;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Tag = enum(u8) {
    block,
    int_lit,
    float_lit,
    var_ref,
    var_decl,
    assign,
    field_assign,
    const_decl,
    return_stmt,
    call,
    struct_init,
    move_expr,
    field_access,
    print_stmt,
    add,
    sub,
    mul,
    div,
    arg,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    is,
    as,
    @"and",
    @"or",
    @"not",
    if_stmt,
    bool_lit,
    unit_lit,
    none_lit,
    type_name,
    type_func,
    type_variant,
    type_union,
    comptime_expr,
    comptime_value_decl,
    comptime_fn,
    comptime_struct,
    struct_expr,
    query_op,
    sizeof_expr,
};

pub const Node = extern struct {
    tag: Tag,
    _pad: [3]u8,
    data0: u32,
    data1: u32,
};

pub const Ast = struct {
    backing: []u8,

    nodes: []Node,
    extra: []u32,
    ident_bytes: []u8,
    ident_offsets: []u32,
    spans: []Span,
    decls: []NodeIdx,
    entry: NodeIdx,
    name_map: std.StringHashMap(NodeIdx),

    pub fn deinit(ast: *Ast, gpa: std.mem.Allocator) void {
        gpa.free(ast.backing);
        ast.name_map.deinit();
    }

    pub fn spanOf(ast: *const Ast, idx: NodeIdx) ?Span {
        if (idx < ast.spans.len) return ast.spans[idx];
        return null;
    }

    pub fn identOf(ast: *const Ast, idx: IdentIdx) []const u8 {
        const start = ast.ident_offsets[idx];
        const end = if (idx + 1 < ast.ident_offsets.len)
            ast.ident_offsets[idx + 1]
        else
            @as(u32, @intCast(ast.ident_bytes.len));
        return ast.ident_bytes[start..end];
    }

    pub fn blockItems(ast: *const Ast, idx: NodeIdx) []const NodeIdx {
        const start = ast.nodes[idx].data0;
        const count = ast.nodes[idx].data1;
        return ast.extra[start..][0..count];
    }

    pub fn varDeclHasType(ast: *const Ast, idx: NodeIdx) bool { return declHasType(ast, idx); }
    pub fn varDeclType(ast: *const Ast, idx: NodeIdx) ?TypeIdx { return declType(ast, idx); }
    pub fn varDeclValue(ast: *const Ast, idx: NodeIdx) NodeIdx { return declValue(ast, idx); }

    pub const comptimeValueDeclHasType = varDeclHasType;
    pub const comptimeValueDeclType = varDeclType;
    pub const comptimeValueDeclValue = varDeclValue;

    pub fn callArgs(ast: *const Ast, idx: NodeIdx) []const NodeIdx {
        const extra_idx = ast.nodes[idx].data1;
        const count = ast.extra[extra_idx];
        return ast.extra[extra_idx + 1 ..][0..count];
    }

    pub fn ifData(ast: *const Ast, idx: NodeIdx) struct { cond: NodeIdx, then_: NodeIdx, else_: NodeIdx } {
        const extra_idx = ast.nodes[idx].data1;
        return .{
            .cond = ast.nodes[idx].data0,
            .then_ = ast.extra[extra_idx],
            .else_ = ast.extra[extra_idx + 1],
        };
    }

    pub fn structInitFields(ast: *const Ast, idx: NodeIdx) []const FieldPair {
        const extra_idx = ast.nodes[idx].data1;
        const count = ast.extra[extra_idx];
        const pairs = @as([*]const FieldPair, @ptrCast(&ast.extra[extra_idx + 1]));
        return pairs[0..count];
    }

    pub fn structInitName(ast: *const Ast, idx: NodeIdx) IdentIdx {
        const type_expr = ast.nodes[idx].data0;
        if (ast.nodes[type_expr].tag == .var_ref) {
            return ast.nodes[type_expr].data0;
        }
        return std.math.maxInt(IdentIdx);
    }

    pub fn structInitTypeExpr(ast: *const Ast, idx: NodeIdx) NodeIdx {
        return ast.nodes[idx].data0;
    }

    pub fn isLhs(ast: *const Ast, idx: NodeIdx) NodeIdx {
        return ast.nodes[idx].data0;
    }

    pub fn isRhsType(ast: *const Ast, idx: NodeIdx) TypeIdx {
        return ast.nodes[idx].data1;
    }

    fn hasAnnotation(data1: u32) bool { return data1 & 0x80000000 != 0; }
    fn extraIdx(data1: u32) u32 { return data1 & ~@as(u32, 0x80000000); }

    fn declHasType(ast: *const Ast, idx: NodeIdx) bool { return hasAnnotation(ast.nodes[idx].data1); }
    fn declType(ast: *const Ast, idx: NodeIdx) ?TypeIdx {
        if (!hasAnnotation(ast.nodes[idx].data1)) return null;
        return ast.extra[extraIdx(ast.nodes[idx].data1)];
    }
    fn declValue(ast: *const Ast, idx: NodeIdx) NodeIdx {
        const d1 = ast.nodes[idx].data1;
        if (!hasAnnotation(d1)) return d1;
        return ast.extra[extraIdx(d1) + 1];
    }

    pub const FnAnnotationInfo = struct {
        has_annotation: bool,
        annotation: ?TypeIdx,
    };

    fn fnExtraBase(ast: *const Ast, idx: NodeIdx) u32 { return extraIdx(ast.nodes[idx].data1); }

    pub fn fnComptimeMask(ast: *const Ast, idx: NodeIdx) u32 { return ast.extra[ast.fnExtraBase(idx) + 1]; }
    pub fn fnMutMask(ast: *const Ast, idx: NodeIdx) u32 { return ast.extra[ast.fnExtraBase(idx) + 2]; }
    pub fn fnVarMask(ast: *const Ast, idx: NodeIdx) u32 { return ast.extra[ast.fnExtraBase(idx) + 3]; }
    pub fn fnDeinitMask(ast: *const Ast, idx: NodeIdx) u32 { return ast.extra[ast.fnExtraBase(idx) + 4]; }

    pub fn fnParamAccessMode(ast: *const Ast, idx: NodeIdx, param_index: u32) ParamAccessMode {
        if (fnComptimeMask(ast, idx) & (@as(u32, 1) << @intCast(param_index)) != 0) return .read;
        if (fnMutMask(ast, idx) & (@as(u32, 1) << @intCast(param_index)) != 0) return .mut;
        if (fnVarMask(ast, idx) & (@as(u32, 1) << @intCast(param_index)) != 0) return .var_mode;
        if (fnDeinitMask(ast, idx) & (@as(u32, 1) << @intCast(param_index)) != 0) return .deinit;
        return .read;
    }

    pub fn fnParamIsComptime(ast: *const Ast, idx: NodeIdx, param_index: u32) bool {
        return fnComptimeMask(ast, idx) & (@as(u32, 1) << @intCast(param_index)) != 0;
    }

    pub fn fnParams(ast: *const Ast, idx: NodeIdx) []const ParamPair {
        const ei = ast.fnExtraBase(idx);
        const count = ast.extra[ei];
        const pairs = @as([*]const ParamPair, @ptrCast(&ast.extra[ei + 5]));
        return pairs[0..count];
    }

    pub fn fnRetType(ast: *const Ast, idx: NodeIdx) TypeIdx {
        const ei = ast.fnExtraBase(idx);
        const count = ast.extra[ei];
        return ast.extra[ei + 5 + count * 2];
    }

    pub fn fnBody(ast: *const Ast, idx: NodeIdx) NodeIdx {
        const ei = ast.fnExtraBase(idx);
        const count = ast.extra[ei];
        return ast.extra[ei + 5 + count * 2 + 1];
    }

    pub fn comptimeFnAnnotation(ast: *const Ast, idx: NodeIdx) ?TypeIdx {
        if (!hasAnnotation(ast.nodes[idx].data1)) return null;
        const ei = ast.fnExtraBase(idx);
        const count = ast.extra[ei];
        return ast.extra[ei + 7 + count * 2];
    }

    pub fn structExprFields(ast: *const Ast, idx: NodeIdx) []const ParamPair {
        const ei = ast.nodes[idx].data0;
        const count = ast.nodes[idx].data1;
        const pairs = @as([*]const ParamPair, @ptrCast(&ast.extra[ei + 1]));
        return pairs[0..count];
    }

    fn structExtraBase(ast: *const Ast, idx: NodeIdx) u32 { return extraIdx(ast.nodes[idx].data1); }

    pub fn structFields(ast: *const Ast, idx: NodeIdx) []const ParamPair {
        const ei = ast.structExtraBase(idx);
        const count = ast.extra[ei];
        const pairs = @as([*]const ParamPair, @ptrCast(&ast.extra[ei + 8]));
        return pairs[0..count];
    }

    pub fn comptimeStructAnnotation(ast: *const Ast, idx: NodeIdx) ?TypeIdx {
        if (!hasAnnotation(ast.nodes[idx].data1)) return null;
        const ei = ast.structExtraBase(idx);
        const count = ast.extra[ei];
        return ast.extra[ei + 8 + count * 2];
    }

    pub fn structMoveExplicit(ast: *const Ast, idx: NodeIdx) bool { return ast.extra[ast.structExtraBase(idx) + 7] & 0b001 != 0; }
    pub fn structCopyExplicit(ast: *const Ast, idx: NodeIdx) bool { return ast.extra[ast.structExtraBase(idx) + 7] & 0b010 != 0; }
    pub fn structDropExplicit(ast: *const Ast, idx: NodeIdx) bool { return ast.extra[ast.structExtraBase(idx) + 7] & 0b100 != 0; }

    pub fn structMoveKind(ast: *const Ast, idx: NodeIdx) StructMoveKind { return @enumFromInt(ast.extra[ast.structExtraBase(idx) + 1]); }
    pub fn structMoveHook(ast: *const Ast, idx: NodeIdx) ?IdentIdx {
        const hook = ast.extra[ast.structExtraBase(idx) + 2];
        if (hook == no_hook_ident) return null;
        return hook;
    }
    pub fn structCopyKind(ast: *const Ast, idx: NodeIdx) StructCopyKind { return @enumFromInt(ast.extra[ast.structExtraBase(idx) + 3]); }
    pub fn structCopyHook(ast: *const Ast, idx: NodeIdx) ?IdentIdx {
        const hook = ast.extra[ast.structExtraBase(idx) + 4];
        if (hook == no_hook_ident) return null;
        return hook;
    }
    pub fn structDropKind(ast: *const Ast, idx: NodeIdx) StructDropKind { return @enumFromInt(ast.extra[ast.structExtraBase(idx) + 5]); }
    pub fn structDropHook(ast: *const Ast, idx: NodeIdx) ?IdentIdx {
        const hook = ast.extra[ast.structExtraBase(idx) + 6];
        if (hook == no_hook_ident) return null;
        return hook;
    }

    pub fn funcTypeParams(ast: *const Ast, idx: NodeIdx) []const TypeIdx {
        const extra_idx = ast.nodes[idx].data0;
        const count = ast.nodes[idx].data1;
        return ast.extra[extra_idx..][0..count];
    }

    pub fn funcTypeRet(ast: *const Ast, idx: NodeIdx) TypeIdx {
        const extra_idx = ast.nodes[idx].data0;
        const count = ast.nodes[idx].data1;
        return ast.extra[extra_idx + count];
    }

    pub fn variantTypeMembers(ast: *const Ast, idx: NodeIdx) []const TypeIdx {
        const extra_idx = ast.nodes[idx].data0;
        const count = ast.nodes[idx].data1;
        return ast.extra[extra_idx..][0..count];
    }

    pub fn typeUnionMembers(ast: *const Ast, idx: NodeIdx) []const NodeIdx {
        const extra_idx = ast.nodes[idx].data0;
        const count = ast.nodes[idx].data1;
        return ast.extra[extra_idx..][0..count];
    }

    pub fn comptimeExprBody(ast: *const Ast, idx: NodeIdx) NodeIdx {
        return ast.nodes[idx].data0;
    }

    pub fn sizeofExprType(ast: *const Ast, idx: NodeIdx) NodeIdx {
        return ast.nodes[idx].data0;
    }

    fn alignForward(addr: usize, alignment: usize) usize {
        return (addr + (alignment - 1)) & ~(@as(usize, alignment) - 1);
    }

    pub fn serialize(ast: *const Ast, gpa: std.mem.Allocator) ![]u8 {
        const layout = computedSize(
            @intCast(ast.nodes.len), @intCast(ast.extra.len),
            @intCast(ast.ident_bytes.len), @intCast(ast.ident_offsets.len),
            @intCast(ast.spans.len), @intCast(ast.decls.len),
        );
        var buf = try std.ArrayList(u8).initCapacity(gpa, layout.total);
        errdefer buf.deinit(gpa);

        var w: [4]u8 = undefined;
        inline for (.{ @as(u32, @intCast(ast.nodes.len)), @as(u32, @intCast(ast.extra.len)), @as(u32, @intCast(ast.ident_bytes.len)), @as(u32, @intCast(ast.ident_offsets.len)), @as(u32, @intCast(ast.spans.len)), @as(u32, @intCast(ast.decls.len)), ast.entry }) |v| {
            std.mem.writeInt(u32, &w, v, .little);
            try buf.appendSlice(gpa, &w);
        }

        try buf.appendSlice(gpa, std.mem.sliceAsBytes(ast.nodes));
        try buf.appendSlice(gpa, std.mem.sliceAsBytes(ast.extra));
        try buf.appendSlice(gpa, ast.ident_bytes);
        try buf.appendNTimes(gpa, 0, layout.str_offs_off - buf.items.len);
        try buf.appendSlice(gpa, std.mem.sliceAsBytes(ast.ident_offsets));
        try buf.appendNTimes(gpa, 0, layout.spans_off - buf.items.len);
        try buf.appendSlice(gpa, std.mem.sliceAsBytes(ast.spans));
        try buf.appendSlice(gpa, std.mem.sliceAsBytes(ast.decls));

        return buf.toOwnedSlice(gpa);
    }

    pub fn computedSize(
        nodes_len: u32,
        extra_len: u32,
        str_bytes_len: u32,
        str_offs_len: u32,
        spans_len: u32,
        decls_len: u32,
    ) struct {
        total: usize,
        nodes_off: usize,
        extra_off: usize,
        str_bytes_off: usize,
        str_offs_off: usize,
        spans_off: usize,
        decls_off: usize,
    } {
        const header_size = @sizeOf(Header);
        const nodes_off = header_size;
        const nodes_bytes: usize = @intCast(nodes_len * @sizeOf(Node));
        const extra_off = nodes_off + nodes_bytes;
        const extra_bytes: usize = @intCast(extra_len * 4);
        const str_bytes_off = extra_off + extra_bytes;
        const str_bytes_bytes: usize = @intCast(str_bytes_len);
        const str_offs_off = alignForward(str_bytes_off + str_bytes_bytes, 4);
        const str_offs_bytes: usize = @intCast(str_offs_len * 4);
        const spans_off = alignForward(str_offs_off + str_offs_bytes, @alignOf(Span));
        const spans_bytes: usize = @intCast(spans_len * @sizeOf(Span));
        const decls_off = spans_off + spans_bytes;
        const decls_bytes: usize = @intCast(decls_len * 4);
        const total = decls_off + decls_bytes;
        return .{
            .total = total,
            .nodes_off = nodes_off,
            .extra_off = extra_off,
            .str_bytes_off = str_bytes_off,
            .str_offs_off = str_offs_off,
            .spans_off = spans_off,
            .decls_off = decls_off,
        };
    }

    pub fn deserialize(gpa: std.mem.Allocator, data: []const u8) !Ast {
        if (data.len < @sizeOf(Header)) return error.UnexpectedEndOfStream;
        const header_bytes = data[0..@sizeOf(Header)];
        const header = std.mem.bytesAsValue(Header, header_bytes);
        const layout = computedSize(header.nodes_len, header.extra_len, header.str_bytes_len, header.str_offs_len, header.spans_len, header.decls_len);

        if (data.len < layout.total) return error.UnexpectedEndOfStream;
        const payload = data[0..layout.total];

        const backing = try gpa.alloc(u8, layout.total);
        errdefer gpa.free(backing);
        @memcpy(backing, payload);

        const nodes = @as([*]Node, @ptrCast(@alignCast(backing.ptr + layout.nodes_off)))[0..header.nodes_len];
        const extra = @as([*]u32, @ptrCast(@alignCast(backing.ptr + layout.extra_off)))[0..header.extra_len];
        const ident_bytes = backing[layout.str_bytes_off..][0..header.str_bytes_len];
        const ident_offsets = @as([*]u32, @ptrCast(@alignCast(backing.ptr + layout.str_offs_off)))[0..header.str_offs_len];
        const spans = @as([*]Span, @ptrCast(@alignCast(backing.ptr + layout.spans_off)))[0..header.spans_len];
        const decls = @as([*]NodeIdx, @ptrCast(@alignCast(backing.ptr + layout.decls_off)))[0..header.decls_len];

        var ast_result = Ast{
            .backing = backing,
            .nodes = nodes,
            .extra = extra,
            .ident_bytes = ident_bytes,
            .ident_offsets = ident_offsets,
            .spans = spans,
            .decls = decls,
            .entry = header.entry,
            .name_map = std.StringHashMap(NodeIdx).init(gpa),
        };

        for (decls) |decl_idx| {
            const name_idx = ast_result.nodes[decl_idx].data0;
            const name = ast_result.identOf(name_idx);
            try ast_result.name_map.put(name, decl_idx);
        }

        return ast_result;
    }

    pub const Header = extern struct {
        nodes_len: u32,
        extra_len: u32,
        str_bytes_len: u32,
        str_offs_len: u32,
        spans_len: u32,
        decls_len: u32,
        entry: u32,
    };
};

pub const TypeIdx = u32;

pub const ParamAccessMode = enum(u32) {
    read = 0,
    mut = 1,
    var_mode = 2,
    deinit = 3,
};

pub const StructMoveKind = enum(u32) {
    fieldwise = 0,
    trivial = 1,
    none = 2,
    func = 3,
};

pub const StructCopyKind = enum(u32) {
    none = 0,
    fieldwise = 1,
    trivial = 2,
    func = 3,
};

pub const StructDropKind = enum(u32) {
    trivial = 0,
    fieldwise = 1,
    explicit = 2,
    func = 3,
};

pub const no_hook_ident: u32 = std.math.maxInt(u32);

/// Sentinel value stored in the extra array as `ret_ty` when a function declaration
/// omits the return type annotation, indicating it should be inferred from the body.
pub const FN_NO_RET_TYPE: u32 = std.math.maxInt(u32);

pub const FieldPair = struct { name: IdentIdx, value: NodeIdx };
pub const ParamPair = struct { name: IdentIdx, ty: TypeIdx };
