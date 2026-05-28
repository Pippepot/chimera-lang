const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const AstNode = ast.AstNode;

pub const Type = enum {
    unit,
    bool,
    int,
    float,
};

pub const TypeError = error{
    UnknownVariable,
    DuplicateVariable,
    PrintUnitValue,
    ArithmeticOperandMismatch,
    ArithmeticRequiresNumeric,
    ComparisonOperandMismatch,
    ComparisonRequiresNumeric,
    EqualityOperandMismatch,
    EqualityUnsupportedType,
    IfConditionNotFallible,
    FallibleOutsideFallibleContext,
    IfBranchTypeMismatch,
    IfWithoutElseRequiresUnit,
    MissingNodeType,
};

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

pub const TypecheckReport = struct {
    typed: ?TypedAst,
    diagnostic: ?diagnostics.Diagnostic,
};

pub fn typeErrorMessage(kind: TypeError) []const u8 {
    return switch (kind) {
        error.UnknownVariable => "unknown variable",
        error.DuplicateVariable => "duplicate variable binding",
        error.PrintUnitValue => "cannot print a unit value",
        error.ArithmeticOperandMismatch => "arithmetic operands must have the same type",
        error.ArithmeticRequiresNumeric => "arithmetic requires int or float operands",
        error.ComparisonOperandMismatch => "comparison operands must have the same type",
        error.ComparisonRequiresNumeric => "comparison requires int or float operands",
        error.EqualityOperandMismatch => "equality operands must have the same type",
        error.EqualityUnsupportedType => "equality is not supported for unit values",
        error.IfConditionNotFallible => "If condition must be a fallible expression",
        error.FallibleOutsideFallibleContext => "Fallible expression is not allowed outside fallible context",
        error.IfBranchTypeMismatch => "if branches must return the same type",
        error.IfWithoutElseRequiresUnit => "if without else must have unit then-branch",
        error.MissingNodeType => "internal type table mismatch",
    };
}

const Checker = struct {
    gpa: std.mem.Allocator,
    typed: TypedAst,
    bindings: std.ArrayList(Binding),
    failure: ?Failure,
    in_fallible_scope: bool,

    const Binding = struct {
        name: []const u8,
        ty: Type,
    };

    const Failure = struct {
        node: *const AstNode,
        kind: TypeError,
    };

    const InferError = std.mem.Allocator.Error || error{TypecheckFailed};

    fn init(gpa: std.mem.Allocator) Checker {
        return .{
            .gpa = gpa,
            .typed = TypedAst.init(gpa),
            .bindings = .empty,
            .failure = null,
            .in_fallible_scope = false,
        };
    }

    fn deinit(self: *@This()) void {
        self.typed.deinit();
        self.bindings.deinit(self.gpa);
    }

    fn remember(self: *@This(), node: *const AstNode, ty: Type) std.mem.Allocator.Error!Type {
        try self.typed.node_types.put(nodeKey(node), ty);
        return ty;
    }

    fn fail(self: *@This(), node: *const AstNode, kind: TypeError) error{TypecheckFailed} {
        if (self.failure == null) {
            self.failure = .{ .node = node, .kind = kind };
        }
        return error.TypecheckFailed;
    }

    fn pushBinding(self: *@This(), node: *const AstNode, name: []const u8, ty: Type) InferError!void {
        if (self.lookupBinding(name) != null) return self.fail(node, error.DuplicateVariable);
        try self.bindings.append(self.gpa, .{ .name = name, .ty = ty });
    }

    fn lookupBinding(self: *const @This(), name: []const u8) ?Type {
        var idx = self.bindings.items.len;
        while (idx > 0) {
            idx -= 1;
            const binding = self.bindings.items[idx];
            if (std.mem.eql(u8, binding.name, name)) return binding.ty;
        }
        return null;
    }

    fn inferPair(self: *@This(), kids: *const [2]AstNode) InferError![2]Type {
        const lhs = try self.inferNode(&kids[0]);
        const rhs = try self.inferNode(&kids[1]);
        return .{ lhs, rhs };
    }

    fn isNumeric(ty: Type) bool {
        return ty == .int or ty == .float;
    }

    fn isFallible(node: *const AstNode) bool {
        return switch (node.*) {
            .lt, .gt, .le, .ge, .eq, .ne => true,
            else => false,
        };
    }

    fn inferArithmetic(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) InferError!Type {
        const pair = try self.inferPair(kids);
        if (!isNumeric(pair[0])) return self.fail(&kids[0], error.ArithmeticRequiresNumeric);
        if (!isNumeric(pair[1])) return self.fail(&kids[1], error.ArithmeticRequiresNumeric);
        if (pair[0] != pair[1]) return self.fail(node, error.ArithmeticOperandMismatch);
        return self.remember(node, pair[0]);
    }

    fn inferComparison(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) InferError!Type {
        const pair = try self.inferPair(kids);
        if (!isNumeric(pair[0])) return self.fail(&kids[0], error.ComparisonRequiresNumeric);
        if (!isNumeric(pair[1])) return self.fail(&kids[1], error.ComparisonRequiresNumeric);
        if (pair[0] != pair[1]) return self.fail(node, error.ComparisonOperandMismatch);
        return self.remember(node, .unit);
    }

    fn inferEquality(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) InferError!Type {
        const pair = try self.inferPair(kids);
        if (pair[0] != pair[1]) return self.fail(node, error.EqualityOperandMismatch);
        switch (pair[0]) {
            .bool, .int, .float => {},
            .unit => return self.fail(node, error.EqualityUnsupportedType),
        }
        return self.remember(node, .unit);
    }

    fn inferIf(self: *@This(), node: *const AstNode, if_node: *const ast.IfNode) InferError!Type {
        self.in_fallible_scope = true;
        _ = try self.inferNode(if_node.cond);
        self.in_fallible_scope = false;

        if (!isFallible(if_node.cond)) return self.fail(if_node.cond, error.IfConditionNotFallible);

        const then_ty = try self.inferNode(if_node.then_);
        if (if_node.else_) |else_node| {
            const else_ty = try self.inferNode(else_node);
            if (then_ty != else_ty) return self.fail(node, error.IfBranchTypeMismatch);
            return self.remember(node, then_ty);
        }

        if (then_ty != .unit) return self.fail(if_node.then_, error.IfWithoutElseRequiresUnit);
        return self.remember(node, .unit);
    }

    fn inferConst(self: *@This(), node: *const AstNode, const_node: *const ast.ConstNode) InferError!Type {
        const value_ty = try self.inferNode(const_node.value);
        try self.pushBinding(node, const_node.name, value_ty);
        const body_ty = try self.inferNode(const_node.body);
        return self.remember(node, body_ty);
    }

    fn inferFallible(self: *@This(), node: *const AstNode, kids: *const [2]AstNode, comptime inferFn: fn (*@This(), *const AstNode, *const [2]AstNode) InferError!Type) InferError!Type {
        const result = try inferFn(self, node, kids);
        if (!self.in_fallible_scope) return self.fail(node, error.FallibleOutsideFallibleContext);
        return result;
    }

    fn inferNode(self: *@This(), node: *const AstNode) InferError!Type {
        if (self.typed.node_types.get(nodeKey(node))) |existing| return existing;
        return switch (node.*) {
            .int => self.remember(node, .int),
            .float => self.remember(node, .float),
            .var_ref => |name| self.remember(node, self.lookupBinding(name) orelse return self.fail(node, error.UnknownVariable)),
            .seq => |kids| block: {
                _ = try self.inferNode(&kids[0]);
                const rhs = try self.inferNode(&kids[1]);
                break :block try self.remember(node, rhs);
            },
            .const_ => |const_node| self.inferConst(node, const_node),
            .arg => self.remember(node, .int),
            .print => |child| block: {
                const child_ty = try self.inferNode(child);
                if (child_ty == .unit) return self.fail(child, error.PrintUnitValue);
                break :block try self.remember(node, .unit);
            },
            .add => |kids| self.inferArithmetic(node, kids),
            .sub => |kids| self.inferArithmetic(node, kids),
            .mul => |kids| self.inferArithmetic(node, kids),
            .div => |kids| self.inferArithmetic(node, kids),
            .lt => |kids| try self.inferFallible(node, kids, Checker.inferComparison),
            .gt => |kids| try self.inferFallible(node, kids, Checker.inferComparison),
            .le => |kids| try self.inferFallible(node, kids, Checker.inferComparison),
            .ge => |kids| try self.inferFallible(node, kids, Checker.inferComparison),
            .eq => |kids| try self.inferFallible(node, kids, Checker.inferEquality),
            .ne => |kids| try self.inferFallible(node, kids, Checker.inferEquality),
            .if_ => |if_node| self.inferIf(node, if_node),
            .bool => self.remember(node, .bool),
            .unit => self.remember(node, .unit),
        };
    }
};

