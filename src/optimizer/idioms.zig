const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");
const loops = @import("loops.zig");
const inlining = @import("inline.zig");
const Graph = @import("graph.zig").Graph;

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;
const Loop = loops.Loop;

pub fn transform(function: *Function, context: anytype, callees: *inlining.Cache, bulk_fallbacks: *std.AutoHashMapUnmanaged(u32, void), loop_growth: *usize) !bool {
    var changed = false;
    while (try once(function, context, callees, bulk_fallbacks, loop_growth)) changed = true;
    if (changed) function.resolveReferences();
    return changed;
}

fn once(function: *Function, context: anytype, callees: *inlining.Cache, bulk_fallbacks: *std.AutoHashMapUnmanaged(u32, void), loop_growth: *usize) !bool {
    const found = try loops.canonicalLoops(function);
    function.resolveReferences();
    if (found.len == 0) return false;
    const graph = (try function.controlFlow()).*;
    var analysis = try loops.Analysis.init(function, graph, found);
    analysis.call_arguments = try successfulCallArguments(function, context, callees);
    const scoped = scopeValues(function, &analysis);
    for (found) |loop| {
        const preheader = loops.preheader(function, graph, loop) orelse continue;
        if (loop.latches.len != 1) continue;
        if (try rewriteLoop(function, &analysis, loop, preheader, bulk_fallbacks) or try @import("unswitch.zig").transform(function, &analysis, loop, preheader, loop_growth)) {
            function.invalidateControlFlow();
            return true;
        }
    }
    const guard_changes = guardedValues(function, &analysis);
    if (guard_changes.control_flow) function.invalidateControlFlow();
    // Scoped substitutions are already canonical and change only unaddressed
    // immutable reads. Numeric proofs change policy, not operands or addresses.
    return scoped or guard_changes.changed;
}

fn scopeValues(function: *Function, analysis: *const loops.Analysis) bool {
    for (function.instructions.items, function.removed.items) |instruction, removed| {
        if (!removed and instruction == .select) break;
    } else return false;
    var changed = false;
    for (analysis.graph.order) |block| {
        var scoped: ScopedValues = .{ .function = function, .analysis = analysis, .block = block };
        function_ir.visitBlockOperands(function, &function.blocks.items[block], &scoped, ScopedValues.replace);
        changed = changed or scoped.changed;
    }
    return changed;
}

fn guardedValues(function: *Function, analysis: *const loops.Analysis) function_ir.Changes {
    var changed: function_ir.Changes = .{};
    for (analysis.graph.order) |block| {
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            if (instruction.* != .numeric_binary) continue;
            const operation = &instruction.numeric_binary;
            if (operation.type_id != .int or operation.overflow != .checked) continue;
            if (analysis.arithmeticFitsAt(operation.*, function.results.items[index], block)) {
                operation.overflow = .wrapping;
                changed.changed = true;
            }
        }
        const terminator = &function.blocks.items[block].terminator;
        if (terminator.* != .predicate_branch) continue;
        const predicate = terminator.predicate_branch;
        if (predicate.operation == .eqb or predicate.operation == .neb or predicate.operation == .eqt or predicate.operation == .net) continue;
        const taken = analysis.predicateAt(predicate.operation, predicate.operands, block) orelse continue;
        terminator.* = .{ .branch = if (taken) predicate.then_branch else predicate.else_branch };
        // Removing edges preserves the old graph's dominance facts. Finish
        // this sweep before rebuilding analyses instead of rebuilding per guard.
        changed.changed = true;
        changed.control_flow = true;
    }
    return changed;
}

const ScopedValues = struct {
    function: *Function,
    analysis: *const loops.Analysis,
    block: u32,
    changed: bool = false,

    fn replace(self: *ScopedValues, operand: *ValueId) void {
        const value = self.function.find(operand.*);
        const definition = self.function.definition(value) orelse return;
        if (definition != .select or self.analysis.address_taken[@backingInt(value)]) return;
        const selected = self.analysis.selectedAt(definition.select, self.block) orelse return;
        if (!self.function.plainValue(selected) or self.analysis.address_taken[@backingInt(selected)]) return;
        operand.* = selected;
        self.changed = true;
    }
};

