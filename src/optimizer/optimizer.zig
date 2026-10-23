const std = @import("std");
const structures = @import("../structures.zig");
const value_operations = @import("../value.zig");
const compaction = @import("compaction.zig");
const verifier = @import("verifier.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;

pub fn optimize(gpa: std.mem.Allocator, body: *const Body) !Body {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const optimized = try optimizeInto(arena.allocator(), body);
    if (std.debug.runtime_safety) verifier.verify(&optimized);
    return value_operations.Owned(Body).clone(gpa, optimized);
}

fn optimizeInto(scratch: std.mem.Allocator, body: *const Body) !Body {
    const regions = try scratch.alloc(Body, body.initializer_regions.len);
    for (body.initializer_regions, regions) |*region, *optimized| optimized.* = try optimizeInto(scratch, region);
    var work = try Work.init(scratch, body);
    work.canonicalize();
    return compaction.compact(scratch, body, work.view(), regions);
}

const Work = struct {
    body: *const Body,
    instructions: []Instruction,
    blocks: []structures.FunctionBlock,
    call_arguments: []structures.FunctionCallArgument,
    branch_arguments: []structures.FunctionValueUse,
    initializer_captures: []ValueId,
    replacement: []ValueId,
    address_taken: []const bool,

    fn init(scratch: std.mem.Allocator, body: *const Body) !Work {
        const replacement = try scratch.alloc(ValueId, body.valueCount());
        for (replacement, 0..) |*value, index| value.* = @fromBackingInt(@intCast(index));
        return .{
            .body = body,
            .instructions = try scratch.dupe(Instruction, body.instructions),
            .blocks = try scratch.dupe(structures.FunctionBlock, body.blocks),
            .call_arguments = try scratch.dupe(structures.FunctionCallArgument, body.call_arguments),
            .branch_arguments = try scratch.dupe(structures.FunctionValueUse, body.branch_arguments),
            .initializer_captures = try scratch.dupe(ValueId, body.initializer_captures),
            .replacement = replacement,
            .address_taken = try addressTaken(scratch, body),
        };
    }

    fn view(self: *const Work) structures.FunctionBodyFinalization {
        return .{
            .instructions = self.instructions,
            .blocks = self.blocks,
            .call_arguments = self.call_arguments,
            .branch_arguments = self.branch_arguments,
            .initializer_captures = self.initializer_captures,
        };
    }

    fn canonicalize(self: *Work) void {
        var changed = true;
        while (changed) {
            self.view().visitValueReferences(self.replacement, resolve);
            changed = false;
            for (self.instructions, 0..) |*instruction, index| {
                if (self.simplify(instruction, self.body.instructionValue(index))) changed = true;
            }
            for (self.blocks) |*block| {
                if (self.simplifyTerminator(&block.terminator)) changed = true;
            }
        }
    }

    fn simplify(self: *Work, instruction: *Instruction, result: ValueId) bool {
        if (self.replacement[@backingInt(result)] != result) return false;
        switch (instruction.*) {
            .addi, .subi, .muli, .divsi => return self.simplifyBinary(instruction, result),
            .negi => |operand| return self.simplifyNegation(instruction, result, operand),
            .byte_to_int => |operand| {
                const folded = self.constant(operand) orelse return false;
                instruction.* = .{ .const_int = folded };
                return true;
            },
            else => return false,
        }
    }

    fn simplifyBinary(self: *Work, instruction: *Instruction, result: ValueId) bool {
        const operands = binaryOperands(instruction);
        const original = operands.*;
        const lhs = self.constant(operands.lhs);
        const rhs = self.constant(operands.rhs);
        if (lhs != null and rhs != null) {
            const folded = instruction.integerResult(lhs.?, rhs.?) orelse return false;
            instruction.* = .{ .const_int = folded };
            return true;
        }
        const laws = algebra(instruction.*);
        if (laws.commutative and lhs != null) {
            operands.* = .{ .lhs = original.rhs, .rhs = original.lhs };
            return true;
        }
        if (rhs) |constant_rhs| {
            if (laws.identity == constant_rhs) return self.alias(result, original.lhs);
            if (laws.absorbing == constant_rhs) {
                instruction.* = .{ .const_int = constant_rhs };
                return true;
            }
            if (laws.negating == constant_rhs) {
                instruction.* = .{ .negi = original.lhs };
                return true;
            }
        }
        if (laws.self_result) |self_result| if (original.lhs == original.rhs) {
            instruction.* = .{ .const_int = self_result };
            return true;
        };
        return false;
    }

    fn simplifyNegation(self: *Work, instruction: *Instruction, result: ValueId, operand: ValueId) bool {
        if (self.constant(operand)) |value| {
            instruction.* = .{ .const_int = -%value };
            return true;
        }
        const negated = self.definition(operand) orelse return false;
        if (negated != .negi) return false;
        return self.alias(result, negated.negi);
    }

    fn simplifyTerminator(self: *Work, terminator: *Terminator) bool {
        if (terminator.* != .predicate_branch) return false;
        const predicate = terminator.predicate_branch;
        const order = self.operandOrder(predicate.operands) orelse return false;
        terminator.* = .{ .branch = if (predicate.operation.holds(order)) predicate.then_branch else predicate.else_branch };
        return true;
    }

    fn operandOrder(self: *const Work, operands: structures.BinaryOperands) ?std.math.Order {
        if (operands.lhs == operands.rhs) return .eq;
        return std.math.order(self.constant(operands.lhs) orelse return null, self.constant(operands.rhs) orelse return null);
    }

    fn alias(self: *Work, result: ValueId, target: ValueId) bool {
        if (self.address_taken[@backingInt(result)] or self.address_taken[@backingInt(target)]) return false;
        self.replacement[@backingInt(result)] = target;
        return true;
    }

    fn definition(self: *const Work, value: ValueId) ?Instruction {
        const index = @backingInt(value);
        if (index < self.body.block_arguments.len) return null;
        return self.instructions[index - self.body.block_arguments.len];
    }

    fn constant(self: *const Work, value: ValueId) ?i32 {
        return switch (self.definition(value) orelse return null) {
            .const_int => |integer| integer,
            .const_bool => |boolean| @intFromBool(boolean),
            .const_byte => |byte| byte,
            else => null,
        };
    }
};

const Algebra = struct {
    commutative: bool = false,
    identity: ?i32 = null,
    absorbing: ?i32 = null,
    negating: ?i32 = null,
    self_result: ?i32 = null,
};

fn algebra(instruction: Instruction) Algebra {
    return switch (instruction) {
        .addi => .{ .commutative = true, .identity = 0 },
        .subi => .{ .identity = 0, .self_result = 0 },
        .muli => .{ .commutative = true, .identity = 1, .absorbing = 0, .negating = -1 },
        .divsi => .{ .identity = 1, .negating = -1 },
        else => unreachable,
    };
}

fn binaryOperands(instruction: *Instruction) *structures.BinaryOperands {
    return switch (instruction.*) {
        inline .addi, .subi, .muli, .divsi => |*operands| operands,
        else => unreachable,
    };
}

fn resolve(replacement: []const ValueId, value: *ValueId) void {
    while (replacement[@backingInt(value.*)] != value.*) value.* = replacement[@backingInt(value.*)];
}

fn addressTaken(scratch: std.mem.Allocator, body: *const Body) ![]const bool {
    const uses = try scratch.alloc(u32, body.valueCount());
    @memset(uses, 0);
    for (body.instructions) |*instruction| compaction.visitInstructionReferences(body, instruction, uses, countUse);
    for (body.blocks) |*block| compaction.visitTerminatorReferences(body, &block.terminator, uses, countUse);
    const reads = try scratch.alloc(u32, body.valueCount());
    @memset(reads, 0);
    for (body.instructions) |instruction| switch (instruction) {
        .addi, .subi, .muli, .divsi => |operands| {
            countRead(reads, operands.lhs);
            countRead(reads, operands.rhs);
        },
        .negi, .byte_to_int => |operand| countRead(reads, operand),
        .value_copy => |operation| countRead(reads, operation.source),
        .call => |call| countCallReads(body, call, reads),
        else => {},
    };
    for (body.blocks) |block| switch (block.terminator) {
        .branch => |branch| countBranchReads(body, branch, reads),
        .predicate_branch => |predicate| {
            countRead(reads, predicate.operands.lhs);
            countRead(reads, predicate.operands.rhs);
            countBranchReads(body, predicate.then_branch, reads);
            countBranchReads(body, predicate.else_branch, reads);
        },
        .fallible_call => |fallible| countCallReads(body, fallible.call, reads),
        .return_value => |use| countRead(reads, use.value),
        .return_unit, .return_failure, .diverge => {},
    };
    const taken = try scratch.alloc(bool, body.valueCount());
    for (taken, uses, reads) |*value_taken, use_count, read_count| value_taken.* = use_count != read_count;
    return taken;
}

fn countUse(uses: []u32, value: ValueId) void {
    uses[@backingInt(value)] += 1;
}

fn countRead(reads: []u32, value: ValueId) void {
    reads[@backingInt(value)] += 1;
}

fn countCallReads(body: *const Body, call: structures.FunctionCall, reads: []u32) void {
    for (body.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
        if (argument == .prepared) countRead(reads, argument.prepared.value);
    }
}

fn countBranchReads(body: *const Body, branch: structures.FunctionBranch, reads: []u32) void {
    const target = body.blocks[@backingInt(branch.target)];
    const parameters = body.block_arguments[target.argument_start..target.argument_end];
    for (body.branch_arguments[branch.arguments.start..branch.arguments.end], parameters) |argument, parameter| {
        if (parameter.representation == .value) countRead(reads, argument.value);
    }
}
