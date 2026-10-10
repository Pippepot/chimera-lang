const std = @import("std");
const x86 = @import("x86_encoding.zig");
const structures = @import("../structures.zig");

const image_base: u64 = 0x400000;
const linux_exit_syscall: i32 = 60;
const linux_mmap_syscall: i32 = 9;
const linux_munmap_syscall: i32 = 11;

const Elf64Header = extern struct {
    ident: [16]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const Elf64Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

const code_file_offset = @sizeOf(Elf64Header) + @sizeOf(Elf64Phdr);

const ValueLocation = union(enum) {
    discarded,
    immediate: i32,
    eax,
    stack: u32,
    incoming_argument: u32,
    return_buffer: u32,
    indirect: u32,
};

const CopyDestination = union(enum) {
    value: ValueLocation,
    reference: ValueLocation,
};

const indirect_layout: structures.TypeLayout = .{ .byte_size = @sizeOf(u64), .byte_alignment = @alignOf(u64) };
const initializer_layout: structures.TypeLayout = .{ .byte_size = 16, .byte_alignment = 8 };
const zero_sized_address_layout: structures.TypeLayout = .{ .byte_size = 1, .byte_alignment = 1 };

fn argumentByAddress(types: anytype, type_id: structures.TypeId, representation: structures.ValueRepresentation) !bool {
    return representation == .storage or (representation == .value and try types.facts().argumentPassing(type_id) == .indirect);
}

fn argumentLayout(types: anytype, type_id: structures.TypeId, representation: structures.ValueRepresentation) !structures.TypeLayout {
    if (representation == .initializer) return initializer_layout;
    return if (try argumentByAddress(types, type_id, representation)) indirect_layout else try types.layout(type_id);
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

fn alignForward32(value: u32, alignment: u32) error{FunctionTooLarge}!u32 {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    const with_padding = std.math.add(u32, value, alignment - 1) catch return error.FunctionTooLarge;
    return with_padding & ~(alignment - 1);
}

fn reserveStack(end: *u32, layout: structures.TypeLayout) error{FunctionTooLarge}!u32 {
    const offset = try alignForward32(end.*, layout.byte_alignment);
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

fn blockArgumentLayout(types: anytype, argument: structures.FunctionBlockArgument) !structures.TypeLayout {
    return argumentLayout(types, argument.type_id, argument.representation);
}

fn branchStorageEnd(ssa: *const structures.FunctionBodyAnalysis, types: anytype, branch: structures.FunctionBranch, start: u32) !u32 {
    const target = ssa.blocks[@backingInt(branch.target)];
    var end = start;
    for (ssa.block_arguments[target.argument_start..target.argument_end]) |argument| {
        _ = try reserveStack(&end, try blockArgumentLayout(types, argument));
    }
    return end;
}

const MutableCallResult = struct { type_id: structures.TypeId, location: ValueLocation };

const CallLayout = struct {
    result: ValueLocation,
    arguments: []ValueLocation,
    storage_end: u32,
    mut_results: []?MutableCallResult = &.{},
    return_register: ?u32 = null,

    fn init(types: anytype, return_type: structures.TypeId, parameters: []const structures.TypeId, representations: []const structures.ValueRepresentation, gpa: std.mem.Allocator) !CallLayout {
        std.debug.assert(parameters.len == representations.len);
        const arguments = try gpa.alloc(ValueLocation, parameters.len);
        errdefer gpa.free(arguments);
        var end: u32 = 0;
        const result: ValueLocation = if (try returnStorageLayout(types, return_type)) |layout| blk: {
            const offset = try reserveStack(&end, layout);
            break :blk if (try types.facts().argumentPassing(return_type) == .indirect) .{ .indirect = offset } else .{ .stack = offset };
        } else .eax;
        for (parameters, representations, arguments) |type_id, representation, *argument| {
            const offset = try reserveStack(&end, try argumentLayout(types, type_id, representation));
            argument.* = if (try argumentByAddress(types, type_id, representation)) .{ .indirect = offset } else .{ .stack = offset };
        }
        return .{ .result = result, .arguments = arguments, .storage_end = end };
    }

    fn deinit(self: *CallLayout, gpa: std.mem.Allocator) void {
        gpa.free(self.arguments);
        gpa.free(self.mut_results);
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
    const parameters = try gpa.alloc(structures.TypeId, call.arguments.end - call.arguments.start);
    defer gpa.free(parameters);
    const representations = try gpa.alloc(structures.ValueRepresentation, parameters.len);
    defer gpa.free(representations);
    for (ssa.call_arguments[call.arguments.start..call.arguments.end], parameters, representations) |argument, *parameter, *representation| {
        const use = argument.valueUse();
        parameter.* = use.coerce_to orelse value_types[@backingInt(use.value)];
        representation.* = switch (argument) {
            .prepared => .value,
            .deinit => .storage,
            .initializer => .initializer,
        };
    }
    var layout = try CallLayout.init(types, call.return_type, parameters, representations, gpa);
    errdefer layout.deinit(gpa);
    layout.mut_results = try gpa.alloc(?MutableCallResult, parameters.len);
    @memset(layout.mut_results, null);
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
    incoming: CallLayout,

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
            if (argument == .deinit) addressable[index] = true;
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
                .mut_parameter_write => |operation| if (ssa.is_initializer_region) {
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
                else => {},
            }
        }
        for (ssa.blocks) |block| {
            var terminator = block.terminator;
            for (terminator.operands()) |operand| if (operand) |value| {
                needed[@backingInt(value.*)] = .used;
            };
            switch (terminator) {
                .branch => |branch| markBranchArguments(ssa, branch, needed, addressable),
                .predicate_branch => |predicate| {
                    markBranchArguments(ssa, predicate.then_branch, needed, addressable);
                    markBranchArguments(ssa, predicate.else_branch, needed, addressable);
                },
                .fallible_call => |fallible| markCallArguments(ssa, fallible.call, needed, addressable),
                .return_unit, .return_value, .return_failure, .diverge => {},
            }
        }
        for (ssa.blocks) |block| {
            if (block.instruction_start == block.instruction_end) continue;
            const value = ssa.instructionValue(block.instruction_end - 1);
            switch (block.terminator) {
                .return_value => |returned| if (returned.value == value and returned.coerce_to == null) {
                    needed[@backingInt(value)] = .returned;
                },
                else => {},
            }
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
        for (ssa.instructions) |instruction| switch (instruction) {
            .call => |call| outgoing_size = @max(outgoing_size, try planCallStorage(ssa, types, value_types, call, &calls, gpa)),
            else => {},
        };
        for (ssa.blocks) |block| switch (block.terminator) {
            .fallible_call => |fallible| outgoing_size = @max(outgoing_size, try planCallStorage(ssa, types, value_types, fallible.call, &calls, gpa)),
            else => {},
        };
        var edge_scratch_end = outgoing_size;
        for (ssa.blocks) |block| switch (block.terminator) {
            .branch => |branch| edge_scratch_end = @max(edge_scratch_end, try branchStorageEnd(ssa, types, branch, outgoing_size)),
            .predicate_branch => |predicate| {
                edge_scratch_end = @max(edge_scratch_end, try branchStorageEnd(ssa, types, predicate.then_branch, outgoing_size));
                edge_scratch_end = @max(edge_scratch_end, try branchStorageEnd(ssa, types, predicate.else_branch, outgoing_size));
            },
            else => {},
        };
        const local_start = edge_scratch_end;
        const locations = try gpa.alloc(ValueLocation, ssa.valueCount());
        errdefer gpa.free(locations);
        @memset(locations[0..ssa.block_arguments.len], .discarded);
        var local_end = local_start;
        const entry_index = @backingInt(ssa.entry);
        std.debug.assert(entry_index < ssa.blocks.len);
        for (ssa.blocks, 0..) |block, block_index| {
            std.debug.assert(block.argument_start <= block.argument_end);
            std.debug.assert(block.argument_end <= ssa.block_arguments.len);
            if (block_index == entry_index) continue;
            for (block.argument_start..block.argument_end) |argument_index| {
                if (needed[argument_index] == .unused) continue;
                if (try argumentByAddress(types, value_types[argument_index], ssa.block_arguments[argument_index].representation)) {
                    locations[argument_index] = .{ .indirect = try reserveStack(&local_end, indirect_layout) };
                    continue;
                }
                const layout = try valueSlotLayout(types, value_types[argument_index]);
                if (layout.byte_size == 0 and !addressable[argument_index]) continue;
                locations[argument_index] = .{ .stack = try reserveStack(&local_end, if (layout.byte_size == 0) zero_sized_address_layout else layout) };
            }
        }
        for (ssa.instructions, locations[ssa.block_arguments.len..], 0..) |instruction, *location, instruction_index| {
            const value_index = @backingInt(ssa.instructionValue(instruction_index));
            location.* = location_blk: {
                switch (instruction) {
                    .const_int => |value| if (!addressable[value_index]) break :location_blk .{ .immediate = value },
                    .const_byte => |value| if (!addressable[value_index]) break :location_blk .{ .immediate = value },
                    .const_bool => |value| if (!addressable[value_index]) break :location_blk .{ .immediate = @intFromBool(value) },
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
                const layout = try valueSlotLayout(types, value_types[value_index]);
                const indirect_return = try types.facts().argumentPassing(value_types[value_index]) == .indirect;
                if (needed[value_index] == .returned and value_types[value_index] == .int and !addressable[value_index]) {
                    break :location_blk .eax;
                }
                if (needed[value_index] != .unused or (indirect_return and instruction == .call)) {
                    if (layout.byte_size == 0) {
                        if (addressable[value_index]) break :location_blk .{ .stack = try reserveStack(&local_end, zero_sized_address_layout) };
                        break :location_blk .discarded;
                    }
                    break :location_blk .{ .stack = try reserveStack(&local_end, layout) };
                }
                break :location_blk .discarded;
            };
        }
        const entry = ssa.blocks[entry_index];
        for (entry.argument_start..entry.argument_end) |argument_index| {
            if (!addressable[argument_index]) continue;
            if ((try argumentLayout(types, value_types[argument_index], ssa.block_arguments[argument_index].representation)).byte_size != 0) continue;
            locations[argument_index] = .{ .stack = try reserveStack(&local_end, zero_sized_address_layout) };
        }
        if (ssa.is_initializer_region) {
            for (entry.argument_start..entry.argument_end) |index| {
                if (needed[index] != .unused) locations[index] = .{ .indirect = try reserveStack(&local_end, indirect_layout) };
            }
        }
        for (ssa.instructions) |instruction| {
            if (instruction != .call_mut_argument) continue;
            const operation = instruction.call_mut_argument;
            const call = calls.getPtr(.{ .arguments = operation.arguments, .return_type = operation.return_type }).?;
            if (call.mut_results[operation.argument_index] != null) continue;
            const by_address = call.arguments[operation.argument_index] == .indirect;
            const offset = try reserveStack(&local_end, if (by_address) indirect_layout else try types.layout(operation.type_id));
            call.mut_results[operation.argument_index] = .{ .type_id = operation.type_id, .location = if (by_address) .{ .indirect = offset } else .{ .stack = offset } };
            if (call.result == .eax and call.return_register == null)
                call.return_register = try reserveStack(&local_end, .{ .byte_size = 4, .byte_alignment = 4 });
        }
        const stack_size = local_end;
        if (stack_size > std.math.maxInt(i32)) return error.FunctionTooLarge;
        std.debug.assert(ssa.parameter_modes.len == entry.argument_end - entry.argument_start);
        const incoming_representations = try gpa.alloc(structures.ValueRepresentation, ssa.parameter_modes.len);
        defer gpa.free(incoming_representations);
        for (ssa.block_arguments[entry.argument_start..entry.argument_end], incoming_representations) |argument, *representation| representation.* = argument.representation;
        var incoming = try CallLayout.init(types, ssa.return_type, value_types[entry.argument_start..entry.argument_end], incoming_representations, gpa);
        errdefer incoming.deinit(gpa);
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
        for (locations[entry.argument_start..entry.argument_end], 0..) |*location, argument_offset| {
            const argument_index = entry.argument_start + argument_offset;
            if (ssa.is_initializer_region) continue;
            const type_id = value_types[argument_index];
            const representation = incoming_representations[argument_offset];
            const layout = try argumentLayout(types, type_id, representation);
            const argument_stack_offset = switch (incoming.arguments[argument_offset]) {
                .stack, .indirect => |offset| offset,
                else => unreachable,
            };
            const offset = std.math.add(u32, caller_stack_offset, argument_stack_offset) catch return error.FunctionTooLarge;
            try ensureAddressableStackRange(offset, layout.byte_size);
            if (needed[argument_index] != .unused and layout.byte_size != 0) {
                location.* = if (try argumentByAddress(types, type_id, representation)) .{ .indirect = offset } else .{ .incoming_argument = offset };
            }
        }
        return .{
            .locations = locations,
            .value_types = value_types,
            .stack_size = stack_size,
            .edge_scratch_offset = outgoing_size,
            .return_buffer_offset = return_buffer_offset,
            .calls = calls,
            .incoming = incoming,
        };
    }

    fn deinit(self: *LocationPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locations);
        gpa.free(self.value_types);
        deinitCallLayouts(&self.calls, gpa);
        self.incoming.deinit(gpa);
        self.* = undefined;
    }
};

const IntegerBinaryOperation = enum {
    add,
    subtract,
    multiply,
    divide_signed,
};

fn FunctionEmitter(comptime Types: type) type {
    return struct {
        const Self = @This();
        const JumpPatch = struct {
            field_offset: u32,
            target: structures.FunctionBlockId,
        };

        gpa: std.mem.Allocator,
        encoder: X86Encoder,
        relocations: std.ArrayList(structures.CompiledFunction.Relocation) = .empty,
        referenced_instances: std.ArrayList(structures.InstanceId) = .empty,
        constant_data: std.ArrayList(structures.ByteString) = .empty,
        // Scratch inverse of referenced_instances; relocations index the slice.
        reference_indices: std.AutoHashMapUnmanaged(structures.InstanceId, u32) = .empty,
        jump_patches: std.ArrayList(JumpPatch) = .empty,
        initializer_patches: std.ArrayList(struct { field_offset: u32, region: u32 }) = .empty,
        types: Types,
        locations: []const ValueLocation,
        value_types: []const structures.TypeId,
        variant_coercion_tags: []const u32,
        branch_arguments: []const structures.FunctionValueUse,
        call_arguments: []const structures.FunctionCallArgument,
        call_layouts: CallLayouts,
        incoming_layout: CallLayout,
        block_offsets: []u32,
        stack_size: u32,
        edge_scratch_offset: u32,
        return_buffer_offset: ?u32,
        is_fallible: bool,

        fn init(
            gpa: std.mem.Allocator,
            ssa: *const structures.FunctionBodyAnalysis,
            plan: LocationPlan,
            types: Types,
        ) !Self {
            const block_offsets = try gpa.alloc(u32, ssa.blocks.len);
            errdefer gpa.free(block_offsets);
            @memset(block_offsets, std.math.maxInt(u32));
            const encoder = try X86Encoder.init(gpa);
            return .{
                .gpa = gpa,
                .encoder = encoder,
                .types = types,
                .locations = plan.locations,
                .value_types = plan.value_types,
                .variant_coercion_tags = ssa.variant_coercion_tags,
                .branch_arguments = ssa.branch_arguments,
                .call_arguments = ssa.call_arguments,
                .call_layouts = plan.calls,
                .incoming_layout = plan.incoming,
                .block_offsets = block_offsets,
                .stack_size = plan.stack_size,
                .edge_scratch_offset = plan.edge_scratch_offset,
                .return_buffer_offset = plan.return_buffer_offset,
                .is_fallible = ssa.is_fallible,
            };
        }

        fn deinit(self: *Self) void {
            self.gpa.free(self.block_offsets);
            self.jump_patches.deinit(self.gpa);
            self.initializer_patches.deinit(self.gpa);
            self.referenced_instances.deinit(self.gpa);
            for (self.constant_data.items) |data| self.gpa.free(data.bytes);
            self.constant_data.deinit(self.gpa);
            self.reference_indices.deinit(self.gpa);
            self.relocations.deinit(self.gpa);
            self.encoder.deinit();
            self.* = undefined;
        }

        fn emit(self: *Self, ssa: *const structures.FunctionBodyAnalysis) !void {
            if (self.stack_size != 0) try self.encoder.offset(.sub_rsp, self.stack_size);
            if (ssa.is_initializer_region) {
                const entry = ssa.blocks[@backingInt(ssa.entry)];
                for (entry.argument_start..entry.argument_end, 0..) |index, capture| {
                    const location = self.locations[index];
                    if (location == .discarded) continue;
                    std.debug.assert(location == .indirect);
                    try self.encoder.offset(.mov_rax_rdi, @intCast(capture * 8));
                    try self.encoder.offset(.mov_rsp_rax, location.indirect);
                }
            }
            try self.emitBlock(ssa, ssa.entry);
            for (ssa.blocks, 0..) |_, block_index| {
                if (block_index == @backingInt(ssa.entry)) continue;
                try self.emitBlock(ssa, @fromBackingInt(@intCast(block_index)));
            }
            for (self.jump_patches.items) |patch| {
                const target_offset = self.block_offsets[@backingInt(patch.target)];
                std.debug.assert(target_offset != std.math.maxInt(u32));
                try self.patchJump(patch.field_offset, target_offset);
            }
        }

        fn emitBlock(self: *Self, ssa: *const structures.FunctionBodyAnalysis, block_id: structures.FunctionBlockId) !void {
            const block_index = @backingInt(block_id);
            const block = ssa.blocks[block_index];
            self.block_offsets[block_index] = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            std.debug.assert(block.instruction_start <= block.instruction_end);
            std.debug.assert(block.instruction_end <= ssa.instructions.len);
            for (block.instruction_start..block.instruction_end) |instruction_index| {
                const instruction = ssa.instructions[instruction_index];
                const destination = self.locations[@backingInt(ssa.instructionValue(instruction_index))];
                switch (instruction) {
                    .const_int => |value| if (destination == .stack) {
                        try self.encoder.immediate(.mov_eax, value);
                        try self.storeResult(destination);
                    },
                    .const_byte => |value| if (destination == .stack) {
                        try self.encoder.immediate(.mov_eax, value);
                        try self.storeByte(destination, 0);
                    },
                    .const_bool => |value| if (destination == .stack) {
                        try self.encoder.immediate(.mov_eax, @intFromBool(value));
                        try self.storeResult(destination);
                    },
                    .const_unit, .const_none => {},
                    .const_type, .const_int_literal, .const_string_literal, .static_conversion => unreachable,
                    .const_data => |data| try self.emitDataAddress(data, 0, destination),
                    .const_storage_cursor => |cursor| {
                        if (cursor.data) |data| {
                            try self.emitDataAddress(data, cursor.offset, destination);
                        } else {
                            try self.encoder.absolute(.mov_rax, 0);
                            try self.storeAddress(destination);
                        }
                    },
                    .storage_cursor => |operation| if (destination != .discarded) {
                        if (try self.types.facts().arrayType(self.valueType(operation.source)) != null)
                            try self.loadValueAddress(self.locations[@backingInt(operation.source)])
                        else
                            try self.loadAddress(self.locations[@backingInt(operation.source)]);
                        try self.storeAddress(destination);
                    },
                    .cursor_offset, .cursor_element => |operation| try self.emitCursorElement(operation, destination),
                    .byte_to_int => |source| {
                        try self.loadByte(self.locations[@backingInt(source)], 0);
                        try self.storeResult(destination);
                    },

                    .function_ref => |reference| try self.emitFunctionReference(reference, destination),
                    .initializer_ref => |reference| try self.emitInitializerReference(ssa, reference, destination),
                    .variant_tag => |operand| {
                        try self.loadComponent(self.locations[@backingInt(operand)], 0);
                        try self.storeResult(destination);
                    },
                    .variant_coerce => |coercion| try self.emitCoercion(.{
                        .value = coercion.operand,
                        .coerce_to = coercion.target_type,
                        .variant_tag_mapping = coercion.tag_mapping.?,
                    }, if (coercion.destination) |storage| self.locations[@backingInt(storage)] else destination),
                    .variant_extract => |extraction| if (destination != .discarded) {
                        const source_type = self.valueType(extraction.operand);
                        const mapping = if (extraction.tag_mapping) |range| blk: {
                            std.debug.assert(range.start <= range.end and range.end <= self.variant_coercion_tags.len);
                            break :blk self.variant_coercion_tags[range.start..range.end];
                        } else &.{};
                        try self.convertVariant(source_type, extraction.target_type, mapping, self.locations[@backingInt(extraction.operand)], destination);
                    },
                    .callable_coerce => |coercion| try self.copyValue(
                        coercion.target_type,
                        self.locations[@backingInt(coercion.operand)],
                        if (coercion.destination) |storage| self.locations[@backingInt(storage)] else destination,
                    ),
                    .local_storage, .result_storage => {},
                    .storage_projection => |operation| try self.emitStorageProjection(operation, destination),
                    .allocation_element => |operation| try self.emitAllocationElement(operation, destination),
                    .array_element => |operation| switch (destination) {
                        .discarded => {},
                        .indirect => |offset| try self.emitArrayElement(operation, offset),
                        else => unreachable,
                    },
                    .borrow_box => |operation| {
                        if (destination != .discarded) {
                            std.debug.assert((try self.types.layout(operation.type_id)).byte_size == @sizeOf(u64));
                            try self.copyRange(self.locations[@backingInt(operation.source)], 0, .{ .value = destination }, 0, @sizeOf(u64));
                        }
                    },
                    .borrow_address => |operation| if (destination != .discarded) {
                        if (operation.base_is_reference)
                            try self.loadAddress(self.locations[@backingInt(operation.source)])
                        else
                            try self.loadValueAddress(self.locations[@backingInt(operation.source)]);
                        const field_offset = try self.borrowFieldOffset(ssa, operation);
                        if (field_offset != 0) {
                            if (field_offset > std.math.maxInt(i32)) return error.FunctionTooLarge;
                            try self.encoder.addRaxImmediate32(field_offset);
                        }
                        try self.storeAddress(destination);
                    },
                    .borrow_read => |operation| {
                        if (destination != .discarded) {
                            const offset = switch (destination) {
                                .indirect => |value| value,
                                else => unreachable,
                            };
                            try self.loadAddress(self.locations[@backingInt(operation.source)]);
                            try self.encoder.offset(.mov_rsp_rax, offset);
                        }
                    },
                    .borrow_write => |operation| try self.emitBorrowWrite(operation),
                    .value_copy => |operation| try self.copyValue(operation.type_id, self.locations[@backingInt(operation.source)], if (operation.destination) |storage| self.locations[@backingInt(storage)] else destination),
                    .field_access => |operation| try self.emitFieldAccess(operation, destination),
                    .mut_parameter_write => |operation| try self.emitMutParameterWrite(ssa, operation),
                    .call_mut_argument => |operation| try self.emitCallMutArgument(operation, destination),
                    .call => |call| try self.emitCall(call, destination),
                    .negi => |operand| {
                        try self.loadValue(self.locations[@backingInt(operand)]);
                        try self.encoder.emit(.neg_eax);
                        try self.storeResult(destination);
                    },
                    .addi => |operands| try self.emitIntegerBinary(.add, operands, destination),
                    .subi => |operands| try self.emitIntegerBinary(.subtract, operands, destination),
                    .muli => |operands| try self.emitIntegerBinary(.multiply, operands, destination),
                    .divsi => |operands| try self.emitIntegerBinary(.divide_signed, operands, destination),
                }
            }
            try self.emitTerminator(ssa, block.terminator);
        }

        fn emitTerminator(self: *Self, ssa: *const structures.FunctionBodyAnalysis, terminator: structures.FunctionTerminator) !void {
            switch (terminator) {
                .branch => |branch| {
                    try self.emitBranchCopies(ssa, branch);
                    try self.emitJump(branch.target);
                },
                .predicate_branch => |predicate| try self.emitPredicateBranch(ssa, predicate),
                .fallible_call => |fallible| try self.emitFallibleCall(ssa, fallible),
                .return_unit => try self.emitReturn(null, .unit),
                .return_value => |value| try self.emitReturn(value, ssa.return_type),
                .return_failure => try self.emitFailureReturn(),
                .diverge => try self.encoder.emit(.ud2),
            }
        }

        fn emitFallibleCall(self: *Self, ssa: *const structures.FunctionBodyAnalysis, fallible: @FieldType(structures.FunctionTerminator, "fallible_call")) !void {
            const success = ssa.blocks[@backingInt(fallible.success)];
            std.debug.assert(success.argument_end - success.argument_start == 1);
            std.debug.assert(fallible.call.destination != null or self.locations[success.argument_start] != .indirect);
            try self.emitCall(fallible.call, self.locations[success.argument_start]);
            if (fallible.failure) |failure| {
                try self.encoder.emit(.test_edx);
                const success_field = try self.encoder.conditionalJumpRelative32(.nei, 0);
                try self.emitJump(failure);
                const success_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
                try self.patchJump(success_field, success_offset);
            }
            try self.emitJump(fallible.success);
        }

        fn emitPredicateBranch(
            self: *Self,
            ssa: *const structures.FunctionBodyAnalysis,
            predicate: @FieldType(structures.FunctionTerminator, "predicate_branch"),
        ) !void {
            try self.loadValue(self.locations[@backingInt(predicate.operands.lhs)]);
            try self.encoder.compareEax(self.locations[@backingInt(predicate.operands.rhs)]);
            const then_field = try self.encoder.conditionalJumpRelative32(predicate.operation, 0);
            try self.emitBranchCopies(ssa, predicate.else_branch);
            try self.emitJump(predicate.else_branch.target);
            const then_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            try self.patchJump(then_field, then_offset);
            try self.emitBranchCopies(ssa, predicate.then_branch);
            try self.emitJump(predicate.then_branch.target);
        }

        fn emitBranchCopies(self: *Self, ssa: *const structures.FunctionBodyAnalysis, branch: structures.FunctionBranch) !void {
            const target = ssa.blocks[@backingInt(branch.target)];
            const arguments = self.branch_arguments[branch.arguments.start..branch.arguments.end];
            std.debug.assert(arguments.len == target.argument_end - target.argument_start);
            if (arguments.len == 1) {
                const type_id = ssa.block_arguments[target.argument_start].type_id;
                const destination = self.locations[target.argument_start];
                if (destination == .indirect) {
                    try self.loadArgumentAddress(arguments[0]);
                    try self.encoder.offset(.mov_rsp_rax, destination.indirect);
                } else if (destination != .discarded) try self.emitUse(arguments[0], type_id, destination);
                return;
            }
            var scratch_end = self.edge_scratch_offset;
            for (arguments, 0..) |argument, argument_offset| {
                const scratch_offset = try reserveStack(&scratch_end, try blockArgumentLayout(self.types, ssa.block_arguments[target.argument_start + argument_offset]));
                const destination = self.locations[target.argument_start + argument_offset];
                if (destination == .indirect) {
                    try self.loadArgumentAddress(argument);
                    try self.encoder.offset(.mov_rsp_rax, scratch_offset);
                } else if (destination != .discarded) try self.emitUseToMemory(argument, scratch_offset);
            }
            scratch_end = self.edge_scratch_offset;
            for (arguments, 0..) |_, argument_offset| {
                const type_id = ssa.block_arguments[target.argument_start + argument_offset].type_id;
                const scratch_offset = try reserveStack(&scratch_end, try blockArgumentLayout(self.types, ssa.block_arguments[target.argument_start + argument_offset]));
                const destination = self.locations[target.argument_start + argument_offset];
                if (destination == .indirect) {
                    try self.encoder.offset(.mov_rax_rsp, scratch_offset);
                    try self.encoder.offset(.mov_rsp_rax, destination.indirect);
                } else if (destination != .discarded) try self.copyValue(type_id, .{ .stack = scratch_offset }, destination);
            }
        }

        fn loadArgumentAddress(self: *Self, argument: structures.FunctionValueUse) !void {
            std.debug.assert(argument.coerce_to == null);
            try self.loadValueAddress(self.locations[@backingInt(argument.value)]);
        }

        fn emitJump(self: *Self, target: structures.FunctionBlockId) !void {
            const field_offset = try self.encoder.jump(.jmp, 0);
            try self.jump_patches.append(self.gpa, .{ .field_offset = field_offset, .target = target });
        }

        fn patchJump(self: *Self, field_offset: u32, target_offset: u32) error{RelocationOverflow}!void {
            try patchRelativeDisplacement(
                self.encoder.code.items,
                field_offset,
                target_offset,
                @as(u64, field_offset) + @sizeOf(i32),
                0,
            );
        }

        fn emitReturn(self: *Self, value: ?structures.FunctionValueUse, return_type: structures.TypeId) !void {
            if (value) |returned| {
                const layout = try self.types.layout(return_type);
                const destination: ValueLocation = if (try self.types.facts().argumentPassing(return_type) == .indirect)
                    .{ .indirect = self.return_buffer_offset orelse unreachable }
                else if (usesMemoryReturn(layout))
                    .{ .return_buffer = self.return_buffer_offset orelse unreachable }
                else
                    .eax;
                try self.emitUse(returned, return_type, destination);
            }
            try self.encoder.immediate(.mov_edx, 1);
            if (self.stack_size != 0) try self.encoder.offset(.add_rsp, self.stack_size);
            try self.encoder.emit(.ret);
        }

        fn emitFailureReturn(self: *Self) !void {
            std.debug.assert(self.is_fallible);
            try self.encoder.immediate(.mov_edx, 0);
            if (self.stack_size != 0) try self.encoder.offset(.add_rsp, self.stack_size);
            try self.encoder.emit(.ret);
        }

        fn emitCall(self: *Self, call: structures.FunctionCall, result: ValueLocation) !void {
            const destination = if (call.destination) |storage| self.locations[@backingInt(storage)] else result;
            try self.emitCallArguments(call, destination);
            switch (call.target) {
                .direct => |instance| {
                    const offset = std.math.cast(u32, self.encoder.code.items.len + 1) orelse return error.FunctionTooLarge;
                    try self.encoder.immediate(.call_relative, 0);
                    try self.appendRelocation(instance, offset, .call_relative_32);
                },
                .initializer => |value| try self.emitInitializerCall(value),
                .indirect => |value| {
                    try self.loadAddress(self.locations[@backingInt(value)]);
                    try self.encoder.emit(.call_rax);
                },
            }
            const layout = self.call_layouts.get(.{ .arguments = call.arguments, .return_type = call.return_type }).?;
            if (layout.return_register) |offset| try self.encoder.offset(.mov_rsp_eax, offset);
            for (layout.arguments, layout.mut_results) |argument, saved| {
                const snapshot = saved orelse continue;
                if (argument == .indirect) {
                    try self.encoder.offset(.mov_rax_rsp, argument.indirect);
                    try self.encoder.offset(.mov_rsp_rax, snapshot.location.indirect);
                } else try self.copyValue(snapshot.type_id, argument, snapshot.location);
            }
            switch (layout.result) {
                .indirect => {},
                .stack => try self.copyValue(call.return_type, layout.result, destination),
                .eax => try self.copyValue(call.return_type, if (layout.return_register) |offset| .{ .stack = offset } else .eax, destination),
                else => unreachable,
            }
        }

        fn emitCallArguments(self: *Self, call: structures.FunctionCall, destination: ValueLocation) !void {
            const layout = self.call_layouts.get(.{ .arguments = call.arguments, .return_type = call.return_type }).?;
            if (layout.result == .indirect) {
                try self.loadValueAddress(destination);
                try self.encoder.offset(.mov_rsp_rax, layout.result.indirect);
            }
            for (self.call_arguments[call.arguments.start..call.arguments.end], layout.arguments) |argument, location| {
                if (argument == .initializer) {
                    std.debug.assert(location == .stack);
                    try self.copyRange(self.locations[@backingInt(argument.initializer)], 0, .{ .value = location }, 0, initializer_layout.byte_size);
                    continue;
                }
                if (location == .indirect) {
                    const use = argument.valueUse();
                    std.debug.assert(use.coerce_to == null);
                    try self.loadValueAddress(self.locations[@backingInt(use.value)]);
                    try self.encoder.offset(.mov_rsp_rax, location.indirect);
                } else try self.emitUseToMemory(argument.valueUse(), location.stack);
            }
        }

        fn loadValueAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .indirect => |offset| try self.encoder.offset(.mov_rax_rsp, offset),
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.lea_rax_rsp, offset),
                .discarded, .immediate, .eax => unreachable,
            }
        }

        fn emitFunctionReference(self: *Self, reference: structures.FunctionReference, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const offset_usize = std.math.add(usize, self.encoder.code.items.len, 2) catch return error.FunctionTooLarge;
            const offset = std.math.cast(u32, offset_usize) orelse return error.FunctionTooLarge;
            try self.encoder.absolute(.mov_rax, 0);
            try self.storeAddress(destination);
            try self.appendRelocation(reference.instance(), offset, .address_absolute_64);
        }

        fn emitInitializerCall(self: *Self, value: structures.FunctionValueId) !void {
            const location = self.locations[@backingInt(value)];
            try self.loadValueAddress(location);
            try self.encoder.offset(.mov_rax_rax_offset, 8);
            try self.encoder.emit(.mov_rdi_rax);
            try self.loadValueAddress(location);
            try self.encoder.offset(.mov_rax_rax_offset, 0);
            try self.encoder.emit(.call_rax);
        }

        fn emitInitializerReference(self: *Self, ssa: *const structures.FunctionBodyAnalysis, reference: @FieldType(structures.FunctionInstruction, "initializer_ref"), destination: ValueLocation) !void {
            std.debug.assert(destination == .stack);
            const offset = destination.stack;
            const field_offset = std.math.cast(u32, self.encoder.code.items.len + 3) orelse return error.FunctionTooLarge;
            try self.encoder.immediate(.lea_rax_rip, 0);
            try self.initializer_patches.append(self.gpa, .{ .field_offset = field_offset, .region = reference.region });
            try self.encoder.offset(.mov_rsp_rax, offset);
            try self.encoder.offset(.lea_rax_rsp, offset + 16);
            try self.encoder.offset(.mov_rsp_rax, offset + 8);
            for (ssa.initializer_captures[reference.captures.start..reference.captures.end], 0..) |capture, index| {
                try self.loadValueAddress(self.locations[@backingInt(capture)]);
                try self.encoder.offset(.mov_rsp_rax, offset + 16 + @as(u32, @intCast(index)) * 8);
            }
        }

        fn emitInitializerRegions(self: *Self, ssa: *const structures.FunctionBodyAnalysis) !void {
            for (ssa.initializer_regions, 0..) |*region, index| {
                var compiled = try compileFunction(region, self.types, self.gpa);
                defer compiled.deinit(self.gpa);
                const start = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
                for (self.initializer_patches.items) |patch| if (patch.region == index) {
                    try self.patchJump(patch.field_offset, start);
                };
                try self.encoder.code.appendSlice(self.gpa, compiled.code);
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
            const field = std.math.cast(u32, self.encoder.code.items.len + 2) orelse return error.FunctionTooLarge;
            try self.encoder.absolute(.mov_rax, 0);
            try self.relocations.append(self.gpa, .{ .offset = field, .kind = .address_absolute_64, .reference = .{ .data = index }, .addend = offset });
            try self.storeAddress(destination);
        }

        fn emitCursorElement(self: *Self, operation: structures.CursorElement, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const access = (try self.types.facts().storageAccess(operation.type_id)) orelse unreachable;
            const layout = try self.types.layout(access.element_type);
            if (layout.byte_size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            if (layout.byte_size != 0) {
                try self.loadValue(self.locations[@backingInt(operation.index)]);
                try self.encoder.emit(.movsxd_rcx_eax);
                try self.encoder.immediate(.imul_rcx, @intCast(layout.byte_size));
            }
            try self.loadAddress(self.locations[@backingInt(operation.cursor)]);
            if (layout.byte_size != 0) try self.encoder.emit(.add_rax_rcx);
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
                .discarded, .immediate, .eax => unreachable,
            }
        }

        fn storeAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_rax, offset),
                .discarded => {},
                .immediate, .eax, .incoming_argument, .indirect => unreachable,
            }
        }

        fn emitIntegerBinary(
            self: *Self,
            operation: IntegerBinaryOperation,
            operands: structures.BinaryOperands,
            destination: ValueLocation,
        ) !void {
            try self.loadValue(self.locations[@backingInt(operands.lhs)]);
            try self.encoder.integerBinary(operation, self.locations[@backingInt(operands.rhs)]);
            try self.storeResult(destination);
        }

        fn valueType(self: *const Self, value: structures.FunctionValueId) structures.TypeId {
            return self.value_types[@backingInt(value)];
        }

        fn emitCoercion(self: *Self, use: structures.FunctionValueUse, destination: ValueLocation) !void {
            const target_type = use.coerce_to orelse unreachable;
            try self.emitUse(use, target_type, destination);
        }

        fn emitUseToMemory(self: *Self, use: structures.FunctionValueUse, offset: u32) !void {
            const target_type = use.coerce_to orelse self.valueType(use.value);
            try self.emitUse(use, target_type, .{ .stack = offset });
        }

        fn emitUse(
            self: *Self,
            use: structures.FunctionValueUse,
            target_type: structures.TypeId,
            destination: ValueLocation,
        ) !void {
            if (destination == .discarded) return;
            const actual_type = self.valueType(use.value);
            if (use.coerce_to == null) {
                std.debug.assert(actual_type == target_type);
                return self.copyValue(target_type, self.locations[@backingInt(use.value)], destination);
            }
            std.debug.assert(use.coerce_to.? == target_type);
            if (try self.types.facts().callable(target_type) != null) {
                std.debug.assert(use.variant_tag_mapping == null);
                return self.copyValue(target_type, self.locations[@backingInt(use.value)], destination);
            }
            const mapping = use.variant_tag_mapping.?;
            std.debug.assert(mapping.start <= mapping.end and mapping.end <= self.variant_coercion_tags.len);
            try self.convertVariant(
                actual_type,
                target_type,
                self.variant_coercion_tags[mapping.start..mapping.end],
                self.locations[@backingInt(use.value)],
                destination,
            );
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
                try self.storeComponent(destination, 0);
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
            try self.loadComponent(source, 0);
            try self.remapVariantTag(tag_mapping);
            try self.storeComponent(destination, 0);
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
                matched += 1;
                if (matched == matching_count) {
                    try self.encoder.immediate(.mov_eax, std.math.cast(i32, target_tag) orelse return error.FunctionTooLarge);
                    break;
                }
                try self.encoder.compareEax(.{ .immediate = @intCast(source_tag) });
                const next = try self.encoder.conditionalJumpRelative32(.nei, 0);
                try self.encoder.immediate(.mov_eax, std.math.cast(i32, target_tag) orelse return error.FunctionTooLarge);
                try done_jumps.append(self.gpa, try self.encoder.jump(.jmp, 0));
                const next_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
                try self.patchJump(next, next_offset);
            }
            const done_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            for (done_jumps.items) |jump| try self.patchJump(jump, done_offset);
        }

        fn copyValue(self: *Self, type_id: structures.TypeId, source: ValueLocation, destination: ValueLocation) !void {
            if (destination == .discarded or std.meta.eql(source, destination)) return;
            const layout = try self.types.layout(type_id);
            try self.copyRange(source, 0, .{ .value = destination }, 0, layout.byte_size);
        }

        fn emitStorageProjection(self: *Self, operation: structures.StorageProjection, destination: ValueLocation) !void {
            if (destination == .discarded or destination == .stack) return;
            const offset = switch (destination) {
                .indirect => |value| value,
                else => unreachable,
            };
            const source = self.locations[@backingInt(operation.owner)];
            switch (operation.projection) {
                .box_element, .allocation_array => try self.loadAddress(source),
                .field => |index| {
                    const layout = (try self.types.structLayout(self.valueType(operation.owner))) orelse return error.Unavailable;
                    try self.loadValueAddress(source);
                    if (layout.field_offsets[index] != 0) try self.encoder.addRaxImmediate32(layout.field_offsets[index]);
                },
                .variant => {
                    const layout = try self.types.variantLayout(self.valueType(operation.owner));
                    try self.loadValueAddress(source);
                    if (layout.payload_offset != 0) try self.encoder.addRaxImmediate32(layout.payload_offset);
                },
            }
            try self.encoder.offset(.mov_rsp_rax, offset);
        }

        fn borrowFieldOffset(self: *Self, ssa: *const structures.FunctionBodyAnalysis, operation: structures.BorrowAddressOperation) !u32 {
            if (operation.fields.start == operation.fields.end) return 0;
            var type_id = self.valueType(operation.source);
            if (operation.base_is_reference) type_id = (try self.types.facts().borrowElement(type_id)) orelse unreachable;
            var offset: u32 = 0;
            for (ssa.borrow_fields[operation.fields.start..operation.fields.end]) |projection| switch (projection) {
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

        fn emitAllocationElement(self: *Self, operation: structures.AllocationElement, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const offset = switch (destination) {
                .indirect => |value| value,
                else => unreachable,
            };
            const layout = try self.types.layout(operation.type_id);
            if (layout.byte_size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            if (layout.byte_size != 0) {
                try self.loadValue(self.locations[@backingInt(operation.index)]);
                try self.encoder.emit(.movsxd_rcx_eax);
                try self.encoder.immediate(.imul_rcx, @intCast(layout.byte_size));
            }
            try self.loadAddress(self.locations[@backingInt(operation.allocation)]);
            if (layout.byte_size != 0) try self.encoder.emit(.add_rax_rcx);
            try self.encoder.offset(.mov_rsp_rax, offset);
        }

        fn emitArrayElement(self: *Self, operation: structures.ArrayElement, destination_offset: u32) !void {
            const layout = try self.types.layout(operation.type_id);
            if (layout.byte_size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            if (layout.byte_size != 0) {
                try self.loadValue(self.locations[@backingInt(operation.index)]);
                try self.encoder.emit(.movsxd_rcx_eax);
                try self.encoder.immediate(.imul_rcx, @intCast(layout.byte_size));
            }
            try self.loadValueAddress(self.locations[@backingInt(operation.array)]);
            if (layout.byte_size != 0) try self.encoder.emit(.add_rax_rcx);
            try self.encoder.offset(.mov_rsp_rax, destination_offset);
        }

        fn emitBorrowWrite(self: *Self, operation: structures.BorrowWriteOperation) !void {
            const layout = try self.types.layout(operation.type_id);
            try self.copyRange(
                self.locations[@backingInt(operation.value)],
                0,
                .{ .reference = self.locations[@backingInt(operation.reference)] },
                0,
                layout.byte_size,
            );
        }

        fn emitFieldAccess(self: *Self, operation: structures.FieldAccessOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const source_type = self.valueType(operation.operand);
            const layout = (try self.types.structLayout(source_type)) orelse return error.Unavailable;
            std.debug.assert(operation.field_index < layout.field_offsets.len);
            const field_layout = try self.types.layout(operation.field_type);
            try self.copyRange(
                self.locations[@backingInt(operation.operand)],
                layout.field_offsets[operation.field_index],
                .{ .value = destination },
                0,
                field_layout.byte_size,
            );
        }

        fn emitMutParameterWrite(self: *Self, ssa: *const structures.FunctionBodyAnalysis, operation: structures.MutParameterWrite) !void {
            const entry = ssa.blocks[@backingInt(ssa.entry)];
            std.debug.assert(operation.parameter_index < entry.argument_end - entry.argument_start);
            if (ssa.is_initializer_region) {
                try self.copyValue(operation.type_id, self.locations[@backingInt(operation.value)], self.locations[operation.parameter_index]);
                return;
            }
            const parameter = self.incoming_layout.arguments[operation.parameter_index];
            const parameter_offset = switch (parameter) {
                .stack, .indirect => |offset| offset,
                else => unreachable,
            };
            const caller_stack_offset = std.math.add(u32, self.stack_size, @sizeOf(u64)) catch return error.FunctionTooLarge;
            const destination_offset = std.math.add(u32, caller_stack_offset, parameter_offset) catch return error.FunctionTooLarge;
            const destination: ValueLocation = if (parameter == .indirect)
                .{ .indirect = destination_offset }
            else
                .{ .incoming_argument = destination_offset };
            try self.copyValue(operation.type_id, self.locations[@backingInt(operation.value)], destination);
        }

        fn emitCallMutArgument(self: *Self, operation: structures.CallMutArgument, destination: ValueLocation) !void {
            const layout = self.call_layouts.get(.{ .arguments = operation.arguments, .return_type = operation.return_type }).?;
            const source = layout.mut_results[operation.argument_index].?.location;
            const storage = operation.destination orelse return self.copyValue(operation.type_id, source, destination);
            if (self.call_arguments[operation.arguments.start + operation.argument_index].valueId() == storage) return;
            try self.copyValue(operation.type_id, source, self.locations[@backingInt(storage)]);
        }

        fn copyRange(self: *Self, source: ValueLocation, source_start: u32, destination: CopyDestination, destination_start: u32, byte_size: u32) !void {
            if (byte_size == 0) return;
            if (destination == .value and destination.value == .discarded) return;
            if (byte_size > 256) {
                try self.loadValueAddress(source);
                if (source_start != 0) try self.encoder.addRaxImmediate32(source_start);
                try self.encoder.emit(.mov_rsi_rax);
                switch (destination) {
                    .value => |location| try self.loadValueAddress(location),
                    .reference => |location| try self.loadAddress(location),
                }
                if (destination_start != 0) try self.encoder.addRaxImmediate32(destination_start);
                try self.encoder.emit(.mov_rdi_rax);
                try self.encoder.absolute(.mov_rax, byte_size);
                try self.encoder.emit(.mov_rcx_rax);
                try self.encoder.emit(.rep_movsb);
                return;
            }
            if (destination == .reference) {
                try self.loadAddress(destination.reference);
                try self.encoder.emit(.mov_rdi_rax);
            }
            var offset: u32 = 0;
            while (byte_size - offset >= @sizeOf(u32)) : (offset += @sizeOf(u32)) {
                try self.loadComponent(source, source_start + offset);
                switch (destination) {
                    .value => |location| try self.storeComponent(location, destination_start + offset),
                    .reference => try self.encoder.offset(.mov_rdi_eax, destination_start + offset),
                }
            }
            while (offset < byte_size) : (offset += 1) {
                try self.loadByte(source, source_start + offset);
                switch (destination) {
                    .value => |location| try self.storeByte(location, destination_start + offset),
                    .reference => try self.encoder.offset(.mov_rdi_al, destination_start + offset),
                }
            }
        }

        fn loadComponent(self: *Self, location: ValueLocation, component_offset: u32) !void {
            switch (location) {
                .immediate => |value| {
                    std.debug.assert(component_offset == 0);
                    try self.encoder.immediate(.mov_eax, value);
                },
                .eax => std.debug.assert(component_offset == 0),
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.mov_eax_rsp, std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.offset(.mov_eax_rax, component_offset);
                },
                .discarded => unreachable,
            }
        }

        fn storeComponent(self: *Self, location: ValueLocation, component_offset: u32) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_eax, std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .eax => std.debug.assert(component_offset == 0),
                .discarded => {},
                .immediate => unreachable,
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rdi_rsp, offset);
                    try self.encoder.offset(.mov_rdi_eax, component_offset);
                },
            }
        }

        fn loadByte(self: *Self, location: ValueLocation, byte_offset: u32) !void {
            switch (location) {
                .immediate => |value| {
                    std.debug.assert(byte_offset < @sizeOf(i32));
                    const bits: u32 = @bitCast(value);
                    try self.encoder.immediate(.mov_eax, @intCast((bits >> @intCast(byte_offset * 8)) & 0xff));
                },
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.movzx_eax_rsp, std.math.add(u32, offset, byte_offset) catch return error.FunctionTooLarge),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.offset(.movzx_eax_rax, byte_offset);
                },
                .eax => std.debug.assert(byte_offset == 0),
                .discarded => unreachable,
            }
        }

        fn storeByte(self: *Self, location: ValueLocation, byte_offset: u32) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_al, std.math.add(u32, offset, byte_offset) catch return error.FunctionTooLarge),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rdi_rsp, offset);
                    try self.encoder.offset(.mov_rdi_al, byte_offset);
                },
                .eax => std.debug.assert(byte_offset == 0),
                .discarded => {},
                .immediate => unreachable,
            }
        }

        fn loadValue(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .immediate => |value| try self.encoder.immediate(.mov_eax, value),
                .eax => {},
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.mov_eax_rsp, offset),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.offset(.mov_eax_rax, 0);
                },
                .discarded => unreachable,
            }
        }

        fn storeResult(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_eax, offset),
                .eax, .discarded => {},
                .immediate, .incoming_argument, .indirect => unreachable,
            }
        }

        fn finish(self: *Self) !structures.CompiledFunction {
            const relocations = try self.relocations.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(relocations);
            const references = try self.referenced_instances.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(references);
            const data = try self.constant_data.toOwnedSlice(self.gpa);
            errdefer {
                for (data) |value| self.gpa.free(value.bytes);
                self.gpa.free(data);
            }
            return .{
                .constant_data = data,
                .code = try self.encoder.code.toOwnedSlice(self.gpa),
                .required_alignment = 1,
                .relocations = relocations,
                .referenced_instances = references,
            };
        }
    };
}