fn successfulCallArguments(function: *Function, context: anytype, callees: *inlining.Cache) ![]const loops.Analysis.CallArgumentRange {
    var ranges: std.ArrayList(loops.Analysis.CallArgumentRange) = .empty;
    const taken = try canonicalize.addressTaken(function);
    for (function.instructions.items, function.removed.items, 0..) |instruction, removed, index| {
        if (removed or instruction != .call or instruction.call.target != .direct) continue;
        const call = instruction.call;
        const arguments = function.call_arguments.items[call.arguments.start..call.arguments.end];
        for (arguments) |argument| {
            const value = function.find(argument.valueId());
            if (function.valueType(value) == .int and function.plainValue(value) and !taken[@backingInt(value)]) break;
        } else continue;
        const body = (try callees.body(function.scratch, context, call.target.direct)) orelse continue;
        const facts = if (@hasDecl(@TypeOf(context), "inlineFacts"))
            (try callees.instanceFacts(function.scratch, context, call.target.direct)) orelse continue
        else
            try callees.analyze(function.scratch, body);
        if (!facts.eligible or facts.normal_return_ranges.len == 0) continue;
        std.debug.assert(facts.normal_return_ranges.len == arguments.len);
        for (arguments, facts.normal_return_ranges) |argument, range| {
            const known = range orelse continue;
            const value = function.find(argument.valueId());
            if (function.valueType(value) != .int or !function.plainValue(value) or taken[@backingInt(value)]) continue;
            try ranges.append(function.scratch, .{ .instruction = @intCast(index), .value = value, .range = known });
        }
    }
    return ranges.items;
}

fn rewriteLoop(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32, bulk_fallbacks: *std.AutoHashMapUnmanaged(u32, void)) !bool {
    if (try rotateCarriedExit(function, analysis.graph, loop)) return true;
    if (removeDeadLoop(function, analysis, loop, preheader)) return true;
    const store = for (function.blocks.items[loop.latches[0]].instructions.items) |index| {
        const instruction = function.instructions.items[index];
        if (!function.removed.items[index] and instruction == .value_copy and instruction.value_copy.destination != null) break index;
    } else null;
    if (store) |index| {
        if (!bulk_fallbacks.contains(index) and (try fill(function, analysis, loop, preheader) or try terminalFill(function, analysis, loop, preheader) or try move(function, analysis, loop, preheader))) {
            try bulk_fallbacks.put(function.scratch, index, {});
            return true;
        }
    }
    return boundsChecks(function, analysis, loop, preheader);
}

const LoopParameters = struct {
    function: *Function,
    from: []const ValueId,
    to: []const ValueId = &.{},
    found: bool = false,

    fn check(self: *LoopParameters, operand: *ValueId) void {
        if (std.mem.indexOfScalar(ValueId, self.from, self.function.find(operand.*)) != null) self.found = true;
    }

    fn replace(self: *LoopParameters, operand: *ValueId) void {
        if (std.mem.indexOfScalar(ValueId, self.from, self.function.find(operand.*))) |position| operand.* = self.to[position];
    }
};

fn selectArm(function: *const Function, value: ValueId, condition: ValueId, taken: bool) ValueId {
    const definition = function.definition(function.find(value)) orelse return value;
    if (definition != .select or function.find(definition.select.condition) != condition) return value;
    return if (taken) definition.select.then_value else definition.select.else_value;
}

