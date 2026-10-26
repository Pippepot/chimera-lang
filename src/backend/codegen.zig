const std = @import("std");
const x86 = @import("x86_encoding.zig");
const registers = @import("registers.zig");
const structures = @import("../structures.zig");

const image_base: u64 = 0x400000;
const linux_exit_syscall: i32 = 60;
const linux_mmap_syscall: i32 = 9;
const linux_munmap_syscall: i32 = 11;

pub const TraceSource = struct {
    path: []const u8,
    source: []const u8,
    line_starts: []const usize,
    name: []const u8,
    fallback_span: structures.SourceSpan,

    fn location(source: TraceSource, offset: usize) struct { line: usize, column: usize } {
        std.debug.assert(offset <= source.source.len);
        std.debug.assert(source.line_starts.len != 0);
        const line = std.sort.upperBound(usize, source.line_starts, offset, compareOffsets);
        return .{ .line = line, .column = offset - source.line_starts[line - 1] + 1 };
    }

    fn compareOffsets(offset: usize, start: usize) std.math.Order {
        return std.math.order(offset, start);
    }
};

pub const InlineSource = struct {
    instance: structures.InstanceId,
    source: TraceSource,
};

const code_file_offset = @sizeOf(std.elf.Elf64.Ehdr) + @sizeOf(std.elf.Elf64.Phdr);

const ValueLocation = union(enum) {
    discarded,
    immediate: i32,
    eax,
    register: x86.Register,
    stack: u32,
    incoming_argument: u32,
    return_buffer: u32,
    indirect: u32,
};

const CopyDestination = union(enum) {
    value: ValueLocation,
    reference: ValueLocation,
};

const CopyAddress = union(enum) { stack: u32, pointer };

fn inversePredicate(operation: structures.PredicateOperation) structures.PredicateOperation {
    return switch (operation) {
        .lti => .gei,
        .gti => .lei,
        .lei => .gti,
        .gei => .lti,
        .eqi => .nei,
        .nei => .eqi,
        .eqb => .neb,
        .neb => .eqb,
        .eqt => .net,
        .net => .eqt,
    };
}

const indirect_layout: structures.TypeLayout = .{ .byte_size = @sizeOf(u64), .byte_alignment = @alignOf(u64) };
const initializer_layout: structures.TypeLayout = .{ .byte_size = 16, .byte_alignment = 8 };
const zero_sized_address_layout: structures.TypeLayout = .{ .byte_size = 1, .byte_alignment = 1 };

const ArgumentLayout = struct { storage: structures.TypeLayout, indirect: bool };

fn argumentLayout(types: anytype, argument: structures.FunctionBlockArgument) !ArgumentLayout {
    if (argument.representation == .initializer) return .{ .storage = initializer_layout, .indirect = false };
    if (argument.representation == .storage or try types.facts().argumentPassing(argument.type_id) == .indirect)
        return .{ .storage = indirect_layout, .indirect = true };
    return .{ .storage = try types.layout(argument.type_id), .indirect = false };
}

fn initializerSlotLayout(captures: structures.FunctionValueRange) error{FunctionTooLarge}!structures.TypeLayout {
    const environment_size = std.math.mul(u32, captures.end - captures.start, @sizeOf(u64)) catch return error.FunctionTooLarge;
    const size = std.math.add(u32, initializer_layout.byte_size, environment_size) catch return error.FunctionTooLarge;
    return .{ .byte_size = size, .byte_alignment = initializer_layout.byte_alignment };
}

fn valueSlotLayout(types: anytype, type_id: structures.TypeId) !structures.TypeLayout {
    const layout = try types.layout(type_id);
    if (layout.byte_size == 0 and try types.facts().argumentPassing(type_id) == .indirect)
        return zero_sized_address_layout;
    return layout;
}

fn reserveStack(end: *u32, layout: structures.TypeLayout) error{FunctionTooLarge}!u32 {
    std.debug.assert(std.math.isPowerOfTwo(layout.byte_alignment));
    const padding = layout.byte_alignment - 1;
    const offset = (std.math.add(u32, end.*, padding) catch return error.FunctionTooLarge) & ~padding;
    end.* = std.math.add(u32, offset, layout.byte_size) catch return error.FunctionTooLarge;
    return offset;
}

fn usesMemoryReturn(layout: structures.TypeLayout) bool {
    return layout.byte_size != 0 and layout.byte_size != @sizeOf(u32);
}

fn returnStorageLayout(types: anytype, type_id: structures.TypeId) !?structures.TypeLayout {
    if (try types.facts().argumentPassing(type_id) == .indirect) return indirect_layout;
    const layout = try types.layout(type_id);
    return if (usesMemoryReturn(layout)) layout else null;
}

fn ensureAddressableStackRange(offset: u32, byte_size: u32) error{FunctionTooLarge}!void {
    if (byte_size == 0) return;
    const last_byte = std.math.add(u32, offset, byte_size - 1) catch return error.FunctionTooLarge;
    if (last_byte > std.math.maxInt(i32)) return error.FunctionTooLarge;
}

fn immediateComponent(comptime Component: type, value: i32, offset: u32) i32 {
    if (Component == u32) {
        std.debug.assert(offset == 0);
        return value;
    }
    std.debug.assert(offset < @sizeOf(i32));
    const bits: u32 = @bitCast(value);
    return @intCast((bits >> @intCast(offset * 8)) & 0xff);
}

fn branchStorageEnd(ssa: *const structures.FunctionBodyAnalysis, types: anytype, branch: structures.FunctionBranch, start: u32) !u32 {
    const target = ssa.blocks[@backingInt(branch.target)];
    var end = start;
    for (ssa.block_arguments[target.argument_start..target.argument_end]) |argument| {
        _ = try reserveStack(&end, (try argumentLayout(types, argument)).storage);
    }
    return end;
}

const CallLayout = struct {
    result: ValueLocation,
    arguments: []ValueLocation,
    storage_end: u32,

    fn init(types: anytype, return_type: structures.TypeId, parameters: []const structures.FunctionBlockArgument, gpa: std.mem.Allocator) !CallLayout {
        const arguments = try gpa.alloc(ValueLocation, parameters.len);
        errdefer gpa.free(arguments);
        var end: u32 = 0;
        const result: ValueLocation = if (try returnStorageLayout(types, return_type)) |layout| blk: {
            const offset = try reserveStack(&end, layout);
            break :blk if (try types.facts().argumentPassing(return_type) == .indirect) .{ .indirect = offset } else .{ .stack = offset };
        } else .eax;
        for (parameters, arguments) |parameter, *argument| {
            const layout = try argumentLayout(types, parameter);
            const offset = try reserveStack(&end, layout.storage);
            argument.* = if (layout.indirect) .{ .indirect = offset } else .{ .stack = offset };
        }
        return .{ .result = result, .arguments = arguments, .storage_end = end };
    }

    fn deinit(self: *CallLayout, gpa: std.mem.Allocator) void {
        gpa.free(self.arguments);
        self.* = undefined;
    }
};

const CallLayoutKey = struct { arguments: structures.FunctionValueRange, return_type: structures.TypeId };

const CallLayouts = std.AutoHashMapUnmanaged(CallLayoutKey, CallLayout);

fn deinitCallLayouts(layouts: *CallLayouts, gpa: std.mem.Allocator) void {
    var iterator = layouts.valueIterator();
    while (iterator.next()) |layout| layout.deinit(gpa);
    layouts.deinit(gpa);
}

fn planCallStorage(
    ssa: *const structures.FunctionBodyAnalysis,
    types: anytype,
    value_types: []const structures.TypeId,
    call: structures.FunctionCall,
    layouts: *CallLayouts,
    gpa: std.mem.Allocator,
) !u32 {
    const key: CallLayoutKey = .{ .arguments = call.arguments, .return_type = call.return_type };
    if (layouts.get(key)) |layout| return layout.storage_end;
    const parameters = try gpa.alloc(structures.FunctionBlockArgument, call.arguments.end - call.arguments.start);
    defer gpa.free(parameters);
    for (ssa.call_arguments[call.arguments.start..call.arguments.end], parameters) |argument, *parameter| {
        const use = argument.valueUse();
        parameter.* = .{
            .type_id = use.coerce_to orelse value_types[@backingInt(use.value)],
            .representation = switch (argument) {
                .prepared => .value,
                .deinit, .borrowed => .storage,
                .initializer => .initializer,
            },
        };
    }
    var layout = try CallLayout.init(types, call.return_type, parameters, gpa);
    errdefer layout.deinit(gpa);
    try layouts.put(gpa, key, layout);
    return layout.storage_end;
}

