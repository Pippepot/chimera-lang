const std = @import("std");
const sources = @import("test_sources");
const modules = sources.modules;
const queries = sources.queries;
const query = sources.query;
const artifact = sources.query_artifact;
const bundle = sources.standard_bundle_loader;
const structures = sources.structures;

test "portable functions remap files and interned identities and recompute after edits" {
    const allocator = std.testing.allocator;
    const library: modules.SourceFile = .{ .path = "lib/answer.chi", .module_path = "lib", .source =
        \\pub struct Pair
        \\    value: int
        \\pub func answer() int
        \\    const pair = Pair{value = 40}
        \\    return pair.value + 2
    };
    const first = try sources.SourceFixture.initFiles("import lib\nexit(lib.answer())", &.{library});
    defer first.deinit();
    try first.db.addInput(queries.InlineLimit, {}, 0);
    _ = try first.executable(0);
    const bytes = try artifact.encode(first.db, allocator);
    defer allocator.free(bytes);

    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    try db.addInput(queries.InlineLimit, {}, 0);
    var registry: modules.SourceRegistry = .{ .entry_path = "another.chi" };
    defer registry.deinit(allocator);
    const padding: modules.SourceFile = .{ .path = "extra.chi", .module_path = "", .source = "struct Unrelated\n    value: bool" };
    const entry = "import lib\nexit(lib.answer())";
    try registry.update(db, allocator, entry, &.{ padding, library }, &.{});
    // Seed unrelated declarations and types to force different intern IDs.
    _ = try db.get(queries.ModuleDeclarations, try db.intern(queries.ModulePaths, .{ .path = "" }));
    _ = try db.intern(queries.Types, .{ .array = .{ .element_type = .byte, .length = 7 } });
    try std.testing.expectEqual(@as(structures.FileId, 2), registry.fileId(library.path).?);
    const imported = try artifact.restore(db, bytes, &registry);
    try std.testing.expect(imported.bodies > 0);
    try std.testing.expect(imported.functions > 0);
    const module = try db.intern(queries.ModulePaths, .{ .path = "lib" });
    const item = (try db.get(queries.ModuleDeclarations, module)).*.?.resolve("answer").?;
    const before = profile.snapshot();
    _ = try db.get(queries.CompileFunction, .{ .item = item });
    _ = try db.get(queries.AnalyzeFunctionInstance, .{ .item = item });
    const after = profile.snapshot();
    try std.testing.expectEqual(before.get(.codegen).runs, after.get(.codegen).runs);
    try std.testing.expectEqual(before.get(.body_typing).runs, after.get(.body_typing).runs);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
    var edited = library;
    edited.source = "pub struct Pair\n    value: int\npub func answer() int -> 43";
    try registry.update(db, allocator, entry, &.{ library, padding }, &.{});
    try fixture.expectExit(0, 42);
    try registry.update(db, allocator, entry, &.{ padding, edited }, &.{});
    try fixture.expectExit(0, 43);
}

