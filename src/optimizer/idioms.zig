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

pub fn transform(function: *Function) !bool {
    var changed = false;
    var filled: std.AutoHashMapUnmanaged(u32, void) = .empty;
    while (try once(function, &filled)) changed = true;
    if (changed) function.resolveReferences();
    return changed;
}

fn once(function: *Function, filled: *std.AutoHashMapUnmanaged(u32, void)) !bool {
    while (try loops.canonicalize(function)) {}
    function.resolveReferences();
    const graph = (try function.controlFlow()).*;
    const found = try loops.find(function.scratch, function, graph);
    for (found) |loop| {
        const preheader = loops.preheader(function, graph, loop) orelse continue;
        if (loop.latches.len != 1) continue;
        if (try rotateCarriedExit(function, graph, loop)) {
            function.invalidateControlFlow();
            return true;
        }
        if (try removeDeadLoop(function, graph, loop, preheader)) {
            function.invalidateControlFlow();
            return true;
        }
        if (!filled.contains(loop.latches[0]) and (try fill(function, graph, loop, preheader) or try move(function, graph, loop, preheader))) {
            try filled.put(function.scratch, loop.latches[0], {});
            return true;
        }
        if (try boundsChecks(function, graph, loop, preheader)) {
            function.invalidateControlFlow();
            return true;
        }
    }
    return false;
}

const Induction = struct {
    parameter: ValueId,
    start: ValueId,
    step: i32,
};

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
    const test_result = exitTest(function, loop) orelse return false;
    if (test_result.operation != .eqb or boolean(function, test_result.operands.rhs) != true) return false;
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
    if (carried != .select or boolean(function, carried.select.then_value) != true or function.find(carried.select.else_value) != flag) return false;
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
    if (edges.len != 1 or edges[0].block != loop.header) return false;
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
    const inactive = try function.insertInstruction(loop.header, 0, .{ .const_bool = false }, header.span, header.frame);
    var initial: std.ArrayList(structures.FunctionValueUse) = .empty;
    for (original, 0..) |parameter, position| {
        if (position == flag_position) {
            replacements[position] = inactive;
            continue;
        }
        const argument = function.definitions.items[@backingInt(parameter)].argument.data;
        replacements[position] = try function.addParameter(body, argument);
        try initial.append(function.scratch, .{ .value = parameter });
    }
    var rewritten: LoopParameters = .{ .function = function, .from = original, .to = replacements };
    for (function.blocks.items, 0..) |*block, index| {
        if (!graph.dominates(body, @intCast(index))) continue;
        for (block.instructions.items) |instruction| {
            if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &rewritten, LoopParameters.replace);
        }
        function_ir.terminatorAllOperands(function, &block.terminator, &rewritten, LoopParameters.replace);
    }
    const active = test_result.operands.rhs;
    var exiting: std.ArrayList(structures.FunctionValueUse) = .empty;
    var repeating: std.ArrayList(structures.FunctionValueUse) = .empty;
    const next_condition = if (std.mem.indexOfScalar(ValueId, original, condition)) |position| replacements[position] else condition;
    for (function.branchArguments(terminator.branch), 0..) |argument, position| {
        try exiting.append(function.scratch, .{ .value = if (position == flag_position) active else selectArm(function, argument.value, next_condition, true) });
        if (position != flag_position) try repeating.append(function.scratch, .{ .value = selectArm(function, argument.value, next_condition, false) });
    }
    const initial_arguments = try function.appendBranchArguments(initial.items);
    for (Function.edges(&function.blocks.items[loop.header].terminator)) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == body) edge.arguments = initial_arguments;
    };
    function.blocks.items[latch].terminator = .{ .predicate_branch = .{
        .operation = .eqb,
        .operands = .{ .lhs = next_condition, .rhs = active },
        .then_branch = .{ .target = @fromBackingInt(loop.header), .arguments = try function.appendBranchArguments(exiting.items) },
        .else_branch = .{ .target = @fromBackingInt(body), .arguments = try function.appendBranchArguments(repeating.items) },
    } };
    return true;
}

fn constant(function: *const Function, value: ValueId) ?i32 {
    const definition = function.definition(function.find(value)) orelse return null;
    return if (definition == .const_int) definition.const_int else null;
}

