const std = @import("std");
const ast = @import("ast.zig");
const ir_mod = @import("ir.zig");

const Program = ir_mod.Program;
const InstPair = ir_mod.InstPair;

fn printBinInst(writer: *std.Io.Writer, id: u32, name: []const u8, p: InstPair) void {
    writer.print("  %{d} = {s} %{d}, %{d}\n", .{ id, name, p.l, p.r }) catch return;
}

fn printCallInst(writer: *std.Io.Writer, id: u32, call_info: ir_mod.CallInst) void {
    writer.print("  %{d} = call %{d}(", .{ id, call_info.callee }) catch return;
    var idx: usize = 0;
    while (idx < call_info.argc) : (idx += 1) {
        if (idx > 0) writer.writeAll(", ") catch return;
        writer.print("%{d}", .{call_info.args[idx]}) catch return;
    }
    writer.writeAll(")\n") catch return;
}

fn printBranch(writer: *std.Io.Writer, b: ir_mod.Branch) void {
    if (b.arg) |arg| writer.print("  br L{d}(%{d})\n", .{ b.target, arg }) catch return else writer.print("  br L{d}\n", .{b.target}) catch return;
}

fn printPbr(writer: *std.Io.Writer, p: @FieldType(ir_mod.Terminator, "pbr")) void {
    const op_name = @tagName(p.pred.op);
    if (p.then_branch.arg) |then_arg| {
        if (p.else_branch.arg) |else_arg| {
            writer.print(
                "  pbr {s} %{d}, %{d}, L{d}(%{d}), L{d}(%{d})\n",
                .{ op_name, p.pred.pair.l, p.pred.pair.r, p.then_branch.target, then_arg, p.else_branch.target, else_arg },
            ) catch return;
        } else {
            writer.print(
                "  pbr {s} %{d}, %{d}, L{d}(%{d}), L{d}\n",
                .{ op_name, p.pred.pair.l, p.pred.pair.r, p.then_branch.target, then_arg, p.else_branch.target },
            ) catch return;
        }
    } else {
        if (p.else_branch.arg) |else_arg| {
            writer.print(
                "  pbr {s} %{d}, %{d}, L{d}, L{d}(%{d})\n",
                .{ op_name, p.pred.pair.l, p.pred.pair.r, p.then_branch.target, p.else_branch.target, else_arg },
            ) catch return;
        } else {
            writer.print(
                "  pbr {s} %{d}, %{d}, L{d}, L{d}\n",
                .{ op_name, p.pred.pair.l, p.pred.pair.r, p.then_branch.target, p.else_branch.target },
            ) catch return;
        }
    }
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
                    .call => |call_info| printCallInst(writer, vinst.id, call_info),
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
        .call, .return_stmt, .print_stmt, .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne, .is, .as, .@"and", .@"or", .if_stmt, .block, .field_access, .comptime_expr, .struct_expr, .type_union, .unit_lit => writer.print("{s}", .{@tagName(node.tag)}) catch return,
        .arg => writer.print("arg {d}", .{node.data0}) catch return,
        .struct_init => {
            const type_expr = a.structInitTypeExpr(idx);
            if (a.nodes[type_expr].tag == .var_ref) {
                writer.print("struct_init {s}", .{a.identOf(a.nodes[type_expr].data0)}) catch return;
            } else {
                writer.writeAll("struct_init") catch return;
            }
        },
        .bool_lit => writer.print("bool {s}", .{if (node.data0 != 0) "true" else "false"}) catch return,
        .comptime_value_decl => writer.print("comptime_decl {s}", .{a.identOf(node.data0)}) catch return,
        .type_name, .type_func, .type_variant, .comptime_fn, .comptime_struct => {},
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
            var has_visible = false;
            for (items) |item| {
                if (a.nodes[item].tag != .comptime_fn and a.nodes[item].tag != .comptime_struct) {
                    has_visible = true;
                    break;
                }
            }
            if (!has_visible) return;

            const last_visible = last_visible: {
                var last: u32 = 0;
                var i: u32 = 0;
                while (i < items.len) : (i += 1) {
                    if (a.nodes[items[i]].tag != .comptime_fn and a.nodes[items[i]].tag != .comptime_struct) {
                        last = i;
                    }
                }
                break :last_visible last;
            };
            for (items, 0..) |item, i| {
                if (a.nodes[item].tag == .comptime_fn or a.nodes[item].tag == .comptime_struct) continue;
                dumpAstNode(a, item, writer, next_prefix, i == last_visible, false);
            }
        },
        .const_decl => dumpAstNode(a, a.varDeclValue(idx), writer, next_prefix, true, false),
        .var_decl => dumpAstNode(a, a.varDeclValue(idx), writer, next_prefix, true, false),
        .assign => dumpAstNode(a, a.nodes[idx].data1, writer, next_prefix, true, false),
        .return_stmt => dumpAstNode(a, a.nodes[idx].data0, writer, next_prefix, true, false),
        .call => {
            const callee = a.nodes[idx].data0;
            const args = a.callArgs(idx);
            if (args.len == 0) {
                dumpAstNode(a, callee, writer, next_prefix, true, false);
            } else {
                dumpAstNode(a, callee, writer, next_prefix, false, false);
                for (args, 0..) |arg, i| {
                    dumpAstNode(a, arg, writer, next_prefix, i + 1 == args.len, false);
                }
            }
        },
        .print_stmt => dumpAstNode(a, a.nodes[idx].data0, writer, next_prefix, true, false),
        .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne, .@"and", .@"or" => {
            dumpAstNode(a, a.nodes[idx].data0, writer, next_prefix, false, false);
            dumpAstNode(a, a.nodes[idx].data1, writer, next_prefix, true, false);
        },
        .is => {
            dumpAstNode(a, a.isLhs(idx), writer, next_prefix, false, false);
            writer.print("{s}└─type ", .{next_prefix}) catch return;
            dumpTypeNode(a, a.isRhsType(idx), writer);
            writer.writeAll("\n") catch return;
        },
        .as => {
            dumpAstNode(a, a.asLhs(idx), writer, next_prefix, false, false);
            writer.print("{s}└─type ", .{next_prefix}) catch return;
            dumpTypeNode(a, a.asRhsType(idx), writer);
            writer.writeAll("\n") catch return;
        },
        .if_stmt => {
            const id = a.ifData(idx);
            if (id.else_ != std.math.maxInt(ast.NodeIdx)) {
                dumpAstNode(a, id.cond, writer, next_prefix, false, false);
                dumpAstNode(a, id.then_, writer, next_prefix, false, false);
                dumpAstNode(a, id.else_, writer, next_prefix, true, false);
            } else {
                dumpAstNode(a, id.cond, writer, next_prefix, false, false);
                dumpAstNode(a, id.then_, writer, next_prefix, true, false);
            }
        },
        .field_access => dumpAstNode(a, a.nodes[idx].data0, writer, next_prefix, true, false),
        .comptime_expr => dumpAstNode(a, a.comptimeExprBody(idx), writer, next_prefix, true, false),
        .comptime_value_decl => dumpAstNode(a, a.comptimeValueDeclValue(idx), writer, next_prefix, true, false),
        .struct_init => {
            const type_expr = a.structInitTypeExpr(idx);
            if (a.nodes[type_expr].tag != .var_ref) {
                dumpAstNode(a, type_expr, writer, next_prefix, false, false);
            }
            const fields = a.structInitFields(idx);
            for (fields, 0..) |field, i| {
                writer.print("{s}{s}", .{ next_prefix, if (i + 1 == fields.len and a.nodes[type_expr].tag == .var_ref) "└─" else "├─" }) catch return;
                writer.print("{s}: ", .{a.identOf(field.name)}) catch return;
                dumpAstNode(a, field.value, writer, next_prefix, i + 1 == fields.len, true);
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
        .type_union => {
            const members = a.typeUnionMembers(idx);
            for (members, 0..) |member, i| {
                dumpAstNode(a, member, writer, next_prefix, i + 1 == members.len, false);
            }
        },
        .int_lit, .float_lit, .var_ref, .arg, .bool_lit, .unit_lit => {},
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
                dumpTypeNode(a, a.fnRetType(decl_idx), writer);
                writer.writeAll("\n") catch return;
                dumpAstNode(a, a.fnBody(decl_idx), writer, "  ", true, true);
                writer.writeAll("\n") catch return;
            },
            .comptime_struct => {
                const name = a.identOf(a.nodes[decl_idx].data0);
                writer.print("comptime {s} = struct\n", .{name}) catch return;
                const fields = a.structFields(decl_idx);
                for (fields) |field| {
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
    if (flags.ast and ast_ast != null) {
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; AST:\n");
        dumpProgram(ast_ast.?, &w.interface);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }
    if (ir) |irim| {
        if (flags.ssa) {
            var wbuf: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &wbuf);
            try w.interface.writeAll("; SSA IR:\n");
            dumpIr(irim, &w.interface);
            try w.interface.writeAll("\n");
            try w.interface.flush();
        }
    }
    if (flags.x86 and asm_text != null) {
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; x86 assembly:\n");
        try w.interface.writeAll(asm_text.?);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }
}