pub fn compileFunction(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator) anyerror!structures.CompiledFunction {
    std.debug.assert(ssa.blocks.len != 0);
    std.debug.assert(@backingInt(ssa.entry) < ssa.blocks.len);
    var plan = try LocationPlan.init(ssa, types, gpa);
    defer plan.deinit(gpa);
    const Emitter = FunctionEmitter(@TypeOf(types));
    var emitter = try Emitter.init(gpa, ssa, plan, types);
    defer emitter.deinit();
    try emitter.emit(ssa);
    try emitter.emitInitializerRegions(ssa);
    return emitter.finish();
}

pub fn compileExternalExit(gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    try encoder.offset(.mov_eax_rsp, 8);
    try encoder.emit(.mov_edi_eax);
    try encoder.immediate(.mov_eax, linux_exit_syscall);
    try encoder.emit(.syscall);
    const code = try encoder.code.toOwnedSlice(gpa);
    errdefer gpa.free(code);
    const relocations = try gpa.alloc(structures.CompiledFunction.Relocation, 0);
    errdefer gpa.free(relocations);
    return .{
        .code = code,
        .required_alignment = 1,
        .relocations = relocations,
        .referenced_instances = try gpa.alloc(structures.InstanceId, 0),
    };
}

pub fn compileExternalAllocateHostStorage(gpa: std.mem.Allocator) !structures.CompiledFunction {
    return compileExternalAllocateStorage(gpa, 1, false);
}

