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
    field: struct { slot: ValueId, index: u32 },
    parameter,
    heap,
    unknown,
};

/// Addressable snapshots may still be immutable when their addresses remain
/// private and no instruction writes their storage. Heap contents are separate.
/// The memory and write scans run on the first query of an addressable value.
pub const Stability = struct {
    function: *Function,
    memory: ?Memory = null,
    writes: ?Writes = null,

    fn scanMemory(self: *Stability) !*const Memory {
        if (self.memory == null) {
            self.function.resolveReferences();
            self.memory = try Memory.init(self.function);
        }
        return &self.memory.?;
    }

    /// Whether an addressable value's storage escapes, which makes it unstable
    /// without scanning for writes.
    pub fn exposed(self: *Stability, value: ValueId) !bool {
        const memory = try self.scanMemory();
        const index = @backingInt(value);
        if (index >= memory.roots.address_taken.len or !memory.roots.address_taken[index]) return false;
        const root = memory.roots.root(value);
        return if (Roots.slotOwner(root)) |slot| memory.slotExposed(slot) else true;
    }

    pub fn stable(self: *Stability, value: ValueId) !bool {
        const function = self.function;
        if (!function.plainValue(value)) return false;
        const memory = try self.scanMemory();
        if (self.writes == null) {
            var writes: Writes = .{};
            for (function.blocks.items) |block| for (block.instructions.items) |index| {
                if (!function.removed.items[index]) try writes.instruction(function.scratch, memory, function.instructions.items[index]);
            };
            self.writes = writes;
        }
        const index = @backingInt(value);
        if (index >= memory.roots.address_taken.len or !memory.roots.address_taken[index]) return true;
        const root = memory.roots.root(value);
        const slot = Roots.slotOwner(root) orelse return false;
        return !memory.slotExposed(slot) and self.writes.?.preserves(memory, root);
    }
};

pub const Roots = struct {
    function: *Function,
    address_taken: []const bool,

    pub fn init(function: *Function) !Roots {
        return .{ .function = function, .address_taken = try canonicalize.addressTaken(function) };
    }

    pub fn root(self: *const Roots, value: ValueId) Resource {
        var current = value;
        var field: ?u32 = null;
        for (0..64) |_| {
            switch (self.function.definitions.items[@backingInt(current)]) {
                .argument => |argument| {
                    if (argument.block == self.function.entry) return .parameter;
                    if (self.address_taken[@backingInt(current)]) return slotResource(current, field);
                    return if (self.function.directParameter(current)) .immutable else .unknown;
                },
                .instruction => |index| switch (self.function.instructions.items[index]) {
                    .local_storage => return slotResource(current, field),
                    .result_storage => return .parameter,
                    .storage_projection => |projection| switch (projection.projection) {
                        .field => |field_index| {
                            field = field_index;
                            current = projection.owner;
                        },
                        .variant => {
                            field = null;
                            current = projection.owner;
                        },
                        .allocation_array => return .heap,
                    },
                    .array_element => |element| current = element.array,
                    .allocation_element => return .heap,
                    .cursor_element => return .unknown,
                    .borrow_read => |read| return self.referent(read.source),
                    else => return if (self.address_taken[@backingInt(current)]) slotResource(current, field) else if (self.function.plainValue(current)) .immutable else .unknown,
                },
            }
        }
        return .unknown;
    }

    fn slotResource(slot: ValueId, field: ?u32) Resource {
        return if (field) |index| .{ .field = .{ .slot = slot, .index = index } } else .{ .slot = slot };
    }

    pub fn fieldResource(self: *const Roots, owner: ValueId, index: u32) Resource {
        const resource = self.root(owner);
        return if (resource == .slot) .{ .field = .{ .slot = resource.slot, .index = index } } else resource;
    }

    pub fn overlaps(first: Resource, second: Resource) bool {
        if (first == .immutable or second == .immutable) return false;
        if (first == .unknown or second == .unknown) return true;
        const first_slot = slotOwner(first);
        const second_slot = slotOwner(second);
        if (first_slot != null or second_slot != null) {
            if (first_slot == null or second_slot == null or first_slot.? != second_slot.?) return false;
            return first != .field or second != .field or first.field.index == second.field.index;
        }
        return true;
    }

    pub fn slotOwner(resource: Resource) ?ValueId {
        return switch (resource) {
            .slot => |value| value,
            .field => |value| value.slot,
            else => null,
        };
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
        if (Roots.slotOwner(resource)) |slot| self.exposed[@backingInt(slot)] = true;
    }

    pub fn slotExposed(self: *const Memory, slot: ValueId) bool {
        return self.exposed[@backingInt(slot)];
    }
};

pub const Writes = struct {
    slots: std.AutoHashMapUnmanaged(ValueId, void) = .empty,
    fields: std.AutoHashMapUnmanaged(@FieldType(Resource, "field"), void) = .empty,
    parameter: bool = false,
    heap: bool = false,
    unknown: bool = false,
    call: bool = false,

    pub fn add(self: *Writes, scratch: std.mem.Allocator, resource: Resource) !void {
        switch (resource) {
            .immutable => {},
            .slot => |slot| try self.slots.put(scratch, slot, {}),
            .field => |field| try self.fields.put(scratch, field, {}),
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
            .slot, .field => self.preservesSlot(memory, resource),
            .parameter, .heap => !(self.parameter or self.heap or self.unknown or self.call),
            .unknown => !(self.parameter or self.heap or self.unknown or self.call) and self.slots.count() == 0 and self.fields.count() == 0,
        };
    }

    fn preservesSlot(self: *const Writes, memory: *const Memory, resource: Resource) bool {
        const slot = Roots.slotOwner(resource).?;
        if (self.slots.contains(slot) or (memory.slotExposed(slot) and (self.unknown or self.call))) return false;
        if (resource == .field) return !self.fields.contains(resource.field);
        var fields = self.fields.keyIterator();
        while (fields.next()) |field| if (field.slot == slot) return false;
        return true;
    }
};