test "bundled std reuses native functions on a fresh project without disk caching" {
    const allocator = std.testing.allocator;
    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{ .entry_path = "fresh.chi" };
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "import std.math\nexit(std.math.clamp(50, 0, 42))", &.{.{ .path = "unrelated/extra.chi", .module_path = "unrelated", .source = "" }}, &.{});
    const loader = try bundle.install(db, sources.standard_bundle);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().functions);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().bodies);
    for (loader.identities.interns.items) |identity| try std.testing.expect(!identity.ready);
    const before = profile.snapshot();
    try std.testing.expectEqual(@as(usize, 0), before.get(.codegen).runs);
    try std.testing.expectEqual(@as(usize, 0), before.get(.body_typing).runs);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
    const after = profile.snapshot();
    try std.testing.expectEqual(@as(usize, 1), loader.stats().functions);
    // Unrelated std functions and their interned identities stay undecoded.
    var undecoded: usize = 0;
    for (loader.identities.interns.items) |identity| if (!identity.ready) {
        undecoded += 1;
    };
    try std.testing.expect(undecoded > 0);
    // Only the project's entry needs code generation; it inlines clamp, min,
    // and max from bundled bodies, and exit already has a native artifact.
    try std.testing.expectEqual(@as(usize, 1), after.get(.codegen).runs - before.get(.codegen).runs);
    const math = try db.intern(queries.ModulePaths, .{ .path = "std.math" });
    const scope = (try db.get(queries.ModuleDeclarations, math)).*.?;
    const instance: structures.InstanceId = .{ .item = scope.resolve("clamp").? };
    const loaded = loader.stats().bodies;
    try std.testing.expect(loaded != 0);
    const body = try db.get(queries.AnalyzeFunctionInstance, instance);
    try std.testing.expect(body.* != null);
    try std.testing.expectEqual(loaded, loader.stats().bodies);
    try std.testing.expectEqual(after.get(.body_typing).runs, profile.snapshot().get(.body_typing).runs);
    try std.testing.expect(body == try db.get(queries.AnalyzeFunctionInstance, instance));
    try std.testing.expectEqual(loaded, loader.stats().bodies);
}

test "bundled std restores optimizer bodies and call components without running passes" {
    const allocator = std.testing.allocator;
    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{ .entry_path = "fresh.chi" };
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "import std.math\nexit(std.math.clamp(50, 0, 42))", &.{.{ .path = "extra.chi", .module_path = "", .source = "struct Extra\n    value: bool" }}, &.{});
    // Force translation of both source locations and interned identities.
    _ = try db.get(queries.ModuleDeclarations, try db.intern(queries.ModulePaths, .{ .path = "" }));
    _ = try db.intern(queries.Types, .{ .array = .{ .element_type = .byte, .length = 7 } });
    const loader = try bundle.install(db, sources.standard_bundle);
    const math = try db.intern(queries.ModulePaths, .{ .path = "std.math" });
    const scope = (try db.get(queries.ModuleDeclarations, math)).*.?;
    const clamp: structures.InstanceId = .{ .item = scope.resolve("clamp").? };
    const prepared = try db.get(queries.PrepareFunctionInstance, clamp);
    const component = try db.get(queries.CallComponent, clamp);
    const optimized = try db.get(queries.OptimizeFunctionInstance, clamp);
    try std.testing.expect(prepared.* != null);
    try std.testing.expectEqual(@as(usize, 0), component.*.?.members.len);
    try std.testing.expect(optimized.* != null);
    try std.testing.expectEqual(@as(usize, 1), loader.stats().prepared);
    try std.testing.expectEqual(@as(usize, 1), loader.stats().components);
    try std.testing.expectEqual(@as(usize, 1), loader.stats().optimized);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().bodies);
    try std.testing.expectEqual(@as(usize, 0), profile.snapshot().get(.body_typing).runs);
    try std.testing.expectEqual(@as(usize, 0), profile.snapshot().get(.optimization_setup).runs);
    try std.testing.expectEqual(@as(usize, 0), profile.snapshot().get(.optimization_inline).runs);
    try std.testing.expectEqual(optimized, try db.get(queries.OptimizeFunctionInstance, clamp));
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
    try std.testing.expectEqual(@as(usize, 1), loader.stats().optimized);
}

