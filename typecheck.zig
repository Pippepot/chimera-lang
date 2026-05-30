const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

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
    decl: ast.NodeIdx,
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
    ast: *const ast.Ast,
    node_types: std.AutoHashMap(ast.NodeIdx, Type),
    functions: []FunctionInfo,
    entry_function: u32,

    pub fn init(gpa: std.mem.Allocator, parsed_ast: *const ast.Ast) TypedAst {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .ast = parsed_ast,
            .node_types = std.AutoHashMap(ast.NodeIdx, Type).init(gpa),
            .functions = &.{},
            .entry_function = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.node_types.deinit();
        self.arena.deinit();
    }

    pub fn typeOf(self: *const @This(), idx: ast.NodeIdx) TypeError!Type {
        return self.node_types.get(idx) orelse error.MissingNodeType;
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
        error.EqualityUnsupportedType => "equality is not supported for this type",
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
            .typed = TypedAst.init(gpa, &parsed.ast),
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

    fn spanOfNode(self: *const @This(), idx: ast.NodeIdx) ?ast.Span {
        return self.parsed.ast.spanOf(idx);
    }

    fn spanOfTypeNode(self: *const @This(), type_idx: ast.TypeIdx) ?ast.Span {
        return self.parsed.ast.spanOf(type_idx);
    }

    fn remember(self: *@This(), idx: ast.NodeIdx, ty: Type) std.mem.Allocator.Error!Type {
        try self.typed.node_types.put(idx, ty);
        return ty;
    }

    fn fail(self: *@This(), span: ?ast.Span, kind: TypeError) error{TypecheckFailed} {
        if (self.failure == null) self.failure = .{ .span = span, .kind = kind };
        return error.TypecheckFailed;
    }

    fn failAtNode(self: *@This(), idx: ast.NodeIdx, kind: TypeError) error{TypecheckFailed} {
        return self.fail(self.spanOfNode(idx), kind);
    }

    fn failAtType(self: *@This(), type_idx: ast.TypeIdx, kind: TypeError) error{TypecheckFailed} {
        return self.fail(self.spanOfTypeNode(type_idx), kind);
    }

    fn pushBinding(self: *@This(), idx: ast.NodeIdx, name: []const u8, binding: Binding) InferError!void {
        self.bindings.push(self.gpa, name, binding) catch |err| switch (err) {
            error.DuplicateVariable => return self.failAtNode(idx, error.DuplicateSymbol),
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

    fn resolveTypeNode(self: *@This(), type_idx: ast.TypeIdx) InferError!Type {
        const a = self.parsed.ast;
        switch (a.nodes[type_idx].tag) {
            .type_name => {
                const name = a.stringOf(a.nodes[type_idx].data0);
                if (std.mem.eql(u8, name, "unit")) return .unit;
                if (std.mem.eql(u8, name, "bool")) return .bool;
                if (std.mem.eql(u8, name, "int")) return .int;
                if (std.mem.eql(u8, name, "float")) return .float;
                if (self.resolved.struct_names.contains(name)) return .{ .named = name };
                return self.failAtType(type_idx, error.UnknownType);
            },
            .type_func => {
                const param_indices = a.funcTypeParams(type_idx);
                var params = try std.ArrayList(Type).initCapacity(self.gpa, param_indices.len);
                defer params.deinit(self.gpa);
                for (param_indices) |p| {
                    try params.append(self.gpa, try self.resolveTypeNode(p));
                }
                const ret_ty = try self.resolveTypeNode(a.funcTypeRet(type_idx));
                const fn_ty = try self.allocFuncType(params.items, ret_ty);
                return .{ .func = fn_ty };
            },
            else => return self.failAtType(type_idx, error.UnknownType),
        }
    }

    fn setupFunctionSignatures(self: *@This()) InferError!void {
        const arena_alloc = self.typed.arena.allocator();
        const fn_count = self.resolved.functions.items.len;
        const reserve_extra: usize = if (hasTopLevelEntry(self.parsed.ast, self.parsed.ast.entry)) 1 else 0;
        const infos = try arena_alloc.alloc(FunctionInfo, fn_count + reserve_extra);

        const a = self.parsed.ast;
        for (self.resolved.functions.items, 0..) |func_decl_idx, idx| {
            var param_types = try std.ArrayList(Type).initCapacity(self.gpa, a.fnParams(func_decl_idx).len);
            defer param_types.deinit(self.gpa);
            for (a.fnParams(func_decl_idx)) |param| {
                try param_types.append(self.gpa, try self.resolveTypeNode(param.ty));
            }
            const ret_ty = try self.resolveTypeNode(a.fnRetType(func_decl_idx));
            const fn_ty = try self.allocFuncType(param_types.items, ret_ty);
            infos[idx] = .{
                .decl = func_decl_idx,
                .ty = fn_ty,
                .has_explicit_return = false,
            };
        }

        if (reserve_extra == 1) {
            const top_fn_ty = try self.allocFuncType(&.{}, .unit);
            infos[fn_count] = .{
                .decl = std.math.maxInt(ast.NodeIdx),
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

    fn isFallibleNode(a: ast.Ast, idx: ast.NodeIdx) bool {
        return switch (a.nodes[idx].tag) {
            .lt, .gt, .le, .ge, .eq, .ne => true,
            else => false,
        };
    }

    fn inferPair(self: *@This(), lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError![2]Type {
        const l = try self.inferNode(lhs);
        const r = try self.inferNode(rhs);
        return .{ l, r };
    }

    fn inferArithmetic(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        const pair = try self.inferPair(lhs, rhs);
        if (!isNumeric(pair[0])) return self.failAtNode(lhs, error.ArithmeticRequiresNumeric);
        if (!isNumeric(pair[1])) return self.failAtNode(rhs, error.ArithmeticRequiresNumeric);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.ArithmeticOperandMismatch);
        return self.remember(idx, pair[0]);
    }

    fn inferComparison(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        const pair = try self.inferPair(lhs, rhs);
        if (!isNumeric(pair[0])) return self.failAtNode(lhs, error.ComparisonRequiresNumeric);
        if (!isNumeric(pair[1])) return self.failAtNode(rhs, error.ComparisonRequiresNumeric);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.ComparisonOperandMismatch);
        return self.remember(idx, .unit);
    }

    fn inferEquality(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        const pair = try self.inferPair(lhs, rhs);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.EqualityOperandMismatch);
        switch (pair[0]) {
            .bool, .int, .float => {},
            .unit, .named, .func => return self.failAtNode(idx, error.EqualityUnsupportedType),
        }
        return self.remember(idx, .unit);
    }

    fn inferFallible(
        self: *@This(),
        idx: ast.NodeIdx,
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
        comptime inferFn: fn (*@This(), ast.NodeIdx, ast.NodeIdx, ast.NodeIdx) InferError!Type,
    ) InferError!Type {
        const result = try inferFn(self, idx, lhs, rhs);
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        return result;
    }

    fn inferIf(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const prev_fallible = self.in_fallible_scope;
        self.in_fallible_scope = true;
        defer self.in_fallible_scope = prev_fallible;

        const a = self.parsed.ast;
        const data = a.ifData(idx);

        _ = try self.inferNode(data.cond);
        if (!isFallibleNode(a, data.cond)) return self.failAtNode(data.cond, error.IfConditionNotFallible);

        const then_ty = then_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            break :then_blk try self.inferNode(data.then_);
        };

        if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
            const else_ty = else_blk: {
                const mark = self.bindings.mark();
                defer self.bindings.restore(mark);
                break :else_blk try self.inferNode(data.else_);
            };
            if (!typeEql(then_ty, else_ty)) return self.failAtNode(idx, error.IfBranchTypeMismatch);
            return self.remember(idx, then_ty);
        }

        if (!typeEql(then_ty, .unit)) return self.failAtNode(data.then_, error.IfWithoutElseRequiresUnit);
        return self.remember(idx, .unit);
    }

    fn inferConst(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const name = a.stringOf(a.nodes[idx].data0);
        const value = a.varDeclValue(idx);
        const value_ty = try self.inferNode(value);
        if (a.varDeclHasType(idx)) {
            const annot_ty = try self.resolveTypeNode(a.varDeclType(idx).?);
            if (!typeEql(value_ty, annot_ty)) return self.failAtNode(idx, error.BindingTypeMismatch);
        }
        try self.pushBinding(idx, name, .{ .ty = value_ty, .mutable = false });
        return self.remember(idx, .unit);
    }

    fn inferVar(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const name = a.stringOf(a.nodes[idx].data0);
        const value = a.varDeclValue(idx);
        const value_ty = try self.inferNode(value);
        if (a.varDeclHasType(idx)) {
            const annot_ty = try self.resolveTypeNode(a.varDeclType(idx).?);
            if (!typeEql(value_ty, annot_ty)) return self.failAtNode(idx, error.BindingTypeMismatch);
        }
        try self.pushBinding(idx, name, .{ .ty = value_ty, .mutable = true });
        return self.remember(idx, .unit);
    }

    fn inferAssign(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const name = a.stringOf(a.nodes[idx].data0);
        const value = a.nodes[idx].data1;
        const value_ty = try self.inferNode(value);
        const binding = self.lookupBinding(name) orelse return self.failAtNode(idx, error.UnknownSymbol);
        if (!binding.mutable) return self.failAtNode(idx, error.AssignToConst);
        if (!typeEql(binding.ty, value_ty)) return self.failAtNode(idx, error.AssignmentTypeMismatch);
        return self.remember(idx, .unit);
    }

    fn inferCall(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const callee = a.nodes[idx].data0;
        const callee_ty = try self.inferNode(callee);
        const fn_ty = switch (callee_ty) {
            .func => |sig| sig,
            else => return self.failAtNode(callee, error.CallTargetNotFunction),
        };

        const args = a.callArgs(idx);
        if (args.len != fn_ty.params.len) return self.failAtNode(idx, error.CallArityMismatch);

        for (args, 0..) |arg_node, arg_idx| {
            const arg_ty = try self.inferNode(arg_node);
            if (!typeEql(arg_ty, fn_ty.params[arg_idx])) return self.failAtNode(arg_node, error.CallArgumentMismatch);
        }

        return self.remember(idx, fn_ty.ret);
    }

    fn inferReturn(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const ret_val = a.nodes[idx].data0;
        const ret_ty = try self.inferNode(ret_val);
        if (!typeEql(ret_ty, self.current_return)) return self.failAtNode(idx, error.ReturnTypeMismatch);
        self.current_saw_return = true;
        return self.remember(idx, self.current_return);
    }

    fn findStructDecl(self: *const @This(), name: []const u8) ?ast.NodeIdx {
        for (self.parsed.ast.decls) |decl_idx| {
            if (self.parsed.ast.nodes[decl_idx].tag == .comptime_struct) {
                const st_name = self.parsed.ast.stringOf(self.parsed.ast.nodes[decl_idx].data0);
                if (std.mem.eql(u8, st_name, name)) return decl_idx;
            }
        }
        return null;
    }

    fn inferStructInit(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const si_name_idx = a.structInitName(idx);
        const si_name = a.stringOf(si_name_idx);
        const struct_decl = self.findStructDecl(si_name) orelse return self.failAtNode(idx, error.UnknownType);

        const fields = a.structInitFields(idx);
        const decl_fields = a.structFields(struct_decl);
        if (fields.len != decl_fields.len) return self.failAtNode(idx, error.StructInitFieldCountMismatch);
        for (fields, decl_fields) |given, decl_field| {
            const given_name = a.stringOf(given.name);
            const decl_field_name = a.stringOf(decl_field.name);
            if (!std.mem.eql(u8, given_name, decl_field_name)) return self.failAtNode(idx, error.StructInitFieldNameMismatch);
            const field_ty = try self.resolveTypeNode(decl_field.ty);
            const value_ty = try self.inferNode(given.value);
            if (!typeEql(value_ty, field_ty)) return self.failAtNode(idx, error.BindingTypeMismatch);
        }
        return self.remember(idx, .{ .named = si_name });
    }

    fn inferFieldAccess(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const target = a.nodes[idx].data0;
        const field_name = a.stringOf(a.nodes[idx].data1);
        const target_ty = try self.inferNode(target);
        const struct_name = switch (target_ty) {
            .named => |name| name,
            else => return self.failAtNode(idx, error.FieldAccessOnNonStruct),
        };
        const struct_decl = self.findStructDecl(struct_name) orelse return self.failAtNode(idx, error.UnknownType);
        for (a.structFields(struct_decl)) |f| {
            const f_name = a.stringOf(f.name);
            if (std.mem.eql(u8, f_name, field_name)) {
                return self.remember(idx, try self.resolveTypeNode(f.ty));
            }
        }
        return self.failAtNode(idx, error.UnknownField);
    }

    fn inferBlock(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        var result_ty: Type = .unit;
        for (self.parsed.ast.blockItems(idx)) |item| {
            result_ty = try self.inferNode(item);
        }
        return self.remember(idx, result_ty);
    }

    fn inferVarRef(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const name = self.parsed.ast.stringOf(self.parsed.ast.nodes[idx].data0);
        if (self.lookupBinding(name)) |binding| return self.remember(idx, binding.ty);

        const resolved_ref = self.resolved.node_refs.get(idx) orelse return self.failAtNode(idx, error.UnknownSymbol);
        switch (resolved_ref) {
            .local => return self.failAtNode(idx, error.UnknownSymbol),
            .function => |fn_id| return self.remember(idx, .{ .func = self.typed.functionType(fn_id) }),
        }
    }

    fn inferNode(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        if (self.typed.node_types.get(idx)) |existing| return existing;

        const a = self.parsed.ast;
        return switch (a.nodes[idx].tag) {
            .block => self.inferBlock(idx),
            .int_lit => self.remember(idx, .int),
            .float_lit => self.remember(idx, .float),
            .bool_lit => self.remember(idx, .bool),
            .unit_lit => self.remember(idx, .unit),
            .var_ref => self.inferVarRef(idx),
            .var_decl => self.inferVar(idx),
            .assign => self.inferAssign(idx),
            .const_decl => self.inferConst(idx),
            .return_stmt => self.inferReturn(idx),
            .call => self.inferCall(idx),
            .arg => self.remember(idx, .int),
            .print_stmt => blk: {
                const child = a.nodes[idx].data0;
                const child_ty = try self.inferNode(child);
                switch (child_ty) {
                    .int, .float, .bool => {},
                    .unit => return self.failAtNode(child, error.PrintUnitValue),
                    .named, .func => return self.failAtNode(child, error.PrintUnsupportedType),
                }
                break :blk try self.remember(idx, .unit);
            },
            .add => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .sub => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .mul => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .div => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .lt => try self.inferFallible(idx, a.nodes[idx].data0, a.nodes[idx].data1, Checker.inferComparison),
            .gt => try self.inferFallible(idx, a.nodes[idx].data0, a.nodes[idx].data1, Checker.inferComparison),
            .le => try self.inferFallible(idx, a.nodes[idx].data0, a.nodes[idx].data1, Checker.inferComparison),
            .ge => try self.inferFallible(idx, a.nodes[idx].data0, a.nodes[idx].data1, Checker.inferComparison),
            .eq => try self.inferFallible(idx, a.nodes[idx].data0, a.nodes[idx].data1, Checker.inferEquality),
            .ne => try self.inferFallible(idx, a.nodes[idx].data0, a.nodes[idx].data1, Checker.inferEquality),
            .if_stmt => self.inferIf(idx),
            .struct_init => self.inferStructInit(idx),
            .field_access => self.inferFieldAccess(idx),
            .type_name, .type_func, .comptime_fn, .comptime_struct => unreachable,
        };
    }

    fn checkFunction(self: *@This(), fn_id: u32) InferError!void {
        const info = &self.typed.functions[fn_id];
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        self.current_return = info.ty.ret;
        self.current_saw_return = false;

        const is_top_level = info.decl == std.math.maxInt(ast.NodeIdx);
        if (!is_top_level) {
            const a = self.parsed.ast;
            for (a.fnParams(info.decl), info.ty.params) |param, param_ty| {
                const pname = a.stringOf(param.name);
                self.bindings.push(self.gpa, pname, .{ .ty = param_ty, .mutable = false }) catch |err| switch (err) {
                    error.DuplicateVariable => return self.failAtNode(info.decl, error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
        }

        const body = if (is_top_level) self.parsed.ast.entry else self.parsed.ast.fnBody(info.decl);
        const body_ty = try self.inferNode(body);
        if (!self.current_saw_return and !typeEql(body_ty, info.ty.ret)) {
            if (is_top_level) {
                const mutable_sig = @constCast(info.ty);
                mutable_sig.ret = body_ty;
            } else {
                return self.failAtNode(body, error.FunctionBodyTypeMismatch);
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

fn hasTopLevelEntry(a: ast.Ast, entry: ast.NodeIdx) bool {
    if (a.nodes[entry].tag == .block) return a.blockItems(entry).len > 0;
    if (a.nodes[entry].tag == .unit_lit) return false;
    return true;
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
        const parsed = if (parse_memo.value) |*p| p else return db.makeMemo(TypedAst, null, diagnostics_list);
        const report = try typecheckReport(parsed, resolved, gpa);
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
