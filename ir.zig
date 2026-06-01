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
    none,
    named: SymbolId,
    func: FuncTypeId,
    variant: u32,
};

pub fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unit, .bool, .int, .float, .type_type, .none => true,
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
    ret_slots: u8,
};

pub const DirectCallInst = struct {
    callee: FuncId,
    argc: u8,
    args: [MaxCallArgs]ValueRef,
    ret_slots: u8,
};

pub const FieldLoad = struct {
    base: ValueRef,
    field_index: u32,
};

pub const PtrLoad = struct {
    ptr: ValueRef,
    offset_slots: u32,
};

pub const PtrStore = struct {
    ptr: ValueRef,
    src: ValueRef,
    offset_slots: u32,
};

pub const Inst = union(enum) {
    iconst: i32,
    fconst: f32,
    fn_addr: FuncId,
    call: CallInst,
    direct_call: DirectCallInst,
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
    slot_addr: ValueRef,
    load_ptr: PtrLoad,
    store_ptr: PtrStore,
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
    ret_slots: u32,

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
        for (typed.functions.items, 0..) |info, idx| {
            if (info.decl == std.math.maxInt(ast.NodeIdx)) continue;
            if (info.is_monomorphized) continue;
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
            .none => .none,
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
            .unit, .bool, .int, .float, .type_type, .none, .func => 1,
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

    fn allocFunction(self: *@This(), id: FuncId, name: []const u8, ret_type: Type, ret_slots: u32) !Function {
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
            .ret_slots = ret_slots,
        };
    }

    fn lowerProgram(self: *@This()) !Program {
        var functions = try std.ArrayList(Function).initCapacity(self.gpa, self.typed.functions.items.len);
        errdefer {
            for (functions.items) |*func| func.deinit(self.gpa);
            functions.deinit(self.gpa);
        }

        for (self.typed.functions.items, 0..) |info, idx| {
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
    const BindingStorage = union(enum) {
        local_slot: ValueRef,
        borrowed_ptr: ValueRef,
    };

    const LowerBinding = struct {
        storage: BindingStorage,
        ty: analyze.Type,
        slot_count: u32,
    };

    parent: *Lowerer,
    function: Function,
    bindings: scope_mod.ScopeStack(LowerBinding),
    current_block_id: BlockId,
    info: analyze.FunctionInfo,
    loaded_ptrs: std.AutoHashMap(ValueRef, ValueRef),

    fn init(parent: *Lowerer, fn_id: FuncId, info: analyze.FunctionInfo) !FunctionLowerer {
        const a = parent.typed.ast;
        const fn_name = if (info.decl == std.math.maxInt(ast.NodeIdx))
            ""
        else
            a.identOf(a.nodes[info.decl].data0);
        const ret_type = try parent.internType(info.ty.ret);
        const ret_slots = try parent.typeSlotCount(info.ty.ret);
        var function = try parent.allocFunction(fn_id, fn_name, ret_type, ret_slots);
        errdefer function.deinit(parent.gpa);

        return .{
            .parent = parent,
            .function = function,
            .bindings = scope_mod.ScopeStack(LowerBinding).init(),
            .current_block_id = 0,
            .info = info,
            .loaded_ptrs = std.AutoHashMap(ValueRef, ValueRef).init(parent.gpa),
        };
    }

    fn deinit(self: *@This()) void {
        self.bindings.deinit(self.parent.gpa);
        self.function.deinit(self.parent.gpa);
        self.loaded_ptrs.deinit();
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

    fn callParamModes(self: *const @This(), call_idx: ast.NodeIdx, callee: ast.NodeIdx) []const ast.ParamAccessMode {
        if (self.parent.typed.call_monomorph_targets.get(call_idx)) |target_fn_id| {
            if (target_fn_id < self.parent.typed.functions.items.len) return self.parent.typed.functions.items[target_fn_id].param_modes;
        }
        if (self.parent.typed.ast.nodes[callee].tag == .var_ref) {
            const cname = self.parent.typed.ast.identOf(self.parent.typed.ast.nodes[callee].data0);
            if (self.parent.function_ids.get(cname)) |fn_id| {
                if (fn_id < self.parent.typed.functions.items.len) {
                    return self.parent.typed.functions.items[fn_id].param_modes;
                }
            }
        }
        return &.{};
    }

    fn lowerBindingPointer(self: *@This(), binding: LowerBinding) LowerResult!ValueRef {
        return switch (binding.storage) {
            .local_slot => |slot| self.addInst(.{ .slot_addr = slot }),
            .borrowed_ptr => |ptr_slot| ptr_slot,
        };
    }

    fn lowerBindingValue(self: *@This(), binding: LowerBinding) LowerResult!ValueRef {
        return switch (binding.storage) {
            .local_slot => |slot| slot,
            .borrowed_ptr => |ptr_slot| blk: {
                if (self.loaded_ptrs.get(ptr_slot)) |cached| break :blk cached;
                const base = try self.allocSlotRange(binding.slot_count);
                var offset: u32 = 0;
                while (offset < binding.slot_count) : (offset += 1) {
                    const loaded = try self.addInst(.{ .load_ptr = .{ .ptr = ptr_slot, .offset_slots = offset } });
                    _ = try self.addInst(.{ .store = .{ .l = loaded, .r = base + offset } });
                }
                try self.loaded_ptrs.put(ptr_slot, base);
                break :blk base;
            },
        };
    }

    fn isReadByValueTy(ty: analyze.Type) bool {
        return switch (ty) {
            .int, .float, .bool, .unit, .none => true,
            .func => true,
            .type_type, .named, .variant => false,
        };
    }

    fn lowerReadArgPointer(self: *@This(), arg_node: ast.NodeIdx, param_ty: analyze.Type) LowerResult!ValueRef {
        if (isReadByValueTy(param_ty)) {
            return self.lowerValueAsType(arg_node, param_ty);
        }
        const a = self.parent.typed.ast;
        if (a.nodes[arg_node].tag == .var_ref) {
            const name = a.identOf(a.nodes[arg_node].data0);
            if (self.lookupBinding(name)) |binding| {
                return self.lowerBindingPointer(binding);
            }
        }
        const arg_value = try self.lowerValueAsType(arg_node, param_ty);
        return self.addInst(.{ .slot_addr = arg_value });
    }

    fn lowerMutArgPointer(self: *@This(), arg_node: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        if (a.nodes[arg_node].tag != .var_ref) return error.UnknownSymbol;
        const name = a.identOf(a.nodes[arg_node].data0);
        const binding = self.lookupBinding(name) orelse return error.UnknownSymbol;
        return self.lowerBindingPointer(binding);
    }

    fn nodeType(self: *const @This(), idx: ast.NodeIdx) analyze.TypeError!analyze.Type {
        const a = self.parent.typed.ast;
        if (a.nodes[idx].tag == .var_ref) {
            const name = a.identOf(a.nodes[idx].data0);
            if (self.lookupBinding(name)) |binding| return binding.ty;
        }
        return self.parent.typed.typeOf(idx);
    }

    fn typeSlotCount(self: *const @This(), ty: analyze.Type) LowerResult!u32 {
        return self.parent.typeSlotCount(ty);
    }

    fn ownershipSpecForType(self: *const @This(), ty: analyze.Type) ?analyze.OwnershipSpec {
        return switch (ty) {
            .named => |name| self.parent.typed.ownership_specs.get(name),
            else => null,
        };
    }

    fn emitCallWithArgs(self: *@This(), callee_ref: ValueRef, arg_values: []const ValueRef, ret_ty: analyze.Type) LowerResult!ValueRef {
        if (arg_values.len > MaxCallArgs) return error.TooManyCallArgs;
        const ret_slots = try self.typeSlotCount(ret_ty);
        var args: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        for (arg_values, 0..) |arg, idx| args[idx] = arg;
        const call_value = try self.addInst(.{ .call = .{
            .callee = callee_ref,
            .argc = @intCast(arg_values.len),
            .args = args,
            .ret_slots = @intCast(ret_slots),
        } });
        if (ret_slots > 1) self.function.next_value += ret_slots - 1;
        return call_value;
    }

    fn emitCopyHook(self: *@This(), hook_fn_id: FuncId, source_base: ValueRef, ty: analyze.Type) LowerResult!ValueRef {
        const source_ptr = try self.addInst(.{ .slot_addr = source_base });
        const callee_ref = try self.addInst(.{ .fn_addr = hook_fn_id });
        return self.emitCallWithArgs(callee_ref, &.{source_ptr}, ty);
    }

    fn emitMoveHook(self: *@This(), hook_fn_id: FuncId, source_base: ValueRef, ty: analyze.Type) LowerResult!ValueRef {
        const width = try self.typeSlotCount(ty);
        if (width > MaxCallArgs) return error.TooManyCallArgs;
        var args_buf: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            args_buf[i] = source_base + i;
        }
        const callee_ref = try self.addInst(.{ .fn_addr = hook_fn_id });
        return self.emitCallWithArgs(callee_ref, args_buf[0..width], ty);
    }

    fn applyImplicitCopy(self: *@This(), value_node: ast.NodeIdx, value_ref: ValueRef, ty: analyze.Type) LowerResult!ValueRef {
        const value_tag = self.parent.typed.ast.nodes[value_node].tag;
        if (value_tag == .move_expr) return value_ref;
        if (value_tag != .var_ref and value_tag != .field_access) return value_ref;
        const spec = self.ownershipSpecForType(ty) orelse return value_ref;
        if (spec.copy.kind != .func) return value_ref;
        const hook_fn = spec.copy.hook_fn orelse return value_ref;
        return self.emitCopyHook(hook_fn, value_ref, ty);
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

    fn wrapValueRefToType(self: *@This(), source_ref: ValueRef, source_ty: analyze.Type, target_ty: analyze.Type) LowerResult!ValueRef {
        if (analyze.typeEql(source_ty, target_ty)) return source_ref;

        const target_variant = switch (target_ty) {
            .variant => |variant_ty| variant_ty,
            else => unreachable,
        };
        const member_tag = variantMemberIndex(target_variant, source_ty) orelse unreachable;
        const source_slots = try self.typeSlotCount(source_ty);
        const variant_slots = try self.typeSlotCount(target_ty);
        const variant_base = try self.allocSlotRange(variant_slots);
        const tag_const = try self.addInst(.{ .iconst = @intCast(member_tag) });
        _ = try self.addInst(.{ .store = .{ .l = tag_const, .r = variant_base } });
        try self.emitCopySlots(source_ref, variant_base + 1, source_slots);
        return variant_base;
    }

    fn lowerValueAsType(self: *@This(), value_node: ast.NodeIdx, target_ty: analyze.Type) LowerResult!ValueRef {
        const source_ref = try self.lowerAst(value_node);
        // For var_ref nodes, derive the source type from the binding rather than
        // from the shared node_types map, which may contain stale entries for
        // AST nodes shared across monomorphized function instances.
        const source_ty = if (self.parent.typed.ast.nodes[value_node].tag == .var_ref) src: {
            const name = self.parent.typed.ast.identOf(self.parent.typed.ast.nodes[value_node].data0);
            if (self.lookupBinding(name)) |binding| break :src binding.ty;
            break :src try self.parent.typed.typeOf(value_node);
        } else try self.parent.typed.typeOf(value_node);
        return self.wrapValueRefToType(source_ref, source_ty, target_ty);
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

    fn lowerVariantAsCondition(
        self: *@This(),
        start_block_id: BlockId,
        as_node: ast.NodeIdx,
        success_binding_slot: ?ValueRef,
        success_binding_width: u32,
        then_target: BlockId,
        else_target: BlockId,
    ) LowerResult!void {
        const a = self.parent.typed.ast;
        const lhs = a.isLhs(as_node);
        const lhs_base = try self.lowerAst(lhs);
        const lhs_ty = try self.nodeType(lhs);
        const lhs_variant = switch (lhs_ty) {
            .variant => |variant_ty| variant_ty,
            else => return error.IfConditionNotFallible,
        };
        const rhs_ty = try self.nodeType(as_node);
        const member_tag = variantMemberIndex(lhs_variant, rhs_ty) orelse return error.IfConditionNotFallible;

        self.current_block_id = start_block_id;
        const tag_const = try self.addInst(.{ .iconst = @intCast(member_tag) });

        const success_target = if (success_binding_slot == null) then_target else try self.newBlock(null);
        self.currentBlock().terminator = .{
            .pbr = .{
                .pred = .{
                    .op = .eqi,
                    .pair = .{ .l = lhs_base, .r = tag_const },
                },
                .then_branch = .{ .target = success_target },
                .else_branch = .{ .target = else_target },
            },
        };

        if (success_binding_slot) |binding_slot| {
            self.current_block_id = success_target;
            try self.emitCopySlots(lhs_base + 1, binding_slot, success_binding_width);
            self.currentBlock().terminator = .{ .br = .{ .target = then_target } };
        }
    }

    fn lowerVariantQueryCondition(
        self: *@This(),
        start_block_id: BlockId,
        query_node: ast.NodeIdx,
        success_binding_slot: ?ValueRef,
        success_binding_width: u32,
        then_target: BlockId,
        else_target: BlockId,
    ) LowerResult!void {
        const a = self.parent.typed.ast;
        const lhs = a.isLhs(query_node);
        const lhs_base = try self.lowerAst(lhs);
        const none_tag = self.parent.typed.query_none_tags.get(query_node) orelse return error.IfConditionNotFallible;

        self.current_block_id = start_block_id;
        const tag_const = try self.addInst(.{ .iconst = @intCast(none_tag) });

        const success_target = if (success_binding_slot == null) then_target else try self.newBlock(null);
        // predicate: tag != none_tag → success, tag == none_tag → else
        self.currentBlock().terminator = .{
            .pbr = .{
                .pred = .{
                    .op = .nei,
                    .pair = .{ .l = lhs_base, .r = tag_const },
                },
                .then_branch = .{ .target = success_target },
                .else_branch = .{ .target = else_target },
            },
        };

        if (success_binding_slot) |binding_slot| {
            self.current_block_id = success_target;
            // If the result is still a variant, copy all slots (tag + payload)
            // Otherwise, copy only the payload (skip the tag at lhs_base)
            const binding_ty = try self.nodeType(query_node);
            const copy_offset: ValueRef = if (binding_ty == .variant) 0 else 1;
            try self.emitCopySlots(lhs_base + copy_offset, binding_slot, success_binding_width);
            self.currentBlock().terminator = .{ .br = .{ .target = then_target } };
        }
    }

    const IfCondBinding = struct {
        name: []const u8,
        mutable: bool,
        ty: analyze.Type,
        slot: ValueRef,
        slot_count: u32,
        as_node: ast.NodeIdx,
        is_query: bool,
    };

    fn setupIfCondBinding(self: *@This(), cond: ast.NodeIdx) LowerResult!?IfCondBinding {
        const a = self.parent.typed.ast;
        const cond_tag = a.nodes[cond].tag;
        if (cond_tag != .const_decl and cond_tag != .var_decl) return null;

        const value_node = a.varDeclValue(cond);
        const value_tag = a.nodes[value_node].tag;

        if (value_tag == .as) {
            const binding_ty = self.parent.typed.decl_binding_types.get(cond) orelse try self.nodeType(value_node);
            const slot_count = try self.typeSlotCount(binding_ty);
            const slot = try self.allocSlotRange(slot_count);
            return .{
                .name = a.identOf(a.nodes[cond].data0),
                .mutable = cond_tag == .var_decl,
                .ty = binding_ty,
                .slot = slot,
                .slot_count = slot_count,
                .as_node = value_node,
                .is_query = false,
            };
        }

        if (value_tag == .query_op) {
            const binding_ty = self.parent.typed.decl_binding_types.get(cond) orelse try self.nodeType(value_node);
            const slot_count = try self.typeSlotCount(binding_ty);
            const slot = try self.allocSlotRange(slot_count);
            return .{
                .name = a.identOf(a.nodes[cond].data0),
                .mutable = cond_tag == .var_decl,
                .ty = binding_ty,
                .slot = slot,
                .slot_count = slot_count,
                .as_node = value_node,
                .is_query = true,
            };
        }

        return null;
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
            .@"not" => {
                try self.lowerConditionToBranches(start_block_id, a.nodes[cond].data0, else_target, then_target);
            },
            .is => {
                try self.lowerVariantIsCondition(start_block_id, cond, then_target, else_target);
            },
            .as => {
                try self.lowerVariantAsCondition(start_block_id, cond, null, 0, then_target, else_target);
            },
            .query_op => {
                try self.lowerVariantQueryCondition(start_block_id, cond, null, 0, then_target, else_target);
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
                .unit, .none, .named, .func, .type_type, .variant => unreachable,
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

    fn packCallArg(
        self: *@This(),
        arg_node: ast.NodeIdx,
        param_ty: analyze.Type,
        mode: ast.ParamAccessMode,
        args: *[MaxCallArgs]ValueRef,
        arg_word_count: *usize,
    ) LowerResult!void {
        switch (mode) {
            .read => {
                if (arg_word_count.* + 1 > MaxCallArgs) return error.TooManyCallArgs;
                args[arg_word_count.*] = try self.lowerReadArgPointer(arg_node, param_ty);
                arg_word_count.* += 1;
            },
            .mut => {
                if (arg_word_count.* + 1 > MaxCallArgs) return error.TooManyCallArgs;
                args[arg_word_count.*] = try self.lowerMutArgPointer(arg_node);
                arg_word_count.* += 1;
            },
            .var_mode, .deinit => {
                const arg_base = try self.lowerValueAsType(arg_node, param_ty);
                const arg_width = try self.typeSlotCount(param_ty);
                if (arg_word_count.* + arg_width > MaxCallArgs) return error.TooManyCallArgs;

                var slot_offset: u32 = 0;
                while (slot_offset < arg_width) : (slot_offset += 1) {
                    args[arg_word_count.*] = arg_base + slot_offset;
                    arg_word_count.* += 1;
                }
            },
        }
    }

    fn lowerCall(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;

        if (self.parent.typed.call_monomorph_targets.get(idx)) |target_fn_id| {
            return self.lowerMonomorphizedCall(idx, target_fn_id);
        }

        const call_args = a.callArgs(idx);
        const callee = a.nodes[idx].data0;

        if (a.nodes[callee].tag == .var_ref) {
            const cname = a.identOf(a.nodes[callee].data0);
            if (self.lookupBinding(cname) == null) {
                for (self.parent.typed.functions.items, 0..) |cinfo, cidx| {
                    if (cinfo.decl == std.math.maxInt(ast.NodeIdx)) continue;
                    if (cinfo.is_monomorphized) continue;
                    const fname = a.identOf(a.nodes[cinfo.decl].data0);
                    if (std.mem.eql(u8, cname, fname)) {
                        return self.lowerDirectCall(idx, @intCast(cidx));
                    }
                }
            }
        }

        const callee_ty = try self.nodeType(callee);
        const fn_ty = switch (callee_ty) {
            .func => |sig| sig,
            else => return error.UnknownFunction,
        };
        if (call_args.len != fn_ty.params.len) return error.UnknownFunction;

        const ret_slots = try self.typeSlotCount(fn_ty.ret);
        const param_modes = self.callParamModes(idx, callee);

        var args: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        var arg_word_count: usize = 0;
        for (call_args, fn_ty.params, 0..) |arg_node, param_ty, arg_idx| {
            const mode = if (arg_idx < param_modes.len) param_modes[arg_idx] else ast.ParamAccessMode.read;
            try self.packCallArg(arg_node, param_ty, mode, &args, &arg_word_count);
        }

        const callee_ref = try self.lowerAst(callee);
        const call_value = try self.addInst(.{ .call = .{
            .callee = callee_ref,
            .argc = @intCast(arg_word_count),
            .args = args,
            .ret_slots = @intCast(ret_slots),
        } });
        if (ret_slots > 1) self.function.next_value += ret_slots - 1;
        return call_value;
    }

    fn lowerMonomorphizedCall(self: *@This(), idx: ast.NodeIdx, target_fn_id: FuncId) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const target_info = self.parent.typed.functions.items[target_fn_id];
        const call_args = a.callArgs(idx);
        const mono_params = target_info.ty.params;
        const param_modes = target_info.param_modes;

        const ret_slots = try self.typeSlotCount(target_info.ty.ret);
        const mask = if (target_info.decl != std.math.maxInt(ast.NodeIdx))
            a.fnComptimeMask(target_info.decl)
        else
            0;

        var args: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        var arg_word_count: usize = 0;
        var runtime_idx: usize = 0;
        for (call_args, 0..) |arg_node, arg_idx| {
            if (mask & (@as(u32, 1) << @intCast(arg_idx)) != 0) continue;
            const param_ty = mono_params[runtime_idx];
            const mode = if (runtime_idx < param_modes.len) param_modes[runtime_idx] else ast.ParamAccessMode.read;
            try self.packCallArg(arg_node, param_ty, mode, &args, &arg_word_count);
            runtime_idx += 1;
        }

        const call_value = try self.addInst(.{ .direct_call = .{
            .callee = target_fn_id,
            .argc = @intCast(arg_word_count),
            .args = args,
            .ret_slots = @intCast(ret_slots),
        } });
        if (ret_slots > 1) self.function.next_value += ret_slots - 1;
        return call_value;
    }

    fn lowerDirectCall(self: *@This(), idx: ast.NodeIdx, fn_id: FuncId) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const fn_info = self.parent.typed.functions.items[fn_id];
        const call_args = a.callArgs(idx);
        const fn_ty = fn_info.ty;
        const param_modes = fn_info.param_modes;

        const ret_slots = try self.typeSlotCount(fn_ty.ret);

        var args: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        var arg_word_count: usize = 0;
        for (call_args, fn_ty.params, 0..) |arg_node, param_ty, arg_idx| {
            const mode = if (arg_idx < param_modes.len) param_modes[arg_idx] else ast.ParamAccessMode.read;
            try self.packCallArg(arg_node, param_ty, mode, &args, &arg_word_count);
        }

        const call_value = try self.addInst(.{ .direct_call = .{
            .callee = fn_id,
            .argc = @intCast(arg_word_count),
            .args = args,
            .ret_slots = @intCast(ret_slots),
        } });
        if (ret_slots > 1) self.function.next_value += ret_slots - 1;
        return call_value;
    }

    fn lowerIf(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const data = a.ifData(idx);
        const if_ty = try self.nodeType(idx);

        const cond_tag = a.nodes[data.cond].tag;
        const is_if_binding = cond_tag == .const_decl or cond_tag == .var_decl;
        const cond_binding = try self.setupIfCondBinding(data.cond);

        const then_block_id = try self.newBlock(null);
        const else_block_id = try self.newBlock(null);
        const merge_block_id = try self.newBlock(if_ty);
        const condition_entry_block = self.current_block_id;
        const cond_mark = self.bindings.mark();
        if (cond_binding) |binding| {
            if (binding.is_query) {
                try self.lowerVariantQueryCondition(condition_entry_block, binding.as_node, binding.slot, binding.slot_count, then_block_id, else_block_id);
            } else {
                try self.lowerVariantAsCondition(condition_entry_block, binding.as_node, binding.slot, binding.slot_count, then_block_id, else_block_id);
            }
        } else {
            const cond_node = if (is_if_binding)
                a.varDeclValue(data.cond)
            else
                data.cond;
            try self.lowerConditionToBranches(condition_entry_block, cond_node, then_block_id, else_block_id);
        }

        self.current_block_id = then_block_id;
        const then_value = then_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            if (cond_binding) |binding| {
                try self.pushBinding(binding.name, .{
                    .storage = .{ .local_slot = binding.slot },
                    .ty = binding.ty,
                    .slot_count = binding.slot_count,
                });
            } else if (is_if_binding) {
                const binding_ty = self.parent.typed.decl_binding_types.get(data.cond) orelse .unit;
                const slot_count = try self.typeSlotCount(binding_ty);
                const slot = try self.allocSlotRange(slot_count);
                const unit_val = try self.lowerUnitValue();
                try self.emitCopySlots(unit_val, slot, slot_count);
                try self.pushBinding(a.identOf(a.nodes[data.cond].data0), .{
                    .storage = .{ .local_slot = slot },
                    .ty = binding_ty,
                    .slot_count = slot_count,
                });
            }
            break :then_blk try self.lowerAst(data.then_);
        };
        var then_fallthrough = false;
        if (self.currentBlock().terminator == null) {
            const arg = if (if_ty == .variant)
                try self.wrapValueRefToType(then_value, try self.parent.typed.typeOf(data.then_), if_ty)
            else
                then_value;
            self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = arg } };
            then_fallthrough = true;
        }

        self.bindings.restore(cond_mark);

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
            const arg = if (if_ty == .variant)
                try self.wrapValueRefToType(else_value, if (data.else_ != std.math.maxInt(ast.NodeIdx)) try self.parent.typed.typeOf(data.else_) else analyze.Type.unit, if_ty)
            else
                else_value;
            self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = arg } };
            else_fallthrough = true;
        }

        self.current_block_id = merge_block_id;
        if (then_fallthrough or else_fallthrough) return self.currentBlock().param orelse unreachable;
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
        const raw_value_ref = try self.lowerValueAsType(value, binding_ty);
        const value_ref = try self.applyImplicitCopy(value, raw_value_ref, binding_ty);
        const slot_count = try self.typeSlotCount(binding_ty);
        const var_slot = try self.allocSlotRange(slot_count);
        try self.emitCopySlots(value_ref, var_slot, slot_count);
        try self.pushBinding(name, .{
            .storage = .{ .local_slot = var_slot },
            .ty = binding_ty,
            .slot_count = slot_count,
        });
        return var_slot;
    }

    fn lowerConst(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        return self.lowerVar(idx);
    }

    fn lowerAssign(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const name = a.identOf(a.nodes[idx].data0);
        const binding = self.lookupBinding(name) orelse return error.UnknownSymbol;
        const raw_value_ref = try self.lowerValueAsType(a.nodes[idx].data1, binding.ty);
        const value_ref = try self.applyImplicitCopy(a.nodes[idx].data1, raw_value_ref, binding.ty);
        switch (binding.storage) {
            .local_slot => |slot| try self.emitCopySlots(value_ref, slot, binding.slot_count),
            .borrowed_ptr => |ptr_slot| {
                _ = self.loaded_ptrs.remove(ptr_slot);
                var offset: u32 = 0;
                while (offset < binding.slot_count) : (offset += 1) {
                    _ = try self.addInst(.{
                        .store_ptr = .{
                            .ptr = ptr_slot,
                            .src = value_ref + offset,
                            .offset_slots = offset,
                        },
                    });
                }
            },
        }
        return self.lowerUnitValue();
    }

    fn resolveFieldChainRoot(self: *@This(), node: ast.NodeIdx) struct { root: ast.NodeIdx, field_sum: u32 } {
        const a = self.parent.typed.ast;
        var current = node;
        var field_sum: u32 = 0;
        while (a.nodes[current].tag == .field_access) {
            const f_idx = self.parent.typed.field_index.get(current) orelse break;
            field_sum += f_idx;
            current = a.nodes[current].data0;
        }
        return .{ .root = current, .field_sum = field_sum };
    }

    fn lowerFieldAssign(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const field_node = a.nodes[idx].data0;
        const value_node = a.nodes[idx].data1;
        const field_ty = try self.parent.typed.typeOf(field_node);
        const value_ref = try self.lowerValueAsType(value_node, field_ty);
        const chain = self.resolveFieldChainRoot(field_node);
        if (a.nodes[chain.root].tag == .var_ref) {
            const name = a.identOf(a.nodes[chain.root].data0);
            if (self.lookupBinding(name)) |binding| {
                switch (binding.storage) {
                    .local_slot => |slot| {
                        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = slot + chain.field_sum } });
                    },
                    .borrowed_ptr => |ptr_slot| {
                        _ = self.loaded_ptrs.remove(ptr_slot);
                        _ = try self.addInst(.{
                            .store_ptr = .{
                                .ptr = ptr_slot,
                                .src = value_ref,
                                .offset_slots = chain.field_sum,
                            },
                        });
                    },
                }
                return self.lowerUnitValue();
            }
        }
        const base_ref = try self.lowerAst(chain.root);
        const dst_slot = base_ref + chain.field_sum;
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = dst_slot } });
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
            .unit, .none => self.lowerUnitValue(),
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
        if (self.lookupBinding(name)) |binding| return self.lowerBindingValue(binding);
        if (self.parent.typed.comptime_values.get(name)) |cv| {
            return self.lowerComptimeValue(cv);
        }
        const fn_id = self.parent.function_ids.get(name) orelse return error.UnknownFunction;
        return self.addInst(.{ .fn_addr = fn_id });
    }

    fn lowerAsValue(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const lhs = a.isLhs(idx);
        const lhs_base = try self.lowerAst(lhs);
        const lhs_ty = try self.nodeType(lhs);
        const lhs_variant = switch (lhs_ty) {
            .variant => |variant_ty| variant_ty,
            else => return error.IfConditionNotFallible,
        };
        const rhs_ty = try self.nodeType(idx);
        if (variantMemberIndex(lhs_variant, rhs_ty) == null) return error.IfConditionNotFallible;
        const payload_slots = try self.typeSlotCount(rhs_ty);
        const result_base = try self.allocSlotRange(payload_slots);
        try self.emitCopySlots(lhs_base + 1, result_base, payload_slots);
        return result_base;
    }

    fn lowerQueryOpValue(self: *@This(), idx: ast.NodeIdx) LowerResult!ValueRef {
        const a = self.parent.typed.ast;
        const lhs = a.isLhs(idx);
        const lhs_base = try self.lowerAst(lhs);
        const result_ty = try self.nodeType(idx);
        const binding_slots = try self.typeSlotCount(result_ty);
        const result_base = try self.allocSlotRange(binding_slots);
        const copy_offset: ValueRef = if (result_ty == .variant) 0 else 1;
        try self.emitCopySlots(lhs_base + copy_offset, result_base, binding_slots);
        return result_base;
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
            .unit_lit, .none_lit => try self.lowerUnitValue(),
            .var_ref => blk: {
                const name = a.identOf(a.nodes[idx].data0);
                break :blk try self.lowerVarRef(name);
            },
            .var_decl => try self.lowerVar(idx),
            .const_decl => try self.lowerConst(idx),
            .assign => try self.lowerAssign(idx),
            .field_assign => try self.lowerFieldAssign(idx),
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
            .lt, .gt, .le, .ge, .eq, .ne, .is, .@"and", .@"or", .@"not" => error.IfConditionNotFallible,
            .as => try self.lowerAsValue(idx),
            .query_op => try self.lowerQueryOpValue(idx),
            .if_stmt => try self.lowerIf(idx),
            .struct_init => try self.lowerStructInit(idx),
            .move_expr => blk: {
                const source = a.nodes[idx].data0;
                const source_ty = try self.nodeType(source);
                const source_ref = try self.lowerAst(source);
                const spec = self.ownershipSpecForType(source_ty) orelse break :blk source_ref;
                if (spec.move.kind != .func) break :blk source_ref;
                const hook_fn = spec.move.hook_fn orelse break :blk source_ref;
                break :blk try self.emitMoveHook(hook_fn, source_ref, source_ty);
            },
            .field_access => try self.lowerFieldAccess(idx),
            .comptime_expr, .sizeof_expr => blk: {
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
        const mask = a.fnComptimeMask(self.info.decl);
        var runtime_idx: usize = 0;
        for (params, 0..) |param, param_idx| {
            if (mask & (@as(u32, 1) << @intCast(param_idx)) != 0) continue;
            if (runtime_idx >= self.info.ty.params.len) return error.UnknownFunction;
            const param_ty = self.info.ty.params[runtime_idx];
            const mode = if (runtime_idx < self.info.param_modes.len) self.info.param_modes[runtime_idx] else ast.ParamAccessMode.read;
            const pname = a.identOf(param.name);
            const slot_count = try self.typeSlotCount(param_ty);
            switch (mode) {
                .read => {
                    if (isReadByValueTy(param_ty)) {
                        if (self.function.param_values.items.len + slot_count > MaxCallArgs) return error.TooManyCallArgs;
                        const slot = try self.allocSlotRange(slot_count);
                        var slot_offset: u32 = 0;
                        while (slot_offset < slot_count) : (slot_offset += 1) {
                            try self.function.param_values.append(self.parent.gpa, slot + slot_offset);
                        }
                        try self.pushBinding(pname, .{
                            .storage = .{ .local_slot = slot },
                            .ty = param_ty,
                            .slot_count = slot_count,
                        });
                    } else {
                        if (self.function.param_values.items.len + 1 > MaxCallArgs) return error.TooManyCallArgs;
                        const ptr_slot = try self.allocValue();
                        try self.function.param_values.append(self.parent.gpa, ptr_slot);
                        try self.pushBinding(pname, .{
                            .storage = .{ .borrowed_ptr = ptr_slot },
                            .ty = param_ty,
                            .slot_count = slot_count,
                        });
                    }
                },
                .mut => {
                    if (self.function.param_values.items.len + 1 > MaxCallArgs) return error.TooManyCallArgs;
                    const ptr_slot = try self.allocValue();
                    try self.function.param_values.append(self.parent.gpa, ptr_slot);
                    try self.pushBinding(pname, .{
                        .storage = .{ .borrowed_ptr = ptr_slot },
                        .ty = param_ty,
                        .slot_count = slot_count,
                    });
                },
                .var_mode, .deinit => {
                    if (self.function.param_values.items.len + slot_count > MaxCallArgs) return error.TooManyCallArgs;
                    const slot = try self.allocSlotRange(slot_count);
                    var slot_offset: u32 = 0;
                    while (slot_offset < slot_count) : (slot_offset += 1) {
                        try self.function.param_values.append(self.parent.gpa, slot + slot_offset);
                    }
                    try self.pushBinding(pname, .{
                        .storage = .{ .local_slot = slot },
                        .ty = param_ty,
                        .slot_count = slot_count,
                    });
                },
            }
            runtime_idx += 1;
        }
    }

    fn isGenericFunction(self: *const @This()) bool {
        if (self.info.decl == std.math.maxInt(ast.NodeIdx)) return false;
        if (self.info.is_monomorphized) return false;
        const comptime_mask = self.parent.typed.ast.fnComptimeMask(self.info.decl);
        return comptime_mask != 0;
    }

    fn run(self: *@This()) !Function {
        try self.setupParams();
        if (self.isGenericFunction()) {
            const stub_ret = try self.lowerUnitValue();
            self.currentBlock().terminator = .{ .ret = stub_ret };
            self.bindings.deinit(self.parent.gpa);
            self.loaded_ptrs.deinit();
            return self.function;
        }

        const a = self.parent.typed.ast;
        const body = if (self.info.decl == std.math.maxInt(ast.NodeIdx))
            a.entry
        else
            a.fnBody(self.info.decl);
        const result = try self.lowerAst(body);
        if (self.currentBlock().terminator == null) {
            const body_ty = try self.parent.typed.typeOf(body);
            const wrapped = try self.wrapValueRefToType(result, body_ty, self.info.ty.ret);
            self.currentBlock().terminator = .{ .ret = wrapped };
        }

        self.bindings.deinit(self.parent.gpa);
        self.loaded_ptrs.deinit();
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
