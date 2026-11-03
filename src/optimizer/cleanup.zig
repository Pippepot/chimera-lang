const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");
const effects = @import("effects.zig");

const ValueId = structures.FunctionValueId;
const Function = function_ir.Function;
const Incoming = @import("graph.zig").Incoming;
const Graph = @import("graph.zig").Graph;

pub fn simplifyParameters(function: *Function, variants: bool) !bool {
    if (!function.hasJoinParameters()) return false;
    function.resolveReferences();
    const graph = (try function.controlFlowEdges()).*;
    var parameters: ParameterSimplifier = .{
        .function = function,
        .incoming = graph.incoming,
        .stability = .{ .function = function },
    };
    var changed = false;
    if (variants) {
        changed = try narrowParameters(&parameters);
        if (changed) function.resolveReferences();
        changed = try splitScalarVariants(&parameters) or changed;
    }
    for (graph.order) |block| if (try parameters.foldParameters(block)) {
        changed = true;
    };
    if (changed) function.resolveReferences();
    return changed;
}

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

const scalar_types = [_]structures.TypeId{ .int, .bool, .byte };

// A variant join parameter that every predecessor feeds one injected scalar
// alternative splits into a tag and payload parameters when its remaining
// uses only read the tag or a scalar payload.
const SplitCandidate = struct {
    block: u32,
    position: usize,
    parameter: ValueId,
    references: u32 = 0,
    accepted: u32 = 0,
    payloads: [scalar_types.len]bool = @splat(false),
    split: ?ScalarVariant = null,

    fn splittable(self: SplitCandidate) bool {
        return self.accepted != 0 and self.references == self.accepted;
    }
};

const VariantUses = struct {
    function: *const Function,
    candidates: []SplitCandidate,
    taken: []const bool,
    touched: bool = false,

    fn lookup(self: *VariantUses, value: ValueId) ?*SplitCandidate {
        if (self.function.definitions.items[@backingInt(value)] != .argument) return null;
        for (self.candidates) |*candidate| if (candidate.parameter == value) return candidate;
        return null;
    }

    fn count(self: *VariantUses, value: ValueId) void {
        const candidate = self.lookup(value) orelse return;
        candidate.references += 1;
        self.touched = true;
    }

    /// Returns whether every candidate already has a use that prevents splitting.
    fn block(self: *VariantUses, body: *const function_ir.Block) bool {
        const function = self.function;
        for (body.instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            function_ir.visitInstructionReferences(function, instruction, self, count);
            const result = function.results.items[index];
            if (@backingInt(result) >= self.taken.len or !self.taken[@backingInt(result)]) switch (instruction.*) {
                .variant_tag => |operand| if (self.lookup(operand)) |candidate| {
                    candidate.accepted += 1;
                },
                .variant_extract => |extraction| if (extraction.destination == null) {
                    if (std.mem.indexOfScalar(structures.TypeId, &scalar_types, extraction.target_type)) |scalar| {
                        if (self.lookup(extraction.operand)) |candidate| {
                            candidate.payloads[scalar] = true;
                            candidate.accepted += 1;
                        }
                    }
                },
                else => {},
            };
            if (self.touched and !self.anyAlive()) return true;
        }
        function_ir.visitTerminatorReferences(function, &body.terminator, self, count);
        return self.touched and !self.anyAlive();
    }

    /// References only accumulate, so a candidate with an unaccepted use stays rejected.
    fn anyAlive(self: *VariantUses) bool {
        self.touched = false;
        for (self.candidates) |candidate| if (candidate.references == candidate.accepted) return true;
        return false;
    }
};

