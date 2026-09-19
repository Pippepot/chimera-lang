const std = @import("std");
const structures = @import("structures.zig");

const image_base: u64 = 0x400000;
const linux_exit_syscall: i32 = 60;

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
};

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

fn ensureAddressableStackRange(offset: u32, byte_size: u32) error{FunctionTooLarge}!void {
    if (byte_size == 0) return;
    const last_byte = std.math.add(u32, offset, byte_size - 1) catch return error.FunctionTooLarge;
    if (last_byte > std.math.maxInt(i32)) return error.FunctionTooLarge;
}

fn branchStorageEnd(ssa: *const structures.FunctionBodyAnalysis, types: anytype, branch: structures.FunctionBranch, start: u32) !u32 {
    const target = ssa.blocks[@intFromEnum(branch.target)];
    var end = start;
    for (ssa.block_argument_types[target.argument_start..target.argument_end]) |type_id| {
        const layout = try types.layout(type_id);
        _ = try reserveStack(&end, layout);
    }
    return end;
}

fn callStorageEnd(
    ssa: *const structures.FunctionBodyAnalysis,
    types: anytype,
    value_types: []const structures.TypeId,
    call: anytype,
) !u32 {
    var end: u32 = 0;
    const return_layout = try types.layout(call.return_type);
    if (usesMemoryReturn(return_layout)) _ = try reserveStack(&end, return_layout);
    for (ssa.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
        const type_id = argument.coerce_to orelse value_types[@intFromEnum(argument.value)];
        _ = try reserveStack(&end, try types.layout(type_id));
    }
    return end;
}

