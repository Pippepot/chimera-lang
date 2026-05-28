const std = @import("std");
const ir_mod = @import("ir.zig");
const x86 = @import("x86.zig");
const helpers = @import("helpers_bin.zig");
const AstNode = x86.AstNode;

const InstRef = ir_mod.ValueRef;
const InstPair = ir_mod.InstPair;
const Inst = ir_mod.Inst;
const BlockId = ir_mod.BlockId;
const Program = ir_mod.Program;
pub const lower = ir_mod.lower;

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
        l  = 0x9C,
        g  = 0x9F,
        le = 0x9E,
        ge = 0x9D,
        e  = 0x94,
        ne = 0x95,
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

    fn finish(self: *@This()) ![]const u8 {
        try self.resolveFixups();
        return self.code.toOwnedSlice(self.gpa);
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

    fn emitStoreRaxToSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0x84, 0x24 });
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

    fn emitSetcc(self: *@This(), cond: SetccCond) !void {
        try self.appendBytes(&.{ 0x0F, @intFromEnum(cond), 0xC0 });
    }

    fn emitMovzxEaxAl(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0xB6, 0xC0 });
    }

    fn emitXorEdiEdi(self: *@This()) !void {
        try self.appendBytes(&.{ 0x31, 0xFF });
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

    fn emitBinaryArithmetic(self: *@This(), pair: InstPair, opcode: enum { add, sub, imul }, out: InstRef) !void {
        try self.emitLoadEaxFromSlot(pair.l);
        try self.emitLoadEbxFromSlot(pair.r);
        switch (opcode) {
            .add => try self.emitAddEaxEbx(),
            .sub => try self.emitSubEaxEbx(),
            .imul => try self.emitImulEaxEbx(),
        }
        try self.emitStoreRaxToSlot(out);
    }

    fn emitBinaryDiv(self: *@This(), pair: InstPair, out: InstRef) !void {
        try self.emitLoadEaxFromSlot(pair.l);
        try self.emitLoadEbxFromSlot(pair.r);
        try self.emitCdq();
        try self.emitIdivEbx();
        try self.emitStoreRaxToSlot(out);
    }

    fn emitCompare(self: *@This(), pair: InstPair, cond: SetccCond, out: InstRef) !void {
        try self.emitLoadEaxFromSlot(pair.l);
        try self.emitLoadEbxFromSlot(pair.r);
        try self.emitCmpEaxEbx();
        try self.emitSetcc(cond);
        try self.emitMovzxEaxAl();
        try self.emitStoreRaxToSlot(out);
    }

    fn emitValueInst(self: *@This(), value_inst: ir_mod.ValueInst) !void {
        switch (value_inst.op) {
            .iconst => |value| {
                try self.emitMovEaxImm32(value);
                try self.emitStoreRaxToSlot(value_inst.id);
            },
            .iadd => |pair| try self.emitBinaryArithmetic(pair, .add, value_inst.id),
            .isub => |pair| try self.emitBinaryArithmetic(pair, .sub, value_inst.id),
            .imul => |pair| try self.emitBinaryArithmetic(pair, .imul, value_inst.id),
            .idiv => |pair| try self.emitBinaryDiv(pair, value_inst.id),
            .ilt => |pair| try self.emitCompare(pair, .l, value_inst.id),
            .igt => |pair| try self.emitCompare(pair, .g, value_inst.id),
            .ile => |pair| try self.emitCompare(pair, .le, value_inst.id),
            .ige => |pair| try self.emitCompare(pair, .ge, value_inst.id),
            .ieq => |pair| try self.emitCompare(pair, .e, value_inst.id),
            .ine => |pair| try self.emitCompare(pair, .ne, value_inst.id),
            .print => |value_ref| {
                try self.emitLoadEaxFromSlot(value_ref);
                try self.emitCallAndStore(self.helperSymbol(.print_int), value_inst.id);
            },
            .iarg => |idx| {
                try self.emitMovRdiFromRbpDisp32(idx * 8);
                try self.emitCallAndStore(self.helperSymbol(.atoi), value_inst.id);
            },
        }
    }

    fn emitCallAndStore(self: *@This(), symbol: u32, out: InstRef) !void {
        try self.emitCall(symbol);
        try self.emitStoreRaxToSlot(out);
    }

    fn emitReturn(self: *@This(), value_ref: InstRef) !void {
        try self.emitLoadEaxFromSlot(value_ref);
        try self.emitXorEdiEdi();
        try self.emitMovEaxImm32(60);
        try self.emitSyscall();
    }

    fn emitBranch(self: *@This(), branch: ir_mod.Branch) !void {
        const maybe_copy = self.branchCopy(branch);
        if (maybe_copy) |copy| try self.emitCopySlot(copy.src, copy.dst);
        try self.emitJmp(self.block_symbols[branch.target]);
    }

    fn emitConditionalBranch(self: *@This(), cbr: @FieldType(ir_mod.Terminator, "cbr")) !void {
        try self.emitLoadEaxFromSlot(cbr.cond);
        try self.emitCmpEaxZero();

        const then_copy = self.branchCopy(cbr.then_branch);
        const else_copy = self.branchCopy(cbr.else_branch);
        const then_symbol = self.block_symbols[cbr.then_branch.target];
        const else_symbol = self.block_symbols[cbr.else_branch.target];

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

    fn emitTerm(self: *@This(), term: ir_mod.Terminator) !void {
        switch (term) {
            .br => |branch| try self.emitBranch(branch),
            .cbr => |cbr| try self.emitConditionalBranch(cbr),
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

    fn emitProgram(self: *@This()) !void {
        try self.emitLeaRbpRspPlus8();

        const frame_size = slotOffset(self.prog.next_value);
        if (frame_size > 0) try self.emitSubRspImm32(frame_size);

        if (self.prog.entry != 0) try self.emitJmp(self.block_symbols[self.prog.entry]);

        for (self.prog.blocks.items) |block| try self.emitBlock(block);
        try self.appendHelpers();
    }
};

fn buildElfExecutable(code: []const u8, entry_code_offset: u64, gpa: std.mem.Allocator) error{ OutOfMemory, FileTooBig }![]const u8 {
    const elf_header_size: usize = 64;
    const program_header_size: usize = 56;
    const code_file_offset_u64: u64 = 0x1000;
    const image_base: u64 = 0x400000;

    const le = struct {
        fn write16(bytes: []u8, offset: usize, value: u16) void {
            std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
        }
        fn write32(bytes: []u8, offset: usize, value: u32) void {
            std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
        }
        fn write64(bytes: []u8, offset: usize, value: u64) void {
            std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
        }
    };

    const code_len_u64: u64 = @intCast(code.len);
    const total_file_size_u64 = code_file_offset_u64 + code_len_u64;
    if (total_file_size_u64 > std.math.maxInt(usize)) return error.FileTooBig;

    const total_file_size: usize = @intCast(total_file_size_u64);
    const code_file_offset: usize = @intCast(code_file_offset_u64);

    var file_buf = try std.ArrayList(u8).initCapacity(gpa, total_file_size);
    errdefer file_buf.deinit(gpa);

    try file_buf.appendNTimes(gpa, 0, code_file_offset);

    const bytes = file_buf.items;
    bytes[0] = 0x7f;
    bytes[1] = 'E';
    bytes[2] = 'L';
    bytes[3] = 'F';
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    bytes[7] = 0;

    le.write16(bytes, 16, 2);
    le.write16(bytes, 18, 62);
    le.write32(bytes, 20, 1);
    le.write64(bytes, 24, image_base + code_file_offset_u64 + entry_code_offset);
    le.write64(bytes, 32, elf_header_size);
    le.write64(bytes, 40, 0);
    le.write32(bytes, 48, 0);
    le.write16(bytes, 52, elf_header_size);
    le.write16(bytes, 54, program_header_size);
    le.write16(bytes, 56, 1);
    le.write16(bytes, 58, 0);
    le.write16(bytes, 60, 0);
    le.write16(bytes, 62, 0);

    const phoff = elf_header_size;
    le.write32(bytes, phoff + 0, 1);
    le.write32(bytes, phoff + 4, 5);
    le.write64(bytes, phoff + 8, 0);
    le.write64(bytes, phoff + 16, image_base);
    le.write64(bytes, phoff + 24, image_base);
    le.write64(bytes, phoff + 32, total_file_size_u64);
    le.write64(bytes, phoff + 40, total_file_size_u64);
    le.write64(bytes, phoff + 48, 0x1000);

    try file_buf.appendSlice(gpa, code);
    return file_buf.toOwnedSlice(gpa);
}

pub fn compileProgram(prog: *const Program, gpa: std.mem.Allocator) ![]const u8 {
    var emitter = try BinaryEmitter.init(prog, gpa);
    defer emitter.deinit();

    try emitter.emitProgram();
    const code = try emitter.finish();
    defer gpa.free(code);

    return buildElfExecutable(code, 0, gpa);
}

pub fn compile(node: *const AstNode, gpa: std.mem.Allocator) ![]const u8 {
    var lowered = try lower(node, gpa);
    defer lowered.deinit(gpa);
    return compileProgram(&lowered, gpa);
}