const LocationPlan = struct {
    locations: []ValueLocation,
    value_types: []structures.TypeId,
    stack_size: u32,
    edge_scratch_offset: u32,
    return_buffer_offset: ?u32,
    calls: CallLayouts,
    registers: ?registers.Allocation,
    saved_register_offset: u32,

    const Usage = enum { unused, used, returned };

    fn markBranchArguments(
        ssa: *const structures.FunctionBodyAnalysis,
        branch: structures.FunctionBranch,
        needed: []Usage,
        addressable: []bool,
    ) void {
        const arguments = ssa.branch_arguments[branch.arguments.start..branch.arguments.end];
        const target = ssa.blocks[@backingInt(branch.target)];
        for (arguments, ssa.block_arguments[target.argument_start..target.argument_end]) |argument, parameter| {
            const index = @backingInt(argument.value);
            needed[index] = .used;
            if (parameter.representation == .storage) addressable[index] = true;
        }
    }

    fn markCallArguments(ssa: *const structures.FunctionBodyAnalysis, call: structures.FunctionCall, needed: []Usage, addressable: []bool) void {
        for (ssa.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
            const index = @backingInt(argument.valueId());
            needed[index] = .used;
            if (argument == .deinit or argument == .borrowed) addressable[index] = true;
        }
    }

    fn storageProjectionLocation(
        types: anytype,
        operation: structures.StorageProjection,
        value_index: usize,
        locations: []const ValueLocation,
        value_types: []const structures.TypeId,
        local_end: *u32,
    ) !ValueLocation {
        const owner = @backingInt(operation.owner);
        // Earlier stack locations are final; incoming arguments and
        // result storage receive their locations after frame sizing.
        if (owner < value_index and locations[owner] == .stack) {
            const offset: ?u32 = switch (operation.projection) {
                .field => |index| ((try types.structLayout(value_types[owner])) orelse return error.Unavailable).field_offsets[index],
                .variant => (try types.variantLayout(value_types[owner])).payload_offset,
                .box_element, .allocation_array => null,
            };
            if (offset) |bytes| return .{ .stack = std.math.add(u32, locations[owner].stack, bytes) catch return error.FunctionTooLarge };
        }
        return .{ .indirect = try reserveStack(local_end, indirect_layout) };
    }

    fn init(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator) !LocationPlan {
        const needed = try gpa.alloc(Usage, ssa.valueCount());
        defer gpa.free(needed);
        @memset(needed, .unused);
        const addressable = try gpa.alloc(bool, ssa.valueCount());
        defer gpa.free(addressable);
        @memset(addressable, false);
        const value_types = try gpa.alloc(structures.TypeId, ssa.valueCount());
        errdefer gpa.free(value_types);
        for (ssa.block_arguments, value_types[0..ssa.block_arguments.len]) |argument, *type_id| type_id.* = argument.type_id;

        for (ssa.instructions, 0..) |original, instruction_index| {
            var instruction = original;
            const value_index = @backingInt(ssa.instructionValue(instruction_index));
            value_types[value_index] = instruction.resultType();
            for (instruction.operands()) |operand| if (operand) |value| {
                needed[@backingInt(value.*)] = .used;
            };
            switch (instruction) {
                .const_type, .const_int_literal, .static_conversion => unreachable,
                .initializer_ref => |operation| {
                    for (ssa.initializer_captures[operation.captures.start..operation.captures.end]) |capture| {
                        needed[@backingInt(capture)] = .used;
                        addressable[@backingInt(capture)] = true;
                    }
                },
                .local_storage => addressable[value_index] = true,
                .initializer_capture_write => |operation| if (ssa.is_initializer_region) {
                    needed[operation.parameter_index] = .used;
                },
                .storage_projection => |operation| if (operation.projection != .box_element) {
                    addressable[@backingInt(operation.owner)] = true;
                },
                .storage_cursor => |operation| addressable[@backingInt(operation.source)] = true,
                .array_element => |operation| addressable[@backingInt(operation.array)] = true,
                .borrow_address => |operation| if (!operation.base_is_reference) {
                    addressable[@backingInt(operation.source)] = true;
                },
                .borrow_write => |operation| addressable[@backingInt(operation.value)] = true,
                .call => |call| markCallArguments(ssa, call, needed, addressable),
                .aggregate => |aggregate| for (ssa.aggregate_fields[aggregate.fields.start..aggregate.fields.end]) |field| {
                    needed[@backingInt(field)] = .used;
                },
                .fill => |operation| addressable[@backingInt(operation.first)] = true,
                .move => |operation| {
                    addressable[@backingInt(operation.destination)] = true;
                    addressable[@backingInt(operation.source)] = true;
                },
                else => {},
            }
        }
        for (ssa.blocks) |block| {
            var terminator = block.terminator;
            for (terminator.operands()) |operand| if (operand) |value| {
                needed[@backingInt(value.*)] = .used;
            };
            for (terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
                markBranchArguments(ssa, branch.*, needed, addressable);
            };
        }
        for (ssa.blocks) |block| {
            if (block.instruction_start == block.instruction_end or block.terminator != .return_value) continue;
            const returned = block.terminator.return_value;
            const value = ssa.instructionValue(block.instruction_end - 1);
            if (returned.value == value and returned.coerce_to == null) needed[@backingInt(value)] = .returned;
        }
        // One reusable area handles every call this function makes. After the
        // prologue, this function's own incoming arguments remain above its
        // frame, past its return address:
        //   rsp + 0..outgoing_size: outgoing return storage and arguments
        //   rsp + outgoing_size..stack_size: local spills
        //   rsp + stack_size: return address
        //   rsp + stack_size + 8: incoming argument 0
        var outgoing_size: u32 = 0;
        var calls: CallLayouts = .empty;
        errdefer deinitCallLayouts(&calls, gpa);
        for (ssa.instructions) |instruction| if (instruction == .call) {
            outgoing_size = @max(outgoing_size, try planCallStorage(ssa, types, value_types, instruction.call, &calls, gpa));
        };
        var edge_scratch_end = outgoing_size;
        for (ssa.blocks) |block| {
            var terminator = block.terminator;
            for (terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
                edge_scratch_end = @max(edge_scratch_end, try branchStorageEnd(ssa, types, branch.*, outgoing_size));
            };
        }
        const locations = try gpa.alloc(ValueLocation, ssa.valueCount());
        errdefer gpa.free(locations);
        @memset(locations[0..ssa.block_arguments.len], .discarded);
        var local_end = edge_scratch_end;
        const entry_index = @backingInt(ssa.entry);
        std.debug.assert(entry_index < ssa.blocks.len);
        for (ssa.blocks, 0..) |block, block_index| {
            std.debug.assert(block.argument_start <= block.argument_end);
            std.debug.assert(block.argument_end <= ssa.block_arguments.len);
            if (block_index == entry_index) continue;
            for (block.argument_start..block.argument_end) |argument_index| {
                if (needed[argument_index] == .unused) continue;
                const layout = try argumentLayout(types, ssa.block_arguments[argument_index]);
                if (layout.indirect) {
                    locations[argument_index] = .{ .indirect = try reserveStack(&local_end, layout.storage) };
                    continue;
                }
                if (layout.storage.byte_size == 0 and !addressable[argument_index]) continue;
                locations[argument_index] = .{ .stack = try reserveStack(&local_end, if (layout.storage.byte_size == 0) zero_sized_address_layout else layout.storage) };
            }
        }
        for (ssa.instructions, locations[ssa.block_arguments.len..], 0..) |instruction, *location, instruction_index| {
            const value_index = @backingInt(ssa.instructionValue(instruction_index));
            location.* = location_blk: {
                switch (instruction) {
                    inline .const_int, .const_byte, .const_bool => |value| if (!addressable[value_index]) {
                        break :location_blk .{ .immediate = if (@TypeOf(value) == bool) @intFromBool(value) else value };
                    },
                    .const_type, .const_int_literal, .const_string_literal, .static_conversion => unreachable,
                    .initializer_ref => |operation| break :location_blk .{ .stack = try reserveStack(&local_end, try initializerSlotLayout(operation.captures)) },
                    .const_unit, .const_none => if (!addressable[value_index]) break :location_blk .discarded,
                    .call => |call| if (call.return_type == .unit and !addressable[value_index]) {
                        break :location_blk .discarded;
                    },
                    .result_storage => break :location_blk .discarded,
                    .storage_projection => |operation| if (needed[value_index] != .unused)
                        break :location_blk try storageProjectionLocation(types, operation, value_index, locations, value_types, &local_end)
                    else
                        break :location_blk .discarded,
                    .allocation_element, .array_element, .borrow_read => if (needed[value_index] != .unused) {
                        break :location_blk .{ .indirect = try reserveStack(&local_end, indirect_layout) };
                    } else break :location_blk .discarded,
                    else => {},
                }
                if (needed[value_index] == .unused and
                    (instruction != .call or try types.facts().argumentPassing(value_types[value_index]) != .indirect))
                    break :location_blk .discarded;
                const layout = try valueSlotLayout(types, value_types[value_index]);
                if (needed[value_index] == .returned and value_types[value_index] == .int and !addressable[value_index]) {
                    break :location_blk .eax;
                }
                if (layout.byte_size == 0) {
                    if (addressable[value_index]) break :location_blk .{ .stack = try reserveStack(&local_end, zero_sized_address_layout) };
                    break :location_blk .discarded;
                }
                break :location_blk .{ .stack = try reserveStack(&local_end, layout) };
            };
        }
        const entry = ssa.blocks[entry_index];
        for (entry.argument_start..entry.argument_end) |argument_index| {
            if (!addressable[argument_index]) continue;
            if ((try argumentLayout(types, ssa.block_arguments[argument_index])).storage.byte_size != 0) continue;
            locations[argument_index] = .{ .stack = try reserveStack(&local_end, zero_sized_address_layout) };
        }
        if (ssa.is_initializer_region) {
            for (entry.argument_start..entry.argument_end) |index| {
                if (needed[index] != .unused) locations[index] = .{ .indirect = try reserveStack(&local_end, indirect_layout) };
            }
        }
        const allocated = try allocateRegisters(ssa, gpa, locations, value_types, addressable);
        errdefer if (allocated) |allocation| {
            var owned = allocation;
            owned.deinit(gpa);
        };
        const saved_register_offset = local_end;
        if (allocated) |allocation| for (allocation.used) |_| {
            _ = try reserveStack(&local_end, indirect_layout);
        };
        const stack_size = local_end;
        if (stack_size > std.math.maxInt(i32)) return error.FunctionTooLarge;
        std.debug.assert(ssa.parameter_modes.len == entry.argument_end - entry.argument_start);
        const parameters = ssa.block_arguments[entry.argument_start..entry.argument_end];
        var incoming = try CallLayout.init(types, ssa.return_type, parameters, gpa);
        defer incoming.deinit(gpa);
        var return_buffer_offset: ?u32 = null;
        const caller_stack_offset = std.math.add(u32, stack_size, @sizeOf(u64)) catch return error.FunctionTooLarge;
        if (caller_stack_offset > std.math.maxInt(i32)) return error.FunctionTooLarge;
        if (try returnStorageLayout(types, ssa.return_type)) |return_storage| {
            return_buffer_offset = caller_stack_offset;
            try ensureAddressableStackRange(return_buffer_offset.?, return_storage.byte_size);
        }
        for (ssa.instructions, 0..) |instruction, instruction_index| if (instruction == .result_storage) {
            std.debug.assert(try types.facts().argumentPassing(ssa.return_type) == .indirect);
            locations[@backingInt(ssa.instructionValue(instruction_index))] = .{ .indirect = return_buffer_offset.? };
        };
        if (!ssa.is_initializer_region) for (parameters, incoming.arguments, entry.argument_start..) |parameter, incoming_location, argument_index| {
            const layout = try argumentLayout(types, parameter);
            const argument_stack_offset = switch (incoming_location) {
                .stack, .indirect => |offset| offset,
                else => unreachable,
            };
            const offset = std.math.add(u32, caller_stack_offset, argument_stack_offset) catch return error.FunctionTooLarge;
            try ensureAddressableStackRange(offset, layout.storage.byte_size);
            if (needed[argument_index] != .unused and layout.storage.byte_size != 0) {
                locations[argument_index] = if (layout.indirect) .{ .indirect = offset } else .{ .incoming_argument = offset };
            }
        };
        return .{
            .locations = locations,
            .value_types = value_types,
            .stack_size = stack_size,
            .edge_scratch_offset = outgoing_size,
            .return_buffer_offset = return_buffer_offset,
            .calls = calls,
            .registers = allocated,
            .saved_register_offset = saved_register_offset,
        };
    }

    fn allocateRegisters(ssa: *const structures.FunctionBodyAnalysis, gpa: std.mem.Allocator, locations: []ValueLocation, types: []const structures.TypeId, addressable: []const bool) !?registers.Allocation {
        for (ssa.blocks, 0..) |block, index| {
            var terminator = block.terminator;
            for (terminator.successors()) |successor| if (successor) |target| {
                if (@backingInt(target.*) <= index) break;
            } else continue;
            break;
        } else return null;
        const candidates = try gpa.alloc(bool, locations.len);
        defer gpa.free(candidates);
        for (locations, types, addressable, candidates) |location, type_id, taken, *candidate|
            candidate.* = location == .stack and !taken and (type_id == .int or type_id == .bool);
        for (ssa.instructions, candidates[ssa.block_arguments.len..]) |instruction, *candidate| {
            if (instruction == .storage_projection or instruction == .local_storage or instruction == .initializer_ref) candidate.* = false;
        }
        for (ssa.block_arguments, candidates[0..ssa.block_arguments.len]) |argument, *candidate| {
            if (argument.representation != .value) candidate.* = false;
        }
        const entry = ssa.blocks[@backingInt(ssa.entry)];
        @memset(candidates[entry.argument_start..entry.argument_end], false);
        if (std.mem.indexOfScalar(bool, candidates, true) == null) return null;
        const allocation = try registers.allocate(gpa, ssa, candidates);
        for (locations, allocation.registers) |*location, register| if (register) |selected| {
            location.* = .{ .register = selected };
        };
        return allocation;
    }

    fn deinit(self: *LocationPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locations);
        gpa.free(self.value_types);
        deinitCallLayouts(&self.calls, gpa);
        if (self.registers) |*allocation| allocation.deinit(gpa);
        self.* = undefined;
    }
};

