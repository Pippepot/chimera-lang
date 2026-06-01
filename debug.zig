const std = @import("std");
const ast = @import("ast.zig");
const ir_mod = @import("ir.zig");

const Program = ir_mod.Program;
const InstPair = ir_mod.InstPair;

fn branchRef(writer: *std.Io.Writer, b: ir_mod.Branch) void {
    if (b.arg) |arg|
        writer.print("L{d}(%{d})", .{ b.target, arg }) catch return
    else
        writer.print("L{d}", .{b.target}) catch return;
}

fn printBranch(writer: *std.Io.Writer, b: ir_mod.Branch) void {
    writer.writeAll("  br ") catch return;
    branchRef(writer, b);
    writer.writeAll("\n") catch return;
}

fn printPbr(writer: *std.Io.Writer, p: @FieldType(ir_mod.Terminator, "pbr")) void {
    writer.print("  pbr {s} %{d}, %{d}, ", .{ @tagName(p.pred.op), p.pred.pair.l, p.pred.pair.r }) catch return;
    branchRef(writer, p.then_branch);
    writer.writeAll(", ") catch return;
    branchRef(writer, p.else_branch);
    writer.writeAll("\n") catch return;
}

fn printBinInst(writer: *std.Io.Writer, id: u32, name: []const u8, p: InstPair) void {
    writer.print("  %{d} = {s} %{d}, %{d}\n", .{ id, name, p.l, p.r }) catch return;
}

fn printCallCommon(writer: *std.Io.Writer, id: u32, callee_prefix: u8, callee: u32, argc: u8, args: *const [ir_mod.MaxCallArgs]ir_mod.ValueRef) void {
    writer.print("  %{d} = call {c}{d}(", .{ id, callee_prefix, callee }) catch return;
    var idx: usize = 0;
    while (idx < argc) : (idx += 1) {
        if (idx > 0) writer.writeAll(", ") catch return;
        writer.print("%{d}", .{args[idx]}) catch return;
    }
    writer.writeAll(")\n") catch return;
}

fn dumpIr(program: *const Program, writer: *std.Io.Writer) void {
    for (program.functions.items) |func| {
        writer.print("fn {s} (id={d})\n", .{ program.symbolFor(func.name), func.id }) catch return;
        for (func.blocks.items) |blk| {
            if (blk.param) |param| writer.print("L{d}(%{d}):\n", .{ blk.id, param }) catch return else writer.print("L{d}:\n", .{blk.id}) catch return;
            for (blk.insts.items) |vinst| {
                switch (vinst.op) {
                    .iconst => |v| writer.print("  %{d} = iconst {d}\n", .{ vinst.id, v }) catch return,
                    .fconst => |v| writer.print("  %{d} = fconst {d}\n", .{ vinst.id, v }) catch return,
                    .fn_addr => |fn_id| writer.print("  %{d} = fn_addr @{d}\n", .{ vinst.id, fn_id }) catch return,
                    .call => |c| printCallCommon(writer, vinst.id, '%', c.callee, c.argc, &c.args),
                    .direct_call => |d| printCallCommon(writer, vinst.id, '@', d.callee, d.argc, &d.args),
                    .addi => |p| printBinInst(writer, vinst.id, "addi", p),
                    .addf => |p| printBinInst(writer, vinst.id, "addf", p),
                    .subi => |p| printBinInst(writer, vinst.id, "subi", p),
                    .subf => |p| printBinInst(writer, vinst.id, "subf", p),
                    .muli => |p| printBinInst(writer, vinst.id, "muli", p),
                    .mulf => |p| printBinInst(writer, vinst.id, "mulf", p),
                    .divi => |p| printBinInst(writer, vinst.id, "divi", p),
                    .divf => |p| printBinInst(writer, vinst.id, "divf", p),
                    .printi => |v| writer.print("  %{d} = printi %{d}\n", .{ vinst.id, v }) catch return,
                    .printf => |v| writer.print("  %{d} = printf %{d}\n", .{ vinst.id, v }) catch return,
                    .printb => |v| writer.print("  %{d} = printb %{d}\n", .{ vinst.id, v }) catch return,
                    .argi => |idx_val| writer.print("  %{d} = argi %{d}\n", .{ vinst.id, idx_val }) catch return,
                    .store => |p| printBinInst(writer, vinst.id, "store", p),
                    .field_load => |fl| writer.print("  %{d} = field_load %{d}, {d}\n", .{ vinst.id, fl.base, fl.field_index }) catch return,
                    .slot_addr => |slot| writer.print("  %{d} = slot_addr %{d}\n", .{ vinst.id, slot }) catch return,
                    .load_ptr => |load| writer.print("  %{d} = load_ptr %{d}, {d}\n", .{ vinst.id, load.ptr, load.offset_slots }) catch return,
                    .store_ptr => |st| writer.print("  %{d} = store_ptr %{d}, %{d}, {d}\n", .{ vinst.id, st.ptr, st.src, st.offset_slots }) catch return,
                }
            }
            const terminator = blk.terminator orelse return;
            switch (terminator) {
                .ret => |v| writer.print("  ret %{d}\n", .{v}) catch return,
                .br => |b| printBranch(writer, b),
                .pbr => |p| printPbr(writer, p),
            }
        }
        writer.writeAll("\n") catch return;
    }
}

