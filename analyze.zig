const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

pub const FuncType = struct {
    params: []const Type,
    ret: Type,
};

pub const VariantType = struct {
    members: []const Type,
};

pub const Type = union(enum) {
    unit,
    bool,
    int,
    float,
    type_type,
    named: []const u8,
    func: *const FuncType,
    variant: *const VariantType,
};

pub fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unit, .bool, .int, .float, .type_type => true,
        .named => |lhs| std.mem.eql(u8, lhs, b.named),
        .func => |lhs| funcTypeEql(lhs, b.func),
        .variant => |lhs| variantTypeEql(lhs, b.variant),
    };
}

fn funcTypeEql(a: *const FuncType, b: *const FuncType) bool {
    if (a.params.len != b.params.len) return false;
    for (a.params, b.params) |left, right| {
        if (!typeEql(left, right)) return false;
    }
    return typeEql(a.ret, b.ret);
}

fn variantTypeEql(a: *const VariantType, b: *const VariantType) bool {
    if (a.members.len != b.members.len) return false;
    for (a.members, b.members) |left, right| {
        if (!typeEql(left, right)) return false;
    }
    return true;
}

pub const FunctionInfo = struct {
    decl: ast.NodeIdx,
    ty: *const FuncType,
    has_explicit_return: bool,
};

pub const StructValue = struct {
    decl: ast.NodeIdx,
    fields: []const ComptimeValue,
};

pub const ComptimeValue = union(enum) {
    unit,
    bool: bool,
    int: i32,
    float: f32,
    func: u32,
    struct_type: ast.NodeIdx,
    struct_value: StructValue,
    type_value: Type,
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
    LogicalOperandNotFallible,
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
    ComptimeCycle,
    ComptimeCaptureNotAllowed,
    ComptimePureOperationNotAllowed,
    ComptimeValueNotAvailable,
    RuntimeTypeValue,
    ComptimeValueNotAType,
    DuplicateVariantMember,
    IsOperandNotVariant,
    IsTypeNotInVariant,
};

pub const ResolvedField = struct {
    name: []const u8,
    ty: Type,
};

pub const AnalyzedAst = struct {
    arena: std.heap.ArenaAllocator,
    ast: *const ast.Ast,
    node_types: std.AutoHashMap(ast.NodeIdx, Type),
    field_index: std.AutoHashMap(ast.NodeIdx, u32),
    is_variant_tags: std.AutoHashMap(ast.NodeIdx, []const u32),
    decl_binding_types: std.AutoHashMap(ast.NodeIdx, Type),
    comptime_node_values: std.AutoHashMap(ast.NodeIdx, ComptimeValue),
    comptime_values: std.StringHashMap(ComptimeValue),
    comptime_struct_fields: std.StringHashMap([]const ResolvedField),
    struct_expr_fields: std.AutoHashMap(ast.NodeIdx, []const ResolvedField),
    functions: []FunctionInfo,
    entry_function: u32,

    pub fn init(gpa: std.mem.Allocator, parsed_ast: *const ast.Ast) AnalyzedAst {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .ast = parsed_ast,
            .node_types = std.AutoHashMap(ast.NodeIdx, Type).init(gpa),
            .field_index = std.AutoHashMap(ast.NodeIdx, u32).init(gpa),
            .is_variant_tags = std.AutoHashMap(ast.NodeIdx, []const u32).init(gpa),
            .decl_binding_types = std.AutoHashMap(ast.NodeIdx, Type).init(gpa),
            .comptime_node_values = std.AutoHashMap(ast.NodeIdx, ComptimeValue).init(gpa),
            .comptime_values = std.StringHashMap(ComptimeValue).init(gpa),
            .comptime_struct_fields = std.StringHashMap([]const ResolvedField).init(gpa),
            .struct_expr_fields = std.AutoHashMap(ast.NodeIdx, []const ResolvedField).init(gpa),
            .functions = &.{},
            .entry_function = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.node_types.deinit();
        self.field_index.deinit();
        self.is_variant_tags.deinit();
        self.decl_binding_types.deinit();
        self.comptime_node_values.deinit();
        self.comptime_values.deinit();
        self.comptime_struct_fields.deinit();
        self.struct_expr_fields.deinit();
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
    typed: ?AnalyzedAst,
    diagnostic: ?db.Diagnostic,
};

pub fn typeName(ty: Type) []const u8 {
    return switch (ty) {
        .unit => "unit",
        .bool => "bool",
        .int => "int",
        .float => "float",
        .type_type => "type",
        .named => |name| name,
        .func => "function",
        .variant => "variant",
    };
}

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
        error.LogicalOperandNotFallible => "logical operands must be fallible expressions",
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
        error.ComptimeCycle => "comptime dependency cycle",
        error.ComptimeCaptureNotAllowed => "comptime can only reference comptime symbols and comptime locals",
        error.ComptimePureOperationNotAllowed => "operation is not allowed in pure comptime execution",
        error.ComptimeValueNotAvailable => "comptime value is not available",
        error.RuntimeTypeValue => "type value cannot be used at runtime, use 'comptime' instead of 'const' or 'var'",
        error.ComptimeValueNotAType => "comptime value is not a type",
        error.DuplicateVariantMember => "duplicate variant member type",
        error.IsOperandNotVariant => "left side of 'is' must be a variant type",
        error.IsTypeNotInVariant => "right side of 'is' is not a member of the variant type",
    };
}

fn builtinType(name: []const u8) Type {
    if (std.mem.eql(u8, name, "unit")) return .unit;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "int")) return .int;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "type")) return .type_type;
    return .unit;
}

const Binding = struct {
    ty: Type,
    mutable: bool,
    comptime_visible: bool,
};