const LocationPlan = struct {
    locations: []ValueLocation,
    value_types: []structures.TypeId,
    stack_size: u32,
    edge_scratch_offset: u32,
    return_buffer_offset: ?u32,

    fn markBranchArguments(
        ssa: *const structures.FunctionBodyAnalysis,
        branch: structures.FunctionBranch,
        needed: []bool,
    ) void {
        const arguments = ssa.branch_arguments[branch.arguments.start..branch.arguments.end];
        for (arguments) |argument| needed[@intFromEnum(argument.value)] = true;
    }

    fn init(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator) !LocationPlan {
        const needed = try gpa.alloc(bool, ssa.valueCount());
        defer gpa.free(needed);
        @memset(needed, false);
        const value_types = try gpa.alloc(structures.TypeId, ssa.valueCount());
        errdefer gpa.free(value_types);
        @memcpy(value_types[0..ssa.block_argument_types.len], ssa.block_argument_types);

        for (ssa.instructions, 0..) |instruction, instruction_index| {
            const value_index = @intFromEnum(ssa.instructionValue(instruction_index));
            value_types[value_index] = instruction.resultType();
            switch (instruction) {
                .consti, .constb, .const_unit, .const_none, .function_ref => {},
                .const_type => unreachable,
                .variant_coerce, .variant_extract, .callable_coerce => |operation| needed[@intFromEnum(operation.operand)] = true,
                .struct_init => |operation| {
                    for (ssa.struct_field_values[operation.fields.start..operation.fields.end]) |field| {
                        needed[@intFromEnum(field.value)] = true;
                    }
                },
                .field_access => |operation| needed[@intFromEnum(operation.operand)] = true,
                .field_update => |operation| {
                    needed[@intFromEnum(operation.operand)] = true;
                    needed[@intFromEnum(operation.value)] = true;
                },
                .mut_parameter_write => |operation| needed[@intFromEnum(operation.value)] = true,
                .call_mut_argument => {},
                .call => |call| {
                    for (ssa.call_arguments[call.arguments.start..call.arguments.end]) |argument| needed[@intFromEnum(argument.value)] = true;
                },
                .indirect_call => |call| {
                    needed[@intFromEnum(call.target)] = true;
                    for (ssa.call_arguments[call.arguments.start..call.arguments.end]) |argument| needed[@intFromEnum(argument.value)] = true;
                },
                .variant_tag, .exit, .negi => |operand| needed[@intFromEnum(operand)] = true,
                .addi, .subi, .muli, .divsi => |operands| {
                    needed[@intFromEnum(operands.lhs)] = true;
                    needed[@intFromEnum(operands.rhs)] = true;
                },
            }
        }
        for (ssa.blocks) |block| switch (block.terminator) {
            .branch => |branch| markBranchArguments(ssa, branch, needed),
            .predicate_branch => |predicate| {
                needed[@intFromEnum(predicate.operands.lhs)] = true;
                needed[@intFromEnum(predicate.operands.rhs)] = true;
                markBranchArguments(ssa, predicate.then_branch, needed);
                markBranchArguments(ssa, predicate.else_branch, needed);
            },
            .fallible_call => |fallible| {
                for (ssa.call_arguments[fallible.call.arguments.start..fallible.call.arguments.end]) |argument| {
                    needed[@intFromEnum(argument.value)] = true;
                }
            },
            .fallible_indirect_call => |fallible| {
                needed[@intFromEnum(fallible.call.target)] = true;
                for (ssa.call_arguments[fallible.call.arguments.start..fallible.call.arguments.end]) |argument| {
                    needed[@intFromEnum(argument.value)] = true;
                }
            },
            .return_value => |value| needed[@intFromEnum(value.value)] = true,
            .return_unit, .return_failure, .diverge => {},
        };
        // One reusable area handles every call this function makes. After the
        // prologue, this function's own incoming arguments remain above its
        // frame, past its return address:
        //   rsp + 0..outgoing_size: outgoing return storage and arguments
        //   rsp + outgoing_size..stack_size: local spills
        //   rsp + stack_size: return address
        //   rsp + stack_size + 8: incoming argument 0
        var outgoing_size: u32 = 0;
        for (ssa.instructions) |instruction| switch (instruction) {
            .call => |call| outgoing_size = @max(outgoing_size, try callStorageEnd(ssa, types, value_types, call)),
            .indirect_call => |call| outgoing_size = @max(outgoing_size, try callStorageEnd(ssa, types, value_types, call)),
            else => {},
        };
        for (ssa.blocks) |block| switch (block.terminator) {
            .fallible_call => |fallible| outgoing_size = @max(outgoing_size, try callStorageEnd(ssa, types, value_types, fallible.call)),
            .fallible_indirect_call => |fallible| outgoing_size = @max(outgoing_size, try callStorageEnd(ssa, types, value_types, fallible.call)),
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
        @memset(locations[0..ssa.block_argument_types.len], .discarded);
        var local_end = local_start;
        const entry_index = @intFromEnum(ssa.entry);
        std.debug.assert(entry_index < ssa.blocks.len);
        for (ssa.blocks, 0..) |block, block_index| {
            std.debug.assert(block.argument_start <= block.argument_end);
            std.debug.assert(block.argument_end <= ssa.block_argument_types.len);
            if (block_index == entry_index) continue;
            for (block.argument_start..block.argument_end) |argument_index| {
                if (!needed[argument_index]) continue;
                const layout = try types.layout(value_types[argument_index]);
                if (layout.byte_size == 0) continue;
                locations[argument_index] = .{ .stack = try reserveStack(&local_end, layout) };
            }
        }
        for (ssa.instructions, locations[ssa.block_argument_types.len..], 0..) |instruction, *location, instruction_index| {
            const value_index = @intFromEnum(ssa.instructionValue(instruction_index));
            location.* = location_blk: {
                switch (instruction) {
                    .consti => |value| break :location_blk .{ .immediate = value },
                    .constb => |value| break :location_blk .{ .immediate = @intFromBool(value) },
                    .const_type => unreachable,
                    .const_unit, .const_none => break :location_blk .discarded,
                    .call => |call| if (call.return_type == .unit) {
                        break :location_blk .discarded;
                    },
                    .indirect_call => |call| if (call.return_type == .unit) {
                        break :location_blk .discarded;
                    },
                    .exit => {
                        break :location_blk .discarded;
                    },
                    else => {},
                }
                const layout = try types.layout(value_types[value_index]);
                if (isDirectReturn(ssa, instruction_index) and layout.byte_size == @sizeOf(u32)) {
                    break :location_blk .eax;
                }
                if (needed[value_index]) {
                    if (layout.byte_size == 0) break :location_blk .discarded;
                    break :location_blk .{ .stack = try reserveStack(&local_end, layout) };
                }
                break :location_blk .discarded;
            };
        }
        const stack_size = local_end;
        if (stack_size > std.math.maxInt(i32)) return error.FunctionTooLarge;
        const entry = ssa.blocks[entry_index];
        const return_layout = try types.layout(ssa.return_type);
        var incoming_argument_offset: u32 = 0;
        var return_buffer_offset: ?u32 = null;
        const caller_stack_offset = std.math.add(u32, stack_size, @sizeOf(u64)) catch return error.FunctionTooLarge;
        if (caller_stack_offset > std.math.maxInt(i32)) return error.FunctionTooLarge;
        if (usesMemoryReturn(return_layout)) {
            const offset = try reserveStack(&incoming_argument_offset, return_layout);
            return_buffer_offset = std.math.add(u32, caller_stack_offset, offset) catch return error.FunctionTooLarge;
            try ensureAddressableStackRange(return_buffer_offset.?, return_layout.byte_size);
        }
        for (locations[entry.argument_start..entry.argument_end], 0..) |*location, argument_offset| {
            const argument_index = entry.argument_start + argument_offset;
            const layout = try types.layout(value_types[argument_index]);
            const argument_stack_offset = try reserveStack(&incoming_argument_offset, layout);
            const offset = std.math.add(u32, caller_stack_offset, argument_stack_offset) catch return error.FunctionTooLarge;
            try ensureAddressableStackRange(offset, layout.byte_size);
            if (needed[argument_index] and layout.byte_size != 0) location.* = .{ .incoming_argument = offset };
        }
        return .{
            .locations = locations,
            .value_types = value_types,
            .stack_size = stack_size,
            .edge_scratch_offset = outgoing_size,
            .return_buffer_offset = return_buffer_offset,
        };
    }

    fn deinit(self: *LocationPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locations);
        gpa.free(self.value_types);
        self.* = undefined;
    }
};

