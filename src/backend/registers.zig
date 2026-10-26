const std = @import("std");
const machine = @import("machine.zig");
const x86 = @import("x86_encoding.zig");

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

pub fn allocate(gpa: std.mem.Allocator, function: *const machine.Function, value_count: usize) !Allocation {
    const registers = try gpa.alloc(?Register, value_count);
    errdefer gpa.free(registers);
    @memset(registers, null);
    var single_value: ?machine.ValueId = null;
    for (function.instructions.items) |instruction| {
        if (instruction != .register) continue;
        if (single_value) |value| {
            if (instruction.register.value != value) break;
        } else single_value = instruction.register.value;
    } else {
        if (single_value) |value| {
            const selected = std.enums.values(Register)[0];
            registers[@backingInt(value)] = selected;
            return .{ .registers = registers, .used = try gpa.dupe(Register, &.{selected}) };
        }
        return .{ .registers = registers, .used = &.{} };
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();
    const instructions = function.instructions.items;
    if (instructions.len > std.math.maxInt(u32) / 2) return error.FunctionTooLarge;
    const boundaries = try scratch.alloc(bool, instructions.len + 1);
    @memset(boundaries, false);
    boundaries[0] = true;
    boundaries[instructions.len] = true;
    for (instructions, 0..) |instruction, index| {
        if (instruction != .fixed) continue;
        if (!isBranch(instruction.fixed.operation)) continue;
        if (instruction.fixed.target != 0) boundaries[instruction.fixed.target] = true;
        boundaries[index + 1] = true;
    }
    var starts: std.ArrayList(u32) = .empty;
    for (boundaries, 0..) |boundary, index| if (boundary) try starts.append(scratch, @intCast(index));
    const block_count = starts.items.len - 1;
    const block_at = try scratch.alloc(u32, instructions.len);
    for (0..block_count) |block| @memset(block_at[starts.items[block]..starts.items[block + 1]], @intCast(block));

    const mapping = try scratch.alloc(?u32, value_count);
    @memset(mapping, null);
    var values: std.ArrayList(u32) = .empty;
    for (instructions) |instruction| if (instruction == .register) {
        const value = @backingInt(instruction.register.value);
        if (mapping[value] != null) continue;
        mapping[value] = @intCast(values.items.len);
        try values.append(scratch, value);
    };
    const candidate_count = values.items.len;
    const depth = try scratch.alloc(u32, instructions.len);
    @memset(depth, 0);
    for (instructions, 0..) |instruction, index| {
        if (instruction != .fixed) continue;
        if (!isBranch(instruction.fixed.operation)) continue;
        if (instruction.fixed.target != 0) {
            const target = instruction.fixed.target;
            if (target > index) continue;
            for (depth[target .. index + 1]) |*covered| covered.* +|= 1;
        }
    }
    const weights = try scratch.alloc(u64, candidate_count);
    @memset(weights, 0);
    const uses = try scratch.alloc(BitSet, block_count);
    const defines = try scratch.alloc(BitSet, block_count);
    for (uses, defines, 0..) |*used, *defined, block| {
        used.* = try BitSet.initEmpty(scratch, candidate_count);
        defined.* = try BitSet.initEmpty(scratch, candidate_count);
        for (starts.items[block]..starts.items[block + 1]) |index| {
            const instruction = instructions[index];
            if (instruction != .register) continue;
            const value = mapping[@backingInt(instruction.register.value)].?;
            if (instruction.register.operation == .store_eax or instruction.register.operation == .store_rax) {
                defined.set(value);
            } else {
                if (!defined.isSet(value)) used.set(value);
            }
            weights[value] +|= loopWeight(depth[index]);
        }
    }

    const live_in = try scratch.alloc(BitSet, block_count);
    const live_out = try scratch.alloc(BitSet, block_count);
    for (live_in, live_out) |*input, *output| {
        input.* = try BitSet.initEmpty(scratch, candidate_count);
        output.* = try BitSet.initEmpty(scratch, candidate_count);
    }
    var next = try BitSet.initEmpty(scratch, candidate_count);
    var changed = true;
    while (changed) {
        changed = false;
        var order = block_count;
        while (order > 0) {
            order -= 1;
            const block = order;
            const last = instructions[starts.items[block + 1] - 1];
            var falls_through = true;
            if (last == .fixed and isBranch(last.fixed.operation)) {
                if (last.fixed.target != 0) {
                    const target = last.fixed.target;
                    if (target < instructions.len) live_out[block].setUnion(live_in[block_at[target]]);
                }
                falls_through = last.fixed.operation != .jmp and last.fixed.operation != .ret and last.fixed.operation != .ud2;
            }
            if (falls_through and block + 1 < block_count) {
                live_out[block].setUnion(live_in[block + 1]);
            }
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
    const ranges = try scratch.alloc(std.ArrayList(Interval), candidate_count);
    @memset(ranges, .empty);
    const range_ends = try scratch.alloc(u32, candidate_count);
    for (0..block_count) |block| {
        next.unsetAll();
        next.setUnion(live_out[block]);
        var outputs = next.iterator(.{});
        while (outputs.next()) |value| range_ends[value] = starts.items[block + 1] * 2;
        var index: usize = starts.items[block + 1];
        while (index > starts.items[block]) {
            index -= 1;
            const instruction = instructions[index];
            if (instruction != .register) continue;
            const value = mapping[@backingInt(instruction.register.value)].?;
            const position: u32 = @intCast(index * 2);
            if (instruction.register.operation == .store_eax or instruction.register.operation == .store_rax) {
                const end = if (next.isSet(value)) range_ends[value] else position + 1;
                try ranges[value].append(scratch, .{ .start = position + 1, .end = end });
                next.unset(value);
            } else if (!next.isSet(value)) {
                next.set(value);
                range_ends[value] = position;
            }
        }
        var inputs = next.iterator(.{});
        while (inputs.next()) |value| try ranges[value].append(scratch, .{ .start = starts.items[block] * 2, .end = range_ends[value] });
    }

    var order: std.ArrayList(u32) = .empty;
    for (ranges, 0..) |*value_ranges, value| {
        normalizeRanges(value_ranges);
        if (value_ranges.items.len != 0) try order.append(scratch, @intCast(value));
    }
    std.mem.sort(u32, order.items, weights, heavierFirst);
    const available = std.enums.values(Register);
    const assigned = try scratch.alloc(std.ArrayList(Interval), available.len);
    @memset(assigned, .empty);
    for (order.items) |value| {
        for (available, assigned) |register, *taken| {
            if (overlap(ranges[value].items, taken.items)) continue;
            try taken.appendSlice(scratch, ranges[value].items);
            normalizeRanges(taken);
            registers[values.items[value]] = register;
            break;
        }
    }
    var used: std.ArrayList(Register) = .empty;
    defer used.deinit(gpa);
    for (available, assigned) |register, taken| if (taken.items.len != 0) try used.append(gpa, register);
    return .{ .registers = registers, .used = try used.toOwnedSlice(gpa) };
}

fn normalizeRanges(ranges: *std.ArrayList(Interval)) void {
    std.mem.sort(Interval, ranges.items, {}, intervalBefore);
    var count: usize = 0;
    for (ranges.items) |interval| {
        if (count != 0 and interval.start <= ranges.items[count - 1].end) {
            ranges.items[count - 1].end = @max(ranges.items[count - 1].end, interval.end);
        } else {
            ranges.items[count] = interval;
            count += 1;
        }
    }
    ranges.items.len = count;
}

fn intervalBefore(_: void, left: Interval, right: Interval) bool {
    return left.start < right.start;
}

fn overlap(left: []const Interval, right: []const Interval) bool {
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        const left_range = left[left_index];
        const right_range = right[right_index];
        if (left_range.start <= right_range.end and right_range.start <= left_range.end) return true;
        if (left_range.end < right_range.end) {
            left_index += 1;
        } else {
            right_index += 1;
        }
    }
    return false;
}

fn isBranch(operation: x86.Operation) bool {
    return switch (operation) {
        .jmp, .jl, .jg, .jle, .jge, .je, .jne, .ret, .ud2 => true,
        else => false,
    };
}

fn loopWeight(depth: u32) u64 {
    const exponent: u6 = @intCast(@min(depth, 6));
    return @as(u64, 1) << (exponent * 3);
}

fn heavierFirst(weights: []const u64, left: u32, right: u32) bool {
    if (weights[left] != weights[right]) return weights[left] > weights[right];
    return left < right;
}
