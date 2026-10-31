const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const BlockId = structures.FunctionBlockId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const InlineFrameId = structures.InlineFrameId;
const Range = structures.FunctionValueRange;
const Function = function_ir.Function;

pub fn compact(scratch: std.mem.Allocator, function: *Function) !Body {
    function.resolveReferences();
    const reachable = (try function.controlFlowEdges()).reachable;
    const live = try liveValues(scratch, function, reachable);

    const block_map = try scratch.alloc(?u32, function.blocks.items.len);
    @memset(block_map, null);
    var layout: std.ArrayList(u32) = .empty;
    try layout.append(scratch, function.entry);
    for (function.order.items) |block| if (reachable[block] and block != function.entry) try layout.append(scratch, block);
    for (layout.items, 0..) |block, position| block_map[block] = @intCast(position);

    const value_map = try scratch.alloc(?u32, function.valueCount());
    @memset(value_map, null);
    var block_arguments: std.ArrayList(structures.FunctionBlockArgument) = .empty;
    const argument_ranges = try scratch.alloc(Range, function.blocks.items.len);
    for (layout.items) |block_index| {
        const start: u32 = @intCast(block_arguments.items.len);
        for (function.blocks.items[block_index].parameters.items) |parameter| if (live[@backingInt(parameter)]) {
            value_map[@backingInt(parameter)] = @intCast(block_arguments.items.len);
            try block_arguments.append(scratch, function.definitions.items[@backingInt(parameter)].argument.data);
        };
        argument_ranges[block_index] = .{ .start = start, .end = @intCast(block_arguments.items.len) };
    }
    const argument_count: u32 = @intCast(block_arguments.items.len);

    var rebuilt: Rebuilt = .{ .function = function, .live = live, .frame_map = try scratch.alloc(?u32, function.inline_frames.items.len), .region_map = try scratch.alloc(?u32, function.regions.items.len) };
    @memset(rebuilt.frame_map, null);
    @memset(rebuilt.region_map, null);

    var instructions: std.ArrayList(Instruction) = .empty;
    var instruction_spans: std.ArrayList(structures.SourceSpan) = .empty;
    var instruction_frames: std.ArrayList(InlineFrameId) = .empty;
    const instruction_ranges = try scratch.alloc(Range, function.blocks.items.len);
    for (layout.items) |block_index| {
        const start: u32 = @intCast(instructions.items.len);
        for (function.blocks.items[block_index].instructions.items) |index| {
            const result = function.results.items[index];
            if (function.removed.items[index] or !live[@backingInt(result)]) continue;
            value_map[@backingInt(result)] = argument_count + @as(u32, @intCast(instructions.items.len));
            var instruction = function.instructions.items[index];
            try rebuilt.relocateInstruction(scratch, &instruction);
            try instructions.append(scratch, instruction);
            if (function.publishes_spans) {
                try instruction_spans.append(scratch, function.spans.items[index]);
                try instruction_frames.append(scratch, try rebuilt.frame(scratch, function.frames.items[index]));
            }
        }
        instruction_ranges[block_index] = .{ .start = start, .end = @intCast(instructions.items.len) };
    }

    var blocks: std.ArrayList(structures.FunctionBlock) = .empty;
    var terminator_spans: std.ArrayList(structures.SourceSpan) = .empty;
    var terminator_frames: std.ArrayList(InlineFrameId) = .empty;
    for (layout.items) |index| {
        const block = function.blocks.items[index];
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
        if (function.publishes_spans) {
            try terminator_spans.append(scratch, block.span);
            try terminator_frames.append(scratch, try rebuilt.frame(scratch, block.frame));
        }
    }

    const view: structures.FunctionBodyFinalization = .{
        .instructions = instructions.items,
        .blocks = blocks.items,
        .call_arguments = rebuilt.call_arguments.items,
        .branch_arguments = rebuilt.branch_arguments.items,
        .initializer_captures = rebuilt.initializer_captures.items,
        .aggregate_fields = rebuilt.aggregate_fields.items,
    };
    view.visitValueReferences(value_map, remapValue);

    const framed = rebuilt.inline_frames.items.len != 0;
    return .{
        .return_type = function.return_type,
        .is_initializer_region = function.is_initializer_region,
        .initializer_regions = rebuilt.regions.items,
        .initializer_captures = rebuilt.initializer_captures.items,
        .parameter_modes = function.parameter_modes,
        .block_arguments = block_arguments.items,
        .variant_coercion_tags = rebuilt.variant_coercion_tags.items,
        .borrow_fields = rebuilt.borrow_fields.items,
        .branch_arguments = rebuilt.branch_arguments.items,
        .call_arguments = rebuilt.call_arguments.items,
        .aggregate_fields = rebuilt.aggregate_fields.items,
        .instructions = instructions.items,
        .instruction_spans = instruction_spans.items,
        .terminator_spans = terminator_spans.items,
        .root_instance = function.root_instance,
        .inline_frames = rebuilt.inline_frames.items,
        .instruction_frames = if (framed) instruction_frames.items else &.{},
        .terminator_frames = if (framed) terminator_frames.items else &.{},
        .blocks = blocks.items,
        .entry = @fromBackingInt(0),
    };
}