pub const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    timing: bool = false,
    query: bool = false,
    x86: bool = false,
};

pub fn parseDebugFlags(args: std.process.Args) DebugFlags {
    var flags = DebugFlags{};
    var iter = std.process.Args.Iterator.init(args);
    defer iter.deinit();
    _ = iter.next();
    while (iter.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--debug=")) continue;
        var rest = arg["--debug=".len..];
        while (rest.len > 0) {
            const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            const item = rest[0..comma];
            if (std.mem.eql(u8, item, "ast")) flags.ast = true;
            if (std.mem.eql(u8, item, "ssa")) flags.ssa = true;
            if (std.mem.eql(u8, item, "timing")) flags.timing = true;
            if (std.mem.eql(u8, item, "query")) flags.query = true;
            if (std.mem.eql(u8, item, "asm")) flags.x86 = true;
            if (comma == rest.len) break;
            rest = rest[comma + 1 ..];
        }
    }
    return flags;
}

fn appendPrefix(prefix: []const u8, suffix: []const u8, buf: *[256]u8) ?[]const u8 {
    const need = prefix.len + suffix.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..need], suffix);
    return buf[0..need];
}

fn writeAstLabel(writer: *std.Io.Writer, a: *const ast.Ast, idx: ast.NodeIdx) void {
    const node = a.nodes[idx];
    switch (node.tag) {
        .int_lit => writer.print("int {d}", .{@as(i32, @bitCast(node.data0))}) catch return,
        .float_lit => writer.print("float {d}", .{@as(f32, @bitCast(node.data0))}) catch return,
        .var_ref => writer.print("var {s}", .{a.identOf(node.data0)}) catch return,
        .const_decl, .var_decl => writer.print("{s} {s}", .{ @tagName(node.tag), a.identOf(node.data0) }) catch return,
        .assign => writer.print("assign {s}", .{a.identOf(node.data0)}) catch return,
        .arg => writer.print("arg {d}", .{node.data0}) catch return,
        .bool_lit => writer.print("bool {s}", .{if (node.data0 != 0) "true" else "false"}) catch return,
        .comptime_value_decl => writer.print("comptime_decl {s}", .{a.identOf(node.data0)}) catch return,
        .struct_init => {
            const type_expr = a.structInitTypeExpr(idx);
            if (a.nodes[type_expr].tag == .var_ref) {
                writer.print("struct_init {s}", .{a.identOf(a.nodes[type_expr].data0)}) catch return;
            } else {
                writer.writeAll("struct_init") catch return;
            }
        },
        .type_name, .type_func, .type_variant, .comptime_fn, .comptime_struct => {},
        else => writer.print("{s}", .{@tagName(node.tag)}) catch return,
    }
}