pub fn compileExternalAllocateHostTypedStorage(gpa: std.mem.Allocator, element: structures.TypeLayout) !structures.CompiledFunction {
    if (element.byte_alignment > 4096) return error.UnsupportedAllocationAlignment;
    return compileExternalAllocateStorage(gpa, element.byte_size, true);
}

fn compileExternalAllocateStorage(gpa: std.mem.Allocator, element_size: u32, with_count: bool) !structures.CompiledFunction {
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    const argument_offset: u32 = if (with_count) 24 else 20;
    try encoder.offset(.mov_esi_rsp, argument_offset);
    try encoder.emit(.test_esi);
    const invalid_size = try encoder.conditionalJumpRelative32(.lti, 0);
    const oversized_element = if (element_size > std.math.maxInt(i32)) try encoder.conditionalJumpRelative32(.nei, 0) else null;
    const multiply_size = element_size > 1 and element_size <= std.math.maxInt(i32);
    if (multiply_size) {
        try encoder.immediate(.imul_rsi, @intCast(element_size));
        try encoder.immediate(.cmp_rsi, std.math.maxInt(i32));
    }
    const size_overflow = if (multiply_size) try encoder.jump(.ja, 0) else null;
    if (element_size == 0 or oversized_element != null) {
        try encoder.immediate(.mov_esi, 1);
    } else {
        try encoder.emit(.test_esi);
        const nonzero_size = try encoder.conditionalJumpRelative32(.nei, 0);
        try encoder.immediate(.mov_esi, 1);
        try patchRelativeDisplacement(encoder.code.items, nonzero_size, @intCast(encoder.code.items.len), @as(u64, nonzero_size) + @sizeOf(i32), 0);
    }
    try encoder.emit(.zero_edi);
    try encoder.immediate(.mov_edx, 3);
    try encoder.immediate(.mov_r10d, 0x22);
    try encoder.immediate(.mov_r8d, -1);
    try encoder.emit(.zero_r9d);
    try encoder.immediate(.mov_eax, linux_mmap_syscall);
    try encoder.emit(.syscall);
    try encoder.immediate(.cmp_rax, -4095);
    const allocation_failed = try encoder.jump(.jae, 0);
    try encoder.offset(.mov_rsp_eax, 8);
    try encoder.emit(.shr_rax_32);
    try encoder.offset(.mov_rsp_eax, 12);
    try encoder.emit(.mov_eax_esi);
    try encoder.offset(.mov_rsp_eax, 16);
    if (with_count) {
        try encoder.offset(.mov_eax_rsp, argument_offset);
        try encoder.offset(.mov_rsp_eax, 20);
    }
    try encoder.immediate(.mov_edx, 1);
    try encoder.emit(.ret);
    const failure_offset: u32 = @intCast(encoder.code.items.len);
    try patchRelativeDisplacement(encoder.code.items, invalid_size, failure_offset, @as(u64, invalid_size) + @sizeOf(i32), 0);
    try patchRelativeDisplacement(encoder.code.items, allocation_failed, failure_offset, @as(u64, allocation_failed) + @sizeOf(i32), 0);
    if (size_overflow) |field| try patchRelativeDisplacement(encoder.code.items, field, failure_offset, @as(u64, field) + @sizeOf(i32), 0);
    if (oversized_element) |field| try patchRelativeDisplacement(encoder.code.items, field, failure_offset, @as(u64, field) + @sizeOf(i32), 0);
    try encoder.emit(.zero_edx);
    try encoder.emit(.ret);
    return externalArtifact(&encoder, gpa);
}

