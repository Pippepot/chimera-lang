const std = @import("std");

pub const File = enum(u32) {
    exit,
    memory_allocation,
    memory_host,
    prelude,

    pub fn path(file: File) []const u8 {
        return switch (file) {
            .exit => "exit.chi",
            .memory_allocation => "memory/allocation.chi",
            .memory_host => "memory/host.chi",
            .prelude => "prelude.chi",
        };
    }

    pub fn modulePath(file: File) []const u8 {
        return switch (file) {
            inline else => |known| standardModulePath(known.path()),
        };
    }
};

pub const paths = blk: {
    var result: [@typeInfo(File).@"enum".fields.len][]const u8 = undefined;
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
    unsafe_initialize,
    unsafe_take,
    unsafe_own_ref,
    unsafe_take_ref,
    deallocate_ref,

    pub fn file(symbol: External) File {
        return switch (symbol) {
            .exit => .exit,
            .allocate_host_storage, .deallocate_host_storage => .memory_host,
            .allocate, .deallocate, .unsafe_initialize, .unsafe_take, .unsafe_own_ref, .unsafe_take_ref, .deallocate_ref => .memory_allocation,
        };
    }
};

pub const Structure = enum { HostStorage, Allocation, Ref };

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
