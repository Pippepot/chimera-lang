const std = @import("std");
const ast = @import("ast.zig");
const db = @import("db.zig");
const discover = @import("discover.zig");
const analyze = @import("analyze.zig");
const resolver = @import("resolver.zig");

pub const ScopeEntry = struct {
    name: []const u8,
    item_id: db.ItemId,
    decl: ast.NodeIdx,
};

pub const ScopeSummary = struct {
    entries: []const ScopeEntry,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
    }
};

pub const ResolvedItem = struct {
    item: db.ItemId,
    decl: ast.NodeIdx,
    node_refs: std.AutoHashMap(ast.NodeIdx, resolver.ResolvedRef),

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.node_refs.deinit();
        _ = gpa;
    }
};

pub const HeaderSignature = struct {
    item: db.ItemId,
    decl: ast.NodeIdx,
    param_count: u32,
    comptime_mask: u32,
    has_inferred_return: bool,
    has_body: bool,
    param_modes: []const ast.ParamAccessMode = &.{},
    param_types: []const analyze.Type = &.{},
    return_type: analyze.Type = .unit,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        if (self.param_modes.len > 0) gpa.free(self.param_modes);
        if (self.param_types.len > 0) {
            for (self.param_types) |ty| {
                switch (ty) {
                    .func => |f| {
                        gpa.free(f.params);
                        gpa.destroy(f);
                    },
                    .variant => |v| {
                        gpa.free(v.members);
                        gpa.destroy(v);
                    },
                    else => {},
                }
            }
            gpa.free(self.param_types);
        }
        switch (self.return_type) {
            .func => |f| {
                gpa.free(f.params);
                gpa.destroy(f);
            },
            .variant => |v| {
                gpa.free(v.members);
                gpa.destroy(v);
            },
            else => {},
        }
    }
};

pub const EffectiveSignature = struct {
    instance: db.InstanceId,
    function_id: u32,
    decl: ast.NodeIdx,
    param_count: u32,
    has_inferred_return: bool,
    has_explicit_return: bool,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        _ = self;
        _ = gpa;
    }
};

pub const BodyAnalysis = struct {
    instance: db.InstanceId,
    function_id: u32,
    decl: ast.NodeIdx,
    body: ast.NodeIdx,
    node_types: std.AutoHashMap(ast.NodeIdx, analyze.Type),
    field_index: std.AutoHashMap(ast.NodeIdx, u32),
    call_targets: std.AutoHashMap(ast.NodeIdx, db.InstanceId),
    is_variant_tags: std.AutoHashMap(ast.NodeIdx, []const u32),
    query_none_tags: std.AutoHashMap(ast.NodeIdx, u32),
    decl_binding_types: std.AutoHashMap(ast.NodeIdx, analyze.Type),

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.node_types.deinit();
        self.field_index.deinit();
        // Free owned is_variant_tags arrays
        {
            var iter = self.is_variant_tags.iterator();
            while (iter.next()) |entry| gpa.free(entry.value_ptr.*);
        }
        self.is_variant_tags.deinit();
        self.query_none_tags.deinit();
        self.decl_binding_types.deinit();
        self.call_targets.deinit();
    }
};

pub const HeaderMemo = db.Memo(HeaderSignature);
pub const EffectiveMemo = db.Memo(EffectiveSignature);
pub const BodyMemo = db.Memo(BodyAnalysis);
pub const ScopeMemo = db.Memo(ScopeSummary);
pub const ResolveItemMemo = db.Memo(ResolvedItem);

