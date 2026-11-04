const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const graph_ir = @import("graph.zig");
const value_rules = @import("canonicalize.zig");
const ranges = @import("ranges.zig");

const Interval = ranges.Interval;

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
        range: Interval,
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
        for (loop.blocks) |block| for (self.function.blocks.items[block].terminator.branches()) |maybe_edge| if (maybe_edge) |edge| {
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
        if (counter.terminal_bound) |bound| {
            if (comparison.operation != .eqi or comparison.other != bound) return null;
        }
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

    pub fn iterationRange(self: Analysis, at: u32, counter: InductionExit, depth: u32) ?IterationRange {
        if (depth == 0) return null;
        if (!self.immutable(counter.comparison.other)) return null;
        const start = self.rangeAt(counter.induction.start, at, depth - 1);
        const bound = self.rangeAt(counter.comparison.other, at, depth - 1);
        if (counter.induction.terminal_bound != null) {
            if (!self.immutable(counter.induction.start)) return null;
            const ascending = counter.induction.step == 1;
            const approaching = if (ascending) start.upper <= bound.lower else start.lower >= bound.upper;
            if (!approaching and !self.orderedAt(counter.induction.start, counter.comparison.other, at, ascending)) return null;
            return .{
                .absolute = if (ascending) .{ .lower = start.lower, .upper = bound.upper } else .{ .lower = bound.lower, .upper = start.upper },
                .relative = if (ascending) .{ .lower = start.lower - bound.upper, .upper = 0 } else .{ .lower = 0, .upper = start.upper - bound.lower },
            };
        }
        return IterationRange.init(
            counter.induction.step,
            counter.comparison.operation,
            start,
            bound,
        );
    }

    fn orderedAt(self: Analysis, first: ValueId, last: ValueId, at: u32, ascending: bool) bool {
        if (first == last) return true;
        var block = at;
        while (block != self.function.entry) {
            block = self.graph.dominator[block];
            const predicate = self.pathPredicate(block, at, null) orelse continue;
            const comparison = IntegerComparison.init(self.function, predicate.operation, predicate.operands, first) orelse continue;
            if (comparison.other != last) continue;
            switch (comparison.operation) {
                .eqi => return true,
                .lti, .lei => if (ascending) return true,
                .gti, .gei => if (!ascending) return true,
                else => {},
            }
        }
        return false;
    }

    const PathPredicate = struct { operation: structures.PredicateOperation, operands: structures.BinaryOperands };

    fn pathPredicate(self: Analysis, block: u32, at: u32, ordinal: ?u1) ?PathPredicate {
        const terminator = self.function.blocks.items[block].terminator;
        if (terminator != .predicate_branch) return null;
        const predicate = terminator.predicate_branch;
        const then_target = @backingInt(predicate.then_branch.target);
        const else_target = @backingInt(predicate.else_branch.target);
        const taken = if (ordinal) |edge|
            edge == 0
        else if (self.graph.incoming[then_target].items.len == 1 and self.graph.dominates(then_target, at))
            true
        else if (self.graph.incoming[else_target].items.len == 1 and self.graph.dominates(else_target, at))
            false
        else
            return null;
        return .{ .operation = if (taken) predicate.operation else predicate.operation.negated(), .operands = predicate.operands };
    }

    fn sameEquality(self: Analysis, first: structures.BinaryOperands, second: structures.BinaryOperands) bool {
        const a = self.function.find(first.lhs);
        const b = self.function.find(first.rhs);
        const c = self.function.find(second.lhs);
        const d = self.function.find(second.rhs);
        return (a == c and b == d) or (a == d and b == c);
    }

    fn equalityAt(self: Analysis, operands: structures.BinaryOperands, at: u32, ordinal: ?u1) ?bool {
        var block = at;
        var edge = ordinal;
        if (edge == null) {
            if (block == self.function.entry) return null;
            block = self.graph.dominator[block];
        }
        while (true) {
            if (self.pathPredicate(block, at, edge)) |predicate| {
                if ((predicate.operation == .eqi or predicate.operation == .nei) and self.sameEquality(operands, predicate.operands)) return predicate.operation == .eqi;
            }
            if (block == self.function.entry) return null;
            block = self.graph.dominator[block];
            edge = null;
        }
    }

    /// Equality loops with unit strides terminate without overflowing only when
    /// the initial counter is on the approaching side of the bound.
    pub fn equalityRecurrenceSafe(self: Analysis, preheader_block: u32, counter: InductionExit) bool {
        if (!self.immutable(counter.comparison.other)) return false;
        if (counter.induction.start == counter.comparison.other) return true;
        const start = self.rangeAt(counter.induction.start, preheader_block, 16);
        const bound = self.rangeAt(counter.comparison.other, preheader_block, 16);
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
        const back = function.branchArguments((function.branchTo(loop.latches[0], loop.header) orelse return null).*)[position];
        if (start.coerce_to != null or back.coerce_to != null) return null;
        const ending = exitTestAt(function, loop, loop.latches[0]);
        const terminal = if (ending) |exit| if (exit.operation == .eqi) IntegerComparison.init(function, exit.operation, exit.operands, parameter) else null else null;
        const next_value = self.forwardedAssuming(back.value, 16, if (terminal != null) ending else null);
        if (!self.immutable(next_value)) return null;
        const next = function.definition(next_value) orelse return null;
        const update = Offset.init(next) orelse return null;
        const operands = update.operands;
        const step = if (update.subtract) step: {
            if (function.find(operands.lhs) != parameter) return null;
            const decrement = self.integerConstant(operands.rhs) orelse return null;
            if (decrement == std.math.minInt(i32) and next == .numeric_binary) return null;
            break :step -%decrement;
        } else step: {
            const operand = if (function.find(operands.lhs) == parameter) operands.rhs else if (function.find(operands.rhs) == parameter) operands.lhs else return null;
            break :step self.integerConstant(operand) orelse return null;
        };
        if (step == 0) return null;
        var terminal_bound: ?ValueId = null;
        if (terminal) |comparison| {
            if (step != 1 and step != -1) return null;
            // A terminal iteration keeps the current value. Its speculative
            // modular update is harmless, but a checked producer must execute
            // only on the nonterminal path, including at signed endpoints.
            const producer = self.instruction_blocks[function.instructionIndex(next_value).?];
            if (next == .numeric_binary and next.numeric_binary.overflow == .checked and self.equalityAt(ending.?.operands, producer, null) != false) return null;
            terminal_bound = comparison.other;
        }
        return .{ .parameter = parameter, .start = self.forwardedAssuming(start.value, 16, null), .next = next_value, .step = step, .terminal_bound = terminal_bound };
    }

    fn forwardedAssuming(self: Analysis, value: ValueId, depth: u32, terminal: ?ExitTest) ValueId {
        const resolved = self.function.find(value);
        if (depth == 0 or !self.immutable(resolved)) return resolved;
        const definition = self.function.definitions.items[@backingInt(resolved)];
        if (definition == .instruction) {
            const instruction = self.function.instructions.items[definition.instruction];
            if (terminal) |exit| if (instruction == .select) {
                const condition = self.function.definition(self.function.find(instruction.select.condition)) orelse return resolved;
                if (condition == .compare and (condition.compare.operation == .eqi or condition.compare.operation == .nei) and self.sameEquality(exit.operands, condition.compare.operands)) {
                    return self.forwardedAssuming(if (condition.compare.operation == .eqi) instruction.select.else_value else instruction.select.then_value, depth - 1, terminal);
                }
            };
            return resolved;
        }
        const block = definition.argument.block;
        const incoming = self.graph.incoming[block].items;
        if (incoming.len == 0) return resolved;
        for (incoming) |edge| if (self.graph.dominates(block, edge.block)) return resolved;
        const position = std.mem.indexOfScalar(ValueId, self.function.blocks.items[block].parameters.items, resolved).?;
        var source: ?ValueId = null;
        for (incoming) |edge| {
            if (terminal) |exit| if (self.equalityAt(exit.operands, edge.block, edge.ordinal) == true) continue;
            const argument = self.function.branchArguments(edge.branch(self.function).*)[position];
            if (argument.coerce_to != null or argument.variant_tag_mapping != null) return resolved;
            const forwarded_value = self.forwardedAssuming(argument.value, depth - 1, terminal);
            if (source) |previous| {
                if (previous != forwarded_value) return resolved;
            } else source = forwarded_value;
        }
        return source orelse resolved;
    }

    pub fn rangeAt(self: Analysis, value: ValueId, at: u32, depth: u32) Interval {
        return ranges.bounds(At{ .analysis = &self, .function = self.function, .block = at }, value, depth);
    }

    fn inductionRange(self: Analysis, value: ValueId, at: u32, depth: u32) ?Interval {
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
                const range = self.iterationRange(at, counter, depth - 1) orelse continue;
                return range.absolute;
            }
        }
        return null;
    }

    /// Whether a checked add or subtract of a constant to a header parameter
    /// cannot overflow. A parameter that changes by a bounded step per iteration
    /// moves at most as far as the unit-stride `counter` has, which `travelled`
    /// bounds at the operation.
    pub fn shiftFits(self: Analysis, loop: Loop, entry: u32, counter: InductionExit, travelled: Interval, operation: structures.NumericBinary) bool {
        if (operation.type_id != .int or operation.overflow != .checked) return false;
        if (operation.operation != .add and operation.operation != .sub) return false;
        const function = self.function;
        const parameters = function.blocks.items[loop.header].parameters.items;
        const lhs = function.find(operation.operands.lhs);
        const rhs = function.find(operation.operands.rhs);
        const parameter, const offset = if (std.mem.indexOfScalar(ValueId, parameters, lhs) != null)
            .{ lhs, self.integerConstant(rhs) orelse return false }
        else if (operation.operation == .add and std.mem.indexOfScalar(ValueId, parameters, rhs) != null)
            .{ rhs, self.integerConstant(lhs) orelse return false }
        else
            return false;
        var base = travelled;
        if (parameter != counter.induction.parameter) {
            if (counter.induction.step != 1 and counter.induction.step != -1) return false;
            const position = std.mem.indexOfScalar(ValueId, parameters, parameter).?;
            const back = function.branchArguments((function.branchTo(loop.latches[0], loop.header) orelse return false).*)[position];
            const first = function.branchArguments(function.blocks.items[entry].terminator.branch)[position];
            if (back.coerce_to != null or first.coerce_to != null) return false;
            const step = self.change(loop, back.value, parameter, 16) orelse return false;
            const start = self.rangeAt(first.value, entry, 16);
            const iterations: i128 = travelled.upper - travelled.lower;
            base = .{
                .lower = @intCast(std.math.clamp(start.lower + iterations * @min(0, step.lower), std.math.minInt(i32), std.math.maxInt(i32))),
                .upper = @intCast(std.math.clamp(start.upper + iterations * @max(0, step.upper), std.math.minInt(i32), std.math.maxInt(i32))),
            };
        }
        const shift: i64 = if (operation.operation == .sub) -@as(i64, offset) else offset;
        return Interval.fits(.{ .lower = base.lower + shift, .upper = base.upper + shift });
    }

    /// What one iteration adds to `parameter` along the value its latch forwards.
    fn change(self: Analysis, loop: Loop, value: ValueId, parameter: ValueId, depth: u32) ?Interval {
        if (depth == 0) return null;
        const function = self.function;
        const resolved = function.find(value);
        if (resolved == parameter) return Interval.point(0);
        if (!self.immutable(resolved)) return null;
        switch (function.definitions.items[@backingInt(resolved)]) {
            .argument => |argument| {
                if (argument.block == loop.header or !loop.contains(argument.block)) return null;
                const position = std.mem.indexOfScalar(ValueId, function.blocks.items[argument.block].parameters.items, resolved).?;
                var joined: ?Interval = null;
                for (self.graph.incoming[argument.block].items) |edge| {
                    const use = function.branchArguments(edge.branch(function).*)[position];
                    if (use.coerce_to != null or use.variant_tag_mapping != null) return null;
                    const found = self.change(loop, use.value, parameter, depth - 1) orelse return null;
                    joined = if (joined) |previous| previous.join(found) else found;
                }
                return joined;
            },
            .instruction => |index| {
                const instruction = function.instructions.items[index];
                if (instruction == .select) {
                    const first = self.change(loop, instruction.select.then_value, parameter, depth - 1) orelse return null;
                    return first.join(self.change(loop, instruction.select.else_value, parameter, depth - 1) orelse return null);
                }
                const update = Offset.init(instruction) orelse return null;
                if (!update.checked) return null;
                const operands = update.operands;
                const offset = if (function.find(operands.lhs) == parameter)
                    self.integerConstant(operands.rhs) orelse return null
                else if (!update.subtract and function.find(operands.rhs) == parameter)
                    self.integerConstant(operands.lhs) orelse return null
                else
                    return null;
                return Interval.point(if (update.subtract) -@as(i64, offset) else offset);
            },
        }
    }

    /// The join over every edge into a block parameter, or over one field of the
    /// aggregate each edge forwards.
    fn parameterRange(self: Analysis, value: ValueId, field: ?u32, depth: u32, visited: []const ValueId) ?Interval {
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
        var range: ?Interval = null;
        for (incoming) |edge| {
            const argument = self.function.branchArguments(edge.branch(self.function).*)[position];
            if (argument.coerce_to != null or argument.variant_tag_mapping != null) return .{};
            var source = self.function.find(argument.value);
            if (!self.immutable(source)) return .{};
            if (field) |index| {
                if (source == resolved) continue;
                const aggregate = self.function.definition(source) orelse return .{};
                if (aggregate != .aggregate) return .{};
                source = self.function.find(self.function.aggregate_fields.items[aggregate.aggregate.fields.start + index]);
            }
            const source_definition = self.function.definitions.items[@backingInt(source)];
            const found = if (source_definition == .argument and source_definition.argument.block != self.function.entry)
                self.parameterRange(source, field, depth - 1, path[0 .. visited.len + 1]) orelse continue
            else
                self.rangeAt(source, edge.block, depth - 1);
            range = if (range) |previous| previous.join(found) else found;
        }
        return range;
    }
};

