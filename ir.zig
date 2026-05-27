const std = @import("std");
const x86 = @import("x86.zig");
const AstNode = x86.AstNode;

pub const InstRef = u32;

pub const InstPair = struct {
    l: InstRef,
    r: InstRef,
};

pub const Inst = union(enum) {
    iconst: i32,
    iadd: InstPair,
    isub: InstPair,
    imul: InstPair,
    idiv: InstPair,
    print: InstRef,
    ret: InstRef,
    iarg: u32,
    ilt: InstPair,
    igt: InstPair,
    ile: InstPair,
    ige: InstPair,
    ieq: InstPair,
    ine: InstPair,
    ijz: struct { cond: InstRef, label: u32 },
    ijmp: u32,
    ilabel: u32,
    itoeax: InstRef,
    iphi,
};

fn lowerBinop(arena: *std.ArrayList(Inst), kids: *const [2]AstNode, gpa: std.mem.Allocator, label_counter: *u32) error{OutOfMemory}!InstPair {
    const l = try lowerAst(arena, &kids[0], gpa, label_counter);
    const r = try lowerAst(arena, &kids[1], gpa, label_counter);
    return .{ .l = l, .r = r };
}

fn lowerAst(arena: *std.ArrayList(Inst), node: *const AstNode, gpa: std.mem.Allocator, label_counter: *u32) error{OutOfMemory}!InstRef {
    switch (node.*) {
        .int => |v| try arena.append(gpa, .{ .iconst = v }),
        .print => |child| {
            const val = try lowerAst(arena, child, gpa, label_counter);
            try arena.append(gpa, .{ .print = val });
        },
        .add => |kids| try arena.append(gpa, .{ .iadd = try lowerBinop(arena, kids, gpa, label_counter) }),
        .sub => |kids| try arena.append(gpa, .{ .isub = try lowerBinop(arena, kids, gpa, label_counter) }),
        .mul => |kids| try arena.append(gpa, .{ .imul = try lowerBinop(arena, kids, gpa, label_counter) }),
        .div => |kids| try arena.append(gpa, .{ .idiv = try lowerBinop(arena, kids, gpa, label_counter) }),
        .arg => |idx| try arena.append(gpa, .{ .iarg = idx }),
        .lt => |kids| try arena.append(gpa, .{ .ilt = try lowerBinop(arena, kids, gpa, label_counter) }),
        .gt => |kids| try arena.append(gpa, .{ .igt = try lowerBinop(arena, kids, gpa, label_counter) }),
        .le => |kids| try arena.append(gpa, .{ .ile = try lowerBinop(arena, kids, gpa, label_counter) }),
        .ge => |kids| try arena.append(gpa, .{ .ige = try lowerBinop(arena, kids, gpa, label_counter) }),
        .eq => |kids| try arena.append(gpa, .{ .ieq = try lowerBinop(arena, kids, gpa, label_counter) }),
        .ne => |kids| try arena.append(gpa, .{ .ine = try lowerBinop(arena, kids, gpa, label_counter) }),
        .if_ => |data| {
            const cond_ref = try lowerAst(arena, data.cond, gpa, label_counter);
            const else_label = label_counter.*;
            label_counter.* += 1;
            const end_label = label_counter.*;
            label_counter.* += 1;
            try arena.append(gpa, .{ .ijz = .{ .cond = cond_ref, .label = else_label } });
            const then_ref = try lowerAst(arena, data.then_, gpa, label_counter);
            try arena.append(gpa, .{ .itoeax = then_ref });
            try arena.append(gpa, .{ .ijmp = end_label });
            try arena.append(gpa, .{ .ilabel = else_label });
            const else_ref = if (data.else_) |else_node| try lowerAst(arena, else_node, gpa, label_counter) else blk: {
                try arena.append(gpa, .{ .iconst = 0 });
                break :blk @as(InstRef, @intCast(arena.items.len - 1));
            };
            try arena.append(gpa, .{ .itoeax = else_ref });
            try arena.append(gpa, .{ .ilabel = end_label });
            try arena.append(gpa, .iphi);
            return @intCast(arena.items.len - 1);
        },
    }
    return @intCast(arena.items.len - 1);
}

pub fn lower(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!std.ArrayList(Inst) {
    var ir = try std.ArrayList(Inst).initCapacity(gpa, 16);
    errdefer ir.deinit(gpa);
    var label_counter: u32 = 0;
    const result = try lowerAst(&ir, node, gpa, &label_counter);
    try ir.append(gpa, .{ .ret = result });
    return ir;
}
