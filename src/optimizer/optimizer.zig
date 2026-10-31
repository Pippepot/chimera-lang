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
        const transformed = try measured(.optimization_idioms, idioms.transform, .{ &function, context });
        try check(&function);
        if (hoisted or transformed) try simplify(&function, context, &numbering_workspace, &field_layouts);
    }
    return measured(.optimization_compaction, compaction.compact, .{ scratch, &function });
}

fn simplify(function: *Function, context: anytype, numbering_workspace: *numbering.Workspace, field_layouts: *sroa.Layouts) !void {
    var storage_dirty = true;
    var numbering_dirty = true;
    while (true) {
        if (storage_dirty) try measured(.optimization_setup, Function.classifyTypes, .{ function, context });
        if (storage_dirty and function.hasStorage()) {
            if (try measured(.optimization_sroa, sroa.split, .{ function, context, field_layouts })) {
                numbering_dirty = true;
                try measured(.optimization_setup, Function.classifyTypes, .{ function, context });
            }
            try check(function);
            // Their consumers run below; storage passes need another round only
            // when those consumers change storage uses or control flow.
            if (try measured(.optimization_promotion, promotion.promote, .{function})) numbering_dirty = true;
            try check(function);
        }
        const parameters_changed = try measured(.optimization_joins, cleanup.simplifyParameters, .{ function, true });
        numbering_dirty = numbering_dirty or parameters_changed;
        try check(function);
        var folded = try measured(.optimization_canonicalize, canonicalize.canonicalize, .{function});
        numbering_dirty = numbering_dirty or folded.changed;
        if (parameters_changed or folded.changed) {
            var variants_dirty = folded.control_flow;
            while (try measured(.optimization_joins, cleanup.simplifyParameters, .{ function, variants_dirty })) {
                numbering_dirty = true;
                const more = try measured(.optimization_canonicalize, canonicalize.canonicalize, .{function});
                variants_dirty = more.control_flow;
                folded.changed = folded.changed or more.changed;
                folded.storage = folded.storage or more.storage;
                folded.control_flow = folded.control_flow or more.control_flow;
                try check(function);
            }
        }
        try check(function);
        const numbered: @import("function.zig").Changes = if (numbering_dirty)
            try measured(.optimization_numbering, numbering.number, .{ function, numbering_workspace })
        else
            .{};
        try check(function);
        const dead: @import("function.zig").Changes = if (numbering_dirty)
            try measured(.optimization_dead_code, compaction.removeDead, .{function})
        else
            .{};
        try check(function);
        const cleaned = try measured(.optimization_cleanup, cleanup.simplify, .{function});
        // Numbering visits dominating definitions before their users. Its own
        // substitutions need another numbering pass only after another phase
        // changes inputs or dead-code removal changes address exposure.
        numbering_dirty = dead.uses or cleaned;
        try check(function);
        storage_dirty = folded.storage or folded.control_flow or numbered.storage or dead.storage or cleaned;
        if (!numbered.changed and !dead.uses and !cleaned and !(storage_dirty and function.hasStorage())) break;
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
