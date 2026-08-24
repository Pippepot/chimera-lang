const std = @import("std");
const structures = @import("structures.zig");

const image_base: u64 = 0x400000;

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
};

const LocationPlan = struct {
    locations: []ValueLocation,
    stack_size: u32,
    returned_value: ?usize,

    fn init(
        ssa: *const structures.SsaFunction,
        block: structures.SsaFunction.Block,
        gpa: std.mem.Allocator,
    ) error{ OutOfMemory, FunctionTooLarge }!LocationPlan {
        for (ssa.block_argument_types) |argument_type| std.debug.assert(argument_type == .int);
        const needed = try gpa.alloc(bool, ssa.valueCount());
        defer gpa.free(needed);
        @memset(needed, false);

        var maximum_argument_count: usize = 0;
        for (ssa.instructions) |instruction| {
            switch (instruction) {
                .consti => {},
                .call => |call| {
                    const arguments = ssa.call_arguments[call.arguments.start..call.arguments.end];
                    maximum_argument_count = @max(maximum_argument_count, arguments.len);
                    for (arguments) |argument| needed[@intFromEnum(argument)] = true;
                },
                .negi => |operand_id| {
                    const operand = @intFromEnum(operand_id);
                    needed[operand] = true;
                },
                .addi, .subi, .muli, .divsi => |operands| {
                    const lhs = @intFromEnum(operands.lhs);
                    const rhs = @intFromEnum(operands.rhs);
                    needed[lhs] = true;
                    needed[rhs] = true;
                },
            }
        }
        const returned_value: ?usize = switch (block.terminator) {
            .return_unit => null,
            .return_value => |value| blk: {
                const index = @intFromEnum(value);
                needed[index] = true;
                break :blk index;
            },
        };

        // One reusable area handles every call this function makes. After the
        // prologue, this function's own incoming arguments remain above its
        // frame, past its return address:
        //   rsp + 0..outgoing_size: outgoing arguments
        //   rsp + outgoing_size..stack_size: local spills
        //   rsp + stack_size: return address
        //   rsp + stack_size + 8: incoming argument 0
        const outgoing_size_usize = std.math.mul(usize, maximum_argument_count, @sizeOf(i32)) catch return error.FunctionTooLarge;
        const outgoing_size = std.math.cast(u32, outgoing_size_usize) orelse return error.FunctionTooLarge;
        const locations = try gpa.alloc(ValueLocation, ssa.valueCount());
        errdefer gpa.free(locations);
        @memset(locations[0..ssa.block_argument_types.len], .discarded);
        var stack_slot_count: u32 = 0;
        for (ssa.instructions, locations[ssa.block_argument_types.len..], 0..) |instruction, *location, instruction_index| {
            const value_index = @intFromEnum(ssa.instructionValue(instruction_index));
            location.* = location_blk: {
                switch (instruction) {
                    .consti => |value| break :location_blk .{ .immediate = value },
                    .call => |call| if (call.return_type == .unit) {
                        std.debug.assert(!needed[value_index]);
                        break :location_blk .discarded;
                    },
                    else => {},
                }
                if (returned_value == value_index and instruction_index + 1 == ssa.instructions.len) {
                    break :location_blk .eax;
                }
                if (needed[value_index]) {
                    const slot_offset = std.math.mul(u32, stack_slot_count, @sizeOf(i32)) catch return error.FunctionTooLarge;
                    stack_slot_count = std.math.add(u32, stack_slot_count, 1) catch return error.FunctionTooLarge;
                    const offset = std.math.add(u32, outgoing_size, slot_offset) catch return error.FunctionTooLarge;
                    break :location_blk .{ .stack = offset };
                }
                break :location_blk .discarded;
            };
        }
        const local_size = std.math.mul(u32, stack_slot_count, @sizeOf(i32)) catch return error.FunctionTooLarge;
        const stack_size = std.math.add(u32, outgoing_size, local_size) catch return error.FunctionTooLarge;
        if (stack_size > std.math.maxInt(i32)) return error.FunctionTooLarge;
        for (locations[0..ssa.block_argument_types.len], 0..) |*location, argument_index| {
            if (!needed[argument_index]) continue;
            const argument_offset_usize = std.math.mul(usize, argument_index, @sizeOf(i32)) catch return error.FunctionTooLarge;
            const argument_offset = std.math.cast(u32, argument_offset_usize) orelse return error.FunctionTooLarge;
            const caller_stack_offset = std.math.add(u32, stack_size, @sizeOf(u64)) catch return error.FunctionTooLarge;
            const offset = std.math.add(u32, caller_stack_offset, argument_offset) catch return error.FunctionTooLarge;
            if (offset > std.math.maxInt(i32)) return error.FunctionTooLarge;
            location.* = .{ .incoming_argument = offset };
        }
        return .{ .locations = locations, .stack_size = stack_size, .returned_value = returned_value };
    }

    fn deinit(self: *LocationPlan, gpa: std.mem.Allocator) void {
        gpa.free(self.locations);
        self.* = undefined;
    }
};

