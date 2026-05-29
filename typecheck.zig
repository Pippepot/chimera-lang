const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

const AstNode = ast.AstNode;

pub const FuncType = struct {
    params: []const Type,
    ret: Type,
};

pub const Type = union(enum) {
    unit,
    bool,
    int,
    float,
    named: []const u8,
    func: *const FuncType,
};

pub fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unit, .bool, .int, .float => true,
        .named => |lhs| std.mem.eql(u8, lhs, b.named),
        .func => |lhs| funcTypeEql(lhs, b.func),
    };
}

fn funcTypeEql(a: *const FuncType, b: *const FuncType) bool {
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params) |left, right| {
        if (!typeEql(left, right)) return false;
    }
    return typeEql(a.ret, b.ret);
}

pub const FunctionInfo = struct {
    decl: *const ast.FuncDecl,
    ty: *const FuncType,
    has_explicit_return: bool,
};

pub const TypeError = error{
    UnknownSymbol,
    UnknownType,
    DuplicateSymbol,
    PrintUnitValue,
    PrintUnsupportedType,
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
    AssignToConst,
    AssignmentTypeMismatch,
    BindingTypeMismatch,
    CallTargetNotFunction,
    CallArityMismatch,
    CallArgumentMismatch,
    ReturnTypeMismatch,
    FunctionBodyTypeMismatch,
    MissingNodeType,
    UnknownField,
    FieldAccessOnNonStruct,
    StructInitFieldCountMismatch,
    StructInitFieldNameMismatch,
};

pub const TypedAst = struct {
    arena: std.heap.ArenaAllocator,
    module: *const ast.Module,
    node_types: std.AutoHashMap(usize, Type),
    functions: []FunctionInfo,
    entry_function: u32,

    pub fn init(gpa: std.mem.Allocator, module: *const ast.Module) TypedAst {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .module = module,
            .node_types = std.AutoHashMap(usize, Type).init(gpa),
            .functions = &.{},
            .entry_function = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.node_types.deinit();
        self.arena.deinit();
    }

    pub fn typeOf(self: *const @This(), node: *const AstNode) TypeError!Type {
        return self.node_types.get(nodeKey(node)) orelse error.MissingNodeType;
    }

    pub fn functionType(self: *const @This(), fn_id: u32) *const FuncType {
        return self.functions[fn_id].ty;
    }
};

pub const TypecheckReport = struct {
    typed: ?TypedAst,
    diagnostic: ?diagnostics.Diagnostic,
};

pub fn typeErrorMessage(kind: TypeError) []const u8 {
    return switch (kind) {
        error.UnknownSymbol => "unknown symbol",
        error.UnknownType => "unknown type",
        error.DuplicateSymbol => "duplicate symbol",
        error.PrintUnitValue => "cannot print a unit value",
        error.PrintUnsupportedType => "cannot print this type",
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
        error.AssignToConst => "cannot assign to const symbol",
        error.AssignmentTypeMismatch => "assignment type mismatch",
        error.BindingTypeMismatch => "binding type annotation mismatch",
        error.CallTargetNotFunction => "call target is not a function value",
        error.CallArityMismatch => "call argument count mismatch",
        error.CallArgumentMismatch => "call argument type mismatch",
        error.ReturnTypeMismatch => "return type mismatch",
        error.FunctionBodyTypeMismatch => "function body type does not match declared return type",
        error.MissingNodeType => "internal type table mismatch",
        error.UnknownField => "unknown field",
        error.FieldAccessOnNonStruct => "field access on non-struct type",
        error.StructInitFieldCountMismatch => "struct init field count mismatch",
        error.StructInitFieldNameMismatch => "struct init field name mismatch",
    };
}

const Binding = struct {
    ty: Type,
    mutable: bool,
};