fn resolveHeaderTypeNode(
    type_idx: ast.TypeIdx,
    a: *const ast.Ast,
    resolved: *const resolver.ResolvedAst,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!?analyze.Type {
    switch (a.nodes[type_idx].tag) {
        .type_name => {
            const name = a.identOf(a.nodes[type_idx].data0);
            if (std.mem.eql(u8, name, "unit")) return analyze.Type.unit;
            if (std.mem.eql(u8, name, "bool")) return analyze.Type.bool;
            if (std.mem.eql(u8, name, "int")) return analyze.Type.int;
            if (std.mem.eql(u8, name, "float")) return analyze.Type.float;
            if (std.mem.eql(u8, name, "type")) return analyze.Type.type_type;
            if (std.mem.eql(u8, name, "none")) return analyze.Type.none;
            if (resolved.struct_names.contains(name)) return analyze.Type{ .named = name };
            // Comptime value names — we can't resolve these without evaluation
            if (resolved.comptime_value_names.contains(name)) return null;
            if (resolved.function_names.contains(name)) return null;
            return null;
        },
        .type_func => {
            const param_indices = a.funcTypeParams(type_idx);
            var params = try std.ArrayList(analyze.Type).initCapacity(gpa, param_indices.len);
            defer params.deinit(gpa);
            for (param_indices) |p| {
                const resolved_ty = (try resolveHeaderTypeNode(p, a, resolved, gpa)) orelse return null;
                try params.append(gpa, resolved_ty);
            }
            const ret_ty = (try resolveHeaderTypeNode(a.funcTypeRet(type_idx), a, resolved, gpa)) orelse return null;
            const fn_ty = try gpa.create(analyze.FuncType);
            fn_ty.* = .{
                .params = try gpa.dupe(analyze.Type, params.items),
                .ret = ret_ty,
            };
            return analyze.Type{ .func = fn_ty };
        },
        .type_variant => {
            const member_type_indices = a.variantTypeMembers(type_idx);
            var members = try std.ArrayList(analyze.Type).initCapacity(gpa, member_type_indices.len);
            defer members.deinit(gpa);
            for (member_type_indices) |member_type_idx| {
                const member_ty = (try resolveHeaderTypeNode(member_type_idx, a, resolved, gpa)) orelse return null;
                for (members.items) |existing| {
                    if (analyze.typeEql(existing, member_ty)) return null;
                }
                try members.append(gpa, member_ty);
            }
            const variant_ty = try gpa.create(analyze.VariantType);
            variant_ty.* = .{
                .members = try gpa.dupe(analyze.Type, members.items),
            };
            return analyze.Type{ .variant = variant_ty };
        },
        else => return null,
    }
}

fn runtimeParamModes(a: *const ast.Ast, gpa: std.mem.Allocator, func_decl_idx: ast.NodeIdx) error{OutOfMemory}![]const ast.ParamAccessMode {
    var modes = try std.ArrayList(ast.ParamAccessMode).initCapacity(gpa, a.fnParams(func_decl_idx).len);
    defer modes.deinit(gpa);
    for (a.fnParams(func_decl_idx), 0..) |_, param_idx| {
        if (a.fnParamIsComptime(func_decl_idx, @intCast(param_idx))) continue;
        try modes.append(gpa, a.fnParamAccessMode(func_decl_idx, @intCast(param_idx)));
    }
    return gpa.dupe(ast.ParamAccessMode, modes.items);
}

pub fn computeModuleScope(
    item_tree: *const discover.ItemTree,
    parsed_ast: *const ast.Ast,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!db.Memo(ScopeSummary) {
    var diagnostics_list = try db.initDiagnosticList(gpa, &.{}, 0);
    errdefer diagnostics_list.deinit(gpa);

    var entries = try std.ArrayList(ScopeEntry).initCapacity(gpa, item_tree.items.items.len);
    defer entries.deinit(gpa);
    for (item_tree.items.items) |item| {
        const name = switch (parsed_ast.nodes[item.decl].tag) {
            .comptime_fn, .comptime_struct, .comptime_value_decl => parsed_ast.identOf(parsed_ast.nodes[item.decl].data0),
            else => "$entry",
        };
        try entries.append(gpa, .{ .name = name, .item_id = item.id, .decl = item.decl });
    }
    return db.makeMemo(ScopeSummary, .{ .entries = try gpa.dupe(ScopeEntry, entries.items) }, diagnostics_list);
}

pub fn computeResolveItem(
    item_id: db.ItemId,
    resolved: *const resolver.ResolvedAst,
    item_tree: *const discover.ItemTree,
    parsed_ast: *const ast.Ast,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!db.Memo(ResolvedItem) {
    var diagnostics_list = try db.initDiagnosticList(gpa, &.{}, 0);
    errdefer diagnostics_list.deinit(gpa);

    const item = findItem(item_tree, item_id) orelse return db.makeMemo(ResolvedItem, null, diagnostics_list);
    var node_refs = std.AutoHashMap(ast.NodeIdx, resolver.ResolvedRef).init(gpa);
    errdefer node_refs.deinit();

    // Collect all node refs for this item
    // For functions, visit the declaration and body AST nodes
    if (parsed_ast.nodes[item.decl].tag == .comptime_fn) {
        const body_node = parsed_ast.fnBody(item.decl);
        var visit_stack = std.ArrayList(ast.NodeIdx).initCapacity(gpa, 32) catch return error.OutOfMemory;
        defer visit_stack.deinit(gpa);
        visit_stack.append(gpa, item.decl) catch return error.OutOfMemory;
        if (body_node != std.math.maxInt(ast.NodeIdx)) {
            visit_stack.append(gpa, body_node) catch return error.OutOfMemory;
        }

        while (visit_stack.pop()) |node_idx| {
        if (resolved.node_refs.get(node_idx)) |ref| {
            try node_refs.put(node_idx, ref);
        }
        const tag = parsed_ast.nodes[node_idx].tag;
        switch (tag) {
            .var_ref, .int_lit, .float_lit, .bool_lit, .unit_lit, .none_lit, .arg, .type_name, .type_func, .type_variant, .type_union, .struct_expr, .comptime_fn, .comptime_struct, .comptime_value_decl, .sizeof_expr => {},
            .block => {
                for (parsed_ast.blockItems(node_idx)) |item_node| {
                    visit_stack.append(gpa, item_node) catch return error.OutOfMemory;
                }
            },
            .call => {
                visit_stack.append(gpa, parsed_ast.nodes[node_idx].data0) catch return error.OutOfMemory;
                for (parsed_ast.callArgs(node_idx)) |arg| {
                    visit_stack.append(gpa, arg) catch return error.OutOfMemory;
                }
            },
            .const_decl, .var_decl => {
                const value = parsed_ast.varDeclValue(node_idx);
                visit_stack.append(gpa, value) catch return error.OutOfMemory;
            },
            .assign, .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or", .field_assign => {
                visit_stack.append(gpa, parsed_ast.nodes[node_idx].data0) catch return error.OutOfMemory;
                visit_stack.append(gpa, parsed_ast.nodes[node_idx].data1) catch return error.OutOfMemory;
            },
            .return_stmt, .print_stmt, .field_access, .move_expr, .comptime_expr, .query_op, .@"not" => {
                visit_stack.append(gpa, parsed_ast.nodes[node_idx].data0) catch return error.OutOfMemory;
            },
            .if_stmt => {
                const data = parsed_ast.ifData(node_idx);
                visit_stack.append(gpa, data.cond) catch return error.OutOfMemory;
                visit_stack.append(gpa, data.then_) catch return error.OutOfMemory;
                if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
                    visit_stack.append(gpa, data.else_) catch return error.OutOfMemory;
                }
            },
            .struct_init => {
                for (parsed_ast.structInitFields(node_idx)) |field| {
                    visit_stack.append(gpa, field.value) catch return error.OutOfMemory;
                }
            },
            .is, .as => {
                visit_stack.append(gpa, parsed_ast.isLhs(node_idx)) catch return error.OutOfMemory;
            },
        }
    }
    } else {
        // For non-function items, just add the decl node ref
        if (resolved.node_refs.get(item.decl)) |ref| {
            try node_refs.put(item.decl, ref);
        }
    }

    return db.makeMemo(ResolvedItem, .{ .item = item_id, .decl = item.decl, .node_refs = node_refs }, diagnostics_list);
}

pub fn computeHeaderSignature(
    item_id: db.ItemId,
    item_tree: *const discover.ItemTree,
    parsed_ast: *const ast.Ast,
    resolved: *const resolver.ResolvedAst,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!HeaderMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, &.{}, 0);
    errdefer diagnostics_list.deinit(gpa);

    const item = findItem(item_tree, item_id) orelse return db.makeMemo(HeaderSignature, null, diagnostics_list);
    const node = parsed_ast.nodes[item.decl];
    const value: HeaderSignature = switch (node.tag) {
        .comptime_fn => blk: {
            const param_modes = runtimeParamModes(parsed_ast, gpa, item.decl) catch |err| {
                diagnostics_list.deinit(gpa);
                return err;
            };
            const params = parsed_ast.fnParams(item.decl);
            var param_types = try std.ArrayList(analyze.Type).initCapacity(gpa, params.len);
            defer param_types.deinit(gpa);
            for (params) |param| {
                if (try resolveHeaderTypeNode(param.ty, parsed_ast, resolved, gpa)) |resolved_ty| {
                    try param_types.append(gpa, resolved_ty);
                } else {
                    try param_types.append(gpa, analyze.Type.unit);
                }
            }
            const ret_ty = if (parsed_ast.fnRetType(item.decl) == ast.FN_NO_RET_TYPE)
                analyze.Type.unit
            else if (try resolveHeaderTypeNode(parsed_ast.fnRetType(item.decl), parsed_ast, resolved, gpa)) |resolved_ty|
                resolved_ty
            else
                analyze.Type.unit;
            break :blk HeaderSignature{
                .item = item_id,
                .decl = item.decl,
                .param_count = @intCast(params.len),
                .comptime_mask = parsed_ast.fnComptimeMask(item.decl),
                .has_inferred_return = parsed_ast.fnRetType(item.decl) == ast.FN_NO_RET_TYPE,
                .has_body = true,
                .param_modes = param_modes,
                .param_types = try gpa.dupe(analyze.Type, param_types.items),
                .return_type = ret_ty,
            };
        },
        .comptime_value_decl => .{
            .item = item_id,
            .decl = item.decl,
            .param_count = 0,
            .comptime_mask = 0,
            .has_inferred_return = false,
            .has_body = true,
        },
        .comptime_struct => .{
            .item = item_id,
            .decl = item.decl,
            .param_count = 0,
            .comptime_mask = 0,
            .has_inferred_return = false,
            .has_body = false,
        },
        else => .{
            .item = item_id,
            .decl = item.decl,
            .param_count = 0,
            .comptime_mask = 0,
            .has_inferred_return = false,
            .has_body = item.body != null,
        },
    };
    return db.makeMemo(HeaderSignature, value, diagnostics_list);
}