fn rotateCarriedExit(function: *Function, graph: Graph, loop: Loop) !bool {
    const header = function.blocks.items[loop.header];
    if (header.instructions.items.len != 0) return false;
    const test_result = loops.exitTestAt(function, loop, loop.header) orelse return false;
    const exit_branch = function.branchTo(loop.header, test_result.exit).?.*;
    const exit_arguments = try function.scratch.dupe(structures.FunctionValueUse, function.branchArguments(exit_branch));
    const compared = function.constantBool(test_result.operands.rhs) orelse return false;
    const exit_value = switch (test_result.operation) {
        .eqb => compared,
        .neb => !compared,
        else => return false,
    };
    const flag = function.find(test_result.operands.lhs);
    const flag_position = std.mem.indexOfScalar(ValueId, header.parameters.items, flag) orelse return false;
    const body = test_result.stay;
    if (function.blocks.items[body].parameters.items.len != 0) return false;
    for (loop.blocks) |block| if (block != loop.header and !graph.dominates(body, block)) return false;
    const latch = loop.latches[0];
    const terminator = function.blocks.items[latch].terminator;
    const back_branch = (function.branchTo(latch, loop.header) orelse return false).*;
    const back = function.branchArguments(back_branch);
    for (back) |argument| if (argument.coerce_to != null or argument.variant_tag_mapping != null) return false;
    const carried = function.definition(function.find(back[flag_position].value)) orelse return false;
    if (carried != .select or function.constantBool(carried.select.then_value) != exit_value or function.find(carried.select.else_value) != flag) return false;
    const condition = function.find(carried.select.condition);
    const taken = try canonicalize.addressTaken(function);
    if (!function.plainValue(condition) or taken[@backingInt(condition)]) return false;
    for (back) |argument| {
        const definition = function.definition(function.find(argument.value)) orelse continue;
        if (definition != .select or function.find(definition.select.condition) != condition) continue;
        for ([_]ValueId{ definition.select.then_value, definition.select.else_value }) |arm| {
            const value = function.find(arm);
            if (!function.plainValue(value) or taken[@backingInt(value)]) return false;
        }
    }
    for (header.parameters.items) |parameter| {
        if (!function.valueType(parameter).isPrimitive() or taken[@backingInt(parameter)]) return false;
    }
    const edges = (try function.controlFlowEdges()).incoming[test_result.exit].items;
    const private_exit = for (edges) |edge| {
        if (!loop.contains(edge.block)) break false;
    } else true;
    for (function.blocks.items, 0..) |*block, index| {
        if (index == loop.header or graph.dominates(body, @intCast(index))) continue;
        if (private_exit and graph.dominates(test_result.exit, @intCast(index))) continue;
        var uses: LoopParameters = .{ .function = function, .from = header.parameters.items };
        function_ir.visitBlockOperands(function, block, &uses, LoopParameters.check);
        if (uses.found) return false;
    }
    if (terminator != .branch) {
        // Only this selected backedge needs the flag decision. Leave the
        // latch's other continuation intact, with no invented phi inputs.
        const split = try function.addBlock(.{ .branch = back_branch }, header.span, header.frame);
        function.branchTo(latch, loop.header).?.* = .{ .target = @fromBackingInt(split), .arguments = .{ .start = 0, .end = 0 } };
        try function.placeAfter(split, latch);
        return true;
    }
    const original = try function.scratch.dupe(ValueId, header.parameters.items);
    const replacements = try function.scratch.alloc(ValueId, original.len);
    const exit_parameters = try function.scratch.alloc(ValueId, if (private_exit) original.len else 0);
    const inactive = try function.insertInstruction(loop.header, 0, .{ .const_bool = !exit_value }, header.span, header.frame);
    var initial: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (original, 0..) |parameter, position| {
        const argument = function.definitions.items[@backingInt(parameter)].argument.data;
        if (private_exit) exit_parameters[position] = try function.addParameter(test_result.exit, argument);
        if (position == flag_position) {
            replacements[position] = inactive;
            continue;
        }
        replacements[position] = try function.addParameter(body, argument);
        try initial.append(function.scratch, .{ .value = parameter });
    }
    const active = carried.select.then_value;
    var escaped: LoopParameters = .{ .function = function, .from = original, .to = exit_parameters };
    if (private_exit) {
        for (function.blocks.items, 0..) |*block, index| {
            if (graph.dominates(test_result.exit, @intCast(index))) function_ir.visitBlockOperands(function, block, &escaped, LoopParameters.replace);
        }
    }
    var rewritten: LoopParameters = .{ .function = function, .from = original, .to = replacements };
    for (function.blocks.items, 0..) |*block, index| {
        if (!graph.dominates(body, @intCast(index))) continue;
        function_ir.visitBlockOperands(function, block, &rewritten, LoopParameters.replace);
        for (block.terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
            if (private_exit and @backingInt(branch.target) == test_result.exit) branch.arguments = try function.copyBranchArguments(branch.arguments, replacements);
        };
    }
    var exiting: std.ArrayList(structures.FunctionValueUse) = .empty;
    var repeating: std.ArrayList(structures.FunctionValueUse) = .empty;
    const next_condition = if (std.mem.indexOfScalar(ValueId, original, condition)) |position| replacements[position] else condition;
    for (function.branchArguments(back_branch), 0..) |argument, position| {
        try exiting.append(function.scratch, .{ .value = if (position == flag_position) active else selectArm(function, argument.value, next_condition, true) });
        if (position != flag_position) try repeating.append(function.scratch, .{ .value = selectArm(function, argument.value, next_condition, false) });
    }
    var collision: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (exit_arguments) |argument| {
        var replacement = argument;
        if (std.mem.indexOfScalar(ValueId, original, function.find(argument.value))) |position| replacement.value = exiting.items[position].value;
        try collision.append(function.scratch, replacement);
    }
    if (private_exit) try collision.appendSlice(function.scratch, exiting.items);
    const initial_arguments = try function.appendBranchArguments(initial.items);
    for (function.blocks.items[loop.header].terminator.branches()) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == body) edge.arguments = initial_arguments;
        if (private_exit and @backingInt(edge.target) == test_result.exit) edge.arguments = try function.copyBranchArguments(edge.arguments, original);
    };
    function.blocks.items[latch].terminator = .{ .predicate_branch = .{
        .operation = .eqb,
        .operands = .{ .lhs = next_condition, .rhs = if (exit_value) active else inactive },
        .then_branch = .{ .target = @fromBackingInt(test_result.exit), .arguments = try function.appendBranchArguments(collision.items) },
        .else_branch = .{ .target = @fromBackingInt(body), .arguments = try function.appendBranchArguments(repeating.items) },
    } };
    return true;
}