const Checker = struct {
    gpa: std.mem.Allocator,
    parsed: *const parser.ParsedAst,
    resolved: *const resolver.ResolvedAst,
    typed: TypedAst,
    bindings: scope_mod.ScopeStack(Binding),
    failure: ?Failure,
    in_fallible_scope: bool,
    current_return: Type,
    current_saw_return: bool,

    const Failure = struct {
        span: ?ast.Span,
        kind: TypeError,
    };

    const InferError = std.mem.Allocator.Error || error{TypecheckFailed};

    fn init(parsed: *const parser.ParsedAst, resolved: *const resolver.ResolvedAst, gpa: std.mem.Allocator) Checker {
        return .{
            .gpa = gpa,
            .parsed = parsed,
            .resolved = resolved,
            .typed = TypedAst.init(gpa, resolved.module),
            .bindings = scope_mod.ScopeStack(Binding).init(),
            .failure = null,
            .in_fallible_scope = false,
            .current_return = .unit,
            .current_saw_return = false,
        };
    }

    fn deinit(self: *@This()) void {
        self.typed.deinit();
        self.bindings.deinit(self.gpa);
    }

    fn spanOfNode(self: *const @This(), node: *const AstNode) ?ast.Span {
        return self.parsed.spanOfNode(node);
    }

    fn spanOfTypeNode(self: *const @This(), type_node: *const ast.TypeNode) ?ast.Span {
        return self.parsed.spanOfAny(@intFromPtr(type_node));
    }

    fn remember(self: *@This(), node: *const AstNode, ty: Type) std.mem.Allocator.Error!Type {
        try self.typed.node_types.put(nodeKey(node), ty);
        return ty;
    }

    fn fail(self: *@This(), span: ?ast.Span, kind: TypeError) error{TypecheckFailed} {
        if (self.failure == null) self.failure = .{ .span = span, .kind = kind };
        return error.TypecheckFailed;
    }

    fn failAtNode(self: *@This(), node: *const AstNode, kind: TypeError) error{TypecheckFailed} {
        return self.fail(self.spanOfNode(node), kind);
    }

    fn failAtType(self: *@This(), type_node: *const ast.TypeNode, kind: TypeError) error{TypecheckFailed} {
        return self.fail(self.spanOfTypeNode(type_node), kind);
    }

    fn pushBinding(self: *@This(), node: *const AstNode, name: []const u8, binding: Binding) InferError!void {
        self.bindings.push(self.gpa, name, binding) catch |err| switch (err) {
            error.DuplicateVariable => return self.failAtNode(node, error.DuplicateSymbol),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn lookupBinding(self: *const @This(), name: []const u8) ?Binding {
        return self.bindings.lookup(name);
    }

    fn allocFuncType(self: *@This(), params: []const Type, ret: Type) std.mem.Allocator.Error!*const FuncType {
        const arena_alloc = self.typed.arena.allocator();
        const owned_params = try arena_alloc.alloc(Type, params.len);
        @memcpy(owned_params, params);
        const fn_ty = try arena_alloc.create(FuncType);
        fn_ty.* = .{
            .params = owned_params,
            .ret = ret,
        };
        return fn_ty;
    }

    fn resolveTypeNode(self: *@This(), type_node: *const ast.TypeNode) InferError!Type {
        return switch (type_node.*) {
            .name => |name| blk: {
                if (std.mem.eql(u8, name, "unit")) break :blk .unit;
                if (std.mem.eql(u8, name, "bool")) break :blk .bool;
                if (std.mem.eql(u8, name, "int")) break :blk .int;
                if (std.mem.eql(u8, name, "float")) break :blk .float;
                if (self.resolved.struct_names.contains(name)) break :blk .{ .named = name };
                return self.failAtType(type_node, error.UnknownType);
            },
            .func => |fn_node| blk: {
                var params = try std.ArrayList(Type).initCapacity(self.gpa, fn_node.params.len);
                defer params.deinit(self.gpa);
                for (fn_node.params) |param_type_node| {
                    try params.append(self.gpa, try self.resolveTypeNode(param_type_node));
                }
                const ret_ty = try self.resolveTypeNode(fn_node.ret);
                const fn_ty = try self.allocFuncType(params.items, ret_ty);
                break :blk .{ .func = fn_ty };
            },
        };
    }

    fn setupFunctionSignatures(self: *@This()) InferError!void {
        const arena_alloc = self.typed.arena.allocator();
        const fn_count = self.resolved.functions.items.len;
        const reserve_extra: usize = if (hasTopLevelEntry(self.typed.module.entry)) 1 else 0;
        const infos = try arena_alloc.alloc(FunctionInfo, fn_count + reserve_extra);

        for (self.resolved.functions.items, 0..) |func_decl, idx| {
            var param_types = try std.ArrayList(Type).initCapacity(self.gpa, func_decl.params.len);
            defer param_types.deinit(self.gpa);
            for (func_decl.params) |param| {
                try param_types.append(self.gpa, try self.resolveTypeNode(param.ty));
            }
            const ret_ty = try self.resolveTypeNode(func_decl.ret_type);
            const fn_ty = try self.allocFuncType(param_types.items, ret_ty);
            infos[idx] = .{
                .decl = func_decl,
                .ty = fn_ty,
                .has_explicit_return = false,
            };
        }

        if (reserve_extra == 1) {
            const fake_ret_type = try arena_alloc.create(ast.TypeNode);
            fake_ret_type.* = .{ .name = "unit" };
            const fake_decl = try arena_alloc.create(ast.FuncDecl);
            fake_decl.* = .{
                .name = "__top_level_entry__",
                .params = &.{},
                .ret_type = fake_ret_type,
                .body = self.typed.module.entry,
            };
            const top_fn_ty = try self.allocFuncType(&.{}, .unit);
            infos[fn_count] = .{
                .decl = fake_decl,
                .ty = top_fn_ty,
                .has_explicit_return = false,
            };
        }

        self.typed.functions = infos;

        if (reserve_extra == 1) {
            self.typed.entry_function = @intCast(fn_count);
        } else if (self.resolved.function_names.get("main")) |main_id| {
            self.typed.entry_function = main_id;
        } else {
            self.typed.entry_function = if (fn_count > 0) 0 else 0;
        }
    }

    fn isNumeric(ty: Type) bool {
        return switch (ty) {
            .int, .float => true,
            else => false,
        };
    }

    fn isFallible(node: *const AstNode) bool {
        return switch (node.*) {
            .lt, .gt, .le, .ge, .eq, .ne => true,
            else => false,
        };
    }

    fn inferPair(self: *@This(), kids: *const [2]AstNode) InferError![2]Type {
        const lhs = try self.inferNode(&kids[0]);
        const rhs = try self.inferNode(&kids[1]);
        return .{ lhs, rhs };
    }

    fn inferArithmetic(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) InferError!Type {
        const pair = try self.inferPair(kids);
        if (!isNumeric(pair[0])) return self.failAtNode(&kids[0], error.ArithmeticRequiresNumeric);
        if (!isNumeric(pair[1])) return self.failAtNode(&kids[1], error.ArithmeticRequiresNumeric);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(node, error.ArithmeticOperandMismatch);
        return self.remember(node, pair[0]);
    }

    fn inferComparison(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) InferError!Type {
        const pair = try self.inferPair(kids);
        if (!isNumeric(pair[0])) return self.failAtNode(&kids[0], error.ComparisonRequiresNumeric);
        if (!isNumeric(pair[1])) return self.failAtNode(&kids[1], error.ComparisonRequiresNumeric);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(node, error.ComparisonOperandMismatch);
        return self.remember(node, .unit);
    }

    fn inferEquality(self: *@This(), node: *const AstNode, kids: *const [2]AstNode) InferError!Type {
        const pair = try self.inferPair(kids);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(node, error.EqualityOperandMismatch);
        switch (pair[0]) {
            .bool, .int, .float => {},
            .unit, .named, .func => return self.failAtNode(node, error.EqualityUnsupportedType),
        }
        return self.remember(node, .unit);
    }

    fn inferFallible(
        self: *@This(),
        node: *const AstNode,
        kids: *const [2]AstNode,
        comptime inferFn: fn (*@This(), *const AstNode, *const [2]AstNode) InferError!Type,
    ) InferError!Type {
        const result = try inferFn(self, node, kids);
        if (!self.in_fallible_scope) return self.failAtNode(node, error.FallibleOutsideFallibleContext);
        return result;
    }

    fn inferIf(self: *@This(), node: *const AstNode, if_node: *const ast.IfNode) InferError!Type {
        const prev_fallible = self.in_fallible_scope;
        self.in_fallible_scope = true;
        defer self.in_fallible_scope = prev_fallible;

        _ = try self.inferNode(if_node.cond);
        if (!isFallible(if_node.cond)) return self.failAtNode(if_node.cond, error.IfConditionNotFallible);

        const then_ty = then_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            break :then_blk try self.inferNode(if_node.then_);
        };

        if (if_node.else_) |else_node| {
            const else_ty = else_blk: {
                const mark = self.bindings.mark();
                defer self.bindings.restore(mark);
                break :else_blk try self.inferNode(else_node);
            };
            if (!typeEql(then_ty, else_ty)) return self.failAtNode(node, error.IfBranchTypeMismatch);
            return self.remember(node, then_ty);
        }

        if (!typeEql(then_ty, .unit)) return self.failAtNode(if_node.then_, error.IfWithoutElseRequiresUnit);
        return self.remember(node, .unit);
    }

    fn inferConst(self: *@This(), node: *const AstNode, const_node: *const ast.ConstNode) InferError!Type {
        const value_ty = try self.inferNode(const_node.value);
        if (const_node.ty) |annot| {
            const annot_ty = try self.resolveTypeNode(annot);
            if (!typeEql(value_ty, annot_ty)) return self.failAtNode(node, error.BindingTypeMismatch);
        }
        try self.pushBinding(node, const_node.name, .{ .ty = value_ty, .mutable = false });
        return self.remember(node, .unit);
    }

    fn inferVar(self: *@This(), node: *const AstNode, var_node: *const ast.VarNode) InferError!Type {
        const value_ty = try self.inferNode(var_node.value);
        if (var_node.ty) |annot| {
            const annot_ty = try self.resolveTypeNode(annot);
            if (!typeEql(value_ty, annot_ty)) return self.failAtNode(node, error.BindingTypeMismatch);
        }
        try self.pushBinding(node, var_node.name, .{ .ty = value_ty, .mutable = true });
        return self.remember(node, .unit);
    }

    fn inferAssign(self: *@This(), node: *const AstNode, assign_node: *const ast.VarNode) InferError!Type {
        const value_ty = try self.inferNode(assign_node.value);
        const binding = self.lookupBinding(assign_node.name) orelse return self.failAtNode(node, error.UnknownSymbol);
        if (!binding.mutable) return self.failAtNode(node, error.AssignToConst);
        if (!typeEql(binding.ty, value_ty)) return self.failAtNode(node, error.AssignmentTypeMismatch);
        return self.remember(node, .unit);
    }

    fn inferCall(self: *@This(), node: *const AstNode, call_node: *const ast.CallNode) InferError!Type {
        const callee_ty = try self.inferNode(call_node.callee);
        const fn_ty = switch (callee_ty) {
            .func => |sig| sig,
            else => return self.failAtNode(call_node.callee, error.CallTargetNotFunction),
        };

        if (call_node.args.len != fn_ty.params.len) return self.failAtNode(node, error.CallArityMismatch);

        for (call_node.args, 0..) |arg_node, idx| {
            const arg_ty = try self.inferNode(arg_node);
            if (!typeEql(arg_ty, fn_ty.params[idx])) return self.failAtNode(arg_node, error.CallArgumentMismatch);
        }

        return self.remember(node, fn_ty.ret);
    }

    fn inferReturn(self: *@This(), node: *const AstNode, ret_node: *const ast.ReturnNode) InferError!Type {
        const ret_ty = try self.inferNode(ret_node.value);
        if (!typeEql(ret_ty, self.current_return)) return self.failAtNode(node, error.ReturnTypeMismatch);
        self.current_saw_return = true;
        return self.remember(node, self.current_return);
    }

    fn findStructDeclFor(self: *const @This(), name: []const u8) ?*const ast.StructDecl {
        return findStructDecl(self.resolved, name);
    }

    fn inferStructInit(self: *@This(), node: *const AstNode, si_node: *const ast.StructInitNode) InferError!Type {
        const struct_decl = self.findStructDeclFor(si_node.struct_name) orelse return self.failAtNode(node, error.UnknownType);
        if (si_node.fields.len != struct_decl.fields.len) return self.failAtNode(node, error.StructInitFieldCountMismatch);
        for (si_node.fields, struct_decl.fields) |given, decl_field| {
            if (!std.mem.eql(u8, given.name, decl_field.name)) return self.failAtNode(node, error.StructInitFieldNameMismatch);
            const field_ty = try self.resolveTypeNode(decl_field.ty);
            const value_ty = try self.inferNode(given.value);
            if (!typeEql(value_ty, field_ty)) return self.failAtNode(node, error.BindingTypeMismatch);
        }
        return self.remember(node, .{ .named = si_node.struct_name });
    }

    fn inferFieldAccess(self: *@This(), node: *const AstNode, fa_node: *const ast.FieldAccessNode) InferError!Type {
        const target_ty = try self.inferNode(fa_node.target);
        const struct_name = switch (target_ty) {
            .named => |name| name,
            else => return self.failAtNode(node, error.FieldAccessOnNonStruct),
        };
        const struct_decl = self.findStructDeclFor(struct_name) orelse return self.failAtNode(node, error.UnknownType);
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name, fa_node.field)) {
                return self.remember(node, try self.resolveTypeNode(field.ty));
            }
        }
        return self.failAtNode(node, error.UnknownField);
    }

    fn inferBlock(self: *@This(), node: *const AstNode, block_node: *const ast.BlockNode) InferError!Type {
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        var result_ty: Type = .unit;
        for (block_node.items) |item| {
            result_ty = try self.inferNode(item);
        }
        return self.remember(node, result_ty);
    }

    fn inferVarRef(self: *@This(), node: *const AstNode, name: []const u8) InferError!Type {
        if (self.lookupBinding(name)) |binding| return self.remember(node, binding.ty);

        const resolved_ref = self.resolved.node_refs.get(nodeKey(node)) orelse return self.failAtNode(node, error.UnknownSymbol);
        switch (resolved_ref) {
            .local => return self.failAtNode(node, error.UnknownSymbol),
            .function => |fn_id| return self.remember(node, .{ .func = self.typed.functionType(fn_id) }),
        }
    }

    fn inferNode(self: *@This(), node: *const AstNode) InferError!Type {
        if (self.typed.node_types.get(nodeKey(node))) |existing| return existing;

        return switch (node.*) {
            .block => |blk| self.inferBlock(node, blk),
            .int => self.remember(node, .int),
            .float => self.remember(node, .float),
            .bool => self.remember(node, .bool),
            .unit => self.remember(node, .unit),
            .var_ref => |name| self.inferVarRef(node, name),
            .var_ => |vn| self.inferVar(node, vn),
            .assign => |an| self.inferAssign(node, an),
            .const_ => |cn| self.inferConst(node, cn),
            .return_ => |rn| self.inferReturn(node, rn),
            .call => |cn| self.inferCall(node, cn),
            .arg => self.remember(node, .int),
            .print => |child| blk: {
                const child_ty = try self.inferNode(child);
                switch (child_ty) {
                    .int, .float, .bool => {},
                    .unit => return self.failAtNode(child, error.PrintUnitValue),
                    .named, .func => return self.failAtNode(child, error.PrintUnsupportedType),
                }
                break :blk try self.remember(node, .unit);
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
            .struct_init => |si| self.inferStructInit(node, si),
            .field_access => |fa| self.inferFieldAccess(node, fa),
        };
    }

    fn checkFunction(self: *@This(), fn_id: u32) InferError!void {
        const info = &self.typed.functions[fn_id];
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        self.current_return = info.ty.ret;
        self.current_saw_return = false;

        for (info.decl.params, info.ty.params) |param, param_ty| {
            self.bindings.push(self.gpa, param.name, .{ .ty = param_ty, .mutable = false }) catch |err| switch (err) {
                error.DuplicateVariable => return self.failAtNode(info.decl.body, error.DuplicateSymbol),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        const body_ty = try self.inferNode(info.decl.body);
        if (!self.current_saw_return and !typeEql(body_ty, info.ty.ret)) {
            if (isSyntheticTopLevelEntry(info.decl)) {
                const mutable_sig = @constCast(info.ty);
                mutable_sig.ret = body_ty;
            } else {
                return self.failAtNode(info.decl.body, error.FunctionBodyTypeMismatch);
            }
        }
        info.has_explicit_return = self.current_saw_return;
    }

    fn run(self: *@This()) InferError!void {
        try self.setupFunctionSignatures();

        var idx: u32 = 0;
        while (idx < self.typed.functions.len) : (idx += 1) {
            try self.checkFunction(idx);
        }
    }
};

fn hasTopLevelEntry(node: *const AstNode) bool {
    return switch (node.*) {
        .unit => false,
        else => true,
    };
}

fn isSyntheticTopLevelEntry(decl: *const ast.FuncDecl) bool {
    return std.mem.eql(u8, decl.name, "__top_level_entry__");
}

fn findStructDecl(resolved: *const resolver.ResolvedAst, name: []const u8) ?*const ast.StructDecl {
    for (resolved.module.decls) |decl| {
        if (decl.* == .comptime_struct) {
            const st = decl.comptime_struct;
            if (std.mem.eql(u8, st.name, name)) return st;
        }
    }
    return null;
}

fn nodeKey(node: *const AstNode) usize {
    return @intFromPtr(node);
}

pub const TypeMemo = db.Memo(TypedAst);

pub fn computeType(
    resolve_memo: *const resolver.ResolveMemo,
    parse_memo: *const parser.ParseMemo,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!TypeMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, resolve_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var typed_value: ?TypedAst = null;
    if (resolve_memo.value) |*resolved| {
        const parsed = parse_memo.value orelse return db.makeMemo(TypedAst, null, diagnostics_list);
        const report = try typecheckReport(&parsed, resolved, gpa);
        if (report.diagnostic) |diag| {
            try diagnostics_list.append(gpa, diag);
        }
        typed_value = report.typed;
    }

    return db.makeMemo(TypedAst, typed_value, diagnostics_list);
}

pub fn typecheckReport(
    parsed: *const parser.ParsedAst,
    resolved: *const resolver.ResolvedAst,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!TypecheckReport {
    var checker = Checker.init(parsed, resolved, gpa);
    errdefer checker.deinit();

    checker.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TypecheckFailed => {
            const failure = checker.failure.?;
            checker.deinit();
            return .{
                .typed = null,
                .diagnostic = .{
                    .stage = .typecheck,
                    .span = failure.span,
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