fn FunctionEmitter(comptime Types: type) type {
    return struct {
        const Self = @This();
        const JumpPatch = struct {
            field_offset: u32,
            target: structures.FunctionBlockId,
        };

        gpa: std.mem.Allocator,
        ssa: *const structures.FunctionBodyAnalysis,
        plan: *const LocationPlan,
        types: Types,
        encoder: X86Encoder,
        block_offsets: []u32,
        relocations: std.ArrayList(structures.CompiledFunction.Relocation) = .empty,
        referenced_instances: std.ArrayList(structures.InstanceId) = .empty,
        constant_data: std.ArrayList(structures.ByteString) = .empty,
        trace_sites: std.ArrayList(structures.CompiledFunction.TraceSite) = .empty,
        current_span: ?structures.SourceSpan = null,
        current_frame: structures.InlineFrameId = .root,
        // Scratch inverse of referenced_instances; relocations index the slice.
        reference_indices: std.AutoHashMapUnmanaged(structures.InstanceId, u32) = .empty,
        jump_patches: std.ArrayList(JumpPatch) = .empty,
        initializer_patches: std.ArrayList(struct { field_offset: u32, region: u32 }) = .empty,

        fn init(gpa: std.mem.Allocator, ssa: *const structures.FunctionBodyAnalysis, plan: *const LocationPlan, types: Types) !Self {
            const block_offsets = try gpa.alloc(u32, ssa.blocks.len);
            @memset(block_offsets, std.math.maxInt(u32));
            return .{
                .gpa = gpa,
                .ssa = ssa,
                .plan = plan,
                .types = types,
                .encoder = .{ .gpa = gpa },
                .block_offsets = block_offsets,
            };
        }

        fn deinit(self: *Self) void {
            self.gpa.free(self.block_offsets);
            self.jump_patches.deinit(self.gpa);
            self.initializer_patches.deinit(self.gpa);
            self.referenced_instances.deinit(self.gpa);
            for (self.constant_data.items) |data| self.gpa.free(data.bytes);
            self.constant_data.deinit(self.gpa);
            for (self.trace_sites.items) |site| self.gpa.free(site.label);
            self.trace_sites.deinit(self.gpa);
            self.reference_indices.deinit(self.gpa);
            self.relocations.deinit(self.gpa);
            self.encoder.deinit();
            self.* = undefined;
        }

        fn valueLocation(self: *const Self, value: structures.FunctionValueId) ValueLocation {
            return self.plan.locations[@backingInt(value)];
        }

        fn valueType(self: *const Self, value: structures.FunctionValueId) structures.TypeId {
            return self.plan.value_types[@backingInt(value)];
        }

        /// An instruction with explicit result storage writes there instead of to its own value.
        fn resultLocation(self: *const Self, storage: ?structures.FunctionValueId, own: ValueLocation) ValueLocation {
            return if (storage) |value| self.valueLocation(value) else own;
        }

        fn emit(self: *Self) !void {
            const ssa = self.ssa;
            if (self.plan.stack_size != 0) try self.encoder.offset(.sub_rsp, self.plan.stack_size);
            try self.saveRegisters(.save);
            if (ssa.is_initializer_region) {
                const entry = ssa.blocks[@backingInt(ssa.entry)];
                for (self.plan.locations[entry.argument_start..entry.argument_end], 0..) |location, capture| {
                    if (location == .discarded) continue;
                    try self.encoder.offset(.mov_rax_rdi, @intCast(capture * 8));
                    try self.bindIndirect(location);
                }
            }
            for (0..ssa.blocks.len) |position| {
                const fallthrough = if (position + 1 < ssa.blocks.len) blockInEmissionOrder(ssa, position + 1) else null;
                try self.emitBlock(blockInEmissionOrder(ssa, position), fallthrough);
            }
            for (self.jump_patches.items) |patch| {
                const target_offset = self.block_offsets[@backingInt(patch.target)];
                std.debug.assert(target_offset != std.math.maxInt(u32));
                try self.encoder.patch(patch.field_offset, target_offset);
            }
        }

        fn blockInEmissionOrder(ssa: *const structures.FunctionBodyAnalysis, position: usize) structures.FunctionBlockId {
            if (position == 0) return ssa.entry;
            const index = position - 1;
            return @fromBackingInt(@intCast(index + @intFromBool(index >= @backingInt(ssa.entry))));
        }

        fn emitBlock(self: *Self, block_id: structures.FunctionBlockId, fallthrough: ?structures.FunctionBlockId) !void {
            const ssa = self.ssa;
            const block_index = @backingInt(block_id);
            const block = ssa.blocks[block_index];
            self.block_offsets[block_index] = try self.encoder.position();
            std.debug.assert(block.instruction_start <= block.instruction_end);
            std.debug.assert(block.instruction_end <= ssa.instructions.len);
            for (block.instruction_start..block.instruction_end) |instruction_index| {
                self.current_span = if (ssa.instruction_spans.len == ssa.instructions.len) ssa.instruction_spans[instruction_index] else null;
                self.current_frame = if (ssa.instruction_frames.len != 0) ssa.instruction_frames[instruction_index] else .root;
                try self.emitInstruction(ssa.instructions[instruction_index], self.valueLocation(ssa.instructionValue(instruction_index)));
            }
            self.current_span = if (ssa.terminator_spans.len == ssa.blocks.len) ssa.terminator_spans[block_index] else null;
            self.current_frame = if (ssa.terminator_frames.len != 0) ssa.terminator_frames[block_index] else .root;
            try self.emitTerminator(block.terminator, fallthrough);
        }

        fn emitInstruction(self: *Self, instruction: structures.FunctionInstruction, destination: ValueLocation) !void {
            switch (instruction) {
                inline .const_int, .const_byte, .const_bool => |value| if (destination == .stack) {
                    try self.encoder.immediate(.mov_eax, if (@TypeOf(value) == bool) @intFromBool(value) else value);
                    try self.storeComponent(if (@TypeOf(value) == u8) u8 else u32, destination, 0);
                },
                .const_unit, .const_none, .local_storage, .result_storage => {},
                .const_type, .const_int_literal, .const_string_literal, .static_conversion => unreachable,
                .const_static_string => |constant| try self.emitStaticString(constant, destination),
                .const_storage_cursor => |cursor| if (cursor.data) |data| {
                    try self.emitDataAddress(data, cursor.offset, destination);
                } else {
                    try self.encoder.absolute(.mov_rax, 0);
                    try self.storeAddress(destination);
                },
                .storage_cursor => |operation| try self.emitStorageCursor(operation, destination),
                .cursor_offset, .cursor_element => |operation| try self.emitCursorElement(operation, destination),
                .byte_to_int => |operand| try self.emitUnary(u8, operand, null, destination),
                .variant_tag => |operand| try self.emitUnary(u32, operand, null, destination),
                .negi => |operand| try self.emitUnary(u32, operand, .neg_eax, destination),
                inline .addi, .subi, .muli, .divsi => |operands, operation| try self.emitIntegerBinary(operation, operands, destination),
                .function_ref => |reference| try self.emitFunctionReference(reference, destination),
                .initializer_ref => |reference| try self.emitInitializerReference(reference, destination),
                .variant_coerce => |coercion| try self.emitUse(
                    .{ .value = coercion.operand, .coerce_to = coercion.target_type, .variant_tag_mapping = coercion.tag_mapping.? },
                    coercion.target_type,
                    self.resultLocation(coercion.destination, destination),
                ),
                .variant_extract => |extraction| try self.emitVariantExtract(extraction, destination),
                .value_copy => |operation| try self.copyValue(
                    operation.type_id,
                    self.valueLocation(operation.source),
                    self.resultLocation(operation.destination, destination),
                ),
                .storage_projection => |operation| try self.emitStorageProjection(operation, destination),
                .allocation_element => |operation| if (destination != .discarded) {
                    try self.emitElementAddress(self.valueLocation(operation.allocation), false, operation.index, operation.type_id);
                    try self.bindIndirect(destination);
                },
                .array_element => |operation| if (destination != .discarded) {
                    try self.emitElementAddress(self.valueLocation(operation.array), true, operation.index, operation.type_id);
                    try self.bindIndirect(destination);
                },
                .borrow_box => |operation| try self.emitBorrowBox(operation, destination),
                .borrow_address => |operation| try self.emitBorrowAddress(operation, destination),
                .borrow_read => |operation| if (destination != .discarded) {
                    try self.loadAddress(self.valueLocation(operation.source));
                    try self.bindIndirect(destination);
                },
                .borrow_write => |operation| try self.emitBorrowWrite(operation),
                .field_access => |operation| try self.emitFieldAccess(operation, destination),
                .initializer_capture_write => |operation| try self.emitInitializerCaptureWrite(operation),
                .call => |call| try self.emitCall(call, destination),
                .compare => |operation| try self.emitCompare(operation, destination),
                .select => |operation| try self.emitSelect(operation, destination),
                .aggregate => |operation| try self.emitAggregate(operation, destination),
                .fill => |operation| try self.emitFill(operation),
                .move => |operation| try self.emitMove(operation),
            }
        }

        fn emitIntegerBinary(self: *Self, comptime operation: std.meta.Tag(structures.FunctionInstruction), operands: structures.BinaryOperands, destination: ValueLocation) !void {
            const lhs = self.valueLocation(operands.lhs);
            const rhs = self.valueLocation(operands.rhs);
            if (operation != .divsi and destination == .register) {
                const reuse_lhs = std.meta.eql(lhs, destination);
                const reuse_rhs = operation != .subi and std.meta.eql(rhs, destination);
                if (reuse_lhs or reuse_rhs) {
                    const other = if (reuse_lhs) rhs else lhs;
                    if (other == .immediate) {
                        const encoding: x86.RegisterOperation = switch (operation) {
                            .addi => .add_immediate,
                            .subi => .sub_immediate,
                            .muli => .imul_immediate,
                            else => unreachable,
                        };
                        try self.encoder.register(encoding, destination.register, @as(u32, @bitCast(other.immediate)));
                    } else {
                        try self.loadComponent(u32, other, 0);
                        const encoding: x86.RegisterOperation = switch (operation) {
                            .addi => .add_from_eax,
                            .subi => .sub_from_eax,
                            .muli => .imul_from_eax,
                            else => unreachable,
                        };
                        try self.encoder.register(encoding, destination.register, 0);
                    }
                    return;
                }
            }
            try self.loadComponent(u32, lhs, 0);
            try self.encoder.integerBinary(operation, rhs);
            try self.storeResult(destination);
        }

        fn emitCompare(self: *Self, operation: structures.CompareOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            try self.loadComponent(u32, self.valueLocation(operation.operands.lhs), 0);
            try self.encoder.compareEax(self.valueLocation(operation.operands.rhs));
            try self.encoder.emit(switch (operation.operation) {
                .lti => .setl_al,
                .gti => .setg_al,
                .lei => .setle_al,
                .gei => .setge_al,
                .eqi, .eqb => .sete_al,
                .nei, .neb => .setne_al,
                .eqt, .net => unreachable,
            });
            try self.encoder.emit(.movzx_eax_al);
            try self.storeResult(destination);
        }

        fn emitSelect(self: *Self, operation: structures.SelectOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const size = (try self.types.layout(operation.type_id)).byte_size;
            std.debug.assert(size == 1 or size == 4);
            if (size == 1) {
                try self.loadComponent(u8, self.valueLocation(operation.else_value), 0);
            } else try self.loadComponent(u32, self.valueLocation(operation.else_value), 0);
            try self.encoder.emit(.mov_ecx_eax);
            try self.loadComponent(u32, self.valueLocation(operation.condition), 0);
            try self.encoder.emit(.test_eax);
            if (size == 1) {
                try self.loadComponent(u8, self.valueLocation(operation.then_value), 0);
            } else try self.loadComponent(u32, self.valueLocation(operation.then_value), 0);
            try self.encoder.emit(.cmove_eax_ecx);
            if (size == 1) {
                try self.storeComponent(u8, destination, 0);
            } else try self.storeResult(destination);
        }

        fn emitAggregate(self: *Self, operation: structures.AggregateOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const layout = (try self.types.structLayout(operation.type_id)).?;
            const fields = self.ssa.aggregate_fields[operation.fields.start..operation.fields.end];
            for (fields, layout.field_offsets) |field, offset| {
                const size = (try self.types.layout(self.valueType(field))).byte_size;
                try self.copyRange(self.valueLocation(field), 0, .{ .value = destination }, offset, size);
            }
        }

        fn emitFill(self: *Self, operation: structures.FillOperation) !void {
            const size = (try self.types.layout(operation.type_id)).byte_size;
            std.debug.assert(size == 1 or size == 4);
            try self.loadComponent(u32, self.valueLocation(operation.count), 0);
            try self.encoder.emit(.mov_ecx_eax);
            try self.loadValueAddress(self.valueLocation(operation.first));
            try self.encoder.emit(.mov_rdi_rax);
            if (size == 1) {
                try self.loadComponent(u8, self.valueLocation(operation.value), 0);
            } else try self.loadComponent(u32, self.valueLocation(operation.value), 0);
            try self.encoder.emit(if (size == 1) .rep_stosb else .rep_stosd);
        }

        fn emitMove(self: *Self, operation: structures.MoveOperation) !void {
            const size = (try self.types.layout(operation.type_id)).byte_size;
            if (size == 0) return;
            if (size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            try self.loadComponent(u32, self.valueLocation(operation.count), 0);
            try self.encoder.emit(.movsxd_rcx_eax);
            if (size != 1) try self.encoder.immediate(.imul_rcx, @intCast(size));
            try self.loadValueAddress(self.valueLocation(operation.destination));
            if (operation.backward) {
                try self.encoder.emit(.add_rax_rcx);
                try self.encoder.immediate(.add_rax, -1);
            }
            try self.encoder.emit(.mov_rdi_rax);
            try self.loadValueAddress(self.valueLocation(operation.source));
            if (operation.backward) {
                try self.encoder.emit(.add_rax_rcx);
                try self.encoder.immediate(.add_rax, -1);
            }
            try self.encoder.emit(.mov_rsi_rax);
            if (operation.backward) try self.encoder.emit(.std);
            try self.encoder.emit(.rep_movsb);
            if (operation.backward) try self.encoder.emit(.cld);
        }

        fn emitTerminator(self: *Self, terminator: structures.FunctionTerminator, fallthrough: ?structures.FunctionBlockId) !void {
            switch (terminator) {
                .branch => |branch| {
                    try self.emitBranchCopies(branch);
                    try self.emitJump(branch.target, fallthrough);
                },
                .predicate_branch => |predicate| try self.emitPredicateBranch(predicate, fallthrough),
                .return_unit => try self.emitEpilogue(),
                .return_value => |value| try self.emitReturn(value),
                .diverge => try self.encoder.emit(.ud2),
            }
        }

        fn emitPredicateBranch(self: *Self, predicate: @FieldType(structures.FunctionTerminator, "predicate_branch"), fallthrough: ?structures.FunctionBlockId) !void {
            try self.loadComponent(u32, self.valueLocation(predicate.operands.lhs), 0);
            try self.encoder.compareEax(self.valueLocation(predicate.operands.rhs));
            const final_is_then = fallthrough == predicate.then_branch.target or fallthrough != predicate.else_branch.target;
            const final = if (final_is_then) predicate.then_branch else predicate.else_branch;
            const early = if (final_is_then) predicate.else_branch else predicate.then_branch;
            const operation = if (final_is_then) predicate.operation else inversePredicate(predicate.operation);
            if (early.arguments.start == early.arguments.end) {
                try self.emitConditionalJump(inversePredicate(operation), early.target);
            } else {
                const final_field = try self.encoder.conditionalJump(operation);
                try self.emitBranchCopies(early);
                try self.emitJump(early.target, null);
                try self.encoder.patchHere(final_field);
            }
            try self.emitBranchCopies(final);
            try self.emitJump(final.target, fallthrough);
        }

        fn emitBranchCopies(self: *Self, branch: structures.FunctionBranch) !void {
            const target = self.ssa.blocks[@backingInt(branch.target)];
            const arguments = self.ssa.branch_arguments[branch.arguments.start..branch.arguments.end];
            const parameters = self.ssa.block_arguments[target.argument_start..target.argument_end];
            const destinations = self.plan.locations[target.argument_start..target.argument_end];
            std.debug.assert(arguments.len == parameters.len);
            if (arguments.len == 1) return self.emitBranchArgument(arguments[0], parameters[0].type_id, destinations[0], null);
            if (self.independentBranchCopies(arguments, parameters, destinations)) {
                for (arguments, parameters, destinations) |argument, parameter, destination|
                    try self.emitBranchArgument(argument, parameter.type_id, destination, null);
                return;
            }
            // Several arguments may read each other's parameters, so all of them
            // move through scratch storage before any parameter is written.
            var scratch_end = self.plan.edge_scratch_offset;
            for (arguments, parameters, destinations) |argument, parameter, destination| {
                const scratch = try reserveStack(&scratch_end, (try argumentLayout(self.types, parameter)).storage);
                try self.emitBranchArgument(argument, parameter.type_id, destination, scratch);
            }
            scratch_end = self.plan.edge_scratch_offset;
            for (parameters, destinations) |parameter, destination| {
                const scratch = try reserveStack(&scratch_end, (try argumentLayout(self.types, parameter)).storage);
                if (destination == .indirect) {
                    try self.encoder.offset(.mov_rax_rsp, scratch);
                    try self.bindIndirect(destination);
                } else try self.copyValue(parameter.type_id, .{ .stack = scratch }, destination);
            }
        }

        fn independentBranchCopies(self: *Self, arguments: []const structures.FunctionValueUse, parameters: []const structures.FunctionBlockArgument, destinations: []const ValueLocation) bool {
            for (arguments, parameters, destinations) |argument, parameter, destination| {
                if (destination == .discarded) continue;
                if (argument.coerce_to != null or destination == .indirect) return false;
                if (parameter.type_id != .int and parameter.type_id != .bool and parameter.type_id != .byte) return false;
                const source = self.valueLocation(argument.value);
                if (source == .indirect) return false;
                if (std.meta.eql(source, destination)) continue;
                for (destinations) |other| {
                    if (std.meta.eql(source, other)) return false;
                }
            }
            return true;
        }

        /// Writes one branch argument to its parameter, or to `scratch` when given.
        /// An indirect parameter receives the argument's address.
        fn emitBranchArgument(self: *Self, argument: structures.FunctionValueUse, type_id: structures.TypeId, destination: ValueLocation, scratch: ?u32) !void {
            switch (destination) {
                .discarded => {},
                .indirect => |slot| try self.storeUseAddress(argument, scratch orelse slot),
                else => try self.emitUse(argument, type_id, if (scratch) |offset| .{ .stack = offset } else destination),
            }
        }

        fn emitJump(self: *Self, target: structures.FunctionBlockId, fallthrough: ?structures.FunctionBlockId) !void {
            if (fallthrough == target) return;
            try self.jump_patches.append(self.gpa, .{ .field_offset = try self.encoder.patchable(.jmp), .target = target });
        }

        fn emitConditionalJump(self: *Self, operation: structures.PredicateOperation, target: structures.FunctionBlockId) !void {
            try self.jump_patches.append(self.gpa, .{ .field_offset = try self.encoder.conditionalJump(operation), .target = target });
        }

        fn emitReturn(self: *Self, returned: structures.FunctionValueUse) !void {
            const return_type = self.ssa.return_type;
            const layout = try self.types.layout(return_type);
            const destination: ValueLocation = if (try self.types.facts().argumentPassing(return_type) == .indirect)
                .{ .indirect = self.plan.return_buffer_offset.? }
            else if (usesMemoryReturn(layout))
                .{ .return_buffer = self.plan.return_buffer_offset.? }
            else
                .eax;
            try self.emitUse(returned, return_type, destination);
            try self.emitEpilogue();
        }

        fn emitEpilogue(self: *Self) !void {
            try self.saveRegisters(.restore);
            if (self.plan.stack_size != 0) try self.encoder.offset(.add_rsp, self.plan.stack_size);
            try self.encoder.emit(.ret);
        }

        fn saveRegisters(self: *Self, operation: x86.RegisterOperation) !void {
            const allocation = self.plan.registers orelse return;
            var offset = self.plan.saved_register_offset;
            for (allocation.used) |register| {
                offset = std.mem.alignForward(u32, offset, @alignOf(u64));
                try self.encoder.register(operation, register, offset);
                offset += @sizeOf(u64);
            }
        }

        fn emitCall(self: *Self, call: structures.FunctionCall, result: ValueLocation) !void {
            const destination = self.resultLocation(call.destination, result);
            const layout = self.plan.calls.get(.{ .arguments = call.arguments, .return_type = call.return_type }).?;
            try self.emitCallArguments(call, layout, destination);
            switch (call.target) {
                .direct => |instance| try self.appendRelocation(instance, try self.encoder.patchable(.call_relative), .call_relative_32),
                .initializer => |value| try self.emitInitializerCall(value),
                .indirect => |value| {
                    try self.loadAddress(self.valueLocation(value));
                    try self.encoder.emit(.call_rax);
                },
            }
            try self.recordTraceSite();
            switch (layout.result) {
                .indirect => {},
                .stack, .eax => try self.copyValue(call.return_type, layout.result, destination),
                else => unreachable,
            }
        }

        fn recordTraceSite(self: *Self) !void {
            var output: std.Io.Writer.Allocating = .init(self.gpa);
            defer output.deinit();
            var frame = self.current_frame;
            var span = self.current_span;
            while (true) {
                if (self.traceSource(frame)) |source| {
                    const location = source.location((span orelse source.fallback_span).start);
                    try output.writer.print("  at {s} ({s}:{d}:{d})\n", .{ source.name, source.path, location.line, location.column });
                }
                if (frame == .root) break;
                const inlined = self.ssa.inline_frames[@backingInt(frame)];
                span = inlined.call_span;
                frame = inlined.parent;
            }
            const label = try output.toOwnedSlice();
            errdefer self.gpa.free(label);
            try self.trace_sites.append(self.gpa, .{
                .return_offset = try self.encoder.position(),
                .stack_size = self.plan.stack_size,
                .label = label,
            });
        }

        fn traceSource(self: *const Self, frame: structures.InlineFrameId) ?TraceSource {
            const TypeView = switch (@typeInfo(Types)) {
                .pointer => |pointer| pointer.child,
                else => Types,
            };
            if (@hasField(TypeView, "inline_sources")) {
                const instance = if (frame == .root) self.ssa.root_instance else self.ssa.inline_frames[@backingInt(frame)].instance;
                if (instance) |owner| {
                    for (self.types.inline_sources) |source| {
                        if (std.meta.eql(source.instance, owner)) return source.source;
                    }
                    unreachable;
                }
            }
            if (@hasField(TypeView, "trace_source")) return self.types.trace_source;
            return null;
        }

        fn emitCallArguments(self: *Self, call: structures.FunctionCall, layout: CallLayout, destination: ValueLocation) !void {
            if (layout.result == .indirect) try self.storeValueAddress(destination, layout.result.indirect);
            for (self.ssa.call_arguments[call.arguments.start..call.arguments.end], layout.arguments) |argument, location| {
                if (argument == .initializer) {
                    std.debug.assert(location == .stack);
                    try self.copyRange(self.valueLocation(argument.valueId()), 0, .{ .value = location }, 0, initializer_layout.byte_size);
                } else if (location == .indirect) {
                    try self.storeUseAddress(argument.valueUse(), location.indirect);
                } else try self.emitUseToMemory(argument.valueUse(), location.stack);
            }
        }

        /// Stores the address of an uncoerced value into the pointer slot at `slot`.
        fn storeUseAddress(self: *Self, use: structures.FunctionValueUse, slot: u32) !void {
            std.debug.assert(use.coerce_to == null);
            try self.storeValueAddress(self.valueLocation(use.value), slot);
        }

        fn storeValueAddress(self: *Self, location: ValueLocation, slot: u32) !void {
            try self.loadValueAddress(location);
            try self.encoder.offset(.mov_rsp_rax, slot);
        }

        fn loadValueAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .indirect => |offset| try self.encoder.offset(.mov_rax_rsp, offset),
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.lea_rax_rsp, offset),
                .discarded, .immediate, .eax, .register => unreachable,
            }
        }

        fn emitFunctionReference(self: *Self, reference: structures.FunctionReference, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const field = try self.encoder.patchable(.mov_rax);
            try self.storeAddress(destination);
            try self.appendRelocation(reference.instance(), field, .address_absolute_64);
        }

        fn emitInitializerCall(self: *Self, value: structures.FunctionValueId) !void {
            const location = self.valueLocation(value);
            try self.loadValueAddress(location);
            try self.encoder.offset(.mov_rax_rax_offset, 8);
            try self.encoder.emit(.mov_rdi_rax);
            try self.loadValueAddress(location);
            try self.encoder.offset(.mov_rax_rax_offset, 0);
            try self.encoder.emit(.call_rax);
        }

        fn emitInitializerReference(self: *Self, reference: @FieldType(structures.FunctionInstruction, "initializer_ref"), destination: ValueLocation) !void {
            const offset = destination.stack;
            try self.initializer_patches.append(self.gpa, .{ .field_offset = try self.encoder.patchable(.lea_rax_rip), .region = reference.region });
            try self.encoder.offset(.mov_rsp_rax, offset);
            try self.encoder.offset(.lea_rax_rsp, offset + 16);
            try self.encoder.offset(.mov_rsp_rax, offset + 8);
            for (self.ssa.initializer_captures[reference.captures.start..reference.captures.end], 0..) |capture, index| {
                try self.storeValueAddress(self.valueLocation(capture), offset + 16 + @as(u32, @intCast(index)) * 8);
            }
        }

        fn emitInitializerRegions(self: *Self) !void {
            for (self.ssa.initializer_regions, 0..) |*region, index| {
                var compiled = try compileFunction(region, self.types, self.gpa);
                defer compiled.deinit(self.gpa);
                const start = try self.encoder.position();
                for (self.initializer_patches.items) |patch| if (patch.region == index) {
                    try self.encoder.patch(patch.field_offset, start);
                };
                try self.encoder.code.appendSlice(self.gpa, compiled.code);
                for (compiled.trace_sites) |site| {
                    const label = try self.gpa.dupe(u8, site.label);
                    errdefer self.gpa.free(label);
                    try self.trace_sites.append(self.gpa, .{
                        .return_offset = std.math.add(u32, start, site.return_offset) catch return error.FunctionTooLarge,
                        .stack_size = site.stack_size,
                        .label = label,
                    });
                }
                for (compiled.relocations) |relocation| {
                    var relocated = relocation;
                    relocated.offset = std.math.add(u32, start, relocation.offset) catch return error.FunctionTooLarge;
                    relocated.reference = switch (relocation.reference) {
                        .function => |reference| .{ .function = @fromBackingInt(try self.referenceIndex(compiled.referenced_instances[@backingInt(reference)])) },
                        .data => |data_index| .{ .data = try self.dataIndex(compiled.constant_data[data_index].bytes) },
                    };
                    try self.relocations.append(self.gpa, relocated);
                }
            }
        }

        fn appendRelocation(self: *Self, target: structures.InstanceId, offset: u32, kind: structures.CompiledFunction.RelocationKind) !void {
            const reference = try self.referenceIndex(target);
            try self.relocations.append(self.gpa, .{
                .offset = offset,
                .kind = kind,
                .reference = .{ .function = @fromBackingInt(@intCast(reference)) },
                .addend = 0,
            });
        }

        fn dataIndex(self: *Self, bytes: []const u8) !u32 {
            for (self.constant_data.items, 0..) |data, index| if (std.mem.eql(u8, data.bytes, bytes)) return @intCast(index);
            const index = std.math.cast(u32, self.constant_data.items.len) orelse return error.FunctionTooLarge;
            const owned = try self.gpa.dupe(u8, bytes);
            errdefer self.gpa.free(owned);
            try self.constant_data.append(self.gpa, .{ .bytes = owned });
            return index;
        }

        fn emitDataAddress(self: *Self, id: structures.ByteStringId, offset: u32, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const data = try self.types.byteString(id);
            std.debug.assert(offset <= data.len);
            const index = try self.dataIndex(data);
            const field = try self.encoder.patchable(.mov_rax);
            try self.relocations.append(self.gpa, .{ .offset = field, .kind = .address_absolute_64, .reference = .{ .data = index }, .addend = offset });
            try self.storeAddress(destination);
        }

        fn emitStaticString(self: *Self, constant: structures.StaticStringConstant, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const base = switch (destination) {
                .stack, .return_buffer => |offset| offset,
                .discarded, .immediate, .eax, .register, .incoming_argument, .indirect => unreachable,
            };
            const span_type = (try self.types.facts().staticStringBytes(constant.type_id)) orelse return error.Unavailable;
            const bytes_offset = ((try self.types.structLayout(constant.type_id)) orelse return error.Unavailable).field_offsets[0];
            const span_layout = (try self.types.structLayout(span_type)) orelse return error.Unavailable;
            const data_offset = std.math.add(u32, base, bytes_offset + span_layout.field_offsets[0]) catch return error.FunctionTooLarge;
            try self.emitDataAddress(constant.data, 0, if (destination == .stack) .{ .stack = data_offset } else .{ .return_buffer = data_offset });
            try self.encoder.immediate(.mov_eax, std.math.cast(i32, (try self.types.byteString(constant.data)).len) orelse return error.TypeTooLarge);
            try self.storeComponent(u32, destination, bytes_offset + span_layout.field_offsets[1]);
        }

        fn emitStorageCursor(self: *Self, operation: structures.BorrowOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const source = self.valueLocation(operation.source);
            if (try self.types.facts().arrayType(self.valueType(operation.source)) != null)
                try self.loadValueAddress(source)
            else
                try self.loadAddress(source);
            try self.storeAddress(destination);
        }

        /// Leaves the address of element `index` in rax. The elements start at
        /// the address `base` holds, or at `base` itself when `base_is_value`.
        fn emitElementAddress(self: *Self, base: ValueLocation, base_is_value: bool, index: structures.FunctionValueId, element_type: structures.TypeId) !void {
            const byte_size = (try self.types.layout(element_type)).byte_size;
            if (byte_size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            const add_scaled_index: x86.Operation = switch (byte_size) {
                2 => .lea_rax_rax_rcx_2,
                4 => .lea_rax_rax_rcx_4,
                8 => .lea_rax_rax_rcx_8,
                else => .add_rax_rcx,
            };
            if (byte_size != 0) {
                try self.loadComponent(u32, self.valueLocation(index), 0);
                try self.encoder.emit(.movsxd_rcx_eax);
                if (byte_size != 1 and add_scaled_index == .add_rax_rcx) try self.encoder.immediate(.imul_rcx, @intCast(byte_size));
            }
            if (base_is_value) try self.loadValueAddress(base) else try self.loadAddress(base);
            if (byte_size != 0) try self.encoder.emit(add_scaled_index);
        }

        fn emitCursorElement(self: *Self, operation: structures.CursorElement, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const element = (try self.types.facts().borrowElement(operation.type_id)) orelse (try self.types.facts().storageCursorAccess(operation.type_id)).?;
            try self.emitElementAddress(self.valueLocation(operation.cursor), false, operation.index, element);
            try self.storeAddress(destination);
        }

        fn referenceIndex(self: *Self, instance: structures.InstanceId) !u32 {
            const existing = try self.reference_indices.getOrPut(self.gpa, instance);
            if (existing.found_existing) return existing.value_ptr.*;
            errdefer _ = self.reference_indices.remove(instance);
            const index = std.math.cast(u32, self.referenced_instances.items.len) orelse return error.FunctionTooLarge;
            try self.referenced_instances.append(self.gpa, instance);
            existing.value_ptr.* = index;
            return index;
        }

        fn loadAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.mov_rax_rsp, offset),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.emit(.mov_rax_rax);
                },
                .discarded, .immediate, .eax, .register => unreachable,
            }
        }

        fn storeAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_rax, offset),
                .discarded => {},
                .immediate, .eax, .register, .incoming_argument, .indirect => unreachable,
            }
        }

        /// Points an indirect location at the address in rax.
        fn bindIndirect(self: *Self, location: ValueLocation) !void {
            try self.encoder.offset(.mov_rsp_rax, location.indirect);
        }

        /// Computes a 32-bit result in eax from one operand.
        fn emitUnary(self: *Self, comptime Component: type, operand: structures.FunctionValueId, operation: ?x86.Operation, destination: ValueLocation) !void {
            try self.loadComponent(Component, self.valueLocation(operand), 0);
            if (operation) |code| try self.encoder.emit(code);
            try self.storeResult(destination);
        }

        fn emitUseToMemory(self: *Self, use: structures.FunctionValueUse, offset: u32) !void {
            const target_type = use.coerce_to orelse self.valueType(use.value);
            try self.emitUse(use, target_type, .{ .stack = offset });
        }

        fn emitUse(self: *Self, use: structures.FunctionValueUse, target_type: structures.TypeId, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const actual_type = self.valueType(use.value);
            const source = self.valueLocation(use.value);
            if (use.coerce_to == null) {
                std.debug.assert(actual_type == target_type);
                return self.copyValue(target_type, source, destination);
            }
            std.debug.assert(use.coerce_to.? == target_type);
            if (try self.types.facts().callable(target_type) != null) {
                std.debug.assert(use.variant_tag_mapping == null);
                return self.copyValue(target_type, source, destination);
            }
            const mapping = use.variant_tag_mapping.?;
            try self.convertVariant(actual_type, target_type, self.ssa.variant_coercion_tags[mapping.start..mapping.end], source, destination);
        }

        fn emitVariantExtract(self: *Self, extraction: structures.VariantOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const tags = self.ssa.variant_coercion_tags;
            const mapping = if (extraction.tag_mapping) |range| tags[range.start..range.end] else &.{};
            try self.convertVariant(self.valueType(extraction.operand), extraction.target_type, mapping, self.valueLocation(extraction.operand), destination);
        }

        fn convertVariant(
            self: *Self,
            actual_type: structures.TypeId,
            target_type: structures.TypeId,
            tag_mapping: []const u32,
            source: ValueLocation,
            destination: ValueLocation,
        ) !void {
            const actual_members = try self.types.facts().variantMembers(actual_type);
            if (actual_members == null) {
                _ = (try self.types.facts().variantMembers(target_type)) orelse unreachable;
                std.debug.assert(tag_mapping.len == 1);
                const target_payload_offset = (try self.types.variantLayout(target_type)).payload_offset;
                const actual_layout = try self.types.layout(actual_type);
                try self.copyRange(source, 0, .{ .value = destination }, target_payload_offset, actual_layout.byte_size);
                try self.encoder.immediate(.mov_eax, std.math.cast(i32, tag_mapping[0]) orelse return error.FunctionTooLarge);
                try self.storeComponent(u32, destination, 0);
                return;
            }

            _ = try self.types.facts().variantMembers(target_type) orelse {
                std.debug.assert(tag_mapping.len == 0);
                const target_layout = try self.types.layout(target_type);
                const actual_payload_offset = (try self.types.variantLayout(actual_type)).payload_offset;
                return self.copyRange(source, actual_payload_offset, .{ .value = destination }, 0, target_layout.byte_size);
            };
            std.debug.assert(tag_mapping.len == actual_members.?.len);

            const actual_layout = try self.types.layout(actual_type);
            const actual_payload_offset = (try self.types.variantLayout(actual_type)).payload_offset;
            const actual_payload_size = actual_layout.byte_size - actual_payload_offset;
            const target_layout = try self.types.variantLayout(target_type);
            const target_payload_size = target_layout.layout.byte_size - target_layout.payload_offset;
            try self.copyRange(source, actual_payload_offset, .{ .value = destination }, target_layout.payload_offset, @min(actual_payload_size, target_payload_size));
            try self.loadComponent(u32, source, 0);
            try self.remapVariantTag(tag_mapping);
            try self.storeComponent(u32, destination, 0);
        }

        fn remapVariantTag(self: *Self, tag_mapping: []const u32) !void {
            var matching_count: usize = 0;
            for (tag_mapping) |target_tag| {
                if (target_tag != structures.invalid_variant_tag) matching_count += 1;
            }
            std.debug.assert(matching_count >= 2);

            var matched: usize = 0;
            var done_jumps: std.ArrayList(u32) = .empty;
            defer done_jumps.deinit(self.gpa);
            for (tag_mapping, 0..) |target_tag, source_tag| {
                if (target_tag == structures.invalid_variant_tag) continue;
                const tag = std.math.cast(i32, target_tag) orelse return error.FunctionTooLarge;
                matched += 1;
                if (matched == matching_count) {
                    try self.encoder.immediate(.mov_eax, tag);
                    break;
                }
                try self.encoder.compareEax(.{ .immediate = @intCast(source_tag) });
                const next = try self.encoder.patchable(.jne);
                try self.encoder.immediate(.mov_eax, tag);
                try done_jumps.append(self.gpa, try self.encoder.patchable(.jmp));
                try self.encoder.patchHere(next);
            }
            for (done_jumps.items) |jump| try self.encoder.patchHere(jump);
        }

        fn copyValue(self: *Self, type_id: structures.TypeId, source: ValueLocation, destination: ValueLocation) !void {
            if (destination == .discarded or std.meta.eql(source, destination)) return;
            const layout = try self.types.layout(type_id);
            try self.copyRange(source, 0, .{ .value = destination }, 0, layout.byte_size);
        }

        fn emitStorageProjection(self: *Self, operation: structures.StorageProjection, destination: ValueLocation) !void {
            // A projection into a stack value already has its own stack location.
            if (destination == .discarded or destination == .stack) return;
            const source = self.valueLocation(operation.owner);
            switch (operation.projection) {
                .box_element, .allocation_array => try self.loadAddress(source),
                .field => |index| {
                    const layout = (try self.types.structLayout(self.valueType(operation.owner))) orelse return error.Unavailable;
                    try self.loadValueAddress(source);
                    try self.encoder.addRax(layout.field_offsets[index]);
                },
                .variant => {
                    const layout = try self.types.variantLayout(self.valueType(operation.owner));
                    try self.loadValueAddress(source);
                    try self.encoder.addRax(layout.payload_offset);
                },
            }
            try self.bindIndirect(destination);
        }

        fn borrowFieldOffset(self: *Self, operation: structures.BorrowAddressOperation) !u32 {
            if (operation.fields.start == operation.fields.end) return 0;
            var type_id = self.valueType(operation.source);
            if (operation.base_is_reference) type_id = (try self.types.facts().borrowElement(type_id)) orelse unreachable;
            var offset: u32 = 0;
            for (self.ssa.borrow_fields[operation.fields.start..operation.fields.end]) |projection| switch (projection) {
                .field => |field_index| {
                    const definition = (try self.types.facts().structDefinition(type_id)) orelse unreachable;
                    const layout = (try self.types.structLayout(type_id)) orelse unreachable;
                    offset = std.math.add(u32, offset, layout.field_offsets[field_index]) catch return error.FunctionTooLarge;
                    type_id = definition.fields[field_index].type_id;
                },
                .variant => |member| {
                    const layout = try self.types.variantLayout(type_id);
                    offset = std.math.add(u32, offset, layout.payload_offset) catch return error.FunctionTooLarge;
                    type_id = member;
                },
            };
            return offset;
        }

        fn emitBorrowBox(self: *Self, operation: structures.BorrowOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            std.debug.assert((try self.types.layout(operation.type_id)).byte_size == @sizeOf(u64));
            try self.copyRange(self.valueLocation(operation.source), 0, .{ .value = destination }, 0, @sizeOf(u64));
        }

        fn emitBorrowAddress(self: *Self, operation: structures.BorrowAddressOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const source = self.valueLocation(operation.source);
            if (operation.base_is_reference) try self.loadAddress(source) else try self.loadValueAddress(source);
            try self.encoder.addRax(try self.borrowFieldOffset(operation));
            try self.storeAddress(destination);
        }

        fn emitBorrowWrite(self: *Self, operation: structures.BorrowWriteOperation) !void {
            const layout = try self.types.layout(operation.type_id);
            try self.copyRange(self.valueLocation(operation.value), 0, .{ .reference = self.valueLocation(operation.reference) }, 0, layout.byte_size);
        }

        fn emitFieldAccess(self: *Self, operation: structures.FieldAccessOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const layout = (try self.types.structLayout(self.valueType(operation.operand))) orelse return error.Unavailable;
            std.debug.assert(operation.field_index < layout.field_offsets.len);
            const field_layout = try self.types.layout(operation.field_type);
            try self.copyRange(
                self.valueLocation(operation.operand),
                layout.field_offsets[operation.field_index],
                .{ .value = destination },
                0,
                field_layout.byte_size,
            );
        }

        fn emitInitializerCaptureWrite(self: *Self, operation: structures.InitializerCaptureWrite) !void {
            std.debug.assert(self.ssa.is_initializer_region);
            const entry = self.ssa.blocks[@backingInt(self.ssa.entry)];
            std.debug.assert(operation.parameter_index < entry.argument_end - entry.argument_start);
            try self.copyValue(operation.type_id, self.valueLocation(operation.value), self.plan.locations[operation.parameter_index]);
        }

        fn copyRange(self: *Self, source: ValueLocation, source_start: u32, destination: CopyDestination, destination_start: u32, byte_size: u32) !void {
            if (byte_size == 0) return;
            if (destination == .value and destination.value == .discarded) return;
            if (byte_size > @sizeOf(u32)) return self.copyMemoryRange(source, source_start, destination, destination_start, byte_size);
            if (destination == .reference) {
                try self.loadAddress(destination.reference);
                try self.encoder.emit(.mov_rdi_rax);
            }
            var offset: u32 = 0;
            inline for (.{ u32, u8 }) |Component| {
                while (byte_size - offset >= @sizeOf(Component)) : (offset += @sizeOf(Component)) {
                    try self.loadComponent(Component, source, source_start + offset);
                    switch (destination) {
                        .value => |location| try self.storeComponent(Component, location, destination_start + offset),
                        .reference => try self.encoder.offset(if (Component == u8) .mov_rdi_al else .mov_rdi_eax, destination_start + offset),
                    }
                }
            }
        }

        fn copyMemoryRange(self: *Self, source: ValueLocation, source_start: u32, destination: CopyDestination, destination_start: u32, byte_size: u32) !void {
            if (byte_size > 256) {
                try self.loadCopyAddress(.{ .value = source });
                try self.encoder.addRax(source_start);
                try self.encoder.emit(.mov_rsi_rax);
                try self.loadCopyAddress(destination);
                try self.encoder.addRax(destination_start);
                try self.encoder.emit(.mov_rdi_rax);
                try self.encoder.immediate(.mov_ecx, @bitCast(byte_size));
                return self.encoder.emit(.rep_movsb);
            }
            const source_address = try self.prepareCopyAddress(.{ .value = source }, .rsi);
            const destination_address = try self.prepareCopyAddress(destination, .rdi);
            var offset: u32 = 0;
            inline for (.{ u64, u32, u8 }) |Component| {
                while (byte_size - offset >= @sizeOf(Component)) : (offset += @sizeOf(Component)) {
                    try self.copyComponent(Component, source_address, source_start + offset, destination_address, destination_start + offset);
                }
            }
        }

        /// Loads the address of a copy's first byte into rax.
        fn loadCopyAddress(self: *Self, address: CopyDestination) !void {
            switch (address) {
                .value => |location| try self.loadValueAddress(location),
                .reference => |location| try self.loadAddress(location),
            }
        }

        fn prepareCopyAddress(self: *Self, address: CopyDestination, comptime register: enum { rsi, rdi }) !CopyAddress {
            if (address == .value) switch (address.value) {
                .stack, .incoming_argument, .return_buffer => |offset| return .{ .stack = offset },
                else => {},
            };
            try self.loadCopyAddress(address);
            try self.encoder.emit(if (register == .rsi) .mov_rsi_rax else .mov_rdi_rax);
            return .pointer;
        }

        fn copyComponent(self: *Self, comptime Component: type, source: CopyAddress, source_offset: u32, destination: CopyAddress, destination_offset: u32) !void {
            const load: x86.Operation = if (Component == u64)
                (if (source == .stack) .mov_rax_rsp else .mov_rax_rsi_offset)
            else if (Component == u32)
                (if (source == .stack) .mov_eax_rsp else .mov_eax_rsi_offset)
            else
                (if (source == .stack) .movzx_eax_rsp else .movzx_eax_rsi_offset);
            const store: x86.Operation = if (Component == u64)
                (if (destination == .stack) .mov_rsp_rax else .mov_rdi_rax_offset)
            else if (Component == u32)
                (if (destination == .stack) .mov_rsp_eax else .mov_rdi_eax)
            else
                (if (destination == .stack) .mov_rsp_al else .mov_rdi_al);
            const source_base = if (source == .stack) source.stack else 0;
            const destination_base = if (destination == .stack) destination.stack else 0;
            try self.encoder.offset(load, std.math.add(u32, source_base, source_offset) catch return error.FunctionTooLarge);
            try self.encoder.offset(store, std.math.add(u32, destination_base, destination_offset) catch return error.FunctionTooLarge);
        }

        fn loadComponent(self: *Self, comptime Component: type, location: ValueLocation, component_offset: u32) !void {
            std.debug.assert(Component == u8 or Component == u32);
            switch (location) {
                .immediate => |value| try self.encoder.immediate(.mov_eax, immediateComponent(Component, value, component_offset)),
                .eax => std.debug.assert(component_offset == 0),
                .register => |register| {
                    std.debug.assert(component_offset == 0);
                    try self.encoder.register(.load_eax, register, 0);
                },
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(if (Component == u8) .movzx_eax_rsp else .mov_eax_rsp, std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.offset(if (Component == u8) .movzx_eax_rax else .mov_eax_rax, component_offset);
                },
                .discarded => unreachable,
            }
        }

        fn storeComponent(self: *Self, comptime Component: type, location: ValueLocation, component_offset: u32) !void {
            std.debug.assert(Component == u8 or Component == u32);
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(if (Component == u8) .mov_rsp_al else .mov_rsp_eax, std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .eax => std.debug.assert(component_offset == 0),
                .register => |register| {
                    std.debug.assert(component_offset == 0);
                    try self.encoder.register(.store_eax, register, 0);
                },
                .discarded => {},
                .immediate => unreachable,
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rdi_rsp, offset);
                    try self.encoder.offset(if (Component == u8) .mov_rdi_al else .mov_rdi_eax, component_offset);
                },
            }
        }

        fn storeResult(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_eax, offset),
                .eax, .discarded => {},
                .register => |register| try self.encoder.register(.store_eax, register, 0),
                .immediate, .incoming_argument, .indirect => unreachable,
            }
        }

        fn finish(self: *Self) !structures.CompiledFunction {
            var artifact: structures.CompiledFunction = .{ .required_alignment = 1 };
            errdefer artifact.deinit(self.gpa);
            artifact.relocations = try self.relocations.toOwnedSlice(self.gpa);
            artifact.trace_sites = try self.trace_sites.toOwnedSlice(self.gpa);
            artifact.referenced_instances = try self.referenced_instances.toOwnedSlice(self.gpa);
            artifact.constant_data = try self.constant_data.toOwnedSlice(self.gpa);
            artifact.code = try self.encoder.code.toOwnedSlice(self.gpa);
            return artifact;
        }
    };
}

