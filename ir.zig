const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const typecheck = @import("typecheck.zig");
const monomorphize = @import("monomorphize.zig");
const scope_mod = @import("scope.zig");
const db = @import("db.zig");

const AstNode = ast.AstNode;
const Type = typecheck.Type;

pub const ValueRef = u32;
pub const BlockId = u32;
pub const FuncId = u32;
pub const MaxCallArgs: usize = 6;

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
    string_lit: u32,
    prints: ValueRef,
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
    name: []const u8,
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

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        for (self.functions.items) |*func| func.deinit(gpa);
        self.functions.deinit(gpa);
        for (self.strings.items) |s| gpa.free(s);
        self.strings.deinit(gpa);
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

    fn init(gpa: std.mem.Allocator, typed: *const typecheck.TypedAst, mono: *const monomorphize.MonoProgram) !Lowerer {
        var function_ids = std.StringHashMap(FuncId).init(gpa);
        errdefer function_ids.deinit();

        for (mono.functions.items, 0..) |mono_fn, idx| {
            try function_ids.put(mono_fn.decl.name, @intCast(idx));
        }

        return .{
            .gpa = gpa,
            .typed = typed,
            .mono = mono,
            .function_ids = function_ids,
            .strings = .empty,
        };
    }

    fn deinit(self: *@This()) void {
        self.function_ids.deinit();
        for (self.strings.items) |s| self.gpa.free(s);
        self.strings.deinit(self.gpa);
    }

    fn addString(self: *@This(), s: []const u8) !u32 {
        const owned = try self.gpa.dupe(u8, s);
        try self.strings.append(self.gpa, owned);
        return @intCast(self.strings.items.len - 1);
    }

    fn allocFunction(self: *@This(), id: FuncId, name: []const u8, ret_type: Type) !Function {
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
            .name = name,
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
        };
        self.strings = .empty;
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
        const ret_type = mono_fn.ty.ret;
        var function = try parent.allocFunction(fn_id, mono_fn.decl.name, ret_type);
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

    fn nodeType(self: *const @This(), node: *const AstNode) typecheck.TypeError!Type {
        return self.parent.typed.typeOf(node);
    }

    fn lowerPairOperands(self: *@This(), kids: *const [2]AstNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!InstPair {
        const left = try self.lowerAst(&kids[0]);
        const right = try self.lowerAst(&kids[1]);
        return .{ .l = left, .r = right };
    }

    fn addPairInst(
        self: *@This(),
        comptime tag: std.meta.Tag(Inst),
        kids: *const [2]AstNode,
        result_type: Type,
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const operands = try self.lowerPairOperands(kids);
        return self.addInst(@unionInit(Inst, @tagName(tag), operands), result_type);
    }

    fn lowerUnitValue(self: *@This()) error{OutOfMemory}!ValueRef {
        return self.addInst(.{ .iconst = 0 }, .unit);
    }

    fn lowerConditionPredicate(self: *@This(), cond: *const AstNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!Predicate {
        return switch (cond.*) {
            .lt => |kids| self.lowerComparisonPredicate(kids, .lti, .ltf),
            .gt => |kids| self.lowerComparisonPredicate(kids, .gti, .gtf),
            .le => |kids| self.lowerComparisonPredicate(kids, .lei, .lef),
            .ge => |kids| self.lowerComparisonPredicate(kids, .gei, .gef),
            .eq => |kids| self.lowerEqualityPredicate(kids, .eqi, .eqf, .eqb),
            .ne => |kids| self.lowerEqualityPredicate(kids, .nei, .nef, .neb),
            else => error.IfConditionNotFallible,
        };
    }

    fn lowerComparisonPredicate(
        self: *@This(),
        kids: *const [2]AstNode,
        int_op: PredicateOp,
        float_op: PredicateOp,
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!Predicate {
        const pair = try self.lowerPairOperands(kids);
        const operand_ty = try self.nodeType(&kids[0]);
        return .{
            .op = if (operand_ty == .int) int_op else float_op,
            .pair = pair,
        };
    }

    fn lowerEqualityPredicate(
        self: *@This(),
        kids: *const [2]AstNode,
        int_op: PredicateOp,
        float_op: PredicateOp,
        bool_op: PredicateOp,
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!Predicate {
        const pair = try self.lowerPairOperands(kids);
        const operand_ty = try self.nodeType(&kids[0]);
        return .{
            .op = switch (operand_ty) {
                .int => int_op,
                .float => float_op,
                .bool => bool_op,
                .unit, .named, .func, .string => unreachable,
            },
            .pair = pair,
        };
    }

    fn lowerArithmetic(
        self: *@This(),
        node: *const AstNode,
        kids: *const [2]AstNode,
        comptime int_tag: std.meta.Tag(Inst),
        comptime float_tag: std.meta.Tag(Inst),
    ) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        return switch (try self.nodeType(node)) {
            .int => try self.addPairInst(int_tag, kids, .int),
            .float => try self.addPairInst(float_tag, kids, .float),
            else => unreachable,
        };
    }

    fn lowerCall(self: *@This(), node: *const AstNode, call_node: *const ast.CallNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        if (call_node.args.len > MaxCallArgs) return error.TooManyCallArgs;

        var args: [MaxCallArgs]ValueRef = [_]ValueRef{0} ** MaxCallArgs;
        for (call_node.args, 0..) |arg_node, idx| {
            args[idx] = try self.lowerAst(arg_node);
        }

        const callee = try self.lowerAst(call_node.callee);
        return self.addInst(.{ .call = .{
            .callee = callee,
            .argc = @intCast(call_node.args.len),
            .args = args,
        } }, try self.nodeType(node));
    }

    fn lowerIf(self: *@This(), node: *const AstNode, if_node: *const ast.IfNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const predicate = try self.lowerConditionPredicate(if_node.cond);
        const if_ty = try self.nodeType(node);

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
            break :then_blk try self.lowerAst(if_node.then_);
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
            if (if_node.else_) |else_node| {
                break :else_blk try self.lowerAst(else_node);
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

    fn lowerBlock(self: *@This(), block_node: *const ast.BlockNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        var result: ?ValueRef = null;
        for (block_node.items) |item| {
            if (self.currentBlock().terminator != null) break;
            result = try self.lowerAst(item);
        }
        if (result) |value| return value;
        return self.lowerUnitValue();
    }

    fn lowerVar(self: *@This(), var_node: *const ast.VarNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        if (var_node.value.* == .struct_init) {
            const si = var_node.value.struct_init;
            const struct_decl = self.findStructDecl(si.struct_name) orelse unreachable;
            const field_count: u32 = @intCast(struct_decl.fields.len);
            const var_base = try self.allocValue(try self.nodeType(var_node.value));
            if (field_count > 1) {
                self.function.next_value += field_count - 1;
                var i: u32 = 0;
                while (i < field_count - 1) : (i += 1) {
                    try self.function.value_types.append(self.parent.gpa, try self.nodeType(var_node.value));
                }
            }
            for (si.fields, 0..) |field, idx| {
                const field_value = try self.lowerAst(field.value);
                const dst_slot: ValueRef = var_base + @as(ValueRef, @intCast(idx));
                _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } }, .unit);
            }
            try self.pushBinding(var_node.name, var_base);
            return self.lowerUnitValue();
        }
        const value_ref = try self.lowerAst(var_node.value);
        const var_slot = try self.allocValue(try self.nodeType(var_node.value));
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = var_slot } }, .unit);
        try self.pushBinding(var_node.name, var_slot);
        return self.lowerUnitValue();
    }

    fn lowerConst(self: *@This(), const_node: *const ast.ConstNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        if (const_node.value.* == .struct_init) {
            const si = const_node.value.struct_init;
            const struct_decl = self.findStructDecl(si.struct_name) orelse unreachable;
            const field_count: u32 = @intCast(struct_decl.fields.len);
            const const_base = try self.allocValue(try self.nodeType(const_node.value));
            if (field_count > 1) {
                self.function.next_value += field_count - 1;
                var i: u32 = 0;
                while (i < field_count - 1) : (i += 1) {
                    try self.function.value_types.append(self.parent.gpa, try self.nodeType(const_node.value));
                }
            }
            for (si.fields, 0..) |field, idx| {
                const field_value = try self.lowerAst(field.value);
                const dst_slot: ValueRef = const_base + @as(ValueRef, @intCast(idx));
                _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } }, .unit);
            }
            try self.pushBinding(const_node.name, const_base);
            return self.lowerUnitValue();
        }
        const value_ref = try self.lowerAst(const_node.value);
        try self.pushBinding(const_node.name, value_ref);
        return self.lowerUnitValue();
    }

    fn lowerAssign(self: *@This(), assign_node: *const ast.VarNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const value_ref = try self.lowerAst(assign_node.value);
        const dst = self.lookupBinding(assign_node.name) orelse return error.UnknownSymbol;
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = dst } }, .unit);
        return self.lowerUnitValue();
    }

    fn lowerReturn(self: *@This(), return_node: *const ast.ReturnNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const value_ref = try self.lowerAst(return_node.value);
        self.currentBlock().terminator = .{ .ret = value_ref };
        return value_ref;
    }

    fn findStructDecl(self: *const @This(), name: []const u8) ?*const ast.StructDecl {
        for (self.parent.mono.module.decls) |decl| {
            if (decl.* == .comptime_struct) {
                const st = decl.comptime_struct;
                if (std.mem.eql(u8, st.name, name)) return st;
            }
        }
        return null;
    }

    fn fieldIndex(self: *const @This(), struct_name: []const u8, field_name: []const u8) ?u32 {
        const st = self.findStructDecl(struct_name) orelse return null;
        for (st.fields, 0..) |f, idx| {
            if (std.mem.eql(u8, f.name, field_name)) return @intCast(idx);
        }
        return null;
    }

    fn lowerStructInit(self: *@This(), node: *const AstNode, si: *const ast.StructInitNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const field_count: u32 = @intCast(si.fields.len);
        const struct_type = try self.nodeType(node);
        const base = try self.allocValue(struct_type);
        if (field_count > 1) {
            self.function.next_value += field_count - 1;
            var i: u32 = 0;
            while (i < field_count - 1) : (i += 1) {
                try self.function.value_types.append(self.parent.gpa, struct_type);
            }
        }
        for (si.fields, 0..) |field, idx| {
            const field_value = try self.lowerAst(field.value);
            const dst_slot: ValueRef = base + @as(ValueRef, @intCast(idx));
            _ = try self.addInst(.{ .store = .{ .l = field_value, .r = dst_slot } }, .unit);
        }
        return base;
    }

    fn lowerFieldAccess(self: *@This(), node: *const AstNode, fa: *const ast.FieldAccessNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        const base = try self.lowerAst(fa.target);
        const target_type = try self.nodeType(fa.target);
        const struct_name = switch (target_type) {
            .named => |name| name,
            else => unreachable,
        };
        const f_idx = self.fieldIndex(struct_name, fa.field) orelse unreachable;
        if (f_idx == 0) return base;
        return self.addInst(.{ .field_load = .{ .base = base, .field_index = f_idx } }, try self.nodeType(node));
    }

    fn lowerVarRef(self: *@This(), name: []const u8) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        if (self.lookupBinding(name)) |value| return value;
        const fn_id = self.parent.function_ids.get(name) orelse return error.UnknownFunction;
        return self.addInst(.{ .fn_addr = fn_id }, .{ .func = self.parent.typed.functionType(fn_id) });
    }

    fn lowerAst(self: *@This(), node: *const AstNode) (error{OutOfMemory} || LowerError || typecheck.TypeError)!ValueRef {
        return switch (node.*) {
            .block => |blk| try self.lowerBlock(blk),
            .int => |value| try self.addInst(.{ .iconst = value }, .int),
            .float => |value| try self.addInst(.{ .fconst = value }, .float),
            .bool => |value| try self.addInst(.{ .iconst = if (value) @as(i32, 1) else 0 }, .bool),
            .unit => try self.lowerUnitValue(),
            .string => |s| blk: {
                const id = try self.parent.addString(s);
                break :blk try self.addInst(.{ .string_lit = id }, .string);
            },
            .var_ref => |name| try self.lowerVarRef(name),
            .var_ => |vn| try self.lowerVar(vn),
            .const_ => |cn| try self.lowerConst(cn),
            .assign => |an| try self.lowerAssign(an),
            .return_ => |rn| try self.lowerReturn(rn),
            .call => |call_node| try self.lowerCall(node, call_node),
            .print => |child| blk: {
                const child_ref = try self.lowerAst(child);
                const child_ty = try self.nodeType(child);
                const print_op: Inst = switch (child_ty) {
                    .int => .{ .printi = child_ref },
                    .float => .{ .printf = child_ref },
                    .bool => .{ .printb = child_ref },
                    .string => .{ .prints = child_ref },
                    else => unreachable,
                };
                break :blk try self.addInst(print_op, .unit);
            },
            .add => |kids| try self.lowerArithmetic(node, kids, .addi, .addf),
            .sub => |kids| try self.lowerArithmetic(node, kids, .subi, .subf),
            .mul => |kids| try self.lowerArithmetic(node, kids, .muli, .mulf),
            .div => |kids| try self.lowerArithmetic(node, kids, .divi, .divf),
            .arg => |idx| try self.addInst(.{ .argi = idx }, .int),
            .lt, .gt, .le, .ge, .eq, .ne => error.IfConditionNotFallible,
            .if_ => |if_node| try self.lowerIf(node, if_node),
            .struct_init => |si| try self.lowerStructInit(node, si),
            .field_access => |fa| try self.lowerFieldAccess(node, fa),
        };
    }

    fn setupParams(self: *@This()) !void {
        for (self.mono_fn.decl.params, self.mono_fn.ty.params) |param, param_ty| {
            const slot = try self.allocValue(param_ty);
            try self.function.param_values.append(self.parent.gpa, slot);
            try self.pushBinding(param.name, slot);
        }
    }

    fn run(self: *@This()) !Function {
        try self.setupParams();

        const result = try self.lowerAst(self.mono_fn.decl.body);
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
    if (mono_memo.value != null and type_memo.value != null) {
        const lowered = lower(&mono_memo.value.?, &type_memo.value.?, gpa) catch |err| switch (err) {
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

pub fn lower(mono: *const monomorphize.MonoProgram, typed: *const typecheck.TypedAst, gpa: std.mem.Allocator) !Program {
    var lowerer = try Lowerer.init(gpa, typed, mono);
    defer lowerer.deinit();

    return lowerer.lowerProgram();
}
