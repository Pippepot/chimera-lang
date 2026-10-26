const std = @import("std");
const structures = @import("../structures.zig");
const x86 = @import("x86_encoding.zig");

const Body = structures.FunctionBodyAnalysis;
const ValueId = structures.FunctionValueId;
const Register = x86.Register;
const BitSet = std.DynamicBitSetUnmanaged;

pub const Allocation = struct {
    registers: []?Register,
    used: []const Register,

    pub fn deinit(self: *Allocation, gpa: std.mem.Allocator) void {
        gpa.free(self.registers);
        gpa.free(self.used);
        self.* = undefined;
    }
};

const Interval = struct { start: u32 = std.math.maxInt(u32), end: u32 = 0 };

pub fn emissionBlock(body: *const Body, position: usize) usize {
    if (position == 0) return @backingInt(body.entry);
    const index = position - 1;
    return index + @intFromBool(index >= @backingInt(body.entry));
}

const References = struct {
    body: *const Body,

    fn instruction(self: References, index: usize, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
        var copy = self.body.instructions[index];
        for (copy.operands()) |operand| if (operand) |value| visit(context, value.*);
        switch (copy) {
            .call => |operation| self.callArguments(operation, context, visit),
            .initializer_ref => |reference| for (self.body.initializer_captures[reference.captures.start..reference.captures.end]) |capture| visit(context, capture),
            .aggregate => |aggregate| for (self.body.aggregate_fields[aggregate.fields.start..aggregate.fields.end]) |field| visit(context, field),
            else => {},
        }
    }

    fn callArguments(self: References, operation: structures.FunctionCall, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
        for (self.body.call_arguments[operation.arguments.start..operation.arguments.end]) |argument| visit(context, argument.valueId());
    }

    fn terminator(self: References, block: usize, context: anytype, comptime visit: fn (@TypeOf(context), ValueId) void) void {
        var copy = self.body.blocks[block].terminator;
        for (copy.operands()) |operand| if (operand) |value| visit(context, value.*);
        for (copy.branches()) |maybe_branch| if (maybe_branch) |branch| {
            for (self.body.branch_arguments[branch.arguments.start..branch.arguments.end]) |argument| visit(context, argument.value);
        };
    }
};

const Scan = struct {
    mapping: []const ?u32,
    defined: *BitSet,
    uses: *BitSet,
    intervals: []Interval,
    weights: []u64,
    position: u32 = 0,
    weight: u64 = 1,

    fn use(self: *Scan, value: ValueId) void {
        const index = self.mapping[@backingInt(value)] orelse return;
        if (!self.defined.isSet(index)) self.uses.set(index);
        self.extend(index);
        self.weights[index] +|= self.weight;
    }

    fn extend(self: *Scan, value: u32) void {
        const interval = &self.intervals[value];
        interval.start = @min(interval.start, self.position * 2);
        interval.end = @max(interval.end, self.position * 2);
    }
};

