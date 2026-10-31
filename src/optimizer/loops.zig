const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const graph_ir = @import("graph.zig");
const value_rules = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const Function = function_ir.Function;
const Graph = graph_ir.Graph;

pub const Loop = struct {
    header: u32,
    members: []bool,
    blocks: []const u32,
    latches: []const u32,
    depth: u32 = 1,

    pub fn contains(self: Loop, block: u32) bool {
        return block < self.members.len and self.members[block];
    }
};

pub const Analysis = struct {
    function: *const Function,
    graph: Graph,
    loops: []const Loop,
    instruction_blocks: []const u32,
    instruction_positions: []const u32,
    address_taken: []const bool,
    call_arguments: []const CallArgumentRange = &.{},

    pub const CallArgumentRange = struct {
        instruction: u32,
        value: ValueId,
        range: IntegerRange,
    };

    pub fn init(function: *Function, graph: Graph, found: []const Loop) !Analysis {
        const instruction_blocks = try function.scratch.alloc(u32, function.instructions.items.len);
        const instruction_positions = try function.scratch.alloc(u32, function.instructions.items.len);
        @memset(instruction_blocks, std.math.maxInt(u32));
        @memset(instruction_positions, std.math.maxInt(u32));
        for (function.blocks.items, 0..) |block, index| for (block.instructions.items, 0..) |instruction, position| {
            instruction_blocks[instruction] = @intCast(index);
            instruction_positions[instruction] = @intCast(position);
        };
        return .{
            .function = function,
            .graph = graph,
            .loops = found,
            .instruction_blocks = instruction_blocks,
            .instruction_positions = instruction_positions,
            .address_taken = try value_rules.addressTaken(function),
        };
    }

    pub fn definedOutside(self: Analysis, loop: Loop, value: ValueId) bool {
        const block = switch (self.function.definitions.items[@backingInt(self.function.find(value))]) {
            .argument => |argument| argument.block,
            .instruction => |index| self.instruction_blocks[index],
        };
        return !loop.contains(block);
    }

    pub fn iterationAcyclic(self: Analysis, loop: Loop) bool {
        for (loop.blocks) |block| for (Function.edges(&self.function.blocks.items[block].terminator)) |maybe_edge| if (maybe_edge) |edge| {
            const target = @backingInt(edge.target);
            if (target == loop.header or !loop.contains(target)) continue;
            if (self.graph.rank[target] <= self.graph.rank[block]) return false;
        };
        return true;
    }

    pub fn inductionExit(self: Analysis, loop: Loop, preheader_block: u32, exit: ExitTest, parameter: ValueId) ?InductionExit {
        const counter = self.invariantInductionExit(loop, preheader_block, exit, parameter) orelse return null;
        if (!self.definedOutside(loop, counter.comparison.other)) return null;
        return counter;
    }

    pub fn invariantInductionExit(self: Analysis, loop: Loop, preheader_block: u32, exit: ExitTest, parameter: ValueId) ?InductionExit {
        const counter = self.induction(loop, preheader_block, parameter) orelse return null;
        if (!self.graph.dominates(exit.stay, loop.latches[0])) return null;
        const comparison = IntegerComparison.init(self.function, exit.operation, exit.operands, parameter) orelse return null;
        if (!self.invariant(loop, comparison.other, 16)) return null;
        return .{ .induction = counter, .comparison = comparison };
    }

    fn invariant(self: Analysis, loop: Loop, value: ValueId, depth: u32) bool {
        if (!self.immutable(value)) return false;
        if (self.definedOutside(loop, value)) return true;
        if (depth == 0) return false;
        const definition = self.function.definition(self.function.find(value)) orelse return false;
        switch (definition) {
            .const_int => return true,
            .numeric_binary => |operation| {
                if (operation.type_id != .int) return false;
                return self.invariant(loop, operation.operands.lhs, depth - 1) and self.invariant(loop, operation.operands.rhs, depth - 1);
            },
            .numeric_unary => |operation| {
                if (operation.type_id != .int) return false;
                return self.invariant(loop, operation.operand, depth - 1);
            },
            .addi, .subi, .muli => |operands| return self.invariant(loop, operands.lhs, depth - 1) and self.invariant(loop, operands.rhs, depth - 1),
            else => return false,
        }
    }

    pub fn iterationRange(self: Analysis, preheader_block: u32, counter: InductionExit) ?IterationRange {
        if (!self.immutable(counter.comparison.other)) return null;
        return IterationRange.init(
            counter.induction.step,
            counter.comparison.operation,
            self.rangeAt(counter.induction.start, preheader_block),
            self.rangeAt(counter.comparison.other, preheader_block),
        );
    }

    /// Equality loops with unit strides terminate without overflowing only when
    /// the initial counter is on the approaching side of the bound.
    pub fn equalityRecurrenceSafe(self: Analysis, preheader_block: u32, counter: InductionExit) bool {
        if (!self.immutable(counter.comparison.other)) return false;
        if (counter.induction.start == counter.comparison.other) return true;
        const start = self.rangeAt(counter.induction.start, preheader_block);
        const bound = self.rangeAt(counter.comparison.other, preheader_block);
        return if (counter.induction.step == 1)
            start.upper <= bound.lower
        else if (counter.induction.step == -1)
            start.lower >= bound.upper
        else
            false;
    }

    fn immutable(self: Analysis, value: ValueId) bool {
        const resolved = self.function.find(value);
        return self.function.plainValue(resolved) and !self.address_taken[@backingInt(resolved)];
    }

    pub fn integerConstant(self: Analysis, value: ValueId) ?i32 {
        if (!self.immutable(value)) return null;
        const definition = self.function.definition(self.function.find(value)) orelse return null;
        return if (definition == .const_int) definition.const_int else null;
    }

    fn induction(self: Analysis, loop: Loop, preheader_block: u32, parameter: ValueId) ?Induction {
        if (loop.latches.len != 1) return null;
        const function = self.function;
        const position = std.mem.indexOfScalar(ValueId, function.blocks.items[loop.header].parameters.items, parameter) orelse return null;
        if (function.valueType(parameter) != .int or !self.immutable(parameter)) return null;
        const start = function.branchArguments(function.blocks.items[preheader_block].terminator.branch)[position];
        const back = function.branchArguments(latchBranch(function, loop) orelse return null)[position];
        if (start.coerce_to != null or back.coerce_to != null) return null;
        const next_value = self.forwarded(back.value, 16);
        const next = function.definition(next_value) orelse return null;
        var step: i32 = undefined;
        switch (next) {
            .numeric_binary => |operation| {
                if (operation.type_id != .int or operation.overflow == .saturating) return null;
                const operands = operation.operands;
                if (operation.operation == .add) {
                    const operand = if (function.find(operands.lhs) == parameter) operands.rhs else if (function.find(operands.rhs) == parameter) operands.lhs else return null;
                    step = self.integerConstant(operand) orelse return null;
                } else if (operation.operation == .sub) {
                    if (function.find(operands.lhs) != parameter) return null;
                    const decrement = self.integerConstant(operands.rhs) orelse return null;
                    if (decrement == std.math.minInt(i32)) return null;
                    step = -decrement;
                } else return null;
            },
            .addi => |operands| {
                const operand = if (function.find(operands.lhs) == parameter) operands.rhs else if (function.find(operands.rhs) == parameter) operands.lhs else return null;
                step = self.integerConstant(operand) orelse return null;
            },
            .subi => |operands| {
                if (function.find(operands.lhs) != parameter) return null;
                step = -%(self.integerConstant(operands.rhs) orelse return null);
            },
            else => return null,
        }
        if (step == 0) return null;
        return .{ .parameter = parameter, .start = self.forwarded(start.value, 16), .next = next_value, .step = step };
    }

    fn forwarded(self: Analysis, value: ValueId, depth: u32) ValueId {
        const resolved = self.function.find(value);
        if (depth == 0 or !self.immutable(resolved)) return resolved;
        const definition = self.function.definitions.items[@backingInt(resolved)];
        if (definition != .argument) return resolved;
        const block = definition.argument.block;
        const incoming = self.graph.incoming[block].items;
        if (incoming.len == 0) return resolved;
        for (incoming) |edge| if (self.graph.dominates(block, edge.block)) return resolved;
        const position = std.mem.indexOfScalar(ValueId, self.function.blocks.items[block].parameters.items, resolved).?;
        var source: ?ValueId = null;
        for (incoming) |edge| {
            const branch = Function.edges(&self.function.blocks.items[edge.block].terminator)[edge.ordinal].?;
            const argument = self.function.branchArguments(branch.*)[position];
            if (argument.coerce_to != null or argument.variant_tag_mapping != null) return resolved;
            const forwarded_value = self.forwarded(argument.value, depth - 1);
            if (source) |previous| {
                if (previous != forwarded_value) return resolved;
            } else source = forwarded_value;
        }
        return source.?;
    }

    pub fn rangeAt(self: Analysis, value: ValueId, at: u32) IntegerRange {
        return self.rangeAtDepth(value, at, 16);
    }

    fn rangeAtDepth(self: Analysis, value: ValueId, at: u32, depth: u32) IntegerRange {
        if (!self.immutable(value)) return .{};
        if (self.integerConstant(value)) |number| return .{ .lower = number, .upper = number };
        var range = self.inductionRange(value, at, depth) orelse self.parameterRange(value, depth) orelse self.shiftedRange(value, at, depth);
        var block = at;
        while (block != self.function.entry) {
            block = self.graph.dominator[block];
            const terminator = self.function.blocks.items[block].terminator;
            if (terminator != .predicate_branch) continue;
            const predicate = terminator.predicate_branch;
            const comparison = IntegerComparison.init(self.function, predicate.operation, predicate.operands, value) orelse continue;
            const bound = self.integerConstant(comparison.other) orelse continue;
            const then_target = @backingInt(predicate.then_branch.target);
            const else_target = @backingInt(predicate.else_branch.target);
            const taken = if (self.graph.incoming[then_target].items.len == 1 and self.graph.dominates(then_target, at))
                true
            else if (self.graph.incoming[else_target].items.len == 1 and self.graph.dominates(else_target, at))
                false
            else
                continue;
            range.refine(if (taken) comparison.operation else comparison.operation.negated(), bound);
        }
        return range;
    }

    fn inductionRange(self: Analysis, value: ValueId, at: u32, depth: u32) ?IntegerRange {
        if (depth == 0) return null;
        const parameter = self.function.find(value);
        for (self.loops) |loop| {
            if (!loop.contains(at)) continue;
            if (std.mem.indexOfScalar(ValueId, self.function.blocks.items[loop.header].parameters.items, parameter) == null) continue;
            const entry = preheader(self.function, self.graph, loop) orelse continue;
            for (loop.blocks) |block| {
                const exit = exitTestAt(self.function, loop, block) orelse continue;
                if (!self.graph.dominates(exit.stay, at)) continue;
                const counter = self.invariantInductionExit(loop, entry, exit, parameter) orelse continue;
                if (!self.immutable(counter.comparison.other)) continue;
                const range = IterationRange.init(
                    counter.induction.step,
                    counter.comparison.operation,
                    self.rangeAtDepth(counter.induction.start, at, depth - 1),
                    self.rangeAtDepth(counter.comparison.other, at, depth - 1),
                ) orelse continue;
                return range.absolute;
            }
        }
        return null;
    }

    fn parameterRange(self: Analysis, value: ValueId, depth: u32) ?IntegerRange {
        return self.parameterRangeLeaves(value, depth, &.{});
    }

    fn parameterRangeLeaves(self: Analysis, value: ValueId, depth: u32, visited: []const ValueId) ?IntegerRange {
        const resolved = self.function.find(value);
        if (std.mem.indexOfScalar(ValueId, visited, resolved) != null) return null;
        if (depth == 0) return .{};
        const definition = self.function.definitions.items[@backingInt(resolved)];
        if (definition != .argument) return null;
        const block = definition.argument.block;
        const incoming = self.graph.incoming[block].items;
        if (incoming.len == 0) return null;
        if (visited.len == 16) return .{};
        var path: [16]ValueId = undefined;
        @memcpy(path[0..visited.len], visited);
        path[visited.len] = resolved;
        const position = std.mem.indexOfScalar(ValueId, self.function.blocks.items[block].parameters.items, resolved).?;
        var range: ?IntegerRange = null;
        for (incoming) |edge| {
            const branch = Function.edges(&self.function.blocks.items[edge.block].terminator)[edge.ordinal].?;
            const argument = self.function.branchArguments(branch.*)[position];
            if (argument.coerce_to != null or argument.variant_tag_mapping != null) return .{};
            const source = self.function.find(argument.value);
            if (!self.immutable(source)) return .{};
            const source_definition = self.function.definitions.items[@backingInt(source)];
            const found = if (source_definition == .argument and source_definition.argument.block != self.function.entry)
                self.parameterRangeLeaves(source, depth - 1, path[0 .. visited.len + 1]) orelse continue
            else
                self.rangeAtDepth(source, edge.block, depth - 1);
            if (range) |previous| {
                range = .{ .lower = @min(previous.lower, found.lower), .upper = @max(previous.upper, found.upper) };
            } else {
                range = found;
            }
        }
        return range;
    }

    fn shiftedRange(self: Analysis, value: ValueId, at: u32, depth: u32) IntegerRange {
        if (depth == 0) return .{};
        const definition = self.function.definition(self.function.find(value)) orelse return .{};
        var operands: structures.BinaryOperands = undefined;
        var subtract: bool = undefined;
        var checked = false;
        switch (definition) {
            .numeric_binary => |operation| {
                if (operation.type_id != .int or operation.overflow == .saturating) return .{};
                subtract = switch (operation.operation) {
                    .add => false,
                    .sub => true,
                    else => return .{},
                };
                operands = operation.operands;
                checked = operation.overflow == .checked;
            },
            .addi => |operation| {
                operands = operation;
                subtract = false;
            },
            .subi => |operation| {
                operands = operation;
                subtract = true;
            },
            else => return .{},
        }
        const offset = self.integerConstant(operands.rhs) orelse return .{};
        const shift: i64 = if (subtract) -@as(i64, offset) else offset;
        var base = self.rangeAtDepth(operands.lhs, at, depth - 1);
        const producer = self.function.instructionIndex(self.function.find(value)).?;
        for (self.call_arguments) |argument| {
            if (self.function.find(argument.value) != self.function.find(operands.lhs)) continue;
            const call_block = self.instruction_blocks[argument.instruction];
            const producer_block = self.instruction_blocks[producer];
            if (!self.graph.dominates(call_block, producer_block)) continue;
            if (call_block == producer_block and self.instruction_positions[argument.instruction] >= self.instruction_positions[producer]) continue;
            base.lower = @max(base.lower, argument.range.lower);
            base.upper = @min(base.upper, argument.range.upper);
        }
        const lower = base.lower + shift;
        const upper = base.upper + shift;
        if (!checked and (lower < std.math.minInt(i32) or upper > std.math.maxInt(i32))) return .{};
        return .{ .lower = @max(lower, std.math.minInt(i32)), .upper = @min(upper, std.math.maxInt(i32)) };
    }
};