fn soleExit(function: *Function, loop: Loop, header_exit: u32) bool {
    for (loop.blocks) |block| for (function.successors(block)) |successor| if (successor) |target| {
        if (!loop.contains(target) and (block != loop.header or target != header_exit)) return false;
    };
    return true;
}

fn removeDeadLoop(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) bool {
    const test_result = loops.exitTest(function, loop) orelse return false;
    if (!soleExit(function, loop, test_result.exit)) return false;
    if (test_result.operation != .eqi) return false;
    var counter: ?loops.InductionExit = null;
    for ([_]ValueId{ test_result.operands.lhs, test_result.operands.rhs }) |candidate| {
        const found = analysis.inductionExit(loop, preheader, test_result, function.find(candidate)) orelse continue;
        if (found.induction.step != 1 and found.induction.step != -1) continue;
        counter = found;
        break;
    }
    const controlled = counter orelse return false;
    var needs_proof = false;
    for (loop.blocks) |block| {
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            if (pure(function, function.instructions.items[index])) continue;
            if (function.results.items[index] != controlled.induction.next) return false;
            needs_proof = true;
        }
        const terminator = function.blocks.items[block].terminator;
        if (terminator != .branch and terminator != .predicate_branch) return false;
    }
    if (!analysis.iterationAcyclic(loop)) return false;
    var escape: Escape = .{ .analysis = analysis, .loop = loop };
    for (function.blocks.items, 0..) |*block, index| {
        if (!loop.contains(@intCast(index))) function_ir.visitBlockOperands(function, block, &escape, Escape.check);
        if (escape.escapes) return false;
    }
    if (needs_proof and !analysis.equalityRecurrenceSafe(preheader, controlled)) return false;
    function.blocks.items[preheader].terminator = .{ .branch = .{ .target = @fromBackingInt(test_result.exit), .arguments = .{ .start = 0, .end = 0 } } };
    return true;
}

const Escape = struct {
    analysis: *const loops.Analysis,
    loop: Loop,
    allowed: []const ValueId = &.{},
    escapes: bool = false,

    fn check(self: *Escape, operand: *ValueId) void {
        if (self.analysis.definedOutside(self.loop, operand.*)) return;
        if (std.mem.indexOfScalar(ValueId, self.allowed, self.analysis.function.find(operand.*)) == null) self.escapes = true;
    }
};

fn pure(function: *const Function, instruction: Instruction) bool {
    return switch (instruction) {
        .numeric_binary, .numeric_unary => !function_ir.numericMayTrap(function, instruction),
        .const_numeric, .numeric_convert, .const_int, .const_bool, .const_byte, .const_unit, .const_none, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select, .variant_tag, .field_access, .borrow_address, .borrow_read, .storage_projection, .allocation_element, .array_element, .cursor_offset, .cursor_element, .function_ref => true,
        .divsi, .shli, .shrsi => |operands| function_ir.validConstantRhs(function, instruction, operands.rhs),
        inline .value_copy, .variant_extract, .variant_coerce => |operation| operation.destination == null,
        else => false,
    };
}

const CountedLoop = struct { parameter: ValueId, next: ValueId, start: ValueId, bound: ValueId, exit: u32 };

/// Matches a two-block loop whose empty header exits when its only parameter,
/// stepping by `step` in the single branch latch, equals a bound.
fn countedLoop(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32, step: i32) ?CountedLoop {
    if (loop.blocks.len != 2) return null;
    const header = &function.blocks.items[loop.header];
    if (header.parameters.items.len != 1) return null;
    for (header.instructions.items) |index| if (!function.removed.items[index]) return null;
    const test_result = loops.exitTest(function, loop) orelse return null;
    if (test_result.operation != .eqi) return null;
    const parameter = header.parameters.items[0];
    const matched = analysis.inductionExit(loop, preheader, test_result, parameter) orelse return null;
    if (matched.induction.step != step) return null;
    const body = test_result.stay;
    if (body != loop.latches[0] or function.blocks.items[body].terminator != .branch) return null;
    return .{ .parameter = parameter, .next = matched.induction.next, .start = matched.induction.start, .bound = matched.comparison.other, .exit = test_result.exit };
}

fn useCount(function: *const Function, block: u32, value: ValueId) u32 {
    var users: Users = .{ .function = function, .value = value };
    for (function.blocks.items[block].instructions.items) |index| {
        if (!function.removed.items[index]) function_ir.visitInstructionReferences(function, &function.instructions.items[index], &users, Users.count);
    }
    return users.count_value;
}

