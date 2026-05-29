const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const ir_mod = @import("ir.zig");
const helpers = @import("helpers_bin.zig");
const db = @import("db.zig");

const InstRef = ir_mod.ValueRef;
const InstPair = ir_mod.InstPair;
const Inst = ir_mod.Inst;
const BlockId = ir_mod.BlockId;
const FuncId = ir_mod.FuncId;
const Program = ir_mod.Program;
const Function = ir_mod.Function;

const FunctionLayout = struct {
    symbol: u32,
    block_symbols: []u32,
};

const BinaryEmitter = struct {
    prog: *const Program,
    gpa: std.mem.Allocator,
    code: std.ArrayList(u8),
    symbols: std.ArrayList(?u32),
    fixups: std.ArrayList(RelFixup),
    start_symbol: u32,
    function_layouts: []FunctionLayout,
    helper_symbols: []u32,

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

    fn frameSize(next_value: InstRef) u32 {
        const raw = slotOffset(next_value);
        return std.mem.alignForward(u32, raw, 16);
    }

    fn init(prog: *const Program, gpa: std.mem.Allocator) !@This() {
        var code = try std.ArrayList(u8).initCapacity(gpa, 2048);
        errdefer code.deinit(gpa);

        var symbols = try std.ArrayList(?u32).initCapacity(gpa, 256);
        errdefer symbols.deinit(gpa);

        var fixups = try std.ArrayList(RelFixup).initCapacity(gpa, 256);
        errdefer fixups.deinit(gpa);

        var function_layouts = try gpa.alloc(FunctionLayout, prog.functions.items.len);
        errdefer gpa.free(function_layouts);

        var helper_symbols = try gpa.alloc(u32, helpers.all_helpers.len);
        errdefer gpa.free(helper_symbols);

        const start_symbol = try createSymbol(&symbols, gpa);

        for (prog.functions.items, 0..) |func, fn_idx| {
            const fn_symbol = try createSymbol(&symbols, gpa);
            const block_symbols = try gpa.alloc(u32, func.blocks.items.len);
            errdefer gpa.free(block_symbols);
            for (func.blocks.items, 0..) |_, block_idx| {
                block_symbols[block_idx] = try createSymbol(&symbols, gpa);
            }
            function_layouts[fn_idx] = .{
                .symbol = fn_symbol,
                .block_symbols = block_symbols,
            };
        }

        for (helpers.all_helpers, 0..) |_, idx| {
            helper_symbols[idx] = try createSymbol(&symbols, gpa);
        }

        return .{
            .prog = prog,
            .gpa = gpa,
            .code = code,
            .symbols = symbols,
            .fixups = fixups,
            .start_symbol = start_symbol,
            .function_layouts = function_layouts,
            .helper_symbols = helper_symbols,
        };
    }

    fn createSymbol(symbols: *std.ArrayList(?u32), gpa: std.mem.Allocator) !u32 {
        try symbols.append(gpa, null);
        return @intCast(symbols.items.len - 1);
    }

    fn deinit(self: *@This()) void {
        for (self.function_layouts) |layout| {
            self.gpa.free(layout.block_symbols);
        }
        self.gpa.free(self.function_layouts);
        self.gpa.free(self.helper_symbols);
        self.code.deinit(self.gpa);
        self.symbols.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
    }

    fn layoutFor(self: *const @This(), fn_id: FuncId) *const FunctionLayout {
        return &self.function_layouts[fn_id];
    }

    fn helperSymbol(self: *const @This(), id: helpers.HelperId) u32 {
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

    fn emitCallRel(self: *@This(), symbol: u32) !void {
        try self.appendByte(0xE8);
        try self.addRel32Fixup(symbol);
    }

    fn emitCallRax(self: *@This()) !void {
        try self.appendBytes(&.{ 0xFF, 0xD0 });
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

    fn emitPushRbp(self: *@This()) !void {
        try self.appendByte(0x55);
    }

    fn emitMovRbpRsp(self: *@This()) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0xE5 });
    }

    fn emitMovRspRbp(self: *@This()) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0xEC });
    }

    fn emitPopRbp(self: *@This()) !void {
        try self.appendByte(0x5D);
    }

    fn emitRet(self: *@This()) !void {
        try self.appendByte(0xC3);
    }

    fn emitLeaR15RspPlus8(self: *@This()) !void {
        try self.appendBytes(&.{ 0x4C, 0x8D, 0x7C, 0x24, 0x08 });
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

    fn emitLoadRegFromSlot(self: *@This(), reg_index: usize, value_ref: InstRef) !void {
        switch (reg_index) {
            0 => try self.appendBytes(&.{ 0x48, 0x8B, 0xBC, 0x24 }), // rdi
            1 => try self.appendBytes(&.{ 0x48, 0x8B, 0xB4, 0x24 }), // rsi
            2 => try self.appendBytes(&.{ 0x48, 0x8B, 0x94, 0x24 }), // rdx
            3 => try self.appendBytes(&.{ 0x48, 0x8B, 0x8C, 0x24 }), // rcx
            4 => try self.appendBytes(&.{ 0x4C, 0x8B, 0x84, 0x24 }), // r8
            5 => try self.appendBytes(&.{ 0x4C, 0x8B, 0x8C, 0x24 }), // r9
            else => return error.UnsupportedRegister,
        }
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitStoreRegToSlot(self: *@This(), reg_index: usize, value_ref: InstRef) !void {
        switch (reg_index) {
            0 => try self.appendBytes(&.{ 0x48, 0x89, 0xBC, 0x24 }), // rdi
            1 => try self.appendBytes(&.{ 0x48, 0x89, 0xB4, 0x24 }), // rsi
            2 => try self.appendBytes(&.{ 0x48, 0x89, 0x94, 0x24 }), // rdx
            3 => try self.appendBytes(&.{ 0x48, 0x89, 0x8C, 0x24 }), // rcx
            4 => try self.appendBytes(&.{ 0x4C, 0x89, 0x84, 0x24 }), // r8
            5 => try self.appendBytes(&.{ 0x4C, 0x89, 0x8C, 0x24 }), // r9
            else => return error.UnsupportedRegister,
        }
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

    fn emitMovRdiFromArgv(self: *@This(), disp: u32) !void {
        try self.appendBytes(&.{ 0x49, 0x8B, 0xBF });
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

    fn emitLeaRaxSymbol(self: *@This(), symbol: u32) !void {
        try self.appendBytes(&.{ 0x48, 0x8D, 0x05 });
        try self.addRel32Fixup(symbol);
    }

    fn branchCopy(branch: ir_mod.Branch, block_params: []const ?InstRef) ?BranchCopy {
        const dst = block_params[branch.target] orelse return null;
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

    fn emitCallAndStore(self: *@This(), symbol: u32, out: InstRef) !void {
        try self.emitCallRel(symbol);
        try self.emitStoreRaxToSlot(out);
    }

    fn emitFunctionPrologue(self: *@This(), func: *const Function) !void {
        try self.emitPushRbp();
        try self.emitMovRbpRsp();

        const size = frameSize(func.next_value);
        if (size > 0) try self.emitSubRspImm32(size);

        for (func.param_values.items, 0..) |slot, idx| {
            try self.emitStoreRegToSlot(idx, slot);
        }
    }

    fn emitFunctionReturn(self: *@This(), value_ref: InstRef) !void {
        try self.emitLoadRaxFromSlot(value_ref);
        try self.emitMovRspRbp();
        try self.emitPopRbp();
        try self.emitRet();
    }

    fn emitValueInst(self: *@This(), value_inst: ir_mod.ValueInst, fn_layout: *const FunctionLayout) !void {
        switch (value_inst.op) {
            .iconst => |value| {
                try self.emitMovEaxImm32(value);
                try self.emitStoreRaxToSlot(value_inst.id);
            },
            .fconst => |value| {
                try self.emitMovEaxImmU32(@bitCast(value));
                try self.emitStoreRaxToSlot(value_inst.id);
            },
            .fn_addr => |fn_id| {
                const symbol = self.layoutFor(fn_id).symbol;
                try self.emitLeaRaxSymbol(symbol);
                try self.emitStoreRaxToSlot(value_inst.id);
            },
            .call => |call_info| {
                var idx: usize = 0;
                while (idx < call_info.argc) : (idx += 1) {
                    try self.emitLoadRegFromSlot(idx, call_info.args[idx]);
                }
                try self.emitLoadRaxFromSlot(call_info.callee);
                try self.emitCallRax();
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
                try self.emitCallRel(self.helperSymbol(.print_int));
                try self.emitStoreUnitValue(value_inst.id);
            },
            .printf => |value_ref| {
                try self.emitLoadXmm0FromSlot(value_ref);
                try self.emitCallRel(self.helperSymbol(.print_float32));
                try self.emitStoreUnitValue(value_inst.id);
            },
            .printb => |value_ref| {
                try self.emitLoadEaxFromSlot(value_ref);
                try self.emitCallRel(self.helperSymbol(.print_bool));
                try self.emitStoreUnitValue(value_inst.id);
            },
            .argi => |idx| {
                try self.emitMovRdiFromArgv(idx * 8);
                try self.emitCallAndStore(self.helperSymbol(.atoi), value_inst.id);
            },
            .store => |pair| {
                try self.emitLoadRaxFromSlot(pair.l);
                try self.emitStoreRaxToSlot(pair.r);
                try self.emitStoreUnitValue(value_inst.id);
            },
            .field_load => |fl| {
                try self.emitLoadRaxFromSlot(fl.base + fl.field_index);
                try self.emitStoreRaxToSlot(value_inst.id);
            },
        }
        _ = fn_layout;
    }

    fn emitBranch(self: *@This(), branch: ir_mod.Branch, block_symbols: []const u32, block_params: []const ?InstRef) !void {
        const maybe_copy = branchCopy(branch, block_params);
        if (maybe_copy) |copy| try self.emitCopySlot(copy.src, copy.dst);
        try self.emitJmp(block_symbols[branch.target]);
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

    fn emitBranchOnEaxNonZero(
        self: *@This(),
        then_branch: ir_mod.Branch,
        else_branch: ir_mod.Branch,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
    ) !void {
        try self.emitCmpEaxZero();

        const then_copy = branchCopy(then_branch, block_params);
        const else_copy = branchCopy(else_branch, block_params);
        const then_symbol = block_symbols[then_branch.target];
        const else_symbol = block_symbols[else_branch.target];

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

        const prep_symbol = try createSymbol(&self.symbols, self.gpa);
        try self.emitJe(prep_symbol);
        const then_copy_value = then_copy.?;
        try self.emitCopySlot(then_copy_value.src, then_copy_value.dst);
        try self.emitJmp(then_symbol);

        self.bindSymbol(prep_symbol);
        const else_copy_value = else_copy.?;
        try self.emitCopySlot(else_copy_value.src, else_copy_value.dst);
        try self.emitJmp(else_symbol);
    }

    fn emitPredicateBranch(
        self: *@This(),
        pbr: @FieldType(ir_mod.Terminator, "pbr"),
        block_symbols: []const u32,
        block_params: []const ?InstRef,
    ) !void {
        try self.emitPredicateValueToEax(pbr.pred);
        try self.emitBranchOnEaxNonZero(pbr.then_branch, pbr.else_branch, block_symbols, block_params);
    }

    fn emitTerm(
        self: *@This(),
        term: ir_mod.Terminator,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
    ) !void {
        switch (term) {
            .br => |branch| try self.emitBranch(branch, block_symbols, block_params),
            .pbr => |pbr| try self.emitPredicateBranch(pbr, block_symbols, block_params),
            .ret => |value_ref| try self.emitFunctionReturn(value_ref),
        }
    }

    fn emitBlock(
        self: *@This(),
        block: ir_mod.Block,
        symbol: u32,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
        fn_layout: *const FunctionLayout,
    ) !void {
        self.bindSymbol(symbol);
        for (block.insts.items) |value_inst| try self.emitValueInst(value_inst, fn_layout);
        const terminator = block.terminator orelse unreachable;
        try self.emitTerm(terminator, block_symbols, block_params);
    }

    fn emitFunction(self: *@This(), func: *const Function) !void {
        const layout = self.layoutFor(func.id);
        self.bindSymbol(layout.symbol);
        try self.emitFunctionPrologue(func);

        if (func.entry != 0) {
            try self.emitJmp(layout.block_symbols[func.entry]);
        }

        var block_params = try self.gpa.alloc(?InstRef, func.blocks.items.len);
        defer self.gpa.free(block_params);
        for (func.blocks.items) |block| {
            block_params[block.id] = block.param;
        }

        for (func.blocks.items, 0..) |block, block_idx| {
            try self.emitBlock(block, layout.block_symbols[block_idx], layout.block_symbols, block_params, layout);
        }
    }

    fn emitStart(self: *@This()) !void {
        self.bindSymbol(self.start_symbol);
        try self.emitLeaR15RspPlus8();
        const entry_layout = self.layoutFor(self.prog.entry);
        try self.emitCallRel(entry_layout.symbol);
        try self.emitMovEdiEax();
        try self.emitMovEaxImm32(60);
        try self.emitSyscall();
    }

    fn appendHelpers(self: *@This()) !void {
        for (helpers.all_helpers, 0..) |helper, idx| {
            self.bindSymbol(self.helper_symbols[idx]);
            try self.appendBytes(helper.blob.slice());
        }
    }

    fn emitProgram(self: *@This()) ![]const u8 {
        try self.emitStart();
        for (self.prog.functions.items) |*func| {
            try self.emitFunction(func);
        }
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