const Rebuilt = struct {
    function: *const Function,
    live: []const bool,
    frame_map: []?u32,
    region_map: []?u32,
    call_arguments: std.ArrayList(structures.FunctionCallArgument) = .empty,
    branch_arguments: std.ArrayList(structures.FunctionValueUse) = .empty,
    initializer_captures: std.ArrayList(ValueId) = .empty,
    aggregate_fields: std.ArrayList(ValueId) = .empty,
    variant_coercion_tags: std.ArrayList(u32) = .empty,
    borrow_fields: std.ArrayList(structures.BorrowProjection) = .empty,
    inline_frames: std.ArrayList(structures.InlineFrame) = .empty,
    regions: std.ArrayList(Body) = .empty,

    fn relocateInstruction(self: *Rebuilt, scratch: std.mem.Allocator, instruction: *Instruction) !void {
        switch (instruction.*) {
            .call => |*call| try self.relocateCall(scratch, call),
            .initializer_ref => |*reference| {
                reference.captures = try relocate(ValueId, scratch, &self.initializer_captures, self.function.initializer_captures.items, reference.captures);
                reference.region = try self.region(scratch, reference.region);
            },
            .aggregate => |*aggregate| aggregate.fields = try relocate(ValueId, scratch, &self.aggregate_fields, self.function.aggregate_fields.items, aggregate.fields),
            inline .variant_coerce, .variant_extract => |*operation| operation.tag_mapping = try self.tagMapping(scratch, operation.tag_mapping),
            .borrow_address => |*operation| operation.fields = try relocate(structures.BorrowProjection, scratch, &self.borrow_fields, self.function.borrow_fields.items, operation.fields),
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
            .return_value => |*use| use.variant_tag_mapping = try self.tagMapping(scratch, use.variant_tag_mapping),
            .return_unit, .diverge => {},
        }
    }

    fn relocateCall(self: *Rebuilt, scratch: std.mem.Allocator, call: *structures.FunctionCall) !void {
        const start: u32 = @intCast(self.call_arguments.items.len);
        for (self.function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
            var relocated = argument;
            if (relocated == .prepared) relocated.prepared.variant_tag_mapping = try self.tagMapping(scratch, argument.prepared.variant_tag_mapping);
            try self.call_arguments.append(scratch, relocated);
        }
        call.arguments = .{ .start = start, .end = @intCast(self.call_arguments.items.len) };
    }

    fn relocateBranch(self: *Rebuilt, scratch: std.mem.Allocator, branch: *structures.FunctionBranch) !void {
        const start: u32 = @intCast(self.branch_arguments.items.len);
        const parameters = self.function.blocks.items[@backingInt(branch.target)].parameters.items;
        const arguments = self.function.branch_arguments.items[branch.arguments.start..branch.arguments.end];
        std.debug.assert(parameters.len == arguments.len);
        for (parameters, arguments) |parameter, argument| {
            if (!self.live[@backingInt(parameter)]) continue;
            var relocated = argument;
            relocated.variant_tag_mapping = try self.tagMapping(scratch, argument.variant_tag_mapping);
            try self.branch_arguments.append(scratch, relocated);
        }
        branch.arguments = .{ .start = start, .end = @intCast(self.branch_arguments.items.len) };
    }

    fn tagMapping(self: *Rebuilt, scratch: std.mem.Allocator, mapping: ?Range) !?Range {
        return try relocate(u32, scratch, &self.variant_coercion_tags, self.function.variant_coercion_tags.items, mapping orelse return null);
    }

    fn frame(self: *Rebuilt, scratch: std.mem.Allocator, original: InlineFrameId) !InlineFrameId {
        if (original == .root) return .root;
        const index = @backingInt(original);
        if (self.frame_map[index]) |mapped| return @fromBackingInt(mapped);
        var copied = self.function.inline_frames.items[index];
        copied.parent = try self.frame(scratch, copied.parent);
        const mapped: u32 = @intCast(self.inline_frames.items.len);
        try self.inline_frames.append(scratch, copied);
        self.frame_map[index] = mapped;
        return @fromBackingInt(mapped);
    }

    fn region(self: *Rebuilt, scratch: std.mem.Allocator, original: u32) !u32 {
        if (self.region_map[original]) |mapped| return mapped;
        const mapped: u32 = @intCast(self.regions.items.len);
        try self.regions.append(scratch, self.function.regions.items[original]);
        self.region_map[original] = mapped;
        return mapped;
    }
};