pub fn compileFunction(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator) anyerror!structures.CompiledFunction {
    std.debug.assert(ssa.blocks.len != 0);
    std.debug.assert(@backingInt(ssa.entry) < ssa.blocks.len);
    var plan = try LocationPlan.init(ssa, types, gpa);
    defer plan.deinit(gpa);
    var emitter = try FunctionEmitter(@TypeOf(types)).init(gpa, ssa, &plan, types);
    defer emitter.deinit();
    try emitter.emit();
    try emitter.emitInitializerRegions();
    return emitter.finish();
}

// External functions have no frame: incoming argument storage starts at
// rsp + 8, past the return address.

pub fn compileExternalExit(gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder: X86Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    try encoder.offset(.mov_eax_rsp, 8);
    try encoder.emit(.mov_edi_eax);
    try encoder.immediate(.mov_eax, linux_exit_syscall);
    try encoder.emit(.syscall);
    return externalArtifact(&encoder);
}

pub fn compileExternalPanic(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    var layout = try signatureLayout(types, signature, gpa);
    defer layout.deinit(gpa);
    const message = layout.arguments[0];
    var encoder: X86Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    try emitPanicMessage(&encoder, message);
    try encoder.emit(.test_edx);
    const bare = try encoder.patchable(.je);
    const prefix_address = try emitPanicText(&encoder, 7);
    const ready = try encoder.patchable(.jmp);
    try encoder.patchHere(bare);
    const bare_address = try emitPanicText(&encoder, 5);
    try encoder.patchHere(ready);
    const prefix_write = try encoder.patchable(.call_relative);
    try emitPanicMessage(&encoder, message);
    try encoder.emit(.mov_rsi_rax);
    const message_write = try encoder.patchable(.call_relative);
    const newline_address = try emitPanicText(&encoder, 1);
    const newline_write = try encoder.patchable(.call_relative);
    const trace = try encoder.patchable(.jmp);
    const writer = try encoder.position();
    try emitPanicWriter(&encoder);
    for ([_]u32{ prefix_write, message_write, newline_write }) |call| try encoder.patch(call, writer);
    try encoder.patchHere(prefix_address);
    try encoder.patchHere(bare_address);
    try encoder.code.appendSlice(gpa, "panic: ");
    try encoder.patchHere(newline_address);
    try encoder.code.append(gpa, '\n');
    var artifact = try externalArtifact(&encoder);
    artifact.panic_trace_offset = trace;
    artifact.requires_sigpipe_ignore = true;
    return artifact;
}

