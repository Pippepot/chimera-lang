const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const loops = @import("loops.zig");

const ValueId = structures.FunctionValueId;
const Function = function_ir.Function;
const Range = structures.FunctionValueRange;

pub fn transform(function: *Function, analysis: *const loops.Analysis, loop: loops.Loop, preheader: u32, budget: *usize) !bool {
    if (budget.* == 0) return false;
    for (loop.blocks) |block| {
        const terminator = function.blocks.items[block].terminator;
        if (terminator != .predicate_branch) continue;
        var predicate = terminator.predicate_branch;
        if (predicate.operation != .eqb and predicate.operation != .neb) continue;
        if (function.constantBool(predicate.operands.rhs) == null) std.mem.swap(ValueId, &predicate.operands.lhs, &predicate.operands.rhs);
        const expected = function.constantBool(predicate.operands.rhs) orelse continue;
        const condition = function.find(predicate.operands.lhs);
        if (!function.plainValue(condition) or analysis.address_taken[@backingInt(condition)]) continue;
        // Version parameter-controlled modes. Computed conditions may already
        // be cheap loop guards; duplicating those bodies needs a separate cost case.
        const definition = function.definitions.items[@backingInt(condition)];
        if (definition != .argument or definition.argument.block != function.entry) continue;
        var cost: usize = loop.blocks.len;
        for (loop.blocks) |member| cost += function.blocks.items[member].instructions.items.len + function.blocks.items[member].parameters.items.len;
        if (cost > budget.*) return false;
        var escape: Escape = .{ .analysis = analysis, .loop = loop };
        for (function.blocks.items, 0..) |*outside, index| {
            if (!loop.contains(@intCast(index))) function_ir.visitBlockReferences(function, outside, &escape, Escape.check);
        }
        if (escape.found) return false;
        var clone = try Clone.init(function, loop);
        const old_entry = function.blocks.items[preheader].terminator.branch;
        const new_entry = try clone.branch(old_entry);
        const duplicate = clone.blocks[block];
        const copied = function.blocks.items[duplicate].terminator.predicate_branch;
        function.blocks.items[block].terminator = .{ .branch = predicate.then_branch };
        function.blocks.items[duplicate].terminator = .{ .branch = copied.else_branch };
        const constant = try function.appendInstruction(preheader, .{ .const_bool = expected }, function.blocks.items[preheader].span, function.blocks.items[preheader].frame);
        function.blocks.items[preheader].terminator = .{ .predicate_branch = .{
            .operation = predicate.operation,
            .operands = .{ .lhs = condition, .rhs = constant },
            .then_branch = old_entry,
            .else_branch = new_entry,
        } };
        budget.* -= cost;
        function.invalidateControlFlow();
        return true;
    }
    return false;
}

const Escape = struct {
    analysis: *const loops.Analysis,
    loop: loops.Loop,
    found: bool = false,

    fn check(self: *Escape, value: ValueId) void {
        if (!self.analysis.definedOutside(self.loop, value)) self.found = true;
    }
};

/// Every local definition and edge is copied; immutable side tables stay shared.
/// Values leaving the loop must already travel through explicit exit arguments.
const Clone = struct {
    function: *Function,
    values: []ValueId,
    blocks: []u32,

    fn init(function: *Function, loop: loops.Loop) !Clone {
        const scratch = function.scratch;
        const values = try scratch.alloc(ValueId, function.valueCount());
        const blocks = try scratch.alloc(u32, function.blocks.items.len);
        for (values, 0..) |*value, index| value.* = @fromBackingInt(@intCast(index));
        for (blocks, 0..) |*block, index| block.* = @intCast(index);
        var self: Clone = .{ .function = function, .values = values, .blocks = blocks };
        for (loop.blocks) |block| {
            const original = function.blocks.items[block];
            const duplicate = try function.addBlock(.diverge, original.span, original.frame);
            self.blocks[block] = duplicate;
            try function.order.append(scratch, duplicate);
            for (original.parameters.items) |parameter| {
                self.values[@backingInt(parameter)] = try function.addParameter(duplicate, function.definitions.items[@backingInt(parameter)].argument.data);
            }
        }
        for (loop.blocks) |block| {
            const instructions = function.blocks.items[block].instructions.items;
            for (instructions) |index| {
                if (function.removed.items[index]) continue;
                const duplicate = try function.newInstruction(function.instructions.items[index], function.instructionSpan(index), function.instructionFrame(index));
                try function.blocks.items[self.blocks[block]].instructions.append(scratch, duplicate);
                self.values[@backingInt(function.results.items[index])] = function.results.items[duplicate];
            }
        }
        for (loop.blocks) |block| {
            for (function.blocks.items[self.blocks[block]].instructions.items) |index| {
                var instruction = function.instructions.items[index];
                try self.remapInstruction(&instruction);
                function.instructions.items[index] = instruction;
            }
            var terminator = function.blocks.items[block].terminator;
            for (terminator.operands()) |operand| if (operand) |value| self.remap(value);
            for (terminator.branches()) |maybe_branch| if (maybe_branch) |edge| {
                edge.* = try self.branch(edge.*);
            };
            function.blocks.items[self.blocks[block]].terminator = terminator;
        }
        return self;
    }

    fn remap(self: *const Clone, value: *ValueId) void {
        value.* = self.values[@backingInt(value.*)];
    }

    fn valueRange(self: *Clone, table: *std.ArrayList(ValueId), range: Range) !Range {
        try table.ensureUnusedCapacity(self.function.scratch, range.end - range.start);
        const start: u32 = @intCast(table.items.len);
        for (range.start..range.end) |index| table.appendAssumeCapacity(self.values[@backingInt(table.items[index])]);
        return .{ .start = start, .end = @intCast(table.items.len) };
    }

    fn remapInstruction(self: *Clone, operation: *structures.FunctionInstruction) !void {
        for (operation.operands()) |operand| if (operand) |value| self.remap(value);
        switch (operation.*) {
            .call => |*call| call.arguments = try self.callArguments(call.arguments),
            .aggregate => |*aggregate| aggregate.fields = try self.valueRange(&self.function.aggregate_fields, aggregate.fields),
            .initializer_ref => |*reference| reference.captures = try self.valueRange(&self.function.initializer_captures, reference.captures),
            else => {},
        }
    }

    fn callArguments(self: *Clone, range: Range) !Range {
        const table = &self.function.call_arguments;
        try table.ensureUnusedCapacity(self.function.scratch, range.end - range.start);
        const start: u32 = @intCast(table.items.len);
        for (range.start..range.end) |index| {
            var argument = table.items[index];
            self.remap(argument.operand());
            table.appendAssumeCapacity(argument);
        }
        return .{ .start = start, .end = @intCast(table.items.len) };
    }

    fn branch(self: *Clone, original: structures.FunctionBranch) !structures.FunctionBranch {
        const table = &self.function.branch_arguments;
        try table.ensureUnusedCapacity(self.function.scratch, original.arguments.end - original.arguments.start);
        const start: u32 = @intCast(table.items.len);
        for (original.arguments.start..original.arguments.end) |index| {
            var argument = table.items[index];
            self.remap(&argument.value);
            table.appendAssumeCapacity(argument);
        }
        return .{ .target = @fromBackingInt(self.blocks[@backingInt(original.target)]), .arguments = .{ .start = start, .end = @intCast(table.items.len) } };
    }
};
