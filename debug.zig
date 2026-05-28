const std = @import("std");
const x86 = @import("main.zig");
const ir_mod = @import("ir.zig");
const AstNode = x86.AstNode;
const InstPair = ir_mod.InstPair;
const Program = ir_mod.Program;

fn printBinInst(writer: *std.Io.Writer, id: u32, name: []const u8, p: InstPair) void {
    writer.print("  %{d} = {s} %{d}, %{d}\n", .{ id, name, p.l, p.r }) catch return;
}

fn printBranch(writer: *std.Io.Writer, b: ir_mod.Branch) void {
    if (b.arg) |arg| writer.print("  br L{d}(%{d})\n", .{ b.target, arg }) catch return else writer.print("  br L{d}\n", .{b.target}) catch return;
}

fn printCbr(writer: *std.Io.Writer, c: @FieldType(ir_mod.Terminator, "cbr")) void {
    if (c.then_branch.arg) |then_arg| {
        if (c.else_branch.arg) |else_arg| writer.print("  cbr %{d}, L{d}(%{d}), L{d}(%{d})\n", .{ c.cond, c.then_branch.target, then_arg, c.else_branch.target, else_arg }) catch return else writer.print("  cbr %{d}, L{d}(%{d}), L{d}\n", .{ c.cond, c.then_branch.target, then_arg, c.else_branch.target }) catch return;
    } else {
        if (c.else_branch.arg) |else_arg| writer.print("  cbr %{d}, L{d}, L{d}(%{d})\n", .{ c.cond, c.then_branch.target, c.else_branch.target, else_arg }) catch return else writer.print("  cbr %{d}, L{d}, L{d}\n", .{ c.cond, c.then_branch.target, c.else_branch.target }) catch return;
    }
}

fn dumpIr(program: *const Program, writer: *std.Io.Writer) void {
    for (program.blocks.items) |blk| {
        if (blk.param) |param| writer.print("L{d}(%{d}):\n", .{ blk.id, param }) catch return else writer.print("L{d}:\n", .{blk.id}) catch return;
        for (blk.insts.items) |vinst| {
            switch (vinst.op) {
                .iconst => |v| writer.print("  %{d} = iconst {d}\n", .{ vinst.id, v }) catch return,
                .iadd => |p| printBinInst(writer, vinst.id, "iadd", p),
                .isub => |p| printBinInst(writer, vinst.id, "isub", p),
                .imul => |p| printBinInst(writer, vinst.id, "imul", p),
                .idiv => |p| printBinInst(writer, vinst.id, "idiv", p),
                .ilt => |p| printBinInst(writer, vinst.id, "ilt", p),
                .igt => |p| printBinInst(writer, vinst.id, "igt", p),
                .ile => |p| printBinInst(writer, vinst.id, "ile", p),
                .ige => |p| printBinInst(writer, vinst.id, "ige", p),
                .ieq => |p| printBinInst(writer, vinst.id, "ieq", p),
                .ine => |p| printBinInst(writer, vinst.id, "ine", p),
                .print => |v| writer.print("  %{d} = print %{d}\n", .{ vinst.id, v }) catch return,
                .iarg => |idx| writer.print("  %{d} = iarg %{d}\n", .{ vinst.id, idx }) catch return,
            }
        }
        const terminator = blk.terminator orelse return;
        switch (terminator) {
            .ret => |v| writer.print("  ret %{d}\n", .{v}) catch return,
            .br => |b| printBranch(writer, b),
            .cbr => |c| printCbr(writer, c),
        }
    }
}

pub const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    assembly: bool = false,
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
            if (std.mem.eql(u8, item, "ast")) flags.ast = true else if (std.mem.eql(u8, item, "ssa")) flags.ssa = true else if (std.mem.eql(u8, item, "asm")) flags.assembly = true else if (std.mem.eql(u8, item, "timing")) flags.timing = true else if (std.mem.eql(u8, item, "query")) flags.query = true;
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
        .int, .arg => {},
    }
}

fn dumpAstTree(node: *const AstNode, writer: *std.Io.Writer) void {
    dumpAstNode(node, writer, "", true, true);
}

pub fn dumpDebugInfo(io: std.Io, flags: DebugFlags, root: *const AstNode, ir: ?*const Program, gpa: std.mem.Allocator) !void {
    _ = gpa;
    if (flags.ast) {
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; AST:\n");
        dumpAstTree(root, &w.interface);
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
        if (flags.assembly) {
            var wbuf: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &wbuf);
            try w.interface.writeAll("; --- asm ---\n");
            try w.interface.writeAll("; binary-only backend enabled; text asm emitter removed\n");
            try w.interface.writeAll("; --- end asm ---\n");
            try w.interface.flush();
        }
    }
}
