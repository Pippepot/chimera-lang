const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Terminator = structures.FunctionTerminator;
const Range = structures.FunctionValueRange;
const SourceSpan = structures.SourceSpan;
const InlineFrameId = structures.InlineFrameId;
const Function = function_ir.Function;

pub const Callee = struct {
    instance: structures.InstanceId,
    body: *const Body,
    region: bool = false,
    captures: []const ValueId = &.{},
    entry_taken: []const bool = &.{},
};

const Facts = struct {
    eligible: bool,
    entry_taken: []const bool = &.{},
};

const Cache = struct {
    bodies: std.AutoHashMapUnmanaged(structures.InstanceId, ?*const Body) = .empty,
    facts: std.AutoHashMapUnmanaged(*const Body, Facts) = .empty,
    limit: ?u32 = null,

    fn body(self: *Cache, scratch: std.mem.Allocator, context: anytype, instance: structures.InstanceId) !?*const Body {
        const entry = try self.bodies.getOrPut(scratch, instance);
        if (!entry.found_existing) entry.value_ptr.* = try context.inlineBody(instance);
        return entry.value_ptr.*;
    }

    fn analyze(self: *Cache, scratch: std.mem.Allocator, callee: *const Body) !Facts {
        const entry = try self.facts.getOrPut(scratch, callee);
        if (!entry.found_existing) entry.value_ptr.* = try analyzeCallee(scratch, callee);
        return entry.value_ptr.*;
    }
};

fn analyzeCallee(scratch: std.mem.Allocator, body: *const Body) !Facts {
    var function = try Function.init(scratch, body, &.{});
    if (!try @import("graph.zig").dominatesUses(&function)) return .{ .eligible = false };
    const entry = @backingInt(body.entry);
    for (body.blocks) |*block| {
        var terminator = block.terminator;
        for (terminator.successors()) |successor| if (successor) |target| {
            if (@backingInt(target.*) == entry) return .{ .eligible = false };
        };
    }
    const taken = try canonicalize.addressTaken(&function);
    return .{ .eligible = true, .entry_taken = taken[body.blocks[entry].argument_start..body.blocks[entry].argument_end] };
}

pub fn inlineCalls(function: *Function, context: anytype) !bool {
    var cache: Cache = .{};
    var size = liveInstructions(function);
    const budget = @max(size * 4, size + 512);
    const reachable = (try function.controlFlowEdges()).reachable;
    var changed = false;
    var block: u32 = 0;
    while (block < function.blocks.items.len) : (block += 1) {
        if (block < reachable.len and !reachable[block]) continue;
        if (size > budget) break;
        var position: usize = 0;
        while (position < function.blocks.items[block].instructions.items.len) : (position += 1) {
            const index = function.blocks.items[block].instructions.items[position];
            if (function.removed.items[index]) continue;
            const instruction = function.instructions.items[index];
            if (instruction != .call) continue;
            const callee = (try candidate(function, context, &cache, instruction.call)) orelse continue;
            try inlineInstruction(function, context, block, position, index, callee);
            size += callee.body.instructions.len;
            changed = true;
            break;
        }
    }
    return changed;
}

fn liveInstructions(function: *const Function) usize {
    var count: usize = 0;
    for (function.removed.items) |removed| count += @intFromBool(!removed);
    return count;
}

pub fn cost(body: *const Body) usize {
    return body.instructions.len + body.blocks.len;
}

fn candidate(function: *Function, context: anytype, cache: *Cache, call: structures.FunctionCall) !?Callee {
    var callee: Callee = switch (call.target) {
        .direct => |instance| .{ .instance = instance, .body = (try cache.body(function.scratch, context, instance)) orelse return null },
        .initializer => |value| region: {
            const reference = function.definition(function.find(value)) orelse return null;
            if (reference != .initializer_ref) return null;
            const operation = reference.initializer_ref;
            const region = &function.regions.items[operation.region];
            break :region .{
                .instance = region.root_instance orelse function.root_instance orelse context.instance,
                .region = true,
                .body = region,
                .captures = function.initializer_captures.items[operation.captures.start..operation.captures.end],
            };
        },
        .indirect => return null,
    };
    const body = callee.body;
    if (cache.limit == null) cache.limit = try context.inlineLimit();
    if (cost(body) > cache.limit.?) return null;
    const facts = try cache.analyze(function.scratch, body);
    if (!facts.eligible) return null;
    callee.entry_taken = facts.entry_taken;
    return callee;
}

const Exit = struct {
    block: u32,
    parameter: bool,
    destination: ?ValueId,
};

