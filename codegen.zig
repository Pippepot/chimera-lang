const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const ir_mod = @import("ir.zig");
const helpers = @import("helpers_bin.zig");
const db = @import("db.zig");

const InstRef = ir_mod.ValueRef;
const InstPair = ir_mod.InstPair;
const Inst = ir_mod.Inst;
const BlockId = ir_mod.BlockId;
const Program = ir_mod.Program;
const BinaryEmitter = struct {
    prog: *const Program,
    gpa: std.mem.Allocator,
    code: std.ArrayList(u8),
    block_params: []?InstRef,
    block_symbols: []u32,
    helper_symbols: []u32,
    symbols: std.ArrayList(?u32),
    fixups: std.ArrayList(RelFixup),

    const SetccCond = enum(u8) {
        b = 0x92,
        be = 0x96,
        a = 0x97,
        ae = 0x93,
        l = 0x9C,
        g = 0x9F,
        le = 0x9E,
        ge = 0x9D,
        e = 0x94,
        ne = 0x95,
        p = 0x9A,
        np = 0x9B,
    };

    const BranchCopy = struct {
        src: InstRef,
        dst: InstRef,
    };

    const RelFixup = struct {
        disp_pos: u32,
        symbol: u32,
    };

    fn slotOffset(value_ref: InstRef) u32 {
        return value_ref * 8;
    }

    fn init(prog: *const Program, gpa: std.mem.Allocator) !@This() {
        var code = try std.ArrayList(u8).initCapacity(gpa, 1024);
        errdefer code.deinit(gpa);

        var block_params = try gpa.alloc(?InstRef, prog.blocks.items.len);
        errdefer gpa.free(block_params);
        @memset(block_params, null);

        var block_symbols = try gpa.alloc(u32, prog.blocks.items.len);
        errdefer gpa.free(block_symbols);

        var helper_symbols = try gpa.alloc(u32, helpers.all_helpers.len);
        errdefer gpa.free(helper_symbols);

        var symbols = try std.ArrayList(?u32).initCapacity(gpa, prog.blocks.items.len + 16);
        errdefer symbols.deinit(gpa);

        var fixups = try std.ArrayList(RelFixup).initCapacity(gpa, 128);
        errdefer fixups.deinit(gpa);

        for (prog.blocks.items) |block| {
            block_params[block.id] = block.param;
            try symbols.append(gpa, null);
            block_symbols[block.id] = @intCast(symbols.items.len - 1);
        }

        for (helpers.all_helpers, 0..) |_, idx| {
            try symbols.append(gpa, null);
            helper_symbols[idx] = @intCast(symbols.items.len - 1);
        }

        return .{
            .prog = prog,
            .gpa = gpa,
            .code = code,
            .block_params = block_params,
            .block_symbols = block_symbols,
            .helper_symbols = helper_symbols,
            .symbols = symbols,
            .fixups = fixups,
        };
    }

    fn deinit(self: *@This()) void {
        self.code.deinit(self.gpa);
        self.symbols.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.gpa.free(self.block_params);
        self.gpa.free(self.block_symbols);
        self.gpa.free(self.helper_symbols);
    }

    fn appendByte(self: *@This(), byte: u8) !void {
        try self.appendBytes(&.{byte});
    }

    fn appendBytes(self: *@This(), bytes: []const u8) !void {
        try self.code.appendSlice(self.gpa, bytes);
    }

    fn appendLeI32(self: *@This(), value: i32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, value, .little);
        try self.appendBytes(&bytes);
    }

    fn appendLeU32(self: *@This(), value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.appendBytes(&bytes);
    }

    fn createSymbol(self: *@This()) !u32 {
        try self.symbols.append(self.gpa, null);
        return @intCast(self.symbols.items.len - 1);
    }

    fn helperSymbol(self: *@This(), id: helpers.HelperId) u32 {
        const helper_idx: usize = @intFromEnum(id);
        return self.helper_symbols[helper_idx];
    }

    fn bindSymbol(self: *@This(), symbol: u32) void {
        std.debug.assert(self.symbols.items[symbol] == null);
        self.symbols.items[symbol] = @intCast(self.code.items.len);
    }

    fn addRel32Fixup(self: *@This(), symbol: u32) !void {
        const disp_pos: u32 = @intCast(self.code.items.len);
        try self.appendLeI32(0);
        try self.fixups.append(self.gpa, .{ .disp_pos = disp_pos, .symbol = symbol });
    }

    fn emitCall(self: *@This(), symbol: u32) !void {
        try self.appendByte(0xE8);
        try self.addRel32Fixup(symbol);
    }

    fn emitJmp(self: *@This(), symbol: u32) !void {
        try self.appendByte(0xE9);
        try self.addRel32Fixup(symbol);
    }

    fn emitJe(self: *@This(), symbol: u32) !void {
        try self.appendBytes(&.{ 0x0F, 0x84 });
        try self.addRel32Fixup(symbol);
    }

    fn emitJne(self: *@This(), symbol: u32) !void {
        try self.appendBytes(&.{ 0x0F, 0x85 });
        try self.addRel32Fixup(symbol);
    }

    fn resolveFixups(self: *@This()) !void {
        for (self.fixups.items) |fixup| {
            const target = self.symbols.items[fixup.symbol] orelse return error.MissingSymbol;
            const target_i64: i64 = @intCast(target);
            const next_ip_i64 = @as(i64, fixup.disp_pos) + 4;
            const rel_i64 = target_i64 - next_ip_i64;
            if (rel_i64 < std.math.minInt(i32) or rel_i64 > std.math.maxInt(i32)) return error.BranchOutOfRange;
            const rel_i32: i32 = @intCast(rel_i64);
            const disp_pos: usize = @intCast(fixup.disp_pos);
            std.mem.writeInt(i32, self.code.items[disp_pos..][0..4], rel_i32, .little);
        }
    }

    fn emitLeaRbpRspPlus8(self: *@This()) !void {
        try self.appendBytes(&.{ 0x48, 0x8D, 0x6C, 0x24, 0x08 });
    }

    fn emitSubRspImm32(self: *@This(), value: u32) !void {
        try self.appendBytes(&.{ 0x48, 0x81, 0xEC });
        try self.appendLeU32(value);
    }

    fn emitMovEaxImm32(self: *@This(), value: i32) !void {
        try self.appendByte(0xB8);
        try self.appendLeU32(@bitCast(value));
    }

    fn emitMovEaxImmU32(self: *@This(), value: u32) !void {
        try self.appendByte(0xB8);
        try self.appendLeU32(value);
    }

    fn emitLoadEaxFromSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0x8B, 0x84, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitLoadEbxFromSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0x8B, 0x9C, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitLoadRaxFromSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0x48, 0x8B, 0x84, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitLoadXmm0FromSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0xF3, 0x0F, 0x10, 0x84, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitLoadXmm1FromSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0xF3, 0x0F, 0x10, 0x8C, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitStoreRaxToSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0x84, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitStoreXmm0ToSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0xF3, 0x0F, 0x11, 0x84, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitCopySlot(self: *@This(), src_ref: InstRef, dst_ref: InstRef) !void {
        try self.emitLoadRaxFromSlot(src_ref);
        try self.emitStoreRaxToSlot(dst_ref);
    }

    fn emitMovRdiFromRbpDisp32(self: *@This(), disp: u32) !void {
        try self.appendBytes(&.{ 0x48, 0x8B, 0xBD });
        try self.appendLeU32(disp);
    }

    fn emitAddEaxEbx(self: *@This()) !void {
        try self.appendBytes(&.{ 0x01, 0xD8 });
    }

    fn emitSubEaxEbx(self: *@This()) !void {
        try self.appendBytes(&.{ 0x29, 0xD8 });
    }

    fn emitImulEaxEbx(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0xAF, 0xC3 });
    }

    fn emitCdq(self: *@This()) !void {
        try self.appendByte(0x99);
    }

    fn emitIdivEbx(self: *@This()) !void {
        try self.appendBytes(&.{ 0xF7, 0xFB });
    }

    fn emitCmpEaxEbx(self: *@This()) !void {
        try self.appendBytes(&.{ 0x39, 0xD8 });
    }

    fn emitCmpEaxZero(self: *@This()) !void {
        try self.appendBytes(&.{ 0x83, 0xF8, 0x00 });
    }

    fn emitUcomissXmm0Xmm1(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0x2E, 0xC1 });
    }

    fn emitFloatBinOp(self: *@This(), opcode: u8) !void {
        try self.appendBytes(&.{ 0xF3, 0x0F, opcode, 0xC1 });
    }

    fn emitSetcc(self: *@This(), cond: SetccCond) !void {
        try self.appendBytes(&.{ 0x0F, @intFromEnum(cond), 0xC0 });
    }

    fn emitSetccBl(self: *@This(), cond: SetccCond) !void {
        try self.appendBytes(&.{ 0x0F, @intFromEnum(cond), 0xC3 });
    }

    fn emitMovzxEaxAl(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0xB6, 0xC0 });
    }

    fn emitAndAlBl(self: *@This()) !void {
        try self.appendBytes(&.{ 0x20, 0xD8 });
    }

    fn emitOrAlBl(self: *@This()) !void {
        try self.appendBytes(&.{ 0x08, 0xD8 });
    }

    fn emitMovEdiEax(self: *@This()) !void {
        try self.appendBytes(&.{ 0x89, 0xC7 });
    }

    fn emitSyscall(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0x05 });
    }

    fn branchCopy(self: *@This(), branch: ir_mod.Branch) ?BranchCopy {
        const dst = self.block_params[branch.target] orelse return null;
        const src = branch.arg orelse unreachable;
        if (src == dst) return null;
        return .{ .src = src, .dst = dst };
    }

    fn emitBinaryArithmeticInt(self: *@This(), pair: InstPair, opcode: enum { add, sub, imul }, out: InstRef) !void {
        try self.emitLoadEaxFromSlot(pair.l);
        try self.emitLoadEbxFromSlot(pair.r);
        switch (opcode) {
            .add => try self.emitAddEaxEbx(),
            .sub => try self.emitSubEaxEbx(),
            .imul => try self.emitImulEaxEbx(),
        }
        try self.emitStoreRaxToSlot(out);
    }

    fn emitBinaryArithmeticFloat(self: *@This(), pair: InstPair, opcode: u8, out: InstRef) !void {
        try self.emitLoadXmm0FromSlot(pair.l);
        try self.emitLoadXmm1FromSlot(pair.r);
        try self.emitFloatBinOp(opcode);
        try self.emitStoreXmm0ToSlot(out);
    }

    fn emitBinaryDivInt(self: *@This(), pair: InstPair, out: InstRef) !void {
        try self.emitLoadEaxFromSlot(pair.l);
        try self.emitLoadEbxFromSlot(pair.r);
        try self.emitCdq();
        try self.emitIdivEbx();
        try self.emitStoreRaxToSlot(out);
    }

    fn emitBinaryDivFloat(self: *@This(), pair: InstPair, out: InstRef) !void {
        try self.emitLoadXmm0FromSlot(pair.l);
        try self.emitLoadXmm1FromSlot(pair.r);
        try self.emitFloatBinOp(0x5E);
        try self.emitStoreXmm0ToSlot(out);
    }

    fn emitCompareIntToEax(self: *@This(), pair: InstPair, cond: SetccCond) !void {
        try self.emitLoadEaxFromSlot(pair.l);
        try self.emitLoadEbxFromSlot(pair.r);
        try self.emitCmpEaxEbx();
        try self.emitSetcc(cond);
        try self.emitMovzxEaxAl();
    }

    fn emitCompareFloatOrderedToEax(self: *@This(), pair: InstPair, cond: SetccCond) !void {
        try self.emitLoadXmm0FromSlot(pair.l);
        try self.emitLoadXmm1FromSlot(pair.r);
        try self.emitUcomissXmm0Xmm1();
        try self.emitSetcc(cond);
        try self.emitSetccBl(.np);
        try self.emitAndAlBl();
        try self.emitMovzxEaxAl();
    }

    fn emitCompareFloatNotEqualToEax(self: *@This(), pair: InstPair) !void {
        try self.emitLoadXmm0FromSlot(pair.l);
        try self.emitLoadXmm1FromSlot(pair.r);
        try self.emitUcomissXmm0Xmm1();
        try self.emitSetcc(.ne);
        try self.emitSetccBl(.p);
        try self.emitOrAlBl();
        try self.emitMovzxEaxAl();
    }

    fn emitStoreUnitValue(self: *@This(), out: InstRef) !void {
        try self.emitMovEaxImm32(0);
        try self.emitStoreRaxToSlot(out);
    }

    fn emitValueInst(self: *@This(), value_inst: ir_mod.ValueInst) !void {
        switch (value_inst.op) {
            .iconst => |value| {
                try self.emitMovEaxImm32(value);
                try self.emitStoreRaxToSlot(value_inst.id);
            },
            .fconst => |value| {
                try self.emitMovEaxImmU32(@bitCast(value));
                try self.emitStoreRaxToSlot(value_inst.id);
            },
            .addi => |pair| try self.emitBinaryArithmeticInt(pair, .add, value_inst.id),
            .addf => |pair| try self.emitBinaryArithmeticFloat(pair, 0x58, value_inst.id),
            .subi => |pair| try self.emitBinaryArithmeticInt(pair, .sub, value_inst.id),
            .subf => |pair| try self.emitBinaryArithmeticFloat(pair, 0x5C, value_inst.id),
            .muli => |pair| try self.emitBinaryArithmeticInt(pair, .imul, value_inst.id),
            .mulf => |pair| try self.emitBinaryArithmeticFloat(pair, 0x59, value_inst.id),
            .divi => |pair| try self.emitBinaryDivInt(pair, value_inst.id),
            .divf => |pair| try self.emitBinaryDivFloat(pair, value_inst.id),
            .printi => |value_ref| {
                try self.emitLoadEaxFromSlot(value_ref);
                try self.emitCall(self.helperSymbol(.print_int));
                try self.emitStoreUnitValue(value_inst.id);
            },
            .printf => |value_ref| {
                try self.emitLoadXmm0FromSlot(value_ref);
                try self.emitCall(self.helperSymbol(.print_float32));
                try self.emitStoreUnitValue(value_inst.id);
            },
            .printb => |value_ref| {
                try self.emitLoadEaxFromSlot(value_ref);
                try self.emitCall(self.helperSymbol(.print_bool));
                try self.emitStoreUnitValue(value_inst.id);
            },
            .argi => |idx| {
                try self.emitMovRdiFromRbpDisp32(idx * 8);
                try self.emitCallAndStore(self.helperSymbol(.atoi), value_inst.id);
            },
            .store => |pair| {
                try self.emitLoadRaxFromSlot(pair.l);
                try self.emitStoreRaxToSlot(pair.r);
                try self.emitStoreUnitValue(value_inst.id);
            },
        }
    }

    fn emitCallAndStore(self: *@This(), symbol: u32, out: InstRef) !void {
        try self.emitCall(symbol);
        try self.emitStoreRaxToSlot(out);
    }

    fn emitReturn(self: *@This(), value_ref: InstRef) !void {
        try self.emitLoadEaxFromSlot(value_ref);
        try self.emitMovEdiEax();
        try self.emitMovEaxImm32(60);
        try self.emitSyscall();
    }

    fn emitBranch(self: *@This(), branch: ir_mod.Branch) !void {
        const maybe_copy = self.branchCopy(branch);
        if (maybe_copy) |copy| try self.emitCopySlot(copy.src, copy.dst);
        try self.emitJmp(self.block_symbols[branch.target]);
    }

    fn emitPredicateValueToEax(self: *@This(), pred: ir_mod.Predicate) !void {
        switch (pred.op) {
            .lti => try self.emitCompareIntToEax(pred.pair, .l),
            .ltf => try self.emitCompareFloatOrderedToEax(pred.pair, .b),
            .gti => try self.emitCompareIntToEax(pred.pair, .g),
            .gtf => try self.emitCompareFloatOrderedToEax(pred.pair, .a),
            .lei => try self.emitCompareIntToEax(pred.pair, .le),
            .lef => try self.emitCompareFloatOrderedToEax(pred.pair, .be),
            .gei => try self.emitCompareIntToEax(pred.pair, .ge),
            .gef => try self.emitCompareFloatOrderedToEax(pred.pair, .ae),
            .eqi => try self.emitCompareIntToEax(pred.pair, .e),
            .eqf => try self.emitCompareFloatOrderedToEax(pred.pair, .e),
            .eqb => try self.emitCompareIntToEax(pred.pair, .e),
            .nei => try self.emitCompareIntToEax(pred.pair, .ne),
            .nef => try self.emitCompareFloatNotEqualToEax(pred.pair),
            .neb => try self.emitCompareIntToEax(pred.pair, .ne),
        }
    }

    fn emitBranchOnEaxNonZero(self: *@This(), then_branch: ir_mod.Branch, else_branch: ir_mod.Branch) !void {
        try self.emitCmpEaxZero();

        const then_copy = self.branchCopy(then_branch);
        const else_copy = self.branchCopy(else_branch);
        const then_symbol = self.block_symbols[then_branch.target];
        const else_symbol = self.block_symbols[else_branch.target];

        if (then_copy == null and else_copy == null) {
            try self.emitJe(else_symbol);
            try self.emitJmp(then_symbol);
            return;
        }

        if (then_copy != null and else_copy == null) {
            try self.emitJe(else_symbol);
            const copy = then_copy.?;
            try self.emitCopySlot(copy.src, copy.dst);
            try self.emitJmp(then_symbol);
            return;
        }

        if (then_copy == null and else_copy != null) {
            try self.emitJne(then_symbol);
            const copy = else_copy.?;
            try self.emitCopySlot(copy.src, copy.dst);
            try self.emitJmp(else_symbol);
            return;
        }

        const prep_symbol = try self.createSymbol();
        try self.emitJe(prep_symbol);
        const then_copy_value = then_copy.?;
        try self.emitCopySlot(then_copy_value.src, then_copy_value.dst);
        try self.emitJmp(then_symbol);

        self.bindSymbol(prep_symbol);
        const else_copy_value = else_copy.?;
        try self.emitCopySlot(else_copy_value.src, else_copy_value.dst);
        try self.emitJmp(else_symbol);
    }

    fn emitPredicateBranch(self: *@This(), pbr: @FieldType(ir_mod.Terminator, "pbr")) !void {
        try self.emitPredicateValueToEax(pbr.pred);
        try self.emitBranchOnEaxNonZero(pbr.then_branch, pbr.else_branch);
    }

    fn emitTerm(self: *@This(), term: ir_mod.Terminator) !void {
        switch (term) {
            .br => |branch| try self.emitBranch(branch),
            .pbr => |pbr| try self.emitPredicateBranch(pbr),
            .ret => |value_ref| try self.emitReturn(value_ref),
        }
    }

    fn emitBlock(self: *@This(), block: ir_mod.Block) !void {
        self.bindSymbol(self.block_symbols[block.id]);
        for (block.insts.items) |value_inst| try self.emitValueInst(value_inst);
        const terminator = block.terminator orelse unreachable;
        try self.emitTerm(terminator);
    }

    fn appendHelpers(self: *@This()) !void {
        for (helpers.all_helpers, 0..) |helper, idx| {
            self.bindSymbol(self.helper_symbols[idx]);
            try self.appendBytes(helper.blob.slice());
        }
    }

    fn emitProgram(self: *@This()) ![]const u8 {
        try self.emitLeaRbpRspPlus8();

        const frame_size = slotOffset(self.prog.next_value);
        if (frame_size > 0) try self.emitSubRspImm32(frame_size);

        if (self.prog.entry != 0) try self.emitJmp(self.block_symbols[self.prog.entry]);

        for (self.prog.blocks.items) |block| try self.emitBlock(block);
        try self.appendHelpers();
        try self.resolveFixups();
        return self.code.toOwnedSlice(self.gpa);
    }
};