const Checker = struct {
    gpa: std.mem.Allocator,
    parsed: *const parser.ParsedAst,
    resolved: *const resolver.ResolvedAst,
    typed: AnalyzedAst,
    bindings: scope_mod.ScopeStack(Binding),
    comptime_decl_state: std.AutoHashMap(ast.NodeIdx, DeclState),
    failure: ?Failure,
    in_fallible_scope: bool,
    in_comptime_context: bool,
    current_return: Type,
    current_saw_return: bool,
    anon_counter: u32,

    const Failure = struct {
        span: ?ast.Span,
        kind: TypeError,
        expected_type: ?Type = null,
        actual_type: ?Type = null,
    };

    const InferError = std.mem.Allocator.Error || error{TypecheckFailed};

    const DeclPhase = enum {
        pending,
        running,
        done,
    };

    const DeclState = struct {
        ty_phase: DeclPhase = .pending,
        val_phase: DeclPhase = .pending,
        ty: ?Type = null,
        value: ?ComptimeValue = null,
    };

    const EvalBinding = struct {
        value: ComptimeValue,
        mutable: bool,
    };

    const EvalStep = struct {
        value: ComptimeValue,
        returned: bool,
    };

    fn init(parsed: *const parser.ParsedAst, resolved: *const resolver.ResolvedAst, gpa: std.mem.Allocator) Checker {
        return .{
            .gpa = gpa,
            .parsed = parsed,
            .resolved = resolved,
            .typed = AnalyzedAst.init(gpa, &parsed.ast),
            .bindings = scope_mod.ScopeStack(Binding).init(),
            .comptime_decl_state = std.AutoHashMap(ast.NodeIdx, DeclState).init(gpa),
            .failure = null,
            .in_fallible_scope = false,
            .in_comptime_context = false,
            .current_return = .unit,
            .current_saw_return = false,
            .anon_counter = 0,
        };
    }

    fn deinit(self: *@This()) void {
        self.typed.deinit();
        self.bindings.deinit(self.gpa);
        self.comptime_decl_state.deinit();
    }

    fn failAtNode(self: *@This(), idx: ast.NodeIdx, kind: TypeError) error{TypecheckFailed} {
        return self.fail(self.parsed.ast.spanOf(idx), kind);
    }

    fn failAtType(self: *@This(), type_idx: ast.TypeIdx, kind: TypeError) error{TypecheckFailed} {
        return self.fail(self.parsed.ast.spanOf(type_idx), kind);
    }

    fn failWithTypes(self: *@This(), span: ?ast.Span, kind: TypeError, expected: Type, actual: Type) error{TypecheckFailed} {
        if (self.failure == null) self.failure = .{ .span = span, .kind = kind, .expected_type = expected, .actual_type = actual };
        return error.TypecheckFailed;
    }

    fn failAtNodeWithTypes(self: *@This(), idx: ast.NodeIdx, kind: TypeError, expected: Type, actual: Type) error{TypecheckFailed} {
        return self.failWithTypes(self.parsed.ast.spanOf(idx), kind, expected, actual);
    }

    fn remember(self: *@This(), idx: ast.NodeIdx, ty: Type) std.mem.Allocator.Error!Type {
        try self.typed.node_types.put(idx, ty);
        return ty;
    }

    fn fail(self: *@This(), span: ?ast.Span, kind: TypeError) error{TypecheckFailed} {
        if (self.failure == null) self.failure = .{ .span = span, .kind = kind };
        return error.TypecheckFailed;
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

    fn allocVariantType(self: *@This(), members: []const Type) std.mem.Allocator.Error!*const VariantType {
        const arena_alloc = self.typed.arena.allocator();
        const owned_members = try arena_alloc.alloc(Type, members.len);
        @memcpy(owned_members, members);
        const variant_ty = try arena_alloc.create(VariantType);
        variant_ty.* = .{
            .members = owned_members,
        };
        return variant_ty;
    }

    fn variantMemberIndex(variant_ty: *const VariantType, member_ty: Type) ?u32 {
        for (variant_ty.members, 0..) |existing, index| {
            if (typeEql(existing, member_ty)) return @intCast(index);
        }
        return null;
    }

    fn isAssignableTo(target_ty: Type, value_ty: Type) bool {
        if (typeEql(target_ty, value_ty)) return true;
        return switch (target_ty) {
            .variant => |variant_ty| variantMemberIndex(variant_ty, value_ty) != null,
            else => false,
        };
    }

    fn resolveTypeNode(self: *@This(), type_idx: ast.TypeIdx) InferError!Type {
        const a = self.parsed.ast;
        switch (a.nodes[type_idx].tag) {
            .type_name => {
                const name = a.identOf(a.nodes[type_idx].data0);
                if (std.mem.eql(u8, name, "unit")) return .unit;
                if (std.mem.eql(u8, name, "bool")) return .bool;
                if (std.mem.eql(u8, name, "int")) return .int;
                if (std.mem.eql(u8, name, "float")) return .float;
                if (std.mem.eql(u8, name, "type")) return .type_type;
                if (self.resolved.struct_names.contains(name)) return .{ .named = name };
                if (self.resolved.comptime_value_names.get(name)) |decl_idx| {
                    var locals = scope_mod.ScopeStack(EvalBinding).init();
                    defer locals.deinit(self.gpa);
                    const cv = try self.evalComptimeDeclValue(decl_idx, &locals);
                    switch (cv) {
                        .type_value => |ty| return ty,
                        .struct_type => return .{ .named = name },
                        else => return self.failAtType(type_idx, error.ComptimeValueNotAType),
                    }
                }
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
            .type_variant => {
                const member_type_indices = a.variantTypeMembers(type_idx);
                var members = try std.ArrayList(Type).initCapacity(self.gpa, member_type_indices.len);
                defer members.deinit(self.gpa);
                for (member_type_indices) |member_type_idx| {
                    const member_ty = try self.resolveTypeNode(member_type_idx);
                    for (members.items) |existing| {
                        if (typeEql(existing, member_ty)) return self.failAtType(type_idx, error.DuplicateVariantMember);
                    }
                    try members.append(self.gpa, member_ty);
                }
                const variant_ty = try self.allocVariantType(members.items);
                return .{ .variant = variant_ty };
            },
            else => return self.failAtType(type_idx, error.UnknownType),
        }
    }

    fn setupFunctionSignatures(self: *@This()) InferError!void {
        const arena_alloc = self.typed.arena.allocator();
        const fn_count = self.resolved.functions.items.len;
        const has_top_level_entry = hasTopLevelEntry(self.parsed.ast, self.parsed.ast.entry);
        const main_fn_id = self.resolved.function_names.get("main");
        const reserve_extra: usize = if (has_top_level_entry or (fn_count == 0 and main_fn_id == null)) 1 else 0;
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
            if (a.comptimeFnAnnotation(func_decl_idx)) |annot| {
                const annot_ty = try self.resolveTypeNode(annot);
                if (!typeEql(.{ .func = fn_ty }, annot_ty)) return self.failAtNodeWithTypes(func_decl_idx, error.BindingTypeMismatch, annot_ty, .{ .func = fn_ty });
            }
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
        } else if (main_fn_id) |main_id| {
            self.typed.entry_function = main_id;
        } else {
            self.typed.entry_function = 0;
        }
    }

    fn validateTopLevelComptimeDecls(self: *@This()) InferError!void {
        for (self.parsed.ast.decls) |decl_idx| {
            if (self.parsed.ast.nodes[decl_idx].tag != .comptime_value_decl) continue;
            _ = try self.inferComptimeDeclType(decl_idx);
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
            .lt, .gt, .le, .ge, .eq, .ne, .is, .@"and", .@"or" => true,
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
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const pair = try self.inferPair(lhs, rhs);
        if (!isNumeric(pair[0])) return self.failAtNode(lhs, error.ComparisonRequiresNumeric);
        if (!isNumeric(pair[1])) return self.failAtNode(rhs, error.ComparisonRequiresNumeric);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.ComparisonOperandMismatch);
        return self.remember(idx, .unit);
    }

    fn inferEquality(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const pair = try self.inferPair(lhs, rhs);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.EqualityOperandMismatch);
        switch (pair[0]) {
            .bool, .int, .float => {},
            .unit, .named, .func, .type_type, .variant => return self.failAtNodeWithTypes(idx, error.EqualityUnsupportedType, pair[0], pair[0]),
        }
        return self.remember(idx, .unit);
    }

    fn inferLogical(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        _ = try self.inferNode(lhs);
        if (!isFallibleNode(self.parsed.ast, lhs)) return self.failAtNode(lhs, error.LogicalOperandNotFallible);
        _ = try self.inferNode(rhs);
        if (!isFallibleNode(self.parsed.ast, rhs)) return self.failAtNode(rhs, error.LogicalOperandNotFallible);
        return self.remember(idx, .unit);
    }

    fn inferIs(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs_type_idx: ast.TypeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const lhs_ty = try self.inferNode(lhs);
        const lhs_variant = switch (lhs_ty) {
            .variant => |variant_ty| variant_ty,
            else => return self.failAtNode(lhs, error.IsOperandNotVariant),
        };

        const rhs_ty = try self.resolveTypeNode(rhs_type_idx);
        var tag_values = try std.ArrayList(u32).initCapacity(self.gpa, 4);
        defer tag_values.deinit(self.gpa);

        switch (rhs_ty) {
            .variant => |rhs_variant| {
                for (rhs_variant.members) |member_ty| {
                    const member_index = variantMemberIndex(lhs_variant, member_ty) orelse return self.failAtType(rhs_type_idx, error.IsTypeNotInVariant);
                    var seen = false;
                    for (tag_values.items) |existing| {
                        if (existing == member_index) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try tag_values.append(self.gpa, member_index);
                }
            },
            else => {
                const member_index = variantMemberIndex(lhs_variant, rhs_ty) orelse return self.failAtType(rhs_type_idx, error.IsTypeNotInVariant);
                try tag_values.append(self.gpa, member_index);
            },
        }

        const arena_alloc = self.typed.arena.allocator();
        const owned_tags = try arena_alloc.alloc(u32, tag_values.items.len);
        @memcpy(owned_tags, tag_values.items);
        try self.typed.is_variant_tags.put(idx, owned_tags);
        return self.remember(idx, .unit);
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
            if (!typeEql(then_ty, else_ty)) return self.failAtNodeWithTypes(idx, error.IfBranchTypeMismatch, then_ty, else_ty);
            return self.remember(idx, then_ty);
        }

        if (!typeEql(then_ty, .unit)) return self.failAtNode(data.then_, error.IfWithoutElseRequiresUnit);
        return self.remember(idx, .unit);
    }

    fn inferDecl(self: *@This(), idx: ast.NodeIdx, mutable: bool) InferError!Type {
        const a = self.parsed.ast;
        const name = a.identOf(a.nodes[idx].data0);
        const value_ty = try self.inferNode(a.varDeclValue(idx));
        if (value_ty == .type_type) return self.failAtNode(idx, error.RuntimeTypeValue);
        var binding_ty = value_ty;
        if (a.varDeclHasType(idx)) {
            const annot_ty = try self.resolveTypeNode(a.varDeclType(idx).?);
            if (!isAssignableTo(annot_ty, value_ty)) return self.failAtNodeWithTypes(idx, error.BindingTypeMismatch, annot_ty, value_ty);
            binding_ty = annot_ty;
        }
        try self.pushBinding(idx, name, .{ .ty = binding_ty, .mutable = mutable, .comptime_visible = self.in_comptime_context });
        try self.typed.decl_binding_types.put(idx, binding_ty);
        return self.remember(idx, .unit);
    }

    fn inferAssign(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const name = a.identOf(a.nodes[idx].data0);
        const value = a.nodes[idx].data1;
        const value_ty = try self.inferNode(value);
        const binding = self.lookupBinding(name) orelse return self.failAtNode(idx, error.UnknownSymbol);
        if (!binding.mutable) return self.failAtNode(idx, error.AssignToConst);
        if (!isAssignableTo(binding.ty, value_ty)) return self.failAtNodeWithTypes(idx, error.AssignmentTypeMismatch, binding.ty, value_ty);
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
            if (!isAssignableTo(fn_ty.params[arg_idx], arg_ty)) return self.failAtNodeWithTypes(arg_node, error.CallArgumentMismatch, fn_ty.params[arg_idx], arg_ty);
        }

        return self.remember(idx, fn_ty.ret);
    }

    fn inferReturn(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const ret_val = a.nodes[idx].data0;
        const ret_ty = try self.inferNode(ret_val);
        if (!isAssignableTo(self.current_return, ret_ty)) return self.failAtNodeWithTypes(idx, error.ReturnTypeMismatch, self.current_return, ret_ty);
        self.current_saw_return = true;
        return self.remember(idx, .unit);
    }

    fn findStructDecl(self: *const @This(), name: []const u8) ?ast.NodeIdx {
        for (self.parsed.ast.decls) |decl_idx| {
            if (self.parsed.ast.nodes[decl_idx].tag == .comptime_struct) {
                const st_name = self.parsed.ast.identOf(self.parsed.ast.nodes[decl_idx].data0);
                if (std.mem.eql(u8, st_name, name)) return decl_idx;
            }
        }
        if (self.typed.comptime_struct_fields.contains(name)) return 0;
        return null;
    }

    fn ensureComptimeStructFields(self: *@This(), name: []const u8) InferError!void {
        if (self.typed.comptime_struct_fields.contains(name)) return;
        if (self.typed.comptime_values.contains(name)) return;
        if (self.resolved.comptime_value_names.get(name)) |decl_idx| {
            if (self.parsed.ast.nodes[decl_idx].tag == .comptime_value_decl) {
                // Check for cycles: if this decl is already running, skip
                const state = try self.comptimeDeclStatePtr(decl_idx);
                if (state.val_phase == .running) return;
                var eval_locals = scope_mod.ScopeStack(EvalBinding).init();
                defer eval_locals.deinit(self.gpa);
                const value = try self.evalComptimeDeclValue(decl_idx, &eval_locals);
                switch (value) {
                    .struct_type => |struct_node| {
                        if (self.typed.struct_expr_fields.get(struct_node)) |resolved| {
                            try self.typed.comptime_struct_fields.put(name, resolved);
                        }
                    },
                    else => {},
                }
            }
        }
    }

    fn comptimeDeclStatePtr(self: *@This(), decl_idx: ast.NodeIdx) InferError!*DeclState {
        if (self.comptime_decl_state.getPtr(decl_idx)) |state| return state;
        try self.comptime_decl_state.put(decl_idx, .{});
        return self.comptime_decl_state.getPtr(decl_idx).?;
    }

    fn evalBindingIndex(bindings: *scope_mod.ScopeStack(EvalBinding), name: []const u8) ?usize {
        var idx = bindings.entries.items.len;
        while (idx > 0) {
            idx -= 1;
            if (std.mem.eql(u8, bindings.entries.items[idx].name, name)) return idx;
        }
        return null;
    }

    fn materializeAnonStructType(self: *@This(), source_idx: ast.NodeIdx, struct_node: ast.NodeIdx) InferError!Type {
        if (self.typed.struct_expr_fields.get(struct_node)) |resolved_fields| {
            const anon_name = try std.fmt.allocPrint(self.typed.arena.allocator(), "$anon{}", .{self.anon_counter});
            self.anon_counter += 1;
            try self.typed.comptime_struct_fields.put(anon_name, resolved_fields);
            return .{ .named = anon_name };
        }
        return self.failAtNode(source_idx, error.ComptimeValueNotAType);
    }

    fn typeFromComptimeValue(self: *@This(), source_idx: ast.NodeIdx, value: ComptimeValue) InferError!Type {
        return switch (value) {
            .type_value => |ty| ty,
            .struct_type => |struct_node| blk: {
                const source_node = self.parsed.ast.nodes[source_idx];
                if (source_node.tag == .var_ref) {
                    break :blk .{ .named = self.parsed.ast.identOf(source_node.data0) };
                }
                const struct_ast_node = self.parsed.ast.nodes[struct_node];
                if (struct_ast_node.tag == .comptime_struct) {
                    break :blk .{ .named = self.parsed.ast.identOf(struct_ast_node.data0) };
                }
                break :blk try self.materializeAnonStructType(source_idx, struct_node);
            },
            else => self.failAtNode(source_idx, error.ComptimeValueNotAType),
        };
    }

    fn inferTypeUnionExpr(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        if (!self.in_comptime_context) return self.failAtNode(idx, error.RuntimeTypeValue);
        const members = self.parsed.ast.typeUnionMembers(idx);
        var member_types = try std.ArrayList(Type).initCapacity(self.gpa, members.len);
        defer member_types.deinit(self.gpa);

        for (members) |member_node| {
            _ = try self.inferNode(member_node);
            var eval_locals = scope_mod.ScopeStack(EvalBinding).init();
            defer eval_locals.deinit(self.gpa);
            const member_value = (try self.evalNodeStep(member_node, &eval_locals)).value;
            const member_ty = try self.typeFromComptimeValue(member_node, member_value);
            for (member_types.items) |existing| {
                if (typeEql(existing, member_ty)) return self.failAtNode(member_node, error.DuplicateVariantMember);
            }
            try member_types.append(self.gpa, member_ty);
        }

        _ = try self.allocVariantType(member_types.items);
        return self.remember(idx, .type_type);
    }

    fn inferStructInit(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const type_expr = a.structInitTypeExpr(idx);

        if (a.nodes[type_expr].tag == .call) {
            var eval_locals = scope_mod.ScopeStack(EvalBinding).init();
            defer eval_locals.deinit(self.gpa);
            const eval_result = try self.evalNodeStep(type_expr, &eval_locals);
            const struct_node = switch (eval_result.value) {
                .struct_type => |n| n,
                else => return self.failAtNode(idx, error.UnknownType),
            };
            if (self.typed.struct_expr_fields.get(struct_node)) |resolved_fields| {
                const fields = a.structInitFields(idx);
                if (fields.len != resolved_fields.len) return self.failAtNode(idx, error.StructInitFieldCountMismatch);
                for (fields, resolved_fields) |given, resolved| {
                    const given_name = a.identOf(given.name);
                    if (!std.mem.eql(u8, given_name, resolved.name)) return self.failAtNode(idx, error.StructInitFieldNameMismatch);
                    const value_ty = try self.inferNode(given.value);
                    if (!typeEql(value_ty, resolved.ty)) return self.failAtNodeWithTypes(idx, error.BindingTypeMismatch, resolved.ty, value_ty);
                }
                const anon_name = try std.fmt.allocPrint(self.typed.arena.allocator(), "$anon{}", .{self.anon_counter});
                self.anon_counter += 1;
                try self.typed.comptime_struct_fields.put(anon_name, resolved_fields);
                return self.remember(idx, .{ .named = anon_name });
            }
            return self.failAtNode(idx, error.UnknownType);
        }

        const si_name_idx = a.structInitName(idx);
        if (si_name_idx == std.math.maxInt(ast.IdentIdx)) return self.failAtNode(idx, error.UnknownType);
        const si_name = a.identOf(si_name_idx);

        if (self.findStructDecl(si_name)) |struct_decl| {
            if (struct_decl != 0) {
                const fields = a.structInitFields(idx);
                const decl_fields = a.structFields(struct_decl);
                if (fields.len != decl_fields.len) return self.failAtNode(idx, error.StructInitFieldCountMismatch);
                for (fields, decl_fields) |given, decl_field| {
                    const given_name = a.identOf(given.name);
                    const decl_field_name = a.identOf(decl_field.name);
                    if (!std.mem.eql(u8, given_name, decl_field_name)) return self.failAtNode(idx, error.StructInitFieldNameMismatch);
                    const field_ty = try self.resolveTypeNode(decl_field.ty);
                    const value_ty = try self.inferNode(given.value);
                    if (!typeEql(value_ty, field_ty)) return self.failAtNodeWithTypes(idx, error.BindingTypeMismatch, field_ty, value_ty);
                }
                return self.remember(idx, .{ .named = si_name });
            }
        }

        try self.ensureComptimeStructFields(si_name);
        if (self.typed.comptime_struct_fields.get(si_name)) |resolved_fields| {
            const fields = a.structInitFields(idx);
            if (fields.len != resolved_fields.len) return self.failAtNode(idx, error.StructInitFieldCountMismatch);
            for (fields, resolved_fields) |given, resolved| {
                const given_name = a.identOf(given.name);
                if (!std.mem.eql(u8, given_name, resolved.name)) return self.failAtNode(idx, error.StructInitFieldNameMismatch);
                const value_ty = try self.inferNode(given.value);
                if (!typeEql(value_ty, resolved.ty)) return self.failAtNodeWithTypes(idx, error.BindingTypeMismatch, resolved.ty, value_ty);
            }
            return self.remember(idx, .{ .named = si_name });
        }

        return self.failAtNode(idx, error.UnknownType);
    }

    fn inferFieldAccess(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const target = a.nodes[idx].data0;
        const field_name = a.identOf(a.nodes[idx].data1);
        const target_ty = try self.inferNode(target);
        const struct_name = switch (target_ty) {
            .named => |name| name,
            else => return self.failAtNode(idx, error.FieldAccessOnNonStruct),
        };

        if (self.findStructDecl(struct_name)) |struct_decl| {
            if (struct_decl != 0) {
                for (a.structFields(struct_decl), 0..) |f, i| {
                    const f_name = a.identOf(f.name);
                    if (std.mem.eql(u8, f_name, field_name)) {
                        try self.typed.field_index.put(idx, @intCast(i));
                        return self.remember(idx, try self.resolveTypeNode(f.ty));
                    }
                }
                return self.failAtNode(idx, error.UnknownField);
            }
        }

        if (self.typed.comptime_struct_fields.get(struct_name)) |resolved_fields| {
            for (resolved_fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, field_name)) {
                    try self.typed.field_index.put(idx, @intCast(i));
                    return self.remember(idx, f.ty);
                }
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

    fn inferComptimeDeclType(self: *@This(), decl_idx: ast.NodeIdx) InferError!Type {
        const decl = self.parsed.ast.nodes[decl_idx];
        return switch (decl.tag) {
            .comptime_fn => blk: {
                const a = self.parsed.ast;
                const name = a.identOf(decl.data0);
                const fn_id = self.resolved.function_names.get(name) orelse return self.failAtNode(decl_idx, error.UnknownSymbol);
                const fn_ty: Type = .{ .func = self.typed.functionType(fn_id) };
                if (a.comptimeFnAnnotation(decl_idx)) |annot| {
                    const annot_ty = try self.resolveTypeNode(annot);
                    if (!typeEql(fn_ty, annot_ty)) return self.failAtNodeWithTypes(decl_idx, error.BindingTypeMismatch, annot_ty, fn_ty);
                }
                break :blk fn_ty;
            },
            .comptime_struct => blk: {
                const a = self.parsed.ast;
                const name = a.identOf(decl.data0);
                const struct_ty: Type = .{ .named = name };
                if (a.comptimeStructAnnotation(decl_idx)) |annot| {
                    const annot_ty = try self.resolveTypeNode(annot);
                    if (!typeEql(struct_ty, annot_ty)) return self.failAtNodeWithTypes(decl_idx, error.BindingTypeMismatch, annot_ty, struct_ty);
                }
                break :blk struct_ty;
            },
            .comptime_value_decl => blk: {
                const a = self.parsed.ast;
                const state = try self.comptimeDeclStatePtr(decl_idx);
                switch (state.ty_phase) {
                    .done => break :blk state.ty.?,
                    .running => return self.failAtNode(decl_idx, error.ComptimeCycle),
                    .pending => {},
                }

                state.ty_phase = .running;
                const prev = self.in_comptime_context;
                self.in_comptime_context = true;
                const value_ty = self.inferNode(a.comptimeValueDeclValue(decl_idx)) catch |err| {
                    self.in_comptime_context = prev;
                    state.ty_phase = .pending;
                    return err;
                };
                self.in_comptime_context = prev;
                if (a.comptimeValueDeclHasType(decl_idx)) {
                    const annot_ty = try self.resolveTypeNode(a.comptimeValueDeclType(decl_idx).?);
                    if (!typeEql(value_ty, annot_ty)) return self.failAtNodeWithTypes(decl_idx, error.BindingTypeMismatch, annot_ty, value_ty);
                }
                state.ty = value_ty;
                state.ty_phase = .done;
                break :blk value_ty;
            },
            else => return self.failAtNode(decl_idx, error.UnknownSymbol),
        };
    }

    fn cloneCtValue(self: *@This(), value: ComptimeValue) std.mem.Allocator.Error!ComptimeValue {
        return switch (value) {
            .struct_value => |sv| blk: {
                const arena_alloc = self.typed.arena.allocator();
                const copied_fields = try arena_alloc.alloc(ComptimeValue, sv.fields.len);
                for (sv.fields, 0..) |f, i| copied_fields[i] = try self.cloneCtValue(f);
                break :blk .{ .struct_value = .{
                    .decl = sv.decl,
                    .fields = copied_fields,
                } };
            },
            .type_value => |ty| .{ .type_value = ty },
            else => value,
        };
    }

    fn runtimeTypeOfComptimeValue(self: *@This(), source_idx: ast.NodeIdx, value: ComptimeValue) InferError!Type {
        return switch (value) {
            .unit => .unit,
            .bool => .bool,
            .int => .int,
            .float => .float,
            .func => |fn_id| .{ .func = self.typed.functionType(fn_id) },
            .struct_value => |sv| blk: {
                const decl_node = self.parsed.ast.nodes[sv.decl];
                if (decl_node.tag == .comptime_struct) {
                    break :blk .{ .named = self.parsed.ast.identOf(decl_node.data0) };
                }
                break :blk try self.materializeAnonStructType(source_idx, sv.decl);
            },
            .type_value, .struct_type => self.failAtNode(source_idx, error.ComptimeValueNotAType),
        };
    }

    fn evalPredicate(self: *@This(), idx: ast.NodeIdx, locals: *scope_mod.ScopeStack(EvalBinding)) InferError!bool {
        const a = self.parsed.ast;
        const tag = a.nodes[idx].tag;
        return switch (tag) {
            .@"and" => {
                if (!try self.evalPredicate(a.nodes[idx].data0, locals)) return false;
                return self.evalPredicate(a.nodes[idx].data1, locals);
            },
            .@"or" => {
                if (try self.evalPredicate(a.nodes[idx].data0, locals)) return true;
                return self.evalPredicate(a.nodes[idx].data1, locals);
            },
            .lt, .gt, .le, .ge, .eq, .ne => blk: {
                const lhs_v = (try self.evalNodeStep(a.nodes[idx].data0, locals)).value;
                const rhs_v = (try self.evalNodeStep(a.nodes[idx].data1, locals)).value;
                break :blk switch (lhs_v) {
                    .int => |lv| switch (tag) {
                        .lt => lv < rhs_v.int,
                        .gt => lv > rhs_v.int,
                        .le => lv <= rhs_v.int,
                        .ge => lv >= rhs_v.int,
                        .eq => lv == rhs_v.int,
                        .ne => lv != rhs_v.int,
                        else => unreachable,
                    },
                    .float => |lv| switch (tag) {
                        .lt => lv < rhs_v.float,
                        .gt => lv > rhs_v.float,
                        .le => lv <= rhs_v.float,
                        .ge => lv >= rhs_v.float,
                        .eq => lv == rhs_v.float,
                        .ne => lv != rhs_v.float,
                        else => unreachable,
                    },
                    .bool => |lv| switch (tag) {
                        .eq => lv == rhs_v.bool,
                        .ne => lv != rhs_v.bool,
                        else => false,
                    },
                    else => false,
                };
            },
            .is => blk: {
                const lhs_node = a.isLhs(idx);
                const lhs_value = (try self.evalNodeStep(lhs_node, locals)).value;
                const lhs_ty = try self.runtimeTypeOfComptimeValue(lhs_node, lhs_value);
                const rhs_ty = try self.resolveTypeNode(a.isRhsType(idx));
                break :blk switch (rhs_ty) {
                    .variant => |rhs_variant| variantMemberIndex(rhs_variant, lhs_ty) != null,
                    else => typeEql(lhs_ty, rhs_ty),
                };
            },
            else => false,
        };
    }

    fn evalComptimeDeclValue(self: *@This(), decl_idx: ast.NodeIdx, locals: *scope_mod.ScopeStack(EvalBinding)) InferError!ComptimeValue {
        const decl = self.parsed.ast.nodes[decl_idx];
        switch (decl.tag) {
            .comptime_fn => {
                const name = self.parsed.ast.identOf(decl.data0);
                const v: ComptimeValue = .{ .func = self.resolved.function_names.get(name).? };
                try self.typed.comptime_values.put(name, v);
                return v;
            },
            .comptime_struct => {
                const name = self.parsed.ast.identOf(decl.data0);
                const v: ComptimeValue = .{ .struct_type = decl_idx };
                try self.typed.comptime_values.put(name, v);
                return v;
            },
            .comptime_value_decl => {
                const a = self.parsed.ast;
                const state = try self.comptimeDeclStatePtr(decl_idx);
                switch (state.val_phase) {
                    .done => return state.value.?,
                    .running => return self.failAtNode(decl_idx, error.ComptimeCycle),
                    .pending => {},
                }

                state.val_phase = .running;
                const prev = self.in_comptime_context;
                self.in_comptime_context = true;
                const eval_result = self.evalNodeStep(a.comptimeValueDeclValue(decl_idx), locals) catch |err| {
                    self.in_comptime_context = prev;
                    state.val_phase = .pending;
                    return err;
                };
                self.in_comptime_context = prev;
                state.value = eval_result.value;
                state.val_phase = .done;
                const decl_name = a.identOf(decl.data0);
                try self.typed.comptime_values.put(decl_name, eval_result.value);
                switch (eval_result.value) {
                    .struct_type => |struct_node| {
                        if (self.typed.struct_expr_fields.get(struct_node)) |resolved| {
                            try self.typed.comptime_struct_fields.put(decl_name, resolved);
                        }
                    },
                    else => {},
                }
                return eval_result.value;
            },
            else => return self.failAtNode(decl_idx, error.ComptimeValueNotAvailable),
        }
    }

    fn evalFunction(self: *@This(), fn_id: u32, args: []const ComptimeValue) InferError!ComptimeValue {
        const info = self.typed.functions[fn_id];
        if (info.decl == std.math.maxInt(ast.NodeIdx)) return .unit;

        var locals = scope_mod.ScopeStack(EvalBinding).init();
        defer locals.deinit(self.gpa);

        const fn_params = self.parsed.ast.fnParams(info.decl);
        for (fn_params, args) |param, arg_value| {
            const pname = self.parsed.ast.identOf(param.name);
            try self.pushLocal(&locals, info.decl, pname, .{ .value = try self.cloneCtValue(arg_value), .mutable = false });
        }

        const step = try self.evalNodeStep(self.parsed.ast.fnBody(info.decl), &locals);
        return step.value;
    }

    fn pushLocal(self: *@This(), locals: *scope_mod.ScopeStack(EvalBinding), idx: ast.NodeIdx, name: []const u8, eb: EvalBinding) InferError!void {
        locals.push(self.gpa, name, eb) catch |err| switch (err) {
            error.DuplicateVariable => return self.failAtNode(idx, error.DuplicateSymbol),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn evalDecl(self: *@This(), idx: ast.NodeIdx, mutable: bool, locals: *scope_mod.ScopeStack(EvalBinding)) InferError!EvalStep {
        const a = self.parsed.ast;
        const name = a.identOf(a.nodes[idx].data0);
        const value = (try self.evalNodeStep(a.varDeclValue(idx), locals)).value;
        try self.pushLocal(locals, idx, name, .{ .value = try self.cloneCtValue(value), .mutable = mutable });
        return .{ .value = .unit, .returned = false };
    }

    fn evalArithmetic(self: *@This(), idx: ast.NodeIdx, locals: *scope_mod.ScopeStack(EvalBinding)) InferError!EvalStep {
        const a = self.parsed.ast;
        const l = (try self.evalNodeStep(a.nodes[idx].data0, locals)).value;
        const r = (try self.evalNodeStep(a.nodes[idx].data1, locals)).value;
        const v: ComptimeValue = switch (l) {
            .int => |lv| .{ .int = switch (a.nodes[idx].tag) {
                .add => lv + r.int,
                .sub => lv - r.int,
                .mul => lv * r.int,
                .div => @divTrunc(lv, r.int),
                else => unreachable,
            } },
            .float => |lv| .{ .float = switch (a.nodes[idx].tag) {
                .add => lv + r.float,
                .sub => lv - r.float,
                .mul => lv * r.float,
                .div => lv / r.float,
                else => unreachable,
            } },
            else => return self.failAtNode(idx, error.ArithmeticRequiresNumeric),
        };
        return .{ .value = v, .returned = false };
    }

    fn evalNodeStep(self: *@This(), idx: ast.NodeIdx, locals: *scope_mod.ScopeStack(EvalBinding)) InferError!EvalStep {
        const a = self.parsed.ast;
        return switch (a.nodes[idx].tag) {
            .block => blk: {
                const mark = locals.mark();
                defer locals.restore(mark);
                var last: ComptimeValue = .unit;
                for (a.blockItems(idx)) |item| {
                    const step = try self.evalNodeStep(item, locals);
                    last = step.value;
                    if (step.returned) break :blk .{ .value = step.value, .returned = true };
                }
                break :blk .{ .value = last, .returned = false };
            },
            .int_lit => .{ .value = .{ .int = @bitCast(a.nodes[idx].data0) }, .returned = false },
            .float_lit => .{ .value = .{ .float = @bitCast(a.nodes[idx].data0) }, .returned = false },
            .bool_lit => .{ .value = .{ .bool = a.nodes[idx].data0 != 0 }, .returned = false },
            .unit_lit => .{ .value = .unit, .returned = false },
            .var_ref => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                if (evalBindingIndex(locals, name)) |binding_idx| {
                    break :blk .{ .value = locals.entries.items[binding_idx].value.value, .returned = false };
                }
                const resolved_ref = self.resolved.node_refs.get(idx) orelse return self.failAtNode(idx, error.UnknownSymbol);
                switch (resolved_ref) {
                    .function => |fn_id| break :blk .{ .value = .{ .func = fn_id }, .returned = false },
                    .struct_decl => |decl_idx| break :blk .{ .value = .{ .struct_type = decl_idx }, .returned = false },
                    .comptime_value => |decl_idx| break :blk .{ .value = try self.evalComptimeDeclValue(decl_idx, locals), .returned = false },
                    .builtin_type => break :blk .{ .value = .{ .type_value = builtinType(name) }, .returned = false },
                    .local => return self.failAtNode(idx, error.ComptimeCaptureNotAllowed),
                }
            },
            .const_decl => try self.evalDecl(idx, false, locals),
            .var_decl => try self.evalDecl(idx, true, locals),
            .assign => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                const value = (try self.evalNodeStep(a.nodes[idx].data1, locals)).value;
                const binding_idx = evalBindingIndex(locals, name) orelse return self.failAtNode(idx, error.ComptimeCaptureNotAllowed);
                if (!locals.entries.items[binding_idx].value.mutable) return self.failAtNode(idx, error.AssignToConst);
                locals.entries.items[binding_idx].value.value = try self.cloneCtValue(value);
                break :blk .{ .value = .unit, .returned = false };
            },
            .return_stmt => blk: {
                const value = (try self.evalNodeStep(a.nodes[idx].data0, locals)).value;
                break :blk .{ .value = value, .returned = true };
            },
            .call => blk: {
                const callee = (try self.evalNodeStep(a.nodes[idx].data0, locals)).value;
                const fn_id = switch (callee) {
                    .func => |id| id,
                    else => return self.failAtNode(idx, error.CallTargetNotFunction),
                };

                const arg_nodes = a.callArgs(idx);
                var arg_values = try std.ArrayList(ComptimeValue).initCapacity(self.gpa, arg_nodes.len);
                defer arg_values.deinit(self.gpa);
                for (arg_nodes) |arg_node| {
                    const arg_value = (try self.evalNodeStep(arg_node, locals)).value;
                    try arg_values.append(self.gpa, try self.cloneCtValue(arg_value));
                }
                break :blk .{ .value = try self.evalFunction(fn_id, arg_values.items), .returned = false };
            },
            .print_stmt, .arg => self.failAtNode(idx, error.ComptimePureOperationNotAllowed),
            .add, .sub, .mul, .div => try self.evalArithmetic(idx, locals),
            .lt, .gt, .le, .ge, .eq, .ne, .is, .@"and", .@"or" => .{ .value = .unit, .returned = false },
            .if_stmt => blk: {
                const data = a.ifData(idx);
                const pred = try self.evalPredicate(data.cond, locals);
                if (pred) break :blk try self.evalNodeStep(data.then_, locals);
                if (data.else_ != std.math.maxInt(ast.NodeIdx)) break :blk try self.evalNodeStep(data.else_, locals);
                break :blk .{ .value = .unit, .returned = false };
            },
            .struct_init => blk: {
                const type_expr = a.structInitTypeExpr(idx);
                if (a.nodes[type_expr].tag == .call) {
                    const eval_result = try self.evalNodeStep(type_expr, locals);
                    const struct_node = switch (eval_result.value) {
                        .struct_type => |n| n,
                        else => return self.failAtNode(idx, error.UnknownType),
                    };
                    const fields = a.structInitFields(idx);
                    const arena_alloc = self.typed.arena.allocator();
                    const values = try arena_alloc.alloc(ComptimeValue, fields.len);
                    for (fields, 0..) |field, i| {
                        values[i] = (try self.evalNodeStep(field.value, locals)).value;
                    }
                    break :blk .{ .value = .{ .struct_value = .{
                        .decl = struct_node,
                        .fields = values,
                    } }, .returned = false };
                }
                const si_name = a.identOf(a.structInitName(idx));
                const decl = self.findStructDecl(si_name) orelse return self.failAtNode(idx, error.UnknownType);
                const fields = a.structInitFields(idx);
                const arena_alloc = self.typed.arena.allocator();
                const values = try arena_alloc.alloc(ComptimeValue, fields.len);
                for (fields, 0..) |field, i| {
                    values[i] = (try self.evalNodeStep(field.value, locals)).value;
                }
                break :blk .{ .value = .{ .struct_value = .{
                    .decl = decl,
                    .fields = values,
                } }, .returned = false };
            },
            .field_access => blk: {
                const target = (try self.evalNodeStep(a.nodes[idx].data0, locals)).value;
                const field_idx = self.typed.field_index.get(idx) orelse return self.failAtNode(idx, error.UnknownField);
                const sv = switch (target) {
                    .struct_value => |v| v,
                    else => return self.failAtNode(idx, error.FieldAccessOnNonStruct),
                };
                break :blk .{ .value = sv.fields[field_idx], .returned = false };
            },
            .comptime_expr => self.evalNodeStep(a.comptimeExprBody(idx), locals),
            .comptime_value_decl => .{ .value = .unit, .returned = false },
            .comptime_fn, .comptime_struct => .{ .value = .unit, .returned = false },
            .type_name => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                if (evalBindingIndex(locals, name)) |binding_idx| {
                    break :blk .{ .value = locals.entries.items[binding_idx].value.value, .returned = false };
                }
                const ty = builtinType(name);
                break :blk .{ .value = .{ .type_value = ty }, .returned = false };
            },
            .type_func => blk: {
                const ty = try self.resolveTypeNode(idx);
                break :blk .{ .value = .{ .type_value = ty }, .returned = false };
            },
            .type_union => blk: {
                const members = a.typeUnionMembers(idx);
                var member_types = try std.ArrayList(Type).initCapacity(self.gpa, members.len);
                defer member_types.deinit(self.gpa);
                for (members) |member_node| {
                    const member_value = (try self.evalNodeStep(member_node, locals)).value;
                    const member_ty = try self.typeFromComptimeValue(member_node, member_value);
                    for (member_types.items) |existing| {
                        if (typeEql(existing, member_ty)) return self.failAtNode(member_node, error.DuplicateVariantMember);
                    }
                    try member_types.append(self.gpa, member_ty);
                }
                const variant_ty = try self.allocVariantType(member_types.items);
                break :blk .{ .value = .{ .type_value = .{ .variant = variant_ty } }, .returned = false };
            },
            .struct_expr => blk: {
                const fields = a.structExprFields(idx);
                const arena_alloc = self.typed.arena.allocator();
                const resolved = try arena_alloc.alloc(ResolvedField, fields.len);
                for (fields, 0..) |field, i| {
                    const ty_value = (try self.evalNodeStep(field.ty, locals)).value;
                    const field_ty: Type = switch (ty_value) {
                        .type_value => |ty| ty,
                        .struct_type => .{ .named = self.parsed.ast.identOf(self.parsed.ast.nodes[ty_value.struct_type].data0) },
                        else => return self.failAtNode(idx, error.ComptimeValueNotAvailable),
                    };
                    resolved[i] = .{
                        .name = a.identOf(field.name),
                        .ty = field_ty,
                    };
                }
                try self.typed.struct_expr_fields.put(idx, resolved);
                break :blk .{ .value = .{ .struct_type = idx }, .returned = false };
            },
            .type_variant => unreachable,
        };
    }

    fn inferComptimeExpr(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const body = self.parsed.ast.comptimeExprBody(idx);
        const prev = self.in_comptime_context;
        self.in_comptime_context = true;
        const ty = self.inferNode(body) catch |err| {
            self.in_comptime_context = prev;
            return err;
        };
        self.in_comptime_context = prev;

        var locals = scope_mod.ScopeStack(EvalBinding).init();
        defer locals.deinit(self.gpa);
        const value = (try self.evalNodeStep(body, &locals)).value;
        try self.typed.comptime_node_values.put(idx, value);
        return self.remember(idx, ty);
    }

    fn inferVarRef(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const name = self.parsed.ast.identOf(self.parsed.ast.nodes[idx].data0);
        if (self.lookupBinding(name)) |binding| {
            if (self.in_comptime_context and !binding.comptime_visible) {
                return self.failAtNode(idx, error.ComptimeCaptureNotAllowed);
            }
            return self.remember(idx, binding.ty);
        }

        const resolved_ref = self.resolved.node_refs.get(idx) orelse return self.failAtNode(idx, error.UnknownSymbol);
        return switch (resolved_ref) {
            .local => self.failAtNode(idx, if (self.in_comptime_context) error.ComptimeCaptureNotAllowed else error.UnknownSymbol),
            .function => |fn_id| blk: {
                const fn_ty: Type = .{ .func = self.typed.functionType(fn_id) };
                break :blk try self.remember(idx, fn_ty);
            },
            .comptime_value => |decl_idx| blk: {
                const ty = try self.inferComptimeDeclType(decl_idx);
                if (!self.in_comptime_context) {
                    var locals = scope_mod.ScopeStack(EvalBinding).init();
                    defer locals.deinit(self.gpa);
                    _ = try self.evalComptimeDeclValue(decl_idx, &locals);
                }
                break :blk try self.remember(idx, ty);
            },
            .builtin_type => self.remember(idx, .type_type),
            .struct_decl => |decl_idx| self.remember(idx, .{ .named = self.parsed.ast.identOf(self.parsed.ast.nodes[decl_idx].data0) }),
        };
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
            .var_decl => self.inferDecl(idx, true),
            .assign => self.inferAssign(idx),
            .const_decl => self.inferDecl(idx, false),
            .return_stmt => self.inferReturn(idx),
            .call => self.inferCall(idx),
            .arg => if (self.in_comptime_context) self.failAtNode(idx, error.ComptimePureOperationNotAllowed) else self.remember(idx, .int),
            .print_stmt => blk: {
                if (self.in_comptime_context) return self.failAtNode(idx, error.ComptimePureOperationNotAllowed);
                const child = a.nodes[idx].data0;
                const child_ty = try self.inferNode(child);
                switch (child_ty) {
                    .int, .float, .bool => {},
                    .unit => return self.failAtNode(child, error.PrintUnitValue),
                    .named, .func, .type_type, .variant => return self.failAtNode(child, error.PrintUnsupportedType),
                }
                break :blk try self.remember(idx, .unit);
            },
            .add => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .sub => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .mul => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .div => self.inferArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .lt, .gt, .le, .ge => try self.inferComparison(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .eq, .ne => try self.inferEquality(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .is => try self.inferIs(idx, a.isLhs(idx), a.isRhsType(idx)),
            .@"and", .@"or" => try self.inferLogical(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .if_stmt => self.inferIf(idx),
            .struct_init => self.inferStructInit(idx),
            .field_access => self.inferFieldAccess(idx),
            .comptime_expr => self.inferComptimeExpr(idx),
            .comptime_value_decl => try self.remember(idx, .unit),
            .comptime_fn, .comptime_struct => try self.remember(idx, .unit),
            .struct_expr => self.remember(idx, .type_type),
            .type_union => self.inferTypeUnionExpr(idx),
            .type_name, .type_func, .type_variant => unreachable,
        };
    }

    fn hasComptimeParams(self: *const @This(), info: FunctionInfo) bool {
        if (info.decl == std.math.maxInt(ast.NodeIdx)) return false;
        const mask = self.parsed.ast.fnComptimeMask(info.decl);
        return mask != 0;
    }

    fn checkFunction(self: *@This(), fn_id: u32) InferError!void {
        const info = &self.typed.functions[fn_id];
        if (self.hasComptimeParams(info.*) and info.ty.ret == .type_type) return;

        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        self.current_return = info.ty.ret;
        self.current_saw_return = false;

        const is_top_level = info.decl == std.math.maxInt(ast.NodeIdx);
        if (!is_top_level) {
            const a = self.parsed.ast;
            for (a.fnParams(info.decl), info.ty.params) |param, param_ty| {
                const pname = a.identOf(param.name);
                try self.pushBinding(info.decl, pname, .{ .ty = param_ty, .mutable = false, .comptime_visible = false });
            }
        }

        const body = if (is_top_level) self.parsed.ast.entry else self.parsed.ast.fnBody(info.decl);
        const body_ty = try self.inferNode(body);
        if (!self.current_saw_return and !isAssignableTo(info.ty.ret, body_ty)) {
            if (is_top_level) {
                const mutable_sig = @constCast(info.ty);
                mutable_sig.ret = body_ty;
            } else {
                return self.failAtNodeWithTypes(body, error.FunctionBodyTypeMismatch, info.ty.ret, body_ty);
            }
        }
        info.has_explicit_return = self.current_saw_return;
    }

    fn run(self: *@This()) InferError!void {
        try self.setupFunctionSignatures();
        try self.validateTopLevelComptimeDecls();

        var idx: u32 = 0;
        while (idx < self.typed.functions.len) : (idx += 1) {
            try self.checkFunction(idx);
        }
    }
};

fn hasTopLevelEntry(a: ast.Ast, entry: ast.NodeIdx) bool {
    if (a.nodes[entry].tag == .block) {
        for (a.blockItems(entry)) |item| {
            switch (a.nodes[item].tag) {
                .comptime_fn, .comptime_struct, .comptime_value_decl => continue,
                else => return true,
            }
        }
        return false;
    }
    if (a.nodes[entry].tag == .unit_lit) return false;
    return true;
}

pub const AnalyzeMemo = db.Memo(AnalyzedAst);

pub fn computeAnalyze(
    resolve_memo: *const resolver.ResolveMemo,
    parse_memo: *const parser.ParseMemo,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!AnalyzeMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, resolve_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var typed_value: ?AnalyzedAst = null;
    if (resolve_memo.value) |*resolved| {
        const parsed = if (parse_memo.value) |*p| p else return db.makeMemo(AnalyzedAst, null, diagnostics_list);
        const report = try typecheckReport(parsed, resolved, gpa);
        if (report.diagnostic) |diag| {
            try diagnostics_list.append(gpa, diag);
        }
        typed_value = report.typed;
    }

    return db.makeMemo(AnalyzedAst, typed_value, diagnostics_list);
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
            const message = if (failure.expected_type) |expected| msg: {
                const base = typeErrorMessage(failure.kind);
                const expected_str = typeName(expected);
                const actual_str = typeName(failure.actual_type.?);
                if (failure.kind == error.IfBranchTypeMismatch) {
                    break :msg try std.fmt.allocPrint(gpa, "{s}: '{s}' vs '{s}'", .{ base, expected_str, actual_str });
                }
                if (failure.kind == error.EqualityUnsupportedType) {
                    break :msg try std.fmt.allocPrint(gpa, "{s}: '{s}'", .{ base, expected_str });
                }
                break :msg try std.fmt.allocPrint(gpa, "{s}: expected '{s}', got '{s}'", .{ base, expected_str, actual_str });
            } else typeErrorMessage(failure.kind);
            return .{
                .typed = null,
                .diagnostic = .{
                    .stage = .typecheck,
                    .span = failure.span,
                    .message = message,
                    .message_allocated = failure.expected_type != null,
                },
            };
        },
    };

    checker.bindings.deinit(gpa);
    checker.comptime_decl_state.deinit();
    return .{
        .typed = checker.typed,
        .diagnostic = null,
    };
}