fn inlineInstruction(function: *Function, context: anytype, block: u32, position: usize, index: u32, callee: Callee) !void {
    const call = function.instructions.items[index].call;
    const result = function.results.items[index];
    const tail = try function.splitBlock(block, position + 1);
    _ = function.blocks.items[block].instructions.pop();
    function.removed.items[index] = true;
    const span = function.instructionSpan(index);
    const frame = function.instructionFrame(index);
    const returns_value = call.destination == null and call.return_type != .unit and call.return_type != .never;
    var splice = try Splice.init(function, callee, span, frame, block);
    try splice.bindArguments(call, block);
    try splice.copyBody(.{ .block = tail, .parameter = returns_value, .destination = call.destination });
    if (returns_value) {
        const parameter = try function.addParameter(tail, .{ .type_id = call.return_type });
        function.replace(result, try materializeResult(function, context, tail, parameter, call.return_type, span, frame));
    } else if (call.return_type != .never) {
        function.replace(result, try function.insertInstruction(tail, 0, .const_unit, span, frame));
    }
}

fn materializeResult(function: *Function, context: anytype, block: u32, parameter: ValueId, type_id: structures.TypeId, span: SourceSpan, frame: InlineFrameId) !ValueId {
    if (!try context.passesIndirectly(type_id)) return parameter;
    const storage = try function.insertInstruction(block, 0, .{ .local_storage = type_id }, span, frame);
    _ = try function.insertInstruction(block, 1, .{ .value_copy = .{ .source = parameter, .type_id = type_id, .destination = storage } }, span, frame);
    return storage;
}

