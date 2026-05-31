const std = @import("std");
const ast = @import("ast.zig");
const analyze = @import("analyze.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

pub const SymbolId = u32;
pub const FuncTypeId = u32;
pub const ValueRef = u32;
pub const BlockId = u32;
pub const FuncId = u32;
pub const MaxCallArgs: usize = 6;

pub const Type = union(enum) {
    unit,
    bool,
    int,
    float,
    type_type,
    named: SymbolId,
    func: FuncTypeId,
    variant: u32,
};

pub fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unit, .bool, .int, .float, .type_type => true,
        .named => |lhs| lhs == b.named,
        .func => |lhs| lhs == b.func,
        .variant => |lhs| lhs == b.variant,
    };
}

pub const IrFuncType = struct {
    params: []const Type,
    ret: Type,
};

pub const InstPair = struct {
    l: ValueRef,
    r: ValueRef,
};

pub const CallInst = struct {
    callee: ValueRef,
    argc: u8,
    args: [MaxCallArgs]ValueRef,
};

pub const FieldLoad = struct {
    base: ValueRef,
    field_index: u32,
};

pub const Inst = union(enum) {
    iconst: i32,
    fconst: f32,
    fn_addr: FuncId,
    call: CallInst,
    addi: InstPair,
    addf: InstPair,
    subi: InstPair,
    subf: InstPair,
    muli: InstPair,
    mulf: InstPair,
    divi: InstPair,
    divf: InstPair,
    printi: ValueRef,
    printf: ValueRef,
    printb: ValueRef,
    argi: u32,
    store: InstPair,
    field_load: FieldLoad,
};

pub const PredicateOp = enum {
    lti,
    ltf,
    gti,
    gtf,
    lei,
    lef,
    gei,
    gef,
    eqi,
    eqf,
    eqb,
    nei,
    nef,
    neb,
};

pub const Predicate = struct {
    op: PredicateOp,
    pair: InstPair,
};

pub const ValueInst = struct {
    id: ValueRef,
    op: Inst,
};

pub const Branch = struct {
    target: BlockId,
    arg: ?ValueRef = null,
};

pub const Terminator = union(enum) {
    br: Branch,
    pbr: struct {
        pred: Predicate,
        then_branch: Branch,
        else_branch: Branch,
    },
    ret: ValueRef,
};

pub const Block = struct {
    id: BlockId,
    param: ?ValueRef,
    param_width: u32,
    insts: std.ArrayList(ValueInst),
    terminator: ?Terminator,

    pub fn init(gpa: std.mem.Allocator, id: BlockId, param: ?ValueRef, param_width: u32) error{OutOfMemory}!Block {
        return .{
            .id = id,
            .param = param,
            .param_width = param_width,
            .insts = try std.ArrayList(ValueInst).initCapacity(gpa, 8),
            .terminator = null,
        };
    }

    pub fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
    }
};

pub const Function = struct {
    id: FuncId,
    name: SymbolId,
    entry: BlockId,
    blocks: std.ArrayList(Block),
    next_value: ValueRef,
    param_values: std.ArrayList(ValueRef),
    ret_type: Type,

    pub fn deinit(self: *Function, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
        self.param_values.deinit(gpa);
    }
};

pub const Program = struct {
    entry: FuncId,
    functions: std.ArrayList(Function),
    symbols: std.ArrayList([]const u8),
    func_types: std.ArrayList(IrFuncType),

    pub fn symbolFor(self: *const Program, id: SymbolId) []const u8 {
        return self.symbols.items[id];
    }

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        for (self.functions.items) |*func| func.deinit(gpa);
        self.functions.deinit(gpa);
        for (self.symbols.items) |s| gpa.free(s);
        self.symbols.deinit(gpa);
        for (self.func_types.items) |ft| gpa.free(ft.params);
        self.func_types.deinit(gpa);
    }
};

const LowerError = error{
    UnknownSymbol,
    UnknownFunction,
    TooManyCallArgs,
    MissingComptimeValue,
    UnsupportedComptimeValue,
    UnsupportedMultiSlotFunctionSignature,
};

