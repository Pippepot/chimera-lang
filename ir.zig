const std = @import("std");
const x86 = @import("x86.zig");
const AstNode = x86.AstNode;

pub const ValueRef = u32;
pub const BlockId = u32;

pub const InstPair = struct {
    l: ValueRef,
    r: ValueRef,
};

pub const Inst = union(enum) {
    iconst: i32,
    iadd: InstPair,
    isub: InstPair,
    imul: InstPair,
    idiv: InstPair,
    print: ValueRef,
    iarg: u32,
    ilt: InstPair,
    igt: InstPair,
    ile: InstPair,
    ige: InstPair,
    ieq: InstPair,
    ine: InstPair,
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
    term: ?Terminator,

    pub fn init(gpa: std.mem.Allocator, id: BlockId, param: ?ValueRef) error{OutOfMemory}!Block {
        return .{
            .id = id,
            .param = param,
            .insts = try std.ArrayList(ValueInst).initCapacity(gpa, 8),
            .term = null,
        };
    }

    pub fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
    }
};

pub const Program = struct {
    entry: BlockId,
    blocks: std.ArrayList(Block),
    next_value: ValueRef,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(gpa);
        self.blocks.deinit(gpa);
    }
};

const Lowerer = struct {
    gpa: std.mem.Allocator,
    prog: Program,
    current_block_id: BlockId,

    fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Lowerer {
        var blocks = try std.ArrayList(Block).initCapacity(gpa, 8);
        errdefer blocks.deinit(gpa);

        const entry_param: ?ValueRef = null;
        var entry_block = try Block.init(gpa, 0, entry_param);
        errdefer entry_block.deinit(gpa);
        try blocks.append(gpa, entry_block);

        return .{
            .gpa = gpa,
            .prog = .{
                .entry = 0,
                .blocks = blocks,
                .next_value = 0,
            },
            .current_block_id = 0,
        };
    }

    fn currentBlock(self: *@This()) *Block {
        return &self.prog.blocks.items[self.current_block_id];
    }

    fn allocValue(self: *@This()) ValueRef {
        const value_id = self.prog.next_value;
        self.prog.next_value += 1;
        return value_id;
    }

    fn addInst(self: *@This(), op: Inst) error{OutOfMemory}!ValueRef {
        const value_id = self.allocValue();
        try self.currentBlock().insts.append(self.gpa, .{ .id = value_id, .op = op });
        return value_id;
    }

    fn newBlock(self: *@This(), needs_param: bool) error{OutOfMemory}!BlockId {
        const block_id: BlockId = @intCast(self.prog.blocks.items.len);
        const block_param = if (needs_param) self.allocValue() else null;
        var block = try Block.init(self.gpa, block_id, block_param);
        errdefer block.deinit(self.gpa);
        try self.prog.blocks.append(self.gpa, block);
        return block_id;
    }

    fn setCurrentBlock(self: *@This(), block_id: BlockId) void {
        self.current_block_id = block_id;
    }

    fn setTerminator(self: *@This(), term: Terminator) void {
        self.currentBlock().term = term;
    }

    fn lowerPairOperands(self: *@This(), kids: *const [2]AstNode) error{OutOfMemory}!InstPair {
        const left = try self.lowerAst(&kids[0]);
        const right = try self.lowerAst(&kids[1]);
        return .{ .l = left, .r = right };
    }

    fn addPairInst(self: *@This(), comptime tag: std.meta.Tag(Inst), kids: *const [2]AstNode) error{OutOfMemory}!ValueRef {
        const operands = try self.lowerPairOperands(kids);
        return self.addInst(@unionInit(Inst, @tagName(tag), operands));
    }

    fn lowerElseValue(self: *@This(), else_node: ?*const AstNode) error{OutOfMemory}!ValueRef {
        if (else_node) |node| return self.lowerAst(node);
        return self.addInst(.{ .iconst = 0 });
    }

    fn lowerIf(self: *@This(), if_node: *const x86.IfNode) error{OutOfMemory}!ValueRef {
        const condition_value = try self.lowerAst(if_node.cond);

        const then_block_id = try self.newBlock(false);
        const else_block_id = try self.newBlock(false);
        const merge_block_id = try self.newBlock(true);

        self.setTerminator(.{
            .cbr = .{
                .cond = condition_value,
                .then_branch = .{ .target = then_block_id },
                .else_branch = .{ .target = else_block_id },
            },
        });

        self.setCurrentBlock(then_block_id);
        const then_value = try self.lowerAst(if_node.then_);
        self.setTerminator(.{ .br = .{ .target = merge_block_id, .arg = then_value } });

        self.setCurrentBlock(else_block_id);
        const else_value = try self.lowerElseValue(if_node.else_);
        self.setTerminator(.{ .br = .{ .target = merge_block_id, .arg = else_value } });

        self.setCurrentBlock(merge_block_id);
        return self.currentBlock().param orelse unreachable;
    }

    fn lowerAst(self: *@This(), node: *const AstNode) error{OutOfMemory}!ValueRef {
        return switch (node.*) {
            .int => |value| try self.addInst(.{ .iconst = value }),
            .print => |child| try self.addInst(.{ .print = try self.lowerAst(child) }),
            .add => |kids| try self.addPairInst(.iadd, kids),
            .sub => |kids| try self.addPairInst(.isub, kids),
            .mul => |kids| try self.addPairInst(.imul, kids),
            .div => |kids| try self.addPairInst(.idiv, kids),
            .arg => |idx| try self.addInst(.{ .iarg = idx }),
            .lt => |kids| try self.addPairInst(.ilt, kids),
            .gt => |kids| try self.addPairInst(.igt, kids),
            .le => |kids| try self.addPairInst(.ile, kids),
            .ge => |kids| try self.addPairInst(.ige, kids),
            .eq => |kids| try self.addPairInst(.ieq, kids),
            .ne => |kids| try self.addPairInst(.ine, kids),
            .if_ => |if_node| try self.lowerIf(if_node),
        };
    }
};

pub fn lower(node: *const AstNode, gpa: std.mem.Allocator) error{OutOfMemory}!Program {
    var lowerer = try Lowerer.init(gpa);
    errdefer lowerer.prog.deinit(gpa);

    const result = try lowerer.lowerAst(node);
    lowerer.setTerminator(.{ .ret = result });

    return lowerer.prog;
}