/// Leaves a span argument's byte count in edx and its data address in rax.
fn emitPanicMessage(encoder: *X86Encoder, message: ValueLocation) !void {
    try emitIncomingSize(encoder, message);
    try encoder.emit(.mov_edx_eax);
    try emitIncomingAddress(encoder, message);
}

/// Loads the 64-bit address at the start of an incoming argument into rax.
fn emitIncomingAddress(encoder: *X86Encoder, argument: ValueLocation) !void {
    switch (argument) {
        .stack => |offset| try encoder.offset(.mov_rax_rsp, 8 + offset),
        .indirect => |offset| {
            try encoder.offset(.mov_rax_rsp, 8 + offset);
            try encoder.emit(.mov_rax_rax);
        },
        else => unreachable,
    }
}

/// Loads the 32-bit size following that address into eax.
fn emitIncomingSize(encoder: *X86Encoder, argument: ValueLocation) !void {
    switch (argument) {
        .stack => |offset| try encoder.offset(.mov_eax_rsp, 8 + offset + 8),
        .indirect => |offset| {
            try encoder.offset(.mov_rax_rsp, 8 + offset);
            try encoder.offset(.mov_eax_rax, 8);
        },
        else => unreachable,
    }
}

fn emitPanicText(encoder: *X86Encoder, size: i32) !u32 {
    const address = try encoder.patchable(.lea_rax_rip);
    try encoder.emit(.mov_rsi_rax);
    try encoder.immediate(.mov_edx, size);
    return address;
}