pub const Induction = struct {
    parameter: ValueId,
    start: ValueId,
    next: ValueId,
    step: i32,
};

pub const InductionExit = struct {
    induction: Induction,
    comparison: IntegerComparison,
};

pub const ExitTest = struct {
    operation: structures.PredicateOperation,
    operands: structures.BinaryOperands,
    exit: u32,
    stay: u32,
};

pub fn exitTest(function: *const Function, loop: Loop) ?ExitTest {
    const result = exitTestWithArguments(function, loop) orelse return null;
    for (Function.edges(&function.blocks.items[loop.header].terminator)) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == result.exit and edge.arguments.start != edge.arguments.end) return null;
    };
    return result;
}

pub fn exitTestWithArguments(function: *const Function, loop: Loop) ?ExitTest {
    return exitTestAt(function, loop, loop.header);
}

pub fn exitTestAt(function: *const Function, loop: Loop, block: u32) ?ExitTest {
    const terminator = function.blocks.items[block].terminator;
    if (terminator != .predicate_branch) return null;
    const predicate = terminator.predicate_branch;
    const then_target = @backingInt(predicate.then_branch.target);
    const else_target = @backingInt(predicate.else_branch.target);
    if (loop.contains(then_target) == loop.contains(else_target)) return null;
    const exit = if (loop.contains(then_target)) predicate.else_branch else predicate.then_branch;
    const stay = if (loop.contains(then_target)) predicate.then_branch else predicate.else_branch;
    const operation = if (loop.contains(then_target)) predicate.operation.negated() else predicate.operation;
    return .{ .operation = operation, .operands = predicate.operands, .exit = @backingInt(exit.target), .stay = @backingInt(stay.target) };
}