fn fill(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) !bool {
    const counted = countedLoop(function, analysis, loop, preheader, 1) orelse return false;
    const parameter = counted.parameter;
    const bound = counted.bound;
    const body = loop.latches[0];
    const store = fillStore(function, analysis, loop, body, parameter, &.{counted.next}) orelse return false;
    const target = store.target;
    const start = counted.start;
    if (guarded(function, analysis, preheader, start, bound)) return false;
    const span = function.blocks.items[loop.header].span;
    const frame = function.blocks.items[loop.header].frame;
    const filled = try guard(function, preheader, start, bound, counted.exit, span, frame);
    const count = try function.insertInstruction(filled, 0, .{ .subi = .{ .lhs = bound, .rhs = start } }, span, frame);
    const first = try function.insertInstruction(filled, 1, .{ .allocation_element = .{ .allocation = target.allocation, .index = start, .type_id = target.type_id } }, span, frame);
    _ = try function.insertInstruction(filled, 2, .{ .fill = .{ .first = first, .count = count, .value = store.value, .type_id = target.type_id } }, span, frame);

    replaceOutside(function, loop, parameter, bound);
    return true;
}

const FillStore = struct { target: structures.AllocationElement, value: ValueId };

fn fillStore(function: *Function, analysis: *const loops.Analysis, loop: Loop, body: u32, parameter: ValueId, updates: []const ValueId) ?FillStore {
    var element: ?structures.AllocationElement = null;
    var element_value: ?ValueId = null;
    var stored: ?structures.ValueCopy = null;
    for (function.blocks.items[body].instructions.items) |index| {
        if (function.removed.items[index]) continue;
        switch (function.instructions.items[index]) {
            .const_numeric, .const_int, .const_bool, .const_byte => {},
            .numeric_binary => |operation| {
                if (operation.type_id != .int or operation.operation != .add or operation.overflow == .saturating) return null;
                if (std.mem.indexOfScalar(ValueId, updates, function.results.items[index]) == null) return null;
            },
            .addi => if (std.mem.indexOfScalar(ValueId, updates, function.results.items[index]) == null) return null,
            .allocation_element => |operation| {
                if (element != null or function.find(operation.index) != parameter) return null;
                element = operation;
                element_value = function.results.items[index];
            },
            .value_copy => |copy| {
                if (stored != null or copy.destination == null) return null;
                stored = copy;
            },
            else => return null,
        }
    }
    const target = element orelse return null;
    const store = stored orelse return null;
    if (function.find(store.destination.?) != element_value.? or store.type_id != target.type_id) return null;
    if (target.type_id != .int and target.type_id != .bool and target.type_id != .byte) return null;
    if (!analysis.definedOutside(loop, target.allocation) or !analysis.definedOutside(loop, store.source)) return null;
    if (useCount(function, body, element_value.?) != 1) return null;

    return .{ .target = target, .value = store.source };
}

