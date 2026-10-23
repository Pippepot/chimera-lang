const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const BlockId = structures.FunctionBlockId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const Function = function_ir.Function;

pub fn compact(scratch: std.mem.Allocator, function: *Function, regions: []const Body) !Body {
    function.resolveReferences();
    const body = function.body;
    const reachable = try reachableBlocks(scratch, function);
    const live = try liveValues(scratch, function, reachable);

    const block_map = try scratch.alloc(?u32, function.blocks.items.len);
    var block_count: u32 = 0;
    for (block_map, reachable) |*mapped, kept| {
        mapped.* = if (kept) block_count else null;
        if (kept) block_count += 1;
    }

    const value_map = try scratch.alloc(?u32, function.valueCount());
    @memset(value_map, null);
    var block_arguments: std.ArrayList(structures.FunctionBlockArgument) = .empty;
    const argument_ranges = try scratch.alloc(structures.FunctionValueRange, function.blocks.items.len);
    for (function.blocks.items, reachable, argument_ranges) |block, kept, *range| {
        const start: u32 = @intCast(block_arguments.items.len);
        if (kept) for (block.parameters.items) |parameter| if (live[@backingInt(parameter)]) {
            value_map[@backingInt(parameter)] = @intCast(block_arguments.items.len);
            try block_arguments.append(scratch, function.definitions.items[@backingInt(parameter)].argument.data);
        };
        range.* = .{ .start = start, .end = @intCast(block_arguments.items.len) };
    }
    const argument_count: u32 = @intCast(block_arguments.items.len);

    const layout = try scratch.alloc(u32, block_count);
    for (block_map, 0..) |mapped, index| if (mapped) |position| {
        layout[position] = @intCast(index);
    };
    std.mem.sort(u32, layout, function, layoutBefore);

    var instructions: std.ArrayList(Instruction) = .empty;
    var instruction_spans: std.ArrayList(structures.SourceSpan) = .empty;
    const instruction_ranges = try scratch.alloc(structures.FunctionValueRange, function.blocks.items.len);
    for (layout) |block_index| {
        const start: u32 = @intCast(instructions.items.len);
        for (function.blocks.items[block_index].instructions.items) |index| {
            const result = function.results.items[index];
            if (function.removed.items[index] or !live[@backingInt(result)]) continue;
            value_map[@backingInt(result)] = argument_count + @as(u32, @intCast(instructions.items.len));
            try instructions.append(scratch, function.instructions.items[index]);
            if (function.publishesSpans()) try instruction_spans.append(scratch, function.spans.items[index]);
        }
        instruction_ranges[block_index] = .{ .start = start, .end = @intCast(instructions.items.len) };
    }

    var rebuilt: Rebuilt = .{ .function = function, .live = live };
    for (instructions.items) |*instruction| try rebuilt.relocateInstruction(scratch, instruction);

    var blocks: std.ArrayList(structures.FunctionBlock) = .empty;
    var terminator_spans: std.ArrayList(structures.SourceSpan) = .empty;
    for (function.blocks.items, reachable, 0..) |block, kept, index| {
        if (!kept) continue;
        var terminator = block.terminator;
        try rebuilt.relocateTerminator(scratch, &terminator);
        remapTargets(&terminator, block_map);
        try blocks.append(scratch, .{
            .argument_start = argument_ranges[index].start,
            .argument_end = argument_ranges[index].end,
            .instruction_start = instruction_ranges[index].start,
            .instruction_end = instruction_ranges[index].end,
            .terminator = terminator,
        });
        if (function.publishesSpans()) try terminator_spans.append(scratch, body.terminator_spans[index]);
    }

    const view: structures.FunctionBodyFinalization = .{
        .instructions = instructions.items,
        .blocks = blocks.items,
        .call_arguments = rebuilt.call_arguments.items,
        .branch_arguments = rebuilt.branch_arguments.items,
        .initializer_captures = rebuilt.initializer_captures.items,
    };
    view.visitValueReferences(value_map, remapValue);
    for (instructions.items) |*instruction| if (instruction.* == .initializer_capture_write) {
        const write = &instruction.initializer_capture_write;
        write.parameter_index = value_map[write.parameter_index].?;
    };

    return .{
        .return_type = body.return_type,
        .is_fallible = body.is_fallible,
        .is_initializer_region = body.is_initializer_region,
        .initializer_regions = regions,
        .initializer_captures = rebuilt.initializer_captures.items,
        .parameter_modes = body.parameter_modes,
        .block_arguments = block_arguments.items,
        .variant_coercion_tags = body.variant_coercion_tags,
        .borrow_fields = body.borrow_fields,
        .branch_arguments = rebuilt.branch_arguments.items,
        .call_arguments = rebuilt.call_arguments.items,
        .instructions = instructions.items,
        .instruction_spans = instruction_spans.items,
        .terminator_spans = terminator_spans.items,
        .blocks = blocks.items,
        .entry = @fromBackingInt(block_map[@backingInt(body.entry)].?),
    };
}

