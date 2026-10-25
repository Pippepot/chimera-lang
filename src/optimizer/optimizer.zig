const std = @import("std");
const structures = @import("../structures.zig");
const value_operations = @import("../value.zig");
const profiling = @import("../profiling.zig");
const Function = @import("function.zig").Function;
const canonicalize = @import("canonicalize.zig");
const cleanup = @import("cleanup.zig");
const compaction = @import("compaction.zig");
const graph = @import("graph.zig");
const hoisting = @import("hoisting.zig");
const idioms = @import("idioms.zig");
const inlining = @import("inline.zig");
const numbering = @import("numbering.zig");
const promotion = @import("promotion.zig");
const sroa = @import("sroa.zig");
const verifier = @import("verifier.zig");

const Body = structures.FunctionBodyAnalysis;

pub fn prepare(gpa: std.mem.Allocator, body: *const Body, context: anytype) !Body {
    return run(gpa, body, context);
}

pub fn optimize(gpa: std.mem.Allocator, body: *const Body, context: anytype) !Body {
    return run(gpa, body, context);
}

fn run(gpa: std.mem.Allocator, body: *const Body, context: anytype) !Body {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const optimized = try optimizeInto(arena.allocator(), body, context);
    if (std.debug.runtime_safety) verifier.verify(&optimized);
    return measured(.optimization_clone, value_operations.Owned(Body).clone, .{ gpa, optimized });
}

fn optimizeInto(scratch: std.mem.Allocator, body: *const Body, context: anytype) !Body {
    const regions = try scratch.alloc(Body, body.initializer_regions.len);
    for (body.initializer_regions, regions) |*region, *optimized| optimized.* = try optimizeInto(scratch, region, context);
    var function = try measured(.optimization_setup, Function.init, .{ scratch, body, regions });
    var numbering_workspace: numbering.Workspace = .{};
    var field_layouts: sroa.Layouts = .{};
    try measured(.optimization_setup, Function.classifyTypes, .{ &function, context });
    if (!try measured(.optimization_graph, graph.dominatesUses, .{&function}))
        return measured(.optimization_compaction, compaction.compact, .{ scratch, &function });
    try check(&function);
    const final = @hasDecl(@TypeOf(context), "inlineBody");
    const inlined = final and try measured(.optimization_inline, inlining.inlineCalls, .{ &function, context });
    if (inlined) try check(&function);
    if (!final or inlined) try simplify(&function, context, &numbering_workspace, &field_layouts);
    if (final) {
        const hoisted = try measured(.optimization_hoist, hoisting.hoist, .{&function});
        try check(&function);
        const transformed = try measured(.optimization_idioms, idioms.transform, .{&function});
        try check(&function);
        if (hoisted or transformed) try simplify(&function, context, &numbering_workspace, &field_layouts);
    }
    return measured(.optimization_compaction, compaction.compact, .{ scratch, &function });
}

fn simplify(function: *Function, context: anytype, numbering_workspace: *numbering.Workspace, field_layouts: *sroa.Layouts) !void {
    var storage_dirty = true;
    for (0..2) |_| {
        var changed = false;
        if (storage_dirty) try measured(.optimization_setup, Function.classifyTypes, .{ function, context });
        if (storage_dirty and function.hasStorage()) {
            if (try measured(.optimization_sroa, sroa.split, .{ function, context, field_layouts })) {
                changed = true;
                try measured(.optimization_setup, Function.classifyTypes, .{ function, context });
            }
            try check(function);
            if (try measured(.optimization_promotion, promotion.promote, .{function})) changed = true;
            try check(function);
        }
        const folded = try measured(.optimization_canonicalize, canonicalize.canonicalize, .{function});
        changed = changed or folded.changed;
        try check(function);
        const numbered = try measured(.optimization_numbering, numbering.number, .{ function, numbering_workspace });
        changed = changed or numbered.changed;
        try check(function);
        const dead = try measured(.optimization_dead_code, compaction.removeDead, .{function});
        changed = changed or dead.changed;
        try check(function);
        const cleaned = try measured(.optimization_cleanup, cleanup.simplify, .{function});
        changed = changed or cleaned;
        try check(function);
        storage_dirty = folded.storage or folded.control_flow or numbered.storage or dead.storage or cleaned;
        if (!changed) break;
    }
}

fn check(function: *Function) !void {
    if (std.debug.runtime_safety) try verifier.verifyFunction(function);
}

fn measured(comptime category: profiling.Category, comptime operation: anytype, arguments: anytype) @TypeOf(@call(.auto, operation, arguments)) {
    var scope: profiling.Scope = .{};
    scope.beginCurrent(category);
    defer scope.end();
    return @call(.auto, operation, arguments);
}