/// A terminal equality test includes the current element. Other header
/// parameters may independently count initialized elements with modular +1.
fn terminalFill(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) !bool {
    if (loop.blocks.len != 1) return false;
    const ending = loops.exitTestAt(function, loop, loop.header) orelse return false;
    if (ending.operation != .eqi) return false;
    const parameters = function.blocks.items[loop.header].parameters.items;
    const counter = for (parameters) |parameter| {
        const matched = analysis.inductionExit(loop, preheader, ending, parameter) orelse continue;
        if (matched.induction.step == 1) break matched;
    } else return false;
    const entering = function.blocks.items[preheader].terminator.branch;
    const initial = try function.scratch.dupe(structures.FunctionValueUse, function.branchArguments(entering));
    const back = function.branchArguments(function.branchTo(loop.header, loop.header).?.*);
    const updates = try function.scratch.alloc(ValueId, parameters.len);
    for (parameters, back, initial, updates) |parameter, argument, first, *update| {
        if (!function.plainValue(parameter) or analysis.address_taken[@backingInt(parameter)]) return false;
        if (argument.coerce_to != null or argument.variant_tag_mapping != null) return false;
        if (first.coerce_to != null or first.variant_tag_mapping != null) return false;
        update.* = function.find(argument.value);
        const definition = function.definition(update.*) orelse return false;
        // Checked updates remain until range analysis proves them safe. Never
        // replace an intermediate panic with a bulk write and a final panic.
        if (definition != .addi) return false;
        const operands = definition.addi;
        const one = if (function.find(operands.lhs) == parameter) operands.rhs else if (function.find(operands.rhs) == parameter) operands.lhs else return false;
        if (analysis.integerConstant(one) != 1) return false;
    }
    const store = fillStore(function, analysis, loop, loop.header, counter.induction.parameter, updates) orelse return false;
    const original = try function.scratch.alloc(ValueId, parameters.len * 2);
    for (parameters, updates, 0..) |parameter, update, position| {
        original[position * 2] = parameter;
        original[position * 2 + 1] = update;
    }
    var escape: Escape = .{ .analysis = analysis, .loop = loop, .allowed = original };
    for (function.blocks.items, 0..) |*block, index| {
        if (loop.contains(@intCast(index))) continue;
        function_ir.visitBlockOperands(function, block, &escape, Escape.check);
        if (escape.escapes) return false;
        var uses: LoopParameters = .{ .function = function, .from = original };
        function_ir.visitBlockOperands(function, block, &uses, LoopParameters.check);
        if (uses.found and !analysis.graph.dominates(ending.exit, @intCast(index))) return false;
    }
    const exit_branch = function.branchTo(loop.header, ending.exit).?.*;
    const arguments = try function.scratch.dupe(structures.FunctionValueUse, function.branchArguments(exit_branch));
    for (arguments) |argument| {
        const value = function.find(argument.value);
        if (!analysis.definedOutside(loop, value) and std.mem.indexOfScalar(ValueId, parameters, value) == null and std.mem.indexOfScalar(ValueId, updates, value) == null) return false;
    }
    const start = counter.induction.start;
    const bound = counter.comparison.other;
    const start_range = analysis.rangeAt(start, preheader, 16);
    const bound_range = analysis.rangeAt(bound, preheader, 16);
    const span = function.blocks.items[loop.header].span;
    const frame = function.blocks.items[loop.header].frame;
    // Merge the slow and bulk exit states, including values used directly
    // beyond the loop rather than already carried by explicit exit arguments.
    const merged = try function.addBlock(.{ .branch = .{ .target = exit_branch.target, .arguments = try function.appendBranchArguments(arguments) } }, span, frame);
    const replacements = try function.scratch.alloc(ValueId, original.len);
    var slow: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (original, replacements) |value, *replacement| {
        replacement.* = try function.addParameter(merged, .{ .type_id = .int });
        try slow.append(function.scratch, .{ .value = value });
    }
    function.branchTo(loop.header, ending.exit).?.* = .{ .target = @fromBackingInt(merged), .arguments = try function.appendBranchArguments(slow.items) };
    var outside: LoopParameters = .{ .function = function, .from = original, .to = replacements };
    for (function.blocks.items, 0..) |*block, index| {
        if (!loop.contains(@intCast(index))) function_ir.visitBlockOperands(function, block, &outside, LoopParameters.replace);
    }
    try function.placeAfter(merged, loop.header);
    const ordered = try guard(function, preheader, start, bound, merged, span, frame);
    if (start_range.lower >= 0 and start_range.upper <= bound_range.lower) {
        function.blocks.items[preheader].terminator = .{ .branch = .{ .target = @fromBackingInt(ordered), .arguments = .{ .start = 0, .end = 0 } } };
    }
    const distance = try function.appendInstruction(ordered, .{ .subi = .{ .lhs = bound, .rhs = start } }, span, frame);
    const filled = try function.addBlock(.diverge, span, frame);
    try function.placeAfter(filled, ordered);
    const next: structures.FunctionBranch = .{ .target = @fromBackingInt(filled), .arguments = .{ .start = 0, .end = 0 } };
    if (bound_range.upper - start_range.lower < std.math.maxInt(i32)) {
        function.blocks.items[ordered].terminator = .{ .branch = next };
    } else {
        const maximum = try function.appendInstruction(ordered, .{ .const_int = std.math.maxInt(i32) }, span, frame);
        function.blocks.items[ordered].terminator = .{ .predicate_branch = .{
            .operation = .lti,
            .operands = .{ .lhs = distance, .rhs = maximum },
            .then_branch = next,
            .else_branch = .{ .target = entering.target, .arguments = try function.copyBranchArguments(entering.arguments, &.{}) },
        } };
    }
    const one = try function.appendInstruction(filled, .{ .const_int = 1 }, span, frame);
    const count = try function.appendInstruction(filled, .{ .addi = .{ .lhs = distance, .rhs = one } }, span, frame);
    const first = try function.appendInstruction(filled, .{ .allocation_element = .{ .allocation = store.target.allocation, .index = start, .type_id = store.target.type_id } }, span, frame);
    _ = try function.appendInstruction(filled, .{ .fill = .{ .first = first, .count = count, .value = store.value, .type_id = store.target.type_id } }, span, frame);
    var fast: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (initial) |initial_value| {
        const final_next = try function.appendInstruction(filled, .{ .addi = .{ .lhs = initial_value.value, .rhs = count } }, span, frame);
        const final_current = try function.appendInstruction(filled, .{ .subi = .{ .lhs = final_next, .rhs = one } }, span, frame);
        try fast.appendSlice(function.scratch, &.{ .{ .value = final_current }, .{ .value = final_next } });
    }
    function.blocks.items[filled].terminator = .{ .branch = .{ .target = @fromBackingInt(merged), .arguments = try function.appendBranchArguments(fast.items) } };
    return true;
}

