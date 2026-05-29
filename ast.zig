pub const Span = struct {
    start: usize,
    end: usize,
};

pub const IfNode = struct {
    cond: *const AstNode,
    then_: *const AstNode,
    else_: ?*const AstNode,
};

pub const ConstNode = struct {
    name: []const u8,
    value: *const AstNode,
};

pub const BlockNode = struct {
    items: []const *const AstNode,
};

pub const AstNode = union(enum) {
    block: *const BlockNode,
    int: i32,
    float: f32,
    var_ref: []const u8,
    const_: *const ConstNode,
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