fn latchBranch(function: *const Function, loop: Loop) ?structures.FunctionBranch {
    for (Function.edges(&function.blocks.items[loop.latches[0]].terminator)) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == loop.header) return edge.*;
    };
    return null;
}

pub const IntegerComparison = struct {
    operation: structures.PredicateOperation,
    other: ValueId,

    pub fn init(function: *const Function, operation: structures.PredicateOperation, operands: structures.BinaryOperands, value: ValueId) ?IntegerComparison {
        const left = function.find(operands.lhs);
        const right = function.find(operands.rhs);
        const queried = function.find(value);
        const normalized: structures.PredicateOperation = if (left == queried) operation else if (right == queried) switch (operation) {
            .lti => .gti,
            .gti => .lti,
            .lei => .gei,
            .gei => .lei,
            .eqi, .nei => operation,
            else => return null,
        } else return null;
        return switch (normalized) {
            .lti, .gti, .lei, .gei, .eqi, .nei => .{ .operation = normalized, .other = if (left == queried) right else left },
            else => null,
        };
    }
};

pub const IntegerRange = struct {
    lower: i64 = std.math.minInt(i32),
    upper: i64 = std.math.maxInt(i32),

    fn refine(self: *IntegerRange, operation: structures.PredicateOperation, bound: i64) void {
        switch (operation) {
            .lti => self.upper = @min(self.upper, bound - 1),
            .lei => self.upper = @min(self.upper, bound),
            .gti => self.lower = @max(self.lower, bound + 1),
            .gei => self.lower = @max(self.lower, bound),
            .eqi => {
                self.lower = @max(self.lower, bound);
                self.upper = @min(self.upper, bound);
            },
            .nei => {
                if (self.lower == bound) self.lower += 1;
                if (self.upper == bound) self.upper -= 1;
            },
            else => unreachable,
        }
    }

    pub fn known(self: IntegerRange, operation: structures.PredicateOperation, bound: i64) ?bool {
        return switch (operation) {
            .lti => if (self.upper < bound) true else if (self.lower >= bound) false else null,
            .lei => if (self.upper <= bound) true else if (self.lower > bound) false else null,
            .gti => if (self.lower > bound) true else if (self.upper <= bound) false else null,
            .gei => if (self.lower >= bound) true else if (self.upper < bound) false else null,
            .eqi => if (self.lower == bound and self.upper == bound) true else if (bound < self.lower or bound > self.upper) false else null,
            .nei => if (self.lower == bound and self.upper == bound) false else if (bound < self.lower or bound > self.upper) true else null,
            else => unreachable,
        };
    }
};