fn relocate(comptime T: type, scratch: std.mem.Allocator, table: *std.ArrayList(T), source: []const T, range: Range) !Range {
    const start: u32 = @intCast(table.items.len);
    try table.appendSlice(scratch, source[range.start..range.end]);
    return .{ .start = start, .end = @intCast(table.items.len) };
}

pub fn removeDead(function: *Function) !function_ir.Changes {
    function.resolveReferences();
    const reachable = (try function.controlFlowEdges()).reachable;
    const live = try liveValues(function.scratch, function, reachable);
    var changes: function_ir.Changes = .{};
    var uses: DeadUses = .{ .function = function, .live = live };
    const tables = function_ir.tableView(function);
    for (function.results.items, function.removed.items, function.instructions.items) |result, *removed, *instruction| {
        if (!removed.* and !live[@backingInt(result)]) {
            changes.storage = changes.storage or function_ir.usesStorage(function, instruction);
            if (!uses.changed) {
                function_ir.visitInstructionReferences(tables, instruction, &uses, DeadUses.reference);
                canonicalize.visitInstructionAddresses(function, instruction.*, &uses, DeadUses.address);
            }
            removed.* = true;
            changes.changed = true;
        }
    }
    for (function.blocks.items, reachable) |*block, kept| if (!kept) {
        if (block.instructions.items.len != 0 or block.terminator != .diverge) changes.changed = true;
        if (!uses.changed) {
            function_ir.visitTerminatorReferences(tables, &block.terminator, &uses, DeadUses.reference);
            for (block.terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
                canonicalize.visitBranchAddresses(function, branch.*, &uses, DeadUses.address);
            };
        }
        block.instructions.clearRetainingCapacity();
        block.terminator = .diverge;
    };
    const incoming = (try function.controlFlowEdges()).incoming;
    for (function.blocks.items, reachable, 0..) |block, kept, index| {
        if (!kept) continue;
        var position = block.parameters.items.len;
        while (position > 0) {
            position -= 1;
            if (!live[@backingInt(function.blocks.items[index].parameters.items[position])]) {
                const parameter = function.blocks.items[index].parameters.items[position];
                const data = function.definitions.items[@backingInt(parameter)].argument.data;
                for (incoming[index].items) |edge| {
                    const argument = function.branchArguments(edge.branch(function).*)[position];
                    uses.reference(argument.value);
                    if (data.representation != .value or !function.direct(data.type_id)) uses.address(argument.value);
                    if (function.definition(argument.value)) |definition| {
                        if (definition == .local_storage) changes.storage = true;
                    }
                }
                try function.removeParameter(@intCast(index), position, incoming[index].items);
                changes.changed = true;
            }
        }
    }
    changes.uses = uses.changed;
    if (changes.changed) function.invalidateOperands();
    return changes;
}

