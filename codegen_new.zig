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

pub fn compileFunction(ssa: *const structures.SsaFunction, gpa: std.mem.Allocator) error{ OutOfMemory, InvalidSsa }!structures.CompiledFunction {
    if (ssa.blocks.len != 1) return error.InvalidSsa;
    if (@intFromEnum(ssa.entry) != 0) return error.InvalidSsa;
    const block = ssa.blocks[0];
    if (block.instruction_start != 0) return error.InvalidSsa;
    if (block.instruction_end != ssa.instructions.len) return error.InvalidSsa;

    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();
    var relocations: std.ArrayList(structures.CompiledFunction.Relocation) = .empty;
    defer relocations.deinit(gpa);
    var referenced_instances: std.ArrayList(structures.InstanceId) = .empty;
    defer referenced_instances.deinit(gpa);

    for (ssa.instructions) |instruction| {
        switch (instruction) {
            .integer_constant => {},
            .direct_call => |target| {
                const offset_usize = std.math.add(usize, encoder.code.items.len, 1) catch return error.InvalidSsa;
                const offset = std.math.cast(u32, offset_usize) orelse return error.InvalidSsa;
                try encoder.callRelative32(0);

                var reference_index: ?usize = null;
                for (referenced_instances.items, 0..) |existing, index| {
                    if (std.meta.eql(existing, target)) {
                        reference_index = index;
                        break;
                    }
                }
                if (reference_index == null) {
                    reference_index = referenced_instances.items.len;
                    try referenced_instances.append(gpa, target);
                }
                const reference = std.math.cast(u32, reference_index.?) orelse return error.InvalidSsa;
                try relocations.append(gpa, .{
                    .offset = offset,
                    .kind = .call_relative_32,
                    .reference = @enumFromInt(reference),
                    .addend = 0,
                });
            },
        }
    }
    try emitTerminator(&encoder, ssa, block.terminator);

    const owned_relocations: []const structures.CompiledFunction.Relocation = if (relocations.items.len == 0)
        &.{}
    else
        try relocations.toOwnedSlice(gpa);
    errdefer if (owned_relocations.len != 0) gpa.free(owned_relocations);
    const owned_references: []const structures.InstanceId = if (referenced_instances.items.len == 0)
        &.{}
    else
        try referenced_instances.toOwnedSlice(gpa);
    errdefer if (owned_references.len != 0) gpa.free(owned_references);

    return .{
        .code = try encoder.code.toOwnedSlice(gpa),
        .required_alignment = 1,
        .relocations = owned_relocations,
        .referenced_instances = owned_references,
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

fn emitTerminator(
    encoder: *X86Encoder,
    ssa: *const structures.SsaFunction,
    terminator: structures.SsaFunction.Terminator,
) error{ OutOfMemory, InvalidSsa }!void {
    switch (terminator) {
        .return_unit => try encoder.ret(),
        .return_value => |value_id| {
            const instruction_index = @intFromEnum(value_id);
            if (instruction_index >= ssa.instructions.len) return error.InvalidSsa;
            switch (ssa.instructions[instruction_index]) {
                .integer_constant => |value| try encoder.movEaxImmediate32(value),
                .direct_call => {
                    if (instruction_index + 1 != ssa.instructions.len) return error.InvalidSsa;
                },
            }
            try encoder.ret();
        },
    }
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

    fn callRelative32(self: *@This(), displacement: i32) !void {
        var instruction: [5]u8 = undefined;
        instruction[0] = 0xE8;
        std.mem.writeInt(i32, instruction[1..5], displacement, .little);
        try self.appendBytes(&instruction);
    }

    fn zeroEdi(self: *@This()) !void {
        try self.appendBytes(&.{ 0x31, 0xFF });
    }

    fn movEaxImmediate32(self: *@This(), value: i32) !void {
        var instruction: [5]u8 = undefined;
        instruction[0] = 0xB8;
        std.mem.writeInt(i32, instruction[1..5], value, .little);
        try self.appendBytes(&instruction);
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
