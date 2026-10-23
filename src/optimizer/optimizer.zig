const std = @import("std");
const structures = @import("../structures.zig");
const value_operations = @import("../value.zig");
const Function = @import("function.zig").Function;
const canonicalize = @import("canonicalize.zig");
const compaction = @import("compaction.zig");
const promotion = @import("promotion.zig");
const verifier = @import("verifier.zig");

const Body = structures.FunctionBodyAnalysis;

pub fn optimize(gpa: std.mem.Allocator, body: *const Body) !Body {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const optimized = try optimizeInto(arena.allocator(), body);
    if (std.debug.runtime_safety) verifier.verify(&optimized);
    return value_operations.Owned(Body).clone(gpa, optimized);
}

fn optimizeInto(scratch: std.mem.Allocator, body: *const Body) !Body {
    const regions = try scratch.alloc(Body, body.initializer_regions.len);
    for (body.initializer_regions, regions) |*region, *optimized| optimized.* = try optimizeInto(scratch, region);
    var function = try Function.init(scratch, body);
    try promotion.promote(&function);
    try canonicalize.canonicalize(&function);
    return compaction.compact(scratch, &function, regions);
}
