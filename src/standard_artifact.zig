const std = @import("std");
const modules = @import("modules.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const bundle = @import("standard_bundle.zig");
const structures = @import("structures.zig");

/// Demand each concrete standard callable, then close over its references.
/// Generic factories and methods remain available for ordinary specialization.
pub fn build(allocator: std.mem.Allocator) ![]u8 {
    const db = try query.Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{ .entry_path = "$std-precompile" };
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "", &.{}, &.{});
    var instances: std.AutoArrayHashMapUnmanaged(structures.InstanceId, void) = .empty;
    defer instances.deinit(allocator);
    for (modules.standard_sources) |source| {
        const file = registry.fileId(source.registry_path).?;
        const module = (try db.input(queries.FileModule, file)).*;
        if (!(try db.get(queries.ValidateModuleGraph, module)).*) return error.InvalidStandardLibrary;
        const items = (try db.get(queries.IndexItems, file)).* orelse return error.InvalidStandardLibrary;
        for (items.ids()) |item| {
            const location = try db.lookupInterned(queries.ItemLocations, item);
            if (location.kind != .function) continue;
            const arity = (try db.get(queries.SpecializationArity, item)).* orelse return error.InvalidStandardLibrary;
            if (arity.total() != 0) continue;
            const shape = (try db.get(queries.FunctionShape, item)).* orelse return error.InvalidStandardLibrary;
            if (shape.returns_type) continue;
            try instances.put(allocator, .{ .item = item }, {});
        }
    }
    var next: usize = 0;
    while (next < instances.count()) : (next += 1) {
        const instance = instances.keys()[next];
        const compiled = (try db.get(queries.CompileFunction, instance)).* orelse {
            const location = try db.lookupInterned(queries.ItemLocations, instance.item);
            std.debug.print("cannot precompile std callable {s}\n", .{location.name.text()});
            const diagnostics = try db.transitiveAccumulatorValues(queries.CompileFunction, instance, structures.Diagnostic, allocator);
            defer allocator.free(diagnostics);
            for (diagnostics) |diagnostic| std.debug.print("{any}\n", .{diagnostic});
            return error.InvalidStandardLibrary;
        };
        for (compiled.referenced_instances) |referenced| try instances.put(allocator, referenced, {});
    }
    return bundle.encode(db, allocator);
}
