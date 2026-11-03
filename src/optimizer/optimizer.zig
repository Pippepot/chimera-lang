const std = @import("std");
const structures = @import("../structures.zig");
const value_operations = @import("../value.zig");
const profiling = @import("../profiling.zig");
const BumpArena = @import("../bump_arena.zig");
const function_ir = @import("function.zig");
const Function = function_ir.Function;
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

pub const prepare = optimize;

/// Optimizes in scratch memory backed by `gpa` and returns a body owned by `result`.
pub fn optimize(gpa: std.mem.Allocator, result: std.mem.Allocator, body: *const Body, context: anytype) !Body {
    var arena: BumpArena = .init(gpa);
    defer arena.deinit();
    const optimized = try optimizeInto(arena.allocator(), body, context);
    if (std.debug.runtime_safety) verifier.verify(&optimized);
    return measured(.optimization_clone, value_operations.Owned(Body).clone, .{ result, optimized });
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
    if (final) {
        // Pruning an inlined body can free room for later small callees. Keep
        // the original caller's growth limit across rounds so simplification
        // exposes opportunities without repeatedly multiplying that limit.
        const budget = inlining.growthBudget(&function);
        var callees: inlining.Cache = .{};
        while (try measured(.optimization_inline, inlining.inlineCalls, .{ &function, context, budget, &callees })) {
            try check(&function);
            try simplify(&function, context, &numbering_workspace, &field_layouts, .changed_everywhere);
        }
        if ((try function.controlFlowEdges()).cyclic) try transformLoops(scratch, &function, context, &callees, &numbering_workspace, &field_layouts);
    } else {
        try simplify(&function, context, &numbering_workspace, &field_layouts, .changed_everywhere);
    }
    return measured(.optimization_compaction, compaction.compact, .{ scratch, &function });
}

fn transformLoops(scratch: std.mem.Allocator, function: *Function, context: anytype, callees: *inlining.Cache, numbering_workspace: *numbering.Workspace, field_layouts: *sroa.Layouts) !void {
    // Inlining leaves removed instructions and blocks that every later pass
    // still sizes its scratch tables by. Rebuild densely before loop rewrites.
    // Compaction only drops values, so the classified types cover the rebuilt function.
    try measured(.optimization_setup, Function.classifyTypes, .{ function, context });
    const dense = try measured(.optimization_compaction, compaction.compact, .{ scratch, function });
    const direct_types = function.direct_types;
    function.* = try measured(.optimization_setup, Function.init, .{ scratch, &dense, dense.initializer_regions });
    function.direct_types = direct_types;
    function.classified_values = function.definitions.items.len;
    // Store identities survive cleanup even when fallback latch blocks merge.
    // Keep them across rounds so bulk rewrites cannot version their fallback.
    var bulk_fallbacks: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var needs_simplification = try measured(.optimization_hoist, hoisting.hoist, .{function});
    try check(function);
    while (true) {
        const transformed = try measured(.optimization_idioms, idioms.transform, .{ function, context, callees, &bulk_fallbacks });
        try check(function);
        if (!needs_simplification and !transformed) break;
        try simplify(function, context, numbering_workspace, field_layouts, .loop_rewrite);
        // Simplifying joins left by an inner loop rewrite can expose its
        // containing loop's counter and carried exit.
        needs_simplification = false;
    }
}

/// What changed since the function last converged. Inlining and typed bodies
/// dirty every analysis and iterate to a fixed point. A loop rewrite only
/// removes loop structure, so one round of the remaining passes suffices;
/// storage and numbering facts stay valid until those passes report changes.
const Change = enum { changed_everywhere, loop_rewrite };

fn simplify(function: *Function, context: anytype, numbering_workspace: *numbering.Workspace, field_layouts: *sroa.Layouts, change: Change) !void {
    var storage_dirty = change == .changed_everywhere;
    var numbering_dirty = storage_dirty;
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
        var numbered: function_ir.Changes = .{};
        var dead: function_ir.Changes = .{};
        if (numbering_dirty) {
            numbered = try measured(.optimization_numbering, numbering.number, .{ function, numbering_workspace });
            try check(function);
            dead = try measured(.optimization_dead_code, compaction.removeDead, .{function});
            try check(function);
        }
        const cleaned = try measured(.optimization_cleanup, cleanup.simplify, .{function});
        // Numbering visits dominating definitions before their users. Its own
        // substitutions need another numbering pass only after another phase
        // changes inputs or dead-code removal changes address exposure.
        numbering_dirty = dead.uses or cleaned;
        try check(function);
        storage_dirty = folded.storage or folded.control_flow or numbered.storage or dead.storage;
        // Cleanup runs last; its own changes do not start another round.
        if (change == .loop_rewrite or (!numbered.changed and !dead.uses and !(storage_dirty and function.hasStorage()))) break;
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
