const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const effects = @import("effects.zig");
const loops = @import("loops.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;

pub fn hoist(function: *Function) !bool {
    while (try loops.canonicalize(function)) {}
    const scratch = function.scratch;
    const graph = (try function.controlFlow()).*;
    const found = try loops.find(scratch, function, graph);
    var changed = try snapshotAllocationReads(function, found);
    const memory = try effects.Memory.init(function);
    const owner = try scratch.alloc(u32, function.instructions.items.len);
    @memset(owner, std.math.maxInt(u32));
    for (function.blocks.items, 0..) |block, index| for (block.instructions.items) |instruction| {
        owner[instruction] = @intCast(index);
    };
    for (found) |loop| {
        const preheader = loops.preheader(function, graph, loop) orelse continue;
        var writes: effects.Writes = .{};
        for (loop.blocks) |block| {
            for (function.blocks.items[block].instructions.items) |index| {
                if (!function.removed.items[index]) try writes.instruction(scratch, &memory, function.instructions.items[index]);
            }
        }
        var motion: Motion = .{ .function = function, .loop = loop, .memory = &memory, .writes = &writes, .owner = owner };
        for (loop.blocks) |block| {
            const instructions = &function.blocks.items[block].instructions;
            var kept: usize = 0;
            for (instructions.items) |index| {
                if (!function.removed.items[index] and motion.invariant(function.instructions.items[index], block == loop.header)) {
                    try function.blocks.items[preheader].instructions.append(scratch, index);
                    owner[index] = preheader;
                    motion.hoisted(function.results.items[index]);
                    changed = true;
                    continue;
                }
                instructions.items[kept] = index;
                kept += 1;
            }
            instructions.shrinkRetainingCapacity(kept);
        }
    }
    return changed;
}

/// Element addressing reads the descriptor at this point, independently of the
/// element index. Explicit reads let ordinary memory analysis move that load.
fn snapshotAllocationReads(function: *Function, found: []const loops.Loop) !bool {
    var changed = false;
    for (found) |loop| for (loop.blocks) |block| {
        var position: usize = 0;
        while (position < function.blocks.items[block].instructions.items.len) : (position += 1) {
            const index = function.blocks.items[block].instructions.items[position];
            const instruction = function.instructions.items[index];
            if (function.removed.items[index] or instruction != .allocation_element) continue;
            const allocation = function.find(instruction.allocation_element.allocation);
            if (function.plainValue(allocation)) continue;
            const snapshot = try function.insertInstruction(block, position, .{ .value_copy = .{
                .source = allocation,
                .type_id = function.valueType(allocation),
            } }, function.instructionSpan(index), function.instructionFrame(index));
            function.instructions.items[index].allocation_element.allocation = snapshot;
            position += 1;
            changed = true;
        }
    };
    return changed;
}

const Motion = struct {
    function: *Function,
    loop: loops.Loop,
    memory: *const effects.Memory,
    writes: *const effects.Writes,
    owner: []const u32,
    moved: std.AutoHashMapUnmanaged(ValueId, void) = .empty,
    outside: bool = true,

    fn hoisted(self: *Motion, value: ValueId) void {
        self.moved.put(self.function.scratch, value, {}) catch {};
    }

    fn defined(self: *Motion, value: ValueId) void {
        if (self.moved.contains(value)) return;
        const block = switch (self.function.definitions.items[@backingInt(value)]) {
            .argument => |argument| argument.block,
            .instruction => |index| self.blockOf(index),
        };
        if (self.loop.contains(block)) self.outside = false;
    }

    fn blockOf(self: *Motion, index: u32) u32 {
        return self.owner[index];
    }

    fn invariant(self: *Motion, instruction: Instruction, executes: bool) bool {
        const read = self.classify(instruction) orelse return false;
        self.outside = true;
        function_ir.visitInstructionReferences(function_ir.tableView(self.function), &instruction, self, defined);
        if (!self.outside) return false;
        const resource = switch (read) {
            .pure => return true,
            .read => |resource| resource,
        };
        if (!self.writes.preserves(self.memory, resource)) return false;
        return executes or resource == .slot or resource == .parameter or resource == .immutable;
    }

    const Read = union(enum) { pure, read: effects.Resource };

    fn classify(self: *Motion, instruction: Instruction) ?Read {
        const roots = &self.memory.roots;
        switch (instruction) {
            .const_int, .const_byte, .const_bool, .const_unit, .const_none, .function_ref, .addi, .subi, .muli, .negi, .byte_to_int, .compare, .select, .aggregate, .borrow_address, .storage_projection, .array_element, .borrow_read, .cursor_offset, .cursor_element => return .pure,
            .divsi => |operands| {
                const divisor = self.function.definition(operands.rhs) orelse return null;
                return if (divisor == .const_int and divisor.const_int != 0) .pure else null;
            },
            .field_access => |operation| return .{ .read = roots.root(operation.operand) },
            .value_copy => |copy| return if (copy.destination == null) .{ .read = roots.root(copy.source) } else null,
            .variant_tag => |operand| return .{ .read = roots.root(operand) },
            inline .variant_extract, .variant_coerce => |operation| return if (operation.destination == null) .{ .read = roots.root(operation.operand) } else null,
            .allocation_element => |element| return .{ .read = roots.root(element.allocation) },
            else => return null,
        }
    }
};
