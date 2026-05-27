const std = @import("std");
const x86 = @import("x86.zig");
const codegen = @import("codegen.zig");
const AstNode = x86.AstNode;
const Inst = codegen.Inst;
const emitIr = codegen.emitIr;

fn dumpIr(ir: *const std.ArrayList(Inst), writer: *std.Io.Writer) void {
    for (ir.items, 0..) |inst, i| {
        switch (inst) {
            .iconst => |v| writer.print("%{d} = iconst {d}\n", .{ i, v }) catch return,
            .iadd => |p| writer.print("%{d} = iadd %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .isub => |p| writer.print("%{d} = isub %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .imul => |p| writer.print("%{d} = imul %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .idiv => |p| writer.print("%{d} = idiv %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .ilt => |p| writer.print("%{d} = ilt %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .igt => |p| writer.print("%{d} = igt %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .ile => |p| writer.print("%{d} = ile %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .ige => |p| writer.print("%{d} = ige %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .ieq => |p| writer.print("%{d} = ieq %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .ine => |p| writer.print("%{d} = ine %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .print => |v| writer.print("%{d} = print %{d}\n", .{ i, v }) catch return,
            .ret => |v| writer.print("%{d} = ret %{d}\n", .{ i, v }) catch return,
            .iarg => |idx| writer.print("%{d} = iarg %{d}\n", .{ i, idx }) catch return,
            .ijz => |j| writer.print("%{d} = ijz %{d}, L{d}\n", .{ i, j.cond, j.label }) catch return,
            .ijmp => |label| writer.print("%{d} = ijmp L{d}\n", .{ i, label }) catch return,
            .ilabel => |label| writer.print("%{d} = ilabel L{d}\n", .{ i, label }) catch return,
            .itoeax => |v| writer.print("%{d} = itoeax %{d}\n", .{ i, v }) catch return,
            .iphi => writer.print("%{d} = iphi eax\n", .{i}) catch return,
        }
    }
}

pub const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    assembly: bool = false,
};

pub fn parseDebugFlags(args: std.process.Args) DebugFlags {
    var flags = DebugFlags{};
    var iter = std.process.Args.Iterator.init(args);
    defer iter.deinit();
    _ = iter.next();
    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug=")) {
            var rest = arg["--debug=".len..];
            while (rest.len > 0) {
                const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
                const item = rest[0..comma];
                if (std.mem.eql(u8, item, "ast")) flags.ast = true;
                if (std.mem.eql(u8, item, "ssa")) flags.ssa = true;
                if (std.mem.eql(u8, item, "asm")) flags.assembly = true;
                if (comma == rest.len) break;
                rest = rest[comma + 1 ..];
            }
        }
    }
    return flags;
}

fn dumpAst(node: *const AstNode, writer: *std.Io.Writer) void {
    switch (node.*) {
        .int => |v| writer.print("{d}", .{v}) catch return,
        .print => |child| {
            writer.writeAll("(print ") catch return;
            dumpAst(child, writer);
            writer.writeAll(")") catch return;
        },
        .add => |kids| {
            writer.writeAll("(+ ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .sub => |kids| {
            writer.writeAll("(- ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .mul => |kids| {
            writer.writeAll("(* ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .div => |kids| {
            writer.writeAll("(/ ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .arg => |idx| writer.print("arg({d})", .{idx}) catch return,
        .lt => |kids| {
            writer.writeAll("(< ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .gt => |kids| {
            writer.writeAll("(> ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .le => |kids| {
            writer.writeAll("(<= ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .ge => |kids| {
            writer.writeAll("(>= ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .eq => |kids| {
            writer.writeAll("(== ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .ne => |kids| {
            writer.writeAll("(!= ") catch return;
            dumpAst(&kids[0], writer);
            writer.writeAll(" ") catch return;
            dumpAst(&kids[1], writer);
            writer.writeAll(")") catch return;
        },
        .if_ => |data| {
            writer.writeAll("(if ") catch return;
            dumpAst(data.cond, writer);
            writer.writeAll(" ") catch return;
            dumpAst(data.then_, writer);
            if (data.else_) |else_node| {
                writer.writeAll(" ") catch return;
                dumpAst(else_node, writer);
            }
            writer.writeAll(")") catch return;
        },
    }
}

pub fn dumpDebugInfo(io: std.Io, flags: DebugFlags, root: *const AstNode, ir: ?*const std.ArrayList(Inst), gpa: std.mem.Allocator) !void {
    if (flags.ast) {
        var wbuf: [1024]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; AST:\n; ");
        dumpAst(root, &w.interface);
        try w.interface.writeAll("\n\n");
        try w.interface.flush();
    }
    if (ir) |irim| {
        if (flags.ssa) {
            var wbuf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &wbuf);
            try w.interface.writeAll("; SSA IR:\n");
            dumpIr(irim, &w.interface);
            try w.interface.writeAll("\n");
            try w.interface.flush();
        }
        if (flags.assembly) {
            var asm_buf = try std.ArrayList(u8).initCapacity(gpa, 256);
            defer asm_buf.deinit(gpa);
            try asm_buf.appendSlice(gpa, "global _start\n_start:\n");
            try emitIr(irim, &asm_buf, gpa);
            var wbuf: [4096]u8 = undefined;
            var w = std.Io.File.stdout().writer(io, &wbuf);
            try w.interface.writeAll("; --- asm ---\n");
            try w.interface.writeAll(asm_buf.items);
            try w.interface.writeAll("; --- end asm ---\n");
            try w.interface.flush();
        }
    }
}
