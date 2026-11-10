const std = @import("std");
const structures = @import("../structures.zig");
const function_ir = @import("function.zig");
const canonicalize = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const Instruction = structures.FunctionInstruction;
const Function = function_ir.Function;

/// Raw backing can be adopted at another type or supplied from caller storage.
/// Allocation types and element shapes therefore provide no aliasing proof.
pub const Resource = union(enum) {
    contextual: structures.ContextEntry,
    immutable,
    slot: ValueId,
    field: struct { slot: ValueId, index: u32 },
    parameter: Parameter,
    heap,
    unknown,

    const Parameter = struct { value: ValueId, mutable: bool };
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
        while (true) {
            switch (self.function.definitions.items[@backingInt(current)]) {
                .argument => |argument| {
                    if (argument.block == self.function.entry) {
                        const position = std.mem.indexOfScalar(ValueId, self.function.blocks.items[self.function.entry].parameters.items, current).?;
                        return .{ .parameter = .{
                            .value = current,
                            .mutable = !self.function.is_initializer_region and position < self.function.parameter_modes.len and self.function.parameter_modes[position] == .mut,
                        } };
                    }
                    if (self.address_taken[@backingInt(current)]) return slotResource(current, field);
                    return if (self.function.directParameter(current)) .immutable else .unknown;
                },
                .instruction => |index| switch (self.function.instructions.items[index]) {
                    .local_storage => return slotResource(current, field),
                    .result_storage => return .unknown,
                    .storage_projection => |projection| {
                        switch (projection.projection) {
                            .field => |field_index| {
                                field = field_index;
                                current = projection.owner;
                            },
                            .variant => {
                                field = null;
                                current = projection.owner;
                            },
                            .allocation_array => return .heap,
                        }
                    },
                    .array_element => |element| {
                        current = element.array;
                    },
                    .allocation_element => return .heap,
                    .cursor_element => return .unknown,
                    .borrow_read => |read| return self.referent(read.source),
                    else => return if (self.address_taken[@backingInt(current)]) slotResource(current, field) else if (self.function.plainValue(current)) .immutable else .unknown,
                },
            }
        }
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
        if (first == .contextual or second == .contextual) return first == .contextual and second == .contextual and first.contextual == second.contextual;
        if (first == .parameter and second == .parameter and first.parameter.value != second.parameter.value and
            (first.parameter.mutable or second.parameter.mutable)) return false;
        const first_slot = slotOwner(first);
        const second_slot = slotOwner(second);
        if (first_slot != null or second_slot != null) {
            if (first_slot == null or second_slot == null) return true;
            if (first_slot.? != second_slot.?) return false;
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

    /// A borrowed field of a slot occupies that field alone. Reading fields of the
    /// borrowed value must not be mistaken for fields of the slot.
    fn borrowedRoot(self: *const Roots, address: structures.BorrowAddressOperation) Resource {
        const resource = self.root(address.source);
        if (resource != .slot) return resource;
        const path = self.function.borrow_fields.items[address.fields.start..address.fields.end];
        if (path.len == 0 or path[0] != .field) return resource;
        return .{ .field = .{ .slot = resource.slot, .index = path[0].field } };
    }

    pub fn referent(self: *const Roots, reference: ValueId) Resource {
        const definition = self.function.definition(reference) orelse return .unknown;
        return switch (definition) {
            .borrow_address => |address| if (address.base_is_reference) self.referent(address.source) else self.borrowedRoot(address),
            .value_copy => |copy| if (copy.destination == null) self.referent(copy.source) else .unknown,
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
                    .borrow_address, .borrow_read, .storage_projection, .array_element, .allocation_element, .field_access, .variant_tag => {},
                    .borrow_write => |write| memory.exposeStoredValue(write.value),
                    .value_copy => |copy| memory.exposeStoredValue(copy.source),
                    .storage_cursor => |cursor| memory.expose(cursor.source),
                    .initializer_ref => function_ir.visitOperands(function, &function.instructions.items[index], .addresses, &memory, Memory.expose),
                    .call => |call| for (function.call_arguments.items[call.arguments.start..call.arguments.end]) |argument| {
                        if (argument != .prepared) memory.expose(argument.valueId());
                        memory.exposeStoredValue(argument.valueId());
                    },
                    else => function_ir.visitOperands(function, &function.instructions.items[index], .all, &memory, Memory.exposeStoredValue),
                }
            }
            function_ir.visitTerminatorOperands(function, &block.terminator, .addresses, &memory, Memory.expose);
            function_ir.visitTerminatorOperands(function, &block.terminator, .all, &memory, Memory.exposeStoredValue);
        }
        return memory;
    }

    fn expose(self: *Memory, value: ValueId) void {
        const resource = self.roots.root(value);
        if (Roots.slotOwner(resource)) |slot| self.exposed[@backingInt(slot)] = true;
    }

    fn exposeStoredValue(self: *Memory, value: ValueId) void {
        const resource = self.roots.referent(value);
        if (Roots.slotOwner(resource)) |slot| self.exposed[@backingInt(slot)] = true;
    }

    pub fn slotExposed(self: *const Memory, slot: ValueId) bool {
        return self.exposed[@backingInt(slot)];
    }
};

pub const Writes = struct {
    slots: std.AutoHashMapUnmanaged(ValueId, void) = .empty,
    fields: std.AutoHashMapUnmanaged(@FieldType(Resource, "field"), void) = .empty,
    parameters: std.AutoHashMapUnmanaged(Resource.Parameter, void) = .empty,
    /// A write through allocation-backed storage.
    heap: bool = false,
    unknown: bool = false,
    call: bool = false,
    contexts: u8 = 0,

    pub fn add(self: *Writes, scratch: std.mem.Allocator, resource: Resource) !void {
        switch (resource) {
            .immutable => {},
            .contextual => |entry| self.contexts |= structures.ContextEffects.bit(entry),
            .slot => |slot| try self.slots.put(scratch, slot, {}),
            .field => |field| try self.fields.put(scratch, field, {}),
            .parameter => |parameter| try self.parameters.put(scratch, parameter, {}),
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
            .erased_callable => |callable| if (callable.owns_environment) try self.add(scratch, .heap),
            .context_write => |write| try self.add(scratch, .{ .contextual = write.entry }),
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
            .contextual => |entry| !self.call and (self.contexts & structures.ContextEffects.bit(entry)) == 0,
            .slot, .field => self.preservesSlot(memory, resource),
            .parameter, .heap, .unknown => self.preservesExternal(resource),
        };
    }

    fn preservesExternal(self: *const Writes, resource: Resource) bool {
        if (self.heap or self.unknown or self.call) return false;
        var parameters = self.parameters.keyIterator();
        while (parameters.next()) |parameter| if (Roots.overlaps(resource, .{ .parameter = parameter.* })) return false;
        var slots = self.slots.keyIterator();
        while (slots.next()) |slot| if (Roots.overlaps(resource, .{ .slot = slot.* })) return false;
        var fields = self.fields.keyIterator();
        while (fields.next()) |field| if (Roots.overlaps(resource, .{ .field = field.* })) return false;
        return true;
    }

    fn preservesSlot(self: *const Writes, memory: *const Memory, resource: Resource) bool {
        const slot = Roots.slotOwner(resource).?;
        if (self.slots.contains(slot) or (memory.slotExposed(slot) and
            (self.parameters.count() != 0 or self.heap or self.unknown or self.call))) return false;
        if (resource == .field) return !self.fields.contains(resource.field);
        var fields = self.fields.keyIterator();
        while (fields.next()) |field| if (field.slot == slot) return false;
        return true;
    }
};