const DeadUses = struct {
    function: *const Function,
    live: []const bool,
    changed: bool = false,

    fn address(self: *DeadUses, value: ValueId) void {
        if (self.live[@backingInt(value)]) self.changed = true;
    }

    fn reference(self: *DeadUses, value: ValueId) void {
        if (self.changed or !self.live[@backingInt(value)]) return;
        // Storage eligibility is tracked separately. Other use counts matter
        // only for splitting variant block parameters; immutable snapshots do
        // not need another round merely because an unused reader disappeared.
        const definition = self.function.definitions.items[@backingInt(value)];
        if (definition == .argument and !definition.argument.data.type_id.isPrimitive()) self.changed = true;
    }
};

fn remapTargets(terminator: *Terminator, block_map: []const ?u32) void {
    switch (terminator.*) {
        .branch => |*branch| remapBlock(&branch.target, block_map),
        .predicate_branch => |*predicate| {
            remapBlock(&predicate.then_branch.target, block_map);
            remapBlock(&predicate.else_branch.target, block_map);
        },
        .return_unit, .return_value, .diverge => {},
    }
}

fn remapBlock(block: *BlockId, block_map: []const ?u32) void {
    block.* = @fromBackingInt(block_map[@backingInt(block.*)].?);
}

fn remapValue(value_map: []const ?u32, value: *ValueId) void {
    value.* = @fromBackingInt(value_map[@backingInt(value.*)].?);
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
    const incoming = (try function.controlFlowEdges()).incoming;
    const tables = function_ir.tableView(function);
    for (function.blocks.items[function.entry].parameters.items) |parameter| liveness.mark(parameter);
    for (function.blocks.items, reachable) |*block, kept| {
        if (!kept) continue;
        for (block.instructions.items) |index| {
            if (!function.removed.items[index] and !removableWhenUnused(function, function.instructions.items[index]))
                liveness.mark(function.results.items[index]);
        }
        function_ir.visitTerminatorOperands(tables, &block.terminator, &liveness, Liveness.mark);
    }
    while (liveness.pending.pop()) |value| switch (function.definitions.items[@backingInt(value)]) {
        .instruction => |index| {
            std.debug.assert(!function.removed.items[index]);
            function_ir.visitInstructionReferences(tables, &function.instructions.items[index], &liveness, Liveness.mark);
        },
        .argument => |argument| {
            const position = std.mem.indexOfScalar(ValueId, function.blocks.items[argument.block].parameters.items, value).?;
            for (incoming[argument.block].items) |edge| {
                const branch = edge.branch(function);
                liveness.mark(function.branch_arguments.items[branch.arguments.start + position].value);
            }
        },
    };
    if (liveness.failed) |err| return err;
    return liveness.live;
}

pub fn removableWhenUnused(function: *const Function, instruction: Instruction) bool {
    return switch (instruction) {
        .numeric_binary, .numeric_unary => !instruction.numericMayTrap(),
        .const_numeric, .numeric_convert, .const_int, .const_int_literal, .const_string_literal, .const_static_string, .const_storage_cursor, .const_byte, .const_bool, .const_type, .const_unit, .const_none, .function_ref, .initializer_ref, .local_storage, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select, .aggregate, .variant_tag, .field_access, .borrow_address, .borrow_read, .storage_projection, .allocation_element, .array_element, .storage_cursor, .cursor_offset, .cursor_element => true,
        .divsi, .shli, .shrsi => |operands| if (function.definition(operands.rhs)) |rhs| rhs == .const_int and instruction.integerRhsIsValid(rhs.const_int) else false,
        inline .value_copy, .variant_coerce, .variant_extract => |operation| operation.destination == null,
        else => false,
    };
}

pub fn isScalar(type_id: structures.TypeId) bool {
    return type_id.numericType() != null or type_id == .bool;
}