/// Range context at one block: guards that dominate it and facts from calls
/// that returned normally narrow what definitions alone give.
const At = struct {
    analysis: *const Analysis,
    function: *const Function,
    block: u32,

    pub fn trusted(self: At, value: ValueId) bool {
        return self.analysis.immutable(value);
    }

    pub fn leaf(self: At, value: ValueId, depth: u32) ?Interval {
        const analysis = self.analysis;
        return switch (self.function.definitions.items[@backingInt(value)]) {
            .argument => analysis.inductionRange(value, self.block, depth) orelse analysis.parameterRange(value, null, depth, &.{}),
            .instruction => |index| switch (analysis.function.instructions.items[index]) {
                .field_access => |access| analysis.parameterRange(access.operand, access.field_index, depth, &.{}),
                else => null,
            },
        };
    }

    pub fn narrow(self: At, value: ValueId, range: Interval) Interval {
        const analysis = self.analysis;
        var narrowed = range;
        var block = self.block;
        while (block != self.function.entry) {
            block = analysis.graph.dominator[block];
            const predicate = analysis.pathPredicate(block, self.block, null) orelse continue;
            const comparison = IntegerComparison.init(self.function, predicate.operation, predicate.operands, value) orelse continue;
            narrowed.refine(comparison.operation, analysis.integerConstant(comparison.other) orelse continue);
        }
        return narrowed;
    }

    pub fn facts(self: At, value: ValueId, range: Interval, user: ?ValueId) Interval {
        const analysis = self.analysis;
        const index = self.function.instructionIndex(user orelse return range) orelse return range;
        var narrowed = range;
        for (analysis.call_arguments) |argument| {
            if (self.function.find(argument.value) != self.function.find(value)) continue;
            const call_block = analysis.instruction_blocks[argument.instruction];
            if (!analysis.graph.dominates(call_block, analysis.instruction_blocks[index])) continue;
            if (call_block == analysis.instruction_blocks[index] and analysis.instruction_positions[argument.instruction] >= analysis.instruction_positions[index]) continue;
            narrowed.lower = @max(narrowed.lower, argument.range.lower);
            narrowed.upper = @min(narrowed.upper, argument.range.upper);
        }
        return narrowed;
    }
};

