const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const typecheck = @import("typecheck.zig");
const monomorphize = @import("monomorphize.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

pub const StringId = u32;
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
    named: StringId,
    func: FuncTypeId,
};

pub const IrFuncType = struct {
    params: []const Type,
    ret: Type,
};

pub fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .unit, .bool, .int, .float => true,
        .named => |lhs| lhs == b.named,
        .func => |lhs| lhs == b.func,
    };
}

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
    insts: std.ArrayList(ValueInst),
    terminator: ?Terminator,

    pub fn init(gpa: std.mem.Allocator, id: BlockId, param: ?ValueRef) error{OutOfMemory}!Block {
        return .{
            .id = id,
            .param = param,
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
    name: StringId,
    entry: BlockId,
    blocks: std.ArrayList(Block),
    value_types: std.ArrayList(Type),
    next_value: ValueRef,
    param_values: std.ArrayList(ValueRef),
    ret_type: Type,

    pub fn deinit(self: *Function, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
        self.value_types.deinit(gpa);
        self.param_values.deinit(gpa);
    }
};

pub const Program = struct {
    entry: FuncId,
    functions: std.ArrayList(Function),
    strings: std.ArrayList([]const u8),
    func_types: std.ArrayList(IrFuncType),

    pub fn stringFor(self: *const Program, id: StringId) []const u8 {
        return self.strings.items[id];
    }

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        for (self.functions.items) |*func| func.deinit(gpa);
        self.functions.deinit(gpa);
        for (self.strings.items) |s| gpa.free(s);
        self.strings.deinit(gpa);
        for (self.func_types.items) |ft| gpa.free(ft.params);
        self.func_types.deinit(gpa);
    }
};

const LowerError = error{
    UnknownSymbol,
    UnknownFunction,
    TooManyCallArgs,
};