fn entering(function: *Function, loop: Loop, preheader: u32) structures.FunctionBranch {
    _ = loop;
    return function.blocks.items[preheader].terminator.branch;
}

fn latchBranch(function: *Function, loop: Loop) ?structures.FunctionBranch {
    for (Function.edges(&function.blocks.items[loop.latches[0]].terminator)) |maybe_edge| if (maybe_edge) |edge| {
        if (@backingInt(edge.target) == loop.header) return edge.*;
    };
    return null;
}

fn induction(function: *Function, loop: Loop, preheader: u32, parameter: ValueId) ?Induction {
    const header = &function.blocks.items[loop.header];
    const position = std.mem.indexOfScalar(ValueId, header.parameters.items, parameter) orelse return null;
    if (function.valueType(parameter) != .int) return null;
    const start = function.branchArguments(entering(function, loop, preheader))[position];
    const back = function.branchArguments(latchBranch(function, loop) orelse return null)[position];
    if (start.coerce_to != null or back.coerce_to != null) return null;
    const next = function.definition(function.find(back.value)) orelse return null;
    const step: i32 = switch (next) {
        .addi => |operands| if (function.find(operands.lhs) == parameter) constant(function, operands.rhs) orelse return null else if (function.find(operands.rhs) == parameter) constant(function, operands.lhs) orelse return null else return null,
        .subi => |operands| if (function.find(operands.lhs) == parameter) -%(constant(function, operands.rhs) orelse return null) else return null,
        else => return null,
    };
    if (step == 0) return null;
    return .{ .parameter = parameter, .start = function.find(start.value), .step = step };
}

fn definedOutside(function: *const Function, loop: Loop, owner: []const u32, value: ValueId) bool {
    return switch (function.definitions.items[@backingInt(function.find(value))]) {
        .argument => |argument| !loop.contains(argument.block),
        .instruction => |index| !loop.contains(owner[index]),
    };
}

fn owners(function: *Function) ![]u32 {
    const owner = try function.scratch.alloc(u32, function.instructions.items.len);
    @memset(owner, std.math.maxInt(u32));
    for (function.blocks.items, 0..) |block, index| for (block.instructions.items) |instruction| {
        owner[instruction] = @intCast(index);
    };
    return owner;
}

const Exit = struct { block: u32, target: u32, stays: bool };

fn exitTest(function: *Function, loop: Loop) ?struct { operation: structures.PredicateOperation, operands: structures.BinaryOperands, exit: u32, stay: u32 } {
    const terminator = function.blocks.items[loop.header].terminator;
    if (terminator != .predicate_branch) return null;
    const predicate = terminator.predicate_branch;
    const then_target = @backingInt(predicate.then_branch.target);
    const else_target = @backingInt(predicate.else_branch.target);
    if (loop.contains(then_target) == loop.contains(else_target)) return null;
    const exit = if (loop.contains(then_target)) predicate.else_branch else predicate.then_branch;
    if (exit.arguments.start != exit.arguments.end) return null;
    const stay = if (loop.contains(then_target)) predicate.then_branch else predicate.else_branch;
    const operation = if (loop.contains(then_target)) predicate.operation.negated() else predicate.operation;
    return .{ .operation = operation, .operands = predicate.operands, .exit = @backingInt(exit.target), .stay = @backingInt(stay.target) };
}

fn soleExit(function: *Function, loop: Loop, header_exit: u32) bool {
    for (loop.blocks) |block| for (function.successors(block)) |successor| if (successor) |target| {
        if (!loop.contains(target) and (block != loop.header or target != header_exit)) return false;
    };
    return true;
}

