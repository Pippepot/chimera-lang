const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const typecheck = @import("typecheck.zig");
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
    lti: InstPair,
    ltf: InstPair,
    gti: InstPair,
    gtf: InstPair,
    lei: InstPair,
    lef: InstPair,
    gei: InstPair,
    gef: InstPair,
    eqi: InstPair,
    eqf: InstPair,
    eqb: InstPair,
    nei: InstPair,
    nef: InstPair,
    neb: InstPair,
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
    cbr: struct {
        cond: ValueRef,
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
    bindings: std.ArrayList(Binding),
    prog: Program,
    current_block_id: BlockId,

    const Binding = struct {
        name: []const u8,
        value_ref: ValueRef,
    };

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
            .bindings = .empty,
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
        if (self.lookupBinding(name) != null) return error.DuplicateVariable;
        try self.bindings.append(self.gpa, .{ .name = name, .value_ref = value_ref });
    }

    fn lookupBinding(self: *const @This(), name: []const u8) ?ValueRef {
        var idx = self.bindings.items.len;
        while (idx > 0) {
            idx -= 1;
            const binding = self.bindings.items[idx];
            if (std.mem.eql(u8, binding.name, name)) return binding.value_ref;
        }
        return null;
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

    fn lowerElseValue(self: *@This(), else_node: ?*const AstNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        if (else_node) |node| return self.lowerAst(node);
        return self.addInst(.{ .iconst = 0 }, .unit);
    }

    fn nodeType(self: *const @This(), node: *const AstNode) typecheck.TypeError!Type {
        return self.typed.typeOf(node);
    }

    fn lowerIf(self: *@This(), node: *const AstNode, if_node: *const ast.IfNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        const condition_value = try self.lowerAst(if_node.cond);
        const if_ty = try self.nodeType(node);

        const then_block_id = try self.newBlock(null);
        const else_block_id = try self.newBlock(null);
        const merge_block_id = try self.newBlock(if_ty);

        self.currentBlock().terminator = .{
            .cbr = .{
                .cond = condition_value,
                .then_branch = .{ .target = then_block_id },
                .else_branch = .{ .target = else_block_id },
            },
        };

        self.current_block_id = then_block_id;
        const then_value = try self.lowerAst(if_node.then_);
        self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = then_value } };

        self.current_block_id = else_block_id;
        const else_value = try self.lowerElseValue(if_node.else_);
        self.currentBlock().terminator = .{ .br = .{ .target = merge_block_id, .arg = else_value } };

        self.current_block_id = merge_block_id;
        return self.currentBlock().param orelse unreachable;
    }

    fn lowerConst(self: *@This(), node: *const AstNode, const_node: *const ast.ConstNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        _ = node;
        const value_ref = try self.lowerAst(const_node.value);
        try self.pushBinding(const_node.name, value_ref);
        return self.lowerAst(const_node.body);
    }

    fn lowerAst(self: *@This(), node: *const AstNode) (error{OutOfMemory} || typecheck.TypeError)!ValueRef {
        return switch (node.*) {
            .int => |value| try self.addInst(.{ .iconst = value }, .int),
            .float => |value| try self.addInst(.{ .fconst = value }, .float),
            .var_ref => |name| self.lookupBinding(name) orelse return error.UnknownVariable,
            .seq => |kids| block: {
                _ = try self.lowerAst(&kids[0]);
                break :block try self.lowerAst(&kids[1]);
            },
            .const_ => |const_node| try self.lowerConst(node, const_node),
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
            .add => |kids| switch (try self.nodeType(node)) {
                .int => try self.addPairInst(.addi, kids, .int),
                .float => try self.addPairInst(.addf, kids, .float),
                else => unreachable,
            },
            .sub => |kids| switch (try self.nodeType(node)) {
                .int => try self.addPairInst(.subi, kids, .int),
                .float => try self.addPairInst(.subf, kids, .float),
                else => unreachable,
            },
            .mul => |kids| switch (try self.nodeType(node)) {
                .int => try self.addPairInst(.muli, kids, .int),
                .float => try self.addPairInst(.mulf, kids, .float),
                else => unreachable,
            },
            .div => |kids| switch (try self.nodeType(node)) {
                .int => try self.addPairInst(.divi, kids, .int),
                .float => try self.addPairInst(.divf, kids, .float),
                else => unreachable,
            },
            .arg => |idx| try self.addInst(.{ .argi = idx }, .int),
            .lt => |kids| {
                const operand_ty = try self.nodeType(&kids[0]);
                if (operand_ty == .int) return self.addPairInst(.lti, kids, .unit);
                return self.addPairInst(.ltf, kids, .unit);
            },
            .gt => |kids| {
                const operand_ty = try self.nodeType(&kids[0]);
                if (operand_ty == .int) return self.addPairInst(.gti, kids, .unit);
                return self.addPairInst(.gtf, kids, .unit);
            },
            .le => |kids| {
                const operand_ty = try self.nodeType(&kids[0]);
                if (operand_ty == .int) return self.addPairInst(.lei, kids, .unit);
                return self.addPairInst(.lef, kids, .unit);
            },
            .ge => |kids| {
                const operand_ty = try self.nodeType(&kids[0]);
                if (operand_ty == .int) return self.addPairInst(.gei, kids, .unit);
                return self.addPairInst(.gef, kids, .unit);
            },
            .eq => |kids| {
                const operand_ty = try self.nodeType(&kids[0]);
                return switch (operand_ty) {
                    .int => self.addPairInst(.eqi, kids, .unit),
                    .float => self.addPairInst(.eqf, kids, .unit),
                    .bool => self.addPairInst(.eqb, kids, .unit),
                    .unit => unreachable,
                };
            },
            .ne => |kids| {
                const operand_ty = try self.nodeType(&kids[0]);
                return switch (operand_ty) {
                    .int => self.addPairInst(.nei, kids, .unit),
                    .float => self.addPairInst(.nef, kids, .unit),
                    .bool => self.addPairInst(.neb, kids, .unit),
                    .unit => unreachable,
                };
            },
            .if_ => |if_node| try self.lowerIf(node, if_node),
            .bool => |value| try self.addInst(.{ .iconst = if (value) @as(i32, 1) else 0 }, .bool),
            .unit => try self.addInst(.{ .iconst = 0 }, .unit),
        };
    }
};