test "bundled std tracks inline policy for optimized bodies and native functions" {
    const allocator = std.testing.allocator;
    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "import std.math\nexit(std.math.clamp(50, 0, 42))", &.{}, &.{});
    const loader = try bundle.install(db, sources.standard_bundle);
    const math = try db.intern(queries.ModulePaths, .{ .path = "std.math" });
    const scope = (try db.get(queries.ModuleDeclarations, math)).*.?;
    const clamp: structures.InstanceId = .{ .item = scope.resolve("clamp").? };
    const prepared = try db.get(queries.PrepareFunctionInstance, clamp);
    const optimized = (try db.get(queries.OptimizeFunctionInstance, clamp)).*.?;
    try std.testing.expectEqual(@as(usize, 0), directCalls(optimized));
    _ = try db.get(queries.CompileFunction, clamp);
    try std.testing.expectEqual(@as(usize, 1), loader.stats().functions);
    const before = profile.snapshot();

    // The initial input was absent. Adding an override must invalidate both
    // optimized IR and native code, while retaining policy-independent IR.
    try db.addInput(queries.InlineLimit, {}, 0);
    const out_of_line = (try db.get(queries.OptimizeFunctionInstance, clamp)).*.?;
    try std.testing.expectEqual(@as(usize, 2), directCalls(out_of_line));
    try std.testing.expectEqual(@as(usize, 1), loader.stats().optimized);
    try std.testing.expectEqual(prepared, try db.get(queries.PrepareFunctionInstance, clamp));
    _ = try db.get(queries.CompileFunction, clamp);
    try std.testing.expect(profile.snapshot().get(.codegen).runs > before.get(.codegen).runs);
    try std.testing.expectEqual(@as(usize, 1), loader.stats().functions);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);

    try db.setInput(queries.InlineLimit, {}, queries.default_inline_limit);
    const inlined = (try db.get(queries.OptimizeFunctionInstance, clamp)).*.?;
    try std.testing.expectEqual(@as(usize, 0), directCalls(inlined));
    try std.testing.expectEqual(@as(usize, 2), loader.stats().optimized);
    const restored = profile.snapshot();
    _ = try db.get(queries.CompileFunction, clamp);
    try std.testing.expectEqual(restored.get(.codegen).runs, profile.snapshot().get(.codegen).runs);
    try std.testing.expectEqual(@as(usize, 2), loader.stats().functions);
    try fixture.expectExit(0, 42);
}

fn directCalls(body: structures.FunctionBodyAnalysis) usize {
    var calls: usize = 0;
    for (body.instructions) |instruction| if (instruction == .call and instruction.call.target == .direct) {
        calls += 1;
    };
    return calls;
}

test "unused std functions and identities remain undecoded" {
    const fixture = try sources.SourceFixture.init("const answer = 42");
    defer fixture.deinit();
    const loader = try bundle.install(fixture.db, sources.standard_bundle);
    try fixture.expectExit(0, 0);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().functions);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().bodies);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().prepared);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().components);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().optimized);
    try std.testing.expect(loader.current_files == null);
    for (loader.identities.interns.items) |identity| try std.testing.expect(!identity.ready);
}

test "bundled std remains optional in a database without registered std sources" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{ .entry_path = "bare.chi" };
    defer registry.deinit(allocator);
    const loader = try bundle.install(db, sources.standard_bundle);
    try std.testing.expectEqual(@as(queries.StandardLibraryUnchanged.Output, null), (try db.get(queries.StandardLibraryUnchanged, {})).*);
    const imported = loader.stats();
    try std.testing.expectEqual(@as(usize, 0), imported.bodies);
    try std.testing.expectEqual(@as(usize, 0), imported.functions);
}

test "bundled std preserves text IO ownership and new generic specializations" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    try registry.update(db, allocator,
        \\var values: List(int) = [20, 22]
        \\print(values[0] + values[1])
        \\print(String(values))
        \\for value in 0..3 -> print(value)
    , &.{}, &.{});
    _ = try bundle.install(db, sources.standard_bundle);
    const fixture: sources.SourceFixture = .{ .db = db };
    const result = try fixture.runIo("");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("42\n[20, 22]\n0\n1\n2\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "bundled std preserves panic traces after file renumbering" {
    const allocator = std.testing.allocator;
    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{ .entry_path = "fresh.chi" };
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "const cursor = (0..).iter()", &.{.{ .path = "extra.chi", .module_path = "", .source = "" }}, &.{});
    _ = try bundle.install(db, sources.standard_bundle);
    const fixture: sources.SourceFixture = .{ .db = db };
    const result = try fixture.runIo("");
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "panic: range iteration requires both endpoints as absolute integers\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "$std/range.chi:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "at <entry> (fresh.chi:") != null);
    // The failing library function and its dependencies remain precompiled.
    try std.testing.expectEqual(@as(usize, 1), profile.snapshot().get(.codegen).runs);
}