const LowerResult = error{OutOfMemory} || LowerError || analyze.TypeError;

const Lowerer = struct {
    gpa: std.mem.Allocator,
    typed: *const analyze.AnalyzedAst,
    function_ids: std.StringHashMap(FuncId),
    symbols: std.ArrayList([]const u8),
    ident_map: std.StringHashMap(SymbolId),
    func_types: std.ArrayList(IrFuncType),
    func_type_map: std.AutoHashMap(usize, FuncTypeId),

    fn init(gpa: std.mem.Allocator, typed: *const analyze.AnalyzedAst) !Lowerer {
        var function_ids = std.StringHashMap(FuncId).init(gpa);
        errdefer function_ids.deinit();

        const a = typed.ast;
        for (typed.functions, 0..) |info, idx| {
            if (info.decl == std.math.maxInt(ast.NodeIdx)) continue;
            const name = a.identOf(a.nodes[info.decl].data0);
            try function_ids.put(name, @intCast(idx));
        }

        return .{
            .gpa = gpa,
            .typed = typed,
            .function_ids = function_ids,
            .symbols = .empty,
            .ident_map = .init(gpa),
            .func_types = .empty,
            .func_type_map = .init(gpa),
        };
    }

    fn deinit(self: *@This()) void {
        self.function_ids.deinit();
        self.ident_map.deinit();
        self.func_type_map.deinit();
        for (self.symbols.items) |s| self.gpa.free(s);
        self.symbols.deinit(self.gpa);
        for (self.func_types.items) |ft| self.gpa.free(ft.params);
        self.func_types.deinit(self.gpa);
    }

    fn internIdent(self: *@This(), s: []const u8) !SymbolId {
        if (self.ident_map.get(s)) |id| return id;
        const owned = try self.gpa.dupe(u8, s);
        errdefer self.gpa.free(owned);
        const id: SymbolId = @intCast(self.symbols.items.len);
        try self.symbols.append(self.gpa, owned);
        try self.ident_map.put(owned, id);
        return id;
    }

    fn internType(self: *@This(), tc_ty: analyze.Type) error{OutOfMemory}!Type {
        return switch (tc_ty) {
            .unit => .unit,
            .bool => .bool,
            .int => .int,
            .float => .float,
            .type_type => .type_type,
            .named => |name| .{ .named = try self.internIdent(name) },
            .func => |ft| .{ .func = try self.internFuncType(ft) },
            .variant => .{ .variant = try self.typeSlotCount(tc_ty) },
        };
    }

    fn namedTypeFieldCount(self: *const @This(), name: []const u8) u32 {
        const a = self.typed.ast;
        for (a.decls) |decl_idx| {
            if (a.nodes[decl_idx].tag != .comptime_struct) continue;
            const decl_name = a.identOf(a.nodes[decl_idx].data0);
            if (std.mem.eql(u8, decl_name, name)) return @intCast(a.structFields(decl_idx).len);
        }
        if (self.typed.comptime_struct_fields.get(name)) |fields| return @intCast(fields.len);
        return 1;
    }

    fn typeSlotCount(self: *const @This(), ty: analyze.Type) error{OutOfMemory}!u32 {
        return switch (ty) {
            .unit, .bool, .int, .float, .type_type, .func => 1,
            .named => |name| self.namedTypeFieldCount(name),
            .variant => |variant_ty| blk: {
                var max_member_slots: u32 = 1;
                for (variant_ty.members) |member_ty| {
                    const member_slots = try self.typeSlotCount(member_ty);
                    if (member_slots > max_member_slots) max_member_slots = member_slots;
                }
                break :blk max_member_slots + 1;
            },
        };
    }

    fn internFuncType(self: *@This(), ft: *const analyze.FuncType) !FuncTypeId {
        const ptr_key = @intFromPtr(ft);
        if (self.func_type_map.get(ptr_key)) |id| return id;

        const params = try self.gpa.alloc(Type, ft.params.len);
        errdefer self.gpa.free(params);
        for (ft.params, 0..) |p, i| {
            params[i] = try self.internType(p);
        }
        const ret = try self.internType(ft.ret);

        const id: FuncTypeId = @intCast(self.func_types.items.len);
        try self.func_types.append(self.gpa, .{
            .params = params,
            .ret = ret,
        });
        try self.func_type_map.put(ptr_key, id);
        return id;
    }

    fn allocFunction(self: *@This(), id: FuncId, name: []const u8, ret_type: Type) !Function {
        const name_id = try self.internIdent(name);
        var blocks = try std.ArrayList(Block).initCapacity(self.gpa, 8);
        errdefer blocks.deinit(self.gpa);

        var params = try std.ArrayList(ValueRef).initCapacity(self.gpa, 8);
        errdefer params.deinit(self.gpa);

        var entry_block = try Block.init(self.gpa, 0, null, 0);
        errdefer entry_block.deinit(self.gpa);
        try blocks.append(self.gpa, entry_block);

        return .{
            .id = id,
            .name = name_id,
            .entry = 0,
            .blocks = blocks,
            .next_value = 0,
            .param_values = params,
            .ret_type = ret_type,
        };
    }

    fn lowerProgram(self: *@This()) !Program {
        var functions = try std.ArrayList(Function).initCapacity(self.gpa, self.typed.functions.len);
        errdefer {
            for (functions.items) |*func| func.deinit(self.gpa);
            functions.deinit(self.gpa);
        }

        for (self.typed.functions, 0..) |info, idx| {
            var fn_lower = try FunctionLowerer.init(self, @intCast(idx), info);
            errdefer fn_lower.deinit();

            var lowered = try fn_lower.run();
            errdefer lowered.deinit(self.gpa);
            try functions.append(self.gpa, lowered);
        }

        const result = Program{
            .entry = self.typed.entry_function,
            .functions = functions,
            .symbols = self.symbols,
            .func_types = self.func_types,
        };
        self.symbols = .empty;
        self.func_types = .empty;
        return result;
    }
};

