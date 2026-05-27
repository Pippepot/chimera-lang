const std = @import("std");

pub const AstNode = union(enum) {
    int: i32,
    print: *const AstNode,
    add: *const [2]AstNode,
    sub: *const [2]AstNode,
    mul: *const [2]AstNode,
    div: *const [2]AstNode,
    arg: u32,
};

const InstRef = u32;

const InstPair = struct {
    l: InstRef,
    r: InstRef,
};

const Inst = union(enum) {
    iconst: i32,
    iadd: InstPair,
    isub: InstPair,
    imul: InstPair,
    idiv: InstPair,
    print: InstRef,
    ret: InstRef,
    iarg: u32,
};

fn dumpIr(ir: *const std.ArrayList(Inst), writer: *std.Io.Writer) void {
    for (ir.items, 0..) |inst, i| {
        switch (inst) {
            .iconst => |v| writer.print("%{d} = iconst {d}\n", .{ i, v }) catch return,
            .iadd => |p| writer.print("%{d} = iadd %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .isub => |p| writer.print("%{d} = isub %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .imul => |p| writer.print("%{d} = imul %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .idiv => |p| writer.print("%{d} = idiv %{d}, %{d}\n", .{ i, p.l, p.r }) catch return,
            .print => |v| writer.print("%{d} = print %{d}\n", .{ i, v }) catch return,
            .ret => |v| writer.print("%{d} = ret %{d}\n", .{ i, v }) catch return,
            .iarg => |idx| writer.print("%{d} = iarg %{d}\n", .{ i, idx }) catch return,
        }
    }
}

fn lowerAst(arena: *std.ArrayList(Inst), node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!InstRef {
    switch (node.*) {
        .int => |v| {
            try arena.append(gpa, .{ .iconst = v });
        },
        .print => |child| {
            const val = try lowerAst(arena, child, gpa);
            try arena.append(gpa, .{ .print = val });
        },
        .add => |kids| {
            const l = try lowerAst(arena, &kids[0], gpa);
            const r = try lowerAst(arena, &kids[1], gpa);
            try arena.append(gpa, .{ .iadd = .{ .l = l, .r = r } });
        },
        .sub => |kids| {
            const l = try lowerAst(arena, &kids[0], gpa);
            const r = try lowerAst(arena, &kids[1], gpa);
            try arena.append(gpa, .{ .isub = .{ .l = l, .r = r } });
        },
        .mul => |kids| {
            const l = try lowerAst(arena, &kids[0], gpa);
            const r = try lowerAst(arena, &kids[1], gpa);
            try arena.append(gpa, .{ .imul = .{ .l = l, .r = r } });
        },
        .div => |kids| {
            const l = try lowerAst(arena, &kids[0], gpa);
            const r = try lowerAst(arena, &kids[1], gpa);
            try arena.append(gpa, .{ .idiv = .{ .l = l, .r = r } });
        },
        .arg => |idx| {
            try arena.append(gpa, .{ .iarg = idx });
        },
    }
    return @intCast(arena.items.len - 1);
}

fn reg64(r: usize) []const u8 {
    return switch (r) {
        0 => "rax",
        1 => "rbx",
        2 => "r8",
        3 => "r9",
        4 => "r10",
        5 => "r11",
        6 => "r12",
        7 => "r13",
        8 => "r14",
        9 => "r15",
        else => unreachable,
    };
}

const reg32 = [_][]const u8{ "eax", "ebx", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d" };
const eax_i = 0;
const NUM_REGS = 10;

fn emitIr(ir: *const std.ArrayList(Inst), buf: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!void {
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
    {
        var uc = try gpa.alloc(u32, ir.items.len);
        defer gpa.free(uc);
        @memcpy(uc, use_count);
        var live = try gpa.alloc(bool, ir.items.len);
        defer gpa.free(live);
        @memset(live, false);
        var lc: u32 = 0;
        var peak: u32 = 0;
        for (ir.items, 0..) |inst, i| {
            if (inst != .ret) {
                if (!live[i]) {
                    live[i] = true;
                    lc += 1;
                }
            }
            peak = @max(peak, lc);
            switch (inst) {
                .iadd, .isub, .imul, .idiv => |p| {
                    if (uc[p.l] > 0) {
                        uc[p.l] -= 1;
                        if (uc[p.l] == 0 and live[p.l]) {
                            live[p.l] = false;
                            lc -= 1;
                        }
                    }
                    if (uc[p.r] > 0) {
                        uc[p.r] -= 1;
                        if (uc[p.r] == 0 and live[p.r]) {
                            live[p.r] = false;
                            lc -= 1;
                        }
                    }
                },
                .print, .ret => |v| {
                    if (uc[v] > 0) {
                        uc[v] -= 1;
                        if (uc[v] == 0 and live[v]) {
                            live[v] = false;
                            lc -= 1;
                        }
                    }
                },
                else => {},
            }
            peak = @max(peak, lc);
        }
        const frame_size = if (peak > NUM_REGS) (peak - NUM_REGS) * 8 else @as(u32, 0);
        if (frame_size > 0) {
            try buf.print(gpa, "    sub rsp, {d}\n", .{frame_size});
        }
    }

    // --- Pass 3: register allocation and emission ---
    var locs = try gpa.alloc(?usize, ir.items.len);
    defer gpa.free(locs);
    @memset(locs, null);
    var reg_owner: [NUM_REGS]?u32 = [_]?u32{null} ** NUM_REGS;
    const spill_slots = try gpa.alloc(?u32, ir.items.len);
    defer gpa.free(spill_slots);
    @memset(spill_slots, null);
    var spill_idx: u32 = 0;

    const spillReg = struct {
        fn spill(r: usize, owner: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, locs_: []?usize, buf_: *std.ArrayList(u8), gpa_: std.mem.Allocator) !void {
            const v = owner[r].?;
            if (slots[v] == null) {
                try buf_.print(gpa_, "    mov [rsp+{d}], {s}\n", .{ sidx.*, reg64(r) });
                slots[v] = sidx.*;
                sidx.* += 8;
            }
            locs_[v] = null;
            owner[r] = null;
        }
    }.spill;

    const evict = struct {
        fn e(r: usize, owner: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, locs_: []?usize, uc: []const u32, buf_: *std.ArrayList(u8), gpa_: std.mem.Allocator) !void {
            if (owner[r]) |v| {
                if (uc[v] > 0) {
                    try spillReg(r, owner, slots, sidx, locs_, buf_, gpa_);
                }
                locs_[v] = null;
                owner[r] = null;
            }
        }
    }.e;

    const loadIntoReg = struct {
        fn load(val: u32, r: usize, locs_: []?usize, owner: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, uc: []const u32, iri: []const Inst, buf_: *std.ArrayList(u8), gpa_: std.mem.Allocator) !void {
            if (locs_[val]) |curr| {
                if (curr == r) return;
                try evict(r, owner, slots, sidx, locs_, uc, buf_, gpa_);
                try buf_.print(gpa_, "    mov {s}, {s}\n", .{ reg32[r], reg32[curr] });
                locs_[val] = r;
                owner[curr] = null;
                owner[r] = val;
            } else if (slots[val]) |slot| {
                try evict(r, owner, slots, sidx, locs_, uc, buf_, gpa_);
                try buf_.print(gpa_, "    mov {s}, [rsp+{d}]\n", .{ reg32[r], slot });
                locs_[val] = r;
                owner[r] = val;
            } else {
                const imm = switch (iri[val]) {
                    .iconst => |v| v,
                    else => unreachable,
                };
                try evict(r, owner, slots, sidx, locs_, uc, buf_, gpa_);
                try buf_.print(gpa_, "    mov {s}, {d}\n", .{ reg32[r], imm });
                locs_[val] = r;
                owner[r] = val;
            }
        }
    }.load;

    const ensureAnyReg = struct {
        fn ensure(val: u32, locs_: []?usize, owner: *[NUM_REGS]?u32, slots: []?u32, sidx: *u32, uc: []const u32, iri: []const Inst, buf_: *std.ArrayList(u8), gpa_: std.mem.Allocator) !usize {
            if (locs_[val]) |r| return r;
            var fr: ?usize = null;
            for (owner.*, 0..) |o, ri| {
                if (o == null and ri != eax_i) {
                    fr = ri;
                    break;
                }
            }
            if (fr == null) {
                for (owner.*, 0..) |o, ri| {
                    if (o == null) {
                        fr = ri;
                        break;
                    }
                }
            }
            if (fr == null) {
                var victim: usize = 0;
                var min_uc: u32 = std.math.maxInt(u32);
                for (owner.*, 0..) |o, ri| {
                    if (o) |v| {
                        if (uc[v] < min_uc) {
                            min_uc = uc[v];
                            victim = ri;
                        }
                    }
                }
                try spillReg(victim, owner, slots, sidx, locs_, buf_, gpa_);
                fr = victim;
            }
            const r = fr.?;
            try loadIntoReg(val, r, locs_, owner, slots, sidx, uc, iri, buf_, gpa_);

            return r;
        }
    }.ensure;

    const freeIfDead = struct {
        fn free(val: u32, locs_: []?usize, owner: *[NUM_REGS]?u32, uc: []const u32) void {
            if (uc[val] > 0) return;
            if (locs_[val]) |r| {
                locs_[val] = null;
                owner[r] = null;
            }
        }
    }.free;

    for (ir.items, 0..) |inst, i| {
        switch (inst) {
            .iconst => {},
            .iadd => |p| {
                try loadIntoReg(p.l, eax_i, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                const rhs_imm: ?i32 = switch (ir.items[p.r]) {
                    .iconst => |v| v,
                    else => null,
                };
                if (rhs_imm) |imm| {
                    try buf.print(gpa, "    add eax, {d}\n", .{imm});
                } else {
                    const rhs = try ensureAnyReg(p.r, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    try buf.print(gpa, "    add eax, {s}\n", .{reg32[rhs]});
                }
                use_count[p.l] -= 1;
                freeIfDead(p.l, locs, &reg_owner, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, locs, &reg_owner, use_count);
                reg_owner[eax_i] = @intCast(i);
                locs[i] = eax_i;
            },
            .isub => |p| {
                try loadIntoReg(p.l, eax_i, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                const rhs_imm: ?i32 = switch (ir.items[p.r]) {
                    .iconst => |v| v,
                    else => null,
                };
                if (rhs_imm) |imm| {
                    try buf.print(gpa, "    sub eax, {d}\n", .{imm});
                } else {
                    const rhs = try ensureAnyReg(p.r, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    try buf.print(gpa, "    sub eax, {s}\n", .{reg32[rhs]});
                }
                use_count[p.l] -= 1;
                freeIfDead(p.l, locs, &reg_owner, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, locs, &reg_owner, use_count);
                reg_owner[eax_i] = @intCast(i);
                locs[i] = eax_i;
            },
            .imul => |p| {
                const rhs_imm: ?i32 = switch (ir.items[p.r]) {
                    .iconst => |v| v,
                    else => null,
                };
                if (rhs_imm) |imm| {
                    if (locs[p.l]) |lhs_r| {
                        try buf.print(gpa, "    imul eax, {s}, {d}\n", .{ reg32[lhs_r], imm });
                        reg_owner[lhs_r] = null;
                        locs[p.l] = null;
                    } else {
                        try evict(eax_i, &reg_owner, spill_slots, &spill_idx, locs, use_count, buf, gpa);
                        const lhs_imm: ?i32 = switch (ir.items[p.l]) {
                            .iconst => |v| v,
                            else => null,
                        };
                        if (lhs_imm) |lhs_val| {
                            try buf.print(gpa, "    mov eax, {d}\n    imul eax, {d}\n", .{ lhs_val, imm });
                        } else {
                            const slot = spill_slots[p.l] orelse unreachable;
                            try buf.print(gpa, "    imul eax, [rsp+{d}], {d}\n", .{ slot, imm });
                            spill_slots[p.l] = null;
                        }
                    }
                } else {
                    try loadIntoReg(p.l, eax_i, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    const rhs = try ensureAnyReg(p.r, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                    try buf.print(gpa, "    imul eax, {s}\n", .{reg32[rhs]});
                }
                use_count[p.l] -= 1;
                freeIfDead(p.l, locs, &reg_owner, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, locs, &reg_owner, use_count);
                reg_owner[eax_i] = @intCast(i);
                locs[i] = eax_i;
            },
            .idiv => |p| {
                try loadIntoReg(p.l, eax_i, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                const rhs = try ensureAnyReg(p.r, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                use_count[p.l] -= 1;
                freeIfDead(p.l, locs, &reg_owner, use_count);
                use_count[p.r] -= 1;
                freeIfDead(p.r, locs, &reg_owner, use_count);
                try buf.appendSlice(gpa, "    cdq\n");
                try buf.print(gpa, "    idiv {s}\n", .{reg32[rhs]});
                reg_owner[eax_i] = @intCast(i);
                locs[i] = eax_i;
            },
            .print => |v| {
                try loadIntoReg(v, eax_i, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                use_count[v] -= 1;
                freeIfDead(v, locs, &reg_owner, use_count);
                try buf.appendSlice(gpa, "    call print_int\n");
                reg_owner[eax_i] = @intCast(i);
                locs[i] = eax_i;
            },
            .ret => |v| {
                try loadIntoReg(v, eax_i, locs, &reg_owner, spill_slots, &spill_idx, use_count, ir.items, buf, gpa);
                try buf.appendSlice(gpa, "    mov edi, eax\n    mov eax, 60\n    syscall\n");
            },
            .iarg => |idx| {
                try evict(eax_i, &reg_owner, spill_slots, &spill_idx, locs, use_count, buf, gpa);
                var fr: ?usize = null;
                for (&reg_owner, 0..) |o, ri| {
                    if (o == null and ri != eax_i) {
                        fr = ri;
                        break;
                    }
                }
                if (fr == null) {
                    for (&reg_owner, 0..) |o, ri| {
                        if (o == null) {
                            fr = ri;
                            break;
                        }
                    }
                }
                if (fr == null) {
                    var victim: usize = 0;
                    var min_uc: u32 = std.math.maxInt(u32);
                    for (&reg_owner, 0..) |o, ri| {
                        if (o) |val| {
                            if (use_count[val] < min_uc) {
                                min_uc = use_count[val];
                                victim = ri;
                            }
                        }
                    }
                    try spillReg(victim, &reg_owner, spill_slots, &spill_idx, locs, buf, gpa);
                    fr = victim;
                }
                const r = fr.?;
                try buf.print(gpa, "    mov rdi, [rbp + {d}]\n", .{idx * 8});
                try buf.appendSlice(gpa, "    call atoi\n");
                if (r != eax_i) {
                    try buf.print(gpa, "    mov {s}, eax\n", .{reg32[r]});
                }
                reg_owner[r] = @intCast(i);
                locs[i] = r;
            },
        }
    }
}

fn lower(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!std.ArrayList(Inst) {
    var ir = try std.ArrayList(Inst).initCapacity(gpa, 16);
    errdefer ir.deinit(gpa);
    const result = try lowerAst(&ir, node, gpa);
    try ir.append(gpa, .{ .ret = result });
    return ir;
}

fn compileIr(ir: *const std.ArrayList(Inst), gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
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

pub fn assembleAndLink(io: std.Io, asm_source: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = "x86.asm", .data = asm_source }) catch std.process.exit(1);
    defer cwd.deleteFile(io, "x86.asm") catch {};
    defer cwd.deleteFile(io, "x86.o") catch {};

    var nasm_child = std.process.spawn(io, .{ .argv = &.{ "nasm", "-f", "elf64", "x86.asm", "-o", "x86.o" }, .stderr = .inherit }) catch std.process.exit(1);
    switch (nasm_child.wait(io) catch std.process.exit(1)) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }

    var ld_child = std.process.spawn(io, .{ .argv = &.{ "ld", "x86.o", "-o", "prog" }, .stderr = .inherit }) catch std.process.exit(1);
    switch (ld_child.wait(io) catch std.process.exit(1)) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.exit(1),
    }
}

pub fn runProg(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var argv = std.ArrayList([]const u8).initCapacity(gpa, 1 + args.len) catch std.process.exit(1);
    defer argv.deinit(gpa);
    argv.appendAssumeCapacity("./prog");
    for (args) |a| argv.appendAssumeCapacity(a);
    var child = std.process.spawn(io, .{ .argv = argv.items, .stderr = .inherit }) catch std.process.exit(1);
    switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| return code,
        else => std.process.exit(1),
    }
}

pub fn eval(io: std.Io, node: *const AstNode, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const asm_source = compile(node, gpa) catch std.process.exit(1);
    defer gpa.free(asm_source);
    assembleAndLink(io, asm_source);
    return runProg(io, gpa, args);
}

const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    assembly: bool = false,
};

fn parseDebugFlags(args: std.process.Args) DebugFlags {
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
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var flags = DebugFlags{};
    var prog_args_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer prog_args_list.deinit(gpa);

    {
        var iter = std.process.Args.Iterator.init(init.minimal.args);
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
            } else {
                try prog_args_list.append(gpa, arg);
            }
        }
    }

    const prog_args = prog_args_list.items;

    var arg_node: AstNode = undefined;
    var mkids: [2]AstNode = undefined;
    var akids: [2]AstNode = undefined;
    const root = if (prog_args.len > 0) blk: {
        arg_node = .{ .arg = 1 };
        break :blk AstNode{ .print = &arg_node };
    } else blk: {
        mkids = .{ .{ .int = 2 }, .{ .int = 5 } };
        const mul = AstNode{ .mul = &mkids };
        akids = .{ mul, .{ .int = 3 } };
        const add = AstNode{ .add = &akids };
        break :blk AstNode{ .print = &add };
    };

    if (flags.ast) {
        var wbuf: [1024]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; AST:\n; ");
        dumpAst(&root, &w.interface);
        try w.interface.writeAll("\n\n");
        try w.interface.flush();
    }

    var ir = try lower(&root, gpa);
    defer ir.deinit(gpa);

    if (flags.ssa) {
        var wbuf: [1024]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; SSA IR:\n");
        dumpIr(&ir, &w.interface);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    const asm_source = try compileIr(&ir, gpa);
    defer gpa.free(asm_source);

    if (flags.assembly) {
        var asm_buf = try std.ArrayList(u8).initCapacity(gpa, 256);
        defer asm_buf.deinit(gpa);
        try asm_buf.appendSlice(gpa, "global _start\n_start:\n");
        try emitIr(&ir, &asm_buf, gpa);
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll("; --- asm ---\n");
        try w.interface.writeAll(asm_buf.items);
        try w.interface.writeAll("; --- end asm ---\n");
        try w.interface.flush();
    }

    assembleAndLink(io, asm_source);
    _ = runProg(io, gpa, prog_args);
}