fn splitScalarVariants(parameters: *ParameterSimplifier) !bool {
    const function = parameters.function;
    const graph = (try function.controlFlowEdges()).*;
    var candidates: std.ArrayList(SplitCandidate) = .empty;
    for (graph.order) |block| {
        if (block == function.entry) continue;
        const edges = graph.incoming[block].items;
        if (edges.len < 2) continue;
        var position = function.blocks.items[block].parameters.items.len;
        while (position > 0) {
            position -= 1;
            const parameter = function.blocks.items[block].parameters.items[position];
            if (function.valueType(parameter).isPrimitive()) continue;
            if (!function.plainValue(parameter)) continue;
            for (edges) |edge| {
                const use = function.branchArguments(edge.branch(function).*)[position];
                const mapping = use.variant_tag_mapping orelse break;
                if (use.coerce_to == null or mapping.end - mapping.start != 1) break;
            } else {
                if ((try parameters.addressTaken())[@backingInt(parameter)]) continue;
                try candidates.append(function.scratch, .{ .block = block, .position = position, .parameter = parameter });
            }
        }
    }
    if (candidates.items.len == 0) return false;
    countVariantUses(function, graph, try parameters.addressTaken(), candidates.items);
    var changed = false;
    for (candidates.items) |*candidate| {
        if (!candidate.splittable()) continue;
        candidate.split = try splitScalarVariant(function, candidate.*, graph.incoming[candidate.block].items);
        changed = true;
    }
    if (changed) {
        replaceScalarVariants(function, candidates.items);
        function.resolveReferences();
    }
    return changed;
}

/// Uses are dominated by their parameter's block, which precedes them in
/// reverse postorder, so the scan starts at the first candidate and ends once
/// no candidate can split.
fn countVariantUses(function: *Function, graph: Graph, taken: []const bool, candidates: []SplitCandidate) void {
    var uses: VariantUses = .{ .function = function, .candidates = candidates, .taken = taken };
    var first = graph.order.len;
    for (candidates) |candidate| first = @min(first, graph.rank[candidate.block]);
    for (graph.order[first..]) |block| if (uses.block(&function.blocks.items[block])) return;
    for (function.blocks.items, graph.reachable) |*body, reachable| if (!reachable and uses.block(body)) return;
}

const ScalarVariant = struct {
    tag: ValueId,
    payloads: [scalar_types.len]?ValueId,
};

fn splitScalarVariant(function: *Function, candidate: SplitCandidate, edges: []const Incoming) !ScalarVariant {
    const block = candidate.block;
    const position = candidate.position;
    const tag = try function.addParameter(block, .{ .type_id = .int });
    var parameters: [scalar_types.len]?ValueId = @splat(null);
    for (candidate.payloads, scalar_types, &parameters) |needed, type_id, *value| {
        if (needed) value.* = try function.addParameter(block, .{ .type_id = type_id });
    }
    for (edges) |edge| {
        const branch = edge.branch(function);
        const use = function.branchArguments(branch.*)[position];
        const source = function.blocks.items[edge.block];
        const discriminator: i32 = @bitCast(function.variant_coercion_tags.items[use.variant_tag_mapping.?.start]);
        var appended: std.ArrayList(ValueId) = .empty;
        try appended.append(function.scratch, try function.appendInstruction(edge.block, .{ .const_int = discriminator }, source.span, source.frame));
        for (parameters, scalar_types) |payload, type_id| if (payload != null) {
            const value = if (function.valueType(use.value) == type_id) use.value else try function.appendInstruction(edge.block, function_ir.zero(type_id), source.span, source.frame);
            try appended.append(function.scratch, value);
        };
        branch.arguments = try function.copyBranchArguments(branch.arguments, appended.items);
    }
    try function.removeParameter(block, position, edges);
    return .{ .tag = tag, .payloads = parameters };
}

fn replaceScalarVariants(function: *Function, candidates: []const SplitCandidate) void {
    for (function.blocks.items) |body| for (body.instructions.items) |index| {
        if (function.removed.items[index]) continue;
        const instruction = function.instructions.items[index];
        const result = function.results.items[index];
        const operand = switch (instruction) {
            .variant_tag => |operand| operand,
            .variant_extract => |extraction| extraction.operand,
            else => continue,
        };
        const split = for (candidates) |candidate| {
            if (candidate.parameter == operand) break candidate.split orelse continue;
        } else continue;
        const replacement: ValueId = switch (instruction) {
            .variant_tag => split.tag,
            .variant_extract => |extraction| split.payloads[std.mem.indexOfScalar(structures.TypeId, &scalar_types, extraction.target_type).?].?,
            else => unreachable,
        };
        function.replace(result, replacement);
        function.removed.items[index] = true;
    };
}

