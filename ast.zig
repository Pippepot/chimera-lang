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
    body: *const AstNode,
};

pub const AstNode = union(enum) {
    int: i32,
    float: f32,
    var_ref: []const u8,
    seq: *const [2]AstNode,
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