const Lowerer = struct {
    gpa: std.mem.Allocator,
    typed: *const typecheck.TypedAst,
    mono: *const monomorphize.MonoProgram,
    function_ids: std.StringHashMap(FuncId),
    strings: std.ArrayList([]const u8),
    string_map: std.StringHashMap(StringId),
    func_types: std.ArrayList(IrFuncType),
    func_type_map: std.AutoHashMap(usize, FuncTypeId),

    fn init(gpa: std.mem.Allocator, typed: *const typecheck.TypedAst, mono: *const monomorphize.MonoProgram) !Lowerer {
        var function_ids = std.StringHashMap(FuncId).init(gpa);
        errdefer function_ids.deinit();

        const a = typed.ast;
        for (mono.functions.items, 0..) |mono_fn, idx| {
            if (mono_fn.decl == std.math.maxInt(ast.NodeIdx)) continue;
            const name = a.stringOf(a.nodes[mono_fn.decl].data0);
            try function_ids.put(name, @intCast(idx));
        }

        return .{
            .gpa = gpa,
            .typed = typed,
            .mono = mono,
            .function_ids = function_ids,
            .strings = .empty,
            .string_map = .init(gpa),
            .func_types = .empty,
            .func_type_map = .init(gpa),
        };
    }

    fn deinit(self: *@This()) void {
        self.function_ids.deinit();
        self.string_map.deinit();
        self.func_type_map.deinit();
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.deinit(self.gpa);
        for (self.func_types.items) |ft| self.gpa.free(ft.params);
        self.func_types.deinit(self.gpa);
    }

    fn internString(self: *@This(), s: []const u8) !StringId {
        if (self.string_map.get(s)) |id| return id;
        const owned = try self.gpa.dupe(u8, s);
        errdefer self.gpa.free(owned);
        const id: StringId = @intCast(self.strings.items.len);
        try self.strings.append(self.gpa, owned);
        try self.string_map.put(owned, id);
        return id;
    }

    fn internType(self: *@This(), tc_ty: typecheck.Type) error{OutOfMemory}!Type {
        return switch (tc_ty) {
            .unit => .unit,
            .bool => .bool,
            .int => .int,
            .float => .float,
            .named => |name| .{ .named = try self.internString(name) },
            .func => |ft| .{ .func = try self.internFuncType(ft) },
        };
    }

    fn internFuncType(self: *@This(), ft: *const typecheck.FuncType) !FuncTypeId {
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

    fn stringFor(self: *const @This(), id: StringId) []const u8 {
        return self.strings.items[id];
    }

    fn allocFunction(self: *@This(), id: FuncId, name: []const u8, ret_type: Type) !Function {
        const name_id = try self.internString(name);
        var blocks = try std.ArrayList(Block).initCapacity(self.gpa, 8);
        errdefer blocks.deinit(self.gpa);

        var value_types = try std.ArrayList(Type).initCapacity(self.gpa, 32);
        errdefer value_types.deinit(self.gpa);

        var params = try std.ArrayList(ValueRef).initCapacity(self.gpa, 8);
        errdefer params.deinit(self.gpa);

        var entry_block = try Block.init(self.gpa, 0, null);
        errdefer entry_block.deinit(self.gpa);
        try blocks.append(self.gpa, entry_block);

        return .{
            .id = id,
            .name = name_id,
            .entry = 0,
            .blocks = blocks,
            .value_types = value_types,
            .next_value = 0,
            .param_values = params,
            .ret_type = ret_type,
        };
    }

    fn lowerProgram(self: *@This()) !Program {
        var functions = try std.ArrayList(Function).initCapacity(self.gpa, self.mono.functions.items.len);
        errdefer {
            for (functions.items) |*func| func.deinit(self.gpa);
            functions.deinit(self.gpa);
        }

        for (self.mono.functions.items, 0..) |mono_fn, idx| {
            var fn_lower = try FunctionLowerer.init(self, @intCast(idx), mono_fn);
            errdefer fn_lower.deinit();

            var lowered = try fn_lower.run();
            errdefer lowered.deinit(self.gpa);
            try functions.append(self.gpa, lowered);
        }

        const result = Program{
            .entry = self.mono.entry_function,
            .functions = functions,
            .strings = self.strings,
            .func_types = self.func_types,
        };
        self.strings = .empty;
        self.func_types = .empty;
        return result;
    }
};

const FunctionLowerer = struct {
    parent: *Lowerer,
    function: Function,
    bindings: scope_mod.ScopeStack(ValueRef),
    current_block_id: BlockId,
    mono_fn: monomorphize.MonoFunction,

    fn init(parent: *Lowerer, fn_id: FuncId, mono_fn: monomorphize.MonoFunction) !FunctionLowerer {
        const a = parent.typed.ast;
        const fn_name = if (mono_fn.decl == std.math.maxInt(ast.NodeIdx))
            ""
        else
            a.stringOf(a.nodes[mono_fn.decl].data0);
        const ret_type = try parent.internType(mono_fn.ty.ret);
        var function = try parent.allocFunction(fn_id, fn_name, ret_type);
        errdefer function.deinit(parent.gpa);

        return .{
            .parent = parent,
            .function = function,
            .bindings = scope_mod.ScopeStack(ValueRef).init(),
            .current_block_id = 0,
            .mono_fn = mono_fn,
        };
    }

    fn deinit(self: *@This()) void {
        self.bindings.deinit(self.parent.gpa);
        self.function.deinit(self.parent.gpa);
    }

    fn currentBlock(self: *@This()) *Block {
        return &self.function.blocks.items[self.current_block_id];
    }

    fn allocValue(self: *@This(), ty: Type) error{OutOfMemory}!ValueRef {
        const value_id = self.function.next_value;
        self.function.next_value += 1;
        try self.function.value_types.append(self.parent.gpa, ty);
        return value_id;
    }

    fn addInst(self: *@This(), op: Inst, ty: Type) error{OutOfMemory}!ValueRef {
        const value_id = try self.allocValue(ty);
        try self.currentBlock().insts.append(self.parent.gpa, .{ .id = value_id, .op = op });
        return value_id;
    }

    fn newBlock(self: *@This(), param_type: ?Type) error{OutOfMemory}!BlockId {
        const block_id: BlockId = @intCast(self.function.blocks.items.len);
        const block_param = if (param_type) |ty| try self.allocValue(ty) else null;
        var block = try Block.init(self.parent.gpa, block_id, block_param);
        errdefer block.deinit(self.parent.gpa);
        try self.function.blocks.append(self.parent.gpa, block);
        return block_id;
    }

    fn pushBinding(self: *@This(), name: []const u8, value_ref: ValueRef) !void {
        self.bindings.push(self.parent.gpa, name, value_ref) catch |err| switch (err) {
            error.DuplicateVariable => return error.UnknownSymbol,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn lookupBinding(self: *const @This(), name: []const u8) ?ValueRef {
        return self.bindings.lookup(name);
    }

    fn nodeType(self: *const @This(), idx: ast.NodeIdx) (std.mem.Allocator.Error || typecheck.TypeError)!Type {
        return self.parent.internType(try self.parent.typed.typeOf(idx));
    }

    fn lowerPairOperands(self: *@This(), lhs: ast.NodeIdx, rhs: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!InstPair {
        const left = try self.lowerAst(lhs);
        const right = try self.lowerAst(rhs);
        return .{ .l = left, .r = right };
    }

    fn addPairInst(
        self: *@This(),
        comptime tag: std.meta.Tag(Inst),
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
        result_type: Type,
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const operands = try self.lowerPairOperands(lhs, rhs);
        return self.addInst(@unionInit(Inst, @tagName(tag), operands), result_type);
    }

    fn lowerUnitValue(self: *@This()) error{OutOfMemory}!ValueRef {
        return self.addInst(.{ .iconst = 0 }, .unit);
    }

    fn lowerConditionPredicate(self: *@This(), cond: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!Predicate {
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

    fn lowerComparisonPredicate(
        self: *@This(),
        lhs: ast.NodeIdx,
        rhs: ast.NodeIdx,
        int_op: PredicateOp,
        float_op: PredicateOp,
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!Predicate {
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
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!Predicate {
        const pair = try self.lowerPairOperands(lhs, rhs);
        const operand_ty = try self.nodeType(lhs);
        return .{
            .op = switch (operand_ty) {
                .int => int_op,
                .float => float_op,
                .bool => bool_op,
                .unit, .named, .func => unreachable,
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
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        return switch (try self.nodeType(idx)) {
            .int => try self.addPairInst(int_tag, lhs, rhs, .int),
            .float => try self.addPairInst(float_tag, lhs, rhs, .float),
            else => unreachable,
        };
    }

    fn lowerCall(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
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
        } }, try self.nodeType(idx));
    }

    fn lowerIf(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const data = a.ifData(idx);
        const predicate = try self.lowerConditionPredicate(data.cond);
        const if_ty = try self.nodeType(idx);

        const then_block_id = try self.newBlock(null);
        const else_block_id = try self.newBlock(null);
        const merge_block_id = try self.newBlock(if_ty);

        self.currentBlock().terminator = .{
            .pbr = .{
                .pred = predicate,
                .then_branch = .{ .target = then_block_id },
                .else_branch = .{ .target = else_block_id },
            },
        };

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

    fn lowerBlock(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
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

    fn lowerVar(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const value = a.varDeclValue(idx);
        const name = a.stringOf(a.nodes[idx].data0);
        if (a.nodes[value].tag == .struct_init) {
            const si_name = a.stringOf(a.structInitName(value));
            const struct_decl = self.findStructDecl(si_name) orelse unreachable;
            const st_fields = a.structFields(struct_decl);
            const field_count: u32 = @intCast(st_fields.len);
            const var_base = try self.allocValue(try self.nodeType(value));
            if (field_count > 1) {
                self.function.next_value += field_count - 1;
                var i: u32 = 0;
                while (i < field_count - 1) : (i += 1) {
                    try self.function.value_types.append(self.parent.gpa, try self.nodeType(value));
                }
            }
            const init_fields = a.structInitFields(value);
            for (init_fields, 0..) |field, field_idx| {
                const field_value = try self.lowerAst(field.value);
                const dst_slot: ValueRef = var_base + @as(ValueRef, @intCast(field_idx));
                _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } }, .unit);
            }
            try self.pushBinding(name, var_base);
            return self.lowerUnitValue();
        }
        const value_ref = try self.lowerAst(value);
        const var_slot = try self.allocValue(try self.nodeType(value));
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = var_slot } }, .unit);
        try self.pushBinding(name, var_slot);
        return self.lowerUnitValue();
    }

    fn lowerConst(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const value = a.varDeclValue(idx);
        const name = a.stringOf(a.nodes[idx].data0);
        if (a.nodes[value].tag == .struct_init) {
            const si_name = a.stringOf(a.structInitName(value));
            const struct_decl = self.findStructDecl(si_name) orelse unreachable;
            const st_fields = a.structFields(struct_decl);
            const field_count: u32 = @intCast(st_fields.len);
            const const_base = try self.allocValue(try self.nodeType(value));
            if (field_count > 1) {
                self.function.next_value += field_count - 1;
                var i: u32 = 0;
                while (i < field_count - 1) : (i += 1) {
                    try self.function.value_types.append(self.parent.gpa, try self.nodeType(value));
                }
            }
            const init_fields = a.structInitFields(value);
            for (init_fields, 0..) |field, field_idx| {
                const field_value = try self.lowerAst(field.value);
                const dst_slot: ValueRef = const_base + @as(ValueRef, @intCast(field_idx));
                _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } }, .unit);
            }
            try self.pushBinding(name, const_base);
            return self.lowerUnitValue();
        }
        const value_ref = try self.lowerAst(value);
        try self.pushBinding(name, value_ref);
        return self.lowerUnitValue();
    }

    fn lowerAssign(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const name = a.stringOf(a.nodes[idx].data0);
        const value_ref = try self.lowerAst(a.nodes[idx].data1);
        const dst = self.lookupBinding(name) orelse return error.UnknownSymbol;
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = dst } }, .unit);
        return self.lowerUnitValue();
    }

    fn lowerReturn(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const value_ref = try self.lowerAst(a.nodes[idx].data0);
        self.currentBlock().terminator = .{ .ret = value_ref };
        return value_ref;
    }

    fn findStructDecl(self: *const @This(), name: []const u8) ?ast.NodeIdx {
        const a = self.parent.typed.ast;
        for (a.decls) |decl_idx| {
            if (a.nodes[decl_idx].tag == .comptime_struct) {
                const st_name = a.stringOf(a.nodes[decl_idx].data0);
                if (std.mem.eql(u8, st_name, name)) return decl_idx;
            }
        }
        return null;
    }

    fn fieldIndex(self: *const @This(), struct_name: []const u8, field_name: []const u8) ?u32 {
        const a = self.parent.typed.ast;
        const decl_idx = self.findStructDecl(struct_name) orelse return null;
        const fields = a.structFields(decl_idx);
        for (fields, 0..) |f, i| {
            const f_name = a.stringOf(f.name);
            if (std.mem.eql(u8, f_name, field_name)) return @intCast(i);
        }
        return null;
    }

    fn lowerStructInit(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const fields = a.structInitFields(idx);
        const field_count: u32 = @intCast(fields.len);
        const struct_type = try self.nodeType(idx);
        const base = try self.allocValue(struct_type);
        if (field_count > 1) {
            self.function.next_value += field_count - 1;
            var i: u32 = 0;
            while (i < field_count - 1) : (i += 1) {
                try self.function.value_types.append(self.parent.gpa, struct_type);
            }
        }
        for (fields, 0..) |field, field_idx| {
            const field_value = try self.lowerAst(field.value);
            const dst_slot: ValueRef = base + @as(ValueRef, @intCast(field_idx));
            _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } }, .unit);
        }
        return base;
    }

    fn lowerFieldAccess(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        const target = a.nodes[idx].data0;
        const field_name = a.stringOf(a.nodes[idx].data1);
        const base = try self.lowerAst(target);
        const target_type = try self.nodeType(target);
        const struct_name = switch (target_type) {
            .named => |name_id| self.parent.stringFor(name_id),
            else => unreachable,
        };
        const f_idx = self.fieldIndex(struct_name, field_name) orelse unreachable;
        if (f_idx == 0) return base;
        return self.addInst(.{ .field_load = .{ .base = base, .field_index = f_idx } }, try self.nodeType(idx));
    }

    fn lowerVarRef(self: *@This(), name: []const u8) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        if (self.lookupBinding(name)) |value| return value;
        const fn_id = self.parent.function_ids.get(name) orelse return error.UnknownFunction;
        const ft = self.parent.typed.functionType(fn_id);
        return self.addInst(.{ .fn_addr = fn_id }, .{ .func = try self.parent.internFuncType(ft) });
    }

    fn lowerAst(self: *@This(), idx: ast.NodeIdx) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const a = self.parent.typed.ast;
        return switch (a.nodes[idx].tag) {
            .block => try self.lowerBlock(idx),
            .int_lit => blk: {
                const value: i32 = @bitCast(a.nodes[idx].data0);
                break :blk try self.addInst(.{ .iconst = value }, .int);
            },
            .float_lit => blk: {
                const value: f32 = @bitCast(a.nodes[idx].data0);
                break :blk try self.addInst(.{ .fconst = value }, .float);
            },
            .bool_lit => blk: {
                const value = a.nodes[idx].data0 != 0;
                break :blk try self.addInst(.{ .iconst = if (value) @as(i32, 1) else 0 }, .bool);
            },
            .unit_lit => try self.lowerUnitValue(),
            .var_ref => blk: {
                const name = a.stringOf(a.nodes[idx].data0);
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
                break :blk try self.addInst(print_op, .unit);
            },
            .add => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .addi, .addf),
            .sub => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .subi, .subf),
            .mul => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .muli, .mulf),
            .div => try self.lowerArithmetic(idx, a.nodes[idx].data0, a.nodes[idx].data1, .divi, .divf),
            .arg => blk: {
                const arg_idx = a.nodes[idx].data0;
                break :blk try self.addInst(.{ .argi = arg_idx }, .int);
            },
            .lt, .gt, .le, .ge, .eq, .ne => error.IfConditionNotFallible,
            .if_stmt => try self.lowerIf(idx),
            .struct_init => try self.lowerStructInit(idx),
            .field_access => try self.lowerFieldAccess(idx),
            .type_name, .type_func, .comptime_fn, .comptime_struct => unreachable,
        };
    }

    fn setupParams(self: *@This()) !void {
        if (self.mono_fn.decl == std.math.maxInt(ast.NodeIdx)) return;
        const a = self.parent.typed.ast;
        const params = a.fnParams(self.mono_fn.decl);
        for (params, self.mono_fn.ty.params) |param, param_ty| {
            const pname = a.stringOf(param.name);
            const slot = try self.allocValue(try self.parent.internType(param_ty));
            try self.function.param_values.append(self.parent.gpa, slot);
            try self.pushBinding(pname, slot);
        }
    }

    fn run(self: *@This()) !Function {
        try self.setupParams();

        const a = self.parent.typed.ast;
        const body = if (self.mono_fn.decl == std.math.maxInt(ast.NodeIdx))
            a.entry
        else
            a.fnBody(self.mono_fn.decl);
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
    mono_memo: *const monomorphize.MonomorphizeMemo,
    type_memo: *const typecheck.TypeMemo,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!LowerMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, mono_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var lowered_value: ?Program = null;
    if (mono_memo.value) |*mono_val| {
        if (type_memo.value) |*type_val| {
            const lowered = lower(mono_val, type_val, gpa) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    try db.appendStageError(&diagnostics_list, gpa, .lower, @errorName(err));
                    break :blk null;
                },
            };
            lowered_value = lowered;
        }
    }

    return db.makeMemo(Program, lowered_value, diagnostics_list);
}

pub fn lower(mono: *const monomorphize.MonoProgram, typed: *const typecheck.TypedAst, gpa: std.mem.Allocator) !Program {
    var lowerer = try Lowerer.init(gpa, typed, mono);
    defer lowerer.deinit();

    return lowerer.lowerProgram();
}
