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

pub const Facts = struct {
    eligible: bool,
    entry_taken: []const bool = &.{},
    normal_return_ranges: []const ?@import("ranges.zig").Interval = &.{},
};

/// Constants copied from callees live once in the entry block, which dominates
/// every use, instead of once per inlined body.
const Constants = struct {
    const Context = struct {
        pub fn hash(_: Context, instruction: Instruction) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, instruction);
            return hasher.final();
        }

        pub fn eql(_: Context, left: Instruction, right: Instruction) bool {
            return std.meta.eql(left, right);
        }
    };

    values: std.HashMapUnmanaged(Instruction, ValueId, Context, 80) = .empty,
    inserted: usize = 0,

    fn shareable(instruction: Instruction) bool {
        return switch (instruction) {
            .const_numeric, .const_int, .const_byte, .const_bool, .const_unit, .const_none => true,
            else => false,
        };
    }

    fn get(self: *Constants, function: *Function, instruction: Instruction, span: SourceSpan, frame: InlineFrameId) !ValueId {
        const entry = try self.values.getOrPut(function.scratch, instruction);
        if (!entry.found_existing) {
            entry.value_ptr.* = try function.insertInstruction(function.entry, 0, instruction, span, frame);
            self.inserted += 1;
        }
        return entry.value_ptr.*;
    }
};

/// Callee resolutions for one optimization of a function. Callee identity and
/// eligibility do not change as the caller simplifies; inserted constants do.
pub const Cache = struct {
    bodies: std.AutoHashMapUnmanaged(structures.InstanceId, ?*const Body) = .empty,
    facts: std.AutoHashMapUnmanaged(*const Body, Facts) = .empty,
    instance_facts: std.AutoHashMapUnmanaged(structures.InstanceId, ?Facts) = .empty,
    constants: Constants = .{},
    limit: ?u32 = null,

    pub fn body(self: *Cache, scratch: std.mem.Allocator, context: anytype, instance: structures.InstanceId) !?*const Body {
        const entry = try self.bodies.getOrPut(scratch, instance);
        if (!entry.found_existing) entry.value_ptr.* = try context.inlineBody(instance);
        return entry.value_ptr.*;
    }

    pub fn instanceFacts(self: *Cache, scratch: std.mem.Allocator, context: anytype, instance: structures.InstanceId) !?Facts {
        const entry = try self.instance_facts.getOrPut(scratch, instance);
        if (!entry.found_existing) entry.value_ptr.* = try context.inlineFacts(instance);
        return entry.value_ptr.*;
    }

    pub fn analyze(self: *Cache, scratch: std.mem.Allocator, callee: *const Body) !Facts {
        const entry = try self.facts.getOrPut(scratch, callee);
        if (!entry.found_existing) entry.value_ptr.* = try analyzeCallee(scratch, callee);
        return entry.value_ptr.*;
    }
};

pub fn analyzeCallee(scratch: std.mem.Allocator, body: *const Body) !Facts {
    var function = try Function.init(scratch, body, &.{});
    if (!try @import("graph.zig").dominatesUses(&function)) return .{ .eligible = false };
    const entry = @backingInt(body.entry);
    for (0..body.blocks.len) |block| for (function.successors(@intCast(block))) |successor| {
        if (successor == entry) return .{ .eligible = false };
    };
    const taken = try canonicalize.addressTaken(&function);
    const entry_taken = taken[body.blocks[entry].argument_start..body.blocks[entry].argument_end];
    const parameters = function.blocks.items[entry].parameters.items;
    for (parameters, entry_taken) |parameter, exposed| {
        if (!exposed and function.valueType(parameter) == .int and function.plainValue(parameter)) break;
    } else return .{ .eligible = true, .entry_taken = entry_taken };
    const loops = @import("loops.zig");
    const graph = (try function.controlFlow()).*;
    const analysis = try loops.Analysis.init(&function, graph, &.{});
    const ranges = try scratch.alloc(?@import("ranges.zig").Interval, parameters.len);
    @memset(ranges, null);
    for (graph.order) |block| {
        switch (function.blocks.items[block].terminator) {
            .return_unit, .return_value => {},
            else => continue,
        }
        for (parameters, entry_taken, ranges) |parameter, exposed, *range| {
            if (exposed or function.valueType(parameter) != .int or !function.plainValue(parameter)) continue;
            const found = analysis.rangeAt(parameter, block, 16);
            if (range.*) |previous| {
                range.* = .{ .lower = @min(previous.lower, found.lower), .upper = @max(previous.upper, found.upper) };
            } else range.* = found;
        }
    }
    var narrowed = false;
    for (ranges) |*range| {
        if (range.*) |found| {
            if (found.lower == std.math.minInt(i32) and found.upper == std.math.maxInt(i32)) {
                range.* = null;
            } else narrowed = true;
        }
    }
    return .{ .eligible = true, .entry_taken = entry_taken, .normal_return_ranges = if (narrowed) ranges else &.{} };
}

