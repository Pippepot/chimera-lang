const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;

pub const Resource = union(enum) {
    immutable,
    slot: ValueId,
    parameter,
    heap,
    unknown,
};

/// Addressable snapshots may still be immutable when their addresses remain
/// private and no instruction writes their storage. Heap contents are separate.
pub fn stableValues(function: *Function) ![]const bool {
    function.resolveReferences();
    const memory = try Memory.init(function);
    var writes: Writes = .{};
    for (function.blocks.items) |block| for (block.instructions.items) |index| {
        if (!function.removed.items[index]) try writes.instruction(function.scratch, &memory, function.instructions.items[index]);
    };
    const stable = try function.scratch.alloc(bool, function.valueCount());
    for (stable, 0..) |*value, index| {
        const id: ValueId = @fromBackingInt(@intCast(index));
        value.* = function.plainValue(id) and !memory.roots.address_taken[index];
        if (value.* or !function.plainValue(id)) continue;
        const root = memory.roots.root(id);
        value.* = root == .slot and !memory.slotExposed(root.slot) and !writes.slots.contains(root.slot);
    }
    return stable;
}

pub const Roots = struct {
    function: *Function,
    address_taken: []const bool,

    pub fn init(function: *Function) !Roots {
        return .{ .function = function, .address_taken = try canonicalize.addressTaken(function) };
    }

    pub fn root(self: *const Roots, value: ValueId) Resource {
        var current = value;
        for (0..64) |_| {
            switch (self.function.definitions.items[@backingInt(current)]) {
                .argument => |argument| {
                    if (argument.block == self.function.entry) return .parameter;
                    if (self.address_taken[@backingInt(current)]) return .{ .slot = current };
                    return if (self.function.directParameter(current)) .immutable else .unknown;
                },
                .instruction => |index| switch (self.function.instructions.items[index]) {
                    .local_storage => return .{ .slot = current },
                    .result_storage => return .parameter,
                    .storage_projection => |projection| switch (projection.projection) {
                        .field, .variant => current = projection.owner,
                        .allocation_array => return .heap,
                    },
                    .array_element => |element| current = element.array,
                    .allocation_element => return .heap,
                    .cursor_element => return .unknown,
                    .borrow_read => |read| return self.referent(read.source),
                    else => return if (self.address_taken[@backingInt(current)]) .{ .slot = current } else if (self.function.plainValue(current)) .immutable else .unknown,
                },
            }
        }
        return .unknown;
    }

    pub fn referent(self: *const Roots, reference: ValueId) Resource {
        const definition = self.function.definition(reference) orelse return .unknown;
        return switch (definition) {
            .borrow_address => |address| if (address.base_is_reference) self.referent(address.source) else self.root(address.source),
            else => .unknown,
        };
    }
};

pub const Memory = struct {
    roots: Roots,
    exposed: []bool,

    pub fn init(function: *Function) !Memory {
        const roots = try Roots.init(function);
        const exposed = try function.scratch.alloc(bool, function.valueCount());
        @memset(exposed, false);
        var memory: Memory = .{ .roots = roots, .exposed = exposed };
        for (function.blocks.items) |*block| {
            for (block.instructions.items) |index| {
                if (function.removed.items[index]) continue;
                switch (function.instructions.items[index]) {
                    .borrow_address => |address| if (!address.base_is_reference) memory.expose(address.source),
                    .storage_cursor => |cursor| memory.expose(cursor.source),
                    .initializer_ref => |reference| for (function.initializer_captures.items[reference.captures.start..reference.captures.end]) |capture| memory.expose(capture),
                    .call => |call| for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
                        if (argument != .prepared) memory.expose(argument.valueId());
                    },
                    else => {},
                }
            }
            var terminator = block.terminator;
            for (terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
                canonicalize.visitBranchAddresses(function, branch.*, &memory, Memory.expose);
            };
        }
        return memory;
    }

    fn expose(self: *Memory, value: ValueId) void {
        const resource = self.roots.root(value);
        if (resource == .slot) self.exposed[@backingInt(resource.slot)] = true;
    }

    pub fn slotExposed(self: *const Memory, slot: ValueId) bool {
        return self.exposed[@backingInt(slot)];
    }
};

pub const Writes = struct {
    slots: std.AutoHashMapUnmanaged(ValueId, void) = .empty,
    parameter: bool = false,
    heap: bool = false,
    unknown: bool = false,
    call: bool = false,

    pub fn add(self: *Writes, scratch: std.mem.Allocator, resource: Resource) !void {
        switch (resource) {
            .immutable => {},
            .slot => |slot| try self.slots.put(scratch, slot, {}),
            .parameter => self.parameter = true,
            .heap => self.heap = true,
            .unknown => self.unknown = true,
        }
    }

    pub fn instruction(self: *Writes, scratch: std.mem.Allocator, memory: *const Memory, operation: Instruction) !void {
        switch (operation) {
            inline .value_copy, .variant_coerce, .variant_extract, .static_conversion => |copy| if (copy.destination) |destination| try self.add(scratch, memory.roots.root(destination)),
            .borrow_write => |write| try self.add(scratch, memory.roots.referent(write.reference)),
            .fill => |fill| try self.add(scratch, memory.roots.root(fill.first)),
            .move => |move| try self.add(scratch, memory.roots.root(move.destination)),
            .call => |call| {
                self.call = true;
                if (call.destination) |destination| try self.add(scratch, memory.roots.root(destination));
            },
            else => {},
        }
    }

    pub fn preserves(self: *const Writes, memory: *const Memory, resource: Resource) bool {
        return switch (resource) {
            .immutable => true,
            .slot => |slot| !self.slots.contains(slot) and (!memory.slotExposed(slot) or !(self.unknown or self.call)),
            .parameter, .heap => !(self.parameter or self.heap or self.unknown or self.call),
            .unknown => !(self.parameter or self.heap or self.unknown or self.call) and self.slots.count() == 0,
        };
    }
};
