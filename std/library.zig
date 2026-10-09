const std = @import("std");

pub const File = enum(u32) {
    exit,
    memory_allocation,
    memory_host,
    prelude,
    ownership,
    array,

    pub fn path(file: File) []const u8 {
        return switch (file) {
            .exit => "exit.chi",
            .memory_allocation => "memory/allocation.chi",
            .memory_host => "memory/host.chi",
            .prelude => "prelude.chi",
            .ownership => "ownership.chi",
            .array => "array.chi",
        };
    }

    pub fn modulePath(file: File) []const u8 {
        return switch (file) {
            inline else => |known| standardModulePath(known.path()),
        };
    }
};

pub const paths = blk: {
    var result: [@typeInfo(File).@"enum".field_names.len][]const u8 = undefined;
    for (std.meta.tags(File), 0..) |file, index| result[index] = file.path();
    break :blk result;
};

pub const root_module = "std";

pub const External = enum {
    exit,
    allocate_host_storage,
    deallocate_host_storage,
    allocate,
    deallocate,
    allocation_count,
    unsafe_initialize,
    unsafe_take,
    unsafe_destroy,
    unsafe_borrow_initialized,
    borrow_box,
    borrow_mut_box,
    borrow_local,
    unsafe_borrow_element,
    unsafe_borrow_mut_element,
    read,
    write,
    attenuate_ref,
    unsafe_own_box,
    unsafe_take_box,
    unsafe_destroy_box,
    deallocate_box,
    copy_value,
    move_value,
    array_filled,
    array_from,
    array_borrow,
    array_borrow_mut,
    literal_byte,
    initialize_collection,

    pub fn file(symbol: External) File {
        return switch (symbol) {
            .exit => .exit,
            .literal_byte => .prelude,
            .copy_value, .move_value => .ownership,
            .array_filled, .array_from, .array_borrow, .array_borrow_mut => .array,
            .allocate_host_storage, .deallocate_host_storage => .memory_host,
            .allocate, .deallocate, .allocation_count, .unsafe_initialize, .unsafe_take, .unsafe_destroy, .unsafe_borrow_initialized, .borrow_box, .borrow_mut_box, .borrow_local, .unsafe_borrow_element, .unsafe_borrow_mut_element, .read, .write, .attenuate_ref, .unsafe_own_box, .unsafe_take_box, .unsafe_destroy_box, .deallocate_box, .initialize_collection => .memory_allocation,
        };
    }
};

pub const Structure = enum { HostStorage, Allocation, Buffer, BufferView, Box, Ref, Array, collection_literal, List };

pub fn standardModulePath(comptime file_path: []const u8) []const u8 {
    const name = comptime (std.fs.path.dirname(file_path) orelse std.fs.path.stem(file_path));
    const path = comptime blk: {
        var result: [name.len]u8 = undefined;
        for (name, 0..) |character, index| result[index] = if (character == '/') '.' else character;
        break :blk result;
    };
    return root_module ++ "." ++ path;
}

pub fn source(comptime path: []const u8) []const u8 {
    return @embedFile(path);
}