pub fn computeEffectiveSignature(
    instance_id: db.InstanceId,
    typed: *const analyze.AnalyzedAst,
    item_tree: *const discover.ItemTree,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!EffectiveMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, &.{}, 0);
    errdefer diagnostics_list.deinit(gpa);

    const item = findItem(item_tree, instance_id.item) orelse return db.makeMemo(EffectiveSignature, null, diagnostics_list);
    const function_id = findFunctionId(typed, item) orelse return db.makeMemo(EffectiveSignature, null, diagnostics_list);
    const info = typed.functions.items[function_id];
    const value: EffectiveSignature = .{
        .instance = instance_id,
        .function_id = function_id,
        .decl = info.decl,
        .param_count = @intCast(info.ty.params.len),
        .has_inferred_return = item.id.kind == .top_level_entry or (info.decl != std.math.maxInt(ast.NodeIdx) and typed.ast.fnRetType(info.decl) == ast.FN_NO_RET_TYPE),
        .has_explicit_return = info.has_explicit_return,
    };
    return db.makeMemo(EffectiveSignature, value, diagnostics_list);
}

fn collectBodyNodeTypes(
    body: ast.NodeIdx,
    typed: *const analyze.AnalyzedAst,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!struct {
    node_types: std.AutoHashMap(ast.NodeIdx, analyze.Type),
    field_index: std.AutoHashMap(ast.NodeIdx, u32),
    call_targets: std.AutoHashMap(ast.NodeIdx, db.InstanceId),
    is_variant_tags: std.AutoHashMap(ast.NodeIdx, []const u32),
    query_none_tags: std.AutoHashMap(ast.NodeIdx, u32),
    decl_binding_types: std.AutoHashMap(ast.NodeIdx, analyze.Type),
} {
    var node_types = std.AutoHashMap(ast.NodeIdx, analyze.Type).init(gpa);
    errdefer node_types.deinit();
    var field_index = std.AutoHashMap(ast.NodeIdx, u32).init(gpa);
    errdefer field_index.deinit();
    var call_targets = std.AutoHashMap(ast.NodeIdx, db.InstanceId).init(gpa);
    errdefer call_targets.deinit();
    var is_variant_tags = std.AutoHashMap(ast.NodeIdx, []const u32).init(gpa);
    errdefer {
        var iter = is_variant_tags.iterator();
        while (iter.next()) |entry| gpa.free(entry.value_ptr.*);
        is_variant_tags.deinit();
    }
    var query_none_tags = std.AutoHashMap(ast.NodeIdx, u32).init(gpa);
    errdefer query_none_tags.deinit();
    var decl_binding_types = std.AutoHashMap(ast.NodeIdx, analyze.Type).init(gpa);
    errdefer decl_binding_types.deinit();

    var stack = std.ArrayList(ast.NodeIdx).initCapacity(gpa, 32) catch return error.OutOfMemory;
    defer stack.deinit(gpa);
    stack.append(gpa, body) catch return error.OutOfMemory;

    const a = typed.ast;
    while (stack.pop()) |node_idx| {
        if (typed.node_types.get(node_idx)) |ty| {
            try node_types.put(node_idx, ty);
        }
        if (typed.field_index.get(node_idx)) |fi| {
            try field_index.put(node_idx, fi);
        }
        if (typed.call_monomorph_targets.get(node_idx)) |inst_id| {
            try call_targets.put(node_idx, inst_id);
        }
        if (typed.is_variant_tags.get(node_idx)) |tags| {
            const owned_tags = try gpa.dupe(u32, tags);
            try is_variant_tags.put(node_idx, owned_tags);
        }
        if (typed.query_none_tags.get(node_idx)) |tag| {
            try query_none_tags.put(node_idx, tag);
        }
        if (typed.decl_binding_types.get(node_idx)) |bt| {
            try decl_binding_types.put(node_idx, bt);
        }

        switch (a.nodes[node_idx].tag) {
            .var_ref, .int_lit, .float_lit, .bool_lit, .unit_lit, .none_lit,
            .arg, .type_name, .type_func, .type_variant, .type_union,
            .struct_expr, .comptime_fn, .comptime_struct, .comptime_value_decl,
            .sizeof_expr => {},
            .block => {
                for (a.blockItems(node_idx)) |item| {
                    try stack.append(gpa, item);
                }
            },
            .call => {
                try stack.append(gpa, a.nodes[node_idx].data0);
                for (a.callArgs(node_idx)) |arg| {
                    try stack.append(gpa, arg);
                }
            },
            .const_decl, .var_decl => {
                try stack.append(gpa, a.varDeclValue(node_idx));
            },
            .assign, .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne,
            .@"and", .@"or", .field_assign => {
                try stack.append(gpa, a.nodes[node_idx].data0);
                try stack.append(gpa, a.nodes[node_idx].data1);
            },
            .return_stmt, .print_stmt, .field_access, .move_expr,
            .comptime_expr, .query_op, .@"not" => {
                try stack.append(gpa, a.nodes[node_idx].data0);
            },
            .if_stmt => {
                const data = a.ifData(node_idx);
                try stack.append(gpa, data.cond);
                try stack.append(gpa, data.then_);
                if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
                    try stack.append(gpa, data.else_);
                }
            },
            .struct_init => {
                for (a.structInitFields(node_idx)) |field| {
                    try stack.append(gpa, field.value);
                }
            },
            .is, .as => {
                try stack.append(gpa, a.isLhs(node_idx));
            },
        }
    }

    return .{
        .node_types = node_types,
        .field_index = field_index,
        .call_targets = call_targets,
        .is_variant_tags = is_variant_tags,
        .query_none_tags = query_none_tags,
        .decl_binding_types = decl_binding_types,
    };
}