fn replaceOutside(function: *Function, loop: Loop, parameter: ValueId, bound: ValueId) void {
    var outside: Replace = .{ .from = parameter, .to = bound };
    for (function.blocks.items, 0..) |*block, index| {
        if (!loop.contains(@intCast(index))) function_ir.visitBlockOperands(function, block, &outside, Replace.apply);
    }
}

fn guard(function: *Function, preheader: u32, low: ValueId, high: ValueId, exit: u32, span: structures.SourceSpan, frame: structures.InlineFrameId) !u32 {
    const enter = function.blocks.items[preheader].terminator.branch;
    const block = try function.addBlock(.{ .branch = .{ .target = @fromBackingInt(exit), .arguments = .{ .start = 0, .end = 0 } } }, span, frame);
    const ordered = try function.addBlock(.{ .predicate_branch = .{
        .operation = .lei,
        .operands = .{ .lhs = low, .rhs = high },
        .then_branch = .{ .target = @fromBackingInt(block), .arguments = .{ .start = 0, .end = 0 } },
        .else_branch = .{ .target = enter.target, .arguments = try function.copyBranchArguments(enter.arguments, &.{}) },
    } }, span, frame);
    const zero = try function.appendInstruction(preheader, .{ .const_int = 0 }, span, frame);
    function.blocks.items[preheader].terminator = .{ .predicate_branch = .{
        .operation = .gei,
        .operands = .{ .lhs = low, .rhs = zero },
        .then_branch = .{ .target = @fromBackingInt(ordered), .arguments = .{ .start = 0, .end = 0 } },
        .else_branch = .{ .target = enter.target, .arguments = try function.copyBranchArguments(enter.arguments, &.{}) },
    } };
    try function.placeAfter(ordered, preheader);
    try function.placeAfter(block, ordered);
    return block;
}

fn move(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) !bool {
    const counted = countedLoop(function, analysis, loop, preheader, -1) orelse return false;
    const body = loop.latches[0];
    const next = function.find(function.branchArguments(function.blocks.items[body].terminator.branch)[0].value);
    var source: ?structures.AllocationElement = null;
    var source_value: ?ValueId = null;
    var destination: ?structures.AllocationElement = null;
    var destination_value: ?ValueId = null;
    var loaded: ?ValueId = null;
    var stored: ?structures.ValueCopy = null;
    for (function.blocks.items[body].instructions.items) |index| {
        if (function.removed.items[index]) continue;
        const result = function.results.items[index];
        switch (function.instructions.items[index]) {
            .const_int => {},
            .addi, .subi => if (result != next) return false,
            .allocation_element => |operation| {
                if (function.find(operation.index) != next) return false;
                if (source == null) {
                    source = operation;
                    source_value = result;
                } else if (destination == null) {
                    destination = operation;
                    destination_value = result;
                } else return false;
            },
            .value_copy => |copy| if (copy.destination == null) {
                if (loaded != null or function.find(copy.source) != source_value) return false;
                loaded = result;
            } else {
                if (stored != null) return false;
                stored = copy;
            },
            else => return false,
        }
    }
    const from = source orelse return false;
    const to = destination orelse return false;
    const store = stored orelse return false;
    if (loaded == null or function.find(store.source) != loaded.? or function.find(store.destination.?) != destination_value.?) return false;
    if (from.type_id != to.type_id or store.type_id != to.type_id) return false;
    if (!analysis.definedOutside(loop, from.allocation) or !analysis.definedOutside(loop, to.allocation)) return false;
    if (useCount(function, body, source_value.?) != 1 or useCount(function, body, destination_value.?) != 1) return false;

    const bound = counted.bound;
    if (guarded(function, analysis, preheader, bound, counted.start)) return false;
    const span = function.blocks.items[loop.header].span;
    const frame = function.blocks.items[loop.header].frame;
    const moved = try guard(function, preheader, bound, counted.start, counted.exit, span, frame);
    const count = try function.insertInstruction(moved, 0, .{ .subi = .{ .lhs = counted.start, .rhs = bound } }, span, frame);
    const first_destination = try function.insertInstruction(moved, 1, .{ .allocation_element = .{ .allocation = to.allocation, .index = bound, .type_id = to.type_id } }, span, frame);
    const first_source = try function.insertInstruction(moved, 2, .{ .allocation_element = .{ .allocation = from.allocation, .index = bound, .type_id = from.type_id } }, span, frame);
    _ = try function.insertInstruction(moved, 3, .{ .move = .{ .destination = first_destination, .source = first_source, .count = count, .type_id = to.type_id, .backward = true } }, span, frame);
    replaceOutside(function, loop, counted.parameter, bound);
    return true;
}