const IterationRange = struct {
    absolute: IntegerRange,
    relative: IntegerRange,

    fn init(step: i32, operation: structures.PredicateOperation, start: IntegerRange, bound: IntegerRange) ?IterationRange {
        var range = start;
        if (step > 0) {
            if (operation != .gei and operation != .gti) return null;
            range.upper = bound.upper - @as(i64, @intFromBool(operation == .gei));
            if (range.upper + step > std.math.maxInt(i32)) return null;
        } else if (step < 0) {
            if (operation != .lei and operation != .lti) return null;
            range.lower = bound.lower + @as(i64, @intFromBool(operation == .lei));
            if (range.lower + step < std.math.minInt(i32)) return null;
        } else return null;
        var relative: IntegerRange = .{ .lower = range.lower - bound.upper, .upper = range.upper - bound.lower };
        relative.refine(operation.negated(), 0);
        return .{ .absolute = range, .relative = relative };
    }
};

pub fn find(scratch: std.mem.Allocator, function: *Function, graph: Graph) ![]Loop {
    const count = function.blocks.items.len;
    var loops: std.ArrayList(Loop) = .empty;
    for (graph.order) |header| {
        var latches: std.ArrayList(u32) = .empty;
        for (graph.incoming[header].items) |edge| {
            if (graph.dominates(header, edge.block)) try latches.append(scratch, edge.block);
        }
        if (latches.items.len == 0) continue;
        const members = try scratch.alloc(bool, count);
        @memset(members, false);
        members[header] = true;
        var blocks: std.ArrayList(u32) = .empty;
        try blocks.append(scratch, header);
        var pending: std.ArrayList(u32) = .empty;
        for (latches.items) |latch| if (!members[latch]) {
            members[latch] = true;
            try blocks.append(scratch, latch);
            try pending.append(scratch, latch);
        };
        while (pending.pop()) |block| for (graph.incoming[block].items) |edge| {
            if (members[edge.block]) continue;
            members[edge.block] = true;
            try blocks.append(scratch, edge.block);
            try pending.append(scratch, edge.block);
        };
        std.mem.sort(u32, blocks.items, graph.rank, byRank);
        try loops.append(scratch, .{ .header = header, .members = members, .blocks = blocks.items, .latches = latches.items });
    }
    for (loops.items) |*loop| {
        for (loops.items) |other| {
            if (other.header != loop.header and other.contains(loop.header)) loop.depth += 1;
        }
    }
    std.mem.sort(Loop, loops.items, {}, deeperFirst);
    return loops.items;
}

