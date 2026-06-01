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
    none,
    named: []const u8,
    func: *const FuncType,
    variant: *const VariantType,
};

pub fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unit, .bool, .int, .float, .type_type, .none => true,
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
    ty: *FuncType,
    param_modes: []const ast.ParamAccessMode,
    has_explicit_return: bool,
    is_monomorphized: bool = false,
    body_checked_during_mono: bool = false,
};

pub const MovePolicy = struct {
    kind: ast.StructMoveKind,
    hook_fn: ?u32 = null,
};

pub const CopyPolicy = struct {
    kind: ast.StructCopyKind,
    hook_fn: ?u32 = null,
};

pub const DropPolicy = struct {
    kind: ast.StructDropKind,
    hook_fn: ?u32 = null,
};

pub const OwnershipSpec = struct {
    move: MovePolicy,
    copy: CopyPolicy,
    drop: DropPolicy,
};

pub const StructValue = struct {
    decl: ast.NodeIdx,
    fields: []const ComptimeValue,
};

pub const ComptimeValue = union(enum) {
    unit,
    none,
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
    StructInitTypeNotStruct,
    ComptimeCycle,
    ComptimeCaptureNotAllowed,
    ComptimePureOperationNotAllowed,
    ComptimeValueNotAvailable,
    RuntimeTypeValue,
    ComptimeValueNotAType,
    DuplicateVariantMember,
    IsOperandNotVariant,
    IsTypeNotInVariant,
    AsOperandNotVariant,
    AsTypeNotInVariant,
    OwnershipCopyNotAllowed,
    OwnershipMoveNotAllowed,
    MoveBorrowedValue,
    UseAfterMove,
    UseAfterDeinit,
    StableIdentityTransfer,
    DeinitNotSatisfied,
    HookSignatureMismatch,
    StructPolicyIncompatible,
    RecursiveStruct,
    InvalidBorrowArgument,
    InvalidDeinitTransfer,
    MutateConst,
    QueryOperandNotVariant,
    QueryVariantNoNone,
};

pub const ResolvedField = struct {
    name: []const u8,
    ty: Type,
};

pub const AnalyzedAst = struct {
    arena: std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    ast: *const ast.Ast,
    node_types: std.AutoHashMap(ast.NodeIdx, Type),
    field_index: std.AutoHashMap(ast.NodeIdx, u32),
    is_variant_tags: std.AutoHashMap(ast.NodeIdx, []const u32),
    query_none_tags: std.AutoHashMap(ast.NodeIdx, u32),
    decl_binding_types: std.AutoHashMap(ast.NodeIdx, Type),
    comptime_node_values: std.AutoHashMap(ast.NodeIdx, ComptimeValue),
    comptime_values: std.StringHashMap(ComptimeValue),
    comptime_struct_fields: std.StringHashMap([]const ResolvedField),
    struct_expr_fields: std.AutoHashMap(ast.NodeIdx, []const ResolvedField),
    ownership_specs: std.StringHashMap(OwnershipSpec),
    functions: std.ArrayList(FunctionInfo),
    entry_function: u32,
    call_monomorph_targets: std.AutoHashMap(ast.NodeIdx, u32),

    pub fn init(gpa: std.mem.Allocator, parsed_ast: *const ast.Ast) AnalyzedAst {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
            .ast = parsed_ast,
            .node_types = std.AutoHashMap(ast.NodeIdx, Type).init(gpa),
            .field_index = std.AutoHashMap(ast.NodeIdx, u32).init(gpa),
            .is_variant_tags = std.AutoHashMap(ast.NodeIdx, []const u32).init(gpa),
            .query_none_tags = std.AutoHashMap(ast.NodeIdx, u32).init(gpa),
            .decl_binding_types = std.AutoHashMap(ast.NodeIdx, Type).init(gpa),
            .comptime_node_values = std.AutoHashMap(ast.NodeIdx, ComptimeValue).init(gpa),
            .comptime_values = std.StringHashMap(ComptimeValue).init(gpa),
            .comptime_struct_fields = std.StringHashMap([]const ResolvedField).init(gpa),
            .struct_expr_fields = std.AutoHashMap(ast.NodeIdx, []const ResolvedField).init(gpa),
            .ownership_specs = std.StringHashMap(OwnershipSpec).init(gpa),
            .functions = std.ArrayList(FunctionInfo).empty,
            .entry_function = 0,
            .call_monomorph_targets = std.AutoHashMap(ast.NodeIdx, u32).init(gpa),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.node_types.deinit();
        self.field_index.deinit();
        self.is_variant_tags.deinit();
        self.query_none_tags.deinit();
        self.decl_binding_types.deinit();
        self.comptime_node_values.deinit();
        self.comptime_values.deinit();
        self.comptime_struct_fields.deinit();
        self.struct_expr_fields.deinit();
        self.ownership_specs.deinit();
        self.functions.deinit(self.gpa);
        self.call_monomorph_targets.deinit();
        self.arena.deinit();
    }

    pub fn typeOf(self: *const @This(), idx: ast.NodeIdx) TypeError!Type {
        return self.node_types.get(idx) orelse error.MissingNodeType;
    }

    pub fn functionType(self: *const @This(), fn_id: u32) *const FuncType {
        return self.functions.items[fn_id].ty;
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
        .none => "none",
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
        error.StructInitTypeNotStruct => "struct init type is not a struct type",
        error.ComptimeCycle => "comptime dependency cycle",
        error.ComptimeCaptureNotAllowed => "comptime can only reference comptime symbols and comptime locals",
        error.ComptimePureOperationNotAllowed => "operation is not allowed in pure comptime execution",
        error.ComptimeValueNotAvailable => "comptime value is not available",
        error.RuntimeTypeValue => "type value cannot be used at runtime, use 'comptime' instead of 'const' or 'var'",
        error.ComptimeValueNotAType => "comptime value is not a type",
        error.DuplicateVariantMember => "duplicate variant member type",
        error.IsOperandNotVariant => "left side of 'is' must be a variant type",
        error.IsTypeNotInVariant => "right side of 'is' is not a member of the variant type",
        error.AsOperandNotVariant => "left side of 'as' must be a variant type",
        error.AsTypeNotInVariant => "right side of 'as' is not a member of the variant type",
        error.OwnershipCopyNotAllowed => "copy is not allowed for this type",
        error.OwnershipMoveNotAllowed => "move is not allowed for this type",
        error.MoveBorrowedValue => "cannot move a borrowed value; the value is not owned",
        error.UseAfterMove => "use after move",
        error.UseAfterDeinit => "use after deinit",
        error.StableIdentityTransfer => "stable-identity value cannot be transferred",
        error.DeinitNotSatisfied => "deinit ownership must be consumed before function return",
        error.HookSignatureMismatch => "ownership hook function signature mismatch",
        error.StructPolicyIncompatible => "struct ownership policy is incompatible with field policies",
        error.RecursiveStruct => "recursive struct types are not supported",
        error.InvalidBorrowArgument => "borrow argument must be a variable reference",
        error.InvalidDeinitTransfer => "deinit-owned value cannot be transferred except to deinit parameter",
        error.MutateConst => "cannot mutate a const variable; 'mut' parameter requires a mutable variable",
        error.QueryOperandNotVariant => "left side of '?' must be a variant type",
        error.QueryVariantNoNone => "variant does not contain 'none' member",
    };
}