pub fn growthBudget(function: *const Function) usize {
    const size = liveInstructions(function);
    return @max(size * 4, size + 512);
}

pub fn inlineCalls(function: *Function, context: anytype, budget: usize, cache: *Cache) !bool {
    cache.constants = .{};
    var size = liveInstructions(function);
    const reachable = (try function.controlFlowEdges()).reachable;
    var changed = false;
    var block: u32 = 0;
    while (block < function.blocks.items.len) : (block += 1) {
        if (block < reachable.len and !reachable[block]) continue;
        if (size > budget) break;
        var position: usize = 0;
        while (position < function.blocks.items[block].instructions.items.len) {
            const index = function.blocks.items[block].instructions.items[position];
            const instruction = function.instructions.items[index];
            const callee = if (!function.removed.items[index] and instruction == .call)
                try candidate(function, context, cache, instruction.call)
            else
                null;
            if (callee == null or callee.?.body.instructions.len > budget -| size) {
                position += 1;
                continue;
            }
            const straight = straightLine(function, instruction.call, callee.?);
            const shared = cache.constants.inserted;
            if (straight) try inlineStraight(function, context, cache, block, position, index, callee.?) else try inlineInstruction(function, context, cache, block, position, index, callee.?);
            // Constants inserted at the start of the entry block shift this scan.
            if (block == function.entry) position += cache.constants.inserted - shared;
            size += callee.?.body.instructions.len;
            changed = true;
            // A straight-line splice leaves the remaining calls in this block.
            if (!straight or size > budget) break;
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
    var total = body.blocks.len;
    for (body.instructions) |instruction| {
        total += switch (instruction) {
            .const_numeric, .const_int, .const_bool, .const_byte, .const_unit, .const_none => 0,
            else => @as(usize, 1),
        };
    }
    return total;
}

fn candidate(function: *Function, context: anytype, cache: *Cache, call: structures.FunctionCall) !?Callee {
    var callee: Callee = switch (call.target) {
        .direct => |instance| .{ .instance = instance, .body = (try cache.body(function.scratch, context, instance)) orelse return null },
        .initializer => |value| region: {
            const reference = function.definition(function.find(value)) orelse return null;
            if (reference != .initializer_ref) return null;
            const operation = reference.initializer_ref;
            // Inlining appends nested regions and may relocate the region table.
            // The selected body's header must remain stable throughout the splice.
            const region = try function.scratch.create(Body);
            region.* = function.regions.items[operation.region];
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
    if (body.instructions.len + body.blocks.len > cache.limit.?) {
        for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
            if (argument != .prepared) continue;
            const type_id = function.valueType(function.find(argument.valueId()));
            if (!type_id.isPrimitive() and function.direct(type_id)) break;
        } else return null;
        if (cost(body) > cache.limit.?) return null;
    }
    const facts = if (@hasDecl(@TypeOf(context), "inlineFacts") and !callee.region)
        (try cache.instanceFacts(function.scratch, context, callee.instance)) orelse return null
    else
        try cache.analyze(function.scratch, body);
    if (!facts.eligible) return null;
    callee.entry_taken = facts.entry_taken;
    return callee;
}

const Exit = struct {
    block: u32,
    parameter: bool,
    destination: ?ValueId,
};

fn inlineInstruction(function: *Function, context: anytype, cache: *Cache, block: u32, position: usize, index: u32, callee: Callee) !void {
    const call = function.instructions.items[index].call;
    const result = function.results.items[index];
    const tail = try function.splitBlock(block, position + 1);
    _ = function.blocks.items[block].instructions.pop();
    function.removed.items[index] = true;
    const span = function.instructionSpan(index);
    const frame = function.instructionFrame(index);
    const returns_value = call.destination == null and call.return_type != .unit and call.return_type != .never;
    var splice = try Splice.init(function, callee, span, frame, block, null);
    splice.constants = &cache.constants;
    try splice.bindArguments(call, block);
    try splice.copyBody(.{ .block = tail, .parameter = returns_value, .destination = call.destination });
    if (returns_value) {
        const parameter = try function.addParameter(tail, .{ .type_id = call.return_type });
        function.replace(result, try materializeResult(function, context, tail, 0, parameter, call.return_type, span, frame));
    } else if (call.return_type != .never) {
        function.replace(result, try function.insertInstruction(tail, 0, .const_unit, span, frame));
    }
}

/// A single-block callee that returns directly and routes no arguments splices
/// into the call's block, avoiding a continuation block and join parameter.
fn straightLine(function: *const Function, call: structures.FunctionCall, callee: Callee) bool {
    const body = callee.body;
    if (callee.region or body.blocks.len != 1) return false;
    switch (body.blocks[0].terminator) {
        .return_unit => {},
        .return_value => |returned| if (returned.coerce_to != null) return false,
        else => return false,
    }
    const arguments = function.call_arguments.items[call.arguments.start..call.arguments.end];
    for (arguments, callee.entry_taken) |argument, taken| switch (argument) {
        .prepared => |prepared| if (prepared.coerce_to != null or taken or !function.plainValue(prepared.value)) return false,
        .borrowed, .deinit, .initializer => {},
    };
    return true;
}

fn inlineStraight(function: *Function, context: anytype, cache: *Cache, block: u32, position: usize, index: u32, callee: Callee) !void {
    const call = function.instructions.items[index].call;
    const result = function.results.items[index];
    const instructions = &function.blocks.items[block].instructions;
    const rest = try function.scratch.dupe(u32, instructions.items[position + 1 ..]);
    instructions.shrinkRetainingCapacity(position);
    function.removed.items[index] = true;
    const span = function.instructionSpan(index);
    const frame = function.instructionFrame(index);
    var splice = try Splice.init(function, callee, span, frame, block, block);
    splice.constants = &cache.constants;
    const body = callee.body;
    const arguments = function.call_arguments.items[call.arguments.start..call.arguments.end];
    for (arguments, body.blocks[0].argument_start..) |argument, parameter| splice.values[parameter] = switch (argument) {
        .prepared => |prepared| prepared.value,
        .borrowed, .deinit, .initializer => |source| source,
    };
    try splice.copyInstructions(call.destination);
    const returned: ?structures.FunctionValueUse = switch (body.blocks[0].terminator) {
        .return_value => |returned| try splice.use(returned),
        else => null,
    };
    const returns_value = call.destination == null and call.return_type != .unit and call.return_type != .never;
    if (call.destination) |destination| {
        if (returned) |value| try splice.storeResult(block, value, destination);
    }
    const end = function.blocks.items[block].instructions.items.len;
    if (returns_value) {
        // A returned place is read where the call stood, as the join parameter would have.
        const value = returned.?.value;
        const direct = !try context.passesIndirectly(call.return_type);
        const snapshot = if (direct and !function.plainValue(value))
            try function.insertInstruction(block, end, .{ .value_copy = .{ .source = value, .type_id = call.return_type, .destination = null } }, span, frame)
        else
            value;
        const after = end + @intFromBool(snapshot != value);
        function.replace(result, try materializeResult(function, context, block, after, snapshot, call.return_type, span, frame));
    } else if (call.return_type != .never) {
        function.replace(result, try function.insertInstruction(block, end, .const_unit, span, frame));
    }
    try function.blocks.items[block].instructions.appendSlice(function.scratch, rest);
}

fn materializeResult(function: *Function, context: anytype, block: u32, position: usize, parameter: ValueId, type_id: structures.TypeId, span: SourceSpan, frame: InlineFrameId) !ValueId {
    if (!try context.passesIndirectly(type_id)) return parameter;
    const storage = try function.insertInstruction(block, position, .{ .local_storage = type_id }, span, frame);
    _ = try function.insertInstruction(block, position + 1, .{ .value_copy = .{ .source = parameter, .type_id = type_id, .destination = storage } }, span, frame);
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
    constants: ?*Constants = null,

    fn init(function: *Function, callee: Callee, span: SourceSpan, parent: InlineFrameId, after: u32, reuse: ?u32) !Splice {
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
            if (reuse) |existing| {
                mapped.* = existing;
                continue;
            }
            const source = splice.origin(body.terminator_spans, body.terminator_frames, index);
            mapped.* = try function.addBlock(.diverge, source.span, source.frame);
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

    const Origin = struct { span: SourceSpan, frame: InlineFrameId };

    fn origin(self: *const Splice, spans: []const SourceSpan, frames: []const InlineFrameId, index: usize) Origin {
        if (!self.function.publishes_spans or self.callee.terminator_spans.len == 0) return .{ .span = self.span, .frame = self.root };
        return .{ .span = spans[index], .frame = if (frames.len != 0) self.frame(frames[index]) else self.root };
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
        try self.copyInstructions(exit.destination);
        for (self.callee.blocks, 0..) |block, block_index| try self.copyTerminator(block.terminator, self.blocks[block_index], exit);
    }

    fn copyInstructions(self: *Splice, destination: ?ValueId) !void {
        const function = self.function;
        const body = self.callee;
        const first: u32 = @intCast(function.instructions.items.len);
        for (body.blocks, 0..) |block, block_index| {
            for (block.instruction_start..block.instruction_end) |index| {
                var instruction = body.instructions[index];
                if (instruction == .result_storage) {
                    if (destination) |target| {
                        self.values[@backingInt(body.instructionValue(index))] = target;
                        continue;
                    }
                    const storage_type = instruction.result_storage;
                    instruction = .{ .local_storage = storage_type };
                }
                const source = self.origin(body.instruction_spans, body.instruction_frames, index);
                if (self.constants) |constants| if (Constants.shareable(instruction)) {
                    self.values[@backingInt(body.instructionValue(index))] = try constants.get(function, instruction, source.span, source.frame);
                    continue;
                };
                const copied = try function.newInstruction(instruction, source.span, source.frame);
                try function.blocks.items[self.blocks[block_index]].instructions.append(function.scratch, copied);
                self.values[@backingInt(body.instructionValue(index))] = function.results.items[copied];
            }
        }
        for (function.instructions.items[first..]) |*instruction| try self.relocateInstruction(instruction);
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
            .borrow_address => |*operation| operation.fields = try function_ir.copyRange(structures.BorrowProjection, scratch, &function.borrow_fields, self.callee.borrow_fields, operation.fields),
            else => {},
        }
    }

    fn valueRange(self: *Splice, table: *std.ArrayList(ValueId), source: []const ValueId, range: Range) !Range {
        const start: u32 = @intCast(table.items.len);
        for (source[range.start..range.end]) |original| try table.append(self.function.scratch, self.value(original));
        return .{ .start = start, .end = @intCast(table.items.len) };
    }

    fn tagMapping(self: *Splice, mapping: ?Range) !?Range {
        const function = self.function;
        return try function_ir.copyRange(u32, function.scratch, &function.variant_coercion_tags, self.callee.variant_coercion_tags, mapping orelse return null);
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
        for (self.callee.branch_arguments[original.arguments.start..original.arguments.end]) |argument| try function.branch_arguments.append(function.scratch, try self.use(argument));
        return .{ .target = @fromBackingInt(self.blocks[@backingInt(original.target)]), .arguments = .{ .start = start, .end = @intCast(function.branch_arguments.items.len) } };
    }

    fn exitBranch(self: *Splice, exit: Exit, returned: ?structures.FunctionValueUse) !Terminator {
        const arguments: []const structures.FunctionValueUse = if (exit.parameter) &.{returned.?} else &.{};
        return .{ .branch = .{ .target = @fromBackingInt(exit.block), .arguments = try self.function.appendBranchArguments(arguments) } };
    }

    fn copyTerminator(self: *Splice, original: Terminator, block: u32, exit: Exit) !void {
        const function = self.function;
        var terminator = original;
        for (terminator.operands()) |operand| if (operand) |reference| {
            reference.* = self.value(reference.*);
        };
        for (terminator.branches()) |maybe_branch| if (maybe_branch) |edge| {
            edge.* = try self.branch(edge.*);
        };
        function.blocks.items[block].terminator = switch (original) {
            .branch, .predicate_branch, .diverge => terminator,
            .return_unit => try self.exitBranch(exit, null),
            .return_value => |returned| blk: {
                const mapped = try self.use(returned);
                if (exit.destination) |destination| {
                    try self.storeResult(block, mapped, destination);
                    break :blk try self.exitBranch(exit, null);
                }
                break :blk try self.exitBranch(exit, if (exit.parameter) mapped else null);
            },
        };
    }

    fn storeResult(self: *Splice, block: u32, returned: structures.FunctionValueUse, destination: ValueId) !void {
        const function = self.function;
        if (returned.coerce_to == null and returned.value == destination) return;
        const return_type = self.callee.return_type;
        const instruction: Instruction = if (returned.coerce_to) |target|
            .{ .variant_coerce = .{ .operand = returned.value, .target_type = target, .tag_mapping = returned.variant_tag_mapping.?, .destination = destination } }
        else
            .{ .value_copy = .{ .source = returned.value, .type_id = return_type, .destination = destination } };
        _ = try function.appendInstruction(block, instruction, function.blocks.items[block].span, function.blocks.items[block].frame);
    }
};
