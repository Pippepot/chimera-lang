const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const compaction = @import("compaction.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const Function = function_ir.Function;

pub fn canonicalize(function: *Function) !void {
    var rules: Rules = .{ .function = function, .address_taken = try addressTaken(function) };
    var changed = true;
    while (changed) {
        function.resolveReferences();
        changed = false;
        for (function.instructions.items, function.results.items, function.removed.items) |*instruction, result, removed| {
            if (!removed and rules.simplify(instruction, result)) changed = true;
        }
        for (function.blocks.items) |*block| {
            if (rules.simplifyTerminator(&block.terminator)) changed = true;
        }
    }
}

const Rules = struct {
    function: *Function,
    address_taken: []const bool,

    fn simplify(self: *Rules, instruction: *Instruction, result: ValueId) bool {
        if (self.function.find(result) != result) return false;
        switch (instruction.*) {
            .addi, .subi, .muli, .divsi => return self.simplifyBinary(instruction, result),
            .negi => |operand| return self.simplifyNegation(instruction, result, operand),
            .byte_to_int => |operand| {
                const folded = self.constant(operand) orelse return false;
                instruction.* = .{ .const_int = folded };
                return true;
            },
            .value_copy => |copy| return self.simplifyCopy(copy, result),
            else => return false,
        }
    }

    fn simplifyBinary(self: *Rules, instruction: *Instruction, result: ValueId) bool {
        const operands = binaryOperands(instruction);
        const original = operands.*;
        const lhs = self.constant(original.lhs);
        const rhs = self.constant(original.rhs);
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

    fn simplifyNegation(self: *Rules, instruction: *Instruction, result: ValueId, operand: ValueId) bool {
        if (self.constant(operand)) |value| {
            instruction.* = .{ .const_int = -%value };
            return true;
        }
        const negated = self.function.definition(operand) orelse return false;
        if (negated != .negi) return false;
        return self.alias(result, negated.negi);
    }

    fn simplifyCopy(self: *Rules, copy: structures.ValueCopy, result: ValueId) bool {
        if (copy.destination != null or !compaction.isScalar(copy.type_id)) return false;
        if (self.function.valueType(copy.source) != copy.type_id or !self.function.plainValue(copy.source)) return false;
        return self.alias(result, copy.source);
    }

    fn simplifyTerminator(self: *Rules, terminator: *Terminator) bool {
        if (terminator.* != .predicate_branch) return false;
        const predicate = terminator.predicate_branch;
        const order = self.operandOrder(predicate.operands) orelse return false;
        terminator.* = .{ .branch = if (predicate.operation.holds(order)) predicate.then_branch else predicate.else_branch };
        return true;
    }

    fn operandOrder(self: *const Rules, operands: structures.BinaryOperands) ?std.math.Order {
        if (operands.lhs == operands.rhs) return .eq;
        return std.math.order(self.constant(operands.lhs) orelse return null, self.constant(operands.rhs) orelse return null);
    }

    fn alias(self: *Rules, result: ValueId, target: ValueId) bool {
        if (self.address_taken[@backingInt(result)] or self.address_taken[@backingInt(target)]) return false;
        self.function.replace(result, target);
        return true;
    }

    fn constant(self: *const Rules, value: ValueId) ?i32 {
        return switch (self.function.definition(value) orelse return null) {
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

pub fn addressTaken(function: *Function) ![]const bool {
    const scratch = function.scratch;
    const tables = function_ir.tableView(function);
    const uses = try scratch.alloc(u32, function.valueCount());
    @memset(uses, 0);
    const reads = try scratch.alloc(u32, function.valueCount());
    @memset(reads, 0);
    for (function.instructions.items, function.removed.items) |*instruction, removed| {
        if (removed) continue;
        function_ir.visitInstructionReferences(tables, instruction, uses, countUse);
        switch (instruction.*) {
            .addi, .subi, .muli, .divsi => |operands| {
                countUse(reads, operands.lhs);
                countUse(reads, operands.rhs);
            },
            .negi, .byte_to_int => |operand| countUse(reads, operand),
            .value_copy => |operation| countUse(reads, operation.source),
            .call => |call| countCallReads(function, call, reads),
            else => {},
        }
    }
    for (function.blocks.items) |*block| {
        function_ir.visitTerminatorReferences(tables, &block.terminator, uses, countUse);
        switch (block.terminator) {
            .branch => |branch| countBranchReads(function, branch, reads),
            .predicate_branch => |predicate| {
                countUse(reads, predicate.operands.lhs);
                countUse(reads, predicate.operands.rhs);
                countBranchReads(function, predicate.then_branch, reads);
                countBranchReads(function, predicate.else_branch, reads);
            },
            .fallible_call => |fallible| countCallReads(function, fallible.call, reads),
            .return_value => |use| countUse(reads, use.value),
            .return_unit, .return_failure, .diverge => {},
        }
    }
    const taken = try scratch.alloc(bool, function.valueCount());
    for (taken, uses, reads) |*value_taken, use_count, read_count| value_taken.* = use_count != read_count;
    return taken;
}

fn countUse(counts: []u32, value: ValueId) void {
    counts[@backingInt(value)] += 1;
}

fn countCallReads(function: *const Function, call: structures.FunctionCall, reads: []u32) void {
    for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
        if (argument == .prepared) countUse(reads, argument.prepared.value);
    }
}

fn countBranchReads(function: *const Function, branch: structures.FunctionBranch, reads: []u32) void {
    const parameters = function.blocks.items[@backingInt(branch.target)].parameters.items;
    for (function.branch_arguments.items[branch.arguments.start..branch.arguments.end], parameters) |argument, parameter| {
        if (function.definitions.items[@backingInt(parameter)].argument.data.representation == .value) countUse(reads, argument.value);
    }
}
