const std = @import("std");
const ir_mod = @import("ir.zig");
const x86 = @import("x86.zig");
const AstNode = x86.AstNode;

pub const InstRef = ir_mod.ValueRef;
pub const InstPair = ir_mod.InstPair;
pub const Inst = ir_mod.Inst;
pub const BlockId = ir_mod.BlockId;
pub const Program = ir_mod.Program;
pub const lower = ir_mod.lower;

fn slotOffset(value_ref: InstRef) u32 {
    return value_ref * 8;
}

const BranchCopy = struct {
    src: InstRef,
    dst: InstRef,
};

const Emitter = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    block_params: []?InstRef,
    prep_label_counter: u32,

    fn init(prog: *const Program, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!@This() {
        var params = try gpa.alloc(?InstRef, prog.blocks.items.len);
        @memset(params, null);
        for (prog.blocks.items) |blk| params[blk.id] = blk.param;
        return .{
            .buf = buf,
            .gpa = gpa,
            .block_params = params,
            .prep_label_counter = 0,
        };
    }

    fn deinit(self: *@This()) void {
        self.gpa.free(self.block_params);
    }

    fn appendLine(self: *@This(), line: []const u8) !void {
        try self.buf.appendSlice(self.gpa, line);
    }

    fn loadReg(self: *@This(), reg: []const u8, value_ref: InstRef) !void {
        try self.buf.print(self.gpa, "    mov {s}, [rsp+{d}]\n", .{ reg, slotOffset(value_ref) });
    }

    fn storeRax(self: *@This(), value_ref: InstRef) !void {
        try self.buf.print(self.gpa, "    mov [rsp+{d}], rax\n", .{slotOffset(value_ref)});
    }

    fn copyValue(self: *@This(), src_ref: InstRef, dst_ref: InstRef) !void {
        try self.buf.print(self.gpa, "    mov rax, [rsp+{d}]\n", .{slotOffset(src_ref)});
        try self.buf.print(self.gpa, "    mov [rsp+{d}], rax\n", .{slotOffset(dst_ref)});
    }

    fn emitBinaryWithSingleOp(self: *@This(), pair: InstPair, op_line: []const u8, out: InstRef) !void {
        try self.loadReg("eax", pair.l);
        try self.loadReg("ebx", pair.r);
        try self.appendLine(op_line);
        try self.storeRax(out);
    }

    fn emitBinaryDiv(self: *@This(), pair: InstPair, out: InstRef) !void {
        try self.loadReg("eax", pair.l);
        try self.loadReg("ebx", pair.r);
        try self.appendLine("    cdq\n");
        try self.appendLine("    idiv ebx\n");
        try self.storeRax(out);
    }

    fn emitCompare(self: *@This(), setcc: []const u8, pair: InstPair, out: InstRef) !void {
        try self.loadReg("eax", pair.l);
        try self.loadReg("ebx", pair.r);
        try self.appendLine("    cmp eax, ebx\n");
        try self.buf.print(self.gpa, "    {s} al\n", .{setcc});
        try self.appendLine("    movzx eax, al\n");
        try self.storeRax(out);
    }

    fn emitValueInst(self: *@This(), value_inst: ir_mod.ValueInst) !void {
        switch (value_inst.op) {
            .iconst => |v| {
                try self.buf.print(self.gpa, "    mov eax, {d}\n", .{v});
                try self.storeRax(value_inst.id);
            },
            .iadd => |pair| try self.emitBinaryWithSingleOp(pair, "    add eax, ebx\n", value_inst.id),
            .isub => |pair| try self.emitBinaryWithSingleOp(pair, "    sub eax, ebx\n", value_inst.id),
            .imul => |pair| try self.emitBinaryWithSingleOp(pair, "    imul eax, ebx\n", value_inst.id),
            .idiv => |pair| try self.emitBinaryDiv(pair, value_inst.id),
            .ilt => |pair| try self.emitCompare("setl", pair, value_inst.id),
            .igt => |pair| try self.emitCompare("setg", pair, value_inst.id),
            .ile => |pair| try self.emitCompare("setle", pair, value_inst.id),
            .ige => |pair| try self.emitCompare("setge", pair, value_inst.id),
            .ieq => |pair| try self.emitCompare("sete", pair, value_inst.id),
            .ine => |pair| try self.emitCompare("setne", pair, value_inst.id),
            .print => |v| {
                try self.loadReg("eax", v);
                try self.appendLine("    call print_int\n");
                try self.storeRax(value_inst.id);
            },
            .iarg => |idx| {
                try self.buf.print(self.gpa, "    mov rdi, [rbp + {d}]\n", .{idx * 8});
                try self.appendLine("    call atoi\n");
                try self.storeRax(value_inst.id);
            },
        }
    }

    fn branchCopy(self: *@This(), branch: ir_mod.Branch) ?BranchCopy {
        const dst = self.block_params[branch.target] orelse return null;
        const src = branch.arg orelse unreachable;
        if (src == dst) return null;
        return .{ .src = src, .dst = dst };
    }

    fn emitJump(self: *@This(), target: BlockId) !void {
        try self.buf.print(self.gpa, "    jmp near .L{d}\n", .{target});
    }

    fn emitBranch(self: *@This(), branch: ir_mod.Branch) !void {
        const maybe_copy = self.branchCopy(branch);
        if (maybe_copy) |copy| try self.copyValue(copy.src, copy.dst);
        try self.emitJump(branch.target);
    }

    fn emitConditionalBranch(self: *@This(), cbr: @FieldType(ir_mod.Terminator, "cbr")) !void {
        try self.loadReg("eax", cbr.cond);
        try self.appendLine("    cmp eax, 0\n");

        const then_copy = self.branchCopy(cbr.then_branch);
        const else_copy = self.branchCopy(cbr.else_branch);

        if (then_copy == null and else_copy == null) {
            try self.buf.print(self.gpa, "    je near .L{d}\n", .{cbr.else_branch.target});
            try self.emitJump(cbr.then_branch.target);
            return;
        }

        if (then_copy != null and else_copy == null) {
            try self.buf.print(self.gpa, "    je near .L{d}\n", .{cbr.else_branch.target});
            const copy = then_copy.?;
            try self.copyValue(copy.src, copy.dst);
            try self.emitJump(cbr.then_branch.target);
            return;
        }

        if (then_copy == null and else_copy != null) {
            try self.buf.print(self.gpa, "    jne near .L{d}\n", .{cbr.then_branch.target});
            const copy = else_copy.?;
            try self.copyValue(copy.src, copy.dst);
            try self.emitJump(cbr.else_branch.target);
            return;
        }

        const prep_label = self.prep_label_counter;
        self.prep_label_counter += 1;
        try self.buf.print(self.gpa, "    je near .Lprep{d}\n", .{prep_label});
        const then_copy_value = then_copy.?;
        try self.copyValue(then_copy_value.src, then_copy_value.dst);
        try self.emitJump(cbr.then_branch.target);
        try self.buf.print(self.gpa, ".Lprep{d}:\n", .{prep_label});
        const else_copy_value = else_copy.?;
        try self.copyValue(else_copy_value.src, else_copy_value.dst);
        try self.emitJump(cbr.else_branch.target);
    }

    fn emitReturn(self: *@This(), value_ref: InstRef) !void {
        try self.loadReg("eax", value_ref);
        try self.appendLine("    xor edi, edi\n");
        try self.appendLine("    mov eax, 60\n");
        try self.appendLine("    syscall\n");
    }

    fn emitTerm(self: *@This(), term: ir_mod.Terminator) !void {
        switch (term) {
            .br => |branch| try self.emitBranch(branch),
            .cbr => |cbr| try self.emitConditionalBranch(cbr),
            .ret => |result| try self.emitReturn(result),
        }
    }

    fn emitBlock(self: *@This(), block: ir_mod.Block) !void {
        try self.buf.print(self.gpa, ".L{d}:\n", .{block.id});
        for (block.insts.items) |value_inst| try self.emitValueInst(value_inst);
        const term = block.term orelse unreachable;
        try self.emitTerm(term);
    }
};

pub fn emitIr(prog: *const Program, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) error{OutOfMemory}!void {
    const frame_size = prog.next_value * 8;
    if (frame_size > 0) try buf.print(gpa, "    sub rsp, {d}\n", .{frame_size});

    var emitter = try Emitter.init(prog, buf, gpa);
    defer emitter.deinit();

    if (prog.entry != 0) try buf.print(gpa, "    jmp near .L{d}\n", .{prog.entry});

    for (prog.blocks.items) |block| try emitter.emitBlock(block);
}

pub fn compileIr(prog: *const Program, gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 256);
    errdefer buf.deinit(gpa);
    try buf.appendSlice(gpa, "global _start\n_start:\n");
    try buf.appendSlice(gpa, "    lea rbp, [rsp+8]\n");
    try emitIr(prog, &buf, gpa);
    try buf.appendSlice(gpa, @embedFile("print.asm"));
    return buf.toOwnedSlice(gpa);
}

pub fn compile(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}![]const u8 {
    var lowered = try lower(node, gpa);
    defer lowered.deinit(gpa);
    return compileIr(&lowered, gpa);
}