// A merge of injections of one alternative can carry its payload directly.
// Rebuild the variant only for consumers that still need the complete value.
fn narrowParameters(parameters: *ParameterSimplifier) !bool {
    const function = parameters.function;
    const graph = (try function.controlFlowEdges()).*;
    var changed = false;
    for (graph.order) |block| {
        if (block == function.entry or graph.incoming[block].items.len == 0) continue;
        var position = function.blocks.items[block].parameters.items.len;
        while (position > 0) {
            position -= 1;
            const parameter = function.blocks.items[block].parameters.items[position];
            if (function.valueType(parameter).isPrimitive() or !function.directParameter(parameter)) continue;
            const edges = graph.incoming[block].items;
            const first = function.branchArguments(edges[0].branch(function).*)[position];
            const mapping = first.variant_tag_mapping orelse continue;
            if (first.coerce_to == null or mapping.end - mapping.start != 1) continue;
            const type_id = function.valueType(first.value);
            if (!function.direct(type_id)) continue;
            const tag = function.variant_coercion_tags.items[mapping.start];
            const taken = try parameters.addressTaken();
            if (taken[@backingInt(parameter)]) continue;
            for (edges) |edge| {
                const argument = function.branchArguments(edge.branch(function).*)[position];
                const tags = argument.variant_tag_mapping orelse break;
                if (argument.coerce_to != first.coerce_to or tags.end - tags.start != 1 or function.valueType(argument.value) != type_id) break;
                if (function.variant_coercion_tags.items[tags.start] != tag) break;
            } else {
                const payload = try function.addParameter(block, .{ .type_id = type_id });
                const rebuilt = try function.insertInstruction(block, 0, .{ .variant_coerce = .{
                    .operand = payload,
                    .target_type = function.valueType(parameter),
                    .tag_mapping = mapping,
                } }, function.blocks.items[block].span, function.blocks.items[block].frame);
                for (edges) |edge| {
                    const branch = edge.branch(function);
                    const value = function.branchArguments(branch.*)[position].value;
                    branch.arguments = try function.copyBranchArguments(branch.arguments, &.{value});
                }
                function.replace(parameter, rebuilt);
                try function.removeParameter(block, position, edges);
                changed = true;
            }
        }
    }
    return changed;
}

