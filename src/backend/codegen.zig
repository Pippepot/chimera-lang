const std = @import("std");
const x86 = @import("x86_encoding.zig");
const division = @import("division.zig");
const registers = @import("registers.zig");
const machine = @import("machine.zig");
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
    register: machine.ValueId,
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

const StackSlot = struct { offset: u32, layout: structures.TypeLayout };

fn reserveLocalStack(end: *u32, slots: *std.ArrayList(StackSlot), gpa: std.mem.Allocator, layout: structures.TypeLayout) !u32 {
    const offset = try reserveStack(end, layout);
    try slots.append(gpa, .{ .offset = offset, .layout = layout });
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

/// Size of a scalar moved through eax/rax.
const Width = enum(u2) {
    byte,
    word,
    dword,
    qword,

    fn ofBytes(size: u32) Width {
        std.debug.assert(size == 1 or size == 2 or size == 4 or size == 8);
        return @fromBackingInt(@intCast(std.math.log2_int(u32, size)));
    }

    fn bytes(self: Width) u32 {
        return @as(u32, 1) << @backingInt(self);
    }

    /// Selects the operation for this width from operations ordered byte, word, dword, qword.
    fn select(self: Width, operations: []const x86.Operation) x86.Operation {
        return operations[@backingInt(self)];
    }
};

const load_rax = [_]x86.Operation{ .movzx_eax_rax, .movzx_eax_word_rax, .mov_eax_rax, .mov_rax_rax_offset };
const load_rsp = [_]x86.Operation{ .movzx_eax_rsp, .movzx_eax_word_rsp, .mov_eax_rsp, .mov_rax_rsp };
const store_rsp = [_]x86.Operation{ .mov_rsp_al, .mov_rsp_ax, .mov_rsp_eax, .mov_rsp_rax };
const store_rdi = [_]x86.Operation{ .mov_rdi_al, .mov_rdi_ax, .mov_rdi_eax, .mov_rdi_rax_offset };

fn immediateComponent(width: Width, value: i32, offset: u32) i32 {
    if (width == .dword) {
        std.debug.assert(offset == 0);
        return value;
    }
    std.debug.assert(width != .qword);
    std.debug.assert(offset < @sizeOf(i32));
    const bits: u32 = @bitCast(value);
    const mask = (@as(u32, 1) << @intCast(width.bytes() * 8)) - 1;
    return @intCast((bits >> @intCast(offset * 8)) & mask);
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
            .type_id = use.coerce_to orelse ssa.valueType(use.value),
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
    stack_size: u32,
    edge_scratch_offset: u32,
    return_buffer_offset: ?u32,
    calls: CallLayouts,
    spills: []u32,
    allocation_bases: []bool,
    uses: []Usage,
    stack_slots: []StackSlot,
    local_storage_offset: u32,
    runtime_scratch_offset: ?u32,
    service_nodes: []?u32,

    const Usage = enum { unused, used, shared, returned };

    fn markUsed(usage: *Usage) void {
        usage.* = if (usage.* == .unused) .used else .shared;
    }

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
            markUsed(&needed[index]);
            if (parameter.representation == .storage) addressable[index] = true;
        }
    }

    fn markCallArguments(ssa: *const structures.FunctionBodyAnalysis, call: structures.FunctionCall, needed: []Usage, addressable: []bool) void {
        for (ssa.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
            const index = @backingInt(argument.valueId());
            markUsed(&needed[index]);
            if (argument == .deinit or argument == .borrowed) addressable[index] = true;
        }
    }

    fn storageProjectionLocation(
        ssa: *const structures.FunctionBodyAnalysis,
        types: anytype,
        operation: structures.StorageProjection,
        value_index: usize,
        locations: []const ValueLocation,
        local_end: *u32,
        slots: *std.ArrayList(StackSlot),
        gpa: std.mem.Allocator,
    ) !ValueLocation {
        const owner = @backingInt(operation.owner);
        // Earlier stack locations are final; incoming arguments and
        // result storage receive their locations after frame sizing.
        if (owner < value_index and locations[owner] == .stack) {
            const offset: ?u32 = switch (operation.projection) {
                .field => |index| ((try types.structLayout(ssa.valueType(operation.owner))) orelse return error.Unavailable).field_offsets[index],
                .variant => (try types.variantLayout(ssa.valueType(operation.owner))).payload_offset,
                .allocation_array => null,
            };
            if (offset) |bytes| return .{ .stack = std.math.add(u32, locations[owner].stack, bytes) catch return error.FunctionTooLarge };
        }
        return .{ .indirect = try reserveLocalStack(local_end, slots, gpa, indirect_layout) };
    }

    /// A consumed private snapshot can supply the storage of a wrapper or a
    /// whole-size field read. Its bytes and observable storage identity agree.
    fn consumedSnapshot(ssa: *const structures.FunctionBodyAnalysis, types: anytype, instruction: structures.FunctionInstruction, index: usize, locations: []const ValueLocation, uses: []const Usage, addressable: []const bool) !?ValueLocation {
        if (addressable[index]) return null;
        const source = switch (instruction) {
            .aggregate => |aggregate| if (aggregate.fields.end - aggregate.fields.start == 1) ssa.aggregate_fields[aggregate.fields.start] else return null,
            .field_access => |field| if (field.field_index == 0) field.operand else return null,
            else => return null,
        };
        const from = @backingInt(source);
        if (from >= index or uses[from] != .used or addressable[from] or locations[from] != .stack) return null;
        const source_layout = try types.layout(ssa.valueType(source));
        const target_layout = try types.layout(instruction.resultType());
        if (source_layout.byte_size != target_layout.byte_size) return null;
        return locations[from];
    }

    fn init(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator) !LocationPlan {
        const needed = try gpa.alloc(Usage, ssa.valueCount());
        errdefer gpa.free(needed);
        @memset(needed, .unused);
        const addressable = try gpa.alloc(bool, ssa.valueCount());
        defer gpa.free(addressable);
        @memset(addressable, false);

        for (ssa.instructions, 0..) |original, instruction_index| {
            var instruction = original;
            const value_index = @backingInt(ssa.instructionValue(instruction_index));
            for (instruction.operands()) |operand| if (operand) |value| {
                markUsed(&needed[@backingInt(value.*)]);
            };
            switch (instruction) {
                .type_union, .const_type, .const_int_literal, .static_conversion => unreachable,
                .initializer_ref => |operation| {
                    for (ssa.initializer_captures[operation.captures.start..operation.captures.end]) |capture| {
                        markUsed(&needed[@backingInt(capture)]);
                        addressable[@backingInt(capture)] = true;
                    }
                },
                .local_storage => addressable[value_index] = true,
                .storage_projection => |operation| addressable[@backingInt(operation.owner)] = true,
                .storage_cursor => |operation| addressable[@backingInt(operation.source)] = true,
                .array_element => |operation| addressable[@backingInt(operation.array)] = true,
                .borrow_address => |operation| if (!operation.base_is_reference) {
                    addressable[@backingInt(operation.source)] = true;
                },
                .borrow_write => |operation| addressable[@backingInt(operation.value)] = true,
                .service_enter => |operation| addressable[@backingInt(operation.receiver)] = true,
                .context_read => {
                    markUsed(&needed[value_index]);
                    addressable[value_index] = true;
                },
                .context_write => |operation| addressable[@backingInt(operation.source)] = true,
                .call => |call| markCallArguments(ssa, call, needed, addressable),
                .aggregate => |aggregate| for (ssa.aggregate_fields[aggregate.fields.start..aggregate.fields.end]) |field| {
                    markUsed(&needed[@backingInt(field)]);
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
                markUsed(&needed[@backingInt(value.*)]);
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
            outgoing_size = @max(outgoing_size, try planCallStorage(ssa, types, instruction.call, &calls, gpa));
        } else if (instruction == .context_read) {
            outgoing_size = @max(outgoing_size, try planCallStorage(ssa, types, .{ .target = .{ .direct = instruction.context_read.root }, .arguments = .{ .start = 0, .end = 0 }, .return_type = instruction.context_read.type_id }, &calls, gpa));
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
        var stack_slots: std.ArrayList(StackSlot) = .empty;
        errdefer stack_slots.deinit(gpa);
        var local_end = edge_scratch_end;
        const service_nodes = try gpa.alloc(?u32, ssa.instructions.len);
        errdefer gpa.free(service_nodes);
        @memset(service_nodes, null);
        var runtime_scratch_offset: ?u32 = null;
        for (ssa.instructions, 0..) |instruction, index| {
            if (instruction != .service_enter and instruction != .service_leave and instruction != .context_read and instruction != .context_write) continue;
            if (runtime_scratch_offset == null) runtime_scratch_offset = try reserveLocalStack(&local_end, &stack_slots, gpa, .{ .byte_size = 24, .byte_alignment = 8 });
            if (instruction == .service_enter) service_nodes[index] = try reserveLocalStack(&local_end, &stack_slots, gpa, .{ .byte_size = 24, .byte_alignment = 8 });
        }

        const entry_index = @backingInt(ssa.entry);
        for (ssa.blocks, 0..) |block, block_index| {
            if (block_index == entry_index) continue;
            for (block.argument_start..block.argument_end) |argument_index| {
                if (needed[argument_index] == .unused) continue;
                const layout = try argumentLayout(types, ssa.block_arguments[argument_index]);
                if (layout.indirect) {
                    locations[argument_index] = .{ .indirect = try reserveLocalStack(&local_end, &stack_slots, gpa, layout.storage) };
                    continue;
                }
                if (layout.storage.byte_size == 0 and !addressable[argument_index]) continue;
                locations[argument_index] = .{ .stack = try reserveLocalStack(&local_end, &stack_slots, gpa, if (layout.storage.byte_size == 0) zero_sized_address_layout else layout.storage) };
            }
        }
        for (ssa.instructions, locations[ssa.block_arguments.len..], 0..) |instruction, *location, instruction_index| {
            const value_index = @backingInt(ssa.instructionValue(instruction_index));
            const value_type = instruction.resultType();
            location.* = location_blk: {
                switch (instruction) {
                    inline .const_int, .const_byte, .const_bool => |value| if (!addressable[value_index]) {
                        break :location_blk .{ .immediate = if (@TypeOf(value) == bool) @intFromBool(value) else value };
                    },
                    .type_union, .const_type, .const_int_literal, .const_string_literal, .static_conversion => unreachable,
                    .initializer_ref => |operation| break :location_blk .{ .stack = try reserveLocalStack(&local_end, &stack_slots, gpa, try initializerSlotLayout(operation.captures)) },
                    .const_unit, .const_none, .service_enter, .service_leave => if (!addressable[value_index]) break :location_blk .discarded,
                    .call => |call| if (call.return_type == .unit and !addressable[value_index]) {
                        break :location_blk .discarded;
                    },
                    .result_storage => break :location_blk .discarded,
                    .storage_projection => |operation| if (needed[value_index] != .unused)
                        break :location_blk try storageProjectionLocation(ssa, types, operation, value_index, locations, &local_end, &stack_slots, gpa)
                    else
                        break :location_blk .discarded,
                    .allocation_element, .array_element, .borrow_read => if (needed[value_index] != .unused) {
                        break :location_blk .{ .indirect = try reserveLocalStack(&local_end, &stack_slots, gpa, indirect_layout) };
                    } else break :location_blk .discarded,
                    else => {},
                }
                if (needed[value_index] == .unused and
                    (instruction != .call or try types.facts().argumentPassing(value_type) != .indirect))
                    break :location_blk .discarded;
                if (try consumedSnapshot(ssa, types, instruction, value_index, locations, needed, addressable)) |shared|
                    break :location_blk shared;
                const layout = try valueSlotLayout(types, value_type);
                if (needed[value_index] == .returned and value_type == .int and !addressable[value_index]) {
                    break :location_blk .eax;
                }
                if (layout.byte_size == 0) {
                    if (addressable[value_index]) break :location_blk .{ .stack = try reserveLocalStack(&local_end, &stack_slots, gpa, zero_sized_address_layout) };
                    break :location_blk .discarded;
                }
                break :location_blk .{ .stack = try reserveLocalStack(&local_end, &stack_slots, gpa, layout) };
            };
        }
        const entry = ssa.blocks[entry_index];
        for (entry.argument_start..entry.argument_end) |argument_index| {
            if (!addressable[argument_index]) continue;
            if ((try argumentLayout(types, ssa.block_arguments[argument_index])).storage.byte_size != 0) continue;
            locations[argument_index] = .{ .stack = try reserveLocalStack(&local_end, &stack_slots, gpa, zero_sized_address_layout) };
        }
        if (ssa.is_initializer_region) {
            for (entry.argument_start..entry.argument_end) |index| {
                if (needed[index] != .unused) locations[index] = .{ .indirect = try reserveLocalStack(&local_end, &stack_slots, gpa, indirect_layout) };
            }
        }
        const spills = try promoteRegisters(ssa, types, gpa, locations, addressable, needed);
        errdefer gpa.free(spills);
        var allocation_bases: []bool = &.{};
        errdefer gpa.free(allocation_bases);
        if (spills.len != 0) for (ssa.instructions) |instruction| {
            if (instruction != .allocation_element) continue;
            const index = @backingInt(instruction.allocation_element.allocation);
            if (index < ssa.block_arguments.len or addressable[index] or locations[index] != .stack) continue;
            const definition = ssa.instructions[index - ssa.block_arguments.len];
            if (definition == .local_storage or definition == .storage_projection or definition == .initializer_ref) continue;
            if (allocation_bases.len == 0) {
                allocation_bases = try gpa.alloc(bool, locations.len);
                @memset(allocation_bases, false);
            }
            allocation_bases[index] = true;
            spills[index] = locations[index].stack;
        };
        const stack_size = local_end;
        if (stack_size > std.math.maxInt(i32)) return error.FunctionTooLarge;
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
                if (locations[argument_index] == .register) {
                    spills[argument_index] = offset;
                } else locations[argument_index] = if (layout.indirect) .{ .indirect = offset } else .{ .incoming_argument = offset };
            }
        };
        return .{
            .locations = locations,
            .stack_size = stack_size,
            .edge_scratch_offset = outgoing_size,
            .return_buffer_offset = return_buffer_offset,
            .calls = calls,
            .spills = spills,
            .allocation_bases = allocation_bases,
            .uses = needed,
            .stack_slots = try stack_slots.toOwnedSlice(gpa),
            .local_storage_offset = edge_scratch_end,
            .runtime_scratch_offset = runtime_scratch_offset,
            .service_nodes = service_nodes,
        };
    }

    fn registerScalar(types: anytype, type_id: structures.TypeId) !bool {
        if (type_id == .bool) return true;
        if (type_id.numericType()) |numeric| return !numeric.isFloat() and (numeric.width() == 32 or numeric.width() == 64);
        if (type_id.isPrimitive()) return false;
        return try types.facts().borrowElement(type_id) != null or
            try types.facts().storageCursorAccess(type_id) != null or
            try types.facts().functionReference(type_id) != null or
            try types.facts().boundMethod(type_id) != null;
    }

    fn promoteRegisters(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator, locations: []ValueLocation, addressable: []const bool, uses: []const Usage) ![]u32 {
        const promote_locals = for (ssa.blocks, 0..) |block, index| {
            var terminator = block.terminator;
            for (terminator.successors()) |successor| if (successor) |target| {
                if (@backingInt(target.*) <= index) break;
            } else continue;
            break true;
        } else false;
        const entry = ssa.blocks[@backingInt(ssa.entry)];
        var spills: []u32 = &.{};
        errdefer gpa.free(spills);
        for (locations, addressable, 0..) |*location, taken, index| {
            if (taken) continue;
            const parameter = index >= entry.argument_start and index < entry.argument_end;
            if (parameter) {
                if (ssa.is_initializer_region or uses[index] != .shared) continue;
            } else {
                if (location.* != .stack) continue;
                if (!promote_locals) {
                    if (index < ssa.block_arguments.len) continue;
                    if (ssa.instructions[index - ssa.block_arguments.len] != .call or uses[index] != .used) continue;
                }
            }
            if (index < ssa.block_arguments.len) {
                if (ssa.block_arguments[index].representation != .value) continue;
            } else {
                const instruction = ssa.instructions[index - ssa.block_arguments.len];
                if (instruction == .storage_projection or instruction == .local_storage or instruction == .initializer_ref) continue;
                if (instruction == .aggregate) continue;
            }
            if (!try registerScalar(types, ssa.valueType(@fromBackingInt(@intCast(index))))) continue;
            if (spills.len == 0) {
                spills = try gpa.alloc(u32, locations.len);
                @memset(spills, 0);
            }
            spills[index] = if (parameter) 0 else location.stack;
            location.* = .{ .register = @fromBackingInt(@intCast(index)) };
        }
        return spills;
    }

    fn deinit(self: *LocationPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locations);
        deinitCallLayouts(&self.calls, gpa);
        gpa.free(self.spills);
        gpa.free(self.allocation_bases);
        gpa.free(self.uses);
        gpa.free(self.stack_slots);
        gpa.free(self.service_nodes);
        self.* = undefined;
    }
};

