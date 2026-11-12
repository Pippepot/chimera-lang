const std = @import("std");

pub const File = enum(u32) {
    exit,
    memory_allocation,
    memory_raw,
    memory_allocator,
    logging,
    prelude,
    ownership,
    array,
    text,
    io,
    range,
    iteration,
    math,
    primitives,
    search,
    memory_sort,
    algorithms,
    callables,
    context,

    pub fn path(file: File) []const u8 {
        return switch (file) {
            .exit => "exit.chi",
            .memory_allocation => "memory/allocation.chi",
            .memory_raw => "memory/raw.chi",
            .memory_allocator => "memory/allocator.chi",
            .logging => "logging.chi",
            .prelude => "prelude.chi",
            .ownership => "ownership.chi",
            .array => "array.chi",
            .text => "text.chi",
            .io => "io.chi",
            .range => "range.chi",
            .iteration => "iteration.chi",
            .math => "math.chi",
            .primitives => "primitives.chi",
            .search => "search.chi",
            .memory_sort => "memory/sort.chi",
            .algorithms => "algorithms.chi",
            .callables => "callables.chi",
            .context => "context.chi",
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
    panic_message,
    unsafe_initialize,
    unsafe_take,
    unsafe_destroy,
    unsafe_borrow,
    copy_value,
    move_value,
    array_filled,
    array_borrow,
    literal_byte,
    initialize_collection,
    initialize_collection_element,
    static_iteration_item,
    empty_cursor,
    array_cursor,
    allocation_cursor,
    cursor_offset,
    cursor_element,
    cursor_attenuate,
    cursor_take,
    cursor_initialize,
    cursor_destroy,
    io_read,
    io_write,
    primitive_operation,
    numeric_converter,
    erase,
    clone,
    copy_callable,
    drop_callable,
    type_layout,
    layout_for,
    cursor_aligned,
    allocate_raw,
    deallocate_raw,
    allocator_from,
    allocator_from_unchecked,
    logger_from,
    logger_from_unchecked,

    pub fn file(symbol: External) File {
        return switch (symbol) {
            .exit => .exit,
            .literal_byte, .primitive_operation, .numeric_converter => .primitives,
            .panic_message => .text,
            .io_read => .memory_allocation,
            .io_write => .text,
            .copy_value, .move_value => .ownership,
            .array_filled, .array_borrow => .array,
            .empty_cursor, .array_cursor, .allocation_cursor, .cursor_offset, .cursor_element, .cursor_attenuate, .cursor_take, .cursor_initialize, .cursor_destroy => .memory_allocation,
            .unsafe_initialize, .unsafe_take, .unsafe_destroy, .unsafe_borrow, .initialize_collection, .initialize_collection_element, .static_iteration_item => .memory_allocation,
            .erase, .clone, .copy_callable, .drop_callable => .callables,
            .type_layout, .layout_for, .cursor_aligned, .allocate_raw, .deallocate_raw => .memory_raw,
            .allocator_from, .allocator_from_unchecked => .memory_allocator,
            .logger_from, .logger_from_unchecked => .logging,
        };
    }
};

pub const Structure = enum {
    Allocation,
    Box,
    Ref,
    StorageCursor,
    Span,
    Array,
    collection_literal,
    collection_sequence,
    List,

    pub fn declarationName(self: Structure) []const u8 {
        return @tagName(self);
    }
};

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
