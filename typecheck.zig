const std = @import("std");
const x86 = @import("main.zig");
const AstNode = x86.AstNode;

pub const Type = enum {
    unit,
    bool,
    int,
    float,
};

pub const TypeError = error{
    PrintUnitValue,
    ArithmeticOperandMismatch,
    ArithmeticRequiresNumeric,
    ComparisonOperandMismatch,
    ComparisonRequiresNumeric,
    EqualityOperandMismatch,
    EqualityUnsupportedType,
    IfConditionMustBeBool,
    IfBranchTypeMismatch,
    IfWithoutElseRequiresUnit,
    MissingNodeType,
};

pub const TypecheckError = TypeError || std.mem.Allocator.Error;

pub const TypedAst = struct {
    node_types: std.AutoHashMap(usize, Type),
    root_type: Type,

    pub fn init(gpa: std.mem.Allocator) TypedAst {
        return .{
            .node_types = std.AutoHashMap(usize, Type).init(gpa),
            .root_type = .unit,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.node_types.deinit();
    }

    pub fn typeOf(self: *const @This(), node: *const AstNode) TypeError!Type {
        return self.node_types.get(nodeKey(node)) orelse error.MissingNodeType;
    }
};

const Checker = struct {
    typed: TypedAst,

    fn init(gpa: std.mem.Allocator) Checker {
        return .{ .typed = TypedAst.init(gpa) };
    }

    fn deinit(self: *@This()) void {
        self.typed.deinit();
    }

    fn remember(self: *@This(), node: *const AstNode, ty: Type) std.mem.Allocator.Error!Type {
        try self.typed.node_types.put(nodeKey(node), ty);
        return ty;
    }

    fn inferPair(self: *@This(), kids: *const [2]AstNode) TypecheckError![2]Type {
        const lhs = try self.inferNode(&kids[0]);
        const rhs = try self.inferNode(&kids[1]);
        return .{ lhs, rhs };
    }

    fn ensureNumeric(ty: Type, arithmetic: bool) TypeError!void {
        if (ty == .int or ty == .float) return;
        return if (arithmetic) error.ArithmeticRequiresNumeric else error.ComparisonRequiresNumeric;
    }

    fn inferArithmetic(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) TypecheckError!Type {
        const pair = try self.inferPair(kids);
        try ensureNumeric(pair[0], true);
        try ensureNumeric(pair[1], true);
        if (pair[0] != pair[1]) return error.ArithmeticOperandMismatch;
        return self.remember(node, pair[0]);
    }

    fn inferComparison(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) TypecheckError!Type {
        const pair = try self.inferPair(kids);
        try ensureNumeric(pair[0], false);
        try ensureNumeric(pair[1], false);
        if (pair[0] != pair[1]) return error.ComparisonOperandMismatch;
        return self.remember(node, .bool);
    }

    fn inferEquality(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) TypecheckError!Type {
        const pair = try self.inferPair(kids);
        if (pair[0] != pair[1]) return error.EqualityOperandMismatch;
        switch (pair[0]) {
            .bool, .int, .float => {},
            .unit => return error.EqualityUnsupportedType,
        }
        return self.remember(node, .bool);
    }

    fn inferIf(self: *@This(), node: *const AstNode, if_node: *const x86.IfNode) TypecheckError!Type {
        const cond_ty = try self.inferNode(if_node.cond);
        if (cond_ty != .bool) return error.IfConditionMustBeBool;

        const then_ty = try self.inferNode(if_node.then_);
        if (if_node.else_) |else_node| {
            const else_ty = try self.inferNode(else_node);
            if (then_ty != else_ty) return error.IfBranchTypeMismatch;
            return self.remember(node, then_ty);
        }

        if (then_ty != .unit) return error.IfWithoutElseRequiresUnit;
        return self.remember(node, .unit);
    }

    fn inferNode(self: *@This(), node: *const AstNode) TypecheckError!Type {
        if (self.typed.node_types.get(nodeKey(node))) |existing| return existing;
        return switch (node.*) {
            .int => self.remember(node, .int),
            .float => self.remember(node, .float),
            .arg => self.remember(node, .int),
            .print => |child| block: {
                const child_ty = try self.inferNode(child);
                if (child_ty == .unit) return error.PrintUnitValue;
                break :block try self.remember(node, .unit);
            },
            .add => |kids| self.inferArithmetic(node, kids),
            .sub => |kids| self.inferArithmetic(node, kids),
            .mul => |kids| self.inferArithmetic(node, kids),
            .div => |kids| self.inferArithmetic(node, kids),
            .lt => |kids| self.inferComparison(node, kids),
            .gt => |kids| self.inferComparison(node, kids),
            .le => |kids| self.inferComparison(node, kids),
            .ge => |kids| self.inferComparison(node, kids),
            .eq => |kids| self.inferEquality(node, kids),
            .ne => |kids| self.inferEquality(node, kids),
            .if_ => |if_node| self.inferIf(node, if_node),
        };
    }
};

fn nodeKey(node: *const AstNode) usize {
    return @intFromPtr(node);
}

pub fn typecheck(root: *const AstNode, gpa: std.mem.Allocator) TypecheckError!TypedAst {
    var checker = Checker.init(gpa);
    errdefer checker.deinit();

    checker.typed.root_type = try checker.inferNode(root);
    return checker.typed;
}