const IntegerBinaryOperation = enum {
    add,
    subtract,
    multiply,
    divide_signed,
};

const FunctionEmitter = struct {
    gpa: std.mem.Allocator,
    encoder: X86Encoder,
    relocations: std.ArrayList(structures.CompiledFunction.Relocation) = .empty,
    referenced_instances: std.ArrayList(structures.InstanceId) = .empty,
    locations: []const ValueLocation,
    call_arguments: []const structures.FunctionValueId,

    fn init(
        gpa: std.mem.Allocator,
        locations: []const ValueLocation,
        call_arguments: []const structures.FunctionValueId,
    ) !FunctionEmitter {
        return .{
            .gpa = gpa,
            .encoder = try X86Encoder.init(gpa),
            .locations = locations,
            .call_arguments = call_arguments,
        };
    }

    fn deinit(self: *FunctionEmitter) void {
        self.referenced_instances.deinit(self.gpa);
        self.relocations.deinit(self.gpa);
        self.encoder.deinit();
        self.* = undefined;
    }

    fn emit(self: *FunctionEmitter, ssa: *const structures.SsaFunction, plan: LocationPlan) !void {
        if (plan.stack_size != 0) try self.encoder.subRspImmediate32(plan.stack_size);
        for (ssa.instructions, plan.locations[ssa.block_argument_types.len..]) |instruction, destination| {
            switch (instruction) {
                .consti => {},
                .call => |call| try self.emitDirectCall(call, destination),
                .negi => |operand| {
                    try self.loadValue(plan.locations[@intFromEnum(operand)]);
                    try self.encoder.negateEax();
                    try self.storeResult(destination);
                },
                .addi => |operands| try self.emitIntegerBinary(.add, operands, destination),
                .subi => |operands| try self.emitIntegerBinary(.subtract, operands, destination),
                .muli => |operands| try self.emitIntegerBinary(.multiply, operands, destination),
                .divsi => |operands| try self.emitIntegerBinary(.divide_signed, operands, destination),
            }
        }
        if (plan.returned_value) |value| try self.loadValue(plan.locations[value]);
        if (plan.stack_size != 0) try self.encoder.addRspImmediate32(plan.stack_size);
        try self.encoder.ret();
    }

    fn emitDirectCall(
        self: *FunctionEmitter,
        call: structures.FunctionCall(structures.InstanceId),
        destination: ValueLocation,
    ) !void {
        for (self.call_arguments[call.arguments.start..call.arguments.end], 0..) |argument, argument_index| {
            try self.loadValue(self.locations[@intFromEnum(argument)]);
            const offset: u32 = @intCast(argument_index * @sizeOf(i32));
            try self.encoder.movRspFromEax(offset);
        }
        const offset_usize = std.math.add(usize, self.encoder.code.items.len, 1) catch return error.FunctionTooLarge;
        const offset = std.math.cast(u32, offset_usize) orelse return error.FunctionTooLarge;
        try self.encoder.callRelative32(0);

        var reference_index: ?usize = null;
        for (self.referenced_instances.items, 0..) |existing, index| {
            if (std.meta.eql(existing, call.target)) {
                reference_index = index;
                break;
            }
        }
        if (reference_index == null) {
            reference_index = self.referenced_instances.items.len;
            try self.referenced_instances.append(self.gpa, call.target);
        }
        const reference = std.math.cast(u32, reference_index.?) orelse return error.FunctionTooLarge;
        try self.relocations.append(self.gpa, .{
            .offset = offset,
            .kind = .call_relative_32,
            .reference = @enumFromInt(reference),
            .addend = 0,
        });
        try self.storeResult(destination);
    }

    fn emitIntegerBinary(
        self: *FunctionEmitter,
        operation: IntegerBinaryOperation,
        operands: structures.BinaryOperands,
        destination: ValueLocation,
    ) !void {
        try self.loadValue(self.locations[@intFromEnum(operands.lhs)]);
        try self.encoder.integerBinary(operation, self.locations[@intFromEnum(operands.rhs)]);
        try self.storeResult(destination);
    }

    fn loadValue(self: *FunctionEmitter, location: ValueLocation) !void {
        switch (location) {
            .immediate => |value| try self.encoder.movEaxImmediate32(value),
            .eax => {},
            .stack, .incoming_argument => |offset| try self.encoder.movEaxFromRsp(offset),
            .discarded => unreachable,
        }
    }

    fn storeResult(self: *FunctionEmitter, location: ValueLocation) !void {
        switch (location) {
            .stack => |offset| try self.encoder.movRspFromEax(offset),
            .eax, .discarded => {},
            .immediate, .incoming_argument => unreachable,
        }
    }

    fn finish(self: *FunctionEmitter) !structures.CompiledFunction {
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

pub fn compileFunction(ssa: *const structures.SsaFunction, gpa: std.mem.Allocator) error{ OutOfMemory, FunctionTooLarge, UnsupportedControlFlow }!structures.CompiledFunction {
    if (ssa.blocks.len != 1) return error.UnsupportedControlFlow;
    if (@intFromEnum(ssa.entry) != 0) return error.UnsupportedControlFlow;
    const block = ssa.blocks[0];
    if (block.argument_start != 0) return error.UnsupportedControlFlow;
    if (block.argument_end != ssa.block_argument_types.len) return error.UnsupportedControlFlow;
    if (block.instruction_start != 0) return error.UnsupportedControlFlow;
    if (block.instruction_end != ssa.instructions.len) return error.UnsupportedControlFlow;

    var plan = try LocationPlan.init(ssa, block, gpa);
    defer plan.deinit(gpa);
    var emitter = try FunctionEmitter.init(gpa, plan.locations, ssa.call_arguments);
    defer emitter.deinit();
    try emitter.emit(ssa, plan);
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
            if (relocation_offset > function.artifact.code.len or
                function.artifact.code.len - relocation_offset < @sizeOf(i32))
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
    try encoder.movEaxImmediate32(60);
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
            try patchRelativeDisplacement(
                encoder.code.items,
                layout.offset + @as(usize, relocation.offset),
                target_layout.address,
                layout.address + @as(u64, relocation.offset) + @sizeOf(i32),
                relocation.addend,
            );
        }
    }

    return .{ .bytes = try buildElfExecutable(encoder.code.items, gpa) };
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

    fn callRelative32(self: *@This(), displacement: i32) !void {
        try self.appendBits32(&.{0xE8}, @bitCast(displacement));
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

    fn movEcxImmediate32(self: *@This(), value: i32) !void {
        try self.appendBits32(&.{0xB9}, @bitCast(value));
    }

    fn movEaxFromRsp(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x8B, 0x84, 0x24 }, offset);
    }

    fn movRspFromEax(self: *@This(), offset: u32) !void {
        try self.appendBits32(&.{ 0x89, 0x84, 0x24 }, offset);
    }

    fn negateEax(self: *@This()) !void {
        try self.appendBytes(&.{ 0xF7, 0xD8 });
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
                .eax, .discarded => unreachable,
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
            .eax, .discarded => unreachable,
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
