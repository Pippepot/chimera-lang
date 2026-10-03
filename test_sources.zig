const std = @import("std");

pub const codegen = @import("src/backend/codegen.zig");
pub const modules = @import("src/modules.zig");
pub const query = @import("src/query/engine.zig");
pub const queries = @import("src/queries.zig");
pub const runtime = @import("src/runtime.zig");
pub const structures = @import("src/structures.zig");

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
        inline for (std.meta.fields(@TypeOf(values))) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                try result.appendSlice(allocator, @field(values, field.name));
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
    _ = @import("src/cache.zig");
    _ = @import("src/query_disk_cache.zig");
    _ = modules;
    _ = runtime;
    _ = @import("src/frontend/tokenizer.zig");
    _ = @import("src/frontend/parser.zig");
    _ = @import("src/frontend/semantic.zig");
    _ = @import("src/frontend/comptime_interpreter.zig");
    _ = @import("src/frontend/lifetime.zig");
    _ = @import("src/frontend/typing.zig");
    _ = @import("src/query/codec.zig");
    _ = @import("src/backend/disasm.zig");
}
