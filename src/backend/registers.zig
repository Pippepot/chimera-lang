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
const Preference = struct { value: u32, weight: u64 };

pub fn allocate(gpa: std.mem.Allocator, function: *const machine.Function, value_count: usize) !Allocation {
    const registers = try gpa.alloc(?Register, value_count);
    errdefer gpa.free(registers);
    @memset(registers, null);
    var fixed: x86.RegisterSet = .empty;
    for (function.instructions.items) |instruction| if (instruction == .fixed) {
        fixed.setUnion(x86.fixedRegisters(instruction.fixed.operation));
    };
    var single_value: ?machine.ValueId = null;
    for (function.instructions.items) |instruction| {
        if (instruction == .parameter) break;
        if (instruction != .register) continue;
        if (single_value) |value| {
            if (instruction.register.value != value) break;
        } else single_value = instruction.register.value;
    } else {
        if (single_value) |value| {
            for (std.enums.values(Register)) |selected| {
                if (!selected.calleeSaved() or fixed.contains(selected)) continue;
                registers[@backingInt(value)] = selected;
                return .{ .registers = registers, .used = try gpa.dupe(Register, &.{selected}) };
            }
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
    for (instructions) |instruction| {
        const access = instruction.registerAccess() orelse continue;
        const value = @backingInt(access.value);
        if (mapping[value] != null) continue;
        mapping[value] = @intCast(values.items.len);
        try values.append(scratch, value);
    }
    const candidate_count = values.items.len;
    const parameters = try scratch.alloc(bool, candidate_count);
    @memset(parameters, false);
    for (instructions) |instruction| if (instruction == .parameter) {
        parameters[mapping[@backingInt(instruction.parameter.value)].?] = true;
    };
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
            const access = instruction.registerAccess() orelse continue;
            const value = mapping[@backingInt(access.value)].?;
            if (access.write) {
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
            const access = instruction.registerAccess() orelse continue;
            const value = mapping[@backingInt(access.value)].?;
            const position: u32 = @intCast(index * 2);
            if (access.write) {
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
    std.mem.sort(u32, order.items, Priority{ .weights = weights, .parameters = parameters }, heavierFirst);
    const available = std.enums.values(Register);
    const assigned = try scratch.alloc(std.ArrayList(Interval), available.len);
    @memset(assigned, .empty);
    for (instructions, 0..) |instruction, index| {
        if (instruction != .fixed) continue;
        const clobbered = x86.clobberedRegisters(instruction.fixed.operation);
        for (available, assigned) |register, *taken| {
            if (!clobbered.contains(register)) continue;
            const position: u32 = @intCast(index * 2);
            try taken.append(scratch, .{ .start = position, .end = position + 1 });
        }
    }
    const allocated = try scratch.alloc(bool, available.len);
    @memset(allocated, false);
    const preferences = try scratch.alloc(std.ArrayList(Preference), candidate_count);
    @memset(preferences, .empty);
    try collectPreferences(scratch, instructions, mapping, depth, preferences);
    for (order.items) |value| {
        var scores: [std.enums.values(Register).len]u64 = @splat(0);
        for (preferences[value].items) |preference| {
            const selected = registers[values.items[preference.value]] orelse continue;
            const index = std.mem.indexOfScalar(Register, available, selected).?;
            scores[index] +|= preference.weight;
        }
        var best: ?usize = null;
        for (available, assigned, 0..) |register, taken, index| {
            if (parameters[value] and register.calleeSaved()) continue;
            if (fixed.contains(register)) continue;
            if (overlap(ranges[value].items, taken.items)) continue;
            if (best == null or scores[index] > scores[best.?]) best = index;
        }
        const selected = best orelse continue;
        try assigned[selected].appendSlice(scratch, ranges[value].items);
        normalizeRanges(&assigned[selected]);
        registers[values.items[value]] = available[selected];
        allocated[selected] = true;
    }
    var used: std.ArrayList(Register) = .empty;
    defer used.deinit(gpa);
    for (available, allocated) |register, taken| if (taken) try used.append(gpa, register);
    return .{ .registers = registers, .used = try used.toOwnedSlice(gpa) };
}

// These are allocation preferences, not aliases: every choice still has to
// satisfy the complete expanded-stream liveness and fixed-register constraints.
fn collectPreferences(allocator: std.mem.Allocator, instructions: []const machine.Instruction, mapping: []const ?u32, depth: []const u32, preferences: []std.ArrayList(Preference)) !void {
    for (instructions, 0..) |instruction, index| {
        if (instruction != .register or instruction.register.operation != .load_eax) continue;
        if (index + 2 >= instructions.len) continue;
        const lhs = instruction.register.value;
        var destination = index + 1;
        var rhs: ?machine.ValueId = null;
        switch (instructions[destination]) {
            .fixed => |operation| {
                switch (operation.operation) {
                    .add_eax, .sub_eax, .imul_eax, .add_eax_rsp, .sub_eax_rsp, .imul_eax_rsp => destination += 1,
                    else => continue,
                }
            },
            .register => |operation| {
                switch (operation.operation) {
                    .store_eax => {},
                    .add_eax, .imul_eax => {
                        rhs = operation.value;
                        destination += 1;
                    },
                    .sub_eax => destination += 1,
                    else => continue,
                }
            },
            else => continue,
        }
        if (destination + 1 >= instructions.len) continue;
        if (instructions[destination] != .register or instructions[destination].register.operation != .store_eax) continue;
        if (instructions[destination + 1] != .scratch_dead) continue;
        const result = instructions[destination].register.value;
        try prefer(allocator, mapping, preferences, lhs, result, loopWeight(depth[index]));
        if (rhs) |value| try prefer(allocator, mapping, preferences, value, result, loopWeight(depth[index]));
    }
}

fn prefer(allocator: std.mem.Allocator, mapping: []const ?u32, preferences: []std.ArrayList(Preference), lhs: machine.ValueId, rhs: machine.ValueId, weight: u64) !void {
    const left = mapping[@backingInt(lhs)].?;
    const right = mapping[@backingInt(rhs)].?;
    if (left == right) return;
    try preferences[left].append(allocator, .{ .value = right, .weight = weight });
    try preferences[right].append(allocator, .{ .value = left, .weight = weight });
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
        .jmp, .jl, .jg, .jle, .jge, .je, .jne, .ja, .jae, .jb, .jbe, .jo, .jno, .jp, .jnp, .js, .jns, .ret, .ud2 => true,
        else => false,
    };
}

fn loopWeight(depth: u32) u64 {
    const exponent: u6 = @intCast(@min(depth, 6));
    return @as(u64, 1) << (exponent * 3);
}

const Priority = struct { weights: []const u64, parameters: []const bool };

fn heavierFirst(priority: Priority, left: u32, right: u32) bool {
    if (priority.parameters[left] != priority.parameters[right]) return !priority.parameters[left];
    if (priority.weights[left] != priority.weights[right]) return priority.weights[left] > priority.weights[right];
    return left < right;
}