fn layoutBefore(function: *const Function, a: u32, b: u32) bool {
    const left = function.blocks.items[a].layout;
    const right = function.blocks.items[b].layout;
    return left < right or left == right and a < b;
}

const Rebuilt = struct {
    function: *const Function,
    live: []const bool,
    call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
    branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
    initializer_captures: std.ArrayList(ValueId) = .empty,

    fn relocateInstruction(self: *Rebuilt, scratch: std.mem.Allocator, instruction: *Instruction) !void {
        switch (instruction.*) {
            .call => |*call| try self.relocateCall(scratch, call),
            .initializer_ref => |*reference| {
                const start: u32 = @intCast(self.initializer_captures.items.len);
                try self.initializer_captures.appendSlice(scratch, self.function.initializer_captures.items[reference.captures.start..reference.captures.end]);
                reference.captures = .{ .start = start, .end = @intCast(self.initializer_captures.items.len) };
            },
            else => {},
        }
    }

    fn relocateTerminator(self: *Rebuilt, scratch: std.mem.Allocator, terminator: *Terminator) !void {
        switch (terminator.*) {
            .branch => |*branch| try self.relocateBranch(scratch, branch),
            .predicate_branch => |*predicate| {
                try self.relocateBranch(scratch, &predicate.then_branch);
                try self.relocateBranch(scratch, &predicate.else_branch);
            },
            .fallible_call => |*fallible| try self.relocateCall(scratch, &fallible.call),
            .return_unit, .return_value, .return_failure, .diverge => {},
        }
    }

    fn relocateCall(self: *Rebuilt, scratch: std.mem.Allocator, call: *structures.FunctionCall) !void {
        const start: u32 = @intCast(self.call_arguments.items.len);
        try self.call_arguments.appendSlice(scratch, self.function.call_arguments.items[call.arguments.start..call.arguments.end]);
        call.arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) };
    }

    fn relocateBranch(self: *Rebuilt, scratch: std.mem.Allocator, branch: *structures.FunctionBranch) !void {
        const start: u32 = @intCast(self.branch_arguments.items.len);
        const parameters = self.function.blocks.items[@backingInt(branch.target)].parameters.items;
        const arguments = self.function.branch_arguments.items[branch.arguments.start..branch.arguments.end];
        std.debug.assert(parameters.len == arguments.len);
        for (parameters, arguments) |parameter, argument| {
            if (self.live[@backingInt(parameter)]) try self.branch_arguments.append(scratch, argument);
        }
        branch.arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
    }
};

fn remapTargets(terminator: *Terminator, block_map: []const ?u32) void {
    switch (terminator.*) {
        .branch => |*branch| remapBlock(&branch.target, block_map),
        .predicate_branch => |*predicate| {
            remapBlock(&predicate.then_branch.target, block_map);
            remapBlock(&predicate.else_branch.target, block_map);
        },
        .fallible_call => |*fallible| {
            remapBlock(&fallible.success, block_map);
            if (fallible.failure) |*failure| remapBlock(failure, block_map);
        },
        .return_unit, .return_value, .return_failure, .diverge => {},
    }
}

fn remapBlock(block: *BlockId, block_map: []const ?u32) void {
    block.* = @fromBackingInt(block_map[@backingInt(block.*)].?);
}

fn remapValue(value_map: []const ?u32, value: *ValueId) void {
    value.* = @fromBackingInt(value_map[@backingInt(value.*)].?);
}