pub fn allocate(gpa: std.mem.Allocator, body: *const Body, candidate: []const bool) !Allocation {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const block_count = body.blocks.len;
    const value_count = body.valueCount();
    const mapping = try scratch.alloc(?u32, value_count);
    @memset(mapping, null);
    const candidate_count = std.mem.count(bool, candidate, &.{true});
    const values = try scratch.alloc(u32, candidate_count);
    var next_value: u32 = 0;
    for (candidate, 0..) |allowed, index| if (allowed) {
        mapping[index] = next_value;
        values[next_value] = @intCast(index);
        next_value += 1;
    };
    const references: References = .{ .body = body };

    const starts = try scratch.alloc(u32, block_count);
    const ends = try scratch.alloc(u32, block_count);
    const emitted = try scratch.alloc(u32, block_count);
    var position: u32 = 0;
    for (0..block_count) |order| {
        const block = emissionBlock(body, order);
        emitted[block] = @intCast(order);
        starts[block] = position;
        position += body.blocks[block].instruction_end - body.blocks[block].instruction_start + 1;
        ends[block] = position;
        position += 1;
    }

    if (position > std.math.maxInt(u32) / 2) return error.FunctionTooLarge;
    const depth = try scratch.alloc(u32, position + 1);
    @memset(depth, 0);
    for (body.blocks, 0..) |block, index| {
        var terminator = block.terminator;
        for (terminator.successors()) |maybe_successor| if (maybe_successor) |successor| {
            const target = @backingInt(successor.*);
            if (emitted[target] > emitted[index]) continue;
            for (starts[target]..ends[index] + 1) |covered| depth[covered] += 1;
        };
    }

    const intervals = try scratch.alloc(Interval, candidate_count);
    @memset(intervals, .{});
    const weights = try scratch.alloc(u64, candidate_count);
    @memset(weights, 0);
    const uses = try scratch.alloc(BitSet, block_count);
    const defines = try scratch.alloc(BitSet, block_count);
    for (body.blocks, uses, defines, 0..) |block, *used, *defined, index| {
        used.* = try BitSet.initEmpty(scratch, candidate_count);
        defined.* = try BitSet.initEmpty(scratch, candidate_count);
        var scan: Scan = .{ .mapping = mapping, .defined = defined, .uses = used, .intervals = intervals, .weights = weights, .position = starts[index] };
        for (block.argument_start..block.argument_end) |argument| {
            if (mapping[argument]) |value| {
                defined.set(value);
                scan.extend(value);
            }
        }
        for (block.instruction_start..block.instruction_end) |instruction| {
            scan.position += 1;
            scan.weight = loopWeight(depth[scan.position]);
            references.instruction(instruction, &scan, Scan.use);
            const result = body.instructionValue(instruction);
            if (mapping[@backingInt(result)]) |value| {
                defined.set(value);
                // Read operands before defining the result, allowing last-use reuse.
                extendTo(&intervals[value], scan.position * 2 + 1);
                weights[value] +|= scan.weight;
            }
        }
        scan.position = ends[index];
        scan.weight = loopWeight(depth[scan.position]);
        references.terminator(index, &scan, Scan.use);
    }

    const live_in = try scratch.alloc(BitSet, block_count);
    const live_out = try scratch.alloc(BitSet, block_count);
    for (live_in, live_out) |*input, *output| {
        input.* = try BitSet.initEmpty(scratch, candidate_count);
        output.* = try BitSet.initEmpty(scratch, candidate_count);
    }
    var next = try BitSet.initEmpty(scratch, candidate_count);
    var incoming = try BitSet.initEmpty(scratch, candidate_count);
    var changed = true;
    while (changed) {
        changed = false;
        var order = block_count;
        while (order > 0) {
            order -= 1;
            const block = emissionBlock(body, order);
            var terminator = body.blocks[block].terminator;
            for (terminator.successors()) |maybe_successor| if (maybe_successor) |successor| {
                const target = @backingInt(successor.*);
                incoming.unsetAll();
                incoming.setUnion(live_in[target]);
                for (body.blocks[target].argument_start..body.blocks[target].argument_end) |argument| {
                    if (mapping[argument]) |value| incoming.unset(value);
                }
                live_out[block].setUnion(incoming);
            };
            next.unsetAll();
            next.setUnion(live_out[block]);
            var definitions = defines[block].iterator(.{});
            while (definitions.next()) |defined| next.unset(defined);
            next.setUnion(uses[block]);
            if (!next.eql(live_in[block])) {
                live_in[block].unsetAll();
                live_in[block].setUnion(next);
                changed = true;
            }
        }
    }
    for (0..block_count) |block| {
        var inputs = live_in[block].iterator(.{});
        while (inputs.next()) |value| extendTo(&intervals[value], starts[block] * 2);
        var outputs = live_out[block].iterator(.{});
        while (outputs.next()) |value| extendTo(&intervals[value], ends[block] * 2);
    }

    var order: std.ArrayList(u32) = .empty;
    for (intervals, 0..) |interval, value| if (interval.start <= interval.end) try order.append(scratch, @intCast(value));
    std.mem.sort(u32, order.items, weights, heavierFirst);
    const available = std.enums.values(Register);
    const assigned = try scratch.alloc(std.ArrayList(Interval), available.len);
    @memset(assigned, .empty);
    const registers = try gpa.alloc(?Register, value_count);
    errdefer gpa.free(registers);
    @memset(registers, null);
    for (order.items) |value| {
        const interval = intervals[value];
        choice: for (available, assigned) |register, *taken| {
            for (taken.items) |other| if (interval.start <= other.end and other.start <= interval.end) continue :choice;
            try taken.append(scratch, interval);
            registers[values[value]] = register;
            break;
        }
    }
    var used: std.ArrayList(Register) = .empty;
    defer used.deinit(gpa);
    for (available, assigned) |register, taken| if (taken.items.len != 0) try used.append(gpa, register);
    return .{ .registers = registers, .used = try used.toOwnedSlice(gpa) };
}

fn loopWeight(depth: u32) u64 {
    const exponent: u6 = @intCast(@min(depth, 6));
    return @as(u64, 1) << (exponent * 3);
}

fn extendTo(interval: *Interval, position: u32) void {
    interval.start = @min(interval.start, position);
    interval.end = @max(interval.end, position);
}

fn heavierFirst(weights: []const u64, left: u32, right: u32) bool {
    if (weights[left] != weights[right]) return weights[left] > weights[right];
    return left < right;
}