fn dumpAstNode(a: *const ast.Ast, idx: ast.NodeIdx, writer: *std.Io.Writer, prefix: []const u8, is_last: bool, is_root: bool) void {
    if (!is_root) writer.print("{s}{s}", .{ prefix, if (is_last) "└─" else "├─" }) catch return;
    writeAstLabel(writer, a, idx);
    writer.writeAll("\n") catch return;

    var next_prefix_buf: [256]u8 = undefined;
    const next_suffix = if (is_root) "" else if (is_last) "  " else "│ ";
    const next_prefix = appendPrefix(prefix, next_suffix, &next_prefix_buf) orelse return;

    switch (a.nodes[idx].tag) {
        .block => {
            const items = a.blockItems(idx);
            const last = last_visible: {
                var last_idx: ?u32 = null;
                for (items, 0..) |item, i| {
                    const tag = a.nodes[item].tag;
                    if (tag != .comptime_fn and tag != .comptime_struct) last_idx = @intCast(i);
                }
                if (last_idx) |li| break :last_visible li else return;
            };
            for (items, 0..) |item, i| {
                const tag = a.nodes[item].tag;
                if (tag == .comptime_fn or tag == .comptime_struct) continue;
                dumpAstNode(a, item, writer, next_prefix, i == last, false);
            }
        },
        .call => {
            const callee = a.nodes[idx].data0;
            const args = a.callArgs(idx);
            dumpAstNode(a, callee, writer, next_prefix, args.len == 0, false);
            for (args, 0..) |arg, i| {
                dumpAstNode(a, arg, writer, next_prefix, i + 1 == args.len, false);
            }
        },
        .if_stmt => {
            const id = a.ifData(idx);
            const has_else = id.else_ != std.math.maxInt(ast.NodeIdx);
            dumpAstNode(a, id.cond, writer, next_prefix, false, false);
            dumpAstNode(a, id.then_, writer, next_prefix, !has_else, false);
            if (has_else) dumpAstNode(a, id.else_, writer, next_prefix, true, false);
        },
        .struct_init => {
            const type_expr = a.structInitTypeExpr(idx);
            const is_named = a.nodes[type_expr].tag == .var_ref;
            if (!is_named) dumpAstNode(a, type_expr, writer, next_prefix, false, false);
            const fields = a.structInitFields(idx);
            for (fields, 0..) |field, i| {
                const is_field_last = i + 1 == fields.len;
                writer.print("{s}{s}", .{ next_prefix, if (is_field_last and is_named) "└─" else "├─" }) catch return;
                writer.print("{s}: ", .{a.identOf(field.name)}) catch return;
                dumpAstNode(a, field.value, writer, next_prefix, is_field_last, true);
            }
        },
        .struct_expr => {
            const fields = a.structExprFields(idx);
            for (fields, 0..) |field, i| {
                writer.print("{s}{s}", .{ next_prefix, if (i + 1 == fields.len) "└─" else "├─" }) catch return;
                writer.print("{s}: ", .{a.identOf(field.name)}) catch return;
                dumpTypeNode(a, field.ty, writer);
                writer.writeAll("\n") catch return;
            }
        },
        .is, .as => {
            dumpAstNode(a, a.isLhs(idx), writer, next_prefix, false, false);
            writer.print("{s}└─type ", .{next_prefix}) catch return;
            dumpTypeNode(a, a.isRhsType(idx), writer);
            writer.writeAll("\n") catch return;
        },
        .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or", .field_assign => {
            dumpAstNode(a, a.nodes[idx].data0, writer, next_prefix, false, false);
            dumpAstNode(a, a.nodes[idx].data1, writer, next_prefix, true, false);
        },
        .const_decl, .var_decl => dumpAstNode(a, a.varDeclValue(idx), writer, next_prefix, true, false),
        .comptime_value_decl => dumpAstNode(a, a.comptimeValueDeclValue(idx), writer, next_prefix, true, false),
        .return_stmt, .print_stmt, .field_access, .move_expr, .sizeof_expr,
        .comptime_expr, .@"not", .query_op => dumpAstNode(a, a.nodes[idx].data0, writer, next_prefix, true, false),
        .assign => dumpAstNode(a, a.nodes[idx].data1, writer, next_prefix, true, false),
        .type_union => {
            const members = a.typeUnionMembers(idx);
            for (members, 0..) |member, i| {
                dumpAstNode(a, member, writer, next_prefix, i + 1 == members.len, false);
            }
        },
        .int_lit, .float_lit, .var_ref, .arg, .bool_lit, .unit_lit, .none_lit,
        .type_name, .type_func, .type_variant, .comptime_fn, .comptime_struct => {},
    }
}

