const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");
const loops = @import("loops.zig");
const Graph = @import("graph.zig").Graph;

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;
const Loop = loops.Loop;

pub fn transform(function: *Function, context: anytype) !bool {
    var changed = false;
    var filled: std.AutoHashMapUnmanaged(u32, void) = .empty;
    while (try once(function, context, &filled)) changed = true;
    if (changed) function.resolveReferences();
    return changed;
}

fn once(function: *Function, context: anytype, filled: *std.AutoHashMapUnmanaged(u32, void)) !bool {
    while (try loops.canonicalize(function)) {}
    function.resolveReferences();
    const graph = (try function.controlFlow()).*;
    const found = try loops.find(function.scratch, function, graph);
    if (found.len == 0) return false;
    var analysis = try loops.Analysis.init(function, graph, found);
    analysis.call_arguments = try successfulCallArguments(function, context);
    for (found) |loop| {
        const preheader = loops.preheader(function, graph, loop) orelse continue;
        if (loop.latches.len != 1) continue;
        if (try rewriteLoop(function, &analysis, loop, preheader, filled)) {
            function.invalidateControlFlow();
            return true;
        }
    }
    return false;
}

fn successfulCallArguments(function: *Function, context: anytype) ![]const loops.Analysis.CallArgumentRange {
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
        const body = (try context.inlineBody(call.target.direct)) orelse continue;
        const facts = if (@hasDecl(@TypeOf(context), "inlineFacts"))
            (try context.inlineFacts(call.target.direct)) orelse continue
        else
            try @import("inline.zig").analyzeCallee(function.scratch, body);
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

fn rewriteLoop(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32, filled: *std.AutoHashMapUnmanaged(u32, void)) !bool {
    if (try rotateCarriedExit(function, analysis.graph, loop)) return true;
    if (removeDeadLoop(function, analysis, loop, preheader)) return true;
    if (!filled.contains(loop.latches[0]) and (try fill(function, analysis, loop, preheader) or try move(function, analysis, loop, preheader))) {
        try filled.put(function.scratch, loop.latches[0], {});
        return true;
    }
    return boundsChecks(function, analysis, loop, preheader);
}

fn boolean(function: *const Function, value: ValueId) ?bool {
    const definition = function.definition(function.find(value)) orelse return null;
    return if (definition == .const_bool) definition.const_bool else null;
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
    const test_result = loops.exitTestWithArguments(function, loop) orelse return false;
    const exit_branch = for (Function.edges(&function.blocks.items[loop.header].terminator)) |maybe_edge| {
        if (maybe_edge) |edge| if (@backingInt(edge.target) == test_result.exit) break edge.*;
    } else unreachable;
    const exit_arguments = try function.scratch.dupe(structures.FunctionValueUse, function.branchArguments(exit_branch));
    const compared = boolean(function, test_result.operands.rhs) orelse return false;
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
    if (terminator != .branch or @backingInt(terminator.branch.target) != loop.header) return false;
    const back = function.branchArguments(terminator.branch);
    for (back) |argument| if (argument.coerce_to != null or argument.variant_tag_mapping != null) return false;
    const carried = function.definition(function.find(back[flag_position].value)) orelse return false;
    if (carried != .select or boolean(function, carried.select.then_value) != exit_value or function.find(carried.select.else_value) != flag) return false;
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
    for (edges) |edge| if (!loop.contains(edge.block)) return false;
    for (function.blocks.items, 0..) |*block, index| {
        if (index == loop.header or graph.dominates(body, @intCast(index)) or graph.dominates(test_result.exit, @intCast(index))) continue;
        var uses: LoopParameters = .{ .function = function, .from = header.parameters.items };
        for (block.instructions.items) |instruction| {
            if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &uses, LoopParameters.check);
        }
        function_ir.terminatorAllOperands(function, &block.terminator, &uses, LoopParameters.check);
        if (uses.found) return false;
    }
    const original = try function.scratch.dupe(ValueId, header.parameters.items);
    const replacements = try function.scratch.alloc(ValueId, original.len);
    const exit_parameters = try function.scratch.alloc(ValueId, original.len);
    const inactive = try function.insertInstruction(loop.header, 0, .{ .const_bool = !exit_value }, header.span, header.frame);
    var initial: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (original, 0..) |parameter, position| {
        const argument = function.definitions.items[@backingInt(parameter)].argument.data;
        exit_parameters[position] = try function.addParameter(test_result.exit, argument);
        if (position == flag_position) {
            replacements[position] = inactive;
            continue;
        }
        replacements[position] = try function.addParameter(body, argument);
        try initial.append(function.scratch, .{ .value = parameter });
    }
    const active = carried.select.then_value;
    var escaped: LoopParameters = .{ .function = function, .from = original, .to = exit_parameters };
    for (function.blocks.items, 0..) |*block, index| {
        if (!graph.dominates(test_result.exit, @intCast(index))) continue;
        for (block.instructions.items) |instruction| {
            if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &escaped, LoopParameters.replace);
        }
        function_ir.terminatorAllOperands(function, &block.terminator, &escaped, LoopParameters.replace);
    }
    var rewritten: LoopParameters = .{ .function = function, .from = original, .to = replacements };
    for (function.blocks.items, 0..) |*block, index| {
        if (!graph.dominates(body, @intCast(index))) continue;
        for (block.instructions.items) |instruction| {
            if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &rewritten, LoopParameters.replace);
        }
        function_ir.terminatorAllOperands(function, &block.terminator, &rewritten, LoopParameters.replace);
        for (Function.edges(&block.terminator)) |maybe_branch| if (maybe_branch) |branch| {
            if (@backingInt(branch.target) == test_result.exit) try appendExitValues(function, branch, replacements);
        };
    }
    var exiting: std.ArrayList(structures.FunctionValueUse) = .empty;
    var repeating: std.ArrayList(structures.FunctionValueUse) = .empty;
    const next_condition = if (std.mem.indexOfScalar(ValueId, original, condition)) |position| replacements[position] else condition;
    for (function.branchArguments(terminator.branch), 0..) |argument, position| {
        try exiting.append(function.scratch, .{ .value = if (position == flag_position) active else selectArm(function, argument.value, next_condition, true) });
        if (position != flag_position) try repeating.append(function.scratch, .{ .value = selectArm(function, argument.value, next_condition, false) });
    }
    var collision: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (exit_arguments) |argument| {
        var replacement = argument;
        if (std.mem.indexOfScalar(ValueId, original, function.find(argument.value))) |position| replacement.value = exiting.items[position].value;
        try collision.append(function.scratch, replacement);
    }
    try collision.appendSlice(function.scratch, exiting.items);
    const initial_arguments = try function.appendBranchArguments(initial.items);
    for (Function.edges(&function.blocks.items[loop.header].terminator)) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == body) edge.arguments = initial_arguments;
        if (@backingInt(edge.target) == test_result.exit) try appendExitValues(function, edge, original);
    };
    function.blocks.items[latch].terminator = .{ .predicate_branch = .{
        .operation = .eqb,
        .operands = .{ .lhs = next_condition, .rhs = if (exit_value) active else inactive },
        .then_branch = .{ .target = @fromBackingInt(test_result.exit), .arguments = try function.appendBranchArguments(collision.items) },
        .else_branch = .{ .target = @fromBackingInt(body), .arguments = try function.appendBranchArguments(repeating.items) },
    } };
    return true;
}