fn byRank(rank: []const u32, left: u32, right: u32) bool {
    return rank[left] < rank[right];
}

fn deeperFirst(_: void, left: Loop, right: Loop) bool {
    return left.depth > right.depth;
}

pub fn canonicalize(function: *Function) !bool {
    const scratch = function.scratch;
    const graph = (try function.controlFlow()).*;
    const loops = try find(scratch, function, graph);
    var changed = false;
    for (loops) |loop| {
        if (try insertPreheader(function, graph, loop)) changed = true;
        if (changed) return true;
        if (try mergeLatches(function, loop)) return true;
    }
    return changed;
}

pub fn preheader(function: *const Function, graph: Graph, loop: Loop) ?u32 {
    var outside: ?u32 = null;
    for (graph.incoming[loop.header].items) |edge| {
        if (loop.contains(edge.block)) continue;
        if (outside != null) return null;
        outside = edge.block;
    }
    const block = outside orelse return null;
    if (function.blocks.items[block].terminator != .branch) return null;
    return block;
}

fn insertPreheader(function: *Function, graph: Graph, loop: Loop) !bool {
    if (preheader(function, graph, loop) != null) return false;
    var outside: std.ArrayList(graph_ir.Incoming) = .empty;
    for (graph.incoming[loop.header].items) |edge| {
        if (loop.contains(edge.block)) continue;
        try outside.append(function.scratch, edge);
    }
    if (outside.items.len == 0) return false;
    const taken = try value_rules.addressTaken(function);
    const header = &function.blocks.items[loop.header];
    const block = try function.addBlock(.diverge, header.span, header.frame);
    var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (function.blocks.items[loop.header].parameters.items, 0..) |parameter, position| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        const first = function.branchArguments(outside.items[0].branch(function).*)[position];
        const value = function.find(first.value);
        if (data.representation == .value and function.direct(data.type_id) and function.plainValue(value) and !taken[@backingInt(value)] and first.coerce_to == null) {
            for (outside.items[1..]) |edge| {
                const argument = function.branchArguments(edge.branch(function).*)[position];
                if (argument.coerce_to != null or function.find(argument.value) != value) break;
            } else {
                try arguments.append(function.scratch, .{ .value = value });
                continue;
            }
        }
        try arguments.append(function.scratch, .{ .value = try function.addParameter(block, data) });
    }
    function.blocks.items[block].terminator = .{ .branch = .{ .target = @fromBackingInt(loop.header), .arguments = try function.appendBranchArguments(arguments.items) } };
    for (outside.items) |edge| {
        const branch = edge.branch(function);
        const original = function.branchArguments(branch.*);
        var forwarded: std.ArrayList(structures.FunctionValueUse) = .empty;
        for (arguments.items, original) |argument, incoming| {
            const definition = function.definitions.items[@backingInt(argument.value)];
            if (definition == .argument and definition.argument.block == block) try forwarded.append(function.scratch, incoming);
        }
        branch.* = .{ .target = @fromBackingInt(block), .arguments = try function.appendBranchArguments(forwarded.items) };
    }
    const position = std.mem.indexOfScalar(u32, function.order.items, loop.header).?;
    try function.order.insert(function.scratch, position, block);
    return true;
}

