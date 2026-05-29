const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const typecheck = @import("typecheck.zig");
const scope_mod = @import("scope.zig");
const AstNode = ast.AstNode;
const Type = typecheck.Type;

pub const ValueRef = u32;
pub const BlockId = u32;

pub const InstPair = struct {
    l: ValueRef,
    r: ValueRef,
};

pub const Inst = union(enum) {
    iconst: i32,
    fconst: f32,
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

pub const Program = struct {
    entry: BlockId,
    blocks: std.ArrayList(Block),
    value_types: std.ArrayList(Type),
    next_value: ValueRef,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
        self.value_types.deinit(gpa);
    }
};

const Lowerer = struct {
    gpa: std.mem.Allocator,
    typed: *const typecheck.TypedAst,
    bindings: scope_mod.ScopeStack(ValueRef),
    prog: Program,
    current_block_id: BlockId,

    fn init(gpa: std.mem.Allocator, typed: *const typecheck.TypedAst) error{OutOfMemory}!Lowerer {
        var blocks = try std.ArrayList(Block).initCapacity(gpa, 8);
        errdefer blocks.deinit(gpa);
        var value_types = try std.ArrayList(Type).initCapacity(gpa, 32);
        errdefer value_types.deinit(gpa);

        const entry_param: ?ValueRef = null;
        var entry_block = try Block.init(gpa, 0, entry_param);
        errdefer entry_block.deinit(gpa);
        try blocks.append(gpa, entry_block);

        return .{
            .gpa = gpa,
            .typed = typed,
            .bindings = scope_mod.ScopeStack(ValueRef).init(),
            .prog = .{
                .entry = 0,
                .blocks = blocks,
                .value_types = value_types,
                .next_value = 0,
            },
            .current_block_id = 0,
        };
    }

    fn currentBlock(self: *@This()) *Block {
        return &self.prog.blocks.items[self.current_block_id];
    }

    fn pushBinding(self: *@This(), name: []const u8, value_ref: ValueRef) (std.mem.Allocator.Error || typecheck.TypeError)!void {
        self.bindings.push(self.gpa, name, value_ref) catch |err| switch (err) {
            error.DuplicateVariable => return error.DuplicateVariable,
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    fn lookupBinding(self: *const @This(), name: []const u8) ?ValueRef {
        return self.bindings.lookup(name);
    }

    fn allocValue(self: *@This(), ty: Type) error{OutOfMemory}!ValueRef {
        const value_id = self.prog.next_value;
        self.prog.next_value += 1;
        try self.prog.value_types.append(self.gpa, ty);
        return value_id;
    }

    fn addInst(self: *@This(), op: Inst, ty: Type) error{OutOfMemory}!ValueRef {
        const value_id = try self.allocValue(ty);
        try self.currentBlock().insts.append(self.gpa, .{ .id = value_id, .op = op });
        return value_id;
    }

    fn newBlock(self: *@This(), param_type: ?Type) error{OutOfMemory}!BlockId {
        const block_id: BlockId = @intCast(self.prog.blocks.items.len);
        const block_param = if (param_type) |ty| try self.allocValue(ty) else null;
        var block = try Block.init(self.gpa, block_id, block_param);
        errdefer block.deinit(self.gpa);
        try self.prog.blocks.append(self.gpa, block);
        return block_id;
    }

    fn lowerPairOperands(self: *@This(), kids: *const [2]AstNode) (error{OutOfMemory} || typecheck.TypeError)!InstPair {
        const left = try self.lowerAst(&kids[0]);
        const right = try self.lowerAst(&kids[1]);
        return .{ .l = left, .r = right };
    }

    fn addPairInst(self: *@This(), comptime tag: std.meta.Tag(Inst), kids: *const [2]AstNode, result_type: Type) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        const operands = try self.lowerPairOperands(kids);
        return self.addInst(@unionInit(Inst, @tagName(tag), operands), result_type);
    }

    fn lowerUnitValue(self: *@This()) error{OutOfMemory}!ValueRef {
        return self.addInst(.{ .iconst = 0 }, .unit);
    }

    fn lowerElseValue(self: *@This(), else_node: ?*const AstNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        if (else_node) |node| {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            return self.lowerAst(node);
        }
        return self.lowerUnitValue();
    }

    fn nodeType(self: *const @This(), node: *const AstNode) typecheck.TypeError!Type {
        return self.typed.typeOf(node);
    }

    fn lowerComparisonPredicate(
        self: *@This(),
        kids: *const [2]AstNode,
        int_op: PredicateOp,
        float_op: PredicateOp,
    ) (error{OutOfMemory} || typecheck.TypeError)!Predicate {
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
    ) (error{OutOfMemory} || typecheck.TypeError)!Predicate {
        const pair = try self.lowerPairOperands(kids);
        const operand_ty = try self.nodeType(&kids[0]);
        return .{
            .op = switch (operand_ty) {
                .int => int_op,
                .float => float_op,
                .bool => bool_op,
                .unit => unreachable,
            },
            .pair = pair,
        };
    }

    fn lowerConditionPredicate(self: *@This(), cond: *const AstNode) (error{OutOfMemory} || typecheck.TypeError)!Predicate {
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

    fn lowerIf(self: *@This(), node: *const AstNode, if_node: *const ast.IfNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
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

        self.current_block_id = then_block_id;
        const then_value = then_blk: {
            const mark = self.bindings.mark();
            defer self.bindings.restore(mark);
            break :then_blk try self.lowerAst(if_node.then_);
        };
        self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = then_value } };

        self.current_block_id = else_block_id;
        const else_value = try self.lowerElseValue(if_node.else_);
        self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = else_value } };

        self.current_block_id = merge_block_id;
        return self.currentBlock().param orelse unreachable;
    }

    fn lowerConst(self: *@This(), const_node: *const ast.ConstNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        const value_ref = try self.lowerAst(const_node.value);
        try self.pushBinding(const_node.name, value_ref);
        return self.lowerUnitValue();
    }

    fn lowerVar(self: *@This(), var_node: *const ast.VarNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        const value_ref = try self.lowerAst(var_node.value);
        const var_slot = try self.allocValue(try self.nodeType(var_node.value));
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = var_slot } }, .unit);
        try self.pushBinding(var_node.name, var_slot);
        return self.lowerUnitValue();
    }

    fn lowerAssign(self: *@This(), assign_node: *const ast.VarNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        const value_ref = try self.lowerAst(assign_node.value);
        const var_slot = self.lookupBinding(assign_node.name) orelse return error.UnknownVariable;
        _ = try self.addInst(.{ .store = .{ .l = value_ref, .r = var_slot } }, .unit);
        return self.lowerUnitValue();
    }

    fn lowerBlock(self: *@This(), block_node: *const ast.BlockNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        const mark = self.bindings.mark();
        defer self.bindings.restore(mark);

        var result: ?ValueRef = null;
        for (block_node.items) |item| {
            result = try self.lowerAst(item);
        }
        if (result) |value| return value;
        return self.lowerUnitValue();
    }

    fn lowerArithmetic(self: *@This(), node: *const AstNode, kids: *const [2]AstNode, comptime int_tag: std.meta.Tag(Inst), comptime float_tag: std.meta.Tag(Inst)) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        return switch (try self.nodeType(node)) {
            .int => try self.addPairInst(int_tag, kids, .int),
            .float => try self.addPairInst(float_tag, kids, .float),
            else => unreachable,
        };
    }

    fn lowerAst(self: *@This(), node: *const AstNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        return switch (node.*) {
            .block => |block_node| try self.lowerBlock(block_node),
            .int => |value| try self.addInst(.{ .iconst = value }, .int),
            .float => |value| try self.addInst(.{ .fconst = value }, .float),
            .var_ref => |name| self.lookupBinding(name) orelse return error.UnknownVariable,
            .var_ => |var_node| try self.lowerVar(var_node),
            .assign => |assign_node| try self.lowerAssign(assign_node),
            .const_ => |const_node| try self.lowerConst(const_node),
            .print => |child| block: {
                const child_ref = try self.lowerAst(child);
                const child_ty = try self.nodeType(child);
                const print_op: Inst = switch (child_ty) {
                    .int => .{ .printi = child_ref },
                    .float => .{ .printf = child_ref },
                    .bool => .{ .printb = child_ref },
                    .unit => unreachable,
                };
                break :block try self.addInst(print_op, .unit);
            },
            .add => |kids| try self.lowerArithmetic(node, kids, .addi, .addf),
            .sub => |kids| try self.lowerArithmetic(node, kids, .subi, .subf),
            .mul => |kids| try self.lowerArithmetic(node, kids, .muli, .mulf),
            .div => |kids| try self.lowerArithmetic(node, kids, .divi, .divf),
            .arg => |idx| try self.addInst(.{ .argi = idx }, .int),
            .lt, .gt, .le, .ge, .eq, .ne => error.IfConditionNotFallible,
            .if_ => |if_node| try self.lowerIf(node, if_node),
            .bool => |value| try self.addInst(.{ .iconst = if (value) @as(i32, 1) else 0 }, .bool),
            .unit => try self.lowerUnitValue(),
        };
    }
};

const parser = @import("parser.zig");
const db = @import("db.zig");

pub const LowerMemo = db.Memo(Program);

pub fn computeLower(type_memo: *const typecheck.TypeMemo, parse_memo: *const parser.ParseMemo, gpa: std.mem.Allocator) error{OutOfMemory}!LowerMemo {
    var diagnostics_list = try db.initDiagnosticList(gpa, type_memo.diagnostics.items, 1);
    errdefer diagnostics_list.deinit(gpa);

    var lowered_value: ?Program = null;
    if (type_memo.value != null and parse_memo.value != null) {
        const lowered = lower(parse_memo.value.?.root, &type_memo.value.?, gpa) catch |err| switch (err) {
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

pub fn lower(node: *const AstNode, typed: *const typecheck.TypedAst, gpa: std.mem.Allocator) (error{OutOfMemory} || typecheck.TypeError)!Program {
    var lowerer = try Lowerer.init(gpa, typed);
    errdefer lowerer.prog.deinit(gpa);
    defer lowerer.bindings.deinit(gpa);

    const result = try lowerer.lowerAst(node);
    lowerer.currentBlock().terminator = .{ .ret = result };

    return lowerer.prog;
}