test "bundled std rejects changed dependencies before importing native code" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "import std.math\nexit(std.math.clamp(50, 0, 42))", &.{}, &.{});
    const math_file = registry.fileId("$std/math.chi").?;
    try db.setInput(queries.SourceText, math_file, "pub func clamp(value: int, lower: int, upper: int) int -> 43");
    _ = try bundle.install(db, sources.standard_bundle);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 43);
}

test "bundled std retains native code across unrelated modules and invalidates std edits" {
    const allocator = std.testing.allocator;
    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    const entry = "import std.math\nexit(std.math.clamp(50, 0, 42))";
    try registry.update(db, allocator, entry, &.{}, &.{});
    _ = try bundle.install(db, sources.standard_bundle);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
    const before = profile.snapshot();
    try registry.update(db, allocator, entry, &.{.{ .path = "other/unused.chi", .module_path = "other", .source = "pub static unused = 7" }}, &.{});
    try fixture.expectExit(0, 42);
    const after = profile.snapshot();
    try std.testing.expectEqual(before.get(.codegen).runs, after.get(.codegen).runs);
    try db.setInput(queries.SourceText, registry.fileId("$std/math.chi").?, "pub func clamp(value: int, lower: int, upper: int) int -> 43");
    try fixture.expectExit(0, 43);
}

test "portable snapshots remap the shared std validation boundary" {
    const allocator = std.testing.allocator;
    const original = try sources.SourceFixture.init("");
    defer original.deinit();
    var original_registry: modules.SourceRegistry = .{};
    defer original_registry.deinit(allocator);
    try original_registry.update(original.db, allocator, "", &.{}, &.{});
    _ = try bundle.install(original.db, sources.standard_bundle);
    const module = try original.db.intern(queries.ModulePaths, .{ .path = "std.math" });
    const scope = (try original.db.get(queries.ModuleDeclarations, module)).*.?;
    const clamp: structures.InstanceId = .{ .item = scope.resolve("clamp").? };
    // Demand both memo shapes so the snapshot exercises the shared boundary.
    _ = try original.db.get(queries.AnalyzeFunctionInstance, clamp);
    _ = try original.db.get(queries.CompileFunction, clamp);
    const bytes = try artifact.encode(original.db, allocator);
    defer allocator.free(bytes);
    const db = try query.Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{ .entry_path = "second.chi" };
    defer registry.deinit(allocator);
    try registry.update(db, allocator, "import std.math\nexit(std.math.clamp(50, 0, 42))", &.{.{ .path = "other.chi", .module_path = "", .source = "" }}, &.{});
    const imported = try artifact.restore(db, bytes, &registry);
    try std.testing.expect(imported.bodies > 0);
    try std.testing.expect(imported.functions > 0);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
}

test "lazy std refreshes identities after registered file numbers change" {
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    const entry = "import std.math\nexit(std.math.clamp(50, 0, 42))";
    try registry.update(db, allocator, entry, &.{}, &.{});
    const loader = try bundle.install(db, sources.standard_bundle);
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
    const before = loader.stats();
    var reassigned: modules.SourceRegistry = .{};
    defer reassigned.deinit(allocator);
    for (modules.standard_sources, 0..) |source, index| {
        const path = try allocator.dupe(u8, source.registry_path);
        errdefer allocator.free(path);
        try reassigned.paths.put(allocator, path, @intCast(100 + index));
    }
    try reassigned.update(db, allocator, entry, &.{}, &.{});
    try fixture.expectExit(0, 42);
    try std.testing.expect(loader.stats().functions > before.functions);
    try std.testing.expect(loader.stats().optimized > before.optimized);
    try db.setInput(queries.SourceText, reassigned.fileId("$std/math.chi").?, "pub func clamp(value: int, lower: int, upper: int) int -> 43");
    try fixture.expectExit(0, 43);
}