fn isDirectReturn(ssa: *const structures.FunctionBodyAnalysis, instruction_index: usize) bool {
    const value = ssa.instructionValue(instruction_index);
    for (ssa.blocks) |block| {
        if (block.instruction_end != instruction_index + 1) continue;
        switch (block.terminator) {
            .return_value => |returned| if (returned.value == value and returned.coerce_to == null) return true,
            else => {},
        }
    }
    return false;
}

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
        // Scratch inverse of referenced_instances; relocations index the slice.
        reference_indices: std.AutoHashMapUnmanaged(structures.InstanceId, u32) = .empty,
        jump_patches: std.ArrayList(JumpPatch) = .empty,
        types: Types,
        locations: []const ValueLocation,
        value_types: []const structures.TypeId,
        variant_coercion_tags: []const u32,
        branch_arguments: []const structures.FunctionValueUse,
        call_arguments: []const structures.FunctionValueUse,
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
            self.referenced_instances.deinit(self.gpa);
            self.reference_indices.deinit(self.gpa);
            self.relocations.deinit(self.gpa);
            self.encoder.deinit();
            self.* = undefined;
        }

        fn emit(self: *Self, ssa: *const structures.FunctionBodyAnalysis) !void {
            if (self.stack_size != 0) try self.encoder.subRspImmediate32(self.stack_size);
            try self.emitBlock(ssa, ssa.entry);
            for (ssa.blocks, 0..) |_, block_index| {
                if (block_index == @intFromEnum(ssa.entry)) continue;
                try self.emitBlock(ssa, @enumFromInt(block_index));
            }
            for (self.jump_patches.items) |patch| {
                const target_offset = self.block_offsets[@intFromEnum(patch.target)];
                std.debug.assert(target_offset != std.math.maxInt(u32));
                try self.patchJump(patch.field_offset, target_offset);
            }
        }

        fn emitBlock(self: *Self, ssa: *const structures.FunctionBodyAnalysis, block_id: structures.FunctionBlockId) !void {
            const block_index = @intFromEnum(block_id);
            const block = ssa.blocks[block_index];
            self.block_offsets[block_index] = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            std.debug.assert(block.instruction_start <= block.instruction_end);
            std.debug.assert(block.instruction_end <= ssa.instructions.len);
            for (block.instruction_start..block.instruction_end) |instruction_index| {
                const instruction = ssa.instructions[instruction_index];
                const destination = self.locations[@intFromEnum(ssa.instructionValue(instruction_index))];
                switch (instruction) {
                    .consti, .constb, .const_unit, .const_none => {},
                    .const_type => unreachable,
                    .function_ref => |reference| try self.emitFunctionReference(reference, destination),
                    .variant_tag => |operand| {
                        try self.loadComponent(self.locations[@intFromEnum(operand)], 0);
                        try self.storeResult(destination);
                    },
                    .variant_coerce => |coercion| try self.emitCoercion(.{
                        .value = coercion.operand,
                        .coerce_to = coercion.target_type,
                        .variant_tag_mapping = coercion.tag_mapping.?,
                    }, destination),
                    .variant_extract => |extraction| if (destination != .discarded) {
                        const source_type = self.valueType(extraction.operand);
                        const mapping = if (extraction.tag_mapping) |range| blk: {
                            std.debug.assert(range.start <= range.end and range.end <= self.variant_coercion_tags.len);
                            break :blk self.variant_coercion_tags[range.start..range.end];
                        } else &.{};
                        try self.convertVariant(source_type, extraction.target_type, mapping, self.locations[@intFromEnum(extraction.operand)], destination);
                    },
                    .callable_coerce => |coercion| try self.copyValue(coercion.target_type, self.locations[@intFromEnum(coercion.operand)], destination),
                    .struct_init => |operation| try self.emitStructInit(ssa, operation, destination),
                    .field_access => |operation| try self.emitFieldAccess(operation, destination),
                    .field_update => |operation| try self.emitFieldUpdate(operation, destination),
                    .mut_parameter_write => |operation| try self.emitMutParameterWrite(ssa, operation),
                    .call_mut_argument => |operation| try self.emitCallMutArgument(operation, destination),
                    .call => |call| try self.emitDirectCall(call, destination),
                    .indirect_call => |call| try self.emitIndirectCall(call, destination),
                    .exit => |operand| try self.emitExit(operand),
                    .negi => |operand| {
                        try self.loadValue(self.locations[@intFromEnum(operand)]);
                        try self.encoder.negateEax();
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
                .fallible_indirect_call => |fallible| try self.emitFallibleIndirectCall(ssa, fallible),
                .return_unit => try self.emitReturn(null, .unit),
                .return_value => |value| try self.emitReturn(value, ssa.return_type),
                .return_failure => try self.emitFailureReturn(),
                .diverge => {},
            }
        }

        fn emitFallibleCall(
            self: *Self,
            ssa: *const structures.FunctionBodyAnalysis,
            fallible: @FieldType(structures.FunctionTerminator, "fallible_call"),
        ) !void {
            const success = ssa.blocks[@intFromEnum(fallible.success)];
            std.debug.assert(success.argument_end - success.argument_start == 1);
            try self.emitDirectCall(fallible.call, self.locations[success.argument_start]);
            try self.encoder.compareEdxZero();
            const success_field = try self.encoder.conditionalJumpRelative32(.nei, 0);
            try self.emitJump(fallible.failure);
            const success_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            try self.patchJump(success_field, success_offset);
            try self.emitJump(fallible.success);
        }

        fn emitFallibleIndirectCall(
            self: *Self,
            ssa: *const structures.FunctionBodyAnalysis,
            fallible: @FieldType(structures.FunctionTerminator, "fallible_indirect_call"),
        ) !void {
            const success = ssa.blocks[@intFromEnum(fallible.success)];
            std.debug.assert(success.argument_end - success.argument_start == 1);
            try self.emitIndirectCall(fallible.call, self.locations[success.argument_start]);
            try self.encoder.compareEdxZero();
            const success_field = try self.encoder.conditionalJumpRelative32(.nei, 0);
            try self.emitJump(fallible.failure);
            const success_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            try self.patchJump(success_field, success_offset);
            try self.emitJump(fallible.success);
        }

        fn emitPredicateBranch(
            self: *Self,
            ssa: *const structures.FunctionBodyAnalysis,
            predicate: @FieldType(structures.FunctionTerminator, "predicate_branch"),
        ) !void {
            try self.loadValue(self.locations[@intFromEnum(predicate.operands.lhs)]);
            try self.encoder.compareEax(self.locations[@intFromEnum(predicate.operands.rhs)]);
            const then_field = try self.encoder.conditionalJumpRelative32(predicate.operation, 0);
            try self.emitBranchCopies(ssa, predicate.else_branch);
            try self.emitJump(predicate.else_branch.target);
            const then_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            try self.patchJump(then_field, then_offset);
            try self.emitBranchCopies(ssa, predicate.then_branch);
            try self.emitJump(predicate.then_branch.target);
        }

        fn emitBranchCopies(self: *Self, ssa: *const structures.FunctionBodyAnalysis, branch: structures.FunctionBranch) !void {
            const target = ssa.blocks[@intFromEnum(branch.target)];
            const arguments = self.branch_arguments[branch.arguments.start..branch.arguments.end];
            std.debug.assert(arguments.len == target.argument_end - target.argument_start);
            if (arguments.len == 1) {
                const type_id = ssa.block_argument_types[target.argument_start];
                const destination = self.locations[target.argument_start];
                if (destination != .discarded) try self.emitUse(arguments[0], type_id, destination);
                return;
            }
            var scratch_end = self.edge_scratch_offset;
            for (arguments, 0..) |argument, argument_offset| {
                const type_id = ssa.block_argument_types[target.argument_start + argument_offset];
                const layout = try self.types.layout(type_id);
                const scratch_offset = try reserveStack(&scratch_end, layout);
                const destination = self.locations[target.argument_start + argument_offset];
                if (destination != .discarded) try self.emitUseToMemory(argument, scratch_offset);
            }
            scratch_end = self.edge_scratch_offset;
            for (arguments, 0..) |_, argument_offset| {
                const type_id = ssa.block_argument_types[target.argument_start + argument_offset];
                const layout = try self.types.layout(type_id);
                const scratch_offset = try reserveStack(&scratch_end, layout);
                const destination = self.locations[target.argument_start + argument_offset];
                if (destination != .discarded) try self.copyValue(type_id, .{ .stack = scratch_offset }, destination);
            }
        }

        fn emitJump(self: *Self, target: structures.FunctionBlockId) !void {
            const field_offset = try self.encoder.jumpRelative32(0);
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
                const destination: ValueLocation = if (usesMemoryReturn(layout))
                    .{ .return_buffer = self.return_buffer_offset orelse unreachable }
                else
                    .eax;
                try self.emitUse(returned, return_type, destination);
            }
            try self.encoder.movEdxImmediate32(1);
            if (self.stack_size != 0) try self.encoder.addRspImmediate32(self.stack_size);
            try self.encoder.ret();
        }

        fn emitFailureReturn(self: *Self) !void {
            std.debug.assert(self.is_fallible);
            try self.encoder.movEdxImmediate32(0);
            if (self.stack_size != 0) try self.encoder.addRspImmediate32(self.stack_size);
            try self.encoder.ret();
        }

        fn emitDirectCall(
            self: *Self,
            call: structures.FunctionCall,
            destination: ValueLocation,
        ) !void {
            var argument_end: u32 = 0;
            const return_layout = try self.types.layout(call.return_type);
            if (usesMemoryReturn(return_layout)) {
                const return_offset = try reserveStack(&argument_end, return_layout);
                std.debug.assert(return_offset == 0);
            }
            for (self.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
                const type_id = argument.coerce_to orelse self.valueType(argument.value);
                const layout = try self.types.layout(type_id);
                const argument_offset = try reserveStack(&argument_end, layout);
                try self.emitUseToMemory(argument, argument_offset);
            }
            const offset_usize = std.math.add(usize, self.encoder.code.items.len, 1) catch return error.FunctionTooLarge;
            const offset = std.math.cast(u32, offset_usize) orelse return error.FunctionTooLarge;
            try self.encoder.callRelative32(0);

            const reference = try self.referenceIndex(call.instance());
            try self.relocations.append(self.gpa, .{
                .offset = offset,
                .kind = .call_relative_32,
                .reference = @enumFromInt(reference),
                .addend = 0,
            });

            if (usesMemoryReturn(return_layout)) {
                try self.copyValue(call.return_type, .{ .stack = 0 }, destination);
            } else {
                try self.storeResult(destination);
            }
        }

        fn emitIndirectCall(self: *Self, call: structures.IndirectFunctionCall, destination: ValueLocation) !void {
            try self.emitCallArguments(call);
            try self.loadAddress(self.locations[@intFromEnum(call.target)]);
            try self.encoder.callRax();
            const return_layout = try self.types.layout(call.return_type);
            if (usesMemoryReturn(return_layout)) {
                try self.copyValue(call.return_type, .{ .stack = 0 }, destination);
            } else {
                try self.storeResult(destination);
            }
        }

        fn emitCallArguments(self: *Self, call: anytype) !void {
            var argument_end: u32 = 0;
            const return_layout = try self.types.layout(call.return_type);
            if (usesMemoryReturn(return_layout)) {
                const return_offset = try reserveStack(&argument_end, return_layout);
                std.debug.assert(return_offset == 0);
            }
            for (self.call_arguments[call.arguments.start..call.arguments.end]) |argument| {
                const type_id = argument.coerce_to orelse self.valueType(argument.value);
                const layout = try self.types.layout(type_id);
                const argument_offset = try reserveStack(&argument_end, layout);
                try self.emitUseToMemory(argument, argument_offset);
            }
        }

        fn emitFunctionReference(self: *Self, reference: structures.FunctionReference, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const offset_usize = std.math.add(usize, self.encoder.code.items.len, 2) catch return error.FunctionTooLarge;
            const offset = std.math.cast(u32, offset_usize) orelse return error.FunctionTooLarge;
            try self.encoder.movRaxImmediate64(0);
            try self.storeAddress(destination);
            try self.appendRelocation(reference.target, offset, .address_absolute_64);
        }

        fn appendRelocation(self: *Self, target: structures.ItemId, offset: u32, kind: structures.CompiledFunction.RelocationKind) !void {
            const reference = try self.referenceIndex(.{ .item = target });
            try self.relocations.append(self.gpa, .{
                .offset = offset,
                .kind = kind,
                .reference = @enumFromInt(reference),
                .addend = 0,
            });
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
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.movRaxFromRsp(offset),
                .discarded, .immediate, .eax => unreachable,
            }
        }

        fn storeAddress(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .return_buffer => |offset| try self.encoder.movRspFromRax(offset),
                .discarded => {},
                .immediate, .eax, .incoming_argument => unreachable,
            }
        }

        fn emitExit(self: *Self, operand: structures.FunctionValueId) !void {
            try self.loadValue(self.locations[@intFromEnum(operand)]);
            try self.encoder.movEdiFromEax();
            try self.encoder.movEaxImmediate32(linux_exit_syscall);
            try self.encoder.syscall();
        }

        fn emitIntegerBinary(
            self: *Self,
            operation: IntegerBinaryOperation,
            operands: structures.BinaryOperands,
            destination: ValueLocation,
        ) !void {
            try self.loadValue(self.locations[@intFromEnum(operands.lhs)]);
            try self.encoder.integerBinary(operation, self.locations[@intFromEnum(operands.rhs)]);
            try self.storeResult(destination);
        }

        fn valueType(self: *const Self, value: structures.FunctionValueId) structures.TypeId {
            return self.value_types[@intFromEnum(value)];
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
                return self.copyValue(target_type, self.locations[@intFromEnum(use.value)], destination);
            }
            std.debug.assert(use.coerce_to.? == target_type);
            if (try self.types.callable(target_type) != null) {
                std.debug.assert(use.variant_tag_mapping == null);
                return self.copyValue(target_type, self.locations[@intFromEnum(use.value)], destination);
            }
            const mapping = use.variant_tag_mapping.?;
            std.debug.assert(mapping.start <= mapping.end and mapping.end <= self.variant_coercion_tags.len);
            try self.convertVariant(
                actual_type,
                target_type,
                self.variant_coercion_tags[mapping.start..mapping.end],
                self.locations[@intFromEnum(use.value)],
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
            const actual_members = try self.types.variantMembers(actual_type);
            if (actual_members == null) {
                _ = (try self.types.variantMembers(target_type)) orelse unreachable;
                std.debug.assert(tag_mapping.len == 1);
                const target_payload_offset = (try self.types.variantLayout(target_type)).payload_offset;
                const actual_layout = try self.types.layout(actual_type);
                try self.copyRange(source, 0, destination, target_payload_offset, actual_layout.byte_size);
                try self.encoder.movEaxImmediate32(std.math.cast(i32, tag_mapping[0]) orelse return error.FunctionTooLarge);
                try self.storeComponent(destination, 0);
                return;
            }

            _ = try self.types.variantMembers(target_type) orelse {
                std.debug.assert(tag_mapping.len == 0);
                const target_layout = try self.types.layout(target_type);
                const actual_payload_offset = (try self.types.variantLayout(actual_type)).payload_offset;
                return self.copyRange(source, actual_payload_offset, destination, 0, target_layout.byte_size);
            };
            std.debug.assert(tag_mapping.len == actual_members.?.len);

            const actual_layout = try self.types.layout(actual_type);
            const actual_payload_offset = (try self.types.variantLayout(actual_type)).payload_offset;
            const actual_payload_size = actual_layout.byte_size - actual_payload_offset;
            const target_layout = try self.types.variantLayout(target_type);
            const target_payload_size = target_layout.layout.byte_size - target_layout.payload_offset;
            try self.copyRange(source, actual_payload_offset, destination, target_layout.payload_offset, @min(actual_payload_size, target_payload_size));
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
                    try self.encoder.movEaxImmediate32(std.math.cast(i32, target_tag) orelse return error.FunctionTooLarge);
                    break;
                }
                try self.encoder.compareEax(.{ .immediate = @intCast(source_tag) });
                const next = try self.encoder.conditionalJumpRelative32(.nei, 0);
                try self.encoder.movEaxImmediate32(std.math.cast(i32, target_tag) orelse return error.FunctionTooLarge);
                try done_jumps.append(self.gpa, try self.encoder.jumpRelative32(0));
                const next_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
                try self.patchJump(next, next_offset);
            }
            const done_offset = std.math.cast(u32, self.encoder.code.items.len) orelse return error.FunctionTooLarge;
            for (done_jumps.items) |jump| try self.patchJump(jump, done_offset);
        }

        fn copyValue(self: *Self, type_id: structures.TypeId, source: ValueLocation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const layout = try self.types.layout(type_id);
            try self.copyRange(source, 0, destination, 0, layout.byte_size);
        }

        fn emitStructInit(
            self: *Self,
            ssa: *const structures.FunctionBodyAnalysis,
            operation: structures.StructOperation,
            destination: ValueLocation,
        ) !void {
            if (destination == .discarded) return;
            const layout = (try self.types.structLayout(operation.type_id)) orelse return error.Unavailable;
            for (ssa.struct_field_values[operation.fields.start..operation.fields.end]) |field| {
                std.debug.assert(field.field_index < layout.field_offsets.len);
                const source_type = self.valueType(field.value);
                const field_layout = try self.types.layout(source_type);
                try self.copyRange(
                    self.locations[@intFromEnum(field.value)],
                    0,
                    destination,
                    layout.field_offsets[field.field_index],
                    field_layout.byte_size,
                );
            }
        }

        fn emitFieldAccess(self: *Self, operation: structures.FieldAccessOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const source_type = self.valueType(operation.operand);
            const layout = (try self.types.structLayout(source_type)) orelse return error.Unavailable;
            std.debug.assert(operation.field_index < layout.field_offsets.len);
            const field_layout = try self.types.layout(operation.field_type);
            try self.copyRange(
                self.locations[@intFromEnum(operation.operand)],
                layout.field_offsets[operation.field_index],
                destination,
                0,
                field_layout.byte_size,
            );
        }

        fn emitFieldUpdate(self: *Self, operation: structures.FieldUpdateOperation, destination: ValueLocation) !void {
            if (destination == .discarded) return;
            const layout = (try self.types.structLayout(operation.type_id)) orelse return error.Unavailable;
            std.debug.assert(operation.field_index < layout.field_offsets.len);
            try self.copyValue(operation.type_id, self.locations[@intFromEnum(operation.operand)], destination);
            const field_type = self.valueType(operation.value);
            const field_layout = try self.types.layout(field_type);
            try self.copyRange(
                self.locations[@intFromEnum(operation.value)],
                0,
                destination,
                layout.field_offsets[operation.field_index],
                field_layout.byte_size,
            );
        }

        fn emitMutParameterWrite(self: *Self, ssa: *const structures.FunctionBodyAnalysis, operation: structures.MutParameterWrite) !void {
            const entry = ssa.blocks[@intFromEnum(ssa.entry)];
            std.debug.assert(operation.parameter_index < entry.argument_end - entry.argument_start);
            var incoming_offset: u32 = 0;
            const return_layout = try self.types.layout(ssa.return_type);
            if (usesMemoryReturn(return_layout)) _ = try reserveStack(&incoming_offset, return_layout);
            for (ssa.block_argument_types[entry.argument_start .. entry.argument_start + operation.parameter_index]) |type_id| {
                _ = try reserveStack(&incoming_offset, try self.types.layout(type_id));
            }
            const parameter_offset = try reserveStack(&incoming_offset, try self.types.layout(operation.type_id));
            const caller_stack_offset = std.math.add(u32, self.stack_size, @sizeOf(u64)) catch return error.FunctionTooLarge;
            const destination_offset = std.math.add(u32, caller_stack_offset, parameter_offset) catch return error.FunctionTooLarge;
            try self.copyValue(operation.type_id, self.locations[@intFromEnum(operation.value)], .{ .incoming_argument = destination_offset });
        }

        fn emitCallMutArgument(self: *Self, operation: structures.CallMutArgument, destination: ValueLocation) !void {
            var argument_offset: u32 = 0;
            const return_layout = try self.types.layout(operation.return_type);
            if (usesMemoryReturn(return_layout)) _ = try reserveStack(&argument_offset, return_layout);
            const arguments = self.call_arguments[operation.arguments.start..operation.arguments.end];
            std.debug.assert(operation.argument_index < arguments.len);
            for (arguments[0..operation.argument_index]) |argument| {
                const type_id = argument.coerce_to orelse self.valueType(argument.value);
                _ = try reserveStack(&argument_offset, try self.types.layout(type_id));
            }
            const source_offset = try reserveStack(&argument_offset, try self.types.layout(operation.type_id));
            try self.copyValue(operation.type_id, .{ .stack = source_offset }, destination);
        }

        fn copyRange(self: *Self, source: ValueLocation, source_start: u32, destination: ValueLocation, destination_start: u32, byte_size: u32) !void {
            var offset: u32 = 0;
            while (byte_size - offset >= @sizeOf(u32)) : (offset += @sizeOf(u32)) {
                try self.loadComponent(source, source_start + offset);
                try self.storeComponent(destination, destination_start + offset);
            }
            while (offset < byte_size) : (offset += 1) {
                try self.loadByte(source, source_start + offset);
                try self.storeByte(destination, destination_start + offset);
            }
        }

        fn loadComponent(self: *Self, location: ValueLocation, component_offset: u32) !void {
            switch (location) {
                .immediate => |value| {
                    std.debug.assert(component_offset == 0);
                    try self.encoder.movEaxImmediate32(value);
                },
                .eax => std.debug.assert(component_offset == 0),
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.movEaxFromRsp(std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .discarded => unreachable,
            }
        }

        fn storeComponent(self: *Self, location: ValueLocation, component_offset: u32) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.movRspFromEax(std.math.add(u32, offset, component_offset) catch return error.FunctionTooLarge),
                .eax => std.debug.assert(component_offset == 0),
                .discarded => {},
                .immediate => unreachable,
            }
        }

        fn loadByte(self: *Self, location: ValueLocation, byte_offset: u32) !void {
            switch (location) {
                .immediate => |value| {
                    std.debug.assert(byte_offset < @sizeOf(i32));
                    const bits: u32 = @bitCast(value);
                    try self.encoder.movEaxImmediate32(@intCast((bits >> @intCast(byte_offset * 8)) & 0xff));
                },
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.movzxEaxByteFromRsp(std.math.add(u32, offset, byte_offset) catch return error.FunctionTooLarge),
                .eax => std.debug.assert(byte_offset == 0),
                .discarded => unreachable,
            }
        }

        fn storeByte(self: *Self, location: ValueLocation, byte_offset: u32) !void {
            switch (location) {
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.movRspByteFromAl(std.math.add(u32, offset, byte_offset) catch return error.FunctionTooLarge),
                .eax => std.debug.assert(byte_offset == 0),
                .discarded => {},
                .immediate => unreachable,
            }
        }

        fn loadValue(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .immediate => |value| try self.encoder.movEaxImmediate32(value),
                .eax => {},
                .stack, .incoming_argument, .return_buffer => |offset| try self.encoder.movEaxFromRsp(offset),
                .discarded => unreachable,
            }
        }

        fn storeResult(self: *Self, location: ValueLocation) !void {
            switch (location) {
                .stack, .return_buffer => |offset| try self.encoder.movRspFromEax(offset),
                .eax, .discarded => {},
                .immediate, .incoming_argument => unreachable,
            }
        }

        fn finish(self: *Self) !structures.CompiledFunction {
            const relocations = try self.relocations.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(relocations);
            const references = try self.referenced_instances.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(references);
            return .{
                .code = try self.encoder.code.toOwnedSlice(self.gpa),
                .required_alignment = 1,
                .relocations = relocations,
                .referenced_instances = references,
            };
        }
    };
}