pub fn computeBodyAnalysis(
    instance_id: db.InstanceId,
    effective: *const EffectiveSignature,
    typed: *const analyze.AnalyzedAst,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!BodyMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, &.{}, 0);
    errdefer diagnostics_list.deinit(gpa);

    const body_node = if (effective.decl == std.math.maxInt(ast.NodeIdx))
        typed.ast.entry
    else
        typed.ast.fnBody(effective.decl);

    const collected = collectBodyNodeTypes(body_node, typed, gpa) catch |err| {
        diagnostics_list.deinit(gpa);
        return err;
    };

    return db.makeMemo(BodyAnalysis, .{
        .instance = instance_id,
        .function_id = effective.function_id,
        .decl = effective.decl,
        .body = body_node,
        .node_types = collected.node_types,
        .field_index = collected.field_index,
        .call_targets = collected.call_targets,
        .is_variant_tags = collected.is_variant_tags,
        .query_none_tags = collected.query_none_tags,
        .decl_binding_types = collected.decl_binding_types,
    }, diagnostics_list);
}

fn findItem(item_tree: *const discover.ItemTree, item_id: db.ItemId) ?discover.DiscoveredItem {
    for (item_tree.items.items) |item| {
        if (db.itemIdEql(item.id, item_id)) return item;
    }
    return null;
}

fn findFunctionId(typed: *const analyze.AnalyzedAst, item: discover.DiscoveredItem) ?u32 {
    if (item.id.kind == .top_level_entry) return typed.entry_function;
    for (typed.functions.items, 0..) |info, function_id| {
        if (info.decl == item.decl and !info.is_monomorphized) return @intCast(function_id);
    }
    return null;
}
