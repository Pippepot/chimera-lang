const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const diagnostics = @import("diagnostics.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

pub const ResolveError = error{
    DuplicateSymbol,
    UnknownSymbol,
};

pub const ResolvedRef = union(enum) {
    local,
    function: u32,
    comptime_value: ast.NodeIdx,
    struct_decl: ast.NodeIdx,
    builtin_type,
};

pub const ResolvedAst = struct {
    functions: std.ArrayList(ast.NodeIdx),
    function_names: std.StringHashMap(u32),
    comptime_value_names: std.StringHashMap(ast.NodeIdx),
    struct_names: std.StringHashMap(void),
    node_refs: std.AutoHashMap(ast.NodeIdx, ResolvedRef),
    key_arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) !ResolvedAst {
        return .{
            .functions = try std.ArrayList(ast.NodeIdx).initCapacity(gpa, 8),
            .function_names = std.StringHashMap(u32).init(gpa),
            .comptime_value_names = std.StringHashMap(ast.NodeIdx).init(gpa),
            .struct_names = std.StringHashMap(void).init(gpa),
            .node_refs = std.AutoHashMap(ast.NodeIdx, ResolvedRef).init(gpa),
            .key_arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.functions.deinit(gpa);
        self.function_names.deinit();
        self.comptime_value_names.deinit();
        self.struct_names.deinit();
        self.node_refs.deinit();
        self.key_arena.deinit();
    }
};

pub const ResolveReport = struct {
    resolved: ?ResolvedAst,
    diagnostic: ?diagnostics.Diagnostic,
};

const Resolver = struct {
    gpa: std.mem.Allocator,
    parsed: *const parser.ParsedAst,
    resolved: ResolvedAst,
    locals: scope_mod.ScopeStack(void),
    failure: ?Failure,

    const Failure = struct {
        span: ?ast.Span,
        kind: ResolveError,
    };

    fn init(parsed: *const parser.ParsedAst, gpa: std.mem.Allocator) !Resolver {
        return .{
            .gpa = gpa,
            .parsed = parsed,
            .resolved = try ResolvedAst.init(gpa),
            .locals = scope_mod.ScopeStack(void).init(),
            .failure = null,
        };
    }

    fn deinit(self: *@This()) void {
        self.locals.deinit(self.gpa);
        self.resolved.deinit(self.gpa);
    }

    fn fail(self: *@This(), span: ?ast.Span, kind: ResolveError) error{ResolveFailed} {
        if (self.failure == null) self.failure = .{ .span = span, .kind = kind };
        return error.ResolveFailed;
    }

    fn addTopLevelSymbol(self: *@This(), name: []const u8, decl_idx: ast.NodeIdx) !void {
        if (self.resolved.function_names.contains(name) or
            self.resolved.comptime_value_names.contains(name) or
            self.resolved.struct_names.contains(name))
        {
            return self.fail(self.parsed.ast.spanOf(decl_idx), error.DuplicateSymbol);
        }

        switch (self.parsed.ast.nodes[decl_idx].tag) {
            .comptime_fn => {
                const fn_id: u32 = @intCast(self.resolved.functions.items.len);
                try self.resolved.functions.append(self.gpa, decl_idx);
                try self.resolved.function_names.put(name, fn_id);
            },
            .comptime_struct => {
                try self.resolved.struct_names.put(name, {});
            },
            .comptime_value_decl => {
                try self.resolved.comptime_value_names.put(name, decl_idx);
            },
            else => {},
        }
    }

    fn resolveTopLevel(self: *@This()) !void {
        for (self.parsed.ast.decls) |decl_idx| {
            const name = self.parsed.ast.identOf(self.parsed.ast.nodes[decl_idx].data0);
            try self.addTopLevelSymbol(name, decl_idx);
        }
    }

    fn resolve(self: *@This()) !void {
        try self.resolveTopLevel();
        for (self.resolved.functions.items) |func_decl_idx| {
            try self.resolveFunction(func_decl_idx);
        }
        try self.resolveNode(self.parsed.ast.entry);
    }

    fn resolveFunction(self: *@This(), func_decl_idx: ast.NodeIdx) !void {
        const mark = self.locals.mark();
        defer self.locals.restore(mark);

        for (self.parsed.ast.fnParams(func_decl_idx)) |param| {
            const name = self.parsed.ast.identOf(param.name);
            self.locals.push(self.gpa, name, {}) catch |err| switch (err) {
                error.DuplicateVariable => return self.fail(self.parsed.ast.spanOf(func_decl_idx), error.DuplicateSymbol),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        try self.resolveNode(self.parsed.ast.fnBody(func_decl_idx));
    }

    fn resolveNode(self: *@This(), idx: ast.NodeIdx) !void {
        const ast_ = self.parsed.ast;
        switch (ast_.nodes[idx].tag) {
            .block => {
                const mark = self.locals.mark();
                defer self.locals.restore(mark);
                for (ast_.blockItems(idx)) |item| {
                    try self.resolveNode(item);
                }
            },
            .int_lit, .float_lit, .arg, .bool_lit, .unit_lit => {},
            .var_ref => {
                const name = ast_.identOf(ast_.nodes[idx].data0);
                if (self.locals.lookup(name) != null) {
                    try self.resolved.node_refs.put(idx, .local);
                    return;
                }
                if (self.resolved.function_names.get(name)) |fn_id| {
                    try self.resolved.node_refs.put(idx, .{ .function = fn_id });
                    return;
                }
                if (self.resolved.comptime_value_names.get(name)) |decl_idx| {
                    try self.resolved.node_refs.put(idx, .{ .comptime_value = decl_idx });
                    return;
                }
                if (self.parsed.ast.name_map.get(name)) |decl_idx| {
                    if (self.parsed.ast.nodes[decl_idx].tag == .comptime_struct) {
                        try self.resolved.node_refs.put(idx, .{ .struct_decl = decl_idx });
                        return;
                    }
                }
                if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float") or
                    std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "unit") or
                    std.mem.eql(u8, name, "type"))
                {
                    try self.resolved.node_refs.put(idx, .builtin_type);
                    return;
                }
                return self.fail(ast_.spanOf(idx), error.UnknownSymbol);
            },
            .const_decl => {
                const name = ast_.identOf(ast_.nodes[idx].data0);
                try self.resolveNode(ast_.varDeclValue(idx));
                self.locals.push(self.gpa, name, {}) catch |err| switch (err) {
                    error.DuplicateVariable => return self.fail(ast_.spanOf(idx), error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            },
            .var_decl => {
                const name = ast_.identOf(ast_.nodes[idx].data0);
                try self.resolveNode(ast_.varDeclValue(idx));
                self.locals.push(self.gpa, name, {}) catch |err| switch (err) {
                    error.DuplicateVariable => return self.fail(ast_.spanOf(idx), error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            },
            .assign => {
                const name = ast_.identOf(ast_.nodes[idx].data0);
                if (self.locals.lookup(name) == null) {
                if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float") or
                    std.mem.eql(u8, name, "bool") or std.mem.eql(u8, name, "unit") or
                    std.mem.eql(u8, name, "type"))
                {
                    try self.resolved.node_refs.put(idx, .builtin_type);
                    return;
                }
                return self.fail(ast_.spanOf(idx), error.UnknownSymbol);
                }
                try self.resolveNode(ast_.nodes[idx].data1);
            },
            .return_stmt => try self.resolveNode(ast_.nodes[idx].data0),
            .call => {
                try self.resolveNode(ast_.nodes[idx].data0);
                for (ast_.callArgs(idx)) |arg| try self.resolveNode(arg);
            },
            .print_stmt => try self.resolveNode(ast_.nodes[idx].data0),
            .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne => {
                try self.resolveNode(ast_.nodes[idx].data0);
                try self.resolveNode(ast_.nodes[idx].data1);
            },
            .if_stmt => {
                const data = ast_.ifData(idx);
                try self.resolveNode(data.cond);
                {
                    const mark = self.locals.mark();
                    defer self.locals.restore(mark);
                    try self.resolveNode(data.then_);
                }
                if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
                    const mark = self.locals.mark();
                    defer self.locals.restore(mark);
                    try self.resolveNode(data.else_);
                }
            },
            .struct_init => {
                try self.resolveNode(ast_.structInitTypeExpr(idx));
                for (ast_.structInitFields(idx)) |field| try self.resolveNode(field.value);
            },
            .struct_expr => {},
            .field_access => {
                try self.resolveNode(ast_.nodes[idx].data0);
            },
            .comptime_expr => try self.resolveNode(ast_.comptimeExprBody(idx)),
            .comptime_value_decl => try self.resolveNode(ast_.comptimeValueDeclValue(idx)),
            .type_name, .type_func, .comptime_fn, .comptime_struct => {},
        }
    }
};

pub fn resolveErrorMessage(kind: ResolveError) []const u8 {
    return switch (kind) {
        error.DuplicateSymbol => "duplicate symbol",
        error.UnknownSymbol => "unknown symbol",
    };
}

pub const ResolveMemo = db.Memo(ResolvedAst);

pub fn computeResolve(parse_memo: *const parser.ParseMemo, gpa: std.mem.Allocator) error{OutOfMemory}!ResolveMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, parse_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var resolved_value: ?ResolvedAst = null;
    if (parse_memo.value) |*parsed| {
        const report = try resolveReport(parsed, gpa);
        if (report.diagnostic) |diag| {
            try diagnostics_list.append(gpa, diag);
        }
        resolved_value = report.resolved;
    }

    return db.makeMemo(ResolvedAst, resolved_value, diagnostics_list);
}

pub fn resolveReport(parsed: *const parser.ParsedAst, gpa: std.mem.Allocator) error{OutOfMemory}!ResolveReport {
    var resolver = try Resolver.init(parsed, gpa);
    errdefer resolver.deinit();

    resolver.resolve() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResolveFailed => {
            const failure = resolver.failure.?;
            resolver.deinit();
            return .{
                .resolved = null,
                .diagnostic = .{
                    .stage = .resolve,
                    .span = failure.span,
                    .message = resolveErrorMessage(failure.kind),
                },
            };
        },
    };

    resolver.locals.deinit(gpa);
    return .{
        .resolved = resolver.resolved,
        .diagnostic = null,
    };
}