fn removeDeadLoop(function: *Function, graph: Graph, loop: Loop, preheader: u32) !bool {
    _ = graph;
    const test_result = exitTest(function, loop) orelse return false;
    if (!soleExit(function, loop, test_result.exit)) return false;
    if (test_result.operation != .eqi) return false;
    const owner = try owners(function);
    var counter: ?Induction = null;
    for ([_]ValueId{ test_result.operands.lhs, test_result.operands.rhs }, [_]ValueId{ test_result.operands.rhs, test_result.operands.lhs }) |candidate, bound| {
        const found = induction(function, loop, preheader, function.find(candidate)) orelse continue;
        if (found.step != 1 and found.step != -1) continue;
        if (!definedOutside(function, loop, owner, bound)) continue;
        counter = found;
    }
    if (counter == null) return false;
    for (loop.blocks) |block| {
        for (function.blocks.items[block].instructions.items) |index| {
            if (function.removed.items[index]) continue;
            if (!pure(function, function.instructions.items[index])) return false;
        }
        const terminator = function.blocks.items[block].terminator;
        if (terminator != .branch and terminator != .predicate_branch) return false;
    }
    var escape: Escape = .{ .function = function, .loop = loop, .owner = owner };
    for (function.blocks.items, 0..) |*block, index| {
        if (loop.contains(@intCast(index))) continue;
        for (block.instructions.items) |instruction| if (!function.removed.items[instruction]) function_ir.allOperands(function, &function.instructions.items[instruction], &escape, Escape.check);
        function_ir.terminatorAllOperands(function, &block.terminator, &escape, Escape.check);
    }
    if (escape.escapes) return false;
    function.blocks.items[preheader].terminator = .{ .branch = .{ .target = @fromBackingInt(test_result.exit), .arguments = .{ .start = 0, .end = 0 } } };
    return true;
}

const Escape = struct {
    function: *Function,
    loop: Loop,
    owner: []const u32,
    escapes: bool = false,

    fn check(self: *Escape, operand: *ValueId) void {
        if (!definedOutside(self.function, self.loop, self.owner, operand.*)) self.escapes = true;
    }
};

fn pure(function: *const Function, instruction: Instruction) bool {
    return switch (instruction) {
        .const_int, .const_bool, .const_byte, .const_unit, .const_none, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select, .variant_tag, .field_access, .borrow_address, .borrow_read, .storage_projection, .allocation_element, .array_element, .cursor_offset, .cursor_element, .function_ref => true,
        .divsi => |operands| if (function.definition(operands.rhs)) |divisor| divisor == .const_int and divisor.const_int != 0 else false,
        inline .value_copy, .variant_extract, .variant_coerce => |operation| operation.destination == null,
        else => false,
    };
}