pub fn compileFunction(ssa: *const structures.FunctionBodyAnalysis, types: anytype, gpa: std.mem.Allocator) !structures.CompiledFunction {
    std.debug.assert(ssa.blocks.len != 0);
    std.debug.assert(@intFromEnum(ssa.entry) < ssa.blocks.len);
    var plan = try LocationPlan.init(ssa, types, gpa);
    defer plan.deinit(gpa);
    const Emitter = FunctionEmitter(@TypeOf(types));
    var emitter = try Emitter.init(gpa, ssa, plan, types);
    defer emitter.deinit();
    try emitter.emit(ssa);
    return emitter.finish();
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
            const reference_index = @intFromEnum(relocation.reference);
            if (reference_index >= function.artifact.referenced_instances.len) return error.RelocationOutOfBounds;
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

    const call_displacement_offset = encoder.code.items.len + 1;
    try encoder.callRelative32(0);
    try encoder.zeroEdi();
    try encoder.movEaxImmediate32(linux_exit_syscall);
    try encoder.syscall();

    const Layout = struct { address: u64, offset: usize };
    const layouts = try gpa.alloc(Layout, functions.len);
    defer gpa.free(layouts);

    const code_virtual_address = image_base + @as(u64, code_file_offset);
    for (functions, layouts) |function, *layout| {
        const function_address = try alignedAddress(code_virtual_address, encoder.code.items.len, function.artifact.required_alignment);
        const function_offset = try offsetFromBase(function_address, code_virtual_address);
        if (function.artifact.code.len > std.math.maxInt(usize) - function_offset) return error.FileTooBig;
        try encoder.code.appendNTimes(gpa, 0x90, function_offset - encoder.code.items.len);
        try encoder.appendBytes(function.artifact.code);
        layout.* = .{ .address = function_address, .offset = function_offset };
    }

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
            const target = function.artifact.referenced_instances[@intFromEnum(relocation.reference)];
            const target_layout = layouts[function_indices.get(target).?];
            const field_offset = layout.offset + @as(usize, relocation.offset);
            switch (relocation.kind) {
                .call_relative_32 => try patchRelativeDisplacement(
                    encoder.code.items,
                    field_offset,
                    target_layout.address,
                    layout.address + @as(u64, relocation.offset) + @sizeOf(i32),
                    relocation.addend,
                ),
                .address_absolute_64 => try patchAbsoluteAddress(
                    encoder.code.items,
                    field_offset,
                    target_layout.address,
                    relocation.addend,
                ),
            }
        }
    }

    return .{ .bytes = try buildElfExecutable(encoder.code.items, gpa) };
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

    fn appendBytes(self: *@This(), bytes: []const u8) !void {
        try self.code.appendSlice(self.gpa, bytes);
    }

    fn appendBits32(self: *@This(), prefix: []const u8, bits: u32) !void {
        try self.appendBytes(prefix);
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, bits, .little);
        try self.appendBytes(&encoded);
    }

    fn appendBits64(self: *@This(), prefix: []const u8, bits: u64) !void {
        try self.appendBytes(prefix);
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, bits, .little);
        try self.appendBytes(&encoded);
    }

    fn callRelative32(self: *@This(), displacement: i32) !void {
        try self.appendBits32(&.{0xE8}, @bitCast(displacement));
    }

    fn callRax(self: *@This()) !void {
        try self.appendBytes(&.{ 0xFF, 0xD0 });
    }

    fn jumpRelative32(self: *@This(), displacement: i32) !u32 {
        const field_offset = std.math.cast(u32, self.code.items.len + 1) orelse return error.FunctionTooLarge;
        try self.appendBits32(&.{0xE9}, @bitCast(displacement));
        return field_offset;
    }

    fn conditionalJumpRelative32(self: *@This(), operation: structures.PredicateOperation, displacement: i32) !u32 {
        const opcode: u8 = switch (operation) {
            .lti => 0x8C,
            .gti => 0x8F,
            .lei => 0x8E,
            .gei => 0x8D,
            .eqi, .eqb => 0x84,
            .nei, .neb => 0x85,
            .eqt, .net => unreachable,
        };
        const field_offset = std.math.cast(u32, self.code.items.len + 2) orelse return error.FunctionTooLarge;
        try self.appendBits32(&.{ 0x0F, opcode }, @bitCast(displacement));
        return field_offset;
    }

    fn subRspImmediate32(self: *@This(), value: u32) !void {
        try self.appendBits32(&.{ 0x48, 0x81, 0xEC }, value);
    }

    fn addRspImmediate32(self: *@This(), value: u32) !void {
        try self.appendBits32(&.{ 0x48, 0x81, 0xC4 }, value);
    }

    fn zeroEdi(self: *@This()) !void {
        try self.appendBytes(&.{ 0x31, 0xFF });
    }

    fn movEaxImmediate32(self: *@This(), value: i32) !void {
        try self.appendBits32(&.{0xB8}, @bitCast(value));
    }

    fn movRaxImmediate64(self: *@This(), value: u64) !void {
        try self.appendBits64(&.{ 0x48, 0xB8 }, value);
    }

    fn movEdxImmediate32(self: *@This(), value: i32) !void {
        try self.appendBits32(&.{0xBA}, @bitCast(value));
    }

    fn movEdiFromEax(self: *@This()) !void {
        try self.appendBytes(&.{ 0x89, 0xC7 });
    }

    fn movEcxImmediate32(self: *@This(), value: i32) !void {
        try self.appendBits32(&.{0xB9}, @bitCast(value));
    }

    fn movEaxFromRsp(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x8B, 0x84, 0x24 }, offset);
    }

    fn movRaxFromRsp(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x48, 0x8B, 0x84, 0x24 }, offset);
    }

    fn movRspFromEax(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x89, 0x84, 0x24 }, offset);
    }

    fn movRspFromRax(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x48, 0x89, 0x84, 0x24 }, offset);
    }

    fn movzxEaxByteFromRsp(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x0F, 0xB6, 0x84, 0x24 }, offset);
    }

    fn movRspByteFromAl(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x88, 0x84, 0x24 }, offset);
    }

    fn negateEax(self: *@This()) !void {
        try self.appendBytes(&.{ 0xF7, 0xD8 });
    }

    fn compareEax(self: *@This(), rhs: ValueLocation) !void {
        switch (rhs) {
            .immediate => |value| try self.appendBits32(&.{0x3D}, @bitCast(value)),
            .stack, .incoming_argument => |offset| try self.appendBits32(&.{ 0x3B, 0x84, 0x24 }, offset),
            .eax, .return_buffer, .discarded => unreachable,
        }
    }

    fn compareEdxZero(self: *@This()) !void {
        try self.appendBytes(&.{ 0x85, 0xD2 });
    }

    fn integerBinary(self: *@This(), operation: IntegerBinaryOperation, rhs: ValueLocation) !void {
        if (operation == .divide_signed) {
            switch (rhs) {
                .immediate => |value| {
                    try self.movEcxImmediate32(value);
                    try self.appendBytes(&.{ 0x99, 0xF7, 0xF9 });
                },
                .stack, .incoming_argument => |offset| {
                    try self.appendBytes(&.{0x99});
                    try self.appendBits32(&.{ 0xF7, 0xBC, 0x24 }, offset);
                },
                .eax, .return_buffer, .discarded => unreachable,
            }
            return;
        }

        const encoding: struct { immediate: []const u8, stack: []const u8 } = switch (operation) {
            .add => .{ .immediate = &.{0x05}, .stack = &.{ 0x03, 0x84, 0x24 } },
            .subtract => .{ .immediate = &.{0x2D}, .stack = &.{ 0x2B, 0x84, 0x24 } },
            .multiply => .{ .immediate = &.{ 0x69, 0xC0 }, .stack = &.{ 0x0F, 0xAF, 0x84, 0x24 } },
            .divide_signed => unreachable,
        };
        switch (rhs) {
            .immediate => |value| try self.appendBits32(encoding.immediate, @bitCast(value)),
            .stack, .incoming_argument => |offset| try self.appendBits32(encoding.stack, offset),
            .eax, .return_buffer, .discarded => unreachable,
        }
    }

    fn ret(self: *@This()) !void {
        try self.appendBytes(&.{0xC3});
    }

    fn syscall(self: *@This()) !void {
        try self.appendBytes(&.{ 0x0F, 0x05 });
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