fn nodeKey(node: *const AstNode) usize {
    return @intFromPtr(node);
}

const parser = @import("parser.zig");
const db = @import("db.zig");

pub const TypeMemo = db.Memo(TypedAst);

pub fn computeType(parse_memo: *const parser.ParseMemo, gpa: std.mem.Allocator) error{OutOfMemory}!TypeMemo {
    var diagnostics_list = try std.ArrayList(diagnostics.Diagnostic).initCapacity(gpa, parse_memo.diagnostics.items.len + 1);
    errdefer diagnostics_list.deinit(gpa);
    try diagnostics_list.appendSlice(gpa, parse_memo.diagnostics.items);

    var typed_value: ?TypedAst = null;
    if (parse_memo.value) |*parsed| {
        const report = try typecheckReport(parsed.root, &parsed.spans, gpa);
        if (report.diagnostic) |diag| {
            try diagnostics_list.append(gpa, diag);
        }
        typed_value = report.typed;
    }

    return .{
        .value = typed_value,
        .diagnostics = diagnostics_list,
        .deps = .empty,
        .verified_at = 0,
        .changed_at = 0,
        .computing = false,
    };
}

pub fn typecheckReport(
    root: *const AstNode,
    spans: *const std.AutoHashMap(usize, ast.Span),
    gpa: std.mem.Allocator,
) error{OutOfMemory}!TypecheckReport {
    var checker = Checker.init(gpa);
    errdefer checker.deinit();

    checker.typed.root_type = checker.inferNode(root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TypecheckFailed => {
            const failure = checker.failure.?;
            checker.deinit();
            return .{
                .typed = null,
                .diagnostic = .{
                    .stage = .typecheck,
                    .span = spans.get(nodeKey(failure.node)),
                    .message = typeErrorMessage(failure.kind),
                },
            };
        },
    };

    checker.bindings.deinit(gpa);
    return .{
        .typed = checker.typed,
        .diagnostic = null,
    };
}