const FrameLayout = struct {
    const Slot = struct { original: StackSlot, relocated: ?u32 };
    slots: []Slot,
    original_size: u32,
    stack_size: u32,
    preserve_offset: u32,
    returns: bool,

    fn init(plan: *const LocationPlan, ssa: *const structures.FunctionBodyAnalysis, stream: *const machine.Function, allocation: registers.Allocation, gpa: std.mem.Allocator) !FrameLayout {
        const slots = try gpa.alloc(Slot, plan.stack_slots.len);
        errdefer gpa.free(slots);
        for (plan.stack_slots, slots) |original, *slot| slot.* = .{ .original = original, .relocated = null };
        for (stream.instructions.items) |instruction| {
            if (instruction == .fixed and x86.hasStackOffset(instruction.fixed.operation) and instruction.fixed.bits < plan.stack_size) {
                const position = std.sort.upperBound(Slot, slots, @as(u32, @intCast(instruction.fixed.bits)), compareOffset);
                if (position != 0) slots[position - 1].relocated = slots[position - 1].original.offset;
            }
            const access = instruction.registerAccess() orelse continue;
            const index = @backingInt(access.value);
            if (plan.locations[index] != .register or allocation.registers[index] != null) continue;
            const offset = plan.spills[index];
            if (offset >= plan.stack_size) continue;
            const position = std.sort.upperBound(Slot, slots, offset, compareOffset);
            std.debug.assert(position != 0);
            const slot = &slots[position - 1];
            std.debug.assert(slot.original.offset == offset);
            slot.relocated = slot.original.offset;
        }
        var end = plan.local_storage_offset;
        for (slots) |*slot| {
            if (slot.relocated == null) continue;
            slot.relocated = try reserveStack(&end, slot.original.layout);
        }
        const returns = for (ssa.blocks) |block| {
            switch (block.terminator) {
                .return_unit, .return_value => break true,
                else => {},
            }
        } else false;
        const preserve_offset = end;
        if (returns) for (allocation.used) |selected| {
            if (selected.calleeSaved()) _ = try reserveStack(&end, indirect_layout);
        };
        if (end > std.math.maxInt(i32)) return error.FunctionTooLarge;
        return .{ .slots = slots, .original_size = plan.stack_size, .stack_size = end, .preserve_offset = preserve_offset, .returns = returns };
    }

    fn compareOffset(offset: u32, slot: Slot) std.math.Order {
        return std.math.order(offset, slot.original.offset);
    }

    fn relocate(self: FrameLayout, offset: u32) error{FunctionTooLarge}!u32 {
        if (offset >= self.original_size) {
            const relocated = std.math.add(u32, self.stack_size, offset - self.original_size) catch return error.FunctionTooLarge;
            if (relocated > std.math.maxInt(i32)) return error.FunctionTooLarge;
            return relocated;
        }
        const position = std.sort.upperBound(Slot, self.slots, offset, compareOffset);
        if (position == 0) return offset;
        const slot = self.slots[position - 1];
        const relocated = slot.relocated orelse unreachable;
        return std.math.add(u32, relocated, offset - slot.original.offset) catch error.FunctionTooLarge;
    }

    fn apply(self: FrameLayout, stream: *machine.Function) !void {
        for (stream.instructions.items) |*instruction| {
            switch (instruction.*) {
                .fixed => |*fixed| {
                    if (fixed.operation == .sub_rsp or fixed.operation == .add_rsp) {
                        fixed.bits = self.stack_size;
                        if (self.stack_size == 0) instruction.* = .scratch_dead;
                    } else if (x86.hasStackOffset(fixed.operation)) fixed.bits = try self.relocate(@intCast(fixed.bits));
                },
                .parameter => |*parameter| parameter.offset = try self.relocate(parameter.offset),
                .preserve => |*preserve| {
                    if (self.returns) preserve.offset = self.preserve_offset else instruction.* = .scratch_dead;
                },
                .label, .scratch_dead, .register => {},
            }
        }
    }
};

// Reverse postorder keeps loop bodies together. An empty loop test can follow
// its body so the conditional backedge replaces a jump to the test. Block
// identities and all edge arguments remain unchanged.
fn emissionOrder(ssa: *const structures.FunctionBodyAnalysis, allocator: std.mem.Allocator) ![]structures.FunctionBlockId {
    const order = try allocator.alloc(structures.FunctionBlockId, ssa.blocks.len);
    errdefer allocator.free(order);
    const visited = try allocator.alloc(bool, ssa.blocks.len);
    defer allocator.free(visited);
    @memset(visited, false);
    const Frame = struct { block: structures.FunctionBlockId, successor: usize = 0 };
    const stack = try allocator.alloc(Frame, ssa.blocks.len);
    defer allocator.free(stack);
    var count: usize = 0;
    for (0..ssa.blocks.len) |root_position| {
        const root_index = if (root_position == 0) @backingInt(ssa.entry) else root_position - 1 + @intFromBool(root_position - 1 >= @backingInt(ssa.entry));
        if (visited[root_index]) continue;
        const start = count;
        stack[0] = .{ .block = @fromBackingInt(@intCast(root_index)) };
        visited[root_index] = true;
        var pending: usize = 1;
        while (pending != 0) {
            const frame = &stack[pending - 1];
            var terminator = ssa.blocks[@backingInt(frame.block)].terminator;
            const successors = terminator.successors();
            if (frame.successor < successors.len) {
                const successor = successors[frame.successor];
                frame.successor += 1;
                const target = (successor orelse continue).*;
                if (visited[@backingInt(target)]) continue;
                visited[@backingInt(target)] = true;
                stack[pending] = .{ .block = target };
                pending += 1;
            } else {
                order[count] = frame.block;
                count += 1;
                pending -= 1;
            }
        }
        std.mem.reverse(structures.FunctionBlockId, order[start..count]);
    }
    std.debug.assert(count == order.len);
    std.debug.assert(order[0] == ssa.entry);
    // Preserve reverse postorder among normal blocks while moving terminal
    // failure/exit blocks away from loop bodies. Entry must stay first.
    var warm: usize = 1;
    var cold: usize = 0;
    for (order[1..]) |block| {
        if (ssa.blocks[@backingInt(block)].terminator == .diverge) {
            stack[cold].block = block;
            cold += 1;
        } else {
            order[warm] = block;
            warm += 1;
        }
    }
    for (stack[0..cold], order[warm..]) |frame, *block| block.* = frame.block;
    placeLoopTestsAfterBodies(ssa, order);
    return order;
}

fn placeLoopTestsAfterBodies(ssa: *const structures.FunctionBodyAnalysis, order: []structures.FunctionBlockId) void {
    var position: usize = 1;
    while (position + 1 < order.len) : (position += 1) {
        const header = order[position];
        const body = order[position + 1];
        const block = ssa.blocks[@backingInt(header)];
        if (block.instruction_start != block.instruction_end) continue;
        if (block.terminator != .predicate_branch) continue;
        const predicate = block.terminator.predicate_branch;
        if (predicate.then_branch.target != body and predicate.else_branch.target != body) continue;
        var terminator = ssa.blocks[@backingInt(body)].terminator;
        for (terminator.successors()) |successor| {
            if (successor == null or successor.?.* != header) continue;
            order[position] = body;
            order[position + 1] = header;
            position += 1;
            break;
        }
    }
}

/// An x86 condition code named by its mnemonic suffix; it also distinguishes unsigned from signed order.
const Condition = enum(u4) {
    b = 2,
    ae = 3,
    e = 4,
    ne = 5,
    be = 6,
    a = 7,
    l = 12,
    ge = 13,
    le = 14,
    g = 15,

    fn of(operation: structures.PredicateOperation) Condition {
        return switch (operation) {
            .lti => .l,
            .gti => .g,
            .lei => .le,
            .gei => .ge,
            .eqi, .eqb => .e,
            .nei, .neb => .ne,
            .eqt, .net => unreachable,
        };
    }

    fn ofNumeric(operation: structures.numeric.Binary, signed: bool) Condition {
        return switch (operation) {
            .eq => .e,
            .ne => .ne,
            .lt => if (signed) .l else .b,
            .gt => if (signed) .g else .a,
            .le => if (signed) .le else .be,
            .ge => if (signed) .ge else .ae,
            else => unreachable,
        };
    }

    /// Condition codes come in pairs that differ in the lowest bit.
    fn negated(self: Condition) Condition {
        return @fromBackingInt(@backingInt(self) ^ 1);
    }

    fn jump(self: Condition) x86.Operation {
        return switch (self) {
            inline else => |condition| @field(x86.Operation, "j" ++ @tagName(condition)),
        };
    }

    fn set(self: Condition) x86.Operation {
        return switch (self) {
            inline else => |condition| @field(x86.Operation, "set" ++ @tagName(condition) ++ "_al"),
        };
    }

    /// Replaces eax with ecx when the condition holds.
    fn move(self: Condition) x86.Operation {
        return switch (self) {
            inline else => |condition| @field(x86.Operation, "cmov" ++ @tagName(condition) ++ "_eax_ecx"),
        };
    }
};