fn buildElfExecutable(code: []const u8, entry_code_offset: u64, gpa: std.mem.Allocator) error{ OutOfMemory, FileTooBig }![]const u8 {
    const code_file_offset: u64 = 0x1000;
    const image_base: u64 = 0x400000;

    const code_len_u64: u64 = @intCast(code.len);
    const total_file_size_u64 = code_file_offset + code_len_u64;
    if (total_file_size_u64 > std.math.maxInt(usize)) return error.FileTooBig;
    const total_file_size: usize = @intCast(total_file_size_u64);

    const Elf64Header = extern struct {
        ident: [16]u8,
        e_type: u16,
        e_machine: u16,
        e_version: u32,
        e_entry: u64,
        e_phoff: u64,
        e_shoff: u64,
        e_flags: u32,
        e_ehsize: u16,
        e_phentsize: u16,
        e_phnum: u16,
        e_shentsize: u16,
        e_shnum: u16,
        e_shstrndx: u16,
    };

    const Elf64Phdr = extern struct {
        p_type: u32,
        p_flags: u32,
        p_offset: u64,
        p_vaddr: u64,
        p_paddr: u64,
        p_filesz: u64,
        p_memsz: u64,
        p_align: u64,
    };

    const elf_header = Elf64Header{
        .ident = .{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .e_type = 2,
        .e_machine = 62,
        .e_version = 1,
        .e_entry = image_base + code_file_offset + entry_code_offset,
        .e_phoff = @sizeOf(Elf64Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(Elf64Header),
        .e_phentsize = @sizeOf(Elf64Phdr),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };

    const phdr = Elf64Phdr{
        .p_type = 1,
        .p_flags = 5,
        .p_offset = 0,
        .p_vaddr = image_base,
        .p_paddr = image_base,
        .p_filesz = total_file_size_u64,
        .p_memsz = total_file_size_u64,
        .p_align = 0x1000,
    };

    var file_buf = try std.ArrayList(u8).initCapacity(gpa, total_file_size);
    errdefer file_buf.deinit(gpa);

    try file_buf.appendSlice(gpa, std.mem.asBytes(&elf_header));
    try file_buf.appendSlice(gpa, std.mem.asBytes(&phdr));
    const remaining = code_file_offset - file_buf.items.len;
    try file_buf.appendNTimes(gpa, 0, @intCast(remaining));
    try file_buf.appendSlice(gpa, code);

    return file_buf.toOwnedSlice(gpa);
}

const ir = @import("ir.zig");

pub const CompileMemo = db.Memo([]const u8);

pub fn computeCompile(lower_memo: *const ir.LowerMemo, gpa: std.mem.Allocator) error{OutOfMemory}!CompileMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, lower_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var bytes: ?[]const u8 = null;
    if (lower_memo.value) |*prog| {
        bytes = compileProgram(prog, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                try db.appendStageError(&diagnostics_list, gpa, .compile, @errorName(err));
                break :blk null;
            },
        };
    }

    return db.makeMemo([]const u8, bytes, diagnostics_list);
}

pub fn compileProgram(prog: *const Program, gpa: std.mem.Allocator) ![]const u8 {
    var emitter = try BinaryEmitter.init(prog, gpa);
    defer emitter.deinit();

    const code = try emitter.emitProgram();
    defer gpa.free(code);

    return buildElfExecutable(code, 0, gpa);
}