fn appendExitValues(function: *Function, branch: *structures.FunctionBranch, values: []const ValueId) !void {
    var arguments: std.ArrayList(structures.FunctionValueUse) = .empty;
    try arguments.appendSlice(function.scratch, function.branchArguments(branch.*));
    for (values) |value| try arguments.append(function.scratch, .{ .value = value });
    branch.arguments = try function.appendBranchArguments(arguments.items);
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
        if (loop.contains(@intCast(index))) continue;
        for (block.instructions.items) |instruction| if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &escape, Escape.check);
        function_ir.terminatorAllOperands(function, &block.terminator, &escape, Escape.check);
    }
    if (escape.escapes) return false;
    if (needs_proof and !analysis.equalityRecurrenceSafe(preheader, controlled)) return false;
    function.blocks.items[preheader].terminator = .{ .branch = .{ .target = @fromBackingInt(test_result.exit), .arguments = .{ .start = 0, .end = 0 } } };
    return true;
}

const Escape = struct {
    analysis: *const loops.Analysis,
    loop: Loop,
    escapes: bool = false,

    fn check(self: *Escape, operand: *ValueId) void {
        if (!self.analysis.definedOutside(self.loop, operand.*)) self.escapes = true;
    }
};

fn pure(function: *const Function, instruction: Instruction) bool {
    return switch (instruction) {
        .numeric_binary, .numeric_unary => !instruction.numericMayTrap(),
        .const_numeric, .numeric_convert, .const_int, .const_bool, .const_byte, .const_unit, .const_none, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select, .variant_tag, .field_access, .borrow_address, .borrow_read, .storage_projection, .allocation_element, .array_element, .cursor_offset, .cursor_element, .function_ref => true,
        .divsi, .shli, .shrsi => |operands| if (function.definition(operands.rhs)) |rhs| rhs == .const_int and instruction.integerRhsIsValid(rhs.const_int) else false,
        inline .value_copy, .variant_extract, .variant_coerce => |operation| operation.destination == null,
        else => false,
    };
}