pub fn reachableBlocks(scratch: std.mem.Allocator, function: *Function) ![]bool {
    const reachable = try scratch.alloc(bool, function.blocks.items.len);
    @memset(reachable, false);
    var pending: std.ArrayList(u32) = .empty;
    const entry = @backingInt(function.body.entry);
    try pending.append(scratch, entry);
    reachable[entry] = true;
    while (pending.pop()) |block| {
        for (Function.edges(&function.blocks.items[block].terminator)) |maybe_edge| if (maybe_edge) |edge| {
            const target = @backingInt(Function.edgeTarget(edge));
            if (reachable[target]) continue;
            reachable[target] = true;
            try pending.append(scratch, target);
        };
    }
    return reachable;
}

const Liveness = struct {
    function: *Function,
    live: []bool,
    pending: std.ArrayList(ValueId) = .empty,
    failed: ?std.mem.Allocator.Error = null,

    fn mark(self: *Liveness, value: ValueId) void {
        if (self.live[@backingInt(value)]) return;
        self.live[@backingInt(value)] = true;
        self.pending.append(self.function.scratch, value) catch |err| {
            self.failed = err;
        };
    }
};

fn liveValues(scratch: std.mem.Allocator, function: *Function, reachable: []const bool) ![]const bool {
    var liveness: Liveness = .{ .function = function, .live = try scratch.alloc(bool, function.valueCount()) };
    @memset(liveness.live, false);
    const incoming = try incomingBranches(scratch, function, reachable);
    const tables = function_ir.tableView(function);
    for (function.blocks.items[@backingInt(function.body.entry)].parameters.items) |parameter| liveness.mark(parameter);
    for (function.blocks.items, reachable) |*block, kept| {
        if (!kept) continue;
        for (block.instructions.items) |index| {
            if (!function.removed.items[index] and !removableWhenUnused(function, function.instructions.items[index]))
                liveness.mark(function.results.items[index]);
        }
        function_ir.visitTerminatorOperands(tables, &block.terminator, &liveness, Liveness.mark);
        for (Function.edges(&block.terminator)) |maybe_edge| if (maybe_edge) |edge| if (edge == .fallible) {
            for (function.blocks.items[@backingInt(edge.fallible)].parameters.items) |result| liveness.mark(result);
        };
    }
    while (liveness.pending.pop()) |value| switch (function.definitions.items[@backingInt(value)]) {
        .instruction => |index| {
            std.debug.assert(!function.removed.items[index]);
            function_ir.visitInstructionReferences(tables, &function.instructions.items[index], &liveness, Liveness.mark);
        },
        .argument => |argument| {
            const position = std.mem.indexOfScalar(ValueId, function.blocks.items[argument.block].parameters.items, value).?;
            for (incoming[argument.block].items) |branch| liveness.mark(function.branch_arguments.items[branch.arguments.start + position].value);
        },
    };
    if (liveness.failed) |err| return err;
    return liveness.live;
}

pub fn incomingBranches(scratch: std.mem.Allocator, function: *Function, reachable: []const bool) ![]std.ArrayList(*structures.FunctionBranch) {
    const incoming = try scratch.alloc(std.ArrayList(*structures.FunctionBranch), function.blocks.items.len);
    @memset(incoming, .empty);
    for (function.blocks.items, reachable) |*block, kept| {
        if (!kept) continue;
        for (Function.edges(&block.terminator)) |maybe_edge| if (maybe_edge) |edge| if (edge == .branch) {
            try incoming[@backingInt(edge.branch.target)].append(scratch, edge.branch);
        };
    }
    return incoming;
}

fn removableWhenUnused(function: *const Function, instruction: Instruction) bool {
    return switch (instruction) {
        .const_int, .const_int_literal, .const_string_literal, .const_static_string, .const_storage_cursor, .const_byte, .const_bool, .const_type, .const_unit, .const_none, .function_ref, .local_storage, .addi, .subi, .muli, .negi, .byte_to_int => true,
        .divsi => |operands| if (function.definition(operands.rhs)) |divisor| divisor == .const_int and divisor.const_int != 0 else false,
        .value_copy => |copy| copy.destination == null and isScalar(copy.type_id),
        else => false,
    };
}

pub fn isScalar(type_id: structures.TypeId) bool {
    return type_id == .int or type_id == .bool or type_id == .byte;
}