const parser = @import("parser.zig");
const db = @import("db.zig");

pub const LowerMemo = struct {
    value: ?Program,
    diagnostics: std.ArrayList(diagnostics.Diagnostic),
    deps: std.ArrayList(db.Dependency),
    verified_at: db.Revision,
    changed_at: db.Revision,
    computing: bool,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        if (self.value) |*program| program.deinit(gpa);
        self.diagnostics.deinit(gpa);
        self.deps.deinit(gpa);
    }
};

pub fn computeLower(type_memo: *const typecheck.TypeMemo, parse_memo: *const parser.ParseMemo, gpa: std.mem.Allocator) error{OutOfMemory}!LowerMemo {
    var diagnostics_list = try std.ArrayList(diagnostics.Diagnostic).initCapacity(gpa, type_memo.diagnostics.items.len + 1);
    errdefer diagnostics_list.deinit(gpa);
    try diagnostics_list.appendSlice(gpa, type_memo.diagnostics.items);

    var lowered_value: ?Program = null;
    if (type_memo.value != null and parse_memo.value != null) {
        const lowered = lower(parse_memo.value.?.root, &type_memo.value.?, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                try diagnostics_list.append(gpa, .{
                    .stage = .lower,
                    .span = null,
                    .message = @errorName(err),
                });
                break :blk null;
            },
        };
        lowered_value = lowered;
    }

    return .{
        .value = lowered_value,
        .diagnostics = diagnostics_list,
        .deps = .empty,
        .verified_at = 0,
        .changed_at = 0,
        .computing = false,
    };
}

pub fn lower(node: *const AstNode, typed: *const typecheck.TypedAst, gpa: std.mem.Allocator) (error{OutOfMemory} || typecheck.TypeError)!Program {
    var lowerer = try Lowerer.init(gpa, typed);
    errdefer lowerer.prog.deinit(gpa);
    defer lowerer.bindings.deinit(gpa);

    const result = try lowerer.lowerAst(node);
    lowerer.currentBlock().terminator = .{ .ret = result };

    return lowerer.prog;
}