fn mergeLatches(function: *Function, loop: Loop) !bool {
    if (loop.latches.len < 2) return false;
    var back: std.ArrayList(graph_ir.Incoming) = .empty;
    for (loop.latches) |latch| {
        for (Function.edges(&function.blocks.items[latch].terminator), 0..) |maybe_edge, ordinal| if (maybe_edge) |edge| {
            if (@backingInt(Function.edgeTarget(edge)) != loop.header) continue;
            try back.append(function.scratch, .{ .block = latch, .ordinal = @intCast(ordinal) });
        };
    }
    const header = &function.blocks.items[loop.header];
    const block = try function.addBlock(.diverge, header.span, header.frame);
    var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (function.blocks.items[loop.header].parameters.items) |parameter| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        try arguments.append(function.scratch, .{ .value = try function.addParameter(block, data) });
    }
    function.blocks.items[block].terminator = .{ .branch = .{ .target = @fromBackingInt(loop.header), .arguments = try function.appendBranchArguments(arguments.items) } };
    for (back.items) |edge| edge.branch(function).target = @fromBackingInt(block);
    try function.placeAfter(block, loop.latches[loop.latches.len - 1]);
    return true;
}

test "loop canonicalization preserves branch payloads when block storage relocates" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var relocating = std.testing.FailingAllocator.init(arena.allocator(), .{ .resize_fail_index = 0 });
    const scratch = relocating.allocator();
    var function: Function = .{
        .scratch = scratch,
        .return_type = .int,
        .is_initializer_region = false,
        .parameter_modes = &.{},
        .publishes_spans = false,
        .root_instance = null,
        .entry = 0,
        .blocks = try std.ArrayList(function_ir.Block).initCapacity(scratch, 6),
        .branch_arguments = try std.ArrayList(structures.FunctionValueUse).initCapacity(scratch, 8),
    };
    for (0..6) |_| {
        const block = try function.addBlock(.diverge, .{ .start = 0, .end = 0 }, .root);
        try function.order.append(scratch, block);
    }
    const shared = try function.addParameter(0, .{ .type_id = .int });
    const varying = try function.addParameter(0, .{ .type_id = .int });
    const carried_shared = try function.addParameter(1, .{ .type_id = .int });
    const carried_varying = try function.addParameter(1, .{ .type_id = .int });
    const empty: structures.FunctionValueRange = .{ .start = 0, .end = 0 };
    function.blocks.items[0].terminator = .{ .predicate_branch = .{
        .operation = .lti,
        .operands = .{ .lhs = shared, .rhs = varying },
        .then_branch = .{ .target = @fromBackingInt(1), .arguments = try function.appendBranchArguments(&.{ .{ .value = shared }, .{ .value = varying } }) },
        .else_branch = .{ .target = @fromBackingInt(2), .arguments = empty },
    } };
    function.blocks.items[2].terminator = .{ .branch = .{
        .target = @fromBackingInt(1),
        .arguments = try function.appendBranchArguments(&.{ .{ .value = shared }, .{ .value = shared } }),
    } };
    function.blocks.items[1].terminator = .{ .predicate_branch = .{
        .operation = .lti,
        .operands = .{ .lhs = carried_shared, .rhs = carried_varying },
        .then_branch = .{ .target = @fromBackingInt(3), .arguments = empty },
        .else_branch = .{ .target = @fromBackingInt(5), .arguments = empty },
    } };
    function.blocks.items[3].terminator = .{ .predicate_branch = .{
        .operation = .lti,
        .operands = .{ .lhs = carried_shared, .rhs = carried_varying },
        .then_branch = .{ .target = @fromBackingInt(1), .arguments = try function.appendBranchArguments(&.{ .{ .value = carried_shared }, .{ .value = carried_varying } }) },
        .else_branch = .{ .target = @fromBackingInt(4), .arguments = empty },
    } };
    function.blocks.items[4].terminator = .{ .branch = .{
        .target = @fromBackingInt(1),
        .arguments = try function.appendBranchArguments(&.{ .{ .value = shared }, .{ .value = carried_shared } }),
    } };
    function.blocks.items[5].terminator = .{ .return_value = .{ .value = carried_shared } };
    const verifier = @import("verifier.zig");
    try verifier.verifyFunction(&function);
    const original_blocks = function.blocks.items.ptr;
    try std.testing.expect(try canonicalize(&function));
    try std.testing.expect(original_blocks != function.blocks.items.ptr);
    try std.testing.expectEqual(@as(usize, 7), function.blocks.items.len);
    const preheader_block = function.blocks.items[6];
    try std.testing.expectEqual(@as(usize, 1), preheader_block.parameters.items.len);
    try expectBranch(&function, preheader_block.terminator.branch, 1, &.{ .{ .value = shared }, .{ .value = preheader_block.parameters.items[0] } });
    try expectBranch(&function, function.blocks.items[0].terminator.predicate_branch.then_branch, 6, &.{.{ .value = varying }});
    try expectBranch(&function, function.blocks.items[2].terminator.branch, 6, &.{.{ .value = shared }});
    try expectBranch(&function, function.blocks.items[3].terminator.predicate_branch.then_branch, 1, &.{ .{ .value = carried_shared }, .{ .value = carried_varying } });
    try expectBranch(&function, function.blocks.items[4].terminator.branch, 1, &.{ .{ .value = shared }, .{ .value = carried_shared } });
    try verifier.verifyFunction(&function);
    try std.testing.expect(try graph_ir.dominatesUses(&function));

    try function.blocks.shrinkToLen(scratch);
    const preheader_blocks = function.blocks.items.ptr;
    try std.testing.expect(try canonicalize(&function));
    try std.testing.expect(preheader_blocks != function.blocks.items.ptr);
    try std.testing.expectEqual(@as(usize, 8), function.blocks.items.len);
    const latch = function.blocks.items[7];
    try std.testing.expectEqual(@as(usize, 2), latch.parameters.items.len);
    try expectBranch(&function, latch.terminator.branch, 1, &.{ .{ .value = latch.parameters.items[0] }, .{ .value = latch.parameters.items[1] } });
    try expectBranch(&function, function.blocks.items[3].terminator.predicate_branch.then_branch, 7, &.{ .{ .value = carried_shared }, .{ .value = carried_varying } });
    try expectBranch(&function, function.blocks.items[4].terminator.branch, 7, &.{ .{ .value = shared }, .{ .value = carried_shared } });
    try verifier.verifyFunction(&function);
    try std.testing.expect(try graph_ir.dominatesUses(&function));
    try std.testing.expect(!try canonicalize(&function));
}