fn dumpTypeNode(a: *const ast.Ast, type_idx: ast.TypeIdx, writer: *std.Io.Writer) void {
    switch (a.nodes[type_idx].tag) {
        .type_name => writer.print("{s}", .{a.identOf(a.nodes[type_idx].data0)}) catch return,
        .type_func => {
            writer.writeAll("func(") catch return;
            const params = a.funcTypeParams(type_idx);
            for (params, 0..) |param, i| {
                if (i > 0) writer.writeAll(", ") catch return;
                dumpTypeNode(a, param, writer);
            }
            writer.writeAll(") ") catch return;
            dumpTypeNode(a, a.funcTypeRet(type_idx), writer);
        },
        .type_variant => {
            const members = a.variantTypeMembers(type_idx);
            for (members, 0..) |member, i| {
                if (i > 0) writer.writeAll(" | ") catch return;
                dumpTypeNode(a, member, writer);
            }
        },
        else => {},
    }
}

fn dumpProgram(a: *const ast.Ast, writer: *std.Io.Writer) void {
    for (a.decls) |decl_idx| {
        switch (a.nodes[decl_idx].tag) {
            .comptime_fn => {
                const name = a.identOf(a.nodes[decl_idx].data0);
                writer.print("comptime {s} = func(", .{name}) catch return;
                const params = a.fnParams(decl_idx);
                for (params, 0..) |param, i| {
                    if (i > 0) writer.writeAll(", ") catch return;
                    if (a.fnParamIsComptime(decl_idx, @intCast(i))) {
                        writer.writeAll("comptime ") catch return;
                    }
                    writer.print("{s}: ", .{a.identOf(param.name)}) catch return;
                    dumpTypeNode(a, param.ty, writer);
                }
                writer.writeAll(") ") catch return;
                const ret_ty = a.fnRetType(decl_idx);
                if (ret_ty == ast.FN_NO_RET_TYPE) {
                    writer.writeAll("<inferred>") catch return;
                } else {
                    dumpTypeNode(a, ret_ty, writer);
                }
                writer.writeAll("\n") catch return;
                dumpAstNode(a, a.fnBody(decl_idx), writer, "  ", true, true);
                writer.writeAll("\n") catch return;
            },
            .comptime_struct => {
                const name = a.identOf(a.nodes[decl_idx].data0);
                writer.print("comptime {s} = struct\n", .{name}) catch return;
                for (a.structFields(decl_idx)) |field| {
                    writer.print("  {s}: ", .{a.identOf(field.name)}) catch return;
                    dumpTypeNode(a, field.ty, writer);
                    writer.writeAll("\n") catch return;
                }
                writer.writeAll("\n") catch return;
            },
            .comptime_value_decl => {
                const name = a.identOf(a.nodes[decl_idx].data0);
                writer.print("comptime {s} = ...\n\n", .{name}) catch return;
            },
            else => {},
        }
    }

    if (a.entry != std.math.maxInt(ast.NodeIdx)) {
        writer.writeAll("program entry\n") catch return;
        dumpAstNode(a, a.entry, writer, "  ", true, true);
        writer.writeAll("\n") catch return;
    }
}

pub fn dumpDebugInfo(
    io: std.Io,
    flags: DebugFlags,
    ast_ast: ?*const ast.Ast,
    ir: ?*const Program,
    asm_text: ?[]const u8,
    gpa: std.mem.Allocator,
) !void {
    _ = gpa;
    var wbuf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &wbuf);
    const wi = &w.interface;

    if (flags.ast) if (ast_ast) |aa| {
        try wi.writeAll("; AST:\n");
        dumpProgram(aa, wi);
        try wi.writeAll("\n");
    };
    if (flags.ssa) if (ir) |irim| {
        try wi.writeAll("; SSA IR:\n");
        dumpIr(irim, wi);
        try wi.writeAll("\n");
    };
    if (flags.x86) if (asm_text) |at| {
        try wi.writeAll("; x86 assembly:\n");
        try wi.writeAll(at);
        try wi.writeAll("\n");
    };
    try wi.flush();
}
