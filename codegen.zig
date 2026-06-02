const std = @import("std");
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
    program_code_len: u32 = 0,
    slot_addr_map: std.AutoHashMap(InstRef, InstRef),
    reg_eax: ?InstRef,
    reg_eax_dirty: bool,
    reg_ebx: ?InstRef,
    reg_ebx_dirty: bool,
    use_counts: std.AutoHashMap(InstRef, u32),
    const_values: std.AutoHashMap(InstRef, i32),

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

    const JccCond = enum(u8) {
        b = 0x82,
        be = 0x86,
        a = 0x87,
        ae = 0x83,
        l = 0x8C,
        g = 0x8F,
        le = 0x8E,
        ge = 0x8D,
        e = 0x84,
        ne = 0x85,
        p = 0x8A,
        np = 0x8B,
    };

    const BranchCopy = struct {
        src: InstRef,
        dst: InstRef,
        width: u32,
    };

    const CallKind = union(enum) {
        indirect: InstRef,
        direct: FuncId,
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

        var slot_addr_map = std.AutoHashMap(InstRef, InstRef).init(gpa);
        errdefer slot_addr_map.deinit();

        var use_counts = std.AutoHashMap(InstRef, u32).init(gpa);
        errdefer use_counts.deinit();

        var const_values = std.AutoHashMap(InstRef, i32).init(gpa);
        errdefer const_values.deinit();

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
            .slot_addr_map = slot_addr_map,
            .reg_eax = null,
            .reg_eax_dirty = false,
            .reg_ebx = null,
            .reg_ebx_dirty = false,
            .use_counts = use_counts,
            .const_values = const_values,
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
        self.slot_addr_map.deinit();
        self.use_counts.deinit();
        self.const_values.deinit();
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

    fn appendLeU64(self: *@This(), value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
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

    fn emitJcc(self: *@This(), cond: JccCond, symbol: u32) !void {
        try self.appendBytes(&.{ 0x0F, @intFromEnum(cond) });
        try self.addRel32Fixup(symbol);
    }

    fn invertJcc(cond: JccCond) JccCond {
        return switch (cond) {
            .b => .ae,
            .be => .a,
            .a => .be,
            .ae => .b,
            .l => .ge,
            .g => .le,
            .le => .g,
            .ge => .l,
            .e => .ne,
            .ne => .e,
            .p => .np,
            .np => .p,
        };
    }

    fn emitPushRbp(self: *@This()) !void {
        try self.appendByte(0x55);
    }

    fn emitMovRbpRsp(self: *@This()) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0xE5 });
    }

    fn emitLeave(self: *@This()) !void {
        try self.appendByte(0xC9);
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

    fn emitMovEbxImm32(self: *@This(), value: i32) !void {
        try self.appendByte(0xBB);
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

    fn emitLoadRaxFromRaxOffset32(self: *@This(), offset: u32) !void {
        try self.appendBytes(&.{ 0x48, 0x8B, 0x80 });
        try self.appendLeU32(offset);
    }

    fn emitStoreRaxToRdxOffset32(self: *@This(), offset: u32) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0x82 });
        try self.appendLeU32(offset);
    }

    fn emitLoadRegFromSlot(self: *@This(), reg_index: usize, value_ref: InstRef) !void {
        const prefixes = [_][]const u8{
            &.{ 0x48, 0x8B, 0xBC, 0x24 },
            &.{ 0x48, 0x8B, 0xB4, 0x24 },
            &.{ 0x48, 0x8B, 0x94, 0x24 },
            &.{ 0x48, 0x8B, 0x8C, 0x24 },
            &.{ 0x4C, 0x8B, 0x84, 0x24 },
            &.{ 0x4C, 0x8B, 0x8C, 0x24 },
        };
        if (reg_index >= prefixes.len) return error.UnsupportedRegister;
        try self.appendBytes(prefixes[reg_index]);
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitStoreRegToSlot(self: *@This(), reg_index: usize, value_ref: InstRef) !void {
        const prefixes = [_][]const u8{
            &.{ 0x48, 0x89, 0xBC, 0x24 },
            &.{ 0x48, 0x89, 0xB4, 0x24 },
            &.{ 0x48, 0x89, 0x94, 0x24 },
            &.{ 0x48, 0x89, 0x8C, 0x24 },
            &.{ 0x4C, 0x89, 0x84, 0x24 },
            &.{ 0x4C, 0x89, 0x8C, 0x24 },
        };
        if (reg_index >= prefixes.len) return error.UnsupportedRegister;
        try self.appendBytes(prefixes[reg_index]);
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitLeaRegFromSlot(self: *@This(), reg_index: usize, slot: InstRef) !void {
        const prefixes = [_][]const u8{
            &.{ 0x48, 0x8D, 0xBC, 0x24 },
            &.{ 0x48, 0x8D, 0xB4, 0x24 },
            &.{ 0x48, 0x8D, 0x94, 0x24 },
            &.{ 0x48, 0x8D, 0x8C, 0x24 },
            &.{ 0x4C, 0x8D, 0x84, 0x24 },
            &.{ 0x4C, 0x8D, 0x8C, 0x24 },
        };
        if (reg_index >= prefixes.len) return error.UnsupportedRegister;
        try self.appendBytes(prefixes[reg_index]);
        try self.appendLeU32(slotOffset(slot));
    }

    fn emitMovRegFromEax(self: *@This(), reg_index: usize) !void {
        const prefixes = [_][]const u8{
            &.{ 0x48, 0x89, 0xC7 },  // mov rdi, rax
            &.{ 0x48, 0x89, 0xC6 },  // mov rsi, rax
            &.{ 0x48, 0x89, 0xC2 },  // mov rdx, rax
            &.{ 0x48, 0x89, 0xC1 },  // mov rcx, rax
            &.{ 0x4C, 0x89, 0xC0 },  // mov r8, rax
            &.{ 0x4C, 0x89, 0xC8 },  // mov r9, rax
        };
        if (reg_index >= prefixes.len) return error.UnsupportedRegister;
        try self.appendBytes(prefixes[reg_index]);
    }

    fn emitXmmFromSlot(self: *@This(), comptime store: bool, comptime reg: u8, slot: InstRef) !void {
        try self.appendBytes(&.{ 0xF3, 0x0F, if (store) @as(u8, 0x11) else @as(u8, 0x10), 0x84 | (reg << 3), 0x24 });
        try self.appendLeU32(slotOffset(slot));
    }

    fn emitStoreRaxToSlot(self: *@This(), value_ref: InstRef) !void {
        try self.appendBytes(&.{ 0x48, 0x89, 0x84, 0x24 });
        try self.appendLeU32(slotOffset(value_ref));
    }

    fn emitStoreRaxToR10Offset32(self: *@This(), offset: u32) !void {
        try self.appendBytes(&.{ 0x49, 0x89, 0x82 });
        try self.appendLeU32(offset);
    }

    fn emitLeaRaxRspOffset(self: *@This(), offset: u32) !void {
        try self.appendBytes(&.{ 0x48, 0x8D, 0x84, 0x24 });
        try self.appendLeU32(offset);
    }

    fn emitLeaR10RspOffset(self: *@This(), offset: u32) !void {
        try self.appendBytes(&.{ 0x4C, 0x8D, 0x94, 0x24 });
        try self.appendLeU32(offset);
    }

    fn forEachInstRef(self: *BinaryEmitter, inst: ir_mod.Inst, comptime apply: fn (*BinaryEmitter, InstRef) void) void {
        switch (inst) {
            .addi, .subi, .muli, .divi, .addf, .subf, .mulf, .divf => |p| {
                apply(self, p.l);
                apply(self, p.r);
            },
            .store => |p| apply(self, p.l),
            .call => |c| {
                apply(self, c.callee);
                var i: usize = 0;
                while (i < c.argc) : (i += 1) apply(self, c.args[i]);
            },
            .direct_call => |dc| {
                var i: usize = 0;
                while (i < dc.argc) : (i += 1) apply(self, dc.args[i]);
            },
            .printi, .printf, .printb => |v| apply(self, v),
            .load_ptr => |l| apply(self, l.ptr),
            .store_ptr => |st| {
                apply(self, st.src);
                apply(self, st.ptr);
            },
            .field_load => |fl| apply(self, fl.base + fl.field_index),
            .iconst, .fconst, .fn_addr, .argi, .slot_addr => {},
        }
    }

    fn countUse(self: *BinaryEmitter, ref: InstRef) void {
        const entry = self.use_counts.getOrPut(ref) catch return;
        if (entry.found_existing) entry.value_ptr.* += 1 else entry.value_ptr.* = 1;
    }

    fn decUse(self: *BinaryEmitter, ref: InstRef) void {
        if (self.use_counts.getPtr(ref)) |ptr| {
            if (ptr.* > 0) ptr.* -= 1;
        }
    }

    fn countInstOperands(self: *BinaryEmitter, inst: ir_mod.Inst) void {
        const W = struct {
            fn visit(s: *BinaryEmitter, r: InstRef) void { s.countUse(r); }
        };
        self.forEachInstRef(inst, W.visit);
    }

    fn decrementUses(self: *BinaryEmitter, inst: ir_mod.Inst) void {
        const W = struct {
            fn visit(s: *BinaryEmitter, r: InstRef) void { s.decUse(r); }
        };
        self.forEachInstRef(inst, W.visit);
    }

    fn emitPrintResult(self: *BinaryEmitter, id: InstRef) !void {
        try self.emitMovEaxImm32(0);
        if ((self.use_counts.get(id) orelse 0) > 0) {
            try self.emitStoreRaxToSlot(id);
        }
        self.setEaxClean(id);
    }

    fn emitCopySlot(self: *@This(), src_ref: InstRef, dst_ref: InstRef) !void {
        try self.loadEax(src_ref);
        try self.emitStoreRaxToSlot(dst_ref);
    }

    fn refUseCount(self: *const BinaryEmitter, ref: InstRef) u32 {
        return self.use_counts.get(ref) orelse 0;
    }

    fn shouldSpillRef(self: *const BinaryEmitter, ref: InstRef, kept_uses: u32) bool {
        if (self.const_values.contains(ref)) return false;
        return self.refUseCount(ref) > kept_uses;
    }

    fn flushEax(self: *@This()) !void {
        if (self.reg_eax) |ref| {
            if (self.reg_eax_dirty and self.shouldSpillRef(ref, 0)) {
                try self.emitStoreRaxToSlot(ref);
            }
            self.reg_eax = null;
            self.reg_eax_dirty = false;
        }
    }

    fn loadEax(self: *@This(), value_ref: InstRef) !void {
        if (self.reg_eax == value_ref) return;
        if (self.reg_eax) |old| {
            if (self.reg_eax_dirty and self.shouldSpillRef(old, 0)) {
                try self.emitStoreRaxToSlot(old);
            }
            self.reg_eax = null;
            self.reg_eax_dirty = false;
        }
        if (self.const_values.get(value_ref)) |imm| {
            try self.emitMovEaxImm32(imm);
        } else {
            try self.emitLoadEaxFromSlot(value_ref);
        }
        self.reg_eax = value_ref;
        self.reg_eax_dirty = false;
    }

    fn setEax(self: *@This(), value_ref: InstRef) void {
        self.reg_eax = value_ref;
        self.reg_eax_dirty = true;
    }

    fn setEaxClean(self: *@This(), value_ref: InstRef) void {
        self.reg_eax = value_ref;
        self.reg_eax_dirty = false;
    }

    fn flushEbx(self: *@This()) void {
        self.reg_ebx = null;
        self.reg_ebx_dirty = false;
    }

    fn loadEbx(self: *@This(), value_ref: InstRef) !void {
        if (self.reg_ebx == value_ref) return;
        self.flushEbx();
        if (self.const_values.get(value_ref)) |imm| {
            try self.emitMovEbxImm32(imm);
        } else {
            try self.emitLoadEbxFromSlot(value_ref);
        }
        self.reg_ebx = value_ref;
        self.reg_ebx_dirty = false;
    }

    fn setEbx(self: *@This(), value_ref: InstRef) void {
        self.reg_ebx = value_ref;
        self.reg_ebx_dirty = true;
    }

    fn setEbxClean(self: *@This(), value_ref: InstRef) void {
        self.reg_ebx = value_ref;
        self.reg_ebx_dirty = false;
    }

    fn emitMovRdiFromArgv(self: *@This(), disp: u32) !void {
        try self.appendBytes(&.{ 0x49, 0x8B, 0xBF });
        try self.appendLeU32(disp);
    }

    fn emitMovEbxEax(self: *@This()) !void {
        try self.appendBytes(&.{ 0x89, 0xC3 });
    }

    const AluOp = enum { add, sub, cmp };

    fn emitAluEaxImm32(self: *@This(), op: AluOp, value: i32) !void {
        try self.appendByte(switch (op) { .add => 0x05, .sub => 0x2D, .cmp => 0x3D });
        try self.appendLeU32(@bitCast(value));
    }

    fn emitAluEaxEbx(self: *@This(), op: AluOp) !void {
        const opcode: u8 = switch (op) { .add => 0x01, .sub => 0x29, .cmp => 0x39 };
        try self.appendBytes(&.{ opcode, 0xD8 });
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

    fn emitTestEaxEax(self: *@This()) !void {
        try self.appendBytes(&.{ 0x85, 0xC0 });
    }

    fn emitUcomissXmm0Xmm1(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0x2E, 0xC1 });
    }

    fn emitFloatBinOp(self: *@This(), opcode: u8) !void {
        try self.appendBytes(&.{ 0xF3, 0x0F, opcode, 0xC1 });
    }

    fn emitSetcc(self: *@This(), cond: SetccCond, comptime bl: bool) !void {
        try self.appendBytes(&.{ 0x0F, @intFromEnum(cond), if (bl) 0xC3 else 0xC0 });
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

    fn branchCopy(branch: ir_mod.Branch, block_params: []const ?InstRef, block_param_widths: []const u32) ?BranchCopy {
        const dst = block_params[branch.target] orelse return null;
        const width = block_param_widths[branch.target];
        if (width == 0) return null;
        const src = branch.arg orelse unreachable;
        if (src == dst) return null;
        return .{ .src = src, .dst = dst, .width = width };
    }

    fn emitCopySlots(self: *@This(), src: InstRef, dst: InstRef, width: u32) !void {
        var slot_index: u32 = 0;
        while (slot_index < width) : (slot_index += 1) {
            try self.emitCopySlot(src + slot_index, dst + slot_index);
        }
    }

    fn emitBinaryArithmeticInt(self: *@This(), pair: InstPair, opcode: enum { add, sub, imul }, out: InstRef) !void {
        if (self.const_values.get(pair.r)) |imm| {
            try self.loadEax(pair.l);
            switch (opcode) {
                .add => try self.emitAluEaxImm32(.add, imm),
                .sub => try self.emitAluEaxImm32(.sub, imm),
                .imul => {
                    try self.emitLoadEbxFromSlot(pair.r);
                    try self.emitImulEaxEbx();
                },
            }
        } else if (self.reg_eax == pair.r) {
            try self.emitMovEbxEax();
            self.reg_ebx = pair.r;
            self.reg_ebx_dirty = false;
            self.reg_eax = null;
            self.reg_eax_dirty = false;
            try self.loadEax(pair.l);
            switch (opcode) {
                .add => try self.emitAluEaxEbx(.add),
                .sub => try self.emitAluEaxEbx(.sub),
                .imul => try self.emitImulEaxEbx(),
            }
        } else {
            try self.loadEbx(pair.r);
            try self.loadEax(pair.l);
            switch (opcode) {
                .add => try self.emitAluEaxEbx(.add),
                .sub => try self.emitAluEaxEbx(.sub),
                .imul => try self.emitImulEaxEbx(),
            }
        }
        self.setEax(out);
    }

    fn emitBinaryArithmeticFloat(self: *@This(), pair: InstPair, opcode: u8, out: InstRef) !void {
        try self.emitXmmFromSlot(false, 0, pair.l);
        try self.emitXmmFromSlot(false, 1, pair.r);
        try self.emitFloatBinOp(opcode);
        try self.emitXmmFromSlot(true, 0, out);
    }

    fn emitBinaryDivInt(self: *@This(), pair: InstPair, out: InstRef) !void {
        if (self.reg_eax == pair.r) {
            try self.emitMovEbxEax();
            self.reg_ebx = pair.r;
            self.reg_ebx_dirty = false;
            self.reg_eax = null;
            self.reg_eax_dirty = false;
        } else {
            try self.loadEbx(pair.r);
        }
        try self.loadEax(pair.l);
        try self.emitCdq();
        try self.emitIdivEbx();
        self.setEax(out);
    }

    fn emitBinaryDivFloat(self: *@This(), pair: InstPair, out: InstRef) !void {
        try self.emitXmmFromSlot(false, 0, pair.l);
        try self.emitXmmFromSlot(false, 1, pair.r);
        try self.emitFloatBinOp(0x5E);
        try self.emitXmmFromSlot(true, 0, out);
    }

    fn emitCompareIntToEax(self: *@This(), pair: InstPair, cond: SetccCond) !void {
        try self.emitCompareIntFlags(pair);
        try self.emitSetcc(cond, false);
        try self.emitMovzxEaxAl();
    }

    fn emitCompareIntFlags(self: *@This(), pair: InstPair) !void {
        if (self.const_values.get(pair.r)) |imm| {
            try self.loadEax(pair.l);
            try self.emitAluEaxImm32(.cmp, imm);
        } else if (self.reg_eax == pair.r) {
            try self.emitMovEbxEax();
            self.reg_ebx = pair.r;
            self.reg_ebx_dirty = false;
            self.reg_eax = null;
            self.reg_eax_dirty = false;
            try self.loadEax(pair.l);
            try self.emitAluEaxEbx(.cmp);
        } else {
            try self.loadEbx(pair.r);
            try self.loadEax(pair.l);
            try self.emitAluEaxEbx(.cmp);
        }
    }

    fn emitCompareFloatOrderedToEax(self: *@This(), pair: InstPair, cond: SetccCond) !void {
        try self.emitXmmFromSlot(false, 0, pair.l);
        try self.emitXmmFromSlot(false, 1, pair.r);
        try self.emitUcomissXmm0Xmm1();
        try self.emitSetcc(cond, false);
        try self.emitSetcc(.np, true);
        try self.emitAndAlBl();
        try self.emitMovzxEaxAl();
    }

    fn emitCompareFloatNotEqualToEax(self: *@This(), pair: InstPair) !void {
        try self.emitXmmFromSlot(false, 0, pair.l);
        try self.emitXmmFromSlot(false, 1, pair.r);
        try self.emitUcomissXmm0Xmm1();
        try self.emitSetcc(.ne, false);
        try self.emitSetcc(.p, true);
        try self.emitOrAlBl();
        try self.emitMovzxEaxAl();
    }

    fn emitCallAndStore(self: *@This(), symbol: u32, out: InstRef) !void {
        try self.emitCallRel(symbol);
        try self.emitStoreRaxToSlot(out);
    }

    fn emitLoadCallArg(self: *BinaryEmitter, reg_index: usize, value_ref: InstRef) !void {
        if (self.const_values.get(value_ref)) |imm| {
            try self.emitMovEaxImm32(imm);
            try self.emitMovRegFromEax(reg_index);
        } else {
            try self.emitLoadRegFromSlot(reg_index, value_ref);
        }
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

    fn callOperandUseCount(kind: CallKind, args: []const InstRef, argc: usize, ref: InstRef) u32 {
        var count: u32 = 0;
        if (kind == .indirect and kind.indirect == ref) count += 1;
        var idx: usize = 0;
        while (idx < argc) : (idx += 1) {
            if (args[idx] == ref) count += 1;
        }
        return count;
    }

    fn emitCallLike(self: *BinaryEmitter, kind: CallKind, args: []const InstRef, argc: usize, ret_slots: u8, result_id: InstRef) !void {
        var handled: [ir_mod.MaxCallArgs]bool = [_]bool{false} ** ir_mod.MaxCallArgs;
        var idx: usize = 0;
        while (idx < argc) : (idx += 1) {
            if (self.reg_eax == args[idx]) {
                try self.emitMovRegFromEax(idx);
                handled[idx] = true;
            } else if (self.slot_addr_map.get(args[idx])) |slot| {
                try self.emitLeaRegFromSlot(idx, slot);
                handled[idx] = true;
            }
        }
        if (self.reg_eax) |ref| {
            if (self.reg_eax_dirty) {
                const kept_uses = callOperandUseCount(kind, args, argc, ref);
                if (self.shouldSpillRef(ref, kept_uses)) {
                    try self.emitStoreRaxToSlot(ref);
                }
            }
            self.reg_eax = null;
            self.reg_eax_dirty = false;
        }
        var j: usize = 0;
        while (j < argc) : (j += 1) {
            if (!handled[j]) {
                try self.emitLoadCallArg(j, args[j]);
            }
        }
        if (ret_slots > 1) {
            try self.emitLeaR10RspOffset(slotOffset(result_id));
        }
        switch (kind) {
            .indirect => |callee_ref| {
                try self.emitLoadRaxFromSlot(callee_ref);
                try self.emitCallRax();
            },
            .direct => |fn_id| {
                try self.emitCallRel(self.layoutFor(fn_id).symbol);
            },
        }
        if (ret_slots == 1) {
            self.setEax(result_id);
        }
    }

    fn emitFunctionReturn(self: *@This(), value_ref: InstRef, ret_slots: u32) !void {
        if (ret_slots == 0) {
            try self.flushEax();
            try self.emitMovEaxImm32(0);
        } else if (ret_slots == 1 and self.reg_eax == value_ref) {
            self.reg_eax_dirty = false;
        } else if (ret_slots > 1) {
            try self.flushEax();
            var i: u32 = 0;
            while (i < ret_slots) : (i += 1) {
                try self.emitLoadRaxFromSlot(value_ref + i);
                try self.emitStoreRaxToR10Offset32(i * 8);
            }
        } else {
            try self.flushEax();
            if (self.const_values.get(value_ref)) |imm| {
                try self.emitMovEaxImm32(imm);
            } else {
                try self.emitLoadRaxFromSlot(value_ref);
            }
        }
        try self.emitLeave();
        try self.emitRet();
    }

    fn emitValueInst(self: *@This(), value_inst: ir_mod.ValueInst) !void {
        switch (value_inst.op) {
            .iconst => |value| {
                try self.const_values.put(value_inst.id, value);
            },
            .fconst => |value| {
                try self.flushEax();
                try self.emitMovEaxImm32(@as(i32, @bitCast(value)));
                self.setEax(value_inst.id);
            },
            .fn_addr => |fn_id| {
                try self.flushEax();
                const symbol = self.layoutFor(fn_id).symbol;
                try self.emitLeaRaxSymbol(symbol);
                self.setEax(value_inst.id);
            },
            .call => |call_info| try self.emitCallLike(.{ .indirect = call_info.callee }, call_info.args[0..], call_info.argc, call_info.ret_slots, value_inst.id),
            .direct_call => |dc| try self.emitCallLike(.{ .direct = dc.callee }, dc.args[0..], dc.argc, dc.ret_slots, value_inst.id),
            .addi => |pair| try self.emitBinaryArithmeticInt(pair, .add, value_inst.id),
            .addf => |pair| try self.emitBinaryArithmeticFloat(pair, 0x58, value_inst.id),
            .subi => |pair| try self.emitBinaryArithmeticInt(pair, .sub, value_inst.id),
            .subf => |pair| try self.emitBinaryArithmeticFloat(pair, 0x5C, value_inst.id),
            .muli => |pair| try self.emitBinaryArithmeticInt(pair, .imul, value_inst.id),
            .mulf => |pair| try self.emitBinaryArithmeticFloat(pair, 0x59, value_inst.id),
            .divi => |pair| try self.emitBinaryDivInt(pair, value_inst.id),
            .divf => |pair| try self.emitBinaryDivFloat(pair, value_inst.id),
            .printi => |value_ref| {
                try self.loadEax(value_ref);
                try self.emitCallRel(self.helperSymbol(.print_int));
                try self.emitPrintResult(value_inst.id);
            },
            .printf => |value_ref| {
                try self.flushEax();
                try self.emitXmmFromSlot(false, 0, value_ref);
                try self.emitCallRel(self.helperSymbol(.print_float32));
                try self.emitPrintResult(value_inst.id);
            },
            .printb => |value_ref| {
                try self.loadEax(value_ref);
                try self.emitCallRel(self.helperSymbol(.print_bool));
                try self.emitPrintResult(value_inst.id);
            },
            .argi => |idx| {
                try self.flushEax();
                try self.emitMovRdiFromArgv(idx * 8);
                try self.emitCallAndStore(self.helperSymbol(.atoi), value_inst.id);
                self.setEaxClean(value_inst.id);
            },
            .store => |pair| {
                try self.loadEax(pair.l);
                try self.emitStoreRaxToSlot(pair.r);
                try self.emitPrintResult(value_inst.id);
            },
            .field_load => |fl| {
                try self.flushEax();
                try self.emitLoadRaxFromSlot(fl.base + fl.field_index);
                self.setEax(value_inst.id);
            },
            .slot_addr => |slot| {
                try self.flushEax();
                try self.emitLeaRaxRspOffset(slotOffset(slot));
                try self.emitStoreRaxToSlot(value_inst.id);
                self.setEaxClean(value_inst.id);
                try self.slot_addr_map.put(value_inst.id, slot);
            },
            .load_ptr => |load| {
                try self.flushEax();
                try self.emitLoadRaxFromSlot(load.ptr);
                try self.emitLoadRaxFromRaxOffset32(load.offset_slots * 8);
                self.setEax(value_inst.id);
            },
            .store_ptr => |st| {
                try self.loadEax(st.src);
                try self.emitLoadRegFromSlot(2, st.ptr);
                try self.emitStoreRaxToRdxOffset32(st.offset_slots * 8);
                try self.emitPrintResult(value_inst.id);
            },
        }
    }

    fn emitBranch(
        self: *@This(),
        branch: ir_mod.Branch,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
        block_param_widths: []const u32,
    ) !void {
        try self.flushEax();
        const maybe_copy = branchCopy(branch, block_params, block_param_widths);
        if (maybe_copy) |copy| try self.emitCopySlots(copy.src, copy.dst, copy.width);
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
        block_param_widths: []const u32,
        then_fallthrough: bool,
    ) !void {
        try self.emitTestEaxEax();

        const then_copy = branchCopy(then_branch, block_params, block_param_widths);
        const else_copy = branchCopy(else_branch, block_params, block_param_widths);
        const then_symbol = block_symbols[then_branch.target];
        const else_symbol = block_symbols[else_branch.target];

        if (then_copy == null and else_copy == null) {
            if (then_fallthrough) {
                try self.emitJe(else_symbol);
            } else {
                try self.emitJne(then_symbol);
                try self.emitJmp(else_symbol);
            }
            return;
        }

        if (then_copy != null and else_copy == null) {
            try self.emitJne(then_symbol);
            const copy = then_copy.?;
            try self.emitCopySlots(copy.src, copy.dst, copy.width);
            try self.emitJmp(then_symbol);
            return;
        }

        if (then_copy == null and else_copy != null) {
            try self.emitJe(else_symbol);
            const copy = else_copy.?;
            try self.emitCopySlots(copy.src, copy.dst, copy.width);
            try self.emitJmp(else_symbol);
            return;
        }

        const prep_symbol = try createSymbol(&self.symbols, self.gpa);
        try self.emitJne(then_symbol);
        const prep2_symbol = try createSymbol(&self.symbols, self.gpa);
        try self.emitJmp(prep2_symbol);

        self.bindSymbol(prep_symbol);
        const then_copy_value = then_copy.?;
        try self.emitCopySlots(then_copy_value.src, then_copy_value.dst, then_copy_value.width);
        try self.emitJmp(then_symbol);

        self.bindSymbol(prep2_symbol);
        const else_copy_value = else_copy.?;
        try self.emitCopySlots(else_copy_value.src, else_copy_value.dst, else_copy_value.width);
        try self.emitJmp(else_symbol);
    }

    fn emitBranchOnCondition(
        self: *@This(),
        cond: JccCond,
        then_branch: ir_mod.Branch,
        else_branch: ir_mod.Branch,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
        block_param_widths: []const u32,
        then_fallthrough: bool,
    ) !void {
        const then_copy = branchCopy(then_branch, block_params, block_param_widths);
        const else_copy = branchCopy(else_branch, block_params, block_param_widths);
        const then_symbol = block_symbols[then_branch.target];
        const else_symbol = block_symbols[else_branch.target];

        if (then_copy == null and else_copy == null) {
            if (then_fallthrough) {
                try self.emitJcc(invertJcc(cond), else_symbol);
            } else {
                try self.emitJcc(cond, then_symbol);
                try self.emitJmp(else_symbol);
            }
            return;
        }

        if (then_copy != null and else_copy == null) {
            const prep_symbol = try createSymbol(&self.symbols, self.gpa);
            try self.emitJcc(cond, prep_symbol);
            try self.emitJmp(else_symbol);
            self.bindSymbol(prep_symbol);
            const then_copy_value = then_copy.?;
            try self.emitCopySlots(then_copy_value.src, then_copy_value.dst, then_copy_value.width);
            try self.emitJmp(then_symbol);
            return;
        }

        if (then_copy == null and else_copy != null) {
            try self.emitJcc(cond, then_symbol);
            const else_copy_value = else_copy.?;
            try self.emitCopySlots(else_copy_value.src, else_copy_value.dst, else_copy_value.width);
            try self.emitJmp(else_symbol);
            return;
        }

        const then_prep_symbol = try createSymbol(&self.symbols, self.gpa);
        try self.emitJcc(cond, then_prep_symbol);
        const else_copy_value = else_copy.?;
        try self.emitCopySlots(else_copy_value.src, else_copy_value.dst, else_copy_value.width);
        try self.emitJmp(else_symbol);
        self.bindSymbol(then_prep_symbol);
        const then_copy_value = then_copy.?;
        try self.emitCopySlots(then_copy_value.src, then_copy_value.dst, then_copy_value.width);
        try self.emitJmp(then_symbol);
    }

    fn emitPredicateBranch(
        self: *@This(),
        pbr: @FieldType(ir_mod.Terminator, "pbr"),
        block_symbols: []const u32,
        block_params: []const ?InstRef,
        block_param_widths: []const u32,
        then_fallthrough: bool,
    ) !void {
        const maybe_cond: ?JccCond = switch (pbr.pred.op) {
            .lti => .l,
            .gti => .g,
            .lei => .le,
            .gei => .ge,
            .eqi, .eqb => .e,
            .nei, .neb => .ne,
            else => null,
        };
        if (maybe_cond) |cond| {
            try self.emitCompareIntFlags(pbr.pred.pair);
            try self.emitBranchOnCondition(cond, pbr.then_branch, pbr.else_branch, block_symbols, block_params, block_param_widths, then_fallthrough);
            return;
        }
        try self.emitPredicateValueToEax(pbr.pred);
        try self.emitBranchOnEaxNonZero(pbr.then_branch, pbr.else_branch, block_symbols, block_params, block_param_widths, then_fallthrough);
    }

    fn emitTerm(
        self: *@This(),
        term: ir_mod.Terminator,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
        block_param_widths: []const u32,
        ret_slots: u32,
        then_fallthrough: bool,
    ) !void {
        switch (term) {
            .br => |branch| try self.emitBranch(branch, block_symbols, block_params, block_param_widths),
            .pbr => |pbr| try self.emitPredicateBranch(pbr, block_symbols, block_params, block_param_widths, then_fallthrough),
            .ret => |value_ref| try self.emitFunctionReturn(value_ref, ret_slots),
        }
    }

    fn emitBlock(
        self: *@This(),
        block: ir_mod.Block,
        symbol: u32,
        block_symbols: []const u32,
        block_params: []const ?InstRef,
        block_param_widths: []const u32,
        ret_slots: u32,
        then_fallthrough: bool,
    ) !void {
        self.bindSymbol(symbol);
        try self.flushEax();
        self.flushEbx();
        self.use_counts.clearRetainingCapacity();
        self.const_values.clearRetainingCapacity();
        for (block.insts.items) |vinst| self.countInstOperands(vinst.op);
        const terminator = block.terminator orelse unreachable;
        switch (terminator) {
            .br => |branch| {
                if (branch.arg) |arg| {
                    const width = block_param_widths[branch.target];
                    var i: u32 = 0;
                    while (i < width) : (i += 1) self.countUse(arg + i);
                }
            },
            .pbr => |pbr| {
                self.countUse(pbr.pred.pair.l);
                self.countUse(pbr.pred.pair.r);
                if (pbr.then_branch.arg) |arg| {
                    const width = block_param_widths[pbr.then_branch.target];
                    var i: u32 = 0;
                    while (i < width) : (i += 1) self.countUse(arg + i);
                }
                if (pbr.else_branch.arg) |arg| {
                    const width = block_param_widths[pbr.else_branch.target];
                    var i: u32 = 0;
                    while (i < width) : (i += 1) self.countUse(arg + i);
                }
            },
            .ret => |value_ref| {
                var i: u32 = 0;
                while (i < ret_slots) : (i += 1) self.countUse(value_ref + i);
            },
        }
        for (block.insts.items) |value_inst| {
            try self.emitValueInst(value_inst);
            self.decrementUses(value_inst.op);
        }
        try self.emitTerm(terminator, block_symbols, block_params, block_param_widths, ret_slots, then_fallthrough);
    }

    fn computeBlockOrder(self: *@This(), func: *const Function) ![]u32 {
        const n = func.blocks.items.len;
        var order = try std.ArrayList(u32).initCapacity(self.gpa, n);
        errdefer order.deinit(self.gpa);
        var visited = try self.gpa.alloc(bool, n);
        defer self.gpa.free(visited);
        for (visited) |*v| v.* = false;

        var stack = try std.ArrayList(u32).initCapacity(self.gpa, n);
        defer stack.deinit(self.gpa);
        try stack.append(self.gpa, func.entry);

        while (stack.items.len > 0) {
            const bid: usize = @intCast(stack.pop().?);
            if (visited[bid]) continue;
            visited[bid] = true;
            try order.append(self.gpa, @intCast(bid));

            const block = &func.blocks.items[bid];
            const term = block.terminator orelse continue;
            switch (term) {
                .pbr => |pbr| {
                    try stack.append(self.gpa, pbr.else_branch.target);
                    try stack.append(self.gpa, pbr.then_branch.target);
                },
                .br => |br| {
                    try stack.append(self.gpa, br.target);
                },
                .ret => {},
            }
        }

        for (0..n) |i| {
            if (!visited[i]) try order.append(self.gpa, @intCast(i));
        }

        return order.toOwnedSlice(self.gpa);
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
        var block_param_widths = try self.gpa.alloc(u32, func.blocks.items.len);
        defer self.gpa.free(block_param_widths);
        for (func.blocks.items) |block| {
            block_params[block.id] = block.param;
            block_param_widths[block.id] = block.param_width;
        }

        const emit_order = try self.computeBlockOrder(func);
        defer self.gpa.free(emit_order);
        for (emit_order, 0..) |block_idx, pos| {
            const blk = func.blocks.items[block_idx];
            const next_is_then = if (pos + 1 < emit_order.len) blk: {
                const term = blk.terminator orelse break :blk false;
                const then_target = switch (term) {
                    .pbr => |pbr| pbr.then_branch.target,
                    else => break :blk false,
                };
                break :blk then_target == emit_order[pos + 1];
            } else false;
            try self.emitBlock(blk, layout.block_symbols[block_idx], layout.block_symbols, block_params, block_param_widths, func.ret_slots, next_is_then);
        }
    }

    fn emitStart(self: *@This()) !void {
        if (self.prog.entry >= self.function_layouts.len) return error.InvalidEntryFunction;
        self.bindSymbol(self.start_symbol);
        try self.emitLeaR15RspPlus8();

        const entry_fn = &self.prog.functions.items[self.prog.entry];
        const ret_slot_count: u32 = entry_fn.ret_slots;
        if (ret_slot_count > 1) {
            try self.emitSubRspImm32(ret_slot_count * 8);
            try self.emitLeaR10RspOffset(0);
        }

        const entry_layout = self.layoutFor(self.prog.entry);
        try self.emitCallRel(entry_layout.symbol);

        try self.flushEax();
        if (ret_slot_count == 0) {
            try self.emitMovEaxImm32(0);
            try self.emitMovEdiEax();
        } else if (ret_slot_count == 1) {
            try self.emitMovEdiEax();
        } else {
            try self.emitLoadEaxFromSlot(0);
            try self.emitMovEdiEax();
        }
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
        self.program_code_len = @intCast(self.code.items.len);
        try self.appendHelpers();
        try self.resolveFixups();
        return self.code.toOwnedSlice(self.gpa);
    }
};

fn buildElfExecutable(code: []const u8, entry_code_offset: u64, program_code_len: u32, gpa: std.mem.Allocator) error{ OutOfMemory, FileTooBig }![]const u8 {
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
    var plen_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &plen_bytes, program_code_len, .little);
    try file_buf.appendSlice(gpa, &plen_bytes);
    const remaining = code_file_offset - file_buf.items.len;
    try file_buf.appendNTimes(gpa, 0, @intCast(remaining));
    try file_buf.appendSlice(gpa, code);

    return file_buf.toOwnedSlice(gpa);
}

pub fn computeCompile(lower_memo: *const db.Memo(ir_mod.Program), gpa: std.mem.Allocator) error{OutOfMemory}!db.Memo([]const u8) {
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

    return buildElfExecutable(code, 0, emitter.program_code_len, gpa);
}
