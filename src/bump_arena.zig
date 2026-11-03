//! Unsynchronized arena for scratch memory owned by one thread.
//!
//! `std.heap.ArenaAllocator` publishes every allocation with atomic operations;
//! scratch memory never crosses threads, so plain bump allocation suffices.
const std = @import("std");

const BumpArena = @This();

const Chunk = struct {
    previous: ?*Chunk,
    size: usize,
    used: usize,
};

const chunk_alignment: std.mem.Alignment = .of(Chunk);
const header = std.mem.alignForward(usize, @sizeOf(Chunk), 16);
const first_chunk = 64 * 1024;
const largest_growth = 4 * 1024 * 1024;

child: std.mem.Allocator,
newest: ?*Chunk = null,
first: usize = first_chunk,

pub fn init(child: std.mem.Allocator) BumpArena {
    return .{ .child = child };
}

/// An arena whose first chunk is `first` bytes, for owners that retain the
/// arena and expect many small results.
pub fn initSized(child: std.mem.Allocator, first: usize) BumpArena {
    return .{ .child = child, .first = first };
}

pub fn deinit(arena: BumpArena) void {
    var chunk = arena.newest;
    while (chunk) |current| {
        chunk = current.previous;
        arena.free(current);
    }
}

/// Bytes handed out, excluding chunk headers.
pub fn bytesUsed(arena: BumpArena) usize {
    var total: usize = 0;
    var chunk = arena.newest;
    while (chunk) |current| : (chunk = current.previous) total += current.used - header;
    return total;
}

/// Release the newest chunks until the rest hold at most `retain_limit` bytes,
/// and make the kept chunks empty.
pub fn reset(arena: *BumpArena, retain_limit: usize) void {
    var total: usize = 0;
    var chunk = arena.newest;
    while (chunk) |current| : (chunk = current.previous) total += current.size;
    while (arena.newest) |current| {
        if (total <= retain_limit) break;
        total -= current.size;
        arena.newest = current.previous;
        arena.free(current);
    }
    chunk = arena.newest;
    while (chunk) |current| : (chunk = current.previous) current.used = header;
}

fn free(arena: BumpArena, chunk: *Chunk) void {
    const bytes: [*]u8 = @ptrCast(chunk);
    arena.child.rawFree(bytes[0..chunk.size], chunk_alignment, @returnAddress());
}

pub fn allocator(arena: *BumpArena) std.mem.Allocator {
    return .{ .ptr = arena, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = release } };
}

fn alloc(pointer: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    const arena: *BumpArena = @ptrCast(@alignCast(pointer));
    if (arena.newest) |chunk| if (bump(chunk, length, alignment)) |memory| return memory;
    const growth = if (arena.newest) |chunk| @min(chunk.size * 2, largest_growth) else arena.first;
    const size = @max(growth, header + length + alignment.toByteUnits());
    const bytes = arena.child.rawAlloc(size, chunk_alignment, return_address) orelse return null;
    const chunk: *Chunk = @ptrCast(@alignCast(bytes));
    chunk.* = .{ .previous = arena.newest, .size = size, .used = header };
    arena.newest = chunk;
    return bump(chunk, length, alignment);
}

fn bump(chunk: *Chunk, length: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const base = @intFromPtr(chunk);
    const start = alignment.forward(base + chunk.used);
    if (start + length > base + chunk.size) return null;
    chunk.used = start + length - base;
    return @ptrFromInt(start);
}

fn isNewest(arena: *const BumpArena, memory: []const u8) bool {
    const chunk = arena.newest orelse return false;
    return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(chunk) + chunk.used;
}

fn resize(pointer: *anyopaque, memory: []u8, _: std.mem.Alignment, new_length: usize, _: usize) bool {
    const arena: *BumpArena = @ptrCast(@alignCast(pointer));
    if (!arena.isNewest(memory)) return new_length <= memory.len;
    const chunk = arena.newest.?;
    const base = @intFromPtr(chunk);
    const end = @intFromPtr(memory.ptr) + new_length;
    if (end > base + chunk.size) return false;
    chunk.used = end - base;
    return true;
}

fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
    return if (resize(pointer, memory, alignment, new_length, return_address)) memory.ptr else null;
}

fn release(pointer: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    const arena: *BumpArena = @ptrCast(@alignCast(pointer));
    if (arena.isNewest(memory)) arena.newest.?.used = @intFromPtr(memory.ptr) - @intFromPtr(arena.newest.?);
}

test "bump arena grows in place only for the newest allocation" {
    var arena: BumpArena = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const first = try memory.alloc(u8, 10);
    const second = try memory.alloc(u32, 3);
    try std.testing.expect(!memory.resize(first, 20));
    try std.testing.expect(memory.resize(second, 8));
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(second.ptr) % 4);
    const large = try memory.alloc(u8, 3 * first_chunk);
    @memset(large, 1);
    memory.free(large);
    const grown = try memory.alloc(u8, first_chunk);
    @memset(grown, 2);
}

test "bump arena reset keeps the oldest chunks within the limit" {
    var arena: BumpArena = .init(std.testing.allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    _ = try memory.alloc(u8, 10);
    const oldest = arena.newest.?;
    _ = try memory.alloc(u8, 2 * first_chunk);
    try std.testing.expect(arena.newest.? != oldest);
    arena.reset(2 * first_chunk);
    try std.testing.expectEqual(oldest, arena.newest.?);
    try std.testing.expectEqual(header, oldest.used);
    arena.reset(0);
    try std.testing.expectEqual(null, arena.newest);
    var small = initSized(std.testing.allocator, 256);
    defer small.deinit();
    _ = try small.allocator().alloc(u8, 10);
    try std.testing.expectEqual(@as(usize, 256), small.newest.?.size);
}