test "lazy std handles both existing orders of nominal variant members" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |reverse| {
        const db = try query.Database.init(allocator, .{ .worker_count = 2 });
        defer db.deinit();
        var registry: modules.SourceRegistry = .{};
        defer registry.deinit(allocator);
        try registry.update(db, allocator, "print(42)", &.{}, &.{});
        const module = try db.intern(queries.ModulePaths, .{ .path = "std.text" });
        const scope = (try db.get(queries.ModuleDeclarations, module)).*.?;
        const names: [2][]const u8 = if (reverse) .{ "OwnedBytes", "StaticString" } else .{ "StaticString", "OwnedBytes" };
        for (names) |name| _ = try queries.internStructType(db, scope.resolve(name).?);
        _ = try bundle.install(db, sources.standard_bundle);
        const fixture: sources.SourceFixture = .{ .db = db };
        const result = try fixture.runIo("");
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        try std.testing.expectEqualStrings("42\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "truncated std indexes release installation state and permit retry" {
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 0 });
    defer db.deinit();
    try std.testing.expectError(error.InvalidCache, bundle.install(db, sources.standard_bundle[0 .. sources.standard_bundle.len - 1]));
    const loader = try bundle.install(db, sources.standard_bundle);
    try std.testing.expectEqual(@as(usize, 0), loader.stats().functions);
}

test "portable artifacts recompute conditional and match tags when canonical member order changes" {
    const allocator = std.testing.allocator;
    const library: modules.SourceFile = .{ .path = "lib/choice.chi", .module_path = "lib", .source =
        \\pub struct A
        \\    copy = trivial
        \\    pub value: int
        \\pub struct B
        \\    copy = trivial
        \\    pub value: int
        \\pub func answer(choice: A | B) int
        \\    if const selected: A = choice -> return selected.value
        \\    return 0
        \\pub func match_answer(choice: A | B) int
        \\    return match choice
        \\        B ->
        \\            if const selected: B = choice -> return selected.value
        \\            return 91
        \\        A -> 0
    };
    const entry = "import lib\nexit(lib.answer(lib.A{value = 19}) + lib.match_answer(lib.B{value = 23}))";
    const first = try sources.SourceFixture.initFiles(entry, &.{library});
    defer first.deinit();
    try first.expectExit(0, 42);
    const bytes = try artifact.encode(first.db, allocator);
    defer allocator.free(bytes);
    var profile: sources.profiling.Collector = .{ .io = std.testing.io };
    const db = try query.Database.init(allocator, .{ .worker_count = 0, .profile = &profile });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    try registry.update(db, allocator, entry, &.{library}, &.{});
    const module = try db.intern(queries.ModulePaths, .{ .path = "lib" });
    const scope = (try db.get(queries.ModuleDeclarations, module)).*.?;
    const b = try queries.internStructType(db, scope.resolve("B").?);
    const a = try queries.internStructType(db, scope.resolve("A").?);
    try std.testing.expect(@backingInt(b) < @backingInt(a));
    _ = try artifact.restore(db, bytes, &registry);
    const before = profile.snapshot();
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
    const after = profile.snapshot();
    try std.testing.expect(after.get(.codegen).runs > before.get(.codegen).runs);
}

test "truncated portable artifacts release partially decoded records" {
    const allocator = std.testing.allocator;
    const source = "func answer() int -> 42\nexit(answer())";
    const original = try sources.SourceFixture.init(source);
    defer original.deinit();
    _ = try original.executable(0);
    const bytes = try artifact.encode(original.db, allocator);
    defer allocator.free(bytes);
    const db = try query.Database.init(allocator, .{ .worker_count = 0 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(allocator);
    try registry.update(db, allocator, source, &.{}, &.{});
    try std.testing.expectError(error.InvalidCache, artifact.restore(db, bytes[0 .. bytes.len - 1], &registry));
    const fixture: sources.SourceFixture = .{ .db = db };
    try fixture.expectExit(0, 42);
}