const FunctionLowerer = struct {
    const LowerBinding = struct {
        slot: ValueRef,
        ty: analyze.Type,
        slot_count: u32,
    };

    parent: *Lowerer,
    function: Function,
    bindings: scope_mod.ScopeStack(LowerBinding),
    current_block_id: BlockId,
    info: analyze.FunctionInfo,

    fn init(parent: *Lowerer, fn_id: FuncId, info: analyze.FunctionInfo) !FunctionLowerer {
        const a = parent.typed.ast;
        const fn_name = if (info.decl == std.math.maxInt(ast.NodeIdx))
            ""
        else
            a.identOf(a.nodes[info.decl].data0);
        const ret_slots = try parent.typeSlotCount(info.ty.ret);
        if (ret_slots != 1) return error.UnsupportedMultiSlotFunctionSignature;
        const ret_type = try parent.internType(info.ty.ret);
        var function = try parent.allocFunction(fn_id, fn_name, ret_type);
        errdefer function.deinit(parent.gpa);

        return .{
            .parent = parent,
            .function = function,
            .bindings = scope_mod.ScopeStack(LowerBinding).init(),
            .current_block_id = 0,
            .info = info,
        };
    }

    fn deinit(self: *@This()) void {
        self.bindings.deinit(self.parent.gpa);
        self.function.deinit(self.parent.gpa);
    }

    fn currentBlock(self: *@This()) *Block {
        return &self.function.blocks.items[self.current_block_id];
    }

    fn allocValue(self: *@This()) error{OutOfMemory}!ValueRef {
        const value_id = self.function.next_value;
        self.function.next_value += 1;
        return value_id;
    }

    fn addInst(self: *@This(), op: Inst) error{OutOfMemory}!ValueRef {
        const value_id = try self.allocValue();
        try self.currentBlock().insts.append(self.parent.gpa, .{ .id = value_id, .op = op });
        return value_id;
    }

    fn newBlock(self: *@This(), param_type: ?analyze.Type) LowerResult!BlockId {
        const block_id: BlockId = @intCast(self.function.blocks.items.len);
        const param_width = if (param_type) |ty| try self.typeSlotCount(ty) else 0;
        const block_param = if (param_width > 0) try self.allocValue() else null;
        if (param_width > 1) self.function.next_value += param_width - 1;
        var block = try Block.init(self.parent.gpa, block_id, block_param, param_width);
        errdefer block.deinit(self.parent.gpa);
        try self.function.blocks.append(self.parent.gpa, block);
        return block_id;
    }

    fn pushBinding(self: *@This(), name: []const u8, binding: LowerBinding) !void {
        self.bindings.push(self.parent.gpa, name, binding) catch |err| switch (err) {
            error.DuplicateVariable => return error.UnknownSymbol,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn lookupBinding(self: *const @This(), name: []const u8) ?LowerBinding {
        return self.bindings.lookup(name);
    }

    fn nodeType(self: *const @This(), idx: ast.NodeIdx) (std.mem.Allocator.Error || analyze.TypeError)!analyze.Type {
        return self.parent.typed.typeOf(idx);
    }

    fn typeSlotCount(self: *const @This(), ty: analyze.Type) LowerResult!u32 {
        return self.parent.typeSlotCount(ty);
    }

    fn variantMemberIndex(variant_ty: *const analyze.VariantType, member_ty: analyze.Type) ?u32 {
        for (variant_ty.members, 0..) |candidate, index| {
            if (analyze.typeEql(candidate, member_ty)) return @intCast(index);
        }
        return null;
    }

    fn emitCopySlots(self: *@This(), src_base: ValueRef, dst_base: ValueRef, slot_count: u32) LowerResult!void {
        var slot_index: u32 = 0;
        while (slot_index < slot_count) : (slot_index += 1) {
            const src = src_base + slot_index;
            const dst = dst_base + slot_index;
            _ = try self.addInst(.{ .store = .{ .l = src, .r = dst } });
        }
    }

    fn allocSlotRange(self: *@This(), slot_count: u32) LowerResult!ValueRef {
        const base = try self.allocValue();
        if (slot_count > 1) self.function.next_value += slot_count - 1;
        return base;
    }

    fn lowerValueAsType(self: *@This(), value_node: ast.NodeIdx, target_ty: analyze.Type) LowerResult!ValueRef {
        const source_ty = try self.parent.typed.typeOf(value_node);
        if (analyze.typeEql(target_ty, source_ty)) return self.lowerAst(value_node);

        const target_variant = switch (target_ty) {
            .variant => |variant_ty| variant_ty,
            else => unreachable,
        };
        const member_tag = variantMemberIndex(target_variant, source_ty) orelse unreachable;
        const source_ref = try self.lowerAst(value_node);
        const source_slots = try self.typeSlotCount(source_ty);
        const variant_slots = try self.typeSlotCount(target_ty);
        const variant_base = try self.allocSlotRange(variant_slots);
        const tag_const = try self.addInst(.{ .iconst = @intCast(member_tag) });
        _ = try self.addInst(.{ .store = .{ .l = tag_const, .r = variant_base } });
        try self.emitCopySlots(source_ref, variant_base + 1, source_slots);
        return variant_base;
    }

    fn lowerPairOperands(self: *@This(), lhs: ast.NodeIdx, rhs: ast.NodeIdx) LowerResult!InstPair {
        const left = try self.lowerAst(lhs);
        const right = try self.lowerAst(rhs);
        return .{ .l = left, .r = right };
    }

    fn addPairInst(
        self: *@This(),
        comptime tag: std.meta.Tag(Inst),
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
    ) LowerResult!ValueRef {
        const operands = try self.lowerPairOperands(lhs, rhs);
        return self.addInst(@unionInit(Inst, @tagName(tag), operands));
    }

    fn lowerUnitValue(self: *@This()) error{OutOfMemory}!ValueRef {
        return self.addInst(.{ .iconst = 0 });
    }

    fn lowerConditionPredicate(self: *@This(), cond: ast.NodeIdx) LowerResult!Predicate {
        const a = self.parent.typed.ast;
        return switch (a.nodes[cond].tag) {
            .lt => self.lowerComparisonPredicate(a.nodes[cond].data0, a.nodes[cond].data1, .lti, .ltf),
            .gt => self.lowerComparisonPredicate(a.nodes[cond].data0, a.nodes[cond].data1, .gti, .gtf),
            .le => self.lowerComparisonPredicate(a.nodes[cond].data0, a.nodes[cond].data1, .lei, .lef),
            .ge => self.lowerComparisonPredicate(a.nodes[cond].data0, a.nodes[cond].data1, .gei, .gef),
            .eq => self.lowerEqualityPredicate(a.nodes[cond].data0, a.nodes[cond].data1, .eqi, .eqf, .eqb),
            .ne => self.lowerEqualityPredicate(a.nodes[cond].data0, a.nodes[cond].data1, .nei, .nef, .neb),
            else => error.IfConditionNotFallible,
        };
    }

    fn lowerVariantIsCondition(
        self: *@This(),
        start_block_id: BlockId,
        cond: ast.NodeIdx,
        then_target: BlockId,
        else_target: BlockId,
    ) LowerResult!void {
        const a = self.parent.typed.ast;
        const lhs = a.isLhs(cond);
        const lhs_base = try self.lowerAst(lhs);
        const tag_values = self.parent.typed.is_variant_tags.get(cond) orelse return error.IfConditionNotFallible;

        var current_block_id = start_block_id;
        for (tag_values, 0..) |tag_value, tag_index| {
            self.current_block_id = current_block_id;
            const tag_const = try self.addInst(.{ .iconst = @intCast(tag_value) });
            const next_fail_block = if (tag_index + 1 == tag_values.len) else_target else try self.newBlock(null);
            self.currentBlock().terminator = .{
                .pbr = .{
                    .pred = .{
                        .op = .eqi,
                        .pair = .{ .l = lhs_base, .r = tag_const },
                    },
                    .then_branch = .{ .target = then_target },
                    .else_branch = .{ .target = next_fail_block },
                },
            };
            current_block_id = next_fail_block;
        }
    }

    fn lowerConditionToBranches(
        self: *@This(),
        start_block_id: BlockId,
        cond: ast.NodeIdx,
        then_target: BlockId,
        else_target: BlockId,
    ) LowerResult!void {
        const a = self.parent.typed.ast;
        self.current_block_id = start_block_id;
        switch (a.nodes[cond].tag) {
            .@"and" => {
                const rhs_block_id = try self.newBlock(null);
                try self.lowerConditionToBranches(start_block_id, a.nodes[cond].data0, rhs_block_id, else_target);
                try self.lowerConditionToBranches(rhs_block_id, a.nodes[cond].data1, then_target, else_target);
            },
            .@"or" => {
                const rhs_block_id = try self.newBlock(null);
                try self.lowerConditionToBranches(start_block_id, a.nodes[cond].data0, then_target, rhs_block_id);
                try self.lowerConditionToBranches(rhs_block_id, a.nodes[cond].data1, then_target, else_target);
            },
            .is => {
                try self.lowerVariantIsCondition(start_block_id, cond, then_target, else_target);
            },
            else => {
                const predicate = try self.lowerConditionPredicate(cond);
                self.currentBlock().terminator = .{
                    .pbr = .{
                        .pred = predicate,
                        .then_branch = .{ .target = then_target },
                        .else_branch = .{ .target = else_target },
                    },
                };
            },
        }
    }

    fn lowerComparisonPredicate(
        self: *@This(),
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
        int_op: PredicateOp,
        float_op: PredicateOp,
    ) LowerResult!Predicate {
        const pair = try self.lowerPairOperands(lhs, rhs);
        const operand_ty = try self.nodeType(lhs);
        return .{
            .op = if (operand_ty == .int) int_op else float_op,
            .pair = pair,
        };
    }

    fn lowerEqualityPredicate(
        self: *@This(),
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
        int_op: PredicateOp,
        float_op: PredicateOp,
        bool_op: PredicateOp,
    ) LowerResult!Predicate {
        const pair = try self.lowerPairOperands(lhs, rhs);
        const operand_ty = try self.nodeType(lhs);
        return .{
            .op = switch (operand_ty) {
                .int => int_op,
                .float => float_op,
                .bool => bool_op,
                .unit, .named, .func, .type_type, .variant => unreachable,
            },
            .pair = pair,
        };
    }

    fn lowerArithmetic(
        self: *@This(),
        idx: ast.NodeIdx,
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
        comptime int_tag: std.meta.Tag(Inst),
        comptime float_tag: std.meta.Tag(Inst),
    ) LowerResult!ValueRef {
        return switch (try self.nodeType(idx)) {
            .int => try self.addPairInst(int_tag, lhs, rhs),
            .float => try self.addPairInst(float_tag, lhs, rhs),
            else => unreachable,
        };
    }

    fn lowerCall(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const call_args = a.callArgs(idx);
        if (call_args.len > MaxCallArgs) return error.TooManyCallArgs;

        var args: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        for (call_args, 0..) |arg_node, i| {
            args[i] = try self.lowerAst(arg_node);
        }

        const callee = try self.lowerAst(a.nodes[idx].data0);
        return self.addInst(.{ .call = .{
            .callee = callee,
            .argc = @intCast(call_args.len),
            .args = args,
        } });
    }

    fn lowerIf(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const data = a.ifData(idx);
        const if_ty = try self.nodeType(idx);

        const then_block_id = try self.newBlock(null);
        const else_block_id = try self.newBlock(null);
        const merge_block_id = try self.newBlock(if_ty);
        const condition_entry_block = self.current_block_id;
        try self.lowerConditionToBranches(condition_entry_block, data.cond, then_block_id, else_block_id);

        var then_fallthrough = false;
        self.current_block_id = then_block_id;
        const then_value = then_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            break :then_blk try self.lowerAst(data.then_);
        };
        if (self.currentBlock().terminator == null) {
            self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = then_value } };
            then_fallthrough = true;
        }

        var else_fallthrough = false;
        self.current_block_id = else_block_id;
        const else_value = else_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            if (data.else_ != std.math.maxInt(ast.NodeIdx)) {
                break :else_blk try self.lowerAst(data.else_);
            }
            break :else_blk try self.lowerUnitValue();
        };
        if (self.currentBlock().terminator == null) {
            self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = else_value } };
            else_fallthrough = true;
        }

        self.current_block_id = merge_block_id;
        if (then_fallthrough or else_fallthrough) {
            return self.currentBlock().param orelse unreachable;
        }
        return self.lowerUnitValue();
    }

    fn lowerBlock(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        var result: ?ValueRef = null;
        for (a.blockItems(idx)) |item| {
            if (self.currentBlock().terminator != null) break;
            result = try self.lowerAst(item);
        }
        if (result) |value| return value;
        return self.lowerUnitValue();
    }

    fn lowerStructIntoSlots(self: *@This(), init_idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const fields = a.structInitFields(init_idx);
        const field_count: u32 = @intCast(fields.len);
        const base = try self.allocValue();
        if (field_count > 1) {
            self.function.next_value += field_count - 1;
        }
        for (fields, 0..) |field, field_idx| {
            const field_value = try self.lowerAst(field.value);
            const dst_slot: ValueRef = base + @as(ValueRef, @intCast(field_idx));
            _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } });
        }
        return base;
    }

    fn lowerVar(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const value = a.varDeclValue(idx);
        const name = a.identOf(a.nodes[idx].data0);
        const binding_ty = self.parent.typed.decl_binding_types.get(idx) orelse try self.parent.typed.typeOf(value);
        const value_ref = try self.lowerValueAsType(value, binding_ty);
        const slot_count = try self.typeSlotCount(binding_ty);
        const var_slot = try self.allocSlotRange(slot_count);
        try self.emitCopySlots(value_ref, var_slot, slot_count);
        try self.pushBinding(name, .{
            .slot = var_slot,
            .ty = binding_ty,
            .slot_count = slot_count,
        });
        return self.lowerUnitValue();
    }

    fn lowerConst(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const value = a.varDeclValue(idx);
        const name = a.identOf(a.nodes[idx].data0);
        const binding_ty = self.parent.typed.decl_binding_types.get(idx) orelse try self.parent.typed.typeOf(value);
        const value_ref = try self.lowerValueAsType(value, binding_ty);
        const slot_count = try self.typeSlotCount(binding_ty);
        try self.pushBinding(name, .{
            .slot = value_ref,
            .ty = binding_ty,
            .slot_count = slot_count,
        });
        return self.lowerUnitValue();
    }

    fn lowerAssign(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const name = a.identOf(a.nodes[idx].data0);
        const binding = self.lookupBinding(name) orelse return error.UnknownSymbol;
        const value_ref = try self.lowerValueAsType(a.nodes[idx].data1, binding.ty);
        try self.emitCopySlots(value_ref, binding.slot, binding.slot_count);
        return self.lowerUnitValue();
    }

    fn lowerReturn(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const value_ref = try self.lowerValueAsType(a.nodes[idx].data0, self.info.ty.ret);
        self.currentBlock().terminator = .{ .ret = value_ref };
        return value_ref;
    }

    fn lowerStructInit(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        return self.lowerStructIntoSlots(idx);
    }

    fn lowerFieldAccess(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const target = self.parent.typed.ast.nodes[idx].data0;
        const base = try self.lowerAst(target);
        const f_idx = self.parent.typed.field_index.get(idx).?;
        if (f_idx == 0) return base;
        return self.addInst(.{ .field_load = .{ .base = base, .field_index = f_idx } });
    }

    fn lowerComptimeValue(self: *@This(), value: analyze.ComptimeValue) LowerResult!ValueRef {
        return switch (value) {
            .unit => self.lowerUnitValue(),
            .bool => |v| self.addInst(.{ .iconst = if (v) @as(i32, 1) else 0 }),
            .int => |v| self.addInst(.{ .iconst = v }),
            .float => |v| self.addInst(.{ .fconst = v }),
            .func => |fn_id| self.addInst(.{ .fn_addr = fn_id }),
            .type_value => error.UnsupportedComptimeValue,
            .struct_type => error.UnsupportedComptimeValue,
            .struct_value => |sv| blk: {
                const field_count: u32 = @intCast(sv.fields.len);
                const base = try self.allocValue();
                if (field_count > 1) self.function.next_value += field_count - 1;
                for (sv.fields, 0..) |field_value, field_idx| {
                    const src = try self.lowerComptimeValue(field_value);
                    const dst = base + @as(ValueRef, @intCast(field_idx));
                    _ = try self.addInst(.{ .store = .{ .l = src, .r = dst } });
                }
                break :blk base;
            },
        };
    }

    fn lowerVarRef(self: *@This(), name: []const u8) LowerResult!ValueRef {
        if (self.lookupBinding(name)) |binding| return binding.slot;
        if (self.parent.typed.comptime_values.get(name)) |cv| {
            return self.lowerComptimeValue(cv);
        }
        const fn_id = self.parent.function_ids.get(name) orelse return error.UnknownFunction;
        return self.addInst(.{ .fn_addr = fn_id });
    }

    fn lowerAst(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        return switch (a.nodes[idx].tag) {
            .block => try self.lowerBlock(idx),
            .int_lit => blk: {
                const value: i32 = @bitCast(a.nodes[idx].data0);
                break :blk try self.addInst(.{ .iconst = value });
            },
            .float_lit => blk: {
                const value: f32 = @bitCast(a.nodes[idx].data0);
                break :blk try self.addInst(.{ .fconst = value });
            },
            .bool_lit => blk: {
                const value = a.nodes[idx].data0 != 0;
                break :blk try self.addInst(.{ .iconst = if (value) @as(i32, 1) else 0 });
            },
            .unit_lit => try self.lowerUnitValue(),
            .var_ref => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                break :blk try self.lowerVarRef(name);
            },
            .var_decl => try self.lowerVar(idx),
            .const_decl => try self.lowerConst(idx),
            .assign => try self.lowerAssign(idx),
            .return_stmt => try self.lowerReturn(idx),
            .call => try self.lowerCall(idx),
            .print_stmt => blk: {
                const child = a.nodes[idx].data0;
                const child_ref = try self.lowerAst(child);
                const child_ty = try self.nodeType(child);
                const print_op: Inst = switch (child_ty) {
                    .int => .{ .printi = child_ref },
                    .float => .{ .printf = child_ref },
                    .bool => .{ .printb = child_ref },
                    else => unreachable,
                };
                break :blk try self.addInst(print_op);
            },
            .add => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .addi, .addf),
            .sub => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .subi, .subf),
            .mul => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .muli, .mulf),
            .div => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .divi, .divf),
            .arg => blk: {
                const arg_idx = a.nodes[idx].data0;
                break :blk try self.addInst(.{ .argi = arg_idx });
            },
            .lt, .gt, .le, .ge, .eq, .ne, .is, .@"and", .@"or" => error.IfConditionNotFallible,
            .if_stmt => try self.lowerIf(idx),
            .struct_init => try self.lowerStructInit(idx),
            .field_access => try self.lowerFieldAccess(idx),
            .comptime_expr => blk: {
                const value = self.parent.typed.comptime_node_values.get(idx) orelse return error.MissingComptimeValue;
                break :blk try self.lowerComptimeValue(value);
            },
            .comptime_value_decl => try self.lowerUnitValue(),
            .comptime_fn, .comptime_struct => try self.lowerUnitValue(),
            .struct_expr => try self.lowerUnitValue(),
            .type_name, .type_func, .type_variant, .type_union => unreachable,
        };
    }

    fn setupParams(self: *@This()) !void {
        if (self.info.decl == std.math.maxInt(ast.NodeIdx)) return;
        const a = self.parent.typed.ast;
        const params = a.fnParams(self.info.decl);
        for (params, self.info.ty.params) |param, param_ty| {
            const pname = a.identOf(param.name);
            const slot_count = try self.typeSlotCount(param_ty);
            if (slot_count != 1) return error.UnsupportedMultiSlotFunctionSignature;
            const slot = try self.allocSlotRange(slot_count);
            try self.function.param_values.append(self.parent.gpa, slot);
            try self.pushBinding(pname, .{
                .slot = slot,
                .ty = param_ty,
                .slot_count = slot_count,
            });
        }
    }

    fn isComptimeOnlyFunction(self: *const @This()) bool {
        if (self.info.decl == std.math.maxInt(ast.NodeIdx)) return false;
        const comptime_mask = self.parent.typed.ast.fnComptimeMask(self.info.decl);
        return comptime_mask != 0 and self.info.ty.ret == .type_type;
    }

    fn run(self: *@This()) !Function {
        try self.setupParams();
        if (self.isComptimeOnlyFunction()) {
            const stub_ret = try self.lowerUnitValue();
            self.currentBlock().terminator = .{ .ret = stub_ret };
            self.bindings.deinit(self.parent.gpa);
            return self.function;
        }

        const a = self.parent.typed.ast;
        const body = if (self.info.decl == std.math.maxInt(ast.NodeIdx))
            a.entry
        else
            a.fnBody(self.info.decl);
        const result = try self.lowerAst(body);
        if (self.currentBlock().terminator == null) {
            self.currentBlock().terminator = .{ .ret = result };
        }

        self.bindings.deinit(self.parent.gpa);
        return self.function;
    }
};

pub const LowerMemo = db.Memo(Program);

pub fn computeLower(
    type_memo: *const analyze.AnalyzeMemo,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!LowerMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, type_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var lowered_value: ?Program = null;
    if (type_memo.value) |*type_val| {
        const lowered = lower(type_val, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                try db.appendStageError(&diagnostics_list, gpa, .lower, @errorName(err));
                break :blk null;
            },
        };
        lowered_value = lowered;
    }

    return db.makeMemo(Program, lowered_value, diagnostics_list);
}

fn lower(typed: *const analyze.AnalyzedAst, gpa: std.mem.Allocator) !Program {
    var lowerer = try Lowerer.init(gpa, typed);
    defer lowerer.deinit();

    return lowerer.lowerProgram();
}