fn guarded(function: *Function, analysis: *const loops.Analysis, preheader: u32, low: ValueId, high: ValueId) bool {
    var block = preheader;
    var lower = low;
    var upper = high;
    for (0..4) |_| {
        const incoming = analysis.graph.incoming[block].items;
        for (incoming) |edge| {
            const terminator = function.blocks.items[edge.block].terminator;
            if (terminator != .predicate_branch) continue;
            const predicate = terminator.predicate_branch;
            if (@backingInt(predicate.else_branch.target) != block) continue;
            const entered = through(function, block, edge, lower);
            const lhs = function.find(predicate.operands.lhs);
            const rhs = function.find(predicate.operands.rhs);
            if (predicate.operation == .gei and lhs == entered and analysis.integerConstant(rhs) == 0) return true;
            if (predicate.operation == .lei and lhs == entered and rhs == through(function, block, edge, upper)) return true;
        }
        if (incoming.len != 1) return false;
        lower = through(function, block, incoming[0], lower);
        upper = through(function, block, incoming[0], upper);
        block = incoming[0].block;
    }
    return false;
}

fn through(function: *Function, block: u32, edge: @import("graph.zig").Incoming, value: ValueId) ValueId {
    const branch = edge.branch(function);
    const position = std.mem.indexOfScalar(ValueId, function.blocks.items[block].parameters.items, value) orelse return value;
    return function.find(function.branchArguments(branch.*)[position].value);
}

const Users = struct {
    function: *const Function,
    value: ValueId,
    count_value: u32 = 0,

    fn count(self: *Users, operand: ValueId) void {
        if (self.function.find(operand) == self.value) self.count_value += 1;
    }
};

const Replace = struct {
    from: ValueId,
    to: ValueId,

    fn apply(self: *Replace, operand: *ValueId) void {
        if (operand.* == self.from) operand.* = self.to;
    }
};

fn boundsChecks(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) bool {
    for (function.blocks.items[loop.header].parameters.items) |parameter| {
        for (loop.blocks) |block| {
            const test_result = loops.exitTestAt(function, loop, block) orelse continue;
            const counter = analysis.invariantInductionExit(loop, preheader, test_result, parameter) orelse continue;
            if (boundsForCounter(function, analysis, loop, preheader, counter, test_result)) return true;
        }
    }
    return false;
}

fn boundsForCounter(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32, counter: loops.InductionExit, test_result: loops.ExitTest) bool {
    var changed = false;
    const limit = counter.comparison.other;
    // A stay block reachable around the test (a bottom-tested loop's header) runs
    // its first iteration before the counter is tested, so the range holds only
    // for terminal counters, whose proof does not assume the test passed.
    if (counter.induction.terminal_bound == null and analysis.graph.incoming[test_result.stay].items.len != 1) return false;
    for (loop.blocks) |block| {
        if (!analysis.graph.dominates(test_result.stay, block)) continue;
        const range = analysis.iterationRange(block, counter, 16) orelse continue;
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            const instruction = &function.instructions.items[index];
            if (function.results.items[index] != counter.induction.next) {
                if (instruction.* == .numeric_binary and analysis.shiftFits(loop, preheader, counter, range.absolute, instruction.numeric_binary)) {
                    instruction.numeric_binary.overflow = .wrapping;
                    changed = true;
                }
                continue;
            }
            if (instruction.* == .numeric_binary and instruction.numeric_binary.overflow == .checked) {
                instruction.numeric_binary.overflow = .wrapping;
                changed = true;
            }
        }
        const terminator = &function.blocks.items[block].terminator;
        if (terminator.* != .predicate_branch) continue;
        const predicate = terminator.predicate_branch;
        const comparison = loops.IntegerComparison.init(function, predicate.operation, predicate.operands, counter.induction.parameter) orelse continue;
        const holds = if (analysis.integerConstant(comparison.other)) |number|
            range.absolute.known(comparison.operation, number)
        else if (comparison.other == limit)
            range.relative.known(comparison.operation, 0)
        else
            null;
        if (holds) |taken| {
            terminator.* = .{ .branch = if (taken) predicate.then_branch else predicate.else_branch };
            return true;
        }
    }
    return changed;
}