fn fill(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) !bool {
    if (loop.blocks.len != 2) return false;
    const header = &function.blocks.items[loop.header];
    if (header.parameters.items.len != 1) return false;
    for (header.instructions.items) |index| if (!function.removed.items[index]) return false;
    const test_result = loops.exitTest(function, loop) orelse return false;
    if (test_result.operation != .eqi) return false;
    const parameter = header.parameters.items[0];
    const matched = analysis.inductionExit(loop, preheader, test_result, parameter) orelse return false;
    const counter = matched.induction;
    if (counter.step != 1) return false;
    const bound = matched.comparison.other;
    const body = test_result.stay;
    if (body != loop.latches[0] or function.blocks.items[body].terminator != .branch) return false;
    var element: ?structures.AllocationElement = null;
    var element_value: ?ValueId = null;
    var stored: ?structures.ValueCopy = null;
    for (function.blocks.items[body].instructions.items) |index| {
        if (function.removed.items[index]) continue;
        switch (function.instructions.items[index]) {
            .const_numeric, .const_int, .const_bool, .const_byte => {},
            .numeric_binary => |operation| {
                if (operation.type_id != .int or operation.operation != .add or operation.overflow == .saturating) return false;
                if (function.find(operation.operands.lhs) != parameter and function.find(operation.operands.rhs) != parameter) return false;
            },
            .addi => |operands| if (function.find(operands.lhs) != parameter and function.find(operands.rhs) != parameter) return false,
            .allocation_element => |operation| {
                if (element != null or function.find(operation.index) != parameter) return false;
                element = operation;
                element_value = function.results.items[index];
            },
            .value_copy => |copy| {
                if (stored != null or copy.destination == null) return false;
                stored = copy;
            },
            else => return false,
        }
    }
    const target = element orelse return false;
    const store = stored orelse return false;
    if (function.find(store.destination.?) != element_value.? or store.type_id != target.type_id) return false;
    if (target.type_id != .int and target.type_id != .bool and target.type_id != .byte) return false;
    if (!analysis.definedOutside(loop, target.allocation) or !analysis.definedOutside(loop, store.source)) return false;
    var users: Users = .{ .function = function, .value = element_value.? };
    for (function.blocks.items[body].instructions.items) |index| if (!function.removed.items[index]) function_ir.allOperands(function, &function.instructions.items[index], &users, Users.count);
    if (users.count_value != 1) return false;

    if (guarded(function, analysis, preheader, counter.start, bound)) return false;
    const span = header.span;
    const frame = header.frame;
    const start = counter.start;
    const filled = try guard(function, preheader, start, bound, test_result.exit, span, frame);
    const count = try function.insertInstruction(filled, 0, .{ .subi = .{ .lhs = bound, .rhs = start } }, span, frame);
    const first = try function.insertInstruction(filled, 1, .{ .allocation_element = .{ .allocation = target.allocation, .index = start, .type_id = target.type_id } }, span, frame);
    _ = try function.insertInstruction(filled, 2, .{ .fill = .{ .first = first, .count = count, .value = store.source, .type_id = target.type_id } }, span, frame);

    replaceOutside(function, loop, parameter, bound);
    return true;
}

fn replaceOutside(function: *Function, loop: Loop, parameter: ValueId, bound: ValueId) void {
    var outside: Replace = .{ .from = parameter, .to = bound };
    for (function.blocks.items, 0..) |*block, index| {
        if (loop.contains(@intCast(index))) continue;
        for (block.instructions.items) |instruction| if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &outside, Replace.apply);
        function_ir.terminatorAllOperands(function, &block.terminator, &outside, Replace.apply);
    }
}