const Splice = struct {
    function: *Function,
    callee: *const Body,
    values: []ValueId,
    blocks: []u32,
    frames: []InlineFrameId,
    root: InlineFrameId,
    span: SourceSpan,
    region_offset: u32,
    region: bool,
    captures: []const ValueId,
    entry_taken: []const bool,

    fn init(function: *Function, callee: Callee, span: SourceSpan, parent: InlineFrameId, after: u32) !Splice {
        const scratch = function.scratch;
        const body = callee.body;
        var splice: Splice = .{
            .function = function,
            .callee = body,
            .values = try scratch.alloc(ValueId, body.valueCount()),
            .blocks = try scratch.alloc(u32, body.blocks.len),
            .frames = try scratch.alloc(InlineFrameId, body.inline_frames.len),
            .root = .root,
            .span = span,
            .region_offset = @intCast(function.regions.items.len),
            .region = callee.region,
            .captures = try scratch.dupe(ValueId, callee.captures),
            .entry_taken = callee.entry_taken,
        };
        if (function.publishes_spans) {
            splice.root = @fromBackingInt(@intCast(function.inline_frames.items.len));
            try function.inline_frames.append(scratch, .{ .instance = callee.instance, .call_span = span, .parent = parent });
            for (body.inline_frames, splice.frames) |inline_frame, *mapped| {
                mapped.* = @fromBackingInt(@intCast(function.inline_frames.items.len));
                try function.inline_frames.append(scratch, .{ .instance = inline_frame.instance, .call_span = inline_frame.call_span, .parent = splice.frame(inline_frame.parent) });
            }
        } else @memset(splice.frames, .root);
        for (body.initializer_regions) |region| {
            var owned = region;
            if (owned.root_instance == null) owned.root_instance = callee.instance;
            try function.regions.append(scratch, owned);
        }
        var previous = after;
        for (body.blocks, splice.blocks, 0..) |_, *mapped, index| {
            mapped.* = try function.addBlock(.diverge, splice.terminatorSpan(index), splice.terminatorFrame(index));
            try function.placeAfter(mapped.*, previous);
            previous = mapped.*;
        }
        for (body.blocks, 0..) |block, index| {
            if (index == @backingInt(body.entry)) continue;
            for (block.argument_start..block.argument_end) |argument| {
                splice.values[argument] = try function.addParameter(splice.blocks[index], body.block_arguments[argument]);
            }
        }
        return splice;
    }

    fn frame(self: *const Splice, original: InlineFrameId) InlineFrameId {
        if (!self.function.publishes_spans) return .root;
        return if (original == .root) self.root else self.frames[@backingInt(original)];
    }

    fn spanned(self: *const Splice) bool {
        return self.function.publishes_spans and self.callee.terminator_spans.len != 0;
    }

    fn instructionSpan(self: *const Splice, index: usize) SourceSpan {
        return if (self.spanned()) self.callee.instruction_spans[index] else self.span;
    }

    fn instructionFrame(self: *const Splice, index: usize) InlineFrameId {
        return if (self.spanned() and self.callee.instruction_frames.len != 0) self.frame(self.callee.instruction_frames[index]) else self.root;
    }

    fn terminatorSpan(self: *const Splice, index: usize) SourceSpan {
        return if (self.spanned()) self.callee.terminator_spans[index] else self.span;
    }

    fn terminatorFrame(self: *const Splice, index: usize) InlineFrameId {
        return if (self.spanned() and self.callee.terminator_frames.len != 0) self.frame(self.callee.terminator_frames[index]) else self.root;
    }

    fn bindArguments(self: *Splice, call: structures.FunctionCall, site: u32) !void {
        const function = self.function;
        const body = self.callee;
        const entry = body.blocks[@backingInt(body.entry)];
        const mapped_entry = self.blocks[@backingInt(body.entry)];
        if (self.region) {
            std.debug.assert(call.arguments.start == call.arguments.end);
            for (self.captures, entry.argument_start..) |capture, parameter| self.values[parameter] = capture;
            function.blocks.items[site].terminator = .{ .branch = .{ .target = @fromBackingInt(mapped_entry), .arguments = .{ .start = 0, .end = 0 } } };
            return;
        }
        const arguments = function.call_arguments.items[call.arguments.start..call.arguments.end];
        std.debug.assert(arguments.len == entry.argument_end - entry.argument_start);
        var routed: std.ArrayList(structures.FunctionValueUse) = .empty;
        for (arguments, self.entry_taken, entry.argument_start..) |argument, taken, parameter| {
            switch (argument) {
                .prepared => |prepared| if (prepared.coerce_to == null and !taken and function.plainValue(prepared.value)) {
                    self.values[parameter] = prepared.value;
                } else {
                    self.values[parameter] = try function.addParameter(mapped_entry, body.block_arguments[parameter]);
                    try routed.append(function.scratch, prepared);
                },
                .borrowed, .deinit, .initializer => |source| self.values[parameter] = source,
            }
        }
        function.blocks.items[site].terminator = .{ .branch = .{
            .target = @fromBackingInt(mapped_entry),
            .arguments = try function.appendBranchArguments(routed.items),
        } };
    }

    fn copyBody(self: *Splice, exit: Exit) !void {
        const function = self.function;
        const body = self.callee;
        const first: u32 = @intCast(function.instructions.items.len);
        for (body.blocks, 0..) |block, block_index| {
            for (block.instruction_start..block.instruction_end) |index| {
                var instruction = body.instructions[index];
                if (instruction == .initializer_capture_write) {
                    const write = instruction.initializer_capture_write;
                    instruction = .{ .value_copy = .{ .source = write.value, .type_id = write.type_id, .destination = @fromBackingInt(write.parameter_index) } };
                }
                if (instruction == .result_storage) {
                    if (exit.destination) |destination| {
                        self.values[@backingInt(body.instructionValue(index))] = destination;
                        continue;
                    }
                    const storage_type = instruction.result_storage;
                    instruction = .{ .local_storage = storage_type };
                }
                const copied = try function.newInstruction(instruction, self.instructionSpan(index), self.instructionFrame(index));
                try function.blocks.items[self.blocks[block_index]].instructions.append(function.scratch, copied);
                self.values[@backingInt(body.instructionValue(index))] = function.results.items[copied];
            }
        }
        for (function.instructions.items[first..]) |*instruction| try self.relocateInstruction(instruction);
        for (body.blocks, 0..) |block, block_index| try self.copyTerminator(block.terminator, self.blocks[block_index], exit);
    }

    fn value(self: *const Splice, original: ValueId) ValueId {
        return self.values[@backingInt(original)];
    }

    fn relocateInstruction(self: *Splice, instruction: *Instruction) !void {
        const function = self.function;
        const scratch = function.scratch;
        for (instruction.operands()) |operand| if (operand) |reference| {
            reference.* = self.value(reference.*);
        };
        switch (instruction.*) {
            .call => |*call| call.arguments = try self.callArguments(call.arguments),
            .initializer_ref => |*reference| {
                reference.captures = try self.valueRange(&function.initializer_captures, self.callee.initializer_captures, reference.captures);
                reference.region += self.region_offset;
            },
            .aggregate => |*aggregate| aggregate.fields = try self.valueRange(&function.aggregate_fields, self.callee.aggregate_fields, aggregate.fields),
            inline .variant_coerce, .variant_extract => |*operation| operation.tag_mapping = try self.tagMapping(operation.tag_mapping),
            .borrow_address => |*operation| {
                const start: u32 = @intCast(function.borrow_fields.items.len);
                try function.borrow_fields.appendSlice(scratch, self.callee.borrow_fields[operation.fields.start..operation.fields.end]);
                operation.fields = .{ .start = start, .end = @intCast(function.borrow_fields.items.len) };
            },
            .initializer_capture_write => unreachable,
            else => {},
        }
    }

    fn valueRange(self: *Splice, table: *std.ArrayList(ValueId), source: []const ValueId, range: Range) !Range {
        const start: u32 = @intCast(table.items.len);
        for (source[range.start..range.end]) |original| try table.append(self.function.scratch, self.value(original));
        return .{ .start = start, .end = @intCast(table.items.len) };
    }

    fn tagMapping(self: *Splice, mapping: ?Range) !?Range {
        const range = mapping orelse return null;
        const function = self.function;
        const start: u32 = @intCast(function.variant_coercion_tags.items.len);
        try function.variant_coercion_tags.appendSlice(function.scratch, self.callee.variant_coercion_tags[range.start..range.end]);
        return .{ .start = start, .end = @intCast(function.variant_coercion_tags.items.len) };
    }

    fn use(self: *Splice, original: structures.FunctionValueUse) !structures.FunctionValueUse {
        var mapped = original;
        mapped.value = self.value(original.value);
        mapped.variant_tag_mapping = try self.tagMapping(original.variant_tag_mapping);
        return mapped;
    }

    fn callArguments(self: *Splice, range: Range) !Range {
        const function = self.function;
        const start: u32 = @intCast(function.call_arguments.items.len);
        for (self.callee.call_arguments[range.start..range.end]) |original| {
            var argument = original;
            switch (argument) {
                .prepared => |*prepared| prepared.* = try self.use(prepared.*),
                .borrowed, .deinit, .initializer => |*source| source.* = self.value(source.*),
            }
            try function.call_arguments.append(function.scratch, argument);
        }
        return .{ .start = start, .end = @intCast(function.call_arguments.items.len) };
    }

    fn branch(self: *Splice, original: structures.FunctionBranch) !structures.FunctionBranch {
        const function = self.function;
        const start: u32 = @intCast(function.branch_arguments.items.len);
        for (self.callee.branch_arguments[original.arguments.start..original.arguments.end]) |argument| {
            const mapped = try self.use(argument);
            try function.branch_arguments.append(function.scratch, mapped);
        }
        return .{ .target = @fromBackingInt(self.blocks[@backingInt(original.target)]), .arguments = .{ .start = start, .end = @intCast(function.branch_arguments.items.len) } };
    }

    fn exitBranch(self: *Splice, exit: Exit, returned: ?structures.FunctionValueUse) !Terminator {
        const arguments: []const structures.FunctionValueUse = if (exit.parameter) &.{returned.?} else &.{};
        return .{ .branch = .{ .target = @fromBackingInt(exit.block), .arguments = try self.function.appendBranchArguments(arguments) } };
    }

    fn copyTerminator(self: *Splice, original: Terminator, block: u32, exit: Exit) !void {
        const function = self.function;
        const terminator: Terminator = switch (original) {
            .branch => |target| .{ .branch = try self.branch(target) },
            .predicate_branch => |predicate| .{ .predicate_branch = .{
                .operation = predicate.operation,
                .operands = .{ .lhs = self.value(predicate.operands.lhs), .rhs = self.value(predicate.operands.rhs) },
                .then_branch = try self.branch(predicate.then_branch),
                .else_branch = try self.branch(predicate.else_branch),
            } },
            .return_unit => try self.exitBranch(exit, null),
            .return_value => |returned| blk: {
                const mapped = try self.use(returned);
                if (exit.destination) |destination| {
                    try self.storeResult(block, mapped, destination);
                    break :blk try self.exitBranch(exit, null);
                }
                break :blk try self.exitBranch(exit, if (exit.parameter) mapped else null);
            },
            .diverge => .diverge,
        };
        function.blocks.items[block].terminator = terminator;
    }

    fn storeResult(self: *Splice, block: u32, returned: structures.FunctionValueUse, destination: ValueId) !void {
        const function = self.function;
        if (returned.coerce_to == null and returned.value == destination) return;
        const return_type = self.callee.return_type;
        const instruction: Instruction = if (returned.coerce_to) |target|
            .{ .variant_coerce = .{ .operand = returned.value, .target_type = target, .tag_mapping = returned.variant_tag_mapping.?, .destination = destination } }
        else
            .{ .value_copy = .{ .source = returned.value, .type_id = return_type, .destination = destination } };
        const target = &function.blocks.items[block];
        const copied = try function.newInstruction(instruction, target.span, target.frame);
        try function.blocks.items[block].instructions.append(function.scratch, copied);
    }
};