const ParameterSimplifier = struct {
    function: *Function,
    incoming: []const std.ArrayList(Incoming),
    address_taken: ?[]const bool = null,
    stability: effects.Stability,

    fn addressTaken(self: *ParameterSimplifier) ![]const bool {
        if (self.address_taken == null) self.address_taken = try canonicalize.addressTaken(self.function);
        const taken = self.address_taken.?;
        if (taken.len < self.function.valueCount()) {
            const extended = try self.function.scratch.alloc(bool, self.function.valueCount());
            @memcpy(extended[0..taken.len], taken);
            @memset(extended[taken.len..], false);
            self.address_taken = extended;
        }
        return self.address_taken.?;
    }

    fn stable(self: *ParameterSimplifier, value: ValueId) !bool {
        if (!self.function.plainValue(value)) return false;
        const taken = try self.addressTaken();
        if (!taken[@backingInt(value)]) return true;
        return !try self.stability.exposed(value) and try self.stability.stable(value);
    }

    fn foldParameters(self: *ParameterSimplifier, block: u32) !bool {
        const function = self.function;
        if (block == function.entry) return false;
        var changed = false;
        var position = function.blocks.items[block].parameters.items.len;
        while (position > 0) {
            position -= 1;
            const parameter = function.blocks.items[block].parameters.items[position];
            if (!function.directParameter(parameter)) continue;
            var common: ?ValueId = null;
            for (self.incoming[block].items) |edge| {
                const argument = function.branchArguments(edge.branch(function).*)[position];
                if (argument.coerce_to != null) break;
                const value = function.find(argument.value);
                if (value == parameter) continue;
                if (!function.plainValue(value)) break;
                if (common) |previous| {
                    if (previous != value) break;
                } else common = value;
            } else if (common) |value| {
                if (!try self.stable(parameter) or !try self.stable(value)) continue;
                function.replace(parameter, value);
            }
            if (function.find(parameter) == parameter and !try self.selectParameter(block, position)) continue;
            try function.removeParameter(block, position, self.incoming[block].items);
            changed = true;
        }
        return changed;
    }

    const Arm = struct { fork: u32, ordinal: u1 };

    fn armOrigin(self: *ParameterSimplifier, edge: Incoming) ?Arm {
        const source = self.function.blocks.items[edge.block];
        if (source.terminator == .predicate_branch) return .{ .fork = edge.block, .ordinal = edge.ordinal };
        if (source.terminator != .branch or self.incoming[edge.block].items.len != 1) return null;
        const before = self.incoming[edge.block].items[0];
        if (self.function.blocks.items[before.block].terminator != .predicate_branch) return null;
        return .{ .fork = before.block, .ordinal = before.ordinal };
    }

    fn availableAt(self: *ParameterSimplifier, graph: @import("graph.zig").Graph, value: ValueId, at: u32) bool {
        const function = self.function;
        switch (function.definitions.items[@backingInt(value)]) {
            .argument => |argument| return graph.dominates(argument.block, at),
            .instruction => |index| {
                for (graph.order) |block| {
                    if (std.mem.indexOfScalar(u32, function.blocks.items[block].instructions.items, index) != null) return graph.dominates(block, at);
                }
                unreachable;
            },
        }
    }

    // A scalar join can select values already available at the fork without
    // speculating either arm's instructions. In particular, checked updates
    // remain conditional while their independently carried flags simplify.
    fn selectParameter(self: *ParameterSimplifier, block: u32, position: usize) !bool {
        const function = self.function;
        const incoming = self.incoming[block].items;
        if (incoming.len != 2) return false;
        const parameter = function.blocks.items[block].parameters.items[position];
        if (function.valueType(parameter) != .bool or !try self.stable(parameter)) return false;
        const first = self.armOrigin(incoming[0]) orelse return false;
        const second = self.armOrigin(incoming[1]) orelse return false;
        if (first.fork != second.fork or first.ordinal == second.ordinal or first.fork == block) return false;
        const fork = first.fork;
        const predicate = function.blocks.items[fork].terminator.predicate_branch;
        if (predicate.operation == .eqt or predicate.operation == .net) return false;
        var values: [2]ValueId = undefined;
        const graph = (try function.controlFlow()).*;
        if (!graph.dominates(fork, block)) return false;
        for (incoming, [_]Arm{ first, second }) |edge, arm| {
            const argument = function.branchArguments(edge.branch(function).*)[position];
            if (argument.coerce_to != null or argument.variant_tag_mapping != null) return false;
            const value = function.find(argument.value);
            if (!try self.stable(value) or !self.availableAt(graph, value, fork)) return false;
            values[arm.ordinal] = value;
        }
        const source = function.blocks.items[fork];
        const condition = try function.appendInstruction(fork, .{ .compare = .{ .operation = predicate.operation, .operands = predicate.operands } }, source.span, source.frame);
        const selected = if (function.constantBool(values[0]) == true and function.constantBool(values[1]) == false)
            condition
        else
            try function.appendInstruction(fork, .{ .select = .{ .condition = condition, .then_value = values[0], .else_value = values[1], .type_id = .bool } }, source.span, source.frame);
        function.replace(parameter, selected);
        return true;
    }
};

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

    fn selectEdgeArguments(self: *Sweep, block: u32) !bool {
        const function = self.function;
        const terminator = &function.blocks.items[block].terminator;
        if (terminator.* != .predicate_branch) return false;
        const predicate = terminator.predicate_branch;
        var changed = false;
        for (terminator.branches(), 0..) |maybe_edge, ordinal| {
            const edge = maybe_edge orelse continue;
            const arguments = function.branchArguments(edge.*);
            var replacements: ?[]structures.FunctionValueUse = null;
            for (arguments, 0..) |argument, index| {
                const value = function.find(argument.value);
                if (@backingInt(value) >= self.address_taken.len or self.address_taken[@backingInt(value)]) continue;
                const definition = function.definition(value) orelse continue;
                if (definition != .select) continue;
                const select = definition.select;
                const condition = function.find(select.condition);
                const taken = if ((predicate.operation == .eqb or predicate.operation == .neb) and function.find(predicate.operands.lhs) == condition) flag: {
                    const expected = function.constantBool(function.find(predicate.operands.rhs)) orelse continue;
                    break :flag expected == ((predicate.operation == .eqb) == (ordinal == 0));
                } else compared: {
                    const comparison = function.definition(condition) orelse continue;
                    if (comparison != .compare or !std.meta.eql(comparison.compare.operands, predicate.operands)) continue;
                    if (comparison.compare.operation == predicate.operation) break :compared ordinal == 0;
                    if (comparison.compare.operation == predicate.operation.negated()) break :compared ordinal != 0;
                    continue;
                };
                const selected = function.find(if (taken) select.then_value else select.else_value);
                if (!function.plainValue(selected) or @backingInt(selected) >= self.address_taken.len or self.address_taken[@backingInt(selected)]) continue;
                if (replacements == null) replacements = try function.scratch.dupe(structures.FunctionValueUse, arguments);
                replacements.?[index].value = selected;
            }
            if (replacements) |values| {
                edge.arguments = try function.appendBranchArguments(values);
                changed = true;
            }
        }
        if (changed) self.touch(block);
        return changed;
    }

    fn threadExit(self: *Sweep, block: u32) !bool {
        const function = self.function;
        for (function.blocks.items[block].terminator.branches()) |maybe_edge| {
            const edge = maybe_edge orelse continue;
            const target = @backingInt(edge.target);
            if (target == block or self.dirty[target]) continue;
            const join = function.blocks.items[target];
            if (join.instructions.items.len != 0 or join.terminator != .predicate_branch) continue;
            const predicate = join.terminator.predicate_branch;
            if (predicate.operation == .eqt or predicate.operation == .net) continue;
            const lhs = self.incomingValue(join, edge.*, predicate.operands.lhs) orelse continue;
            const rhs = self.incomingValue(join, edge.*, predicate.operands.rhs) orelse continue;
            const order = if (lhs == rhs) .eq else std.math.order(function.constantInt(lhs) orelse continue, function.constantInt(rhs) orelse continue);
            const selected = if (predicate.operation.holds(order)) predicate.then_branch else predicate.else_branch;
            if (@backingInt(selected.target) == target) continue;
            if (self.dirty[@backingInt(selected.target)]) continue;
            for (join.parameters.items) |parameter| {
                if (!function.valueType(parameter).isPrimitive() or !function.plainValue(parameter) or self.address_taken[@backingInt(parameter)]) break;
            } else {
                if (!try self.independentExit(target, @backingInt(selected.target), join.parameters.items)) continue;
                var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
                for (function.branchArguments(selected)) |argument| {
                    var forwarded = argument;
                    forwarded.value = self.incomingValue(join, edge.*, argument.value) orelse break;
                    try arguments.append(function.scratch, forwarded);
                } else {
                    edge.* = .{ .target = selected.target, .arguments = try function.appendBranchArguments(arguments.items) };
                    self.touch(block);
                    return true;
                }
            }
        }
        return false;
    }

    // Bypassing a join cannot leave its parameters in use along the selected
    // continuation. Re-entering the join defines them again, so it is a barrier
    // rather than a reason to reject loop exits and outer-loop continuations.
    fn independentExit(self: *Sweep, join: u32, start: u32, parameters: []const ValueId) !bool {
        const function = self.function;
        var visited = try std.DynamicBitSetUnmanaged.initEmpty(function.scratch, function.blocks.items.len);
        var pending: std.ArrayList(u32) = .empty;
        try pending.append(function.scratch, start);
        visited.set(start);
        visited.set(join);
        var uses: ParameterUses = .{ .function = function, .parameters = parameters };
        while (pending.pop()) |block| {
            function_ir.visitBlockReferences(function, &function.blocks.items[block], &uses, ParameterUses.reference);
            if (uses.found) return false;
            for (function.successors(block)) |successor| if (successor) |target| {
                if (visited.isSet(target)) continue;
                visited.set(target);
                try pending.append(function.scratch, target);
            };
        }
        return true;
    }

    fn incomingValue(self: *Sweep, join: function_ir.Block, edge: structures.FunctionBranch, operand: ValueId) ?ValueId {
        const value = self.function.find(operand);
        const position = std.mem.indexOfScalar(ValueId, join.parameters.items, value) orelse return value;
        const argument = self.function.branchArguments(edge)[position];
        if (argument.coerce_to != null) return null;
        return self.function.find(argument.value);
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
        const condition = try function.appendInstruction(block, .{ .compare = .{ .operation = predicate.operation, .operands = predicate.operands } }, span, frame);
        var merged: std.ArrayList(structures.FunctionValueUse) = .empty;
        for (function.branchArguments(then_exit), function.branchArguments(else_exit)) |then_argument, else_argument| {
            const then_value = function.find(then_argument.value);
            const else_value = function.find(else_argument.value);
            try merged.append(function.scratch, .{ .value = if (then_value == else_value) then_value else if (function.constantBool(then_value) == true and function.constantBool(else_value) == false)
                condition
            else
                try function.appendInstruction(block, .{ .select = .{ .condition = condition, .then_value = then_value, .else_value = else_value, .type_id = function.valueType(then_value) } }, span, frame) });
        }
        function.blocks.items[block].terminator = .{ .branch = .{ .target = then_exit.target, .arguments = try function.appendBranchArguments(merged.items) } };
        self.touch(block);
        self.dirty[block] = true;
        return true;
    }

    fn merge(self: *Sweep, block: u32) !bool {
        const function = self.function;
        if (block == function.entry or self.incoming[block].items.len != 1) return false;
        const predecessor = self.incoming[block].items[0].block;
        if (predecessor == block or self.dirty[predecessor]) return false;
        if (function.blocks.items[predecessor].terminator != .branch) return false;
        var current = block;
        var merged = false;
        while (true) {
            const values = function.valueCount();
            if (!try self.absorb(current, predecessor)) break;
            merged = true;
            // Absorbing a block that needed no new values leaves its successor's
            // facts intact, so a chain of single-predecessor blocks merges in one sweep.
            const terminator = function.blocks.items[predecessor].terminator;
            if (terminator != .branch or function.valueCount() != values) break;
            current = @backingInt(terminator.branch.target);
            if (current == predecessor or current == function.entry or self.dirty[current] or self.incoming[current].items.len != 1) break;
        }
        if (merged) self.touch(predecessor);
        return merged;
    }

    fn absorb(self: *Sweep, block: u32, predecessor: u32) !bool {
        const function = self.function;
        const edge = self.incoming[block].items[0];
        std.debug.assert(edge.block == predecessor);
        const arguments = function.branchArguments(edge.branch(function).*);
        if (coerces(arguments)) return false;
        for (function.blocks.items[block].parameters.items, arguments) |parameter, argument| {
            const value = function.find(argument.value);
            const aliases = !function.directParameter(parameter);
            const immutable = function.plainValue(value) and !self.address_taken[@backingInt(value)] and !self.address_taken[@backingInt(parameter)];
            if (aliases or immutable) {
                function.replace(parameter, value);
                continue;
            }
            const source = function.blocks.items[predecessor];
            function.replace(parameter, try function.appendInstruction(predecessor, .{ .value_copy = .{ .source = value, .type_id = function.valueType(parameter) } }, source.span, source.frame));
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
        for (function.successors(predecessor)) |successor| if (successor) |next| {
            for (self.incoming[next].items) |*incoming| if (incoming.block == block) {
                incoming.block = predecessor;
            };
        };
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
            branch.* = .{ .target = exit.target, .arguments = try function.copyBranchArguments(exit.arguments, &.{}) };
            self.touch(edge.block);
            changed = true;
        }
        if (changed) self.dirty[block] = true;
        return changed;
    }
};

const ParameterUses = struct {
    function: *const Function,
    parameters: []const ValueId,
    found: bool = false,

    fn reference(self: *ParameterUses, value: ValueId) void {
        if (std.mem.indexOfScalar(ValueId, self.parameters, self.function.find(value)) != null) self.found = true;
    }
};

fn speculatable(instruction: structures.FunctionInstruction) bool {
    return switch (instruction) {
        .const_int, .const_bool, .const_byte, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select => true,
        else => false,
    };
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
        if (state.foldSameTarget(block) or try state.selectEdgeArguments(block) or try state.threadExit(block) or try state.formSelect(block) or try state.merge(block) or try state.forward(block)) changed = true;
    }
    return changed;
}