/// Best-effort, allocation-free stderr output. Failed writes never panic again.
fn emitPanicWriter(encoder: *X86Encoder) !void {
    try encoder.emit(.test_edx);
    const empty = try encoder.patchable(.je);
    const retry = try encoder.position();
    try encoder.immediate(.mov_eax, 1);
    try encoder.immediate(.mov_edi, 2);
    try encoder.emit(.syscall);
    try encoder.immediate(.cmp_eax, -4);
    try encoder.jumpBack(.je, retry);
    try encoder.immediate(.cmp_eax, 0);
    const failed = try encoder.patchable(.jle);
    try encoder.emit(.add_rsi_rax);
    try encoder.emit(.sub_rdx_rax);
    try encoder.emit(.test_edx);
    try encoder.jumpBack(.jne, retry);
    try encoder.patchHere(empty);
    try encoder.patchHere(failed);
    try encoder.emit(.ret);
}

/// Walk only known call sites. The startup call has no record and ends the walk.
/// Metadata describes the existing frames; successful calls execute no tracing.
/// Returns the offset of the table address field.
fn emitPanicTrace(encoder: *X86Encoder) !u32 {
    try encoder.emit(.mov_r12_rsp);
    try encoder.immediate(.mov_r15d, 1024);
    const frame = try encoder.position();
    try encoder.emit(.mov_r13_r12);
    try encoder.emit(.add_r12_8);
    const table_address = try encoder.patchable(.mov_r14);
    const search = try encoder.position();
    try encoder.emit(.mov_rax_r14);
    try encoder.emit(.test_rax);
    const unknown = try encoder.patchable(.je);
    try encoder.emit(.cmp_rax_r13);
    const found = try encoder.patchable(.je);
    try encoder.emit(.add_r14_32);
    try encoder.jumpBack(.jmp, search);
    try encoder.patchHere(found);
    try encoder.offset(.mov_rsi_r14_offset, 16);
    try encoder.offset(.mov_edx_r14_offset, 24);
    const write = try encoder.patchable(.call_relative);
    try encoder.offset(.mov_rax_r14_offset, 8);
    try encoder.emit(.add_r12_rax);
    try encoder.emit(.dec_r15d);
    try encoder.jumpBack(.jne, frame);
    try encoder.patchHere(unknown);
    try encoder.immediate(.mov_edi, 134);
    try encoder.immediate(.mov_eax, linux_exit_syscall);
    try encoder.emit(.syscall);
    try encoder.emit(.ud2);
    try encoder.patchHere(write);
    try emitPanicWriter(encoder);
    return table_address;
}

