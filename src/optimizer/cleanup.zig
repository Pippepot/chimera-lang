const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const Function = function_ir.Function;
const Incoming = @import("graph.zig").Incoming;

pub fn simplify(function: *Function) !bool {
    for (function.blocks.items) |*block| {
        var kept: usize = 0;
        for (block.instructions.items) |index| if (!function.removed.items[index]) {
            block.instructions.items[kept] = index;
            kept += 1;
        };
        block.instructions.shrinkRetainingCapacity(kept);
    }
    var changed = false;
    while (try sweep(function)) {
        function.invalidateControlFlow();
        changed = true;
    }
    if (changed) function.resolveReferences();
    return changed;
}

const Sweep = struct {
    function: *Function,
    reachable: []const bool,
    incoming: []const std.ArrayList(Incoming),
    address_taken: []const bool,
    dirty: []bool,

    fn touch(self: *Sweep, block: u32) void {
        self.dirty[block] = true;
        for (self.function.successors(block)) |successor| if (successor) |target| {
            self.dirty[target] = true;
        };
    }

    fn foldSameTarget(self: *Sweep, block: u32) bool {
        const terminator = &self.function.blocks.items[block].terminator;
        if (terminator.* != .predicate_branch) return false;
        const predicate = terminator.predicate_branch;
        if (predicate.then_branch.target != predicate.else_branch.target) return false;
        const then_arguments = self.function.branchArguments(predicate.then_branch);
        const else_arguments = self.function.branchArguments(predicate.else_branch);
        for (then_arguments, else_arguments) |then_argument, else_argument| {
            if (!std.meta.eql(then_argument, else_argument)) return false;
        }
        terminator.* = .{ .branch = predicate.then_branch };
        self.touch(block);
        return true;
    }

    fn arm(self: *Sweep, block: u32, branch: structures.FunctionBranch) ?structures.FunctionBranch {
        const target = @backingInt(branch.target);
        const candidate = &self.function.blocks.items[target];
        if (target == block or self.dirty[target] or candidate.terminator != .branch) return branch;
        if (candidate.parameters.items.len != 0 or candidate.instructions.items.len > 2 or self.incoming[target].items.len != 1) return branch;
        for (candidate.instructions.items) |index| if (!speculatable(self.function.instructions.items[index])) return branch;
        return candidate.terminator.branch;
    }

    fn hoistArm(self: *Sweep, block: u32, branch: structures.FunctionBranch) !void {
        const target = @backingInt(branch.target);
        const candidate = &self.function.blocks.items[target];
        if (candidate.terminator != .branch or self.arm(block, branch).?.target == branch.target) return;
        try self.function.blocks.items[block].instructions.appendSlice(self.function.scratch, candidate.instructions.items);
        candidate.instructions.clearRetainingCapacity();
    }

    fn formSelect(self: *Sweep, block: u32) !bool {
        const function = self.function;
        const terminator = function.blocks.items[block].terminator;
        if (terminator != .predicate_branch) return false;
        const predicate = terminator.predicate_branch;
        if (predicate.operation == .eqt or predicate.operation == .net) return false;
        const then_exit = self.arm(block, predicate.then_branch) orelse return false;
        const else_exit = self.arm(block, predicate.else_branch) orelse return false;
        if (then_exit.target != else_exit.target or @backingInt(then_exit.target) == block) return false;
        const then_arguments = function.branchArguments(then_exit);
        const else_arguments = function.branchArguments(else_exit);
        if (coerces(then_arguments) or coerces(else_arguments)) return false;
        for (then_arguments, else_arguments) |then_argument, else_argument| {
            if (function.find(then_argument.value) == function.find(else_argument.value)) continue;
            const type_id = function.valueType(then_argument.value);
            if (type_id != .int and type_id != .bool) return false;
        }
        try self.hoistArm(block, predicate.then_branch);
        try self.hoistArm(block, predicate.else_branch);
        const span = function.blocks.items[block].span;
        const frame = function.blocks.items[block].frame;
        const condition = try self.emit(block, .{ .compare = .{ .operation = predicate.operation, .operands = predicate.operands } }, span, frame);
        var merged: std.ArrayList(structures.FunctionValueUse) = .empty;
        for (function.branchArguments(then_exit), function.branchArguments(else_exit)) |then_argument, else_argument| {
            const then_value = function.find(then_argument.value);
            const else_value = function.find(else_argument.value);
            try merged.append(function.scratch, .{ .value = if (then_value == else_value) then_value else if (boolean(function, then_value) == true and boolean(function, else_value) == false)
                condition
            else
                try self.emit(block, .{ .select = .{ .condition = condition, .then_value = then_value, .else_value = else_value, .type_id = function.valueType(then_value) } }, span, frame) });
        }
        function.blocks.items[block].terminator = .{ .branch = .{ .target = then_exit.target, .arguments = try function.appendBranchArguments(merged.items) } };
        self.touch(block);
        self.dirty[block] = true;
        return true;
    }

    fn emit(self: *Sweep, block: u32, instruction: structures.FunctionInstruction, span: structures.SourceSpan, frame: structures.InlineFrameId) !ValueId {
        const function = self.function;
        const index = try function.newInstruction(instruction, span, frame);
        try function.blocks.items[block].instructions.append(function.scratch, index);
        return function.results.items[index];
    }

    fn merge(self: *Sweep, block: u32) !bool {
        const function = self.function;
        if (block == function.entry or self.incoming[block].items.len != 1) return false;
        const edge = self.incoming[block].items[0];
        const predecessor = edge.block;
        if (predecessor == block or self.dirty[predecessor]) return false;
        if (function.blocks.items[predecessor].terminator != .branch) return false;
        const arguments = function.branchArguments(edge.branch(function).*);
        if (coerces(arguments)) return false;
        for (function.blocks.items[block].parameters.items, arguments) |parameter, argument| {
            const data = function.definitions.items[@backingInt(parameter)].argument.data;
            const value = function.find(argument.value);
            const aliases = data.representation != .value or !function.direct(data.type_id);
            const immutable = function.plainValue(value) and !self.address_taken[@backingInt(value)] and !self.address_taken[@backingInt(parameter)];
            if (aliases or immutable) {
                function.replace(parameter, value);
                continue;
            }
            const source = function.blocks.items[predecessor];
            const index = try function.newInstruction(.{ .value_copy = .{ .source = value, .type_id = data.type_id } }, source.span, source.frame);
            try function.blocks.items[predecessor].instructions.append(function.scratch, index);
            function.replace(parameter, function.results.items[index]);
        }
        try function.blocks.items[predecessor].instructions.ensureUnusedCapacity(function.scratch, function.blocks.items[block].instructions.items.len);
        const merged = &function.blocks.items[block];
        const target = &function.blocks.items[predecessor];
        target.instructions.appendSliceAssumeCapacity(merged.instructions.items);
        merged.instructions.clearRetainingCapacity();
        target.terminator = merged.terminator;
        target.span = merged.span;
        target.frame = merged.frame;
        merged.terminator = .diverge;
        self.touch(predecessor);
        self.dirty[block] = true;
        return true;
    }

    fn forward(self: *Sweep, block: u32) !bool {
        const function = self.function;
        const empty = &function.blocks.items[block];
        if (block == function.entry or empty.instructions.items.len != 0 or empty.parameters.items.len != 0 or empty.terminator != .branch) return false;
        const exit = empty.terminator.branch;
        const target: u32 = @backingInt(exit.target);
        if (target == block or self.dirty[target] or loopsBack(function, target, block)) return false;
        if (coerces(function.branchArguments(exit))) return false;
        var changed = false;
        for (self.incoming[block].items) |edge| {
            if (self.dirty[edge.block]) continue;
            const branch = edge.branch(function);
            branch.* = .{ .target = exit.target, .arguments = try function.copyBranchArguments(exit.arguments) };
            self.touch(edge.block);
            changed = true;
        }
        if (changed) self.dirty[block] = true;
        return changed;
    }
};

