const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const diagnostics = @import("diagnostics.zig");
const db = @import("db.zig");

pub const UntypedInst = struct {
    idx: ast.NodeIdx,
    tag: ast.Tag,
    data0: u32,
    data1: u32,
};

pub const ComptimeSymbol = struct {
    name: ast.IdentIdx,
    decl: ast.NodeIdx,
};

pub const AstgenIr = struct {
    insts: std.ArrayList(UntypedInst),
    symbols: std.ArrayList(ComptimeSymbol),

    pub fn init(gpa: std.mem.Allocator) !AstgenIr {
        return .{
            .insts = try std.ArrayList(UntypedInst).initCapacity(gpa, 64),
            .symbols = try std.ArrayList(ComptimeSymbol).initCapacity(gpa, 8),
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
        self.symbols.deinit(gpa);
    }
};

pub const AstgenReport = struct {
    ir: ?AstgenIr,
    diagnostic: ?diagnostics.Diagnostic,
};

pub const AstgenMemo = db.Memo(AstgenIr);

pub fn astgenReport(parsed: *const parser.ParsedAst, gpa: std.mem.Allocator) error{OutOfMemory}!AstgenReport {
    var ir = try AstgenIr.init(gpa);
    errdefer ir.deinit(gpa);

    const nodes = parsed.ast.nodes;
    try ir.insts.ensureUnusedCapacity(gpa, nodes.len);
    for (nodes, 0..) |node, i| {
        ir.insts.appendAssumeCapacity(.{
            .idx = @intCast(i),
            .tag = node.tag,
            .data0 = node.data0,
            .data1 = node.data1,
        });
    }

    for (parsed.ast.decls) |decl_idx| {
        const decl = parsed.ast.nodes[decl_idx];
        switch (decl.tag) {
            .comptime_fn, .comptime_struct, .comptime_value_decl => {
                try ir.symbols.append(gpa, .{
                    .name = decl.data0,
                    .decl = decl_idx,
                });
            },
            else => {},
        }
    }

    return .{
        .ir = ir,
        .diagnostic = null,
    };
}

pub fn computeAstgen(
    resolve_memo: *const resolver.ResolveMemo,
    parse_memo: *const parser.ParseMemo,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!AstgenMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, resolve_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var ir_value: ?AstgenIr = null;
    if (resolve_memo.value != null) {
        const parsed = if (parse_memo.value) |*p| p else return db.makeMemo(AstgenIr, null, diagnostics_list);
        const report = try astgenReport(parsed, gpa);
        if (report.diagnostic) |diag| {
            try diagnostics_list.append(gpa, diag);
        }
        ir_value = report.ir;
    }

    return db.makeMemo(AstgenIr, ir_value, diagnostics_list);
}