fn expectBranch(function: *const Function, branch: structures.FunctionBranch, target: u32, arguments: []const structures.FunctionValueUse) !void {
    try std.testing.expectEqual(target, @backingInt(branch.target));
    const actual = function.branchArguments(branch);
    try std.testing.expectEqual(arguments.len, actual.len);
    for (arguments, actual) |expected, found| try std.testing.expectEqualDeep(expected, found);
}

test "iteration ranges agree with wrapping executions at signed boundaries" {
    const numbers = [_]i32{ std.math.minInt(i32), std.math.minInt(i32) + 1, -3, -1, 0, 1, 3, std.math.maxInt(i32) - 1, std.math.maxInt(i32) };
    const steps = [_]i32{ std.math.minInt(i32), -3, -1, 1, 3, std.math.maxInt(i32) };
    const exits = [_]structures.PredicateOperation{ .gei, .gti, .lei, .lti };
    const comparisons = [_]structures.PredicateOperation{ .lti, .lei, .gti, .gei, .eqi, .nei };
    var proven: usize = 0;
    for (numbers) |first| for (numbers) |limit| for (steps) |step| for (exits) |exit| {
        const range = IterationRange.init(step, exit, .{ .lower = first, .upper = first }, .{ .lower = limit, .upper = limit }) orelse continue;
        proven += 1;
        var index = first;
        for (0..8) |_| {
            if (exit.holds(std.math.order(index, limit))) break;
            try std.testing.expect(range.absolute.lower <= index and index <= range.absolute.upper);
            for (comparisons) |operation| {
                if (range.absolute.known(operation, limit)) |known| try std.testing.expectEqual(operation.holds(std.math.order(index, limit)), known);
                if (range.relative.known(operation, 0)) |known| try std.testing.expectEqual(operation.holds(std.math.order(index, limit)), known);
            }
            const next = index +% step;
            try std.testing.expectEqual(@as(i64, index) + step, @as(i64, next));
            index = next;
        }
    };
    try std.testing.expect(proven != 0);
    try std.testing.expect(IterationRange.init(2, .gei, .{ .lower = std.math.maxInt(i32) - 1 }, .{}) == null);
    try std.testing.expect(IterationRange.init(-2, .lei, .{ .upper = std.math.minInt(i32) + 1 }, .{}) == null);
}
