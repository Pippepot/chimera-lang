pub const Span = struct {
    start: usize,
    end: usize,
};

pub const TypeNode = union(enum) {
    name: []const u8,
    func: *const FuncTypeNode,
};

pub const FuncTypeNode = struct {
    params: []const *const TypeNode,
    ret: *const TypeNode,
};

pub const ParamNode = struct {
    name: []const u8,
    ty: *const TypeNode,
};

pub const FieldNode = struct {
    name: []const u8,
    ty: *const TypeNode,
};

pub const FuncDecl = struct {
    name: []const u8,
    params: []const ParamNode,
    ret_type: *const TypeNode,
    body: *const AstNode,
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []const FieldNode,
};

pub const Decl = union(enum) {
    comptime_func: *const FuncDecl,
    comptime_struct: *const StructDecl,
};

pub const Module = struct {
    decls: []const *const Decl,
    entry: *const AstNode,
};

pub const IfNode = struct {
    cond: *const AstNode,
    then_: *const AstNode,
    else_: ?*const AstNode,
};

pub const VarNode = struct {
    name: []const u8,
    ty: ?*const TypeNode,
    value: *const AstNode,
};

pub const ConstNode = struct {
    name: []const u8,
    ty: ?*const TypeNode,
    value: *const AstNode,
};

pub const ReturnNode = struct {
    value: *const AstNode,
};

pub const CallNode = struct {
    callee: *const AstNode,
    args: []const *const AstNode,
};

pub const FieldInit = struct {
    name: []const u8,
    value: *const AstNode,
};

pub const StructInitNode = struct {
    struct_name: []const u8,
    fields: []const FieldInit,
};

pub const FieldAccessNode = struct {
    target: *const AstNode,
    field: []const u8,
};

pub const BlockNode = struct {
    items: []const *const AstNode,
};

pub const AstNode = union(enum) {
    block: *const BlockNode,
    int: i32,
    float: f32,
    var_ref: []const u8,
    var_: *const VarNode,
    assign: *const VarNode,
    const_: *const ConstNode,
    return_: *const ReturnNode,
    call: *const CallNode,
    struct_init: *const StructInitNode,
    field_access: *const FieldAccessNode,
    print: *const AstNode,
    add: *const [2]AstNode,
    sub: *const [2]AstNode,
    mul: *const [2]AstNode,
    div: *const [2]AstNode,
    arg: u32,
    lt: *const [2]AstNode,
    gt: *const [2]AstNode,
    le: *const [2]AstNode,
    ge: *const [2]AstNode,
    eq: *const [2]AstNode,
    ne: *const [2]AstNode,
    if_: *const IfNode,
    bool: bool,
    unit: void,
};