fn speculatable(instruction: structures.FunctionInstruction) bool {
    return switch (instruction) {
        .const_int, .const_bool, .const_byte, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select => true,
        else => false,
    };
}

fn boolean(function: *const Function, value: ValueId) ?bool {
    const definition = function.definition(value) orelse return null;
    return if (definition == .const_bool) definition.const_bool else null;
}

fn coerces(arguments: []const structures.FunctionValueUse) bool {
    for (arguments) |argument| if (argument.coerce_to != null) return true;
    return false;
}

fn loopsBack(function: *Function, start: u32, block: u32) bool {
    var current = start;
    for (0..function.blocks.items.len) |_| {
        if (current == block) return true;
        const candidate = &function.blocks.items[current];
        if (candidate.instructions.items.len != 0 or candidate.terminator != .branch) return false;
        current = @backingInt(candidate.terminator.branch.target);
    }
    return true;
}

fn sweep(function: *Function) !bool {
    const scratch = function.scratch;
    const graph = (try function.controlFlowEdges()).*;
    const reachable = graph.reachable;
    var state: Sweep = .{ .function = function, .reachable = reachable, .incoming = graph.incoming, .address_taken = try canonicalize.addressTaken(function), .dirty = try scratch.alloc(bool, function.blocks.items.len) };
    @memset(state.dirty, false);
    var changed = false;
    for (function.order.items) |block| {
        if (!reachable[block] or state.dirty[block]) continue;
        if (state.foldSameTarget(block) or try state.formSelect(block) or try state.merge(block) or try state.forward(block)) changed = true;
    }
    return changed;
}