pub fn compileExternalAllocateHostStorage(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    return compileExternalAllocateStorage(signature, types, gpa, 1, false);
}

pub fn compileExternalAllocateHostTypedStorage(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator, element: structures.TypeLayout) !structures.CompiledFunction {
    if (element.byte_alignment > 4096) return error.UnsupportedAllocationAlignment;
    return compileExternalAllocateStorage(signature, types, gpa, element.byte_size, true);
}

fn compileExternalAllocateStorage(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator, element_size: u32, with_count: bool) !structures.CompiledFunction {
    var encoder: X86Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    var call = try signatureLayout(types, signature, gpa);
    defer call.deinit(gpa);
    const result = try optionalReturn(types, signature.return_type);
    const argument_offset = call.arguments[0].stack + 8;
    try encoder.offset(.mov_esi_rsp, argument_offset);
    try encoder.emit(.test_esi);
    const invalid_size = try encoder.patchable(.jl);
    const oversized_element = if (element_size > std.math.maxInt(i32)) try encoder.patchable(.jne) else null;
    const multiply_size = element_size > 1 and element_size <= std.math.maxInt(i32);
    if (multiply_size) {
        try encoder.immediate(.imul_rsi, @intCast(element_size));
        try encoder.immediate(.cmp_rsi, std.math.maxInt(i32));
    }
    const size_overflow = if (multiply_size) try encoder.patchable(.ja) else null;
    if (element_size == 0 or oversized_element != null) {
        try encoder.immediate(.mov_esi, 1);
    } else {
        try encoder.emit(.test_esi);
        const nonzero_size = try encoder.patchable(.jne);
        try encoder.immediate(.mov_esi, 1);
        try encoder.patchHere(nonzero_size);
    }
    try encoder.emit(.zero_edi);
    try encoder.immediate(.mov_edx, 3);
    try encoder.immediate(.mov_r10d, 0x22);
    try encoder.immediate(.mov_r8d, -1);
    try encoder.emit(.zero_r9d);
    try encoder.immediate(.mov_eax, linux_mmap_syscall);
    try encoder.emit(.syscall);
    try encoder.immediate(.cmp_rax, -4095);
    const allocation_failed = try encoder.patchable(.jae);
    try encoder.offset(.mov_rsp_eax, result.payload);
    try encoder.emit(.shr_rax_32);
    try encoder.offset(.mov_rsp_eax, result.payload + 4);
    try encoder.emit(.mov_eax_esi);
    try encoder.offset(.mov_rsp_eax, result.payload + 8);
    if (with_count) {
        try encoder.offset(.mov_eax_rsp, argument_offset);
        try encoder.offset(.mov_rsp_eax, result.payload + 12);
    }
    try emitOptionalReturn(&encoder, result, true);
    for ([_]?u32{ invalid_size, allocation_failed, size_overflow, oversized_element }) |failure| {
        if (failure) |field| try encoder.patchHere(field);
    }
    try emitOptionalReturn(&encoder, result, false);
    return externalArtifact(&encoder);
}

pub fn compileExternalDeallocateHostStorage(gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder: X86Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    // The only argument refers to the storage's address and byte size.
    const storage: ValueLocation = .{ .indirect = 0 };
    try emitIncomingAddress(&encoder, storage);
    try encoder.emit(.mov_rdi_rax);
    try emitIncomingSize(&encoder, storage);
    try encoder.emit(.mov_esi_eax);
    try encoder.immediate(.mov_eax, linux_munmap_syscall);
    try encoder.emit(.syscall);
    try encoder.emit(.ret);
    return externalArtifact(&encoder);
}

pub fn compileExternalAllocationCount(gpa: std.mem.Allocator, count_offset: u32) !structures.CompiledFunction {
    var encoder: X86Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    try encoder.offset(.mov_eax_rsp, count_offset + 8);
    try encoder.emit(.ret);
    return externalArtifact(&encoder);
}

pub fn compileExternalByteIo(read: bool, signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    var layout = try signatureLayout(types, signature, gpa);
    defer layout.deinit(gpa);
    // Arguments are (descriptor, allocation, offset, count) to read and
    // (descriptor, span) to write.
    const arguments = layout.arguments;
    const result = try optionalReturn(types, signature.return_type);
    var encoder: X86Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    if (read) try encoder.offset(.mov_eax_rsp, 8 + arguments[3].stack) else try emitIncomingSize(&encoder, arguments[1]);
    try encoder.immediate(.cmp_eax, 0);
    const empty = try encoder.patchable(.je);
    try encoder.emit(.mov_edx_eax);
    const retry = try encoder.position();
    try encoder.offset(.mov_edi_rsp, 8 + arguments[0].stack);
    if (read) {
        try encoder.offset(.mov_eax_rsp, 8 + arguments[2].stack);
        try encoder.emit(.movsxd_rcx_eax);
    }
    try emitIncomingAddress(&encoder, arguments[1]);
    if (read) try encoder.emit(.add_rax_rcx);
    try encoder.emit(.mov_rsi_rax);
    try encoder.immediate(.mov_eax, if (read) 0 else 1);
    try encoder.emit(.syscall);
    try encoder.immediate(.cmp_eax, -4);
    try encoder.jumpBack(.je, retry);
    try encoder.immediate(.cmp_eax, 0);
    const failed = try encoder.patchable(.jl);
    try encoder.patchHere(empty);
    try encoder.offset(.mov_rsp_eax, result.payload);
    try emitOptionalReturn(&encoder, result, true);
    try encoder.patchHere(failed);
    try emitOptionalReturn(&encoder, result, false);
    var artifact = try externalArtifact(&encoder);
    artifact.requires_sigpipe_ignore = !read;
    return artifact;
}

fn signatureLayout(types: anytype, signature: structures.FunctionSignature, gpa: std.mem.Allocator) !CallLayout {
    const parameters = try gpa.alloc(structures.FunctionBlockArgument, signature.parameters.len);
    defer gpa.free(parameters);
    for (parameters, signature.parameters) |*argument, parameter| argument.* = .{ .type_id = parameter.type_id };
    return CallLayout.init(types, signature.return_type, parameters, gpa);
}

const OptionalReturn = struct { tag: u32, payload: u32, present: i32, absent: i32 };

fn optionalReturn(types: anytype, type_id: structures.TypeId) !OptionalReturn {
    const members = (try types.facts().variantMembers(type_id)).?;
    std.debug.assert(members.len == 2);
    const absent = std.mem.indexOfScalar(structures.TypeId, members, .none).?;
    const layout = try types.variantLayout(type_id);
    return .{ .tag = 8, .payload = 8 + layout.payload_offset, .present = @intCast(1 - absent), .absent = @intCast(absent) };
}

fn emitOptionalReturn(encoder: *X86Encoder, result: OptionalReturn, present: bool) !void {
    try encoder.immediate(.mov_eax, if (present) result.present else result.absent);
    try encoder.offset(.mov_rsp_eax, result.tag);
    try encoder.emit(.ret);
}

fn externalArtifact(encoder: *X86Encoder) !structures.CompiledFunction {
    return .{ .code = try encoder.code.toOwnedSlice(encoder.gpa), .required_alignment = 1 };
}

pub const ReachableFunction = struct {
    instance: structures.InstanceId,
    /// Shallow borrowed artifact; its owned slices outlive buildExecutable.
    artifact: structures.CompiledFunction,
};

pub fn buildExecutable(
    entry: structures.InstanceId,
    functions: []const ReachableFunction,
    gpa: std.mem.Allocator,
) !structures.Executable {
    return buildExecutableWithResultAllocator(entry, functions, gpa, gpa);
}

pub fn buildExecutableWithResultAllocator(
    entry: structures.InstanceId,
    functions: []const ReachableFunction,
    gpa: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
) !structures.Executable {
    for (functions) |function| {
        std.debug.assert(function.artifact.code.len != 0);
        std.debug.assert(function.artifact.required_alignment != 0);
        std.debug.assert(std.math.isPowerOfTwo(function.artifact.required_alignment));
    }

    var function_indices = std.AutoHashMap(structures.InstanceId, usize).init(gpa);
    defer function_indices.deinit();
    const function_count = std.math.cast(u32, functions.len) orelse return error.FileTooBig;
    try function_indices.ensureTotalCapacity(function_count);
    for (functions, 0..) |function, index| {
        const result = function_indices.getOrPutAssumeCapacity(function.instance);
        std.debug.assert(!result.found_existing);
        result.value_ptr.* = index;
    }
    const entry_index = function_indices.get(entry) orelse unreachable;
    for (functions) |function| {
        for (function.artifact.referenced_instances) |target| {
            std.debug.assert(function_indices.contains(target));
        }
    }

    // One load segment maps the whole file, headers first, so the address of
    // image offset `offset` is `image_base + offset`.
    var image: X86Encoder = .{ .gpa = result_allocator };
    defer image.deinit();
    try image.code.appendNTimes(result_allocator, 0, code_file_offset);
    for (functions) |function| if (function.artifact.requires_sigpipe_ignore) {
        try emitIgnoreSigpipe(&image);
        break;
    };
    const entry_call = try image.patchable(.call_relative);
    try image.immediate(.mov_edi, 0);
    try image.immediate(.mov_eax, linux_exit_syscall);
    try image.emit(.syscall);

    const needs_panic_trace = for (functions) |function| {
        if (function.artifact.panic_trace_offset != null) break true;
    } else false;
    var bulk_capacity = image.code.items.len;
    for (functions) |function| {
        bulk_capacity = try std.math.add(usize, bulk_capacity, function.artifact.required_alignment - 1);
        bulk_capacity = try std.math.add(usize, bulk_capacity, function.artifact.code.len);
        if (needs_panic_trace) for (function.artifact.trace_sites) |site| {
            bulk_capacity = try std.math.add(usize, bulk_capacity, site.label.len);
            bulk_capacity = try std.math.add(usize, bulk_capacity, @sizeOf([4]u64));
        };
    }
    try image.code.ensureTotalCapacity(result_allocator, bulk_capacity);

    const function_offsets = try gpa.alloc(usize, functions.len);
    defer gpa.free(function_offsets);
    for (functions, function_offsets) |function, *function_offset| {
        const address = std.mem.alignForward(u64, image_base + image.code.items.len, function.artifact.required_alignment);
        function_offset.* = @intCast(address - image_base);
        try image.code.appendNTimes(result_allocator, 0x90, function_offset.* - image.code.items.len);
        try image.code.appendSlice(result_allocator, function.artifact.code);
    }
    try image.patch(entry_call, function_offsets[entry_index]);

    if (needs_panic_trace) try appendPanicTrace(&image, functions, function_offsets);

    // Data follows code in the read-only load segment. Intern by content across
    // functions, retaining an addressable byte even for the empty sequence.
    var data_offsets: std.StringHashMapUnmanaged(usize) = .empty;
    defer data_offsets.deinit(gpa);
    for (functions) |function| for (function.artifact.constant_data) |data| {
        const interned = try data_offsets.getOrPut(gpa, data.bytes);
        if (interned.found_existing) continue;
        interned.value_ptr.* = image.code.items.len;
        try image.code.appendSlice(result_allocator, data.bytes);
        if (data.bytes.len == 0) try image.code.append(result_allocator, 0);
    };

    for (functions, function_offsets) |function, function_offset| for (function.artifact.relocations) |relocation| {
        const target = switch (relocation.reference) {
            .function => |reference| function_offsets[function_indices.get(function.artifact.referenced_instances[@backingInt(reference)]).?],
            .data => |index| data_offsets.get(function.artifact.constant_data[index].bytes).?,
        };
        const field = function_offset + relocation.offset;
        switch (relocation.kind) {
            .call_relative_32 => try patchRelativeDisplacement(image.code.items, field, target, field + @sizeOf(i32), relocation.addend),
            .address_absolute_64 => try patchAbsoluteAddress(image.code.items, field, image_base + target, relocation.addend),
        }
    };

    writeElfHeaders(image.code.items);
    return .{ .bytes = try image.code.toOwnedSlice(result_allocator) };
}