/// Integer addition or subtraction, either modular or checked.
const Offset = struct {
    operands: structures.BinaryOperands,
    subtract: bool,
    checked: bool = false,

    fn init(instruction: structures.FunctionInstruction) ?Offset {
        return switch (instruction) {
            .numeric_binary => |operation| if (operation.type_id != .int or operation.overflow == .saturating) null else switch (operation.operation) {
                .add, .sub => .{ .operands = operation.operands, .subtract = operation.operation == .sub, .checked = operation.overflow == .checked },
                else => null,
            },
            .addi => |operands| .{ .operands = operands, .subtract = false },
            .subi => |operands| .{ .operands = operands, .subtract = true },
            else => null,
        };
    }
};

pub const Induction = struct {
    parameter: ValueId,
    start: ValueId,
    next: ValueId,
    step: i32,
    terminal_bound: ?ValueId = null,
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
    const result = exitTestAt(function, loop, loop.header) orelse return null;
    const arguments = function.branchTo(loop.header, result.exit).?.arguments;
    return if (arguments.start == arguments.end) result else null;
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

const IterationRange = struct {
    absolute: Interval,
    relative: Interval,

    fn init(step: i32, operation: structures.PredicateOperation, start: Interval, bound: Interval) ?IterationRange {
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
        var relative: Interval = .{ .lower = range.lower - bound.upper, .upper = range.upper - bound.lower };
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

/// Gives every loop a preheader and a single latch, then returns the loops of
/// the resulting graph. Dominance is computed only when some edge can be a back
/// edge. Fixing one loop leaves the edges into every other header and the
/// membership of every other loop's latches intact, so one analysis serves the
/// whole round, in the same order as repeating the analysis after each fix.
pub fn canonicalLoops(function: *Function) ![]const Loop {
    const scratch = function.scratch;
    while (true) {
        if (!(try function.controlFlowEdges()).cyclic) return &.{};
        const graph = (try function.controlFlow()).*;
        const loops = try find(scratch, function, graph);
        var changed = false;
        for (loops) |loop| {
            changed = (try insertPreheader(function, graph, loop)) or changed;
            changed = (try mergeLatches(function, loop)) or changed;
        }
        if (!changed) return loops;
    }
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
        if (function.directParameter(parameter) and function.plainValue(value) and !taken[@backingInt(value)] and first.coerce_to == null) {
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
    const header = &function.blocks.items[loop.header];
    const block = try function.addBlock(.diverge, header.span, header.frame);
    var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (function.blocks.items[loop.header].parameters.items) |parameter| {
        const data = function.definitions.items[@backingInt(parameter)].argument.data;
        try arguments.append(function.scratch, .{ .value = try function.addParameter(block, data) });
    }
    function.blocks.items[block].terminator = .{ .branch = .{ .target = @fromBackingInt(loop.header), .arguments = try function.appendBranchArguments(arguments.items) } };
    for (loop.latches) |latch| for (function.blocks.items[latch].terminator.branches()) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == loop.header) edge.target = @fromBackingInt(block);
    };
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
    _ = try canonicalLoops(&function);
    try std.testing.expect(original_blocks != function.blocks.items.ptr);
    try std.testing.expectEqual(@as(usize, 8), function.blocks.items.len);
    const preheader_block = function.blocks.items[6];
    try std.testing.expectEqual(@as(usize, 1), preheader_block.parameters.items.len);
    try expectBranch(&function, preheader_block.terminator.branch, 1, &.{ .{ .value = shared }, .{ .value = preheader_block.parameters.items[0] } });
    try expectBranch(&function, function.blocks.items[0].terminator.predicate_branch.then_branch, 6, &.{.{ .value = varying }});
    try expectBranch(&function, function.blocks.items[2].terminator.branch, 6, &.{.{ .value = shared }});
    const latch = function.blocks.items[7];
    try std.testing.expectEqual(@as(usize, 2), latch.parameters.items.len);
    try expectBranch(&function, latch.terminator.branch, 1, &.{ .{ .value = latch.parameters.items[0] }, .{ .value = latch.parameters.items[1] } });
    try expectBranch(&function, function.blocks.items[3].terminator.predicate_branch.then_branch, 7, &.{ .{ .value = carried_shared }, .{ .value = carried_varying } });
    try expectBranch(&function, function.blocks.items[4].terminator.branch, 7, &.{ .{ .value = shared }, .{ .value = carried_shared } });
    try verifier.verifyFunction(&function);
    try std.testing.expect(try graph_ir.dominatesUses(&function));
    const canonical_blocks = function.blocks.items.ptr;
    try std.testing.expectEqual(@as(usize, 1), (try canonicalLoops(&function)).len);
    try std.testing.expectEqual(canonical_blocks, function.blocks.items.ptr);
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
