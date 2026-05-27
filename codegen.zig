const std = @import("std");
const ir_mod = @import("ir.zig");
const x86 = @import("x86.zig");
const AstNode = x86.AstNode;

pub const InstRef = ir_mod.InstRef;
pub const InstPair = ir_mod.InstPair;
pub const Inst = ir_mod.Inst;
pub const lower = ir_mod.lower;

const reg64 = [_][]const u8{ "rax", "rbx", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
const reg32 = [_][]const u8{ "eax", "ebx", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d" };
const eax_i = 0;
const NUM_REGS = 10;

fn hasValue(inst: Inst) bool {
    return switch (inst) {
        .ret, .ijz, .ijmp, .ilabel, .itoeax => false,
        else => true,
    };
}

fn computeUseCounts(ir: *const std.ArrayList(Inst), gpa: std.mem.Allocator) error{OutOfMemory}![]u32 {
    var use_count = try gpa.alloc(u32, ir.items.len);
    @memset(use_count, 0);
    for (ir.items) |inst| {
        switch (inst) {
            .iadd, .isub, .imul, .idiv, .ilt, .igt, .ile, .ige, .ieq, .ine => |p| {
                use_count[p.l] += 1;
                use_count[p.r] += 1;
            },
            .print, .ret => |v| use_count[v] += 1,
            .ijz => |j| use_count[j.cond] += 1,
            .itoeax => |v| use_count[v] += 1,
            else => {},
        }
    }
    return use_count;
}

fn computeFrameSize(ir: *const std.ArrayList(Inst), use_count: []u32, gpa: std.mem.Allocator) u32 {
    const rem_uses = gpa.alloc(u32, ir.items.len) catch return 0;
    defer gpa.free(rem_uses);
    @memcpy(rem_uses, use_count);
    const live = gpa.alloc(bool, ir.items.len) catch return 0;
    defer gpa.free(live);
    @memset(live, false);
    var live_count: u32 = 0;
    var peak: u32 = 0;
    for (ir.items, 0..) |inst, i| {
        if (hasValue(inst) and !live[i]) {
            live[i] = true;
            live_count += 1;
        }
        peak = @max(peak, live_count);
        const consume = struct {
            fn c(rem: []u32, lv: []bool, lc: *u32, ref: u32) void {
                std.debug.assert(rem[ref] > 0);
                rem[ref] -= 1;
                if (rem[ref] == 0 and lv[ref]) {
                    lv[ref] = false;
                    lc.* -= 1;
                }
            }
        }.c;
        switch (inst) {
            .iadd, .isub, .imul, .idiv, .ilt, .igt, .ile, .ige, .ieq, .ine => |p| {
                consume(rem_uses, live, &live_count, p.l);
                consume(rem_uses, live, &live_count, p.r);
            },
            .print, .ret => |v| consume(rem_uses, live, &live_count, v),
            .ijz => |j| consume(rem_uses, live, &live_count, j.cond),
            .itoeax => |v| consume(rem_uses, live, &live_count, v),
            else => {},
        }
    }
    return if (peak > NUM_REGS) (peak - NUM_REGS) * 8 else 0;
}

const Emitter = struct {
    iri: []const Inst,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    val_to_reg: []?usize,
    reg_to_val: [NUM_REGS]?u32,
    spill_slots: []?u32,
    spill_idx: u32,
    use_count: []u32,

    fn loadImm(self: *@This(), ref: u32) ?i32 {
        return switch (self.iri[ref]) {
            .iconst => |v| v,
            else => null,
        };
    }

    fn spillReg(self: *@This(), r: usize) !void {
        const v = self.reg_to_val[r].?;
        if (self.spill_slots[v] == null) {
            try self.buf.print(self.gpa, "    mov [rsp+{d}], {s}\n", .{ self.spill_idx, reg64[r] });
            self.spill_slots[v] = self.spill_idx;
            self.spill_idx += 8;
        }
        self.val_to_reg[v] = null;
        self.reg_to_val[r] = null;
    }

    fn evict(self: *@This(), r: usize) !void {
        if (self.reg_to_val[r]) |v| {
            if (self.use_count[v] > 0) try self.spillReg(r);
            self.val_to_reg[v] = null;
            self.reg_to_val[r] = null;
        }
    }

    fn findFreeReg(self: *@This()) !usize {
        var victim: usize = 0;
        var min_uc: u32 = std.math.maxInt(u32);
        for (self.reg_to_val, 0..) |o, ri| {
            if (o) |v| {
                if (self.use_count[v] < min_uc) {
                    min_uc = self.use_count[v];
                    victim = ri;
                }
            } else {
                return ri;
            }
        }
        try self.spillReg(victim);
        return victim;
    }

    fn loadIntoReg(self: *@This(), val: u32, r: usize) !void {
        if (self.val_to_reg[val]) |curr| {
            if (curr == r) return;
            try self.evict(r);
            try self.buf.print(self.gpa, "    mov {s}, {s}\n", .{ reg32[r], reg32[curr] });
            self.val_to_reg[val] = r;
            self.reg_to_val[curr] = null;
            self.reg_to_val[r] = val;
        } else if (self.spill_slots[val]) |slot| {
            try self.evict(r);
            try self.buf.print(self.gpa, "    mov {s}, [rsp+{d}]\n", .{ reg32[r], slot });
            self.val_to_reg[val] = r;
            self.reg_to_val[r] = val;
        } else {
            const imm = switch (self.iri[val]) {
                .iconst => |v| v,
                else => unreachable,
            };
            try self.evict(r);
            try self.buf.print(self.gpa, "    mov {s}, {d}\n", .{ reg32[r], imm });
            self.val_to_reg[val] = r;
            self.reg_to_val[r] = val;
        }
    }

    fn ensureAnyReg(self: *@This(), val: u32) !usize {
        if (self.val_to_reg[val]) |r| return r;
        const r = try self.findFreeReg();
        try self.loadIntoReg(val, r);
        return r;
    }

    fn freeIfDead(self: *@This(), val: u32) void {
        if (self.use_count[val] > 0) return;
        if (self.val_to_reg[val]) |r| {
            self.val_to_reg[val] = null;
            self.reg_to_val[r] = null;
        }
    }

    fn freeOperands(self: *@This(), p: InstPair) void {
        self.use_count[p.l] -= 1;
        self.freeIfDead(p.l);
        self.use_count[p.r] -= 1;
        self.freeIfDead(p.r);
    }

    fn emitAddSub(self: *@This(), mnemonic: []const u8, p: InstPair, i: usize) !void {
        try self.loadIntoReg(p.l, eax_i);
        if (self.loadImm(p.r)) |imm| try self.buf.print(self.gpa, "    {s} eax, {d}\n", .{ mnemonic, imm }) else {
            const rhs = try self.ensureAnyReg(p.r);
            try self.buf.print(self.gpa, "    {s} eax, {s}\n", .{ mnemonic, reg32[rhs] });
        }
        self.freeOperands(p);
        self.assignResult(i);
    }

    fn emitImul(self: *@This(), p: InstPair, i: usize) !void {
        if (self.loadImm(p.r)) |imm| {
            if (self.val_to_reg[p.l]) |lhs_r| {
                // x86 three-operand imul: dest, src, imm — no eax constraint needed
                try self.buf.print(self.gpa, "    imul eax, {s}, {d}\n", .{ reg32[lhs_r], imm });
                self.reg_to_val[lhs_r] = null;
                self.val_to_reg[p.l] = null;
            } else {
                try self.evict(eax_i);
                if (self.loadImm(p.l)) |lhs_val| {
                    try self.buf.print(self.gpa, "    mov eax, {d}\n    imul eax, {d}\n", .{ lhs_val, imm });
                } else {
                    // imul can multiply from memory directly: imul eax, [rsp+slot], imm
                    const slot = self.spill_slots[p.l] orelse unreachable;
                    try self.buf.print(self.gpa, "    imul eax, [rsp+{d}], {d}\n", .{ slot, imm });
                    self.spill_slots[p.l] = null;
                }
            }
        } else {
            // Register rhs — same two-operand form as add/sub
            try self.loadIntoReg(p.l, eax_i);
            const rhs = try self.ensureAnyReg(p.r);
            try self.buf.print(self.gpa, "    imul eax, {s}\n", .{reg32[rhs]});
        }
        self.freeOperands(p);
        self.assignResult(i);
    }

    fn emitIdiv(self: *@This(), p: InstPair, i: usize) !void {
        try self.loadIntoReg(p.l, eax_i);
        const rhs = try self.ensureAnyReg(p.r);
        self.freeOperands(p);
        try self.buf.appendSlice(self.gpa, "    cdq\n");
        try self.buf.print(self.gpa, "    idiv {s}\n", .{reg32[rhs]});
        self.assignResult(i);
    }

    fn emitCmp(self: *@This(), setcc: []const u8, p: InstPair, i: usize) !void {
        try self.loadIntoReg(p.l, eax_i);
        if (self.loadImm(p.r)) |imm| try self.buf.print(self.gpa, "    cmp eax, {d}\n", .{imm}) else {
            const rhs = try self.ensureAnyReg(p.r);
            try self.buf.print(self.gpa, "    cmp eax, {s}\n", .{reg32[rhs]});
        }
        self.freeOperands(p);
        try self.buf.print(self.gpa, "    {s} al\n", .{setcc});
        try self.buf.appendSlice(self.gpa, "    movzx eax, al\n");
        self.assignResult(i);
    }

    fn emitJz(self: *@This(), cond: InstRef, label: u32) !void {
        const cond_reg = try self.ensureAnyReg(cond);
        self.use_count[cond] -= 1;
        try self.buf.print(self.gpa, "    cmp {s}, 0\n", .{reg32[cond_reg]});
        self.freeIfDead(cond);
        try self.buf.print(self.gpa, "    je .L{d}\n", .{label});
    }

    fn emitToEax(self: *@This(), val: InstRef) !void {
        try self.loadIntoReg(val, eax_i);
        self.use_count[val] -= 1;
        self.freeIfDead(val);
    }

    fn assignResult(self: *@This(), i: usize) void {
        self.reg_to_val[eax_i] = @intCast(i);
        self.val_to_reg[i] = eax_i;
    }
};

pub fn emitIr(ir: *const std.ArrayList(Inst), buf: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const use_count = try computeUseCounts(ir, gpa);
    defer gpa.free(use_count);

    const frame_size = computeFrameSize(ir, use_count, gpa);
    if (frame_size > 0) try buf.print(gpa, "    sub rsp, {d}\n", .{frame_size});

    var self = Emitter{
        .iri = ir.items,
        .buf = buf,
        .gpa = gpa,
        .val_to_reg = try gpa.alloc(?usize, ir.items.len),
        .reg_to_val = [_]?u32{null} ** NUM_REGS,
        .spill_slots = try gpa.alloc(?u32, ir.items.len),
        .spill_idx = 0,
        .use_count = use_count,
    };
    defer gpa.free(self.val_to_reg);
    defer gpa.free(self.spill_slots);
    @memset(self.val_to_reg, null);
    @memset(self.spill_slots, null);

    for (ir.items, 0..) |inst, i| {
        switch (inst) {
            .iconst => {},
            .iadd => |p| try self.emitAddSub("add", p, i),
            .isub => |p| try self.emitAddSub("sub", p, i),
            .imul => |p| try self.emitImul(p, i),
            .idiv => |p| try self.emitIdiv(p, i),
            .ilt => |p| try self.emitCmp("setl", p, i),
            .igt => |p| try self.emitCmp("setg", p, i),
            .ile => |p| try self.emitCmp("setle", p, i),
            .ige => |p| try self.emitCmp("setge", p, i),
            .ieq => |p| try self.emitCmp("sete", p, i),
            .ine => |p| try self.emitCmp("setne", p, i),
            .print => |v| {
                try self.loadIntoReg(v, eax_i);
                self.use_count[v] -= 1;
                self.freeIfDead(v);
                try buf.appendSlice(gpa, "    call print_int\n");
                self.assignResult(i);
            },
            .ret => |v| {
                try self.loadIntoReg(v, eax_i);
                try buf.appendSlice(gpa, "    xor edi, edi\n    mov eax, 60\n    syscall\n");
            },
            .iarg => |idx| {
                try self.evict(eax_i);
                const r = try self.findFreeReg();
                try buf.print(gpa, "    mov rdi, [rbp + {d}]\n", .{idx * 8});
                try buf.appendSlice(gpa, "    call atoi\n");
                if (r != eax_i) try buf.print(gpa, "    mov {s}, eax\n", .{reg32[r]});
                self.reg_to_val[r] = @intCast(i);
                self.val_to_reg[i] = r;
            },
            .ijz => |j| try self.emitJz(j.cond, j.label),
            .ijmp => |label| try buf.print(gpa, "    jmp .L{d}\n", .{label}),
            .ilabel => |label| try buf.print(gpa, ".L{d}:\n", .{label}),
            .itoeax => |v| try self.emitToEax(v),
            .iphi => self.assignResult(i),
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
    var lowered = try lower(node, gpa);
    defer lowered.deinit(gpa);
    return compileIr(&lowered, gpa);
}
