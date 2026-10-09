const std = @import("std");

pub const cache = @import("src/cache.zig");
pub const codegen = @import("src/backend/codegen.zig");
pub const comptime_interpreter = @import("src/frontend/comptime_interpreter.zig");
pub const modules = @import("src/modules.zig");
pub const query = @import("src/query/engine.zig");
pub const queries = @import("src/queries.zig");
pub const query_disk_cache = @import("src/query_disk_cache.zig");
pub const runtime = @import("src/runtime.zig");
pub const structures = @import("src/structures.zig");

var allocation_failure_backing: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
// In-place growth depends on allocator storage state. Reject resize and remap
// so every growth is an allocation checked by checkAllAllocationFailures.
var allocation_failure_growth = std.testing.FailingAllocator.init(allocation_failure_backing.allocator(), .{ .resize_fail_index = 0 });
pub const allocation_failure_allocator = allocation_failure_growth.allocator();

pub fn renderTemplate(allocator: std.mem.Allocator, source: []const u8, values: anytype) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var position: usize = 0;
    while (std.mem.indexOfScalarPos(u8, source, position, '$')) |start| {
        try result.appendSlice(allocator, source[position..start]);
        var end = start + 1;
        while (end < source.len and (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) : (end += 1) {}
        const name = source[start + 1 .. end];
        var matched = false;
        inline for (@typeInfo(@TypeOf(values)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                try result.appendSlice(allocator, @field(values, field_name));
                matched = true;
            }
        }
        if (!matched) return error.UnknownTemplateParameter;
        position = end;
    }
    try result.appendSlice(allocator, source[position..]);
    return result.toOwnedSlice(allocator);
}

test "source templates substitute named dollar markers" {
    const rendered = try renderTemplate(std.testing.allocator, "Item{value = $value}; $value_long; $value; $empty", .{
        .value = "42",
        .value_long = "$untouched",
        .empty = "",
    });
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("Item{value = 42}; $untouched; 42; ", rendered);
    try std.testing.expectError(error.UnknownTemplateParameter, renderTemplate(std.testing.allocator, "$missing", .{}));
}

test {
    _ = @import("src/main.zig");
    _ = cache;
    _ = query_disk_cache;
    _ = queries;
    _ = modules;
    _ = runtime;
    _ = @import("src/frontend/tokenizer.zig");
    _ = @import("src/frontend/parser.zig");
    _ = @import("src/frontend/semantic.zig");
    _ = @import("src/frontend/flow_snapshot.zig");
    _ = @import("src/frontend/lifetime.zig");
    _ = @import("src/frontend/typing.zig");
    _ = @import("src/query/codec.zig");
    _ = @import("src/backend/disasm.zig");
}