fn guard(function: *Function, preheader: u32, low: ValueId, high: ValueId, exit: u32, span: structures.SourceSpan, frame: structures.InlineFrameId) !u32 {
    const enter = function.blocks.items[preheader].terminator.branch;
    const block = try function.addBlock(.{ .branch = .{ .target = @fromBackingInt(exit), .arguments = .{ .start = 0, .end = 0 } } }, span, frame);
    const ordered = try function.addBlock(.{ .predicate_branch = .{
        .operation = .lei,
        .operands = .{ .lhs = low, .rhs = high },
        .then_branch = .{ .target = @fromBackingInt(block), .arguments = .{ .start = 0, .end = 0 } },
        .else_branch = .{ .target = enter.target, .arguments = try function.copyBranchArguments(enter.arguments) },
    } }, span, frame);
    const zero = try function.insertInstruction(preheader, function.blocks.items[preheader].instructions.items.len, .{ .const_int = 0 }, span, frame);
    function.blocks.items[preheader].terminator = .{ .predicate_branch = .{
        .operation = .gei,
        .operands = .{ .lhs = low, .rhs = zero },
        .then_branch = .{ .target = @fromBackingInt(ordered), .arguments = .{ .start = 0, .end = 0 } },
        .else_branch = .{ .target = enter.target, .arguments = try function.copyBranchArguments(enter.arguments) },
    } };
    try function.placeAfter(ordered, preheader);
    try function.placeAfter(block, ordered);
    return block;
}

fn move(function: *Function, analysis: *const loops.Analysis, loop: Loop, preheader: u32) !bool {
    if (loop.blocks.len != 2) return false;
    const header = &function.blocks.items[loop.header];
    if (header.parameters.items.len != 1) return false;
    for (header.instructions.items) |index| if (!function.removed.items[index]) return false;
    const test_result = loops.exitTest(function, loop) orelse return false;
    if (test_result.operation != .eqi) return false;
    const parameter = header.parameters.items[0];
    const matched = analysis.inductionExit(loop, preheader, test_result, parameter) orelse return false;
    const counter = matched.induction;
    if (counter.step != -1) return false;
    const bound = matched.comparison.other;
    const body = test_result.stay;
    if (body != loop.latches[0] or function.blocks.items[body].terminator != .branch) return false;
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
    var users: Users = .{ .function = function, .value = source_value.? };
    for (function.blocks.items[body].instructions.items) |index| if (!function.removed.items[index]) function_ir.allOperands(function, &function.instructions.items[index], &users, Users.count);
    if (users.count_value != 1) return false;
    users = .{ .function = function, .value = destination_value.? };
    for (function.blocks.items[body].instructions.items) |index| if (!function.removed.items[index]) function_ir.allOperands(function, &function.instructions.items[index], &users, Users.count);
    if (users.count_value != 1) return false;

    if (guarded(function, analysis, preheader, bound, counter.start)) return false;
    const span = header.span;
    const frame = header.frame;
    const moved = try guard(function, preheader, bound, counter.start, test_result.exit, span, frame);
    const count = try function.insertInstruction(moved, 0, .{ .subi = .{ .lhs = counter.start, .rhs = bound } }, span, frame);
    const first_destination = try function.insertInstruction(moved, 1, .{ .allocation_element = .{ .allocation = to.allocation, .index = bound, .type_id = to.type_id } }, span, frame);
    const first_source = try function.insertInstruction(moved, 2, .{ .allocation_element = .{ .allocation = from.allocation, .index = bound, .type_id = from.type_id } }, span, frame);
    _ = try function.insertInstruction(moved, 3, .{ .move = .{ .destination = first_destination, .source = first_source, .count = count, .type_id = to.type_id, .backward = true } }, span, frame);
    replaceOutside(function, loop, parameter, bound);
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
    function: *Function,
    value: ValueId,
    count_value: u32 = 0,

    fn count(self: *Users, operand: *ValueId) void {
        if (self.function.find(operand.*) == self.value) self.count_value += 1;
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
            if (boundsForCounter(function, analysis, loop, counter, test_result)) return true;
        }
    }
    return false;
}

fn boundsForCounter(function: *Function, analysis: *const loops.Analysis, loop: Loop, counter: loops.InductionExit, test_result: loops.ExitTest) bool {
    var changed = false;
    const limit = counter.comparison.other;
    for (loop.blocks) |block| {
        if (!analysis.graph.dominates(test_result.stay, block)) continue;
        const range = analysis.iterationRange(block, counter) orelse continue;
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index] or function.results.items[index] != counter.induction.next) continue;
            const instruction = &function.instructions.items[index];
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
