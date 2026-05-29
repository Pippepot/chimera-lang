const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const diagnostics = @import("diagnostics.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

const AstNode = ast.AstNode;

pub const ResolveError = error{
    DuplicateSymbol,
    UnknownSymbol,
};

pub const ResolvedRef = union(enum) {
    local,
    function: u32,
};

pub const ResolvedAst = struct {
    module: *const ast.Module,
    functions: std.ArrayList(*const ast.FuncDecl),
    function_names: std.StringHashMap(u32),
    struct_names: std.StringHashMap(void),
    node_refs: std.AutoHashMap(usize, ResolvedRef),

    pub fn init(gpa: std.mem.Allocator, module: *const ast.Module) !ResolvedAst {
        return .{
            .module = module,
            .functions = try std.ArrayList(*const ast.FuncDecl).initCapacity(gpa, 8),
            .function_names = std.StringHashMap(u32).init(gpa),
            .struct_names = std.StringHashMap(void).init(gpa),
            .node_refs = std.AutoHashMap(usize, ResolvedRef).init(gpa),
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.functions.deinit(gpa);
        self.function_names.deinit();
        self.struct_names.deinit();
        self.node_refs.deinit();
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
            .resolved = try ResolvedAst.init(gpa, parsed.root),
            .locals = scope_mod.ScopeStack(void).init(),
            .failure = null,
        };
    }

    fn deinit(self: *@This()) void {
        self.locals.deinit(self.gpa);
        self.resolved.deinit(self.gpa);
    }

    fn spanOfDecl(self: *const @This(), decl: *const ast.Decl) ?ast.Span {
        return self.parsed.spanOfAny(@intFromPtr(decl));
    }

    fn spanOfNode(self: *const @This(), node: *const AstNode) ?ast.Span {
        return self.parsed.spanOfNode(node);
    }

    fn fail(self: *@This(), span: ?ast.Span, kind: ResolveError) error{ResolveFailed} {
        if (self.failure == null) self.failure = .{ .span = span, .kind = kind };
        return error.ResolveFailed;
    }

    fn addTopLevelSymbol(self: *@This(), name: []const u8, decl: *const ast.Decl) !void {
        if (self.resolved.function_names.contains(name) or self.resolved.struct_names.contains(name)) {
            return self.fail(self.spanOfDecl(decl), error.DuplicateSymbol);
        }

        switch (decl.*) {
            .comptime_func => |func_decl| {
                const fn_id: u32 = @intCast(self.resolved.functions.items.len);
                try self.resolved.functions.append(self.gpa, func_decl);
                try self.resolved.function_names.put(name, fn_id);
            },
            .comptime_struct => {
                try self.resolved.struct_names.put(name, {});
            },
        }
    }

    fn resolveTopLevel(self: *@This()) !void {
        for (self.resolved.module.decls) |decl| {
            const name = switch (decl.*) {
                .comptime_func => |func_decl| func_decl.name,
                .comptime_struct => |struct_decl| struct_decl.name,
            };
            try self.addTopLevelSymbol(name, decl);
        }
    }

    fn resolve(self: *@This()) !void {
        try self.resolveTopLevel();
        for (self.resolved.functions.items) |func_decl| {
            try self.resolveFunction(func_decl);
        }
        try self.resolveNode(self.resolved.module.entry);
    }

    fn resolveFunction(self: *@This(), func_decl: *const ast.FuncDecl) !void {
        const mark = self.locals.mark();
        defer self.locals.restore(mark);

        for (func_decl.params) |param| {
            self.locals.push(self.gpa, param.name, {}) catch |err| switch (err) {
                error.DuplicateVariable => return self.fail(self.spanOfNode(func_decl.body), error.DuplicateSymbol),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        try self.resolveNode(func_decl.body);
    }

    fn resolveNode(self: *@This(), node: *const AstNode) !void {
        switch (node.*) {
            .block => |blk| {
                const mark = self.locals.mark();
                defer self.locals.restore(mark);
                for (blk.items) |item| {
                    try self.resolveNode(item);
                }
            },
            .int, .float, .arg, .bool, .unit, .string => {},
            .var_ref => |name| {
                if (self.locals.lookup(name) != null) {
                    try self.resolved.node_refs.put(@intFromPtr(node), .local);
                    return;
                }
                if (self.resolved.function_names.get(name)) |fn_id| {
                    try self.resolved.node_refs.put(@intFromPtr(node), .{ .function = fn_id });
                    return;
                }
                return self.fail(self.spanOfNode(node), error.UnknownSymbol);
            },
            .const_ => |cn| {
                try self.resolveNode(cn.value);
                self.locals.push(self.gpa, cn.name, {}) catch |err| switch (err) {
                    error.DuplicateVariable => return self.fail(self.spanOfNode(node), error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            },
            .var_ => |vn| {
                try self.resolveNode(vn.value);
                self.locals.push(self.gpa, vn.name, {}) catch |err| switch (err) {
                    error.DuplicateVariable => return self.fail(self.spanOfNode(node), error.DuplicateSymbol),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            },
            .assign => |an| {
                if (self.locals.lookup(an.name) == null) {
                    return self.fail(self.spanOfNode(node), error.UnknownSymbol);
                }
                try self.resolveNode(an.value);
            },
            .return_ => |ret| try self.resolveNode(ret.value),
            .call => |call_node| {
                try self.resolveNode(call_node.callee);
                for (call_node.args) |arg| try self.resolveNode(arg);
            },
            .print => |child| try self.resolveNode(child),
            .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne => |kids| {
                try self.resolveNode(&kids[0]);
                try self.resolveNode(&kids[1]);
            },
            .if_ => |if_node| {
                try self.resolveNode(if_node.cond);
                {
                    const mark = self.locals.mark();
                    defer self.locals.restore(mark);
                    try self.resolveNode(if_node.then_);
                }
                if (if_node.else_) |else_node| {
                    const mark = self.locals.mark();
                    defer self.locals.restore(mark);
                    try self.resolveNode(else_node);
                }
            },
            .struct_init => |si| {
                for (si.fields) |field| try self.resolveNode(field.value);
            },
            .field_access => |fa| {
                try self.resolveNode(fa.target);
            },
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
