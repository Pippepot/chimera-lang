const std = @import("std");
const ast = @import("ast.zig");
const typecheck = @import("typecheck.zig");
const db = @import("db.zig");

pub const MonoFunction = struct {
    source_id: u32,
    decl: *const ast.FuncDecl,
    ty: *const typecheck.FuncType,
    has_explicit_return: bool,
};

pub const MonoProgram = struct {
    module: *const ast.Module,
    functions: std.ArrayList(MonoFunction),
    entry_function: u32,

    pub fn init(gpa: std.mem.Allocator, module: *const ast.Module, entry_function: u32) !MonoProgram {
        return .{
            .module = module,
            .functions = try std.ArrayList(MonoFunction).initCapacity(gpa, 8),
            .entry_function = entry_function,
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.functions.deinit(gpa);
    }
};

pub const MonomorphizeMemo = db.Memo(MonoProgram);

pub fn computeMonomorphize(type_memo: *const typecheck.TypeMemo, gpa: std.mem.Allocator) error{OutOfMemory}!MonomorphizeMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, type_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var mono_value: ?MonoProgram = null;
    if (type_memo.value) |*typed| {
        var mono = try MonoProgram.init(gpa, typed.module, typed.entry_function);
        errdefer mono.deinit(gpa);

        var fn_id: u32 = 0;
        while (fn_id < typed.functions.len) : (fn_id += 1) {
            const info = typed.functions[fn_id];
            try mono.functions.append(gpa, .{
                .source_id = fn_id,
                .decl = info.decl,
                .ty = info.ty,
                .has_explicit_return = info.has_explicit_return,
            });
        }

        mono_value = mono;
    }

    return db.makeMemo(MonoProgram, mono_value, diagnostics_list);
}