pub fn compileExternalDeallocateHostStorage(gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    try encoder.offset(.mov_rax_rsp, 8);
    try encoder.emit(.mov_rax_rax);
    try encoder.emit(.mov_rdi_rax);
    try encoder.offset(.mov_rax_rsp, 8);
    try encoder.offset(.mov_eax_rax, 8);
    try encoder.emit(.mov_esi_eax);
    try encoder.immediate(.mov_eax, linux_munmap_syscall);
    try encoder.emit(.syscall);
    try encoder.immediate(.mov_edx, 1);
    try encoder.emit(.ret);
    return externalArtifact(&encoder, gpa);
}

pub fn compileExternalAllocationCount(gpa: std.mem.Allocator, count_offset: u32) !structures.CompiledFunction {
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    try encoder.offset(.mov_eax_rsp, count_offset + 8);
    try encoder.immediate(.mov_edx, 1);
    try encoder.emit(.ret);
    return externalArtifact(&encoder, gpa);
}

pub fn compileExternalHostBoxWrap(gpa: std.mem.Allocator, layout: structures.TypeLayout) !structures.CompiledFunction {
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    var argument_end: u32 = 0;
    _ = try reserveStack(&argument_end, layout);
    const allocation_offset = try reserveStack(&argument_end, indirect_layout);
    try encoder.offset(.mov_rax_rsp, allocation_offset + 8);
    try encoder.emit(.mov_rsi_rax);
    try encoder.offset(.lea_rdi_rsp, 8);
    try encoder.immediate(.mov_ecx, @intCast(layout.byte_size));
    try encoder.emit(.rep_movsb);
    try encoder.immediate(.mov_edx, 1);
    try encoder.emit(.ret);
    return externalArtifact(&encoder, gpa);
}

