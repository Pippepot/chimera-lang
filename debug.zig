const std = @import("std");
const ast = @import("ast.zig");
const ir_mod = @import("ir.zig");

const AstNode = ast.AstNode;
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
        writer.print("fn {s} (id={d})\n", .{ func.name, func.id }) catch return;
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
                    .argi => |idx| writer.print("  %{d} = argi %{d}\n", .{ vinst.id, idx }) catch return,
                    .store => |p| printBinInst(writer, vinst.id, "store", p),
                    .field_load => |fl| writer.print("  %{d} = field_load %{d}, {d}\n", .{ vinst.id, fl.base, fl.field_index }) catch return,
                    .string_lit => |id| writer.print("  %{d} = string_lit ${d}\n", .{ vinst.id, id }) catch return,
                    .prints => |v| writer.print("  %{d} = prints %{d}\n", .{ vinst.id, v }) catch return,
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

fn writeAstLabel(writer: *std.Io.Writer, node: *const AstNode) void {
    switch (node.*) {
        .int => |v| writer.print("int {d}", .{v}) catch return,
        .float => |v| writer.print("float {d}", .{v}) catch return,
        .var_ref => |name| writer.print("var {s}", .{name}) catch return,
        .block => writer.writeAll("block") catch return,
        .const_ => |data| writer.print("const {s}", .{data.name}) catch return,
        .var_ => |data| writer.print("var {s}", .{data.name}) catch return,
        .assign => |data| writer.print("assign {s}", .{data.name}) catch return,
        .return_ => writer.writeAll("return") catch return,
        .call => writer.writeAll("call") catch return,
        .print => writer.writeAll("print") catch return,
        .add => writer.writeAll("add") catch return,
        .sub => writer.writeAll("sub") catch return,
        .mul => writer.writeAll("mul") catch return,
        .div => writer.writeAll("div") catch return,
        .arg => |idx| writer.print("arg {d}", .{idx}) catch return,
        .lt => writer.writeAll("lt") catch return,
        .gt => writer.writeAll("gt") catch return,
        .le => writer.writeAll("le") catch return,
        .ge => writer.writeAll("ge") catch return,
        .eq => writer.writeAll("eq") catch return,
        .ne => writer.writeAll("ne") catch return,
        .if_ => writer.writeAll("if") catch return,
        .struct_init => writer.writeAll("struct_init") catch return,
        .field_access => writer.writeAll("field_access") catch return,
        .bool => |v| writer.print("bool {s}", .{if (v) "true" else "false"}) catch return,
        .unit => writer.writeAll("unit") catch return,
        .string => |s| writer.print("string \"{s}\"", .{s}) catch return,
    }
}

fn dumpAstNode(node: *const AstNode, writer: *std.Io.Writer, prefix: []const u8, is_last: bool, is_root: bool) void {
    if (!is_root) writer.print("{s}{s}", .{ prefix, if (is_last) "└─" else "├─" }) catch return;
    writeAstLabel(writer, node);
    writer.writeAll("\n") catch return;

    var next_prefix_buf: [256]u8 = undefined;
    const next_suffix = if (is_root) "" else if (is_last) "  " else "│ ";
    const next_prefix = appendPrefix(prefix, next_suffix, &next_prefix_buf) orelse return;

    switch (node.*) {
        .block => |block| {
            for (block.items, 0..) |item, idx| {
                dumpAstNode(item, writer, next_prefix, idx + 1 == block.items.len, false);
            }
        },
        .const_ => |data| dumpAstNode(data.value, writer, next_prefix, true, false),
        .var_ => |data| dumpAstNode(data.value, writer, next_prefix, true, false),
        .assign => |data| dumpAstNode(data.value, writer, next_prefix, true, false),
        .return_ => |data| dumpAstNode(data.value, writer, next_prefix, true, false),
        .call => |call_node| {
            if (call_node.args.len == 0) {
                dumpAstNode(call_node.callee, writer, next_prefix, true, false);
            } else {
                dumpAstNode(call_node.callee, writer, next_prefix, false, false);
                for (call_node.args, 0..) |arg, idx| {
                    dumpAstNode(arg, writer, next_prefix, idx + 1 == call_node.args.len, false);
                }
            }
        },
        .print => |child| dumpAstNode(child, writer, next_prefix, true, false),
        .add, .sub, .mul, .div, .lt, .gt, .le, .ge, .eq, .ne => |kids| {
            dumpAstNode(&kids[0], writer, next_prefix, false, false);
            dumpAstNode(&kids[1], writer, next_prefix, true, false);
        },
        .if_ => |data| {
            if (data.else_ != null) {
                dumpAstNode(data.cond, writer, next_prefix, false, false);
                dumpAstNode(data.then_, writer, next_prefix, false, false);
                dumpAstNode(data.else_.?, writer, next_prefix, true, false);
            } else {
                dumpAstNode(data.cond, writer, next_prefix, false, false);
                dumpAstNode(data.then_, writer, next_prefix, true, false);
            }
        },
        .field_access => |fa| {
            dumpAstNode(fa.target, writer, next_prefix, true, false);
        },
        .struct_init => |si| {
            _ = si;
        },
        .int, .float, .var_ref, .arg, .bool, .unit, .string => {},
    }
}

fn dumpTypeNode(ty: *const ast.TypeNode, writer: *std.Io.Writer) void {
    switch (ty.*) {
        .name => |name| writer.print("{s}", .{name}) catch return,
        .func => |func_ty| {
            writer.writeAll("func(") catch return;
            for (func_ty.params, 0..) |param, idx| {
                if (idx > 0) writer.writeAll(", ") catch return;
                dumpTypeNode(param, writer);
            }
            writer.writeAll(") ") catch return;
            dumpTypeNode(func_ty.ret, writer);
        },
    }
}

fn dumpModule(module: *const ast.Module, writer: *std.Io.Writer) void {
    for (module.decls) |decl| {
        switch (decl.*) {
            .comptime_func => |func_decl| {
                writer.print("comptime {s} = func(", .{func_decl.name}) catch return;
                for (func_decl.params, 0..) |param, idx| {
                    if (idx > 0) writer.writeAll(", ") catch return;
                    writer.print("{s}: ", .{param.name}) catch return;
                    dumpTypeNode(param.ty, writer);
                }
                writer.writeAll(") ") catch return;
                dumpTypeNode(func_decl.ret_type, writer);
                writer.writeAll("\n") catch return;
                dumpAstNode(func_decl.body, writer, "  ", true, true);
                writer.writeAll("\n") catch return;
            },
            .comptime_struct => |struct_decl| {
                writer.print("comptime {s} = struct\n", .{struct_decl.name}) catch return;
                for (struct_decl.fields) |field| {
                    writer.print("  {s}: ", .{field.name}) catch return;
                    dumpTypeNode(field.ty, writer);
                    writer.writeAll("\n") catch return;
                }
                writer.writeAll("\n") catch return;
            },
        }
    }

    if (module.entry.* != .unit) {
        writer.writeAll("entry\n") catch return;
        dumpAstNode(module.entry, writer, "  ", true, true);
        writer.writeAll("\n") catch return;
    }
}

pub fn dumpDebugInfo(
    io: std.Io,
    flags: DebugFlags,
    module: ?*const ast.Module,
    ir: ?*const Program,
    gpa: std.mem.Allocator,
) !void {
    _ = gpa;
    if (flags.ast and module != null) {
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; AST:\n");
        dumpModule(module.?, &w.interface);
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
}
