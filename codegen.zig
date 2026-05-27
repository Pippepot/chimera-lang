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
};

fn lowerBinop(arena: *std.ArrayList(Inst), kids: *const [2]AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!InstPair {
    const l = try lowerAst(arena, &kids[0], gpa);
    const r = try lowerAst(arena, &kids[1], gpa);
    return .{ .l = l, .r = r };
}

fn lowerAst(arena: *std.ArrayList(Inst), node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!InstRef {
    switch (node.*) {
        .int => |v| try arena.append(gpa, .{ .iconst = v }),
        .print => |child| {
            const val = try lowerAst(arena, child, gpa);
            try arena.append(gpa, .{ .print = val });
        },
        .add => |kids| try arena.append(gpa, .{ .iadd = try lowerBinop(arena, kids, gpa) }),
        .sub => |kids| try arena.append(gpa, .{ .isub = try lowerBinop(arena, kids, gpa) }),
        .mul => |kids| try arena.append(gpa, .{ .imul = try lowerBinop(arena, kids, gpa) }),
        .div => |kids| try arena.append(gpa, .{ .idiv = try lowerBinop(arena, kids, gpa) }),
        .arg => |idx| try arena.append(gpa, .{ .iarg = idx }),
    }
    return @intCast(arena.items.len - 1);
}

pub fn lower(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!std.ArrayList(Inst) {
    var ir = try std.ArrayList(Inst).initCapacity(gpa, 16);
    errdefer ir.deinit(gpa);
    const result = try lowerAst(&ir, node, gpa);
    try ir.append(gpa, .{ .ret = result });
    return ir;
}

const reg64 = [_][]const u8{ "rax", "rbx", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
const reg32 = [_][]const u8{ "eax", "ebx", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d" };
const eax_i = 0;
const NUM_REGS = 10;

fn consumeUse(rem_uses: []u32, live: []bool, live_count: *u32, ref: u32) void {
    std.debug.assert(rem_uses[ref] > 0);
    rem_uses[ref] -= 1;
    if (rem_uses[ref] == 0 and live[ref]) {
        live[ref] = false;
        live_count.* -= 1;
    }
}

fn spillReg(r: usize, reg_to_val: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, val_to_reg: []?u8, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const v = reg_to_val[r].?;
    if (slots[v] == null) {
        try buf.print(gpa, "    mov [rsp+{d}], {s}\n", .{ sidx.*, reg64[r] });
        slots[v] = sidx.*;
        sidx.* += 8;
    }
    val_to_reg[v] = null;
    reg_to_val[r] = null;
}

fn evict(r: usize, reg_to_val: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, val_to_reg: []?u8, uc: []const u32, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    if (reg_to_val[r]) |v| {
        if (uc[v] > 0) try spillReg(r, reg_to_val, slots, sidx, val_to_reg, buf, gpa);
        val_to_reg[v] = null;
        reg_to_val[r] = null;
    }
}

fn loadIntoReg(val: u32, r: usize, val_to_reg: []?u8, reg_to_val: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, uc: []const u32, iri: []const Inst, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    if (val_to_reg[val]) |curr| {
        const creg = @as(usize, curr);
        if (creg == r) return;
        try evict(r, reg_to_val, slots, sidx, val_to_reg, uc, buf, gpa);
        try buf.print(gpa, "    mov {s}, {s}\n", .{ reg32[r], reg32[creg] });
        val_to_reg[val] = @intCast(r);
        reg_to_val[creg] = null;
        reg_to_val[r] = val;
    } else if (slots[val]) |slot| {
        try evict(r, reg_to_val, slots, sidx, val_to_reg, uc, buf, gpa);
        try buf.print(gpa, "    mov {s}, [rsp+{d}]\n", .{ reg32[r], slot });
        val_to_reg[val] = @intCast(r);
        reg_to_val[r] = val;
    } else {
        const imm = switch (iri[val]) {
            .iconst => |v| v,
            else => unreachable,
        };
        try evict(r, reg_to_val, slots, sidx, val_to_reg, uc, buf, gpa);
        try buf.print(gpa, "    mov {s}, {d}\n", .{ reg32[r], imm });
        val_to_reg[val] = @intCast(r);
        reg_to_val[r] = val;
    }
}

fn ensureAnyReg(val: u32, val_to_reg: []?u8, reg_to_val: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, uc: []const u32, iri: []const Inst, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !u8 {
    if (val_to_reg[val]) |r| return r;
    var fr: ?u8 = null;
    for (reg_to_val.*, 0..) |o, ri| {
        if (o == null and ri != eax_i) {
            fr = @intCast(ri);
            break;
        }
    }
    if (fr == null) {
        for (reg_to_val.*, 0..) |o, ri| {
            if (o == null) {
                fr = @intCast(ri);
                break;
            }
        }
    }
    if (fr == null) {
        var victim: u8 = 0;
        var min_uc: u32 = std.math.maxInt(u32);
        for (reg_to_val.*, 0..) |o, ri| {
            if (o) |v| {
                if (uc[v] < min_uc) {
                    min_uc = uc[v];
                    victim = @intCast(ri);
                }
            }
        }
        try spillReg(victim, reg_to_val, slots, sidx, val_to_reg, buf, gpa);
        fr = victim;
    }
    const r = fr.?;
    try loadIntoReg(val, @as(usize, r), val_to_reg, reg_to_val, slots, sidx, uc, iri, buf, gpa);

    return r;
}

fn freeIfDead(val: u32, val_to_reg: []?u8, reg_to_val: *[NUM_REGS]?u32, uc: []const u32) void {
    if (uc[val] > 0) return;
    if (val_to_reg[val]) |r| {
        val_to_reg[val] = null;
        reg_to_val[@as(usize, r)] = null;
    }
}

pub fn emitIr(ir: *const std.ArrayList(Inst), buf: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    // --- Pass 1: use counts ---
    var use_count = try gpa.alloc(u32, ir.items.len);
    defer gpa.free(use_count);
    @memset(use_count, 0);
    for (ir.items) |inst| {
        switch (inst) {
            .iadd, .isub, .imul, .idiv => |p| {
                use_count[p.l] += 1;
                use_count[p.r] += 1;
            },
            .print, .ret => |v| use_count[v] += 1,
            else => {},
        }
    }

    // --- Pass 2: peak live values for stack frame ---
    const rem_uses = try gpa.alloc(u32, ir.items.len);
    defer gpa.free(rem_uses);
    @memcpy(rem_uses, use_count);
    var live = try gpa.alloc(bool, ir.items.len);
    defer gpa.free(live);
    @memset(live, false);
    var live_count: u32 = 0;
    var peak: u32 = 0;
    for (ir.items, 0..) |inst, i| {
        if (inst != .ret and !live[i]) {
            live[i] = true;
            live_count += 1;
        }
        peak = @max(peak, live_count);
        switch (inst) {
            .iadd, .isub, .imul, .idiv => |p| {
                consumeUse(rem_uses, live, &live_count, p.l);
                consumeUse(rem_uses, live, &live_count, p.r);
            },
            .print, .ret => |v| consumeUse(rem_uses, live, &live_count, v),
            else => {},
        }
    }
    const frame_size = if (peak > NUM_REGS) (peak - NUM_REGS) * 8 else @as(u32, 0);
    if (frame_size > 0) try buf.print(gpa, "    sub rsp, {d}\n", .{frame_size});

    // --- Pass 3: register allocation and emission ---
    var val_to_reg = try gpa.alloc(?u8, ir.items.len);
    defer gpa.free(val_to_reg);
    @memset(val_to_reg, null);
    var reg_to_val: [NUM_REGS]?u32 = [_]?u32{null} ** NUM_REGS;
    const spill_slots = try gpa.alloc(?u32, ir.items.len);
    defer gpa.free(spill_slots);
    @memset(spill_slots, null);
    var spill_idx: u32 = 0;

    for (ir.items, 0..) |inst, i| {
        switch (inst) {
            .iconst => {},
            .iadd => |p| {
                try loadIntoReg(p.l, eax_i, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                const rhs_imm: ?i32 = switch (ir.items[p.r]) {
                    .iconst => |v| v,
                    else => null,
                };
                if (rhs_imm) |imm| try buf.print(gpa, "    add eax, {d}\n", .{imm})
                else {
                    const rhs = try ensureAnyReg(p.r, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    try buf.print(gpa, "    add eax, {s}\n", .{reg32[@as(usize, rhs)]});
                }
                use_count[p.l] -= 1;
                freeIfDead(p.l, val_to_reg, &reg_to_val, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, val_to_reg, &reg_to_val, use_count);
                reg_to_val[eax_i] = @intCast(i);
                val_to_reg[i] = @intCast(eax_i);
            },
            .isub => |p| {
                try loadIntoReg(p.l, eax_i, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                const rhs_imm: ?i32 = switch (ir.items[p.r]) {
                    .iconst => |v| v,
                    else => null,
                };
                if (rhs_imm) |imm| try buf.print(gpa, "    sub eax, {d}\n", .{imm})
                else {
                    const rhs = try ensureAnyReg(p.r, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    try buf.print(gpa, "    sub eax, {s}\n", .{reg32[@as(usize, rhs)]});
                }
                use_count[p.l] -= 1;
                freeIfDead(p.l, val_to_reg, &reg_to_val, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, val_to_reg, &reg_to_val, use_count);
                reg_to_val[eax_i] = @intCast(i);
                val_to_reg[i] = @intCast(eax_i);
            },
            .imul => |p| {
                const rhs_imm: ?i32 = switch (ir.items[p.r]) {
                    .iconst => |v| v,
                    else => null,
                };
                if (rhs_imm) |imm| {
                    if (val_to_reg[p.l]) |lhs_r| {
                        const lhs_reg = @as(usize, lhs_r);
                        try buf.print(gpa, "    imul eax, {s}, {d}\n", .{ reg32[lhs_reg], imm });
                        reg_to_val[lhs_reg] = null;
                        val_to_reg[p.l] = null;
                    } else {
                        try evict(eax_i, &reg_to_val, spill_slots, &spill_idx, val_to_reg, use_count, buf, gpa);
                        const lhs_imm: ?i32 = switch (ir.items[p.l]) {
                            .iconst => |v| v,
                            else => null,
                        };
                        if (lhs_imm) |lhs_val| try buf.print(gpa, "    mov eax, {d}\n    imul eax, {d}\n", .{ lhs_val, imm })
                        else {
                            const slot = spill_slots[p.l] orelse unreachable;
                            try buf.print(gpa, "    imul eax, [rsp+{d}], {d}\n", .{ slot, imm });
                            spill_slots[p.l] = null;
                        }
                    }
                } else {
                    try loadIntoReg(p.l, eax_i, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    const rhs = try ensureAnyReg(p.r, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    try buf.print(gpa, "    imul eax, {s}\n", .{reg32[@as(usize, rhs)]});
                }
                use_count[p.l] -= 1;
                freeIfDead(p.l, val_to_reg, &reg_to_val, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, val_to_reg, &reg_to_val, use_count);
                reg_to_val[eax_i] = @intCast(i);
                val_to_reg[i] = @intCast(eax_i);
            },
            .idiv => |p| {
                try loadIntoReg(p.l, eax_i, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                const rhs = try ensureAnyReg(p.r, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                use_count[p.l] -= 1;
                freeIfDead(p.l, val_to_reg, &reg_to_val, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, val_to_reg, &reg_to_val, use_count);
                try buf.appendSlice(gpa, "    cdq\n");
                try buf.print(gpa, "    idiv {s}\n", .{reg32[@as(usize, rhs)]});
                reg_to_val[eax_i] = @intCast(i);
                val_to_reg[i] = @intCast(eax_i);
            },
            .print => |v| {
                try loadIntoReg(v, eax_i, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                use_count[v] -= 1;
                freeIfDead(v, val_to_reg, &reg_to_val, use_count);
                try buf.appendSlice(gpa, "    call print_int\n");
                reg_to_val[eax_i] = @intCast(i);
                val_to_reg[i] = @intCast(eax_i);
            },
            .ret => |v| {
                try loadIntoReg(v, eax_i, val_to_reg, &reg_to_val, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                try buf.appendSlice(gpa, "    xor edi, edi\n    mov eax, 60\n    syscall\n");
            },
            .iarg => |idx| {
                try evict(eax_i, &reg_to_val, spill_slots, &spill_idx, val_to_reg, use_count, buf, gpa);
                var fr: ?u8 = null;
                for (&reg_to_val, 0..) |o, ri| {
                    if (o == null and ri != eax_i) {
                        fr = @intCast(ri);
                        break;
                    }
                }
                if (fr == null) {
                    for (&reg_to_val, 0..) |o, ri| {
                        if (o == null) {
                            fr = @intCast(ri);
                            break;
                        }
                    }
                }
                if (fr == null) {
                    var victim: u8 = 0;
                    var min_uc: u32 = std.math.maxInt(u32);
                    for (&reg_to_val, 0..) |o, ri| {
                        if (o) |val| {
                            if (use_count[val] < min_uc) {
                                min_uc = use_count[val];
                                victim = @intCast(ri);
                            }
                        }
                    }
                    try spillReg(victim, &reg_to_val, spill_slots, &spill_idx, val_to_reg, buf, gpa);
                    fr = victim;
                }
                const r = fr.?;
                try buf.print(gpa, "    mov rdi, [rbp + {d}]\n", .{idx * 8});
                try buf.appendSlice(gpa, "    call atoi\n");
                if (@as(usize, r) != eax_i) try buf.print(gpa, "    mov {s}, eax\n", .{reg32[@as(usize, r)]});
                reg_to_val[@as(usize, r)] = @intCast(i);
                val_to_reg[i] = r;
            },
        }
    }
}

pub fn compileIr(ir: *const std.ArrayList(Inst), gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 256);
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "global _start\n_start:\n");
    try buf.appendSlice(gpa, "    lea rbp, [rsp+8]\n");
    try emitIr(ir, &buf, gpa);
    try buf.appendSlice(gpa, @embedFile("print.asm"));
    return buf.toOwnedSlice(gpa);
}

pub fn compile(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var ir = try lower(node, gpa);
    defer ir.deinit(gpa);
    return compileIr(&ir, gpa);
}