pub fn compileExternalHostSlotTake(gpa: std.mem.Allocator, allocation: structures.TypeLayout, element: structures.TypeLayout, indexed: bool) !structures.CompiledFunction {
    if (element.byte_size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    if (element.byte_size == 0) {
        try encoder.immediate(.mov_edx, 1);
        try encoder.emit(.ret);
        return externalArtifact(&encoder, gpa);
    }

    var argument_end: u32 = 0;
    if (usesMemoryReturn(element)) _ = try reserveStack(&argument_end, element);
    const allocation_offset = try reserveStack(&argument_end, allocation);
    const index_offset = if (indexed) try reserveStack(&argument_end, .{ .byte_size = 4, .byte_alignment = 4 }) else null;
    try encoder.offset(.mov_rax_rsp, allocation_offset + 8);
    if (index_offset) |offset| {
        try encoder.offset(.movsxd_rcx_rsp, offset + 8);
        try encoder.immediate(.imul_rcx, @intCast(element.byte_size));
        try encoder.emit(.add_rax_rcx);
    }
    try encoder.emit(.mov_rsi_rax);
    if (usesMemoryReturn(element)) {
        try encoder.offset(.lea_rdi_rsp, 8);
        try encoder.immediate(.mov_ecx, @intCast(element.byte_size));
        try encoder.emit(.rep_movsb);
    } else {
        try encoder.emit(.mov_eax_rsi);
    }
    try encoder.immediate(.mov_edx, 1);
    try encoder.emit(.ret);
    return externalArtifact(&encoder, gpa);
}

pub fn compileExternalByteIo(read: bool, signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    const ids = try gpa.alloc(structures.TypeId, signature.parameters.len);
    defer gpa.free(ids);
    const representations = try gpa.alloc(structures.ValueRepresentation, ids.len);
    defer gpa.free(representations);
    for (ids, signature.parameters) |*id, parameter| id.* = parameter.type_id;
    @memset(representations, .value);
    var layout = try CallLayout.init(types, .int, ids, representations, gpa);
    defer layout.deinit(gpa);
    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    if (read) {
        try encoder.offset(.mov_eax_rsp, 8 + layout.arguments[ids.len - 1].stack);
    } else {
        switch (layout.arguments[1]) {
            .stack => |offset| try encoder.offset(.mov_eax_rsp, 8 + offset + 8),
            .indirect => |offset| {
                try encoder.offset(.mov_rax_rsp, 8 + offset);
                try encoder.offset(.mov_eax_rax, 8);
            },
            else => unreachable,
        }
    }
    try encoder.immediate(.cmp_eax, 0);
    const empty = try encoder.jump(.je, 0);
    try encoder.emit(.mov_edx_eax);
    const retry: u32 = @intCast(encoder.code.items.len);
    try encoder.offset(.mov_edi_rsp, 8 + layout.arguments[0].stack);
    if (read) {
        try encoder.offset(.mov_eax_rsp, 8 + layout.arguments[2].stack);
        try encoder.emit(.movsxd_rcx_eax);
    }
    const address = layout.arguments[1];
    const address_offset: u32 = 8 + switch (address) {
        .stack, .indirect => |offset| offset,
        else => unreachable,
    };
    try encoder.offset(.mov_rax_rsp, address_offset);
    if (address == .indirect) try encoder.emit(.mov_rax_rax);
    if (read) try encoder.emit(.add_rax_rcx);
    try encoder.emit(.mov_rsi_rax);
    try encoder.immediate(.mov_eax, if (read) 0 else 1);
    try encoder.emit(.syscall);
    try encoder.immediate(.cmp_eax, -4);
    const interrupted = try encoder.jump(.je, 0);
    try patchRelativeDisplacement(encoder.code.items, interrupted, retry, @as(u64, interrupted) + 4, 0);
    try encoder.immediate(.cmp_eax, 0);
    const failed = try encoder.jump(.jl, 0);
    const success: u32 = @intCast(encoder.code.items.len);
    try patchRelativeDisplacement(encoder.code.items, empty, success, @as(u64, empty) + 4, 0);
    try encoder.immediate(.mov_edx, 1);
    try encoder.emit(.ret);
    const failure: u32 = @intCast(encoder.code.items.len);
    try patchRelativeDisplacement(encoder.code.items, failed, failure, @as(u64, failed) + 4, 0);
    try encoder.emit(.zero_edx);
    try encoder.emit(.ret);
    var artifact = try externalArtifact(&encoder, gpa);
    artifact.requires_sigpipe_ignore = !read;
    return artifact;
}

fn externalArtifact(encoder: *X86Encoder, gpa: std.mem.Allocator) !structures.CompiledFunction {
    const code = try encoder.code.toOwnedSlice(gpa);
    errdefer gpa.free(code);
    const relocations = try gpa.alloc(structures.CompiledFunction.Relocation, 0);
    errdefer gpa.free(relocations);
    return .{
        .code = code,
        .required_alignment = 1,
        .relocations = relocations,
        .referenced_instances = try gpa.alloc(structures.InstanceId, 0),
    };
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
    for (functions) |function| {
        std.debug.assert(function.artifact.code.len != 0);
        std.debug.assert(function.artifact.required_alignment != 0);
        std.debug.assert(std.math.isPowerOfTwo(function.artifact.required_alignment));
        for (function.artifact.relocations) |relocation| {
            switch (relocation.reference) {
                .function => |reference| if (@backingInt(reference) >= function.artifact.referenced_instances.len) return error.RelocationOutOfBounds,
                .data => |index| {
                    if (index >= function.artifact.constant_data.len or relocation.kind != .address_absolute_64) return error.RelocationOutOfBounds;
                    if (relocation.addend < 0 or relocation.addend > function.artifact.constant_data[index].bytes.len) return error.RelocationOutOfBounds;
                },
            }
            const relocation_offset: usize = relocation.offset;
            const field_size: usize = switch (relocation.kind) {
                .call_relative_32 => @sizeOf(i32),
                .address_absolute_64 => @sizeOf(u64),
            };
            if (relocation_offset > function.artifact.code.len or
                function.artifact.code.len - relocation_offset < field_size)
            {
                return error.RelocationOutOfBounds;
            }
        }
    }

    var function_indices = std.AutoHashMap(structures.InstanceId, usize).init(gpa);
    defer function_indices.deinit();
    const function_count = std.math.cast(u32, functions.len) orelse return error.FileTooBig;
    try function_indices.ensureTotalCapacity(function_count);
    for (functions, 0..) |function, index| {
        const result = function_indices.getOrPutAssumeCapacity(function.instance);
        if (result.found_existing) return error.DuplicateFunctionArtifact;
        result.value_ptr.* = index;
    }
    const entry_index = function_indices.get(entry) orelse return error.MissingEntryArtifact;
    for (functions) |function| {
        for (function.artifact.referenced_instances) |target| {
            if (!function_indices.contains(target)) return error.MissingReferencedArtifact;
        }
    }

    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();

    for (functions) |function| if (function.artifact.requires_sigpipe_ignore) {
        try emitIgnoreSigpipe(&encoder);
        break;
    };
    const call_displacement_offset = encoder.code.items.len + 1;
    try encoder.immediate(.call_relative, 0);
    try encoder.emit(.zero_edi);
    try encoder.immediate(.mov_eax, linux_exit_syscall);
    try encoder.emit(.syscall);

    const Layout = struct { address: u64, offset: usize };
    const layouts = try gpa.alloc(Layout, functions.len);
    defer gpa.free(layouts);

    const code_virtual_address = image_base + @as(u64, code_file_offset);
    for (functions, layouts) |function, *layout| {
        const function_address = try alignedAddress(code_virtual_address, encoder.code.items.len, function.artifact.required_alignment);
        const function_offset = try offsetFromBase(function_address, code_virtual_address);
        if (function.artifact.code.len > std.math.maxInt(usize) - function_offset) return error.FileTooBig;
        try encoder.code.appendNTimes(gpa, 0x90, function_offset - encoder.code.items.len);
        try encoder.code.appendSlice(gpa, function.artifact.code);
        layout.* = .{ .address = function_address, .offset = function_offset };
    }

    // Data follows code in the read-only load segment. Intern by content across
    // functions, retaining an addressable byte even for the empty sequence.
    var data_offsets: std.StringHashMapUnmanaged(usize) = .empty;
    defer data_offsets.deinit(gpa);
    for (functions) |function| for (function.artifact.constant_data) |data| {
        const entry_data = try data_offsets.getOrPut(gpa, data.bytes);
        if (entry_data.found_existing) continue;
        entry_data.value_ptr.* = encoder.code.items.len;
        try encoder.code.appendSlice(gpa, data.bytes);
        if (data.bytes.len == 0) try encoder.code.append(gpa, 0);
    };
    const entry_layout = layouts[entry_index];
    try patchRelativeDisplacement(
        encoder.code.items,
        call_displacement_offset,
        entry_layout.address,
        code_virtual_address + @as(u64, call_displacement_offset) + @sizeOf(i32),
        0,
    );

    for (functions, layouts) |function, layout| {
        for (function.artifact.relocations) |relocation| {
            const target_address = switch (relocation.reference) {
                .function => |reference| layouts[function_indices.get(function.artifact.referenced_instances[@backingInt(reference)]).?].address,
                .data => |index| code_virtual_address + @as(u64, @intCast(data_offsets.get(function.artifact.constant_data[index].bytes).?)),
            };
            const field_offset = layout.offset + @as(usize, relocation.offset);
            switch (relocation.kind) {
                .call_relative_32 => try patchRelativeDisplacement(
                    encoder.code.items,
                    field_offset,
                    target_address,
                    layout.address + @as(u64, relocation.offset) + @sizeOf(i32),
                    relocation.addend,
                ),
                .address_absolute_64 => try patchAbsoluteAddress(
                    encoder.code.items,
                    field_offset,
                    target_address,
                    relocation.addend,
                ),
            }
        }
    }

    return .{ .bytes = try buildElfExecutable(encoder.code.items, gpa) };
}

// A broken stream is an ordinary fallible write, including a closed pipe.
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

fn alignedAddress(base: u64, offset: usize, alignment: u32) error{FileTooBig}!u64 {
    const offset_u64 = std.math.cast(u64, offset) orelse return error.FileTooBig;
    const unaligned = std.math.add(u64, base, offset_u64) catch return error.FileTooBig;
    const mask = @as(u64, alignment) - 1;
    if (unaligned > std.math.maxInt(u64) - mask) return error.FileTooBig;
    return (unaligned + mask) & ~mask;
}

fn offsetFromBase(address: u64, base: u64) error{FileTooBig}!usize {
    const offset_u64 = address - base;
    if (offset_u64 > std.math.maxInt(usize)) return error.FileTooBig;
    return @intCast(offset_u64);
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

const X86Encoder = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayList(u8),

    fn init(gpa: std.mem.Allocator) !X86Encoder {
        return .{
            .gpa = gpa,
            .code = try std.ArrayList(u8).initCapacity(gpa, 16),
        };
    }

    fn deinit(self: *@This()) void {
        self.code.deinit(self.gpa);
    }

    fn emit(self: *@This(), operation: x86.Operation) !void {
        std.debug.assert(x86.encoding(operation).operand == .none);
        try x86.append(&self.code, self.gpa, operation, 0);
    }

    fn immediate(self: *@This(), operation: x86.Operation, value: i32) !void {
        const operand = x86.encoding(operation).operand;
        std.debug.assert(operand == .i32 or operand == .rel);
        try x86.append(&self.code, self.gpa, operation, @as(u32, @bitCast(value)));
    }

    fn offset(self: *@This(), operation: x86.Operation, value: u32) !void {
        std.debug.assert(x86.encoding(operation).operand == .u32);
        try x86.append(&self.code, self.gpa, operation, value);
    }

    fn absolute(self: *@This(), operation: x86.Operation, value: u64) !void {
        std.debug.assert(x86.encoding(operation).operand == .u64);
        try x86.append(&self.code, self.gpa, operation, value);
    }

    fn jump(self: *@This(), operation: x86.Operation, displacement: i32) !u32 {
        const encoding = x86.encoding(operation);
        std.debug.assert(encoding.operand == .rel);
        const field_offset = std.math.cast(u32, self.code.items.len + encoding.prefix.len) orelse return error.FunctionTooLarge;
        try self.immediate(operation, displacement);
        return field_offset;
    }

    fn conditionalJumpRelative32(self: *@This(), operation: structures.PredicateOperation, displacement: i32) !u32 {
        const opcode: x86.Operation = switch (operation) {
            .lti => .jl,
            .gti => .jg,
            .lei => .jle,
            .gei => .jge,
            .eqi, .eqb => .je,
            .nei, .neb => .jne,
            .eqt, .net => unreachable,
        };
        return self.jump(opcode, displacement);
    }

    fn addRaxImmediate32(self: *@This(), value: u32) !void {
        std.debug.assert(value <= std.math.maxInt(i32));
        try self.immediate(.add_rax, @intCast(value));
    }

    fn compareEax(self: *@This(), rhs: ValueLocation) !void {
        switch (rhs) {
            .immediate => |value| try self.immediate(.cmp_eax, value),
            .stack, .incoming_argument => |stack_offset| try self.offset(.cmp_eax_rsp, stack_offset),
            .indirect => |stack_offset| {
                try self.offset(.mov_rcx_rsp, stack_offset);
                try self.emit(.cmp_eax_rcx);
            },
            .eax, .return_buffer, .discarded => unreachable,
        }
    }

    fn integerBinary(self: *@This(), operation: IntegerBinaryOperation, rhs: ValueLocation) !void {
        if (operation == .divide_signed) {
            switch (rhs) {
                .immediate => |value| {
                    try self.immediate(.mov_ecx, value);
                    try self.emit(.cdq);
                    try self.emit(.idiv_ecx);
                },
                .stack, .incoming_argument => |stack_offset| {
                    try self.emit(.cdq);
                    try self.offset(.idiv_rsp, stack_offset);
                },
                .indirect => |stack_offset| {
                    try self.offset(.mov_rcx_rsp, stack_offset);
                    try self.emit(.cdq);
                    try self.emit(.idiv_rcx);
                },
                .eax, .return_buffer, .discarded => unreachable,
            }
            return;
        }

        const encoding: struct { immediate: x86.Operation, stack: x86.Operation, indirect: x86.Operation } = switch (operation) {
            .add => .{ .immediate = .add_eax, .stack = .add_eax_rsp, .indirect = .add_eax_rcx },
            .subtract => .{ .immediate = .sub_eax, .stack = .sub_eax_rsp, .indirect = .sub_eax_rcx },
            .multiply => .{ .immediate = .imul_eax, .stack = .imul_eax_rsp, .indirect = .imul_eax_rcx },
            .divide_signed => unreachable,
        };
        switch (rhs) {
            .immediate => |value| try self.immediate(encoding.immediate, value),
            .stack, .incoming_argument => |stack_offset| try self.offset(encoding.stack, stack_offset),
            .indirect => |stack_offset| {
                try self.offset(.mov_rcx_rsp, stack_offset);
                try self.emit(encoding.indirect);
            },
            .eax, .return_buffer, .discarded => unreachable,
        }
    }
};

/// Wraps machine code in an ELF64 header and one executable load segment.
/// Sections are omitted because the Linux program loader only needs segments.
fn buildElfExecutable(code: []const u8, gpa: std.mem.Allocator) error{ OutOfMemory, FileTooBig }![]const u8 {
    if (code.len > std.math.maxInt(usize) - code_file_offset) return error.FileTooBig;
    const total_file_size = code_file_offset + code.len;
    const total_file_size_u64: u64 = @intCast(total_file_size);

    const elf_header = Elf64Header{
        .ident = .{ 0x7f, 'E', 'L', 'F', 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .e_type = 2,
        .e_machine = 62,
        .e_version = 1,
        .e_entry = image_base + @as(u64, code_file_offset),
        .e_phoff = @sizeOf(Elf64Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(Elf64Header),
        .e_phentsize = @sizeOf(Elf64Phdr),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };

    const phdr = Elf64Phdr{
        .p_type = 1,
        .p_flags = 5,
        .p_offset = 0,
        .p_vaddr = image_base,
        .p_paddr = image_base,
        .p_filesz = total_file_size_u64,
        .p_memsz = total_file_size_u64,
        .p_align = 0x1000,
    };

    var file_buf = try std.ArrayList(u8).initCapacity(gpa, total_file_size);
    errdefer file_buf.deinit(gpa);

    try file_buf.appendSlice(gpa, std.mem.asBytes(&elf_header));
    try file_buf.appendSlice(gpa, std.mem.asBytes(&phdr));
    try file_buf.appendSlice(gpa, code);

    return file_buf.toOwnedSlice(gpa);
}