fn builtinType(name: []const u8) Type {
    if (std.mem.eql(u8, name, "unit")) return .unit;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "int")) return .int;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "type")) return .type_type;
    if (std.mem.eql(u8, name, "none")) return .none;
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
        monomorph_cache: std.StringHashMap(u32),
        ownership_in_progress: std.StringHashMap(void),
        failure: ?Failure,
        in_fallible_scope: bool,
        in_comptime_context: bool,
        current_return: Type,
        current_saw_return: bool,
        inferring_return: bool,
        seen_return_types: std.ArrayList(Type),
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
            .monomorph_cache = std.StringHashMap(u32).init(gpa),
            .ownership_in_progress = std.StringHashMap(void).init(gpa),
            .failure = null,
            .in_fallible_scope = false,
            .in_comptime_context = false,
            .current_return = .unit,
            .current_saw_return = false,
            .inferring_return = false,
            .seen_return_types = std.ArrayList(Type).initCapacity(gpa, 0) catch unreachable,
            .anon_counter = 0,
        };
    }

    fn deinit(self: *@This()) void {
        self.typed.deinit();
        self.bindings.deinit(self.gpa);
        self.comptime_decl_state.deinit();
        self.monomorph_cache.deinit();
        self.seen_return_types.deinit(self.gpa);
        self.ownership_in_progress.deinit();
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

    fn allocFuncType(self: *@This(), params: []const Type, ret: Type) std.mem.Allocator.Error!*FuncType {
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

    fn collectUniqueType(self: *@This(), list: *std.ArrayList(Type), ty: Type) InferError!void {
        switch (ty) {
            .variant => |vt| { for (vt.members) |m| try self.collectUniqueType(list, m); },
            else => {
                for (list.items) |existing| { if (typeEql(existing, ty)) return; }
                try list.append(self.gpa, ty);
            },
        }
    }

    fn computeInferredReturnType(self: *@This(), return_types: []const Type) InferError!Type {
        if (return_types.len == 0) return .unit;
        var unique = try std.ArrayList(Type).initCapacity(self.gpa, 0);
        defer unique.deinit(self.gpa);
        for (return_types) |rt| try self.collectUniqueType(&unique, rt);
        if (unique.items.len == 1) return unique.items[0];
        return .{ .variant = try self.allocVariantType(unique.items) };
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
                if (std.mem.eql(u8, name, "none")) return .none;
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
            if (self.typed.comptime_values.get(name)) |cv| {
                switch (cv) {
                    .type_value => |ty| return ty,
                    .struct_type => |decl_idx| {
                        const struct_name = self.parsed.ast.identOf(self.parsed.ast.nodes[decl_idx].data0);
                        return .{ .named = struct_name };
                    },
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

    fn computeByteSize(self: *@This(), ty: Type) InferError!u32 {
        return switch (ty) {
            .unit, .none, .type_type => 0,
            .bool => 1,
            .int, .float => 4,
            .func => 8,
            .named => |name| self.namedTypeByteSize(name),
            .variant => |variant_ty| blk: {
                var max_member_size: u32 = 0;
                for (variant_ty.members) |member_ty| {
                    const member_size = try self.computeByteSize(member_ty);
                    if (member_size > max_member_size) max_member_size = member_size;
                }
                break :blk max_member_size + 1;
            },
        };
    }

    fn namedTypeByteSize(self: *@This(), name: []const u8) InferError!u32 {
        const a = self.parsed.ast;
        for (a.decls) |decl_idx| {
            if (a.nodes[decl_idx].tag != .comptime_struct) continue;
            const decl_name = a.identOf(a.nodes[decl_idx].data0);
            if (std.mem.eql(u8, decl_name, name)) {
                var total: u32 = 0;
                for (a.structFields(decl_idx)) |field| {
                    const field_ty = try self.resolveTypeNode(field.ty);
                    total += try self.computeByteSize(field_ty);
                }
                return total;
            }
        }
        if (self.typed.comptime_struct_fields.get(name)) |fields| {
            var total: u32 = 0;
            for (fields) |field| {
                total += try self.computeByteSize(field.ty);
            }
            return total;
        }
        return 4;
    }

    fn paramTypeReferencesComptimeParam(self: *const @This(), func_decl_idx: ast.NodeIdx, param_ty_idx: ast.TypeIdx) bool {
        const a = self.parsed.ast;
        if (a.nodes[param_ty_idx].tag != .type_name) return false;
        const tname = a.identOf(a.nodes[param_ty_idx].data0);
        const mask = a.fnComptimeMask(func_decl_idx);
        for (a.fnParams(func_decl_idx), 0..) |other_param, other_idx| {
            if (other_idx >= 32) break;
            if (mask & (@as(u32, 1) << @intCast(other_idx)) != 0) {
                const other_name = a.identOf(other_param.name);
                if (std.mem.eql(u8, tname, other_name)) return true;
            }
        }
        return false;
    }

    fn retTypeReferencesComptimeParam(self: *const @This(), func_decl_idx: ast.NodeIdx) bool {
        const a = self.parsed.ast;
        const ret_ty = a.fnRetType(func_decl_idx);
        if (ret_ty == ast.FN_NO_RET_TYPE) return false;
        if (a.nodes[ret_ty].tag != .type_name) return false;
        const tname = a.identOf(a.nodes[ret_ty].data0);
        const mask = a.fnComptimeMask(func_decl_idx);
        for (a.fnParams(func_decl_idx), 0..) |other_param, other_idx| {
            if (other_idx >= 32) break;
            if (mask & (@as(u32, 1) << @intCast(other_idx)) != 0) {
                const other_name = a.identOf(other_param.name);
                if (std.mem.eql(u8, tname, other_name)) return true;
            }
        }
        return false;
    }

    fn setupFunctionSignatures(self: *@This()) InferError!void {
        const a = self.parsed.ast;
        const fn_count = self.resolved.functions.items.len;
        const has_top_level_entry = hasTopLevelEntry(self.parsed.ast, self.parsed.ast.entry);
        const main_fn_id = self.resolved.function_names.get("main");
        const reserve_extra: usize = if (has_top_level_entry or (fn_count == 0 and main_fn_id == null)) 1 else 0;

        try self.typed.functions.ensureTotalCapacity(self.gpa, fn_count + reserve_extra);

        for (self.resolved.functions.items, 0..) |func_decl_idx, idx| {
            _ = idx;
            var param_types = try std.ArrayList(Type).initCapacity(self.gpa, a.fnParams(func_decl_idx).len);
            defer param_types.deinit(self.gpa);
            for (a.fnParams(func_decl_idx)) |param| {
                if (self.paramTypeReferencesComptimeParam(func_decl_idx, param.ty)) {
                    try param_types.append(self.gpa, .type_type);
                } else {
                    try param_types.append(self.gpa, try self.resolveTypeNode(param.ty));
                }
            }
            const ret_ty = if (self.retTypeReferencesComptimeParam(func_decl_idx))
                .type_type
            else
                try self.resolveFnRetType(func_decl_idx);
            const fn_ty = try self.allocFuncType(param_types.items, ret_ty);
            const param_modes = try self.runtimeParamModes(func_decl_idx);
            if (a.comptimeFnAnnotation(func_decl_idx)) |annot| {
                const annot_ty = try self.resolveTypeNode(annot);
                if (!typeEql(.{ .func = fn_ty }, annot_ty)) return self.failAtNodeWithTypes(func_decl_idx, error.BindingTypeMismatch, annot_ty, .{ .func = fn_ty });
            }
            try self.typed.functions.append(self.gpa, .{
                .decl = func_decl_idx,
                .ty = fn_ty,
                .param_modes = param_modes,
                .has_explicit_return = false,
            });
        }

        if (reserve_extra == 1) {
            const top_fn_id = @as(u32, @intCast(self.typed.functions.items.len));
            const top_fn_ty = try self.allocFuncType(&.{}, .unit);
            try self.typed.functions.append(self.gpa, .{
                .decl = std.math.maxInt(ast.NodeIdx),
                .ty = top_fn_ty,
                .param_modes = &.{},
                .has_explicit_return = false,
            });
            self.typed.entry_function = top_fn_id;
        } else if (main_fn_id) |main_id| {
            self.typed.entry_function = main_id;
        } else {
            self.typed.entry_function = 0;
        }
    }

    fn paramModeIsMutable(mode: ast.ParamAccessMode) bool {
        return switch (mode) {
            .read => false,
            .mut, .var_mode, .deinit => true,
        };
    }

    fn paramModeIsOwned(mode: ast.ParamAccessMode) bool {
        return switch (mode) {
            .read, .mut => false,
            .var_mode, .deinit => true,
        };
    }

    fn resolveFnRetType(self: *@This(), func_decl_idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const ret_ty_node = a.fnRetType(func_decl_idx);
        if (ret_ty_node == ast.FN_NO_RET_TYPE) return .unit;
        return self.resolveTypeNode(ret_ty_node);
    }

    fn runtimeParamModes(self: *@This(), func_decl_idx: ast.NodeIdx) InferError![]const ast.ParamAccessMode {
        const a = self.parsed.ast;
        var modes = try std.ArrayList(ast.ParamAccessMode).initCapacity(self.gpa, a.fnParams(func_decl_idx).len);
        defer modes.deinit(self.gpa);
        for (a.fnParams(func_decl_idx), 0..) |_, param_idx| {
            if (a.fnParamIsComptime(func_decl_idx, @intCast(param_idx))) continue;
            try modes.append(self.gpa, a.fnParamAccessMode(func_decl_idx, @intCast(param_idx)));
        }
        return self.typed.arena.allocator().dupe(ast.ParamAccessMode, modes.items) catch return error.OutOfMemory;
    }

    const TypeCaps = struct {
        move_supported: bool = true,
        move_trivial: bool = true,
        copy_supported: bool = true,
        copy_trivial: bool = true,
        drop_fieldwise_supported: bool = true,
        drop_trivial: bool = true,
        has_explicit_drop: bool = false,
    };

    fn hookSignatureExpectedMode(kind: ast.StructMoveKind) ast.ParamAccessMode {
        return switch (kind) {
            .func => .var_mode,
            else => .read,
        };
    }

    fn findStructDecl(self: *const @This(), name: []const u8) ?ast.NodeIdx {
        for (self.parsed.ast.decls) |decl_idx| {
            if (self.parsed.ast.nodes[decl_idx].tag != .comptime_struct) continue;
            const decl_name = self.parsed.ast.identOf(self.parsed.ast.nodes[decl_idx].data0);
            if (std.mem.eql(u8, decl_name, name)) return decl_idx;
        }
        return null;
    }

    fn typeCaps(self: *@This(), ty: Type) InferError!TypeCaps {
        switch (ty) {
            .unit, .bool, .int, .float, .type_type, .none, .func => return .{},
            .variant => |variant_ty| {
                var caps = TypeCaps{};
                for (variant_ty.members) |member_ty| {
                    const mc = try self.typeCaps(member_ty);
                    caps.move_supported = caps.move_supported and mc.move_supported;
                    caps.move_trivial = caps.move_trivial and mc.move_trivial;
                    caps.copy_supported = caps.copy_supported and mc.copy_supported;
                    caps.copy_trivial = caps.copy_trivial and mc.copy_trivial;
                    caps.drop_fieldwise_supported = caps.drop_fieldwise_supported and mc.drop_fieldwise_supported;
                    caps.drop_trivial = caps.drop_trivial and mc.drop_trivial;
                    caps.has_explicit_drop = caps.has_explicit_drop or mc.has_explicit_drop;
                }
                return caps;
            },
            .named => |name| {
                const spec = try self.computeOwnershipForNamed(name);
                return .{
                    .move_supported = spec.move.kind != .none,
                    .move_trivial = spec.move.kind == .trivial,
                    .copy_supported = spec.copy.kind != .none,
                    .copy_trivial = spec.copy.kind == .trivial,
                    .drop_fieldwise_supported = spec.drop.kind != .explicit,
                    .drop_trivial = spec.drop.kind == .trivial,
                    .has_explicit_drop = spec.drop.kind == .explicit,
                };
            },
        }
    }

    fn validateHookSignature(
        self: *@This(),
        fn_id: u32,
        owner_name: []const u8,
        expected_mode: ast.ParamAccessMode,
        expected_ret: Type,
        decl_idx: ast.NodeIdx,
    ) InferError!void {
        if (fn_id >= self.typed.functions.items.len) return self.failAtNode(decl_idx, error.HookSignatureMismatch);
        const info = self.typed.functions.items[fn_id];
        if (info.param_modes.len != 1 or info.ty.params.len != 1) return self.failAtNode(decl_idx, error.HookSignatureMismatch);
        if (info.param_modes[0] != expected_mode) return self.failAtNode(decl_idx, error.HookSignatureMismatch);
        const expected_self: Type = .{ .named = owner_name };
        if (!typeEql(info.ty.params[0], expected_self)) return self.failAtNode(decl_idx, error.HookSignatureMismatch);
        if (!typeEql(info.ty.ret, expected_ret)) return self.failAtNode(decl_idx, error.HookSignatureMismatch);
    }

    fn resolveHookFnId(self: *@This(), hook_ident: ?ast.IdentIdx, decl_idx: ast.NodeIdx) InferError!?u32 {
        const hid = hook_ident orelse return null;
        const hook_name = self.parsed.ast.identOf(hid);
        return self.resolved.function_names.get(hook_name) orelse return self.failAtNode(decl_idx, error.HookSignatureMismatch);
    }

    fn computeOwnershipDefaultFromFields(self: *@This(), field_types: []const Type, decl_idx: ast.NodeIdx) InferError!OwnershipSpec {
        var all_move_supported = true;
        var all_drop_fieldwise = true;
        var all_drop_trivial = true;
        var any_explicit_drop = false;
        for (field_types) |field_ty| {
            const caps = try self.typeCaps(field_ty);
            all_move_supported = all_move_supported and caps.move_supported;
            all_drop_fieldwise = all_drop_fieldwise and caps.drop_fieldwise_supported;
            all_drop_trivial = all_drop_trivial and caps.drop_trivial;
            any_explicit_drop = any_explicit_drop or caps.has_explicit_drop;
        }
        if (!all_move_supported or !all_drop_fieldwise) return self.failAtNode(decl_idx, error.StructPolicyIncompatible);

        const drop_kind: ast.StructDropKind = if (any_explicit_drop) .explicit else if (all_drop_trivial) .trivial else .fieldwise;
        return .{
            .move = .{ .kind = .fieldwise, .hook_fn = null },
            .copy = .{ .kind = .none, .hook_fn = null },
            .drop = .{ .kind = drop_kind, .hook_fn = null },
        };
    }

    fn computeOwnershipForDecl(self: *@This(), decl_idx: ast.NodeIdx, name: []const u8) InferError!OwnershipSpec {
        const a = self.parsed.ast;

        var all_move_supported = true;
        var all_copy_supported = true;
        var all_drop_fieldwise = true;
        var all_move_trivial = true;
        var all_copy_trivial = true;
        var all_drop_trivial = true;
        var any_explicit_drop = false;
        for (a.structFields(decl_idx)) |field| {
            const field_ty = try self.resolveTypeNode(field.ty);
            const caps = try self.typeCaps(field_ty);
            all_move_supported = all_move_supported and caps.move_supported;
            all_copy_supported = all_copy_supported and caps.copy_supported;
            all_drop_fieldwise = all_drop_fieldwise and caps.drop_fieldwise_supported;
            all_move_trivial = all_move_trivial and caps.move_trivial;
            all_copy_trivial = all_copy_trivial and caps.copy_trivial;
            all_drop_trivial = all_drop_trivial and caps.drop_trivial;
            any_explicit_drop = any_explicit_drop or caps.has_explicit_drop;
        }

        var move_policy = MovePolicy{
            .kind = a.structMoveKind(decl_idx),
            .hook_fn = null,
        };
        switch (move_policy.kind) {
            .trivial => if (!all_move_trivial) return self.failAtNode(decl_idx, error.StructPolicyIncompatible),
            .fieldwise => if (!all_move_supported) return self.failAtNode(decl_idx, error.StructPolicyIncompatible),
            .none => {},
            .func => {
                const hook_fn = (try self.resolveHookFnId(a.structMoveHook(decl_idx), decl_idx)) orelse return self.failAtNode(decl_idx, error.HookSignatureMismatch);
                try self.validateHookSignature(hook_fn, name, .var_mode, .{ .named = name }, decl_idx);
                move_policy.hook_fn = hook_fn;
            },
        }

        var copy_policy = CopyPolicy{
            .kind = a.structCopyKind(decl_idx),
            .hook_fn = null,
        };
        switch (copy_policy.kind) {
            .none => {},
            .trivial => if (!all_copy_trivial) return self.failAtNode(decl_idx, error.StructPolicyIncompatible),
            .fieldwise => if (!all_copy_supported) return self.failAtNode(decl_idx, error.StructPolicyIncompatible),
            .func => {
                const hook_fn = (try self.resolveHookFnId(a.structCopyHook(decl_idx), decl_idx)) orelse return self.failAtNode(decl_idx, error.HookSignatureMismatch);
                try self.validateHookSignature(hook_fn, name, .read, .{ .named = name }, decl_idx);
                copy_policy.hook_fn = hook_fn;
            },
        }

        var effective_drop_kind = a.structDropKind(decl_idx);
        if (!a.structDropExplicit(decl_idx)) {
            effective_drop_kind = if (any_explicit_drop) .explicit else if (all_drop_trivial) .trivial else .fieldwise;
        }

        var drop_policy = DropPolicy{
            .kind = effective_drop_kind,
            .hook_fn = null,
        };
        switch (drop_policy.kind) {
            .trivial => if (!all_drop_trivial) return self.failAtNode(decl_idx, error.StructPolicyIncompatible),
            .fieldwise => if (!all_drop_fieldwise) return self.failAtNode(decl_idx, error.StructPolicyIncompatible),
            .explicit => {},
            .func => {
                const hook_fn = (try self.resolveHookFnId(a.structDropHook(decl_idx), decl_idx)) orelse return self.failAtNode(decl_idx, error.HookSignatureMismatch);
                try self.validateHookSignature(hook_fn, name, .deinit, .unit, decl_idx);
                drop_policy.hook_fn = hook_fn;
            },
        }

        if (move_policy.kind == .none and copy_policy.kind != .none) return self.failAtNode(decl_idx, error.StructPolicyIncompatible);

        return .{
            .move = move_policy,
            .copy = copy_policy,
            .drop = drop_policy,
        };
    }

    fn computeOwnershipForNamed(self: *@This(), name: []const u8) InferError!OwnershipSpec {
        if (self.typed.ownership_specs.get(name)) |spec| return spec;
        if (self.ownership_in_progress.contains(name)) {
            const decl = self.findStructDecl(name) orelse self.parsed.ast.entry;
            return self.failAtNode(decl, error.RecursiveStruct);
        }
        try self.ownership_in_progress.put(name, {});
        defer _ = self.ownership_in_progress.remove(name);

        const spec = if (self.findStructDecl(name)) |decl_idx| blk: {
            break :blk try self.computeOwnershipForDecl(decl_idx, name);
        } else if (self.typed.comptime_struct_fields.get(name)) |fields| blk: {
            var field_types = try std.ArrayList(Type).initCapacity(self.gpa, fields.len);
            defer field_types.deinit(self.gpa);
            for (fields) |field| try field_types.append(self.gpa, field.ty);
            break :blk try self.computeOwnershipDefaultFromFields(field_types.items, self.parsed.ast.entry);
        } else {
            return self.failAtNode(self.parsed.ast.entry, error.UnknownType);
        };

        try self.typed.ownership_specs.put(name, spec);
        return spec;
    }

    fn computeOwnershipSpecs(self: *@This()) InferError!void {
        for (self.parsed.ast.decls) |decl_idx| {
            if (self.parsed.ast.nodes[decl_idx].tag != .comptime_struct) continue;
            const name = self.parsed.ast.identOf(self.parsed.ast.nodes[decl_idx].data0);
            _ = try self.computeOwnershipForNamed(name);
        }
    }

    const OwnershipState = enum {
        alive,
        moved,
        deinited,
    };

    const OwnershipBinding = struct {
        ty: Type,
        mutable: bool,
        owned: bool,
        param_mode: ast.ParamAccessMode,
        state: OwnershipState,
    };

    const OwnershipUse = enum {
        read,
        copy,
        move,
        borrow_read,
        borrow_mut,
        deinit_transfer,
    };

    fn copyAllowed(self: *@This(), ty: Type) InferError!bool {
        return switch (ty) {
            .unit, .bool, .int, .float, .type_type, .none, .func => true,
            .named => |name| (try self.computeOwnershipForNamed(name)).copy.kind != .none,
            .variant => |variant_ty| blk: {
                for (variant_ty.members) |member_ty| {
                    if (!try self.copyAllowed(member_ty)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn moveAllowed(self: *@This(), ty: Type) InferError!bool {
        return switch (ty) {
            .unit, .bool, .int, .float, .type_type, .none, .func => true,
            .named => |name| (try self.computeOwnershipForNamed(name)).move.kind != .none,
            .variant => |variant_ty| blk: {
                for (variant_ty.members) |member_ty| {
                    if (!try self.moveAllowed(member_ty)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn dropExplicit(self: *@This(), ty: Type) InferError!bool {
        return switch (ty) {
            .unit, .bool, .int, .float, .type_type, .none, .func => false,
            .named => |name| (try self.computeOwnershipForNamed(name)).drop.kind == .explicit,
            .variant => |variant_ty| blk: {
                for (variant_ty.members) |member_ty| {
                    if (try self.dropExplicit(member_ty)) break :blk true;
                }
                break :blk false;
            },
        };
    }

    fn stableIdentity(self: *@This(), ty: Type) InferError!bool {
        return switch (ty) {
            .named => |name| (try self.computeOwnershipForNamed(name)).move.kind == .none,
            else => false,
        };
    }

    fn checkScopeExitExplicitDrops(self: *@This(), stack: *scope_mod.ScopeStack(OwnershipBinding), mark: usize, span_node: ast.NodeIdx) InferError!void {
        var idx = mark;
        while (idx < stack.entries.items.len) : (idx += 1) {
            const binding = stack.entries.items[idx].value;
            if (!binding.owned) continue;
            if (binding.state != .alive) continue;
            if (binding.param_mode == .deinit) continue;
            if (try self.dropExplicit(binding.ty)) return self.failAtNode(span_node, error.DeinitNotSatisfied);
        }
    }

    fn applyOwnershipUseOnBinding(self: *@This(), node_idx: ast.NodeIdx, binding: *OwnershipBinding, use: OwnershipUse) InferError!void {
        if (binding.state == .moved) return self.failAtNode(node_idx, error.UseAfterMove);
        if (binding.state == .deinited) return self.failAtNode(node_idx, error.UseAfterDeinit);

        switch (use) {
            .read => {
                // Non-consuming read/borrow.
            },
            .copy => {
                if (binding.param_mode == .deinit) return self.failAtNode(node_idx, error.InvalidDeinitTransfer);
                if (!try self.copyAllowed(binding.ty)) return self.failAtNode(node_idx, error.OwnershipCopyNotAllowed);
            },
            .move => {
                if (!binding.owned) return self.failAtNode(node_idx, error.MoveBorrowedValue);
                if (binding.param_mode == .deinit) return self.failAtNode(node_idx, error.InvalidDeinitTransfer);
                if (!try self.moveAllowed(binding.ty)) {
                    if (try self.stableIdentity(binding.ty)) return self.failAtNode(node_idx, error.StableIdentityTransfer);
                    return self.failAtNode(node_idx, error.OwnershipMoveNotAllowed);
                }
                binding.state = .moved;
            },
            .borrow_read => {},
            .borrow_mut => {
                if (!binding.mutable) return self.failAtNode(node_idx, error.MutateConst);
            },
            .deinit_transfer => {
                if (!binding.owned) return self.failAtNode(node_idx, error.InvalidDeinitTransfer);
                binding.state = .deinited;
            },
        }
    }

    fn callParamModes(self: *@This(), call_idx: ast.NodeIdx, callee: ast.NodeIdx) []const ast.ParamAccessMode {
        if (self.typed.call_monomorph_targets.get(call_idx)) |fn_id| {
            if (fn_id < self.typed.functions.items.len) return self.typed.functions.items[fn_id].param_modes;
        }
        if (self.resolved.node_refs.get(callee)) |ref| {
            if (ref == .function) {
                const fn_id = ref.function;
                if (fn_id < self.typed.functions.items.len) return self.typed.functions.items[fn_id].param_modes;
            }
        }
        return &.{};
    }

    fn ownershipUseExpr(self: *@This(), idx: ast.NodeIdx, stack: *scope_mod.ScopeStack(OwnershipBinding), use: OwnershipUse, current_ret: Type) InferError!void {
        const a = self.parsed.ast;
        switch (a.nodes[idx].tag) {
            .int_lit, .float_lit, .bool_lit, .unit_lit, .none_lit, .arg, .type_name, .type_func, .type_variant, .type_union, .struct_expr, .comptime_expr, .comptime_fn, .comptime_struct, .comptime_value_decl, .sizeof_expr => {},
            .var_ref => {
                const name = a.identOf(a.nodes[idx].data0);
                if (stack.lookupPtr(name)) |binding| {
                    try self.applyOwnershipUseOnBinding(idx, binding, use);
                }
            },
            .move_expr => {
                try self.ownershipUseExpr(a.nodes[idx].data0, stack, .move, current_ret);
            },
            .field_access => {
                const borrow_use: OwnershipUse = switch (use) {
                    .borrow_mut => .borrow_mut,
                    else => .borrow_read,
                };
                try self.ownershipUseExpr(a.nodes[idx].data0, stack, borrow_use, current_ret);
            },
            .struct_init => {
                for (a.structInitFields(idx)) |field| {
                    try self.ownershipUseExpr(field.value, stack, .copy, current_ret);
                }
            },
            .call => {
                const callee = a.nodes[idx].data0;
                try self.ownershipUseExpr(callee, stack, .read, current_ret);
                const param_modes = self.callParamModes(idx, callee);
                const args = a.callArgs(idx);
                for (args, 0..) |arg, arg_idx| {
                    const mode = if (arg_idx < param_modes.len) param_modes[arg_idx] else ast.ParamAccessMode.read;
                    switch (mode) {
                        .read => try self.ownershipUseExpr(arg, stack, .read, current_ret),
                        .mut => {
                            if (a.nodes[arg].tag != .var_ref) return self.failAtNode(arg, error.InvalidBorrowArgument);
                            try self.ownershipUseExpr(arg, stack, .borrow_mut, current_ret);
                        },
                        .var_mode => {
                            if (a.nodes[arg].tag == .move_expr) {
                                try self.ownershipUseExpr(arg, stack, .read, current_ret);
                            } else {
                                try self.ownershipUseExpr(arg, stack, .move, current_ret);
                            }
                        },
                        .deinit => {
                            const target_arg = if (a.nodes[arg].tag == .move_expr) a.nodes[arg].data0 else arg;
                            try self.ownershipUseExpr(target_arg, stack, .deinit_transfer, current_ret);
                        },
                    }
                }
            },
            .print_stmt => try self.ownershipUseExpr(a.nodes[idx].data0, stack, .read, current_ret),
            .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or" => {
                try self.ownershipUseExpr(a.nodes[idx].data0, stack, .read, current_ret);
                try self.ownershipUseExpr(a.nodes[idx].data1, stack, .read, current_ret);
            },
            .is => try self.ownershipUseExpr(a.isLhs(idx), stack, .read, current_ret),
            .as => try self.ownershipUseExpr(a.asLhs(idx), stack, .read, current_ret),
            .query_op => try self.ownershipUseExpr(a.queryOpLhs(idx), stack, .read, current_ret),
            .@"not" => try self.ownershipUseExpr(a.nodes[idx].data0, stack, .read, current_ret),
            .if_stmt => try self.ownershipVisitIf(idx, stack, current_ret),
            .const_decl => try self.ownershipVisitDecl(idx, stack, false, current_ret),
            .var_decl => try self.ownershipVisitDecl(idx, stack, true, current_ret),
            .assign => try self.ownershipVisitAssign(idx, stack, current_ret),
            .field_assign => {
                try self.ownershipUseExpr(a.nodes[idx].data1, stack, .copy, current_ret);
                try self.ownershipUseExpr(a.nodes[idx].data0, stack, .borrow_mut, current_ret);
            },
            .return_stmt => {
                try self.ownershipUseExpr(a.nodes[idx].data0, stack, .move, current_ret);
            },
            .block => try self.ownershipVisitBlock(idx, stack, current_ret),
        }
    }

    fn ownershipVisitDecl(self: *@This(), idx: ast.NodeIdx, stack: *scope_mod.ScopeStack(OwnershipBinding), mutable: bool, current_ret: Type) InferError!void {
        const a = self.parsed.ast;
        const value_node = a.varDeclValue(idx);
        try self.ownershipUseExpr(value_node, stack, .copy, current_ret);
        const binding_ty = self.typed.decl_binding_types.get(idx) orelse (self.typed.typeOf(value_node) catch return self.failAtNode(value_node, error.MissingNodeType));
        const name = a.identOf(a.nodes[idx].data0);
        stack.push(self.gpa, name, .{
            .ty = binding_ty,
            .mutable = mutable,
            .owned = true,
            .param_mode = .read,
            .state = .alive,
        }) catch |err| switch (err) {
            error.DuplicateVariable => return self.failAtNode(idx, error.DuplicateSymbol),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn ownershipVisitAssign(self: *@This(), idx: ast.NodeIdx, stack: *scope_mod.ScopeStack(OwnershipBinding), current_ret: Type) InferError!void {
        const a = self.parsed.ast;
        const name = a.identOf(a.nodes[idx].data0);
        if (stack.lookupPtr(name)) |binding| {
            if (binding.state == .alive and try self.dropExplicit(binding.ty)) return self.failAtNode(idx, error.DeinitNotSatisfied);
            try self.ownershipUseExpr(a.nodes[idx].data1, stack, .copy, current_ret);
            binding.state = .alive;
            return;
        }
        try self.ownershipUseExpr(a.nodes[idx].data1, stack, .copy, current_ret);
    }

    fn snapshotOwnershipStates(self: *@This(), stack: *scope_mod.ScopeStack(OwnershipBinding), count: usize) InferError![]OwnershipState {
        const states = try self.gpa.alloc(OwnershipState, count);
        for (0..count) |i| states[i] = stack.entries.items[i].value.state;
        return states;
    }

    fn mergeOwnershipStates(then_state: OwnershipState, else_state: OwnershipState) OwnershipState {
        if (then_state == else_state) return then_state;
        if (then_state == .deinited or else_state == .deinited) return .deinited;
        return .moved;
    }

    fn ownershipVisitIf(self: *@This(), idx: ast.NodeIdx, stack: *scope_mod.ScopeStack(OwnershipBinding), current_ret: Type) InferError!void {
        const a = self.parsed.ast;
        const data = a.ifData(idx);
        const baseline_count = stack.entries.items.len;

        var cond_binding_name: ?[]const u8 = null;
        var cond_binding_ty: ?Type = null;
        var cond_binding_mutable = false;
        const cond_tag = a.nodes[data.cond].tag;
        if (cond_tag == .const_decl or cond_tag == .var_decl) {
            const value_node = a.varDeclValue(data.cond);
            try self.ownershipUseExpr(value_node, stack, .copy, current_ret);
            cond_binding_name = a.identOf(a.nodes[data.cond].data0);
            cond_binding_ty = self.typed.decl_binding_types.get(data.cond) orelse (self.typed.typeOf(value_node) catch return self.failAtNode(value_node, error.MissingNodeType));
            cond_binding_mutable = cond_tag == .var_decl;
        } else {
            try self.ownershipUseExpr(data.cond, stack, .read, current_ret);
        }

        const baseline = try self.snapshotOwnershipStates(stack, baseline_count);
        defer self.gpa.free(baseline);

        {
            const mark = stack.mark();
            if (cond_binding_name) |name| {
                stack.push(self.gpa, name, .{
                    .ty = cond_binding_ty.?,
                    .mutable = cond_binding_mutable,
                    .owned = true,
                    .param_mode = .read,
                    .state = .alive,
                }) catch |err| switch (err) {
                    error.DuplicateVariable => return self.failAtNode(data.cond, error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            }
            try self.ownershipUseExpr(data.then_, stack, .read, current_ret);
            try self.checkScopeExitExplicitDrops(stack, mark, data.then_);
            stack.restore(mark);
        }

        const then_states = try self.snapshotOwnershipStates(stack, baseline_count);
        defer self.gpa.free(then_states);

        for (baseline, 0..) |state, i| stack.entries.items[i].value.state = state;
        if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
            const mark = stack.mark();
            try self.ownershipUseExpr(data.else_, stack, .read, current_ret);
            try self.checkScopeExitExplicitDrops(stack, mark, data.else_);
            stack.restore(mark);
        }
        const else_states = try self.snapshotOwnershipStates(stack, baseline_count);
        defer self.gpa.free(else_states);

        for (0..baseline_count) |i| {
            stack.entries.items[i].value.state = mergeOwnershipStates(then_states[i], else_states[i]);
        }
    }

    fn ownershipVisitBlock(self: *@This(), idx: ast.NodeIdx, stack: *scope_mod.ScopeStack(OwnershipBinding), current_ret: Type) InferError!void {
        const a = self.parsed.ast;
        const mark = stack.mark();
        for (a.blockItems(idx)) |item| {
            switch (a.nodes[item].tag) {
                .const_decl => try self.ownershipVisitDecl(item, stack, false, current_ret),
                .var_decl => try self.ownershipVisitDecl(item, stack, true, current_ret),
                .assign => try self.ownershipVisitAssign(item, stack, current_ret),
                .field_assign => try self.ownershipUseExpr(item, stack, .read, current_ret),
                .return_stmt => try self.ownershipUseExpr(item, stack, .read, current_ret),
                else => try self.ownershipUseExpr(item, stack, .read, current_ret),
            }
        }
        try self.checkScopeExitExplicitDrops(stack, mark, idx);
        stack.restore(mark);
    }

    fn ownershipCheckFunction(self: *@This(), fn_id: u32) InferError!void {
        if (fn_id >= self.typed.functions.items.len) return;
        const info = self.typed.functions.items[fn_id];
        if (self.hasComptimeParams(info) and !info.is_monomorphized) return;

        var stack = scope_mod.ScopeStack(OwnershipBinding).init();
        defer stack.deinit(self.gpa);

        const is_top_level = info.decl == std.math.maxInt(ast.NodeIdx);
        if (!is_top_level) {
            const a = self.parsed.ast;
            const mask = a.fnComptimeMask(info.decl);
            var runtime_idx: usize = 0;
            for (a.fnParams(info.decl), 0..) |param, param_idx| {
                if (mask & (@as(u32, 1) << @intCast(param_idx)) != 0) continue;
                if (runtime_idx >= info.ty.params.len or runtime_idx >= info.param_modes.len) break;
                const pname = a.identOf(param.name);
                const mode = info.param_modes[runtime_idx];
                const mutable = paramModeIsMutable(mode);
                const owned = paramModeIsOwned(mode);
                stack.push(self.gpa, pname, .{
                    .ty = info.ty.params[runtime_idx],
                    .mutable = mutable,
                    .owned = owned,
                    .param_mode = mode,
                    .state = .alive,
                }) catch |err| switch (err) {
                    error.DuplicateVariable => return self.failAtNode(info.decl, error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
                runtime_idx += 1;
            }
        }

        const body = if (is_top_level) self.parsed.ast.entry else self.parsed.ast.fnBody(info.decl);
        try self.ownershipUseExpr(body, &stack, .read, info.ty.ret);

        for (stack.entries.items) |entry| {
            if (!entry.value.owned) continue;
            if (entry.value.state != .alive) continue;
            if (entry.value.param_mode == .deinit) continue;
            if (try self.dropExplicit(entry.value.ty)) return self.failAtNode(body, error.DeinitNotSatisfied);
        }
    }

    fn runOwnershipChecks(self: *@This()) InferError!void {
        var fn_id: u32 = 0;
        while (fn_id < self.typed.functions.items.len) : (fn_id += 1) {
            try self.ownershipCheckFunction(fn_id);
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
            .lt, .gt, .le, .ge, .eq, .ne, .is, .as, .query_op, .@"and", .@"or", .@"not" => true,
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
        if (!isNumeric(pair[0])) return self.failAtNodeWithTypes(lhs, error.ArithmeticRequiresNumeric, pair[0], pair[0]);
        if (!isNumeric(pair[1])) return self.failAtNodeWithTypes(rhs, error.ArithmeticRequiresNumeric, pair[1], pair[1]);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.ArithmeticOperandMismatch);
        return self.remember(idx, pair[0]);
    }

    fn inferComparison(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const pair = try self.inferPair(lhs, rhs);
        if (!isNumeric(pair[0])) return self.failAtNodeWithTypes(lhs, error.ComparisonRequiresNumeric, pair[0], pair[0]);
        if (!isNumeric(pair[1])) return self.failAtNodeWithTypes(rhs, error.ComparisonRequiresNumeric, pair[1], pair[1]);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.ComparisonOperandMismatch);
        return self.remember(idx, .unit);
    }

    fn inferEquality(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs: ast.NodeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const pair = try self.inferPair(lhs, rhs);
        if (!typeEql(pair[0], pair[1])) return self.failAtNode(idx, error.EqualityOperandMismatch);
        switch (pair[0]) {
            .bool, .int, .float => {},
            .unit, .none, .named, .func, .type_type, .variant => return self.failAtNodeWithTypes(idx, error.EqualityUnsupportedType, pair[0], pair[0]),
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

    fn inferNot(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const inner = self.parsed.ast.nodes[idx].data0;
        _ = try self.inferNode(inner);
        if (!isFallibleNode(self.parsed.ast, inner)) return self.failAtNode(inner, error.LogicalOperandNotFallible);
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

    fn inferAs(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx, rhs_type_idx: ast.TypeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const lhs_ty = try self.inferNode(lhs);
        const lhs_variant = switch (lhs_ty) {
            .variant => |variant_ty| variant_ty,
            else => return self.failAtNode(lhs, error.AsOperandNotVariant),
        };

        const rhs_ty = try self.resolveTypeNode(rhs_type_idx);
        switch (rhs_ty) {
            .variant => return self.failAtType(rhs_type_idx, error.AsTypeNotInVariant),
            else => {
                _ = variantMemberIndex(lhs_variant, rhs_ty) orelse return self.failAtType(rhs_type_idx, error.AsTypeNotInVariant);
                return self.remember(idx, rhs_ty);
            },
        }
    }

    fn inferQueryOp(self: *@This(), idx: ast.NodeIdx, lhs: ast.NodeIdx) InferError!Type {
        if (!self.in_fallible_scope) return self.failAtNode(idx, error.FallibleOutsideFallibleContext);
        const lhs_ty = try self.inferNode(lhs);
        const lhs_variant = switch (lhs_ty) {
            .variant => |variant_ty| variant_ty,
            else => return self.failAtNode(lhs, error.QueryOperandNotVariant),
        };

        // Find the none member tag index
        const none_tag = variantMemberIndex(lhs_variant, .none) orelse return self.failAtNode(lhs, error.QueryVariantNoNone);

        // Store the none tag for IR lowering
        try self.typed.query_none_tags.put(idx, none_tag);

        // Compute the stripped variant (minus none)
        var remaining = try std.ArrayList(Type).initCapacity(self.gpa, lhs_variant.members.len - 1);
        defer remaining.deinit(self.gpa);
        for (lhs_variant.members) |member_ty| {
            if (!typeEql(member_ty, .none)) {
                try remaining.append(self.gpa, member_ty);
            }
        }

        if (remaining.items.len == 1) return self.remember(idx, remaining.items[0]);
        const stripped_variant = try self.allocVariantType(remaining.items);
        return self.remember(idx, .{ .variant = stripped_variant });
    }

    const IfCondBinding = struct {
        name: []const u8,
        ty: Type,
        mutable: bool,
    };

    fn inferIfCondBinding(self: *@This(), cond: ast.NodeIdx) InferError!?IfCondBinding {
        const a = self.parsed.ast;
        const cond_tag = a.nodes[cond].tag;
        if (cond_tag != .const_decl and cond_tag != .var_decl) return null;

        const value_node = a.varDeclValue(cond);
        const value_ty = try self.inferNode(value_node);
        if (!isFallibleNode(a, value_node)) return self.failAtNode(value_node, error.IfConditionNotFallible);
        if (value_ty == .type_type) return self.failAtNode(cond, error.RuntimeTypeValue);

        var binding_ty = value_ty;
        if (a.varDeclHasType(cond)) {
            const annot_ty = try self.resolveTypeNode(a.varDeclType(cond).?);
            if (!typeEql(annot_ty, value_ty)) return self.failAtNodeWithTypes(cond, error.BindingTypeMismatch, annot_ty, value_ty);
            binding_ty = annot_ty;
        }
        try self.typed.decl_binding_types.put(cond, binding_ty);
        _ = try self.remember(cond, .unit);
        return .{
            .name = a.identOf(a.nodes[cond].data0),
            .ty = binding_ty,
            .mutable = cond_tag == .var_decl,
        };
    }

    fn inferIf(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const prev_fallible = self.in_fallible_scope;
        self.in_fallible_scope = true;
        defer self.in_fallible_scope = prev_fallible;

        const a = self.parsed.ast;
        const data = a.ifData(idx);

        const cond_binding = try self.inferIfCondBinding(data.cond);
        const cond_mark = self.bindings.mark();
        if (cond_binding == null) {
            _ = try self.inferNode(data.cond);
            if (!isFallibleNode(a, data.cond)) return self.failAtNode(data.cond, error.IfConditionNotFallible);
        }

        const then_ty = then_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            if (cond_binding) |binding| {
                try self.pushBinding(data.cond, binding.name, .{
                    .ty = binding.ty,
                    .mutable = binding.mutable,
                    .comptime_visible = self.in_comptime_context,
                });
            }
            break :then_blk try self.inferNode(data.then_);
        };

        self.bindings.restore(cond_mark);

        if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
            const else_ty = else_blk: {
                const mark = self.bindings.mark();
                defer self.bindings.restore(mark);
                break :else_blk try self.inferNode(data.else_);
            };
            const merged = if (typeEql(then_ty, else_ty)) then_ty else try self.computeInferredReturnType(&.{ then_ty, else_ty });
            return self.remember(idx, merged);
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
        return self.remember(idx, binding_ty);
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

    fn inferFieldAssign(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const field_node = a.nodes[idx].data0;
        const value_node = a.nodes[idx].data1;
        _ = try self.inferFieldAccess(field_node);
        const field_ty = self.typed.typeOf(field_node) catch return self.failAtNode(idx, error.MissingNodeType);
        const target = a.nodes[field_node].data0;
        if (a.nodes[target].tag == .var_ref) {
            const name = a.identOf(a.nodes[target].data0);
            const binding = self.lookupBinding(name) orelse return self.failAtNode(idx, error.UnknownSymbol);
            if (!binding.mutable) return self.failAtNode(idx, error.MutateConst);
        }
        const value_ty = try self.inferNode(value_node);
        if (!isAssignableTo(field_ty, value_ty)) return self.failAtNodeWithTypes(idx, error.AssignmentTypeMismatch, field_ty, value_ty);
        return self.remember(idx, .unit);
    }

    fn inferCall(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const callee = a.nodes[idx].data0;
        const callee_ty = try self.inferNode(callee);

        // Check if this is a call to a generic function (with comptime params)
        if (callee_ty == .func) {
            const resolved_ref = self.resolved.node_refs.get(callee);
            if (resolved_ref) |ref| {
                if (ref == .function) {
                    const generic_fn_id = ref.function;
                    if (generic_fn_id < self.typed.functions.items.len) {
                        const gen_info = self.typed.functions.items[generic_fn_id];
                        const mask = if (gen_info.decl != std.math.maxInt(ast.NodeIdx))
                            a.fnComptimeMask(gen_info.decl)
                        else
                            0;
                        if (mask != 0) {
                            return self.inferMonomorphizedCall(idx, generic_fn_id, mask);
                        }
                    }
                }
            }
        }

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

    fn checkRuntimeArgs(self: *@This(), call_idx: ast.NodeIdx, args: []const ast.NodeIdx, params: []const Type) InferError!void {
        if (args.len != params.len) return self.failAtNode(call_idx, error.CallArityMismatch);
        for (args, params) |arg_node, param_ty| {
            const arg_ty = try self.inferNode(arg_node);
            if (!isAssignableTo(param_ty, arg_ty)) return self.failAtNodeWithTypes(arg_node, error.CallArgumentMismatch, param_ty, arg_ty);
        }
    }

    fn inferMonomorphizedCall(self: *@This(), call_idx: ast.NodeIdx, generic_fn_id: u32, comptime_mask: u32) InferError!Type {
        const a = self.parsed.ast;
        const generic_info = self.typed.functions.items[generic_fn_id];
        const func_decl = generic_info.decl;
        const args = a.callArgs(call_idx);
        const params = a.fnParams(func_decl);

        // Collect comptime args (evaluate them)
        var comptime_types = try std.ArrayList(Type).initCapacity(self.gpa, 4);
        defer comptime_types.deinit(self.gpa);
        var comptime_values = try std.ArrayList(ComptimeValue).initCapacity(self.gpa, 4);
        defer comptime_values.deinit(self.gpa);
        var runtime_arg_nodes = try std.ArrayList(ast.NodeIdx).initCapacity(self.gpa, args.len);
        defer runtime_arg_nodes.deinit(self.gpa);

        for (args, 0..) |arg_node, arg_idx| {
            if (comptime_mask & (@as(u32, 1) << @intCast(arg_idx)) != 0) {
                const prev = self.in_comptime_context;
                self.in_comptime_context = true;
                var eval_locals = scope_mod.ScopeStack(EvalBinding).init();
                defer eval_locals.deinit(self.gpa);
                const eval_result = self.evalNodeStep(arg_node, &eval_locals) catch |err| {
                    self.in_comptime_context = prev;
                    return err;
                };
                self.in_comptime_context = prev;
                if (eval_result.value == .type_value) {
                    try comptime_types.append(self.gpa, eval_result.value.type_value);
                } else {
                    try comptime_types.append(self.gpa, .type_type);
                }
                // Verify comptime arg type matches declared parameter type
                const declared_param_ty = try self.resolveTypeNode(params[arg_idx].ty);
                const arg_ct_ty = comptimeValueCtype(eval_result.value);
                if (!typeEql(declared_param_ty, arg_ct_ty)) {
                    return self.failAtNodeWithTypes(arg_node, error.CallArgumentMismatch, declared_param_ty, arg_ct_ty);
                }
                try comptime_values.append(self.gpa, try self.cloneCtValue(eval_result.value));
            } else {
                try runtime_arg_nodes.append(self.gpa, arg_node);
            }
        }

        // Build cache key
        const fn_name = a.identOf(a.nodes[func_decl].data0);
        var key_buf = try std.ArrayList(u8).initCapacity(self.gpa, 64);
        defer key_buf.deinit(self.gpa);
        try key_buf.appendSlice(self.gpa, fn_name);
        for (comptime_types.items) |ct| {
            try key_buf.append(self.gpa, '$');
            try key_buf.appendSlice(self.gpa, typeName(ct));
        }
        const key = key_buf.items;

        // Check cache
        if (self.monomorph_cache.get(key)) |existing_fn_id| {
            const mono_info = self.typed.functions.items[existing_fn_id];
            try self.checkRuntimeArgs(call_idx, runtime_arg_nodes.items, mono_info.ty.params);
            try self.typed.call_monomorph_targets.put(call_idx, existing_fn_id);
            return self.remember(call_idx, mono_info.ty.ret);
        }

        // Bind comptime param values first so they're available when resolving runtime param types
        var comptime_idx: usize = 0;
        for (params, 0..) |param, param_idx| {
            if (comptime_mask & (@as(u32, 1) << @intCast(param_idx)) != 0) {
                const pname = a.identOf(param.name);
                const ct_value = comptime_values.items[comptime_idx];
                try self.typed.comptime_values.put(pname, try self.cloneCtValue(ct_value));
                comptime_idx += 1;
            }
        }

        // Build monomorphized param types (comptime params are now bound)
        var mono_param_types = try std.ArrayList(Type).initCapacity(self.gpa, params.len);
        defer mono_param_types.deinit(self.gpa);
        for (params, 0..) |param, param_idx| {
            if (comptime_mask & (@as(u32, 1) << @intCast(param_idx)) != 0) continue;
            const resolved_ty = try self.resolveTypeNode(param.ty);
            try mono_param_types.append(self.gpa, resolved_ty);
        }

        const mono_ret_ty = try self.resolveFnRetType(func_decl);
        const mono_fn_ty = try self.allocFuncType(mono_param_types.items, mono_ret_ty);

        // Check binding annotation if present
        if (a.comptimeFnAnnotation(func_decl)) |annot| {
            const annot_ty = try self.resolveTypeNode(annot);
            if (!typeEql(.{ .func = mono_fn_ty }, annot_ty)) return self.failAtNodeWithTypes(func_decl, error.BindingTypeMismatch, annot_ty, .{ .func = mono_fn_ty });
        }

        // Create monomorphized function entry (body will be typechecked by checkFunction later)
        const new_fn_id: u32 = @intCast(self.typed.functions.items.len);
        try self.typed.functions.append(self.gpa, .{
            .decl = func_decl,
            .ty = mono_fn_ty,
            .param_modes = try self.runtimeParamModes(func_decl),
            .has_explicit_return = false,
            .is_monomorphized = true,
        });

        // Cache
        const owned_key = try self.typed.arena.allocator().dupe(u8, key);
        try self.monomorph_cache.put(owned_key, new_fn_id);

        // Record this call node -> monomorphized function mapping
        try self.typed.call_monomorph_targets.put(call_idx, new_fn_id);

        try self.checkRuntimeArgs(call_idx, runtime_arg_nodes.items, mono_fn_ty.params);

        // Check monomorphized function body immediately so it doesn't get re-checked
        // in the run() loop, which would overwrite shared AST node types.
        {
            const saved_saw_return = self.current_saw_return;
            const saved_inferring = self.inferring_return;
            const saved_seen = self.seen_return_types.items.len;
            try self.checkFunction(new_fn_id);
            self.current_saw_return = saved_saw_return;
            self.inferring_return = saved_inferring;
            self.seen_return_types.shrinkRetainingCapacity(saved_seen);
            self.typed.functions.items[new_fn_id].body_checked_during_mono = true;
        }

        return self.remember(call_idx, mono_fn_ty.ret);
    }

    fn clearNodeTypesInSubtree(self: *@This(), idx: ast.NodeIdx) void {
        _ = self.typed.node_types.remove(idx);
        const a = self.parsed.ast;
        switch (a.nodes[idx].tag) {
            .block => {
                for (a.blockItems(idx)) |item| self.clearNodeTypesInSubtree(item);
            },
            .var_ref, .int_lit, .float_lit, .bool_lit, .unit_lit, .none_lit => {},
            .query_op => self.clearNodeTypesInSubtree(a.nodes[idx].data0),
            .const_decl, .var_decl => {
                self.clearNodeTypesInSubtree(a.varDeclValue(idx));
            },
            .assign => self.clearNodeTypesInSubtree(a.nodes[idx].data1),
            .return_stmt => self.clearNodeTypesInSubtree(a.nodes[idx].data0),
            .call => {
                self.clearNodeTypesInSubtree(a.nodes[idx].data0);
                for (a.callArgs(idx)) |arg| self.clearNodeTypesInSubtree(arg);
            },
            .print_stmt => self.clearNodeTypesInSubtree(a.nodes[idx].data0),
            .@"not" => {
                self.clearNodeTypesInSubtree(a.nodes[idx].data0);
            },
            .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or" => {
                self.clearNodeTypesInSubtree(a.nodes[idx].data0);
                self.clearNodeTypesInSubtree(a.nodes[idx].data1);
            },
            .if_stmt => {
                const data = a.ifData(idx);
                self.clearNodeTypesInSubtree(data.cond);
                self.clearNodeTypesInSubtree(data.then_);
                if (data.else_ != std.math.maxInt(ast.NodeIdx)) self.clearNodeTypesInSubtree(data.else_);
            },
            .struct_init => {
                for (a.structInitFields(idx)) |field| self.clearNodeTypesInSubtree(field.value);
            },
            .move_expr => self.clearNodeTypesInSubtree(a.nodes[idx].data0),
            .field_access => self.clearNodeTypesInSubtree(a.nodes[idx].data0),
            .field_assign => {
                self.clearNodeTypesInSubtree(a.nodes[idx].data0);
                self.clearNodeTypesInSubtree(a.nodes[idx].data1);
            },
            .comptime_expr => self.clearNodeTypesInSubtree(a.comptimeExprBody(idx)),
            .sizeof_expr => {},
            .comptime_value_decl => self.clearNodeTypesInSubtree(a.comptimeValueDeclValue(idx)),
            else => {},
        }
    }

    fn inferReturn(self: *@This(), idx: ast.NodeIdx) InferError!Type {
        const a = self.parsed.ast;
        const ret_val = a.nodes[idx].data0;
        const ret_ty = try self.inferNode(ret_val);
        if (self.inferring_return) {
            try self.seen_return_types.append(self.gpa, ret_ty);
        } else if (!isAssignableTo(self.current_return, ret_ty)) {
            return self.failAtNodeWithTypes(idx, error.ReturnTypeMismatch, self.current_return, ret_ty);
        }
        self.current_saw_return = true;
        return self.remember(idx, .unit);
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
            .none => .none,
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

    fn checkStructInitFields(self: *@This(), idx: ast.NodeIdx, expected: []const ResolvedField) InferError!void {
        const a = self.parsed.ast;
        const fields = a.structInitFields(idx);
        if (fields.len != expected.len) return self.failAtNode(idx, error.StructInitFieldCountMismatch);
        for (fields, expected) |given, exp| {
            if (!std.mem.eql(u8, a.identOf(given.name), exp.name)) return self.failAtNode(idx, error.StructInitFieldNameMismatch);
            const value_ty = try self.inferNode(given.value);
            if (!typeEql(value_ty, exp.ty)) return self.failAtNodeWithTypes(idx, error.BindingTypeMismatch, exp.ty, value_ty);
        }
    }

    fn resolveDeclFields(self: *@This(), struct_decl: ast.NodeIdx) InferError![]const ResolvedField {
        const a = self.parsed.ast;
        const decl_fields = a.structFields(struct_decl);
        const arena = self.typed.arena.allocator();
        const resolved = try arena.alloc(ResolvedField, decl_fields.len);
        for (decl_fields, 0..) |df, i| resolved[i] = .{ .name = a.identOf(df.name), .ty = try self.resolveTypeNode(df.ty) };
        return resolved;
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

        // Try named struct decl
        if (self.findStructDecl(si_name)) |struct_decl| {
            const expected = try self.resolveDeclFields(struct_decl);
            try self.checkStructInitFields(idx, expected);
            return self.remember(idx, .{ .named = si_name });
        }

        // Try comptime-evaluated struct fields
        try self.ensureComptimeStructFields(si_name);
        if (self.typed.comptime_struct_fields.get(si_name)) |resolved_fields| {
            try self.checkStructInitFields(idx, resolved_fields);
            return self.remember(idx, .{ .named = si_name });
        }

        // Try comptime value holding a struct type
        if (a.nodes[type_expr].tag == .var_ref) {
            const tv_name = a.identOf(a.nodes[type_expr].data0);
            if (self.typed.comptime_values.get(tv_name)) |cv| {
                if (cv == .struct_type) {
                    const struct_decl = cv.struct_type;
                    const expected = try self.resolveDeclFields(struct_decl);
                    try self.checkStructInitFields(idx, expected);
                    return self.remember(idx, .{ .named = a.identOf(a.nodes[struct_decl].data0) });
                }
                const actual_ty = comptimeValueCtype(cv);
                return self.failAtNodeWithTypes(idx, error.StructInitTypeNotStruct, .type_type, actual_ty);
            }
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
            for (a.structFields(struct_decl), 0..) |f, i| {
                const f_name = a.identOf(f.name);
                if (std.mem.eql(u8, f_name, field_name)) {
                    try self.typed.field_index.put(idx, @intCast(i));
                    return self.remember(idx, try self.resolveTypeNode(f.ty));
                }
            }
            return self.failAtNode(idx, error.UnknownField);
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

    fn comptimeValueCtype(value: ComptimeValue) Type {
        return switch (value) {
            .unit => .unit,
            .none => .none,
            .bool => .bool,
            .int => .int,
            .float => .float,
            .func, .struct_type, .struct_value, .type_value => .type_type,
        };
    }

    fn runtimeTypeOfComptimeValue(self: *@This(), source_idx: ast.NodeIdx, value: ComptimeValue) InferError!Type {
        return switch (value) {
            .unit => .unit,
            .none => .none,
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
            .@"not" => {
                return !try self.evalPredicate(a.nodes[idx].data0, locals);
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
            .as => blk: {
                const lhs_node = a.asLhs(idx);
                const lhs_value = (try self.evalNodeStep(lhs_node, locals)).value;
                const lhs_ty = try self.runtimeTypeOfComptimeValue(lhs_node, lhs_value);
                const rhs_ty = try self.resolveTypeNode(a.asRhsType(idx));
                if (rhs_ty == .variant) break :blk false;
                break :blk typeEql(lhs_ty, rhs_ty);
            },
            .const_decl, .var_decl => blk: {
                const value_node = a.varDeclValue(idx);
                if (a.nodes[value_node].tag != .as) break :blk false;

                const lhs_node = a.asLhs(value_node);
                const lhs_value = (try self.evalNodeStep(lhs_node, locals)).value;
                const lhs_ty = try self.runtimeTypeOfComptimeValue(lhs_node, lhs_value);
                const rhs_ty = try self.resolveTypeNode(a.asRhsType(value_node));
                if (rhs_ty == .variant or !typeEql(lhs_ty, rhs_ty)) break :blk false;

                const name = a.identOf(a.nodes[idx].data0);
                try self.pushLocal(locals, idx, name, .{
                    .value = try self.cloneCtValue(lhs_value),
                    .mutable = a.nodes[idx].tag == .var_decl,
                });
                break :blk true;
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
        const info = self.typed.functions.items[fn_id];
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
        const step = try self.evalNodeStep(a.varDeclValue(idx), locals);
        try self.pushLocal(locals, idx, name, .{ .value = try self.cloneCtValue(step.value), .mutable = mutable });
        return step;
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
            .none_lit => .{ .value = .none, .returned = false },
            .var_ref => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                if (locals.lookupPtr(name)) |binding| {
                    break :blk .{ .value = binding.value, .returned = false };
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
                const binding = locals.lookupPtr(name) orelse return self.failAtNode(idx, error.ComptimeCaptureNotAllowed);
                if (!binding.mutable) return self.failAtNode(idx, error.AssignToConst);
                binding.value = try self.cloneCtValue(value);
                break :blk .{ .value = .unit, .returned = false };
            },
            .return_stmt => blk: {
                const value = (try self.evalNodeStep(a.nodes[idx].data0, locals)).value;
                break :blk .{ .value = value, .returned = true };
            },
            .field_assign => blk: {
                _ = try self.evalNodeStep(a.nodes[idx].data0, locals);
                _ = try self.evalNodeStep(a.nodes[idx].data1, locals);
                break :blk .{ .value = .unit, .returned = false };
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
            .lt, .gt, .le, .ge, .eq, .ne, .is, .@"and", .@"or", .@"not" => .{ .value = .unit, .returned = false },
            .as => blk: {
                const lhs_node = a.asLhs(idx);
                const lhs_step = try self.evalNodeStep(lhs_node, locals);
                const lhs_ty = try self.runtimeTypeOfComptimeValue(lhs_node, lhs_step.value);
                const rhs_ty = try self.resolveTypeNode(a.asRhsType(idx));
                if (typeEql(lhs_ty, rhs_ty)) {
                    break :blk .{ .value = try self.cloneCtValue(lhs_step.value), .returned = false };
                }
                break :blk .{ .value = .unit, .returned = false };
            },
            .query_op => blk: {
                const lhs_node = a.queryOpLhs(idx);
                const lhs_step = try self.evalNodeStep(lhs_node, locals);
                break :blk .{ .value = try self.cloneCtValue(lhs_step.value), .returned = false };
            },
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
            .move_expr => self.evalNodeStep(a.nodes[idx].data0, locals),
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
            .sizeof_expr => blk: {
                const value = self.typed.comptime_node_values.get(idx) orelse return self.failAtNode(idx, error.ComptimeValueNotAvailable);
                break :blk .{ .value = value, .returned = false };
            },
            .comptime_value_decl => .{ .value = .unit, .returned = false },
            .comptime_fn, .comptime_struct => .{ .value = .unit, .returned = false },
            .type_name => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                if (locals.lookupPtr(name)) |binding| {
                    break :blk .{ .value = binding.value, .returned = false };
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
            .struct_decl => self.remember(idx, .type_type),
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
            .none_lit => self.remember(idx, .none),
            .var_ref => self.inferVarRef(idx),
            .var_decl => self.inferDecl(idx, true),
            .assign => self.inferAssign(idx),
            .field_assign => self.inferFieldAssign(idx),
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
            .none, .named, .func, .type_type, .variant => return self.failAtNode(child, error.PrintUnsupportedType),
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
            .as => try self.inferAs(idx, a.asLhs(idx), a.asRhsType(idx)),
            .query_op => try self.inferQueryOp(idx, a.queryOpLhs(idx)),
            .@"and", .@"or" => try self.inferLogical(idx, a.nodes[idx].data0, a.nodes[idx].data1),
            .@"not" => try self.inferNot(idx),
            .if_stmt => self.inferIf(idx),
            .struct_init => self.inferStructInit(idx),
            .move_expr => try self.remember(idx, try self.inferNode(a.nodes[idx].data0)),
            .field_access => self.inferFieldAccess(idx),
            .comptime_expr => self.inferComptimeExpr(idx),
            .sizeof_expr => blk: {
                const type_node = a.nodes[idx].data0;
                const resolved_ty = try self.resolveTypeNode(type_node);
                    const byte_size: i32 = @as(i32, @intCast(try self.computeByteSize(resolved_ty)));
                try self.typed.comptime_node_values.put(idx, .{ .int = byte_size });
                break :blk try self.remember(idx, .int);
            },
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
        if (fn_id >= self.typed.functions.items.len) return;
        const info = self.typed.functions.items[fn_id];
        if (self.hasComptimeParams(info) and !info.is_monomorphized) return;

        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        const is_top_level = info.decl == std.math.maxInt(ast.NodeIdx);

        // Determine if return type should be inferred from return statements
        const has_inferred_ret = if (!is_top_level) blk: {
            const a = self.parsed.ast;
            break :blk a.fnRetType(info.decl) == ast.FN_NO_RET_TYPE;
        } else false;

        if (has_inferred_ret) {
            self.inferring_return = true;
            self.seen_return_types.clearRetainingCapacity();
            self.current_return = .unit;
        } else {
            self.inferring_return = false;
            self.current_return = info.ty.ret;
        }
        self.current_saw_return = false;

        if (!is_top_level) {
            const a = self.parsed.ast;
            if (info.is_monomorphized) {
                // For monomorphized functions, only bind runtime params (skip comptime ones)
                const mask = a.fnComptimeMask(info.decl);
                var runtime_idx: u32 = 0;
                for (a.fnParams(info.decl), 0..) |param, param_idx| {
                    if (mask & (@as(u32, 1) << @intCast(param_idx)) != 0) continue;
                    if (runtime_idx >= info.ty.params.len) return;
                    const param_ty = info.ty.params[runtime_idx];
                    const access_mode = info.param_modes[runtime_idx];
                    const pname = a.identOf(param.name);
                    const mutable = paramModeIsMutable(access_mode);
                    try self.pushBinding(info.decl, pname, .{ .ty = param_ty, .mutable = mutable, .comptime_visible = false });
                    runtime_idx += 1;
                }
                // Clear cached node_types for body since shared AST nodes may have stale types
                const body = a.fnBody(info.decl);
                self.clearNodeTypesInSubtree(body);
            } else {
                for (a.fnParams(info.decl), info.ty.params, info.param_modes) |param, param_ty, access_mode| {
                    const pname = a.identOf(param.name);
                    const mutable = paramModeIsMutable(access_mode);
                    try self.pushBinding(info.decl, pname, .{ .ty = param_ty, .mutable = mutable, .comptime_visible = false });
                }
            }
        }

        const body = if (is_top_level) self.parsed.ast.entry else self.parsed.ast.fnBody(info.decl);
        const body_ty: Type = if (has_inferred_ret) blk: {
            break :blk self.inferNode(body) catch |err| switch (err) {
                error.TypecheckFailed => .unit,
                error.OutOfMemory => return error.OutOfMemory,
            };
        } else try self.inferNode(body);

        if (has_inferred_ret) {
            const inferred_ty = if (self.current_saw_return)
                try self.computeInferredReturnType(self.seen_return_types.items)
            else
                body_ty;
            self.typed.functions.items[fn_id].ty.ret = inferred_ty;

            // Second pass: re-check body with the correct return type so that
            // recursive calls resolve properly. Clear failure from first pass.
            self.failure = null;
            self.current_return = inferred_ty;
            self.inferring_return = false;
            self.current_saw_return = false;
            self.seen_return_types.clearRetainingCapacity();
            self.clearNodeTypesInSubtree(body);
            _ = try self.inferNode(body);
        } else if (!self.current_saw_return and !isAssignableTo(info.ty.ret, body_ty)) {
            if (is_top_level) {
                self.typed.functions.items[fn_id].ty.ret = body_ty;
            } else {
                return self.failAtNodeWithTypes(body, error.FunctionBodyTypeMismatch, info.ty.ret, body_ty);
            }
        }
        self.typed.functions.items[fn_id].has_explicit_return = self.current_saw_return;
    }

    fn run(self: *@This()) InferError!void {
        try self.setupFunctionSignatures();
        try self.computeOwnershipSpecs();
        try self.validateTopLevelComptimeDecls();

        var idx: u32 = 0;
        while (idx < self.typed.functions.items.len) : (idx += 1) {
            // Skip monomorphized functions already checked during monomorphization
            if (!self.typed.functions.items[idx].body_checked_during_mono) {
                try self.checkFunction(idx);
            }
        }
        try self.runOwnershipChecks();
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
                if (failure.kind == error.ArithmeticRequiresNumeric or failure.kind == error.ComparisonRequiresNumeric) {
                    break :msg try std.fmt.allocPrint(gpa, "{s}: got '{s}'", .{ base, actual_str });
                }
                if (failure.kind == error.EqualityUnsupportedType) {
                    break :msg try std.fmt.allocPrint(gpa, "{s}: '{s}'", .{ base, expected_str });
                }
                if (failure.kind == error.StructInitTypeNotStruct) {
                    break :msg try std.fmt.allocPrint(gpa, "{s}: '{s}'", .{ base, actual_str });
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
    checker.monomorph_cache.deinit();
    checker.seen_return_types.deinit(gpa);
    checker.ownership_in_progress.deinit();
    return .{
        .typed = checker.typed,
        .diagnostic = null,
    };
}