fn FunctionEmitter(comptime Types: type) type {
    return struct {
        const Self = @This();
        const IndexKind = enum { element, offset };
        const JumpPatch = struct {
            field_offset: u32,
            target: structures.FunctionBlockId,
        };
        const NumericTrap = struct {
            target_patch: u32,
            span: ?structures.SourceSpan,
            frame: structures.InlineFrameId,
        };
        const EdgeStub = struct {
            field_offset: u32,
            branch: structures.FunctionBranch,
            span: ?structures.SourceSpan,
            frame: structures.InlineFrameId,
        };

        gpa: std.mem.Allocator,
        ssa: *const structures.FunctionBodyAnalysis,
        plan: *const LocationPlan,
        types: Types,
        encoder: Encoder,
        block_offsets: []u32,
        relocations: std.ArrayList(structures.CompiledFunction.Relocation) = .empty,
        referenced_instances: std.ArrayList(structures.InstanceId) = .empty,
        constant_data: std.ArrayList(structures.ByteString) = .empty,
        trace_sites: std.ArrayList(structures.CompiledFunction.TraceSite) = .empty,
        numeric_traps: std.ArrayList(NumericTrap) = .empty,
        edge_stubs: std.ArrayList(EdgeStub) = .empty,
        panic_trace_offsets: std.ArrayList(u32) = .empty,
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
                .encoder = .{ .gpa = gpa, .stream = if (plan.spills.len == 0) null else .{ .gpa = gpa } },
                .block_offsets = block_offsets,
            };
        }

        fn deinit(self: *Self) void {
            self.gpa.free(self.block_offsets);
            self.numeric_traps.deinit(self.gpa);
            self.edge_stubs.deinit(self.gpa);
            self.panic_trace_offsets.deinit(self.gpa);
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
            return self.ssa.valueType(value);
        }

        /// An instruction with explicit result storage writes there instead of to its own value.
        fn resultLocation(self: *const Self, storage: ?structures.FunctionValueId, own: ValueLocation) ValueLocation {
            return if (storage) |value| self.valueLocation(value) else own;
        }

        fn emit(self: *Self) !void {
            const ssa = self.ssa;
            if (self.encoder.stream != null or self.plan.stack_size != 0) try self.encoder.offset(.sub_rsp, self.plan.stack_size);
            try self.saveRegisters(.save);
            if (self.plan.runtime_scratch_offset) |scratch| {
                try self.encoder.immediate(.mov_eax, 0);
                try self.encoder.offset(.mov_rsp_rax, scratch + 16);
            }
            const entry = ssa.blocks[@backingInt(ssa.entry)];
            if (ssa.is_initializer_region) {
                for (self.plan.locations[entry.argument_start..entry.argument_end], 0..) |location, capture| {
                    if (location == .discarded) continue;
                    try self.encoder.offset(.mov_rax_rdi, @intCast(capture * 8));
                    try self.bindIndirect(location);
                }
            } else if (self.encoder.stream) |*stream| {
                for (entry.argument_start..entry.argument_end) |index| {
                    const location = self.plan.locations[index];
                    if (location != .register) continue;
                    try stream.instructions.append(self.gpa, .{ .parameter = .{
                        .value = location.register,
                        .offset = self.plan.spills[index],
                        .width = switch ((try self.types.layout(self.valueType(@fromBackingInt(@intCast(index))))).byte_size) {
                            1 => .byte,
                            4 => .dword,
                            8 => .qword,
                            else => unreachable,
                        },
                    } });
                }
            }
            const order = try emissionOrder(ssa, self.gpa);
            defer self.gpa.free(order);
            for (order, 0..) |block, position| {
                const fallthrough = if (position + 1 < order.len) order[position + 1] else null;
                try self.emitBlock(block, fallthrough);
            }
            // Edge copies execute only on their selected edge. Keeping the
            // non-fallthrough copies here lets the other edge fall through even
            // when its sibling needs parameter setup. These labels and uses
            // enter the expanded machine CFG before register allocation.
            for (self.edge_stubs.items) |stub| {
                try self.encoder.patchHere(stub.field_offset);
                self.current_span = stub.span;
                self.current_frame = stub.frame;
                try self.emitBranchCopies(stub.branch);
                try self.emitJump(stub.branch.target, null);
            }
            if (self.numeric_traps.items.len != 0) {
                // Successful arithmetic falls through. Cold calls retain a
                // return address and the source context of each failed check.
                for (self.numeric_traps.items) |*trap| {
                    try self.encoder.patchHere(trap.target_patch);
                    trap.target_patch = try self.encoder.patchable(.call_relative);
                    self.current_span = trap.span;
                    self.current_frame = trap.frame;
                    try self.recordTraceSite();
                }
                const handler = try self.encoder.position();
                for (self.numeric_traps.items) |trap| try self.encoder.patch(trap.target_patch, handler);
                const message = "panic: invalid numeric operation\n";
                const address = try emitPanicText(&self.encoder, message.len);
                const data_index = try self.dataIndex(message);
                try self.relocations.append(self.gpa, .{ .offset = address, .reference = .{ .data = data_index }, .kind = .address_absolute_64, .addend = 0 });
                const write = try self.encoder.patchable(.call_relative);
                try self.panic_trace_offsets.append(self.gpa, try self.encoder.patchable(.jmp));
                try self.encoder.patchHere(write);
                try emitPanicWriter(&self.encoder);
            }
            for (self.jump_patches.items) |patch| {
                const target_offset = self.block_offsets[@backingInt(patch.target)];
                std.debug.assert(target_offset != std.math.maxInt(u32));
                try self.encoder.patch(patch.field_offset, target_offset);
            }
        }

        fn emitBlock(self: *Self, block_id: structures.FunctionBlockId, fallthrough: ?structures.FunctionBlockId) !void {
            const ssa = self.ssa;
            const block_index = @backingInt(block_id);
            const block = ssa.blocks[block_index];
            self.block_offsets[block_index] = try self.encoder.position();
            const fused_comparison = self.fusedBranchComparison(block);
            var instruction_index = block.instruction_start;
            while (instruction_index < block.instruction_end) : (instruction_index += 1) {
                if (instruction_index == fused_comparison) continue;
                self.current_span = if (ssa.instruction_spans.len == ssa.instructions.len) ssa.instruction_spans[instruction_index] else null;
                self.current_frame = if (ssa.instruction_frames.len != 0) ssa.instruction_frames[instruction_index] else .root;
                if ((ssa.instructions[instruction_index] == .compare or ssa.instructions[instruction_index] == .addi) and
                    try self.emitConditionalIncrement(instruction_index, block.instruction_end))
                {
                    instruction_index += 2;
                    try self.encoder.scratchDead();
                    continue;
                }
                if (ssa.instructions[instruction_index] == .compare and try self.emitFusedSelect(instruction_index, block.instruction_end)) {
                    instruction_index += 1;
                    try self.encoder.scratchDead();
                    continue;
                }
                if ((ssa.instructions[instruction_index] == .allocation_element or ssa.instructions[instruction_index] == .array_element or ssa.instructions[instruction_index] == .borrow_read) and
                    try self.emitElementCopy(instruction_index, block.instruction_end))
                {
                    instruction_index += 1;
                    try self.encoder.scratchDead();
                    continue;
                }
                const destination = self.valueLocation(ssa.instructionValue(instruction_index));
                try self.emitInstruction(ssa.instructions[instruction_index], destination, instruction_index);
                const value_index = @backingInt(ssa.instructionValue(instruction_index));
                if (self.plan.allocation_bases.len != 0 and self.plan.allocation_bases[value_index]) {
                    try self.loadAddress(destination);
                    try self.encoder.register(.store_rax, @fromBackingInt(@intCast(value_index)));
                }
                if (destination != .eax) try self.encoder.scratchDead();
            }
            self.current_span = if (ssa.terminator_spans.len == ssa.blocks.len) ssa.terminator_spans[block_index] else null;
            self.current_frame = if (ssa.terminator_frames.len != 0) ssa.terminator_frames[block_index] else .root;
            if (fused_comparison) |index| {
                try self.emitFusedComparisonBranch(block, index, fallthrough);
            } else try self.emitTerminator(block.terminator, fallthrough);
        }

        /// Leaves the address an element-producing instruction designates in rax.
        fn emitElementPointer(self: *Self, instruction: structures.FunctionInstruction) !void {
            switch (instruction) {
                .allocation_element => |element| try self.emitAllocationElementAddress(element),
                .array_element => |element| try self.emitElementAddress(self.valueLocation(element.array), true, element.index, element.type_id, .element),
                .borrow_read => |read| try self.loadAddress(self.valueLocation(read.source)),
                else => unreachable,
            }
        }

        fn emitElementCopy(self: *Self, index: usize, end: usize) !bool {
            if (index + 1 >= end) return false;
            const value = self.ssa.instructionValue(index);
            if (self.plan.uses[@backingInt(value)] != .used) return false;
            const next = self.ssa.instructions[index + 1];
            if (next != .value_copy) return false;
            const copy = next.value_copy;
            const reading = copy.source == value;
            if (!reading and copy.destination != value) return false;
            const size = (try self.types.layout(copy.type_id)).byte_size;
            if (size != 1 and size != 4) return false;
            try self.emitElementPointer(self.ssa.instructions[index]);
            const width = Width.ofBytes(size);
            if (reading) {
                try self.encoder.offset(width.select(&.{ .movzx_eax_rax, .movzx_eax_word_rax, .mov_eax_rax }), 0);
                const destination = self.resultLocation(copy.destination, self.valueLocation(self.ssa.instructionValue(index + 1)));
                try self.storeComponent(width, destination, 0);
            } else if (size == 4 and self.valueLocation(copy.source) == .immediate) {
                try self.encoder.immediate(.mov_rax_i32, self.valueLocation(copy.source).immediate);
            } else {
                try self.encoder.emit(.mov_rdi_rax);
                try self.loadComponent(width, self.valueLocation(copy.source), 0);
                try self.encoder.offset(width.select(&store_rdi), 0);
            }
            return true;
        }

        fn emitConditionalIncrement(self: *Self, index: usize, end: usize) !bool {
            if (index + 2 >= end) return false;
            const comparison_index = if (self.ssa.instructions[index] == .compare) index else index + 1;
            const addition_index = if (comparison_index == index) index + 1 else index;
            if (self.ssa.instructions[comparison_index] != .compare) return false;
            const condition = self.ssa.instructionValue(comparison_index);
            const increment = self.ssa.instructionValue(addition_index);
            if (self.plan.uses[@backingInt(condition)] != .used or self.plan.uses[@backingInt(increment)] != .used) return false;
            const addition = self.ssa.instructions[addition_index];
            const selection = self.ssa.instructions[index + 2];
            if (addition != .addi or selection != .select) return false;
            const select = selection.select;
            if (select.type_id != .int or select.condition != condition) return false;
            const base = if (self.valueLocation(addition.addi.rhs) == .immediate and self.valueLocation(addition.addi.rhs).immediate == 1)
                addition.addi.lhs
            else if (self.valueLocation(addition.addi.lhs) == .immediate and self.valueLocation(addition.addi.lhs).immediate == 1)
                addition.addi.rhs
            else
                return false;
            var comparison = self.ssa.instructions[comparison_index].compare;
            if (comparison.operands.lhs == increment or comparison.operands.rhs == increment) return false;
            if (select.then_value != increment or select.else_value != base) {
                if (select.else_value != increment or select.then_value != base) return false;
                comparison.operation = comparison.operation.negated();
            }
            try self.emitCompare(comparison, .eax);
            try self.encoder.integerBinary(.addi, self.valueLocation(base));
            try self.storeComponent(.dword, self.valueLocation(self.ssa.instructionValue(index + 2)), 0);
            return true;
        }

        fn emitInstruction(self: *Self, instruction: structures.FunctionInstruction, destination: ValueLocation, index: usize) !void {
            switch (instruction) {
                .const_numeric => |constant| try self.emitNumericConstant(constant, destination),
                .numeric_binary => |operation| try self.emitNumericBinary(operation, destination),
                .numeric_unary => |operation| try self.emitNumericUnary(operation, destination),
                .numeric_convert => |operation| try self.emitNumericConversion(operation, destination),
                inline .const_int, .const_byte, .const_bool => |value| if (destination == .stack) {
                    try self.encoder.immediate(.mov_eax, if (@TypeOf(value) == bool) @intFromBool(value) else value);
                    try self.storeComponent(if (@TypeOf(value) == i32) .dword else .byte, destination, 0);
                },
                .const_unit, .const_none, .local_storage, .result_storage => {},
                .type_union, .const_type, .const_int_literal, .const_string_literal, .static_conversion => unreachable,
                .const_static_string => |constant| try self.emitStaticString(constant, destination),
                .const_storage_cursor => |cursor| if (cursor.data) |data| {
                    try self.emitDataAddress(data, cursor.offset, destination);
                } else {
                    try self.encoder.absolute(.mov_rax, 0);
                    try self.storeAddress(destination);
                },
                .storage_cursor => |operation| try self.emitStorageCursor(operation, destination),
                .cursor_offset, .cursor_element => |operation| try self.emitCursorElement(operation, destination),
                .variant_tag => |operand| try self.emitVariantTag(operand, destination),
                .negi => |operand| try self.emitUnary(.dword, operand, .neg_eax, destination),
                inline .addi, .subi, .muli, .divsi, .shli, .shrsi => |operands, operation| try self.emitIntegerBinary(operation, operands, destination),
                .function_ref => |reference| try self.emitFunctionReference(reference, destination),
                .erased_callable => |callable| try self.emitErasedCallable(callable, destination),
                .callable_payload => |operation| {
                    const offset: u32 = if (try self.types.facts().boundMethod(self.ssa.valueType(operation.source)) != null) 0 else 8;
                    try self.loadComponent(.qword, self.valueLocation(operation.source), offset);
                    try self.storeAddress(destination);
                },
                .callable_invoke => |operation| {
                    try self.loadComponent(.qword, self.valueLocation(operation.source), 0);
                    try self.encoder.offset(.mov_rax_rax_offset, @as(u32, @backingInt(operation.operation)) * 8);
                    try self.storeAddress(destination);
                },
                .callable_allocation => |operation| try self.emitCallableAllocation(operation, destination),
                .initializer_ref => |reference| try self.emitInitializerReference(reference, destination),
                .variant_coerce => |coercion| try self.emitUse(
                    .{ .value = coercion.operand, .coerce_to = coercion.target_type, .variant_tag_mapping = coercion.tag_mapping.? },
                    coercion.target_type,
                    self.resultLocation(coercion.destination, destination),
                ),
                .variant_extract => |extraction| try self.emitVariantExtract(extraction, self.resultLocation(extraction.destination, destination)),
                .value_copy => |operation| try self.copyValue(
                    operation.type_id,
                    self.valueLocation(operation.source),
                    self.resultLocation(operation.destination, destination),
                ),
                .storage_projection => |operation| try self.emitStorageProjection(operation, destination),
                .allocation_element, .array_element, .borrow_read => if (destination != .discarded) {
                    try self.emitElementPointer(instruction);
                    try self.bindIndirect(destination);
                },
                .borrow_address => |operation| try self.emitBorrowAddress(operation, destination),
                .borrow_write => |operation| try self.emitBorrowWrite(operation),
                .field_access => |operation| try self.emitFieldAccess(operation, destination),
                .call => |call| try self.emitCall(call, destination),
                .service_enter => |guard| try self.emitServiceEnter(guard, self.plan.service_nodes[index].?),
                .service_leave => try self.emitServiceLeave(),
                .context_read => |operation| try self.emitContextRead(operation, destination),
                .context_write => |operation| try self.emitContextWrite(operation),
                .compare => |operation| try self.emitCompare(operation, destination),
                .select => |operation| try self.emitSelect(operation, destination),
                .aggregate => |operation| try self.emitAggregate(operation, destination),
                .fill => |operation| try self.emitFill(operation),
                .move => |operation| try self.emitMove(operation),
            }
        }

        fn loadNumeric(self: *Self, type_id: structures.TypeId, source: ValueLocation) !void {
            const kind = type_id.numericType().?;
            if (kind.width() == 64) {
                try self.loadAddress(source);
            } else try self.loadComponent(.ofBytes(kind.width() / 8), source, 0);
            if (!kind.isFloat()) try self.normalizeNumeric(kind);
        }

        fn storeNumeric(self: *Self, kind: structures.numeric.Type, destination: ValueLocation, offset: u32) !void {
            try self.storeComponent(.ofBytes(kind.width() / 8), destination, offset);
        }

        fn normalizeNumeric(self: *Self, kind: structures.numeric.Type) !void {
            switch (kind.width()) {
                8 => try self.encoder.emit(if (kind.isSigned()) .movsx_rax_al else .movzx_eax_al),
                16 => try self.encoder.emit(if (kind.isSigned()) .movsx_rax_ax else .movzx_eax_ax),
                32 => try self.encoder.emit(if (kind.isSigned()) .movsxd_rax_eax else .mov_eax_eax),
                64 => {},
                else => unreachable,
            }
        }

        fn emitNumericConstant(self: *Self, constant: structures.NumericConstant, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            try self.encoder.absolute(.mov_rax, constant.bits);
            try self.storeNumeric(constant.type_id.numericType().?, destination, 0);
        }

        fn numericTrapIf(self: *Self, condition: x86.Operation) !void {
            const branch = try self.encoder.patchable(condition);
            try self.numeric_traps.append(self.gpa, .{
                .target_patch = branch,
                .span = self.current_span,
                .frame = self.current_frame,
            });
        }

        fn numericBounds(self: *Self, kind: structures.numeric.Type, overflow: structures.numeric.Overflow) !void {
            if (overflow == .wrapping) return;
            if (overflow == .checked) {
                if (kind.isSigned()) {
                    try self.encoder.absolute(.mov_rcx, @bitCast(@as(i64, @intCast(kind.minimum()))));
                    try self.encoder.emit(.cmp_rax_rcx);
                    try self.numericTrapIf(.jl);
                }
                try self.encoder.absolute(.mov_rcx, @intCast(kind.maximum()));
                try self.encoder.emit(.cmp_rax_rcx);
                return self.numericTrapIf(if (kind.isSigned()) .jg else .ja);
            }
            try self.encoder.absolute(.mov_rcx, @bitCast(@as(i64, @intCast(kind.minimum()))));
            try self.encoder.emit(.cmp_rax_rcx);
            const above_minimum = try self.encoder.patchable(if (kind.isSigned()) .jge else .jae);
            try self.encoder.emit(.mov_rax_rcx);
            const lower_done = try self.encoder.patchable(.jmp);
            try self.encoder.patchHere(above_minimum);
            try self.encoder.absolute(.mov_rcx, @intCast(kind.maximum()));
            try self.encoder.emit(.cmp_rax_rcx);
            const below_maximum = try self.encoder.patchable(if (kind.isSigned()) .jle else .jbe);
            try self.encoder.emit(.mov_rax_rcx);
            try self.encoder.patchHere(below_maximum);
            try self.encoder.patchHere(lower_done);
        }

        fn numericArithmeticOverflow(self: *Self, kind: structures.numeric.Type, operation: structures.numeric.Binary, overflow: structures.numeric.Overflow) !void {
            if (overflow == .wrapping) return;
            if (overflow == .checked) {
                if (kind.isSigned()) return self.numericTrapIf(.jo);
                if (operation == .mul) {
                    try self.encoder.emit(.test_rdx);
                    return self.numericTrapIf(.jne);
                }
                return self.numericTrapIf(.jb);
            }
            // rsi retains the original left operand; rcx retains the right.
            if (kind.isSigned()) {
                const valid = try self.encoder.patchable(.jno);
                if (operation == .mul) {
                    try self.encoder.emit(.mov_rax_rsi);
                    try self.encoder.emit(.xor_rax_rcx);
                    try self.encoder.emit(.mov_rsi_rax);
                }
                try self.encoder.absolute(.mov_rax, @intCast(kind.maximum()));
                try self.encoder.emit(.test_rsi);
                const positive = try self.encoder.patchable(.jns);
                try self.encoder.absolute(.mov_rax, @bitCast(@as(i64, @intCast(kind.minimum()))));
                try self.encoder.patchHere(positive);
                try self.encoder.patchHere(valid);
            } else {
                if (operation == .mul) try self.encoder.emit(.test_rdx);
                const valid = try self.encoder.patchable(if (operation == .mul) .je else .jae);
                try self.encoder.absolute(.mov_rax, if (operation == .sub) 0 else std.math.maxInt(u64));
                try self.encoder.patchHere(valid);
            }
        }

        /// Add/subtract/multiply at 32 bits consume and produce only their
        /// low 32 bits. Widening is needed by the 64-bit division and narrow
        /// saturation algorithms, not by checked 32-bit arithmetic.
        fn loadNumericBinaryOperand(self: *Self, operation: structures.NumericBinary, source: ValueLocation) !void {
            const kind = operation.type_id.numericType().?;
            switch (operation.operation) {
                .add, .sub, .mul => {
                    if (kind.width() == 32 and !kind.isFloat() and operation.overflow != .saturating)
                        return self.loadComponent(.dword, source, 0);
                },
                else => {},
            }
            return self.loadNumeric(operation.type_id, source);
        }

        fn constantOperand(self: *const Self, value: structures.FunctionValueId) ?structures.NumericConstant {
            const index = @backingInt(value);
            if (index < self.ssa.block_arguments.len) return null;
            return self.ssa.instructions[index - self.ssa.block_arguments.len].numericConstant();
        }

        /// Divides or takes the remainder of a normalized dividend by a constant of
        /// magnitude two or more without a divide instruction. Dividends of every
        /// width are sign- or zero-extended in rax, so the 64-bit forms cover them.
        fn emitConstantDivision(self: *Self, operation: structures.NumericBinary, constant: structures.NumericConstant, destination: ValueLocation) !bool {
            const kind = operation.type_id.numericType().?;
            const signed = kind.isSigned();
            const divisor = structures.numeric.asInteger(kind, constant.bits);
            if (@abs(divisor) < 2) return false;
            const magnitude: u64 = @intCast(@abs(divisor));
            const remainder = operation.operation == .rem;
            const power: ?u6 = if (std.math.isPowerOfTwo(magnitude)) @intCast(@ctz(magnitude)) else null;
            const signed_magic = if (signed and power == null) division.Signed.of(@intCast(divisor)) else null;
            const unsigned_magic = if (!signed and power == null) division.Unsigned.of(magnitude) else null;
            try self.loadNumeric(operation.type_id, self.valueLocation(operation.operands.lhs));
            const encoder = &self.encoder;
            if (power) |bits| {
                if (!signed) {
                    if (remainder) try self.andRax(magnitude - 1) else try encoder.byteImmediate(.shr_rax, bits);
                } else {
                    // The bias, magnitude - 1 for a negative dividend, makes the shift truncate toward zero.
                    try encoder.emit(.mov_rsi_rax);
                    try encoder.byteImmediate(.sar_rsi, 63);
                    try encoder.byteImmediate(.shr_rsi, 64 - @as(u8, bits));
                    try encoder.emit(.add_rax_rsi);
                    if (remainder) {
                        try self.andRax(magnitude - 1);
                        try encoder.emit(.sub_rax_rsi);
                    } else {
                        try encoder.byteImmediate(.sar_rax, bits);
                        if (divisor < 0) try encoder.emit(.neg_rax);
                    }
                }
            } else if (signed_magic) |magic| {
                try encoder.emit(.mov_rdi_rax);
                try encoder.absolute(.mov_rcx, @bitCast(magic.multiplier));
                try encoder.emit(.imul_rcx_wide);
                try encoder.emit(.mov_rax_rdx);
                try encoder.emit(.add_rax_rdi);
                if (magic.shift != 0) try encoder.byteImmediate(.sar_rax, magic.shift);
                try encoder.emit(.mov_rsi_rdi);
                try encoder.byteImmediate(.shr_rsi, 63);
                try encoder.emit(.add_rax_rsi);
                if (divisor < 0) try encoder.emit(.neg_rax);
            } else {
                const magic = unsigned_magic.?;
                try encoder.emit(.mov_rdi_rax);
                try encoder.absolute(.mov_rcx, magic.multiplier);
                try encoder.emit(.mul_rcx);
                try encoder.emit(.mov_rax_from_rdi);
                try encoder.emit(.sub_rax_rdx);
                try encoder.byteImmediate(.shr_rax, 1);
                try encoder.emit(.add_rax_rdx);
                if (magic.shift != 0) try encoder.byteImmediate(.shr_rax, magic.shift);
            }
            if (remainder and power == null) {
                try encoder.absolute(.mov_rcx, @truncate(@as(u128, @bitCast(divisor))));
                try encoder.emit(.imul_rax_rcx);
                try encoder.emit(.mov_rcx_rax);
                try encoder.emit(.mov_rax_from_rdi);
                try encoder.emit(.sub_rax_rcx);
            }
            try self.storeNumeric(kind, destination, 0);
            return true;
        }

        fn andRax(self: *Self, mask: u64) !void {
            if (mask <= std.math.maxInt(i32)) return self.encoder.immediate(.and_rax, @intCast(mask));
            try self.encoder.absolute(.mov_rcx, mask);
            try self.encoder.emit(.and_rax_rcx);
        }

        /// A 64-bit right operand that the accumulator forms can read in place:
        /// a constant that fits a sign-extended immediate, or a register, stack slot or pointer.
        fn wideOperand(self: *const Self, kind: structures.numeric.Type, value: structures.FunctionValueId) bool {
            if (self.constantOperand(value)) |constant| {
                const number = structures.numeric.asInteger(kind, constant.bits);
                return number >= std.math.minInt(i32) and number <= std.math.maxInt(i32);
            }
            return switch (self.valueLocation(value)) {
                .register, .stack, .incoming_argument, .indirect => true,
                else => false,
            };
        }

        /// Applies a 64-bit operation of rax with `wideOperand` already established.
        fn emitWideOperand(self: *Self, kind: structures.numeric.Type, value: structures.FunctionValueId, operations: Encoder.RhsOperations) !void {
            const rhs: ValueLocation = if (self.constantOperand(value)) |constant|
                .{ .immediate = @intCast(structures.numeric.asInteger(kind, constant.bits)) }
            else
                self.valueLocation(value);
            try self.encoder.rhsOperation(rhs, operations);
        }

        /// 32- and 64-bit add, subtract, multiply and bitwise operations applied in place to the accumulator.
        fn emitCompactBinary(self: *Self, operation: structures.NumericBinary, destination: ValueLocation) !bool {
            const kind = operation.type_id.numericType().?;
            const wide = kind.width() == 64;
            if (!wide and kind.width() != 32) return false;
            if (kind.isFloat() or operation.overflow == .saturating) return false;
            const alu: Alu = switch (operation.operation) {
                .add => .add,
                .sub => .sub,
                // Unsigned checked multiplication reads the high half instead of a flag.
                .mul => if (!kind.isSigned() and operation.overflow != .wrapping) return false else .imul,
                .bit_and => .@"and",
                .bit_or => .@"or",
                .bit_xor => .xor,
                else => return false,
            };
            const operations = accumulatorOperations(alu, wide);
            const lhs = self.valueLocation(operation.operands.lhs);
            if (wide) {
                if (!self.wideOperand(kind, operation.operands.rhs)) return false;
                try self.loadNumeric(operation.type_id, lhs);
                try self.emitWideOperand(kind, operation.operands.rhs, operations);
            } else {
                try self.loadComponent(.dword, lhs, 0);
                try self.encoder.rhsOperation(self.valueLocation(operation.operands.rhs), operations);
            }
            switch (alu) {
                .@"and", .@"or", .xor => {},
                else => try self.numericArithmeticOverflow(kind, operation.operation, operation.overflow),
            }
            try self.storeNumeric(kind, destination, 0);
            return true;
        }

        /// Sets the flags for an integer comparison of normalized operands.
        fn emitIntegerComparison(self: *Self, operation: structures.NumericBinary) !void {
            const kind = operation.type_id.numericType().?;
            if (kind.width() == 64 and self.wideOperand(kind, operation.operands.rhs)) {
                try self.loadNumeric(operation.type_id, self.valueLocation(operation.operands.lhs));
                return self.emitWideOperand(kind, operation.operands.rhs, accumulatorOperations(.cmp, true));
            }
            if (kind.width() == 32) {
                // A 32-bit compare orders the operands exactly as the type does.
                try self.loadComponent(.dword, self.valueLocation(operation.operands.lhs), 0);
                if (self.constantOperand(operation.operands.rhs)) |constant| {
                    return self.encoder.immediate(.cmp_eax, @bitCast(@as(u32, @truncate(constant.bits))));
                }
                return self.encoder.compareEax(self.valueLocation(operation.operands.rhs));
            }
            if (self.constantOperand(operation.operands.rhs)) |constant| {
                const value = structures.numeric.asInteger(kind, constant.bits);
                if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                    try self.loadNumeric(operation.type_id, self.valueLocation(operation.operands.lhs));
                    return self.encoder.immediate(.cmp_rax, @intCast(value));
                }
            }
            try self.loadNumeric(operation.type_id, self.valueLocation(operation.operands.rhs));
            try self.encoder.emit(.mov_rcx_rax);
            try self.loadNumeric(operation.type_id, self.valueLocation(operation.operands.lhs));
            try self.encoder.emit(.cmp_rax_rcx);
        }

        /// An integer comparison whose only use is the branch ending its block; the branch
        /// then tests the flags instead of a materialized bool.
        fn fusedBranchComparison(self: *const Self, block: structures.FunctionBlock) ?usize {
            if (block.instruction_start == block.instruction_end or block.terminator != .predicate_branch) return null;
            const predicate = block.terminator.predicate_branch;
            if (predicate.operation != .eqb and predicate.operation != .neb) return null;
            const index = block.instruction_end - 1;
            const comparison = self.ssa.instructions[index];
            if (comparison != .numeric_binary or !comparison.numeric_binary.operation.isComparison()) return null;
            if (comparison.numeric_binary.type_id.numericType().?.isFloat()) {
                switch (comparison.numeric_binary.operation) {
                    .lt, .le, .gt, .ge => {},
                    else => return null,
                }
            }
            const value = self.ssa.instructionValue(index);
            if (predicate.operands.lhs != value or self.plan.uses[@backingInt(value)] != .used) return null;
            return if (self.boolConstant(predicate.operands.rhs) != null) index else null;
        }

        fn boolConstant(self: *const Self, value: structures.FunctionValueId) ?bool {
            const index = @backingInt(value);
            if (index < self.ssa.block_arguments.len) return null;
            const instruction = self.ssa.instructions[index - self.ssa.block_arguments.len];
            return if (instruction == .const_bool) instruction.const_bool else null;
        }

        fn emitFusedComparisonBranch(self: *Self, block: structures.FunctionBlock, index: usize, fallthrough: ?structures.FunctionBlockId) !void {
            const predicate = block.terminator.predicate_branch;
            const comparison = self.ssa.instructions[index].numeric_binary;
            const kind = comparison.type_id.numericType().?;
            const float_condition = if (kind.isFloat()) (try self.emitFloatCompare(comparison)).? else null;
            if (!kind.isFloat()) try self.emitIntegerComparison(comparison);
            try self.encoder.scratchDead();
            // eqb against true, or neb against false, branches when the comparison holds.
            const holds = (predicate.operation == .eqb) == self.boolConstant(predicate.operands.rhs).?;
            const condition = float_condition orelse Condition.ofNumeric(comparison.operation, kind.isSigned());
            try self.emitFlagBranch(predicate.then_branch, predicate.else_branch, if (holds) condition else condition.negated(), fallthrough);
        }

        /// A signed comparison followed by the select it controls: compare, then conditionally
        /// move, without materializing the bool. Moves never change the flags.
        fn emitFusedSelect(self: *Self, index: usize, end: usize) !bool {
            if (index + 1 >= end) return false;
            const selection = self.ssa.instructions[index + 1];
            if (selection != .select) return false;
            const condition = self.ssa.instructionValue(index);
            const select = selection.select;
            if (select.condition != condition or self.plan.uses[@backingInt(condition)] != .used) return false;
            for ([_]structures.FunctionValueId{ select.then_value, select.else_value }) |operand| {
                if (self.valueLocation(operand) == .eax or operand == condition) return false;
            }
            const size = (try self.types.layout(select.type_id)).byte_size;
            if (size != 1 and size != 4) return false;
            const comparison = self.ssa.instructions[index].compare;
            const width = Width.ofBytes(size);
            try self.emitPredicateComparison(comparison);
            try self.encoder.scratchDead();
            try self.loadComponent(width, self.valueLocation(select.else_value), 0);
            try self.encoder.emit(.mov_ecx_eax);
            try self.loadComponent(width, self.valueLocation(select.then_value), 0);
            try self.encoder.emit(Condition.of(comparison.operation).negated().move());
            try self.storeComponent(width, self.valueLocation(self.ssa.instructionValue(index + 1)), 0);
            return true;
        }

        fn emitNumericBinary(self: *Self, operation: structures.NumericBinary, destination: ValueLocation) !void {
            const kind = operation.type_id.numericType().?;
            if (try self.emitCompactBinary(operation, destination)) return;
            if (!kind.isFloat() and operation.operation.isComparison()) {
                try self.emitIntegerComparison(operation);
                try self.encoder.emit(Condition.ofNumeric(operation.operation, kind.isSigned()).set());
                try self.encoder.emit(.movzx_eax_al);
                return self.storeComponent(.byte, destination, 0);
            }
            if (!kind.isFloat() and (operation.operation == .div or operation.operation == .rem)) {
                if (self.constantOperand(operation.operands.rhs)) |constant| {
                    if (try self.emitConstantDivision(operation, constant, destination)) return;
                }
            }
            if (kind.isFloat() and operation.operation.isComparison()) return self.emitFloatComparison(operation, destination);
            if (kind.isFloat() and try self.emitFloatFromMemory(operation, destination)) return;
            // The right operand is loaded first so loading an indirect operand
            // never destroys a live scratch register holding the other input.
            try self.loadNumericBinaryOperand(operation, self.valueLocation(operation.operands.rhs));
            if (kind.isFloat()) try self.encoder.emit(.movq_xmm1_rax) else try self.encoder.emit(.mov_rcx_rax);
            try self.loadNumericBinaryOperand(operation, self.valueLocation(operation.operands.lhs));
            if (kind.isFloat()) {
                try self.encoder.emit(.movq_xmm0_rax);
                return self.emitFloatBinary(operation, destination);
            }
            switch (operation.operation) {
                .add, .sub, .mul => try self.emitNumericArithmetic(kind, operation.operation, operation.overflow),
                .div, .rem => try self.emitNumericDivision(kind, operation.operation, operation.overflow),
                .shl, .shr => {
                    try self.encoder.emit(.mov_rsi_rax);
                    try self.encoder.absolute(.mov_rax, kind.width());
                    try self.encoder.emit(.cmp_rax_rcx);
                    try self.numericTrapIf(.jbe);
                    try self.encoder.emit(.mov_rax_rsi);
                    try self.encoder.emit(if (operation.operation == .shl) .shl_rax_cl else if (kind.isSigned()) .sar_rax_cl else .shr_rax_cl);
                },
                .bit_and => try self.encoder.emit(.and_rax_rcx),
                .bit_or => try self.encoder.emit(.or_rax_rcx),
                .bit_xor => try self.encoder.emit(.xor_rax_rcx),
                else => unreachable,
            }
            try self.storeNumeric(kind, destination, 0);
        }

        fn emitNumericArithmetic(self: *Self, kind: structures.numeric.Type, operation: structures.numeric.Binary, overflow: structures.numeric.Overflow) !void {
            if (overflow == .saturating and kind.isSigned() and kind.width() >= 32) try self.encoder.emit(.mov_rsi_rax);
            const narrow = kind.width() == 32;
            switch (operation) {
                .add => try self.encoder.emit(if (narrow) .add_eax_ecx else .add_rax_rcx),
                .sub => try self.encoder.emit(if (narrow) .sub_eax_ecx else .sub_rax_rcx),
                .mul => try self.encoder.emit(if (narrow) (if (kind.isSigned()) .imul_eax_ecx else .mul_ecx) else if (kind.isSigned() or kind.width() < 64) .imul_rax_rcx else .mul_rcx),
                else => unreachable,
            }
            if (kind.width() >= 32) {
                try self.numericArithmeticOverflow(kind, operation, overflow);
            } else {
                if (!kind.isSigned() and operation == .sub and overflow != .wrapping) {
                    if (overflow == .checked) {
                        try self.numericTrapIf(.jb);
                    } else {
                        const valid = try self.encoder.patchable(.jae);
                        try self.encoder.immediate(.mov_eax, 0);
                        try self.encoder.patchHere(valid);
                    }
                }
                try self.numericBounds(kind, overflow);
            }
        }

        fn emitNumericDivision(self: *Self, kind: structures.numeric.Type, operation: structures.numeric.Binary, overflow: structures.numeric.Overflow) !void {
            try self.encoder.emit(.test_rcx);
            try self.numericTrapIf(.je);
            var done: ?u32 = null;
            if (kind.isSigned()) {
                try self.encoder.emit(.mov_rsi_rax);
                try self.encoder.absolute(.mov_rax, @bitCast(@as(i64, @intCast(kind.minimum()))));
                // Compare the dividend with MIN, then the divisor with -1.
                try self.encoder.emit(.mov_rdx_rax);
                try self.encoder.emit(.mov_rax_rsi);
                try self.encoder.emit(.cmp_rax_rdx);
                const ordinary = try self.encoder.patchable(.jne);
                try self.encoder.absolute(.mov_rax, std.math.maxInt(u64));
                try self.encoder.emit(.cmp_rax_rcx);
                const other_divisor = try self.encoder.patchable(.jne);
                if (operation == .rem) {
                    try self.encoder.immediate(.mov_eax, 0);
                } else switch (overflow) {
                    .checked => try self.numericTrapIf(.jmp),
                    .wrapping => try self.encoder.emit(.mov_rax_rsi),
                    .saturating => try self.encoder.absolute(.mov_rax, @intCast(kind.maximum())),
                }
                done = try self.encoder.patchable(.jmp);
                try self.encoder.patchHere(ordinary);
                try self.encoder.patchHere(other_divisor);
                try self.encoder.emit(.mov_rax_rsi);
                try self.encoder.emit(.cqo);
            } else try self.encoder.emit(.zero_edx);
            try self.encoder.emit(if (kind.isSigned()) .idiv_rcx else .div_rcx);
            if (operation == .rem) try self.encoder.emit(.mov_rax_rdx);
            if (done) |field| try self.encoder.patchHere(field);
        }

        /// Float operands that live in stack slots feed SSE instructions directly,
        /// skipping the integer accumulator.
        fn emitFloatFromMemory(self: *Self, operation: structures.NumericBinary, destination: ValueLocation) !bool {
            const lhs = self.valueLocation(operation.operands.lhs);
            const rhs = self.valueLocation(operation.operands.rhs);
            if (lhs != .stack or rhs != .stack) return false;
            const single = operation.type_id == .f32;
            try self.encoder.offset(if (single) .movss_xmm0_rsp else .movsd_xmm0_rsp, lhs.stack);
            try self.encoder.offset(switch (operation.operation) {
                .add => if (single) .addss_xmm0_rsp else .addsd_xmm0_rsp,
                .sub => if (single) .subss_xmm0_rsp else .subsd_xmm0_rsp,
                .mul => if (single) .mulss_xmm0_rsp else .mulsd_xmm0_rsp,
                .div => if (single) .divss_xmm0_rsp else .divsd_xmm0_rsp,
                else => unreachable,
            }, rhs.stack);
            if (destination == .stack) {
                try self.encoder.offset(if (single) .movss_rsp_xmm0 else .movsd_rsp_xmm0, destination.stack);
            } else {
                try self.encoder.emit(.movq_rax_xmm0);
                try self.storeNumeric(operation.type_id.numericType().?, destination, 0);
            }
            return true;
        }

        /// Materializes float equality from the flags of an unordered compare: unordered operands are unequal.
        fn emitFloatEqualityResult(self: *Self, operation: structures.NumericBinary, destination: ValueLocation) !void {
            const unequal = operation.operation == .ne;
            try self.encoder.immediate(.mov_eax, @intFromBool(unequal));
            const unordered = try self.encoder.patchable(.jp);
            const settled = try self.encoder.patchable(.jne);
            try self.encoder.immediate(.mov_eax, @intFromBool(!unequal));
            try self.encoder.patchHere(unordered);
            try self.encoder.patchHere(settled);
            try self.storeComponent(.byte, destination, 0);
        }

        /// Sets the flags for a float comparison. Greater-than and less-than forms compare
        /// so that "above" holds and unordered operands fail it; they return that condition.
        /// Equality forms return null and need the parity check of `emitFloatEqualityResult`.
        fn emitFloatCompare(self: *Self, operation: structures.NumericBinary) !?Condition {
            const single = operation.type_id == .f32;
            const swap = operation.operation == .lt or operation.operation == .le;
            const first = self.valueLocation(if (swap) operation.operands.rhs else operation.operands.lhs);
            const second = self.valueLocation(if (swap) operation.operands.lhs else operation.operands.rhs);
            if (first == .stack and second == .stack) {
                try self.encoder.offset(if (single) .movss_xmm0_rsp else .movsd_xmm0_rsp, first.stack);
                try self.encoder.offset(if (single) .ucomiss_xmm0_rsp else .ucomisd_xmm0_rsp, second.stack);
            } else {
                try self.loadNumeric(operation.type_id, second);
                try self.encoder.emit(.movq_xmm1_rax);
                try self.loadNumeric(operation.type_id, first);
                try self.encoder.emit(.movq_xmm0_rax);
                try self.encoder.emit(if (single) .ucomiss_xmm0_xmm1 else .ucomisd_xmm0_xmm1);
            }
            return switch (operation.operation) {
                .gt, .lt => .a,
                .ge, .le => .ae,
                else => null,
            };
        }

        fn emitFloatComparison(self: *Self, operation: structures.NumericBinary, destination: ValueLocation) !void {
            if (try self.emitFloatCompare(operation)) |condition| {
                try self.encoder.emit(condition.set());
                try self.encoder.emit(.movzx_eax_al);
                return self.storeComponent(.byte, destination, 0);
            }
            try self.emitFloatEqualityResult(operation, destination);
        }

        fn emitFloatBinary(self: *Self, operation: structures.NumericBinary, destination: ValueLocation) !void {
            const single = operation.type_id == .f32;
            std.debug.assert(!operation.operation.isComparison());
            try self.encoder.emit(switch (operation.operation) {
                .add => if (single) .addss_xmm0_xmm1 else .addsd_xmm0_xmm1,
                .sub => if (single) .subss_xmm0_xmm1 else .subsd_xmm0_xmm1,
                .mul => if (single) .mulss_xmm0_xmm1 else .mulsd_xmm0_xmm1,
                .div => if (single) .divss_xmm0_xmm1 else .divsd_xmm0_xmm1,
                else => unreachable,
            });
            try self.encoder.emit(.movq_rax_xmm0);
            try self.storeNumeric(operation.type_id.numericType().?, destination, 0);
        }

        fn emitNumericUnary(self: *Self, operation: structures.NumericUnary, destination: ValueLocation) !void {
            const kind = operation.type_id.numericType().?;
            if (kind.width() == 32) try self.loadComponent(.dword, self.valueLocation(operation.operand), 0) else try self.loadNumeric(operation.type_id, self.valueLocation(operation.operand));
            if (kind.isFloat()) {
                try self.encoder.absolute(.mov_rcx, @as(u64, 1) << @intCast(kind.width() - 1));
                try self.encoder.emit(.xor_rax_rcx);
            } else if (operation.operation == .bit_not) {
                try self.encoder.emit(.not_rax);
            } else {
                try self.encoder.emit(.mov_rcx_rax);
                try self.encoder.immediate(.mov_eax, 0);
                try self.emitNumericArithmetic(kind, .sub, operation.overflow);
            }
            try self.storeNumeric(kind, destination, 0);
        }

        fn conversionFailure(self: *Self, failures: *std.ArrayList(u32), condition: x86.Operation) !void {
            try failures.append(self.gpa, try self.encoder.patchable(condition));
        }

        fn conversionIntegerBounds(self: *Self, source: structures.numeric.Type, target: structures.numeric.Type, policy: structures.numeric.Policy, failures: *std.ArrayList(u32)) !void {
            if (policy == .wrap) return;
            if (source.minimum() < target.minimum()) {
                try self.encoder.absolute(.mov_rcx, @bitCast(@as(i64, @intCast(target.minimum()))));
                try self.encoder.emit(.cmp_rax_rcx);
                if (policy == .saturate) {
                    const valid = try self.encoder.patchable(.jge);
                    try self.encoder.emit(.mov_rax_rcx);
                    try self.encoder.patchHere(valid);
                } else try self.conversionFailure(failures, .jl);
            }
            if (source.maximum() > target.maximum()) {
                try self.encoder.absolute(.mov_rcx, @intCast(target.maximum()));
                try self.encoder.emit(.cmp_rax_rcx);
                const signed = source.isSigned();
                if (policy == .saturate) {
                    const valid = try self.encoder.patchable(if (signed) .jle else .jbe);
                    try self.encoder.emit(.mov_rax_rcx);
                    try self.encoder.patchHere(valid);
                } else try self.conversionFailure(failures, if (signed) .jg else .ja);
            }
        }

        fn integerToFloat(self: *Self, source: structures.numeric.Type, target: structures.numeric.Type) !void {
            const single = target == .f32;
            if (!source.isSigned() and source.width() == 64) {
                try self.encoder.emit(.test_rax);
                const low = try self.encoder.patchable(.jns);
                // (x >> 1) | (x & 1) retains the sticky bit, so the final
                // doubling rounds once, including for unsigned MAX.
                try self.encoder.emit(.mov_rcx_rax);
                try self.encoder.byteImmediate(.shr_rax, 1);
                try self.encoder.emit(.mov_rdx_rax);
                try self.encoder.immediate(.mov_eax, 1);
                try self.encoder.emit(.and_rax_rcx);
                try self.encoder.emit(.mov_rcx_rax);
                try self.encoder.emit(.mov_rax_rdx);
                try self.encoder.emit(.or_rax_rcx);
                try self.encoder.emit(if (single) .cvtsi2ss_xmm0_rax else .cvtsi2sd_xmm0_rax);
                try self.encoder.emit(.movaps_xmm1_xmm0);
                try self.encoder.emit(if (single) .addss_xmm0_xmm1 else .addsd_xmm0_xmm1);
                const done = try self.encoder.patchable(.jmp);
                try self.encoder.patchHere(low);
                try self.encoder.emit(if (single) .cvtsi2ss_xmm0_rax else .cvtsi2sd_xmm0_rax);
                try self.encoder.patchHere(done);
            } else try self.encoder.emit(if (single) .cvtsi2ss_xmm0_rax else .cvtsi2sd_xmm0_rax);
        }

        fn floatBound(self: *Self, value: f64) !void {
            try self.encoder.absolute(.mov_rax, @bitCast(value));
            try self.encoder.emit(.movq_xmm2_rax);
            try self.encoder.emit(.ucomisd_xmm0_xmm2);
        }

        fn floatToInteger(self: *Self, target: structures.numeric.Type, policy: structures.numeric.Policy, failures: *std.ArrayList(u32)) !void {
            try self.encoder.emit(.ucomisd_xmm0_xmm0);
            try self.conversionFailure(failures, .jp);
            var saturated: std.ArrayList(u32) = .empty;
            defer saturated.deinit(self.gpa);
            if (policy == .saturate) {
                try self.floatBound(@floatFromInt(target.minimum()));
                const above_minimum = try self.encoder.patchable(.ja);
                try self.encoder.absolute(.mov_rax, @bitCast(@as(i64, @intCast(target.minimum()))));
                try saturated.append(self.gpa, try self.encoder.patchable(.jmp));
                try self.encoder.patchHere(above_minimum);
                try self.floatBound(@floatFromInt(target.maximum()));
                const below_maximum = try self.encoder.patchable(.jb);
                try self.encoder.absolute(.mov_rax, @intCast(target.maximum()));
                try saturated.append(self.gpa, try self.encoder.patchable(.jmp));
                try self.encoder.patchHere(below_maximum);
            }
            try self.encoder.emit(.movaps_xmm1_xmm0);
            try self.floatBound(0);
            const negative = try self.encoder.patchable(.jb);
            try self.floatBound(18446744073709551616.0);
            try self.conversionFailure(failures, .jae);
            try self.floatBound(9223372036854775808.0);
            const low = try self.encoder.patchable(.jb);
            // Convert the high half of u64 through an exact power-of-two bias.
            try self.encoder.emit(.movaps_xmm2_xmm0);
            try self.encoder.absolute(.mov_rax, @bitCast(@as(f64, 9223372036854775808.0)));
            try self.encoder.emit(.movq_xmm1_rax);
            try self.encoder.emit(.subsd_xmm0_xmm1);
            try self.encoder.emit(if (policy == .round) .cvtsd2si_rax_xmm0 else .cvttsd2si_rax_xmm0);
            try self.encoder.absolute(.mov_rcx, @as(u64, 1) << 63);
            try self.encoder.emit(.or_rax_rcx);
            try self.encoder.emit(.movaps_xmm1_xmm2);
            try self.conversionIntegerBounds(.u64, target, policy, failures);
            const high_done = try self.encoder.patchable(.jmp);
            try self.encoder.patchHere(low);
            try self.encoder.emit(if (policy == .round) .cvtsd2si_rax_xmm0 else .cvttsd2si_rax_xmm0);
            try self.conversionIntegerBounds(.u64, target, policy, failures);
            const low_done = try self.encoder.patchable(.jmp);
            try self.encoder.patchHere(negative);
            try self.floatBound(-9223372036854775808.0);
            try self.conversionFailure(failures, .jb);
            try self.encoder.emit(if (policy == .round) .cvtsd2si_rax_xmm0 else .cvttsd2si_rax_xmm0);
            try self.conversionIntegerBounds(.i64, target, policy, failures);
            try self.encoder.patchHere(high_done);
            try self.encoder.patchHere(low_done);
            if (policy == .checked) {
                try self.encoder.emit(.mov_rsi_rax);
                // integerToFloat may use xmm1 for unsigned conversion.
                try self.encoder.emit(.movaps_xmm2_xmm1);
                try self.integerToFloat(target, .f64);
                try self.encoder.emit(.ucomisd_xmm0_xmm2);
                try self.conversionFailure(failures, .jne);
                try self.encoder.emit(.mov_rax_rsi);
            }
            for (saturated.items) |field| try self.encoder.patchHere(field);
        }

        fn emitNumericConversion(self: *Self, operation: structures.NumericConversion, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const source = self.valueType(operation.operand).numericType().?;
            const target = operation.destination_type.numericType().?;
            var failures: std.ArrayList(u32) = .empty;
            defer failures.deinit(self.gpa);
            try self.loadNumeric(self.valueType(operation.operand), self.valueLocation(operation.operand));
            if (!source.isFloat() and !target.isFloat()) {
                try self.conversionIntegerBounds(source, target, operation.policy, &failures);
            } else if (source.isFloat() and !target.isFloat()) {
                try self.encoder.emit(.movq_xmm0_rax);
                if (source == .f32) try self.encoder.emit(.cvtss2sd_xmm0_xmm0);
                try self.floatToInteger(target, operation.policy, &failures);
            } else if (!source.isFloat()) {
                try self.encoder.emit(.mov_rdi_rax);
                try self.integerToFloat(source, target);
                if (operation.policy == .checked) {
                    try self.encoder.emit(.movaps_xmm2_xmm0);
                    if (target == .f32) try self.encoder.emit(.cvtss2sd_xmm0_xmm0);
                    try self.floatToInteger(source, .truncate, &failures);
                    try self.encoder.emit(.mov_rcx_rax);
                    try self.encoder.emit(.mov_rax_from_rdi);
                    try self.encoder.emit(.cmp_rax_rcx);
                    try self.conversionFailure(&failures, .jne);
                    try self.encoder.emit(.mov_rax_from_rdi);
                    try self.integerToFloat(source, target);
                }
                try self.encoder.emit(.movq_rax_xmm0);
            } else {
                try self.encoder.emit(.movq_xmm0_rax);
                if (operation.policy == .checked) {
                    try self.encoder.emit(.movaps_xmm1_xmm0);
                    try self.encoder.emit(if (source == .f32) .ucomiss_xmm0_xmm0 else .ucomisd_xmm0_xmm0);
                    try self.conversionFailure(&failures, .jp);
                }
                if (source != target) try self.encoder.emit(if (target == .f32) .cvtsd2ss_xmm0_xmm0 else .cvtss2sd_xmm0_xmm0);
                try self.encoder.emit(.movq_rax_xmm0);
                if (operation.policy == .checked and source != target) {
                    try self.encoder.emit(.mov_rsi_rax);
                    try self.encoder.emit(if (target == .f32) .cvtss2sd_xmm0_xmm0 else .cvtsd2ss_xmm0_xmm0);
                    try self.encoder.emit(if (source == .f32) .ucomiss_xmm0_xmm1 else .ucomisd_xmm0_xmm1);
                    try self.conversionFailure(&failures, .jne);
                    try self.encoder.emit(.mov_rax_rsi);
                }
            }
            if (operation.result_type == operation.destination_type) {
                std.debug.assert(failures.items.len == 0);
                return self.storeNumeric(target, destination, 0);
            }
            const layout = try self.types.variantLayout(operation.result_type);
            const members = (try self.types.facts().variantMembers(operation.result_type)).?;
            try self.storeNumeric(target, destination, layout.payload_offset);
            try self.encoder.immediate(.mov_eax, @intCast(std.mem.indexOfScalar(structures.TypeId, members, operation.destination_type).?));
            try self.storeComponent(variantTagWidth(layout), destination, 0);
            const done = try self.encoder.patchable(.jmp);
            for (failures.items) |field| try self.encoder.patchHere(field);
            try self.encoder.immediate(.mov_eax, @intCast(std.mem.indexOfScalar(structures.TypeId, members, .none).?));
            try self.storeComponent(variantTagWidth(layout), destination, 0);
            try self.encoder.patchHere(done);
        }

        fn emitIntegerBinary(self: *Self, comptime operation: std.meta.Tag(structures.FunctionInstruction), operands: structures.BinaryOperands, destination: ValueLocation) !void {
            const lhs = self.valueLocation(operands.lhs);
            const rhs = self.valueLocation(operands.rhs);
            try self.loadComponent(.dword, lhs, 0);
            try self.encoder.integerBinary(operation, rhs);
            try self.storeComponent(.dword, destination, 0);
        }

        fn emitPredicateComparison(self: *Self, operation: structures.CompareOperation) !void {
            const lhs = self.valueLocation(operation.operands.lhs);
            const rhs = self.valueLocation(operation.operands.rhs);
            if (operation.operation != .eqb and operation.operation != .neb) {
                try self.loadComponent(.dword, lhs, 0);
                return self.encoder.compareEax(rhs);
            }
            if (rhs == .immediate) {
                try self.loadComponent(.byte, lhs, 0);
                return self.encoder.compareEax(rhs);
            }
            try self.loadComponent(.byte, rhs, 0);
            try self.encoder.emit(.mov_ecx_eax);
            try self.loadComponent(.byte, lhs, 0);
            try self.encoder.emit(.cmp_eax_ecx);
        }

        fn emitCompare(self: *Self, operation: structures.CompareOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            try self.emitPredicateComparison(operation);
            try self.encoder.scratchDead();
            try self.encoder.emit(Condition.of(operation.operation).set());
            try self.encoder.emit(.movzx_eax_al);
            try self.storeComponent(.byte, destination, 0);
        }

        fn emitSelect(self: *Self, operation: structures.SelectOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const size = (try self.types.layout(operation.type_id)).byte_size;
            std.debug.assert(size == 1 or size == 4);
            const width = Width.ofBytes(size);
            try self.loadComponent(width, self.valueLocation(operation.else_value), 0);
            try self.encoder.emit(.mov_ecx_eax);
            try self.loadComponent(.byte, self.valueLocation(operation.condition), 0);
            try self.encoder.emit(.test_eax);
            try self.loadComponent(width, self.valueLocation(operation.then_value), 0);
            try self.encoder.emit(.cmove_eax_ecx);
            try self.storeComponent(width, destination, 0);
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
            try self.loadComponent(.dword, self.valueLocation(operation.count), 0);
            try self.encoder.emit(.mov_ecx_eax);
            try self.loadValueAddress(self.valueLocation(operation.first));
            try self.encoder.emit(.mov_rdi_rax);
            try self.loadComponent(.ofBytes(size), self.valueLocation(operation.value), 0);
            try self.encoder.emit(if (size == 1) .rep_stosb else .rep_stosd);
        }

        fn emitMove(self: *Self, operation: structures.MoveOperation) !void {
            const size = (try self.types.layout(operation.type_id)).byte_size;
            if (size == 0) return;
            if (size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            try self.loadComponent(.dword, self.valueLocation(operation.count), 0);
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
            try self.emitPredicateComparison(.{ .operation = predicate.operation, .operands = predicate.operands });
            try self.encoder.scratchDead();
            try self.emitFlagBranch(predicate.then_branch, predicate.else_branch, .of(predicate.operation), fallthrough);
        }

        /// Branches on already computed flags: to `then_branch` when the condition holds.
        fn emitFlagBranch(self: *Self, then_branch: structures.FunctionBranch, else_branch: structures.FunctionBranch, condition: Condition, fallthrough: ?structures.FunctionBlockId) !void {
            const final_is_then = fallthrough == then_branch.target or fallthrough != else_branch.target;
            const final = if (final_is_then) then_branch else else_branch;
            const early = if (final_is_then) else_branch else then_branch;
            const operation = if (final_is_then) condition else condition.negated();
            if (early.arguments.start == early.arguments.end) {
                try self.emitConditionalJump(operation.negated(), early.target);
            } else {
                try self.edge_stubs.append(self.gpa, .{
                    .field_offset = try self.encoder.conditionalJump(operation.negated()),
                    .branch = early,
                    .span = self.current_span,
                    .frame = self.current_frame,
                });
            }
            try self.emitBranchCopies(final);
            try self.emitJump(final.target, fallthrough);
        }

        fn emitBranchCopies(self: *Self, branch: structures.FunctionBranch) !void {
            const target = self.ssa.blocks[@backingInt(branch.target)];
            const arguments = self.ssa.branch_arguments[branch.arguments.start..branch.arguments.end];
            const parameters = self.ssa.block_arguments[target.argument_start..target.argument_end];
            const destinations = self.plan.locations[target.argument_start..target.argument_end];
            if (arguments.len == 1) return self.emitBranchArgument(arguments[0], parameters[0].type_id, destinations[0], null);
            if (self.branchCopyDirection(arguments, parameters, destinations)) |backward| {
                for (0..arguments.len) |position| {
                    const index = if (backward) arguments.len - position - 1 else position;
                    try self.emitBranchArgument(arguments[index], parameters[index].type_id, destinations[index], null);
                }
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

        fn branchCopyDirection(self: *Self, arguments: []const structures.FunctionValueUse, parameters: []const structures.FunctionBlockArgument, destinations: []const ValueLocation) ?bool {
            var forward = true;
            var backward = true;
            for (arguments, parameters, destinations, 0..) |argument, parameter, destination, index| {
                if (destination == .discarded) continue;
                if (argument.coerce_to != null or destination == .indirect) return null;
                if (parameter.type_id.numericType() == null and parameter.type_id != .bool and parameter.type_id != .byte) return null;
                const source = self.valueLocation(argument.value);
                if (source == .indirect) return null;
                if (std.meta.eql(source, destination)) continue;
                for (destinations, 0..) |other, other_index| {
                    if (!std.meta.eql(source, other)) continue;
                    forward = forward and other_index > index;
                    backward = backward and other_index < index;
                }
            }
            if (forward) return false;
            if (backward) return true;
            return null;
        }

        /// Writes one branch argument to its parameter, or to `scratch` when given.
        /// An indirect parameter receives the argument's address.
        fn emitBranchArgument(self: *Self, argument: structures.FunctionValueUse, type_id: structures.TypeId, destination: ValueLocation, scratch: ?u32) !void {
            switch (destination) {
                .discarded => {},
                .indirect => |slot| try self.storeUseAddress(argument, scratch orelse slot),
                else => try self.emitUse(argument, type_id, if (scratch) |offset| .{ .stack = offset } else destination),
            }
            try self.encoder.scratchDead();
        }

        fn emitJump(self: *Self, target: structures.FunctionBlockId, fallthrough: ?structures.FunctionBlockId) !void {
            if (fallthrough == target) return;
            try self.jump_patches.append(self.gpa, .{ .field_offset = try self.encoder.patchable(.jmp), .target = target });
        }

        fn emitConditionalJump(self: *Self, condition: Condition, target: structures.FunctionBlockId) !void {
            try self.jump_patches.append(self.gpa, .{ .field_offset = try self.encoder.conditionalJump(condition), .target = target });
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
            if (self.encoder.stream != null or self.plan.stack_size != 0) try self.encoder.offset(.add_rsp, self.plan.stack_size);
            try self.encoder.emit(.ret);
        }

        fn saveRegisters(self: *Self, operation: x86.RegisterOperation) !void {
            if (self.encoder.stream) |*stream| try stream.preserve(operation == .restore, self.plan.stack_size);
        }

        fn emitRuntimeFailure(self: *Self, message: []const u8) !void {
            const data = try self.dataIndex(message);
            const offset = try self.encoder.patchable(.mov_rax);
            try self.relocations.append(self.gpa, .{ .offset = offset, .kind = .address_absolute_64, .reference = .{ .data = data }, .addend = 0 });
            try self.encoder.emit(.mov_rsi_rax);
            try self.encoder.immediate(.mov_edx, @intCast(message.len));
            try self.encoder.immediate(.mov_edi, 2);
            try self.encoder.syscall(1);
            try self.encoder.immediate(.mov_edi, 134);
            try self.encoder.syscall(linux_exit_syscall);
            try self.encoder.emit(.ud2);
        }

        /// GS is private to Chimera. Query its base before accessing it; a new
        /// thread gets its own root state even when clone inherited the old GS.
        fn emitThreadState(self: *Self) !void {
            const scratch = self.plan.runtime_scratch_offset.?;
            try self.encoder.offset(.mov_rax_rsp, scratch + 16);
            try self.encoder.emit(.test_rax);
            const cached = try self.encoder.patchable(.jne);
            try self.encoder.syscall(186); // gettid
            try self.encoder.offset(.mov_rsp_eax, scratch + 8);
            try self.encoder.immediate(.mov_eax, 158); // arch_prctl
            try self.encoder.immediate(.mov_edi, 0x1004); // ARCH_GET_GS
            try self.encoder.offset(.lea_rsi_rsp, scratch);
            try self.encoder.emit(.syscall);
            try self.encoder.immediate(.cmp_eax, 0);
            const get_failed = try self.encoder.patchable(.jne);
            try self.encoder.offset(.mov_rax_rsp, scratch);
            try self.encoder.emit(.test_rax);
            const unattached = try self.encoder.patchable(.je);
            try self.encoder.emit(.mov_rsi_rax);
            try self.encoder.offset(.mov_eax_rsi_offset, 64);
            try self.encoder.offset(.mov_ecx_rsp, scratch + 8);
            try self.encoder.emit(.cmp_eax_ecx);
            const inherited = try self.encoder.patchable(.jne);
            try self.encoder.offset(.mov_rax_rsp, scratch);
            const ready = try self.encoder.patchable(.jmp);
            try self.encoder.patchHere(unattached);
            try self.encoder.patchHere(inherited);
            try self.encoder.immediate(.mov_esi, 4096);
            const mapping_failed = try self.encoder.mapPages();
            try self.encoder.offset(.mov_rsp_rax, scratch);
            try self.encoder.emit(.mov_rdi_rax);
            try self.encoder.offset(.mov_eax_rsp, scratch + 8);
            try self.encoder.offset(.mov_rdi_eax, 64);
            try self.encoder.offset(.mov_rax_rsp, scratch);
            try self.encoder.emit(.mov_rsi_rax);
            try self.encoder.immediate(.mov_edi, 0x1001); // ARCH_SET_GS
            try self.encoder.syscall(158);
            try self.encoder.immediate(.cmp_eax, 0);
            const set_failed = try self.encoder.patchable(.jne);
            try self.encoder.offset(.mov_rax_rsp, scratch);
            const initialized = try self.encoder.patchable(.jmp);
            try self.encoder.patchHere(get_failed);
            try self.encoder.patchHere(mapping_failed);
            try self.encoder.patchHere(set_failed);
            try self.emitRuntimeFailure("context initialization failed\n");
            try self.encoder.patchHere(ready);
            try self.encoder.patchHere(initialized);
            try self.encoder.offset(.mov_rsp_rax, scratch + 16);
            try self.encoder.patchHere(cached);
        }

        fn emitServiceEnter(self: *Self, guard: @FieldType(structures.FunctionInstruction, "service_enter"), node: u32) !void {
            try self.emitThreadState();
            const scratch = self.plan.runtime_scratch_offset.?;
            try self.encoder.offset(.mov_rsp_rax, scratch);
            try self.loadValueAddress(self.valueLocation(guard.receiver));
            try self.encoder.offset(.mov_rsp_rax, node + 8);
            const key = try self.encoder.patchable(.mov_rax);
            try self.appendRelocation(guard.key, key, .address_absolute_64);
            try self.encoder.offset(.mov_rsp_rax, node);
            try self.encoder.offset(.mov_rdi_rsp, scratch);
            try self.encoder.offset(.mov_rax_rdi, 56);
            try self.encoder.offset(.mov_rsp_rax, node + 16);
            const scan = try self.encoder.position();
            try self.encoder.emit(.test_rax);
            const done = try self.encoder.patchable(.je);
            try self.encoder.emit(.mov_rsi_rax);
            try self.encoder.offset(.mov_rax_rsi_offset, 0);
            try self.encoder.offset(.mov_rcx_rsp, node);
            try self.encoder.emit(.cmp_rax_rcx);
            const next = try self.encoder.patchable(.jne);
            try self.encoder.offset(.mov_rax_rsi_offset, 8);
            try self.encoder.offset(.mov_rcx_rsp, node + 8);
            try self.encoder.emit(.cmp_rax_rcx);
            const cycle = try self.encoder.patchable(.je);
            try self.encoder.patchHere(next);
            try self.encoder.offset(.mov_rax_rsi_offset, 16);
            try self.encoder.jumpBack(.jmp, scan);
            try self.encoder.patchHere(cycle);
            try self.emitRuntimeFailure("service cycle\n");
            try self.encoder.patchHere(done);
            try self.encoder.offset(.lea_rax_rsp, node);
            try self.encoder.offset(.mov_rdi_rsp, scratch);
            try self.encoder.offset(.mov_rdi_rax_offset, 56);
        }

        fn contextOffset(entry: structures.ContextEntry) u32 {
            return switch (entry) {
                .allocator => 0,
                .logger => 32,
            };
        }

        fn emitContextRead(self: *Self, operation: @FieldType(structures.FunctionInstruction, "context_read"), destination: ValueLocation) !void {
            try self.emitThreadState();
            try self.encoder.addRax(contextOffset(operation.entry));
            const scratch = self.plan.runtime_scratch_offset.?;
            try self.encoder.offset(.mov_rsp_rax, scratch);
            try self.encoder.emit(.mov_rax_rax);
            try self.encoder.emit(.test_rax);
            const ready = try self.encoder.patchable(.jne);
            try self.emitCall(.{ .target = .{ .direct = operation.root }, .arguments = .{ .start = 0, .end = 0 }, .return_type = operation.type_id }, destination);
            const layout = try self.types.layout(operation.type_id);
            try self.copyRange(destination, 0, .{ .reference = .{ .stack = scratch } }, 0, layout.byte_size);
            try self.encoder.patchHere(ready);
            try self.copyValue(operation.type_id, .{ .indirect = scratch }, destination);
        }

        fn emitContextWrite(self: *Self, operation: @FieldType(structures.FunctionInstruction, "context_write")) !void {
            try self.emitThreadState();
            try self.encoder.addRax(contextOffset(operation.entry));
            const scratch = self.plan.runtime_scratch_offset.?;
            try self.encoder.offset(.mov_rsp_rax, scratch);
            const layout = try self.types.layout(self.valueType(operation.source));
            try self.copyRange(self.valueLocation(operation.source), 0, .{ .reference = .{ .stack = scratch } }, 0, layout.byte_size);
        }

        fn emitServiceLeave(self: *Self) !void {
            try self.emitThreadState();
            try self.encoder.emit(.mov_rdi_rax);
            try self.encoder.offset(.mov_rax_rdi, 56);
            try self.encoder.emit(.mov_rsi_rax);
            try self.encoder.offset(.mov_rax_rsi_offset, 16);
            try self.encoder.offset(.mov_rdi_rax_offset, 56);
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

        fn emitErasedCallable(self: *Self, callable: @FieldType(structures.FunctionInstruction, "erased_callable"), destination: ValueLocation) !void {
            if (callable.owns_environment) {
                const payload = callable.payload.?;
                const owner_type = self.valueType(payload);
                const environment_type = (try self.types.facts().allocationElement(owner_type)).?;
                const environment = try self.types.layout(environment_type);
                const owner = try self.types.layout(owner_type);
                const trailer = std.mem.alignForward(u32, environment.byte_size, owner.byte_alignment);
                try self.copyRange(self.valueLocation(payload), 0, .{ .reference = self.valueLocation(payload) }, trailer, owner.byte_size);
            }
            if (destination == .discarded) return;
            const field = try self.encoder.patchable(.mov_rax);
            try self.storeComponent(.qword, destination, 0);
            try self.appendRelocation(callable.invocation, field, .address_absolute_64);
            self.relocations.items[self.relocations.items.len - 1].addend = -24;
            if (callable.payload) |payload| {
                try self.loadComponent(.qword, self.valueLocation(payload), 0);
            } else try self.encoder.absolute(.mov_rax, 0);
            try self.storeComponent(.qword, destination, 8);
        }

        fn emitCallableAllocation(self: *Self, operation: structures.BorrowOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const environment_type = (try self.types.facts().allocationElement(operation.type_id)).?;
            const environment = try self.types.layout(environment_type);
            const owner = try self.types.layout(operation.type_id);
            const trailer = std.mem.alignForward(u32, environment.byte_size, owner.byte_alignment);
            var offset: u32 = 0;
            for ([_]Width{ .qword, .dword, .byte }) |width| {
                while (owner.byte_size - offset >= width.bytes()) : (offset += width.bytes()) {
                    try self.loadComponent(.qword, self.valueLocation(operation.source), 8);
                    try self.encoder.offset(width.select(&load_rax), trailer + offset);
                    try self.storeComponent(width, destination, offset);
                }
            }
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
                for (compiled.panic_trace_offsets) |field| try self.panic_trace_offsets.append(self.gpa, std.math.add(u32, start, field) catch return error.FunctionTooLarge);
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
            try self.storeComponent(.dword, destination, bytes_offset + span_layout.field_offsets[1]);
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

        fn emitAllocationElementAddress(self: *Self, operation: structures.AllocationElement) !void {
            const index = @backingInt(operation.allocation);
            const base: ValueLocation = if (self.plan.allocation_bases.len != 0 and self.plan.allocation_bases[index])
                .{ .register = @fromBackingInt(@intCast(index)) }
            else
                self.valueLocation(operation.allocation);
            try self.emitElementAddress(base, false, operation.index, operation.type_id, .element);
        }

        /// Leaves the address of element `index` in rax. The elements start at
        /// the address `base` holds, or at `base` itself when `base_is_value`.
        fn emitElementAddress(self: *Self, base: ValueLocation, base_is_value: bool, index: structures.FunctionValueId, element_type: structures.TypeId, kind: IndexKind) !void {
            const byte_size = (try self.types.layout(element_type)).byte_size;
            if (byte_size > std.math.maxInt(i32)) return error.UnsupportedElementLayout;
            const add_scaled_index: x86.Operation = switch (byte_size) {
                2 => .lea_rax_rax_rcx_2,
                4 => .lea_rax_rax_rcx_4,
                8 => .lea_rax_rax_rcx_8,
                else => .add_rax_rcx,
            };
            if (byte_size != 0) {
                try self.loadComponent(.dword, self.valueLocation(index), 0);
                // Array/allocation projections require valid nonnegative
                // indices. Cursor offsets independently permit negatives.
                try self.encoder.emit(if (kind == .element) .mov_ecx_eax else .movsxd_rcx_eax);
                if (byte_size != 1 and add_scaled_index == .add_rax_rcx) try self.encoder.immediate(.imul_rcx, @intCast(byte_size));
            }
            if (base_is_value) try self.loadValueAddress(base) else try self.loadAddress(base);
            if (byte_size != 0) try self.encoder.emit(add_scaled_index);
        }

        fn emitCursorElement(self: *Self, operation: structures.CursorElement, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const element = (try self.types.facts().borrowElement(operation.type_id)) orelse (try self.types.facts().storageCursorAccess(operation.type_id)).?;
            try self.emitElementAddress(self.valueLocation(operation.cursor), false, operation.index, element, .offset);
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
                .register => |register| try self.encoder.register(.load_rax, register),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.emit(.mov_rax_rax);
                },
                .discarded, .immediate, .eax => unreachable,
            }
        }

        fn storeAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(.mov_rsp_rax, offset),
                .register => |register| try self.encoder.register(.store_rax, register),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rdi_rsp, offset);
                    try self.encoder.offset(.mov_rdi_rax_offset, 0);
                },
                .discarded => {},
                .immediate, .eax => unreachable,
            }
        }

        /// Points an indirect location at the address in rax.
        fn bindIndirect(self: *Self, location: ValueLocation) !void {
            try self.encoder.offset(.mov_rsp_rax, location.indirect);
        }

        /// Computes a 32-bit result in eax from one operand.
        fn emitUnary(self: *Self, width: Width, operand: structures.FunctionValueId, operation: ?x86.Operation, destination: ValueLocation) !void {
            try self.loadComponent(width, self.valueLocation(operand), 0);
            if (operation) |code| try self.encoder.emit(code);
            try self.storeComponent(.dword, destination, 0);
        }

        fn loadVariantTag(self: *Self, type_id: structures.TypeId, source: ValueLocation) !void {
            const layout = try self.types.variantLayout(type_id);
            const width = variantTagWidth(layout);
            try self.loadComponent(width, source, 0);
            if (source == .register or source == .eax) {
                if (width == .byte) try self.encoder.emit(.movzx_eax_al);
                if (width == .word) try self.encoder.emit(.movzx_eax_ax);
            }
        }

        fn emitVariantTag(self: *Self, operand: structures.FunctionValueId, destination: ValueLocation) !void {
            try self.loadVariantTag(self.valueType(operand), self.valueLocation(operand));
            try self.storeComponent(.dword, destination, 0);
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
                const target_layout = try self.types.variantLayout(target_type);
                const actual_layout = try self.types.layout(actual_type);
                try self.copyRange(source, 0, .{ .value = destination }, target_layout.payload_offset, actual_layout.byte_size);
                try self.encoder.immediate(.mov_eax, std.math.cast(i32, tag_mapping[0]) orelse return error.FunctionTooLarge);
                try self.storeComponent(variantTagWidth(target_layout), destination, 0);
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
            try self.loadVariantTag(actual_type, source);
            try self.remapVariantTag(tag_mapping);
            try self.storeComponent(variantTagWidth(target_layout), destination, 0);
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
                .allocation_array => try self.loadAddress(source),
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
            const field_layout = try self.types.layout(operation.field_type);
            try self.copyRange(
                self.valueLocation(operation.operand),
                layout.field_offsets[operation.field_index],
                .{ .value = destination },
                0,
                field_layout.byte_size,
            );
        }

        fn copyRange(self: *Self, source: ValueLocation, source_start: u32, destination: CopyDestination, destination_start: u32, byte_size: u32) !void {
            if (byte_size == 0) return;
            if (destination == .value and destination.value == .discarded) return;
            if (destination == .value and source_start == destination_start and std.meta.eql(source, destination.value)) return;
            if (byte_size == @sizeOf(u64) and (source == .register or (destination == .value and destination.value == .register))) {
                if (destination == .reference) {
                    try self.loadAddress(destination.reference);
                    try self.encoder.emit(.mov_rdi_rax);
                }
                try self.loadComponent(.qword, source, source_start);
                switch (destination) {
                    .value => |location| try self.storeComponent(.qword, location, destination_start),
                    .reference => try self.encoder.offset(.mov_rdi_rax_offset, destination_start),
                }
                return;
            }
            if (byte_size > @sizeOf(u32)) return self.copyMemoryRange(source, source_start, destination, destination_start, byte_size);
            if (destination == .reference) {
                try self.loadAddress(destination.reference);
                try self.encoder.emit(.mov_rdi_rax);
            }
            var offset: u32 = 0;
            for ([_]Width{ .dword, .byte }) |width| {
                while (byte_size - offset >= width.bytes()) : (offset += width.bytes()) {
                    try self.loadComponent(width, source, source_start + offset);
                    switch (destination) {
                        .value => |location| try self.storeComponent(width, location, destination_start + offset),
                        .reference => try self.encoder.offset(width.select(&store_rdi), destination_start + offset),
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
            for ([_]Width{ .qword, .dword, .byte }) |width| {
                while (byte_size - offset >= width.bytes()) : (offset += width.bytes()) {
                    try self.copyComponent(width, source_address, source_start + offset, destination_address, destination_start + offset);
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

        fn copyComponent(self: *Self, width: Width, source: CopyAddress, source_offset: u32, destination: CopyAddress, destination_offset: u32) !void {
            const load: x86.Operation = if (source == .stack) width.select(&load_rsp) else switch (width) {
                .byte => .movzx_eax_rsi_offset,
                .word => unreachable,
                .dword => .mov_eax_rsi_offset,
                .qword => .mov_rax_rsi_offset,
            };
            const store = width.select(if (destination == .stack) &store_rsp else &store_rdi);
            const source_base = if (source == .stack) source.stack else 0;
            const destination_base = if (destination == .stack) destination.stack else 0;
            try self.encoder.offset(load, std.math.add(u32, source_base, source_offset) catch return error.FunctionTooLarge);
            try self.encoder.offset(store, std.math.add(u32, destination_base, destination_offset) catch return error.FunctionTooLarge);
        }

        fn loadComponent(self: *Self, width: Width, location: ValueLocation, component_offset: u32) !void {
            switch (location) {
                .immediate => |value| try self.encoder.immediate(.mov_eax, immediateComponent(width, value, component_offset)),
                .eax => std.debug.assert(component_offset == 0),
                .register => |register| {
                    std.debug.assert(component_offset + width.bytes() <= 8);
                    try self.encoder.register(if (width == .qword or component_offset != 0) .load_rax else if (width == .byte) .load_byte else .load_eax, register);
                    if (component_offset != 0) try self.encoder.byteImmediate(.shr_rax, @intCast(component_offset * 8));
                },
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(width.select(&load_rsp), std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rax_rsp, offset);
                    try self.encoder.offset(width.select(&.{ .movzx_eax_rax, .movzx_eax_word_rax, .mov_eax_rax, .mov_rax_rax_offset }), component_offset);
                },
                .discarded => unreachable,
            }
        }

        fn storeComponent(self: *Self, width: Width, location: ValueLocation, component_offset: u32) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.offset(width.select(&store_rsp), std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .eax => std.debug.assert(component_offset == 0),
                .register => |register| {
                    std.debug.assert(component_offset == 0);
                    try self.encoder.register(if (width == .qword) .store_rax else if (width == .byte) .store_byte else .store_eax, register);
                },
                .discarded => {},
                .immediate => unreachable,
                .indirect => |offset| {
                    try self.encoder.offset(.mov_rdi_rsp, offset);
                    try self.encoder.offset(width.select(&store_rdi), component_offset);
                },
            }
        }

        fn encodeBody(self: *Self) !void {
            const stream = if (self.encoder.stream) |*stream| stream else return;
            try stream.coalesceAccumulatorCopies(self.plan.spills.len);
            stream.verify(self.plan.spills.len);
            var allocation = try registers.allocate(self.gpa, stream, self.plan.spills.len);
            defer allocation.deinit(self.gpa);
            const frame = try FrameLayout.init(self.plan, self.ssa, stream, allocation, self.gpa);
            defer self.gpa.free(frame.slots);
            try frame.apply(stream);
            const spills = try self.gpa.dupe(u32, self.plan.spills);
            defer self.gpa.free(spills);
            for (stream.instructions.items) |instruction| {
                const access = instruction.registerAccess() orelse continue;
                const index = @backingInt(access.value);
                if (allocation.registers[index] == null) spills[index] = try frame.relocate(self.plan.spills[index]);
            }
            var encoded = try stream.encode(allocation.registers, spills, allocation.used);
            defer encoded.deinit(self.gpa);
            for (self.relocations.items) |*relocation| relocation.offset = encoded.fields[relocation.offset];
            for (self.trace_sites.items) |*site| {
                site.return_offset = encoded.positions[site.return_offset];
                site.stack_size = frame.stack_size;
            }
            for (self.initializer_patches.items) |*patch| patch.field_offset = encoded.fields[patch.field_offset];
            for (self.panic_trace_offsets.items) |*field| field.* = encoded.fields[field.*];
            stream.deinit();
            self.encoder.stream = null;
            self.encoder.code = encoded.code;
            encoded.code = .empty;
        }

        fn finish(self: *Self) !structures.CompiledFunction {
            var artifact: structures.CompiledFunction = .{ .required_alignment = 1 };
            errdefer artifact.deinit(self.gpa);
            artifact.relocations = try self.relocations.toOwnedSlice(self.gpa);
            artifact.panic_trace_offsets = try self.panic_trace_offsets.toOwnedSlice(self.gpa);
            artifact.requires_sigpipe_ignore = artifact.panic_trace_offsets.len != 0;
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
    var plan = try LocationPlan.init(ssa, types, gpa);
    defer plan.deinit(gpa);
    var emitter = try FunctionEmitter(@TypeOf(types)).init(gpa, ssa, &plan, types);
    defer emitter.deinit();
    if (emitter.encoder.stream) |*stream| {
        const capacity = std.math.mul(usize, plan.locations.len, 4) catch return error.FunctionTooLarge;
        try stream.instructions.ensureTotalCapacity(gpa, capacity);
    }

    try emitter.emit();
    try emitter.encodeBody();
    try emitter.emitInitializerRegions();
    return emitter.finish();
}

pub fn attachCallableDescriptor(artifact: *structures.CompiledFunction, instance: structures.InstanceId, copy: structures.InstanceId, drop: structures.InstanceId, allocator: std.mem.Allocator) !void {
    const descriptor_size = 24;
    // Every code offset of the artifact, including its trace and relocation fields, then fits in 32 bits.
    if (artifact.code.len > std.math.maxInt(u32) - descriptor_size) return error.FunctionTooLarge;
    const code = try std.mem.concat(allocator, u8, &.{ &@as([descriptor_size]u8, @splat(0)), artifact.code });
    errdefer allocator.free(code);
    const references = try std.mem.concat(allocator, structures.InstanceId, &.{ artifact.referenced_instances, &.{ instance, copy, drop } });
    errdefer allocator.free(references);
    const relocations = try allocator.alloc(structures.CompiledFunction.Relocation, artifact.relocations.len + 3);
    errdefer allocator.free(relocations);
    for (artifact.relocations, relocations[0..artifact.relocations.len]) |source, *relocation| {
        relocation.* = source;
        relocation.offset += descriptor_size;
    }
    for (relocations[artifact.relocations.len..], 0..) |*relocation, index| {
        relocation.* = .{ .offset = @intCast(index * 8), .kind = .address_absolute_64, .reference = .{ .function = @fromBackingInt(@intCast(artifact.referenced_instances.len + index)) }, .addend = 0 };
    }
    allocator.free(artifact.code);
    allocator.free(artifact.relocations);
    allocator.free(artifact.referenced_instances);
    artifact.code = code;
    artifact.relocations = relocations;
    artifact.referenced_instances = references;
    artifact.required_alignment = @max(artifact.required_alignment, 8);
    artifact.entry_offset = descriptor_size;
    for (@constCast(artifact.trace_sites)) |*site| site.return_offset += descriptor_size;
    for (@constCast(artifact.panic_trace_offsets)) |*offset| offset.* += descriptor_size;
}
// External functions have no frame: incoming argument storage starts at
// rsp + 8, past the return address.

pub fn compileExternalExit(gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder: Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    try encoder.offset(.mov_eax_rsp, 8);
    try encoder.emit(.mov_edi_eax);
    try encoder.syscall(linux_exit_syscall);
    return externalArtifact(&encoder);
}

pub fn compileExternalPanic(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    var layout = try signatureLayout(types, signature, gpa);
    defer layout.deinit(gpa);
    const message = layout.arguments[0];
    var encoder: Encoder = .{ .gpa = gpa };
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
    var artifact = try externalArtifact(&encoder);
    errdefer artifact.deinit(gpa);
    artifact.panic_trace_offsets = try gpa.dupe(u32, &.{trace});
    artifact.relocations = try gpa.dupe(structures.CompiledFunction.Relocation, &.{
        .{ .offset = prefix_address, .kind = .address_absolute_64, .reference = .{ .data = 0 }, .addend = 0 },
        .{ .offset = bare_address, .kind = .address_absolute_64, .reference = .{ .data = 0 }, .addend = 0 },
        .{ .offset = newline_address, .kind = .address_absolute_64, .reference = .{ .data = 0 }, .addend = 7 },
    });
    const text = try gpa.dupe(u8, "panic: \n");
    errdefer gpa.free(text);
    artifact.constant_data = try gpa.dupe(structures.ByteString, &.{.{ .bytes = text }});
    artifact.requires_sigpipe_ignore = true;
    return artifact;
}

/// Leaves a span argument's byte count in edx and its data address in rax.
fn emitPanicMessage(encoder: *Encoder, message: ValueLocation) !void {
    try emitIncomingSize(encoder, message);
    try encoder.emit(.mov_edx_eax);
    try emitIncomingAddress(encoder, message);
}

/// Loads the 64-bit address at the start of an incoming argument into rax.
fn emitIncomingAddress(encoder: *Encoder, argument: ValueLocation) !void {
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
fn emitIncomingSize(encoder: *Encoder, argument: ValueLocation) !void {
    switch (argument) {
        .stack => |offset| try encoder.offset(.mov_eax_rsp, 8 + offset + 8),
        .indirect => |offset| {
            try encoder.offset(.mov_rax_rsp, 8 + offset);
            try encoder.offset(.mov_eax_rax, 8);
        },
        else => unreachable,
    }
}

fn emitPanicText(encoder: *Encoder, size: i32) !u32 {
    const address = try encoder.patchable(.mov_rax);
    try encoder.emit(.mov_rsi_rax);
    try encoder.immediate(.mov_edx, size);
    return address;
}

/// Best-effort, allocation-free stderr output. Failed writes never panic again.
fn emitPanicWriter(encoder: *Encoder) !void {
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
fn emitPanicTrace(encoder: *Encoder) !u32 {
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
    try encoder.syscall(linux_exit_syscall);
    try encoder.emit(.ud2);
    try encoder.patchHere(write);
    try emitPanicWriter(encoder);
    return table_address;
}

pub fn compileExternalAllocateRaw(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder: Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    var call = try signatureLayout(types, signature, gpa);
    defer call.deinit(gpa);
    const result = try serviceReturn(types, signature.return_type, try types.facts().allocationError());
    const argument_offset = call.arguments[0].stack + 8;
    try encoder.offset(.mov_esi_rsp, argument_offset);
    try encoder.emit(.test_esi);
    const invalid_size = try encoder.patchable(.jl);
    try encoder.offset(.mov_eax_rsp, argument_offset + 4);
    try encoder.immediate(.cmp_eax, 0);
    const invalid_alignment = try encoder.patchable(.jle);
    try encoder.immediate(.cmp_eax, 4096);
    const unsupported_alignment = try encoder.patchable(.ja);
    try encoder.emit(.mov_ecx_eax);
    try encoder.immediate(.sub_eax, 1);
    try encoder.emit(.and_eax_ecx);
    try encoder.immediate(.cmp_eax, 0);
    const unaligned = try encoder.patchable(.jne);
    try encoder.emit(.test_esi);
    const nonzero_size = try encoder.patchable(.jne);
    try encoder.immediate(.mov_esi, 1);
    try encoder.patchHere(nonzero_size);
    const allocation_failed = try encoder.mapPages();
    try encoder.offset(.mov_rsp_eax, result.payload);
    try encoder.byteImmediate(.shr_rax, 32);
    try encoder.offset(.mov_rsp_eax, result.payload + 4);
    try encoder.offset(.mov_eax_rsp, argument_offset);
    try encoder.offset(.mov_rsp_eax, result.payload + 8);
    try encoder.offset(.mov_eax_rsp, argument_offset + 4);
    try encoder.offset(.mov_rsp_eax, result.payload + 12);
    try emitOptionalReturn(&encoder, result, true);
    try encoder.patchHere(allocation_failed);
    try emitAllocationFailure(&encoder, result, 0);
    try encoder.patchHere(invalid_size);
    try encoder.patchHere(invalid_alignment);
    try encoder.patchHere(unsupported_alignment);
    try encoder.patchHere(unaligned);
    try emitAllocationFailure(&encoder, result, 1);
    return externalArtifact(&encoder);
}

pub fn compileExternalCursorAligned(signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder: Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    var layout = try signatureLayout(types, signature, gpa);
    defer layout.deinit(gpa);
    try emitIncomingAddress(&encoder, layout.arguments[0]);
    try encoder.offset(.mov_ecx_rsp, layout.arguments[1].stack + 8);
    try encoder.immediate(.sub_ecx, 1);
    try encoder.emit(.and_eax_ecx);
    try encoder.immediate(.cmp_eax, 0);
    try encoder.emit(.sete_al);
    try encoder.offset(.mov_rsp_al, 8);
    try encoder.emit(.ret);
    return externalArtifact(&encoder);
}

pub fn compileExternalDeallocateRaw(gpa: std.mem.Allocator) !structures.CompiledFunction {
    var encoder: Encoder = .{ .gpa = gpa };
    defer encoder.deinit();
    // The only argument refers to the storage's address and byte size.
    const storage: ValueLocation = .{ .indirect = 0 };
    try emitIncomingAddress(&encoder, storage);
    try encoder.emit(.mov_rdi_rax);
    try emitIncomingSize(&encoder, storage);
    try encoder.emit(.mov_esi_eax);
    try encoder.emit(.test_esi);
    const nonempty = try encoder.patchable(.jne);
    try encoder.immediate(.mov_esi, 1);
    try encoder.patchHere(nonempty);
    try encoder.syscall(linux_munmap_syscall);
    try encoder.emit(.ret);
    return externalArtifact(&encoder);
}

pub fn compileExternalByteIo(read: bool, signature: structures.FunctionSignature, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    var layout = try signatureLayout(types, signature, gpa);
    defer layout.deinit(gpa);
    // Arguments are (descriptor, allocation, offset, count) to read and
    // (descriptor, span) to write.
    const arguments = layout.arguments;
    const result = try serviceReturn(types, signature.return_type, try types.facts().ioError());
    var encoder: Encoder = .{ .gpa = gpa };
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
    try encoder.syscall(if (read) 0 else 1);
    try encoder.immediate(.cmp_eax, -4);
    try encoder.jumpBack(.je, retry);
    try encoder.immediate(.cmp_eax, 0);
    const failed = try encoder.patchable(.jl);
    try encoder.patchHere(empty);
    try encoder.offset(.mov_rsp_eax, result.payload);
    try emitOptionalReturn(&encoder, result, true);
    try encoder.patchHere(failed);
    try encoder.emit(.neg_eax);
    try encoder.offset(.mov_rsp_eax, result.payload);
    try encoder.immediate(.mov_eax, 0);
    try encoder.offset(.mov_rsp_eax, result.payload + 4);
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

// Zero existing tag padding so full-width register reads need no mask.
fn variantTagWidth(layout: structures.VariantLayout) Width {
    return .ofBytes(@min(4, layout.payload_offset));
}

const OptionalReturn = struct { tag: u32, payload: u32, tag_width: Width, present: i32, absent: i32 };

fn serviceReturn(types: anytype, type_id: structures.TypeId, error_type: structures.TypeId) !OptionalReturn {
    const members = (try types.facts().variantMembers(type_id)).?;
    std.debug.assert(members.len == 2);
    const absent = std.mem.indexOfScalar(structures.TypeId, members, error_type).?;
    const layout = try types.variantLayout(type_id);
    std.debug.assert(layout.tag_size == 1);
    return .{ .tag = 8, .payload = 8 + layout.payload_offset, .tag_width = variantTagWidth(layout), .present = @intCast(1 - absent), .absent = @intCast(absent) };
}

fn emitAllocationFailure(encoder: *Encoder, result: OptionalReturn, code: i32) !void {
    try encoder.immediate(.mov_eax, code);
    try encoder.offset(.mov_rsp_eax, result.payload);
    try emitOptionalReturn(encoder, result, false);
}

fn emitOptionalReturn(encoder: *Encoder, result: OptionalReturn, present: bool) !void {
    try encoder.immediate(.mov_eax, if (present) result.present else result.absent);
    try encoder.offset(result.tag_width.select(&store_rsp), result.tag);
    try encoder.emit(.ret);
}

fn externalArtifact(encoder: *Encoder) !structures.CompiledFunction {
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
    var image: Encoder = .{ .gpa = result_allocator };
    defer image.deinit();
    try image.code.appendNTimes(result_allocator, 0, code_file_offset);
    for (functions) |function| if (function.artifact.requires_sigpipe_ignore) {
        try emitIgnoreSigpipe(&image);
        break;
    };
    const entry_call = try image.patchable(.call_relative);
    try image.immediate(.mov_edi, 0);
    try image.syscall(linux_exit_syscall);

    const needs_panic_trace = for (functions) |function| {
        if (function.artifact.panic_trace_offsets.len != 0) break true;
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
    try image.patch(entry_call, function_offsets[entry_index] + functions[entry_index].artifact.entry_offset);

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
            .function => |reference| target: {
                const index = function_indices.get(function.artifact.referenced_instances[@backingInt(reference)]).?;
                break :target function_offsets[index] + functions[index].artifact.entry_offset;
            },
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
fn appendPanicTrace(image: *Encoder, functions: []const ReachableFunction, function_offsets: []const usize) !void {
    const trace = image.code.items.len;
    const table_field = try emitPanicTrace(image);
    for (functions, function_offsets) |function, function_offset| for (function.artifact.panic_trace_offsets) |field| {
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
fn emitIgnoreSigpipe(encoder: *Encoder) !void {
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

const Alu = enum { add, sub, imul, @"and", @"or", xor, cmp };

/// The accumulator forms of `alu`, one for each location of the right operand.
fn accumulatorOperations(alu: Alu, wide: bool) Encoder.RhsOperations {
    return switch (alu) {
        inline else => |tag| switch (wide) {
            inline else => |is_wide| {
                const name = @tagName(tag) ++ if (is_wide) "_rax" else "_eax";
                return .{
                    .immediate = @field(x86.Operation, name),
                    .register = @field(x86.RegisterOperation, name),
                    .stack = @field(x86.Operation, name ++ "_rsp"),
                    .indirect = @field(x86.Operation, name ++ "_mem_rcx"),
                };
            },
        },
    };
}

/// Encodes x86 directly, or into a machine stream when values still need
/// register allocation.
const Encoder = struct {
    const RhsOperations = struct { immediate: ?x86.Operation = null, register: x86.RegisterOperation, stack: x86.Operation, indirect: x86.Operation };

    gpa: std.mem.Allocator,
    code: std.ArrayList(u8) = .empty,
    /// Pending machine instructions; null when encoding directly into `code`.
    stream: ?machine.Function = null,
    label_end: usize = 0,
    last_store: struct { operation: x86.Operation, offset: u32, end: usize } = .{ .operation = .ret, .offset = 0, .end = 0 },

    fn deinit(self: *Encoder) void {
        self.code.deinit(self.gpa);
        if (self.stream) |*stream| stream.deinit();
    }

    fn position(self: *Encoder) !u32 {
        if (self.stream) |*stream| return stream.position();
        self.label_end = self.code.items.len;
        return std.math.cast(u32, self.code.items.len) orelse error.FunctionTooLarge;
    }

    fn appendFixed(self: *Encoder, operation: x86.Operation, operand: x86.Operand, bits: u64) !void {
        if (self.stream) |*stream| return stream.appendFixed(operation, operand, bits);
        std.debug.assert(x86.encoding(operation).operand == operand);
        try x86.append(&self.code, self.gpa, operation, bits);
    }

    fn emit(self: *Encoder, operation: x86.Operation) !void {
        try self.appendFixed(operation, .none, 0);
    }

    fn immediate(self: *Encoder, operation: x86.Operation, value: i32) !void {
        try self.appendFixed(operation, .i32, @as(u32, @bitCast(value)));
    }

    fn syscall(self: *Encoder, number: i32) !void {
        try self.immediate(.mov_eax, number);
        try self.emit(.syscall);
    }

    /// Maps `esi` bytes of anonymous memory and returns the jump taken when the mapping fails.
    fn mapPages(self: *Encoder) !u32 {
        try self.emit(.zero_edi);
        try self.immediate(.mov_edx, 3);
        try self.immediate(.mov_r10d, 0x22);
        try self.immediate(.mov_r8d, -1);
        try self.emit(.zero_r9d);
        try self.syscall(linux_mmap_syscall);
        try self.immediate(.cmp_rax, -4095);
        return self.patchable(.jae);
    }

    fn byteImmediate(self: *Encoder, operation: x86.Operation, value: u8) !void {
        try self.appendFixed(operation, .u8, value);
    }

    fn absolute(self: *Encoder, operation: x86.Operation, value: u64) !void {
        try self.appendFixed(operation, .u64, value);
    }

    fn offset(self: *Encoder, operation: x86.Operation, value: u32) !void {
        if (self.stream == null) {
            // A reload directly after its store, with no label between, is redundant.
            const store = self.last_store;
            const reload: x86.Operation = if (store.operation == .mov_rsp_eax) .mov_eax_rsp else .mov_rax_rsp;
            if (store.end == self.code.items.len and self.label_end != store.end and store.offset == value and operation == reload) return;
        }
        try self.appendFixed(operation, .u32, value);
        if (self.stream == null and (operation == .mov_rsp_eax or operation == .mov_rsp_rax))
            self.last_store = .{ .operation = operation, .offset = value, .end = self.code.items.len };
    }

    fn register(self: *Encoder, operation: x86.RegisterOperation, value: machine.ValueId) !void {
        try self.stream.?.register(operation, value, 0);
    }

    /// Lets the machine stream's peepholes treat the scratch registers as dead.
    fn scratchDead(self: *Encoder) !void {
        if (self.stream) |*stream| try stream.instructions.append(self.gpa, .scratch_dead);
    }

    /// Emits `operation` with a zero operand and returns the operand's code
    /// offset for a later patch.
    fn patchable(self: *Encoder, operation: x86.Operation) !u32 {
        if (self.stream) |*stream| return stream.patchable(operation);
        const encoding = x86.encoding(operation);
        std.debug.assert(encoding.compact == .none);
        const field = std.math.cast(u32, self.code.items.len + encoding.prefix.len) orelse return error.FunctionTooLarge;
        try x86.append(&self.code, self.gpa, operation, 0);
        return field;
    }

    /// Points the 32-bit relative field at code offset `field` to code offset `target`.
    fn patch(self: *Encoder, field: usize, target: usize) !void {
        if (self.stream) |*stream| return stream.patch(field, target);
        try patchRelativeDisplacement(self.code.items, field, target, field + @sizeOf(i32), 0);
    }

    fn patchHere(self: *Encoder, field: usize) !void {
        try self.patch(field, try self.position());
    }

    /// Emits a jump or call to already emitted code.
    fn jumpBack(self: *Encoder, operation: x86.Operation, target: usize) !void {
        try self.patch(try self.patchable(operation), target);
    }

    fn conditionalJump(self: *Encoder, condition: Condition) !u32 {
        return self.patchable(condition.jump());
    }

    /// Adds a byte offset to rax; a zero offset emits nothing.
    fn addRax(self: *Encoder, value: u32) !void {
        if (value == 0) return;
        try self.immediate(.add_rax, std.math.cast(i32, value) orelse return error.FunctionTooLarge);
    }

    /// Applies the operation selected by the right operand's location.
    fn rhsOperation(self: *Encoder, rhs: ValueLocation, operations: RhsOperations) !void {
        switch (rhs) {
            .immediate => |value| try self.immediate(operations.immediate.?, value),
            .register => |selected| try self.register(operations.register, selected),
            .stack, .incoming_argument => |stack_offset| try self.offset(operations.stack, stack_offset),
            .indirect => |stack_offset| {
                try self.offset(.mov_rcx_rsp, stack_offset);
                try self.emit(operations.indirect);
            },
            .eax, .return_buffer, .discarded => unreachable,
        }
    }

    fn compareEax(self: *Encoder, rhs: ValueLocation) !void {
        try self.rhsOperation(rhs, accumulatorOperations(.cmp, false));
    }

    fn integerBinary(self: *Encoder, comptime operation: std.meta.Tag(structures.FunctionInstruction), rhs: ValueLocation) !void {
        if (operation == .divsi) return self.divide(rhs);
        if (operation == .shli or operation == .shrsi) return self.shift(operation, rhs);
        const alu: Alu = switch (operation) {
            .addi => .add,
            .subi => .sub,
            .muli => .imul,
            else => comptime unreachable,
        };
        try self.rhsOperation(rhs, accumulatorOperations(alu, false));
    }

    fn loadEcx(self: *Encoder, rhs: ValueLocation) !void {
        try self.rhsOperation(rhs, .{ .register = .load_ecx, .stack = .mov_ecx_rsp, .indirect = .mov_ecx_rcx });
    }

    fn shift(self: *Encoder, comptime operation: std.meta.Tag(structures.FunctionInstruction), rhs: ValueLocation) !void {
        const shift_immediate = if (operation == .shli) x86.Operation.shl_eax else x86.Operation.sar_eax;
        if (rhs == .immediate) {
            if (rhs.immediate < 0 or rhs.immediate >= 32) return self.emit(.ud2);
            if (rhs.immediate != 0) try self.byteImmediate(shift_immediate, @intCast(rhs.immediate));
            return;
        }
        try self.loadEcx(rhs);
        try self.immediate(.cmp_ecx, 31);
        const invalid = try self.patchable(.ja);
        try self.emit(if (operation == .shli) .shl_eax_cl else .sar_eax_cl);
        const done = try self.patchable(.jmp);
        try self.patchHere(invalid);
        try self.emit(.ud2);
        try self.patchHere(done);
    }

    /// Truncating signed division of eax by a constant without a divide instruction.
    fn divideByMagic(self: *Encoder, magic: division.Int32, negative: bool) !void {
        try self.emit(.movsxd_rax_eax);
        try self.emit(.mov_rsi_rax);
        if (magic.high) {
            try self.immediate(.mov_ecx, @bitCast(magic.multiplier));
            try self.emit(.imul_rax_rcx);
            try self.byteImmediate(.sar_rax, 32);
            try self.emit(.add_rax_rsi);
            try self.byteImmediate(.sar_rax, magic.shift);
        } else {
            try self.immediate(.mov_ecx, @bitCast(magic.multiplier));
            try self.emit(.imul_rax_rcx);
            try self.byteImmediate(.sar_rax, @as(u8, 32) + magic.shift);
        }
        // Flooring a negative dividend rounds away from zero by one.
        try self.byteImmediate(.shr_rsi, 63);
        try self.emit(.add_rax_rsi);
        if (negative) try self.emit(.neg_eax);
    }

    fn divide(self: *Encoder, rhs: ValueLocation) !void {
        if (rhs == .immediate) {
            if (rhs.immediate == -1) return self.emit(.neg_eax);
            if (division.Int32.of(rhs.immediate)) |magic| return self.divideByMagic(magic, rhs.immediate < 0);
            try self.immediate(.mov_ecx, rhs.immediate);
            try self.emit(.cdq);
            return self.emit(.idiv_ecx);
        }
        try self.loadEcx(rhs);
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
