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
    var direct_call: ?structures.InstanceId = null;
    for (ssa.instructions) |instruction| {
        switch (instruction) {
            .integer_constant => {},
            .direct_call => |target| {
                if (direct_call != null) return error.InvalidSsa;
                direct_call = target;
            },
        }
    }
    if (direct_call != null) {
        if (ssa.instructions.len != 1) return error.InvalidSsa;
        switch (ssa.terminator) {
            .return_unit => {},
            .return_value => return error.InvalidSsa,
        }
    }

    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();

    if (direct_call != null) try encoder.callRelative32(0);
    try emitTerminator(&encoder, ssa);

    var relocations: []const structures.CompiledFunction.Relocation = &.{};
    errdefer if (relocations.len != 0) gpa.free(relocations);
    var referenced_instances: []const structures.InstanceId = &.{};
    errdefer if (referenced_instances.len != 0) gpa.free(referenced_instances);
    if (direct_call) |target| {
        const owned_relocations = try gpa.alloc(structures.CompiledFunction.Relocation, 1);
        owned_relocations[0] = .{
            .offset = 1,
            .kind = .call_relative_32,
            .reference = @enumFromInt(0),
            .addend = 0,
        };
        relocations = owned_relocations;

        const owned_references = try gpa.alloc(structures.InstanceId, 1);
        owned_references[0] = target;
        referenced_instances = owned_references;
    }

    return .{
        .code = try encoder.code.toOwnedSlice(gpa),
        .required_alignment = 1,
        .relocations = relocations,
        .referenced_instances = referenced_instances,
    };
}

/// `callee` must be non-null exactly when `entry` carries the one currently
/// supported call shape (one relocation, one referenced instance); every
/// other shape is `UnsupportedArtifactMetadata`.
pub fn buildExecutable(
    entry: *const structures.CompiledFunction,
    callee: ?*const structures.CompiledFunction,
    gpa: std.mem.Allocator,
) !structures.Executable {
    std.debug.assert(entry.code.len != 0);
    std.debug.assert(std.math.isPowerOfTwo(entry.required_alignment));

    const has_call = entry.relocations.len == 1 and entry.referenced_instances.len == 1;
    if (!has_call and (entry.relocations.len != 0 or entry.referenced_instances.len != 0)) {
        return error.UnsupportedArtifactMetadata;
    }
    if (has_call != (callee != null)) return error.UnsupportedArtifactMetadata;
    if (callee) |target| {
        std.debug.assert(target.code.len != 0);
        std.debug.assert(std.math.isPowerOfTwo(target.required_alignment));
        // Declared-function bodies cannot themselves call yet, so every callee
        // reachable through this path is a leaf artifact.
        std.debug.assert(target.relocations.len == 0);
        std.debug.assert(target.referenced_instances.len == 0);
    }

    var encoder = try X86Encoder.init(gpa);
    defer encoder.deinit();

    const call_displacement_offset = encoder.code.items.len + 1;
    try encoder.callRelative32(0);
    try encoder.zeroEdi();
    try encoder.movEaxImmediate32(60);
    try encoder.syscall();

    const code_virtual_address = image_base + @as(u64, code_file_offset);
    const entry_virtual_address = std.mem.alignForward(u64, code_virtual_address + encoder.code.items.len, entry.required_alignment);
    const entry_offset = try offsetFromBase(entry_virtual_address, code_virtual_address);
    try patchRelativeDisplacement(
        encoder.code.items,
        call_displacement_offset,
        entry_virtual_address,
        code_virtual_address + @as(u64, call_displacement_offset) + @sizeOf(i32),
        0,
    );

    if (entry.code.len > std.math.maxInt(usize) - entry_offset) return error.FileTooBig;
    try encoder.code.appendNTimes(gpa, 0x90, entry_offset - encoder.code.items.len);
    try encoder.appendBytes(entry.code);

    if (callee) |target| {
        const reloc = entry.relocations[0];
        switch (reloc.kind) {
            .call_relative_32 => {},
        }
        if (@intFromEnum(reloc.reference) != 0) return error.RelocationOutOfBounds;
        const reloc_offset: usize = reloc.offset;
        if (reloc_offset > entry.code.len or entry.code.len - reloc_offset < @sizeOf(i32)) {
            return error.RelocationOutOfBounds;
        }

        const callee_virtual_address = std.mem.alignForward(u64, code_virtual_address + encoder.code.items.len, target.required_alignment);
        const callee_offset = try offsetFromBase(callee_virtual_address, code_virtual_address);
        try patchRelativeDisplacement(
            encoder.code.items,
            entry_offset + reloc_offset,
            callee_virtual_address,
            entry_virtual_address + @as(u64, reloc.offset) + @sizeOf(i32),
            reloc.addend,
        );

        if (target.code.len > std.math.maxInt(usize) - callee_offset) return error.FileTooBig;
        try encoder.code.appendNTimes(gpa, 0x90, callee_offset - encoder.code.items.len);
        try encoder.appendBytes(target.code);
    }

    return .{ .bytes = try buildElfExecutable(encoder.code.items, gpa) };
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

fn emitTerminator(encoder: *X86Encoder, ssa: *const structures.SsaFunction) error{ OutOfMemory, InvalidSsa }!void {
    switch (ssa.terminator) {
        .return_unit => try encoder.ret(),
        .return_value => |value_id| {
            const instruction_index = @intFromEnum(value_id);
            if (instruction_index >= ssa.instructions.len) return error.InvalidSsa;
            switch (ssa.instructions[instruction_index]) {
                .integer_constant => |value| try encoder.movEaxImmediate32(value),
                .direct_call => unreachable,
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