/// Appends the panic trace walker, then its call-site labels and the table
/// that refers to them.
fn appendPanicTrace(image: *X86Encoder, functions: []const ReachableFunction, function_offsets: []const usize) !void {
    const trace = image.code.items.len;
    const table_field = try emitPanicTrace(image);
    for (functions, function_offsets) |function, function_offset| if (function.artifact.panic_trace_offset) |field| {
        try image.patch(function_offset + field, trace);
    };
    // Labels precede the fixed-width table; pointers are final ELF addresses.
    const labels = image.code.items.len;
    for (functions) |function| for (function.artifact.trace_sites) |site| {
        try image.code.appendSlice(image.gpa, site.label);
    };
    try patchAbsoluteAddress(image.code.items, table_field, image_base + image.code.items.len, 0);
    var label = labels;
    for (functions, function_offsets) |function, function_offset| for (function.artifact.trace_sites) |site| {
        for ([_]u64{ image_base + function_offset + site.return_offset, site.stack_size, image_base + label, site.label.len }) |word| {
            try image.code.appendSlice(image.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, word)));
        }
        label += site.label.len;
    };
    try image.code.appendNTimes(image.gpa, 0, @sizeOf(u64));
}

// A broken stream returns none, including a closed pipe.
// Install SIG_IGN once before entry rather than changing it on every write.
fn emitIgnoreSigpipe(encoder: *X86Encoder) !void {
    try encoder.offset(.sub_rsp, 32);
    try encoder.absolute(.mov_rax, 1);
    try encoder.offset(.mov_rsp_rax, 0);
    try encoder.absolute(.mov_rax, 0);
    for ([_]u32{ 8, 16, 24 }) |offset| try encoder.offset(.mov_rsp_rax, offset);
    try encoder.immediate(.mov_eax, 13); // rt_sigaction
    try encoder.immediate(.mov_edi, 13); // SIGPIPE
    try encoder.offset(.lea_rsi_rsp, 0);
    try encoder.emit(.zero_edx);
    try encoder.immediate(.mov_r10d, 8); // kernel sigset size
    try encoder.emit(.syscall);
    try encoder.offset(.add_rsp, 32);
}

pub fn executableCode(executable: structures.Executable) []const u8 {
    std.debug.assert(executable.bytes.len >= code_file_offset);
    return executable.bytes[code_file_offset..];
}

/// Patches a call-relative-32 field so it resolves to `target_address`, per
/// the ABI's site-relative-to-next-instruction convention: the encoded value
/// is `target_address + addend - site_end_address`.
fn patchRelativeDisplacement(
    buffer: []u8,
    field_offset: usize,
    target_address: u64,
    site_end_address: u64,
    addend: i64,
) error{RelocationOverflow}!void {
    const displacement: i128 = @as(i128, target_address) + addend - @as(i128, site_end_address);
    if (displacement < std.math.minInt(i32) or displacement > std.math.maxInt(i32)) return error.RelocationOverflow;
    std.mem.writeInt(i32, buffer[field_offset..][0..@sizeOf(i32)], @intCast(displacement), .little);
}

fn patchAbsoluteAddress(buffer: []u8, field_offset: usize, target_address: u64, addend: i64) error{RelocationOverflow}!void {
    const address: i128 = @as(i128, target_address) + addend;
    if (address < 0 or address > std.math.maxInt(u64)) return error.RelocationOverflow;
    std.mem.writeInt(u64, buffer[field_offset..][0..@sizeOf(u64)], @intCast(address), .little);
}

/// Fills the ELF64 header and the one load segment that maps the whole file.
/// Sections are omitted because the Linux program loader only needs segments.
fn writeElfHeaders(image: []u8) void {
    const header: std.elf.Elf64.Ehdr = .{
        .ident = .{ .class = .@"64", .data = .@"2LSB", .version = 1, .osabi = .NONE, .abiversion = 0 },
        .type = .EXEC,
        .machine = .X86_64,
        .version = 1,
        .entry = image_base + code_file_offset,
        .phoff = @sizeOf(std.elf.Elf64.Ehdr),
        .shoff = 0,
        .flags = .{ .int = 0 },
        .ehsize = @sizeOf(std.elf.Elf64.Ehdr),
        .phentsize = @sizeOf(std.elf.Elf64.Phdr),
        .phnum = 1,
        .shentsize = 0,
        .shnum = 0,
        .shstrndx = 0,
    };
    const segment: std.elf.Elf64.Phdr = .{
        .type = .LOAD,
        .flags = .{ .R = true, .X = true },
        .offset = 0,
        .vaddr = image_base,
        .paddr = image_base,
        .filesz = image.len,
        .memsz = image.len,
        .@"align" = 0x1000,
    };
    @memcpy(image[0..@sizeOf(std.elf.Elf64.Ehdr)], std.mem.asBytes(&header));
    @memcpy(image[@sizeOf(std.elf.Elf64.Ehdr)..code_file_offset], std.mem.asBytes(&segment));
}

const X86Encoder = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    label_end: usize = 0,
    last_store: struct { operation: x86.Operation, offset: u32, end: usize } = .{ .operation = .ret, .offset = 0, .end = 0 },

    fn deinit(self: *X86Encoder) void {
        self.code.deinit(self.gpa);
    }

    fn position(self: *X86Encoder) error{FunctionTooLarge}!u32 {
        self.label_end = self.code.items.len;
        return std.math.cast(u32, self.code.items.len) orelse error.FunctionTooLarge;
    }

    fn emit(self: *X86Encoder, operation: x86.Operation) !void {
        std.debug.assert(x86.encoding(operation).operand == .none);
        try x86.append(&self.code, self.gpa, operation, 0);
    }

    fn register(self: *X86Encoder, operation: x86.RegisterOperation, selected: x86.Register, value: u32) !void {
        try x86.appendRegister(&self.code, self.gpa, operation, selected, value);
    }

    fn immediate(self: *X86Encoder, operation: x86.Operation, value: i32) !void {
        std.debug.assert(x86.encoding(operation).operand == .i32);
        try x86.append(&self.code, self.gpa, operation, @as(u32, @bitCast(value)));
    }

    fn offset(self: *X86Encoder, operation: x86.Operation, value: u32) !void {
        std.debug.assert(x86.encoding(operation).operand == .u32);
        const store = self.last_store;
        const reload: x86.Operation = if (store.operation == .mov_rsp_eax) .mov_eax_rsp else .mov_rax_rsp;
        if (store.end == self.code.items.len and self.label_end != store.end and store.offset == value and operation == reload) return;
        try x86.append(&self.code, self.gpa, operation, value);
        if (operation == .mov_rsp_eax or operation == .mov_rsp_rax)
            self.last_store = .{ .operation = operation, .offset = value, .end = self.code.items.len };
    }

    fn absolute(self: *X86Encoder, operation: x86.Operation, value: u64) !void {
        std.debug.assert(x86.encoding(operation).operand == .u64);
        try x86.append(&self.code, self.gpa, operation, value);
    }

    /// Emits `operation` with a zero operand and returns the operand's code
    /// offset for a later patch.
    fn patchable(self: *X86Encoder, operation: x86.Operation) !u32 {
        const encoding = x86.encoding(operation);
        std.debug.assert(encoding.compact == .none);
        const field = std.math.cast(u32, self.code.items.len + encoding.prefix.len) orelse return error.FunctionTooLarge;
        try x86.append(&self.code, self.gpa, operation, 0);
        return field;
    }

    /// Points the 32-bit relative field at code offset `field` to code offset `target`.
    fn patch(self: *X86Encoder, field: usize, target: usize) error{RelocationOverflow}!void {
        try patchRelativeDisplacement(self.code.items, field, target, field + @sizeOf(i32), 0);
    }

    fn patchHere(self: *X86Encoder, field: usize) !void {
        try self.patch(field, try self.position());
    }

    /// Emits a jump or call to already emitted code.
    fn jumpBack(self: *X86Encoder, operation: x86.Operation, target: usize) !void {
        try self.patch(try self.patchable(operation), target);
    }

    fn conditionalJump(self: *X86Encoder, operation: structures.PredicateOperation) !u32 {
        return self.patchable(switch (operation) {
            .lti => .jl,
            .gti => .jg,
            .lei => .jle,
            .gei => .jge,
            .eqi, .eqb => .je,
            .nei, .neb => .jne,
            .eqt, .net => unreachable,
        });
    }

    /// Adds a byte offset to rax; a zero offset emits nothing.
    fn addRax(self: *X86Encoder, value: u32) !void {
        if (value == 0) return;
        try self.immediate(.add_rax, std.math.cast(i32, value) orelse return error.FunctionTooLarge);
    }

    fn compareEax(self: *X86Encoder, rhs: ValueLocation) !void {
        switch (rhs) {
            .immediate => |value| try self.immediate(.cmp_eax, value),
            .register => |selected| try self.register(.cmp_eax, selected, 0),
            .stack, .incoming_argument => |stack_offset| try self.offset(.cmp_eax_rsp, stack_offset),
            .indirect => |stack_offset| {
                try self.offset(.mov_rcx_rsp, stack_offset);
                try self.emit(.cmp_eax_rcx);
            },
            .eax, .return_buffer, .discarded => unreachable,
        }
    }

    fn integerBinary(self: *X86Encoder, comptime operation: std.meta.Tag(structures.FunctionInstruction), rhs: ValueLocation) !void {
        if (operation == .divsi) return self.divide(rhs);
        const encoding: struct { immediate: x86.Operation, stack: x86.Operation, indirect: x86.Operation } = switch (operation) {
            .addi => .{ .immediate = .add_eax, .stack = .add_eax_rsp, .indirect = .add_eax_rcx },
            .subi => .{ .immediate = .sub_eax, .stack = .sub_eax_rsp, .indirect = .sub_eax_rcx },
            .muli => .{ .immediate = .imul_eax, .stack = .imul_eax_rsp, .indirect = .imul_eax_rcx },
            else => comptime unreachable,
        };
        switch (rhs) {
            .immediate => |value| try self.immediate(encoding.immediate, value),
            .register => |selected| try self.register(switch (operation) {
                .addi => .add_eax,
                .subi => .sub_eax,
                .muli => .imul_eax,
                else => comptime unreachable,
            }, selected, 0),
            .stack, .incoming_argument => |stack_offset| try self.offset(encoding.stack, stack_offset),
            .indirect => |stack_offset| {
                try self.offset(.mov_rcx_rsp, stack_offset);
                try self.emit(encoding.indirect);
            },
            .eax, .return_buffer, .discarded => unreachable,
        }
    }

    fn divide(self: *X86Encoder, rhs: ValueLocation) !void {
        switch (rhs) {
            .register => |selected| try self.register(.load_ecx, selected, 0),
            .immediate => |value| {
                if (value == -1) return self.emit(.neg_eax);
                try self.immediate(.mov_ecx, value);
                try self.emit(.cdq);
                return self.emit(.idiv_ecx);
            },
            .stack, .incoming_argument => |stack_offset| try self.offset(.mov_ecx_rsp, stack_offset),
            .indirect => |stack_offset| {
                try self.offset(.mov_rcx_rsp, stack_offset);
                try self.emit(.mov_ecx_rcx);
            },
            .eax, .return_buffer, .discarded => unreachable,
        }
        try self.immediate(.cmp_ecx, -1);
        const quotient = try self.patchable(.jne);
        try self.emit(.neg_eax);
        const done = try self.patchable(.jmp);
        try self.patchHere(quotient);
        try self.emit(.cdq);
        try self.emit(.idiv_ecx);
        try self.patchHere(done);
    }
};