fn fill(function: *Function, graph: Graph, loop: Loop, preheader: u32) !bool {
    if (loop.blocks.len != 2) return false;
    const header = &function.blocks.items[loop.header];
    if (header.parameters.items.len != 1) return false;
    for (header.instructions.items) |index| if (!function.removed.items[index]) return false;
    const test_result = exitTest(function, loop) orelse return false;
    if (test_result.operation != .eqi) return false;
    const parameter = header.parameters.items[0];
    const counter = induction(function, loop, preheader, parameter) orelse return false;
    if (counter.step != 1) return false;
    const owner = try owners(function);
    const bound = if (function.find(test_result.operands.lhs) == parameter) function.find(test_result.operands.rhs) else if (function.find(test_result.operands.rhs) == parameter) function.find(test_result.operands.lhs) else return false;
    if (!definedOutside(function, loop, owner, bound)) return false;
    const body = test_result.stay;
    if (body != loop.latches[0] or function.blocks.items[body].terminator != .branch) return false;
    var element: ?structures.AllocationElement = null;
    var element_value: ?ValueId = null;
    var stored: ?structures.ValueCopy = null;
    for (function.blocks.items[body].instructions.items) |index| {
        if (function.removed.items[index]) continue;
        switch (function.instructions.items[index]) {
            .const_int, .const_bool, .const_byte => {},
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
    if (!definedOutside(function, loop, owner, target.allocation) or !definedOutside(function, loop, owner, store.source)) return false;
    var users: Users = .{ .function = function, .value = element_value.? };
    for (function.blocks.items[body].instructions.items) |index| if (!function.removed.items[index]) function_ir.allOperands(function, &function.instructions.items[index], &users, Users.count);
    if (users.count_value != 1) return false;

    if (guarded(function, graph, preheader, counter.start, bound)) return false;
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

fn move(function: *Function, graph: Graph, loop: Loop, preheader: u32) !bool {
    if (loop.blocks.len != 2) return false;
    const header = &function.blocks.items[loop.header];
    if (header.parameters.items.len != 1) return false;
    for (header.instructions.items) |index| if (!function.removed.items[index]) return false;
    const test_result = exitTest(function, loop) orelse return false;
    if (test_result.operation != .eqi) return false;
    const parameter = header.parameters.items[0];
    const counter = induction(function, loop, preheader, parameter) orelse return false;
    if (counter.step != -1) return false;
    const owner = try owners(function);
    const bound = if (function.find(test_result.operands.lhs) == parameter) function.find(test_result.operands.rhs) else if (function.find(test_result.operands.rhs) == parameter) function.find(test_result.operands.lhs) else return false;
    if (!definedOutside(function, loop, owner, bound)) return false;
    const body = test_result.stay;
    if (body != loop.latches[0] or function.blocks.items[body].terminator != .branch) return false;
    const next = function.find(function.branchArguments(latchBranch(function, loop).?)[0].value);
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
    if (!definedOutside(function, loop, owner, from.allocation) or !definedOutside(function, loop, owner, to.allocation)) return false;
    var users: Users = .{ .function = function, .value = source_value.? };
    for (function.blocks.items[body].instructions.items) |index| if (!function.removed.items[index]) function_ir.allOperands(function, &function.instructions.items[index], &users, Users.count);
    if (users.count_value != 1) return false;
    users = .{ .function = function, .value = destination_value.? };
    for (function.blocks.items[body].instructions.items) |index| if (!function.removed.items[index]) function_ir.allOperands(function, &function.instructions.items[index], &users, Users.count);
    if (users.count_value != 1) return false;

    if (guarded(function, graph, preheader, bound, counter.start)) return false;
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

fn guarded(function: *Function, graph: Graph, preheader: u32, low: ValueId, high: ValueId) bool {
    var block = preheader;
    var lower = low;
    var upper = high;
    for (0..4) |_| {
        const incoming = graph.incoming[block].items;
        for (incoming) |edge| {
            const terminator = function.blocks.items[edge.block].terminator;
            if (terminator != .predicate_branch) continue;
            const predicate = terminator.predicate_branch;
            if (@backingInt(predicate.else_branch.target) != block) continue;
            const entered = through(function, block, edge, lower);
            const lhs = function.find(predicate.operands.lhs);
            const rhs = function.find(predicate.operands.rhs);
            if (predicate.operation == .gei and lhs == entered and constant(function, rhs) == 0) return true;
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

fn boundsChecks(function: *Function, graph: Graph, loop: Loop, preheader: u32) !bool {
    const test_result = exitTest(function, loop) orelse return false;
    const owner = try owners(function);
    var changed = false;
    for (function.blocks.items[loop.header].parameters.items) |parameter| {
        const counter = induction(function, loop, preheader, parameter) orelse continue;
        if (counter.step != 1) continue;
        const start = constant(function, counter.start) orelse continue;
        if (start < 0) continue;
        const lhs = function.find(test_result.operands.lhs);
        const rhs = function.find(test_result.operands.rhs);
        const bounded = (test_result.operation == .gei and lhs == parameter and definedOutside(function, loop, owner, rhs)) or
            (test_result.operation == .lei and rhs == parameter and definedOutside(function, loop, owner, lhs));
        if (!bounded) continue;
        const limit = if (lhs == parameter) rhs else lhs;
        for (loop.blocks) |block| {
            if (!graph.dominates(test_result.stay, block)) continue;
            const terminator = &function.blocks.items[block].terminator;
            if (terminator.* != .predicate_branch) continue;
            const predicate = terminator.predicate_branch;
            const left = function.find(predicate.operands.lhs);
            const right = function.find(predicate.operands.rhs);
            const holds: ?bool = if (left == parameter and constant(function, right) != null and constant(function, right).? <= start and (predicate.operation == .gei or predicate.operation == .lti))
                predicate.operation == .gei
            else if (left == parameter and right == limit and (predicate.operation == .lti or predicate.operation == .gei))
                predicate.operation == .lti
            else
                null;
            if (holds) |taken| {
                terminator.* = .{ .branch = if (taken) predicate.then_branch else predicate.else_branch };
                changed = true;
            }
        }
    }
    return changed;
}
