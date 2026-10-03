const std = @import("std");
const cache = @import("cache.zig");
const modules = @import("modules.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const query_disk_cache = @import("query_disk_cache.zig");
const structures = @import("structures.zig");
const runtime = @import("runtime.zig");
const standard_library = @import("standard_library");

const Fixture = struct {
    db: *query.Database,

    fn restore(source: []const u8) !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const first = try query.Database.init(allocator, .{ .worker_count = 2 });
        defer first.deinit();
        try modules.registerSources(first, allocator, source, &.{}, &.{});
        const original = try executable(first);
        const original_body = try functionBody(first, "run");
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(directory);
        const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &.{});
        try query_disk_cache.save(io, allocator, directory, digest, first);
        const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
        defer allocator.free(payload);
        const second = try query.Database.init(allocator, .{ .worker_count = 2 });
        errdefer second.deinit();
        const offset = try query_disk_cache.restoreInterns(second, allocator, payload);
        try modules.registerSources(second, allocator, source, &.{}, &.{});
        try std.testing.expect(try query_disk_cache.restoreQueries(second, payload, offset) > 0);
        if (!structures.FunctionBodyAnalysis.eql(original_body.*.?, (try functionBody(second, "run")).*.?)) {
            std.debug.print("restored run body changed\n", .{});
            return error.TestUnexpectedResult;
        }
        const restored = try executable(second);
        try std.testing.expectEqualSlices(u8, original.bytes, restored.bytes);
        return .{ .db = second };
    }

    fn functionBody(db: *query.Database, name: []const u8) !*const ?structures.FunctionBodyAnalysis {
        const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
        return db.get(queries.AnalyzeFunctionInstance, .{ .item = scope.resolveFunction(name).? });
    }

    fn expectExit(self: Fixture, status: u8) !void {
        const artifact = try executable(self.db);
        try runtime.writeProgram(std.testing.io, artifact.bytes);
        defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
        try std.testing.expectEqual(status, try runtime.runProg(std.testing.io, std.testing.allocator, &.{}));
    }

    fn executable(db: *query.Database) !structures.Executable {
        if ((try db.get(queries.BuildExecutable, 0)).*) |artifact| return artifact;
        const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        for (diagnostics) |diagnostic| std.debug.print("file {d} at {d}: {s}\n", .{ diagnostic.file_id, if (diagnostic.span) |span| span.start else 0, @tagName(diagnostic.kind) });
        std.debug.print("compiler returned no executable\n", .{});
        return error.TestUnexpectedResult;
    }
};

test "infallible initializer consumers handle failure and survive snapshots" {
    const source =
        \\fallible materialize(init item: int) int -> item
        \\func recover(init item: int) int
        \\    if const value = materialize(item) -> return value
        \\    return 40
        \\func run() int
        \\    const callback: func(init int) int = recover
        \\    const first = callback(if 1 == 1 -> fail else 0)
        \\    return first + callback(2)
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "initializer failure writes survive snapshots and failure single use and mode edits" {
    const allocator = std.testing.allocator;
    const source =
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(materialize(item))
        \\func run() int
        \\    var value = 0
        \\    const callback: fallible(init int) int = forward
        \\    if callback(if true == true
        \\        value = 42
        \\        fail
        \\    else 0) -> return 99
        \\    return value
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const second = fixture.db;
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(second, "materialize");

    const effect_edit = try std.mem.replaceOwned(u8, allocator, source, "value = 42", "value = 41");
    defer allocator.free(effect_edit);
    try second.setInput(queries.SourceText, 0, effect_edit);
    try fixture.expectExit(40);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(second, "materialize"));

    const failure_edit = try std.mem.replaceOwned(u8, allocator, source, "        fail", "        7");
    defer allocator.free(failure_edit);
    try second.setInput(queries.SourceText, 0, failure_edit);
    try fixture.expectExit(156);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(second, "materialize"));

    const single_use_edit = try std.mem.replaceOwned(u8, allocator, source, "fallible forward(init item: int) int -> return materialize(materialize(item))", "fallible forward(init item: int) int\n    const first = materialize(item)\n    return materialize(item)");
    defer allocator.free(single_use_edit);
    try second.setInput(queries.SourceText, 0, single_use_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);

    const mode_edit = try std.mem.replaceOwned(u8, allocator, source, "init item", "imm item");
    defer allocator.free(mode_edit);
    try second.setInput(queries.SourceText, 0, mode_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    const signature_edit = try std.mem.replaceOwned(u8, allocator, source, "fallible(init int) int", "fallible(init bool) bool");
    defer allocator.free(signature_edit);
    try second.setInput(queries.SourceText, 0, signature_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    try second.setInput(queries.SourceText, 0, source);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* != null);
}

test "initializer capture effects survive snapshots and capability edits" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Item
        \\    value: int
        \\    move = trivial
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 2 -> return else exit(99)
        \\fallible materialize(init item: Item) Item -> return item
        \\fallible forward(init item: Item) Item -> return materialize(item)
        \\fallible run() int
        \\    var value = 1
        \\    const source = Item{value = 2}
        \\    const callback: fallible(init Item) Item = forward
        \\    const result = callback(if true == true
        \\        value = 40
        \\        source^
        \\    else Item{value = 0})
        \\    return value + result.value
        \\if const result = run() -> exit(result) else exit(98)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const second = fixture.db;
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(second, "materialize");
    const effect_edit = try std.mem.replaceOwned(u8, allocator, source, "value = 40", "value = 39");
    defer allocator.free(effect_edit);
    try second.setInput(queries.SourceText, 0, effect_edit);
    try fixture.expectExit(41);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(second, "materialize"));
    const capability_edit = try std.mem.replaceOwned(u8, allocator, source, "move = trivial", "move = none");
    defer allocator.free(capability_edit);
    try second.setInput(queries.SourceText, 0, capability_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    const mode_edit = try std.mem.replaceOwned(u8, allocator, source, "init item", "imm item");
    defer allocator.free(mode_edit);
    try second.setInput(queries.SourceText, 0, mode_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    try second.setInput(queries.SourceText, 0, source);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* != null);
}

test "initializer regions and native callbacks survive cache reuse and mode edits" {
    const allocator = std.testing.allocator;
    const source =
        \\fallible produce(imm value: int) int
        \\    value > 0
        \\    return value
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\func run(imm base: int) int
        \\    var offset = 2
        \\    const callback: fallible(init int) int = forward
        \\    if const value = callback(materialize(produce(base + offset))) -> return value
        \\    return 0
        \\exit(run(40))
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const second = fixture.db;
    try fixture.expectExit(42);
    const body = (try Fixture.functionBody(second, "run")).*.?;
    try std.testing.expect(body.initializer_regions.len > 0);
    try std.testing.expect(body.initializer_regions[0].initializer_regions.len > 0);

    const edited = try std.mem.replaceOwned(u8, allocator, source, "init item", "imm item");
    defer allocator.free(edited);
    try second.setInput(queries.SourceText, 0, edited);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try second.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, allocator);
    defer allocator.free(diagnostics);
    var rejected_mode = false;
    for (diagnostics) |diagnostic| if (diagnostic.kind == .local_type_mismatch) {
        rejected_mode = true;
    };
    try std.testing.expect(rejected_mode);
}

test "allocating initializer snapshots retain named return hooks and invalidate capabilities and single use" {
    const source =
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\    move = func(deinit self: Item) Item -> Item{value = self.value + 2}
        \\static Owner = Box(Item)
        \\static create = Owner.new
        \\fallible own(init item: Item) Box(Item) -> create(item)
        \\func copied() Item
        \\    const local = Item{value = 19}
        \\    return local
        \\func moved() Item
        \\    const local = Item{value = 20}
        \\    return local^
        \\fallible run() int
        \\    const callback: fallible(init Item) Box(Item) = own
        \\    const first = callback(copied())
        \\    const second = callback(moved())
        \\    return first.borrow()[].value + second.borrow()[].value
        \\if const value = run() -> exit(value) else exit(99)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(fixture.db, "own");
    const hook_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.value + 1", "self.value + 2");
    defer std.testing.allocator.free(hook_edit);
    try fixture.db.setInput(queries.SourceText, 0, hook_edit);
    try fixture.expectExit(43);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(fixture.db, "own"));
    for ([_][]const u8{
        "copy = func(imm self: Item) Item -> Item{value = self.value + 1}",
        "move = func(deinit self: Item) Item -> Item{value = self.value + 2}",
        "fallible own(init item: Item) Box(Item) -> create(item)",
    }, [_][]const u8{
        "copy = none",
        "move = none",
        "fallible own(init item: Item) Box(Item)\n    const first = create(item)\n    return create(item)",
    }) |original, replacement| {
        const edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, original, replacement);
        defer std.testing.allocator.free(edit);
        try fixture.db.setInput(queries.SourceText, 0, edit);
        try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    }
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "allocating initializer snapshots retain skipped evaluation after allocator edits" {
    const source =
        \\func forbidden() int -> exit(90)
        \\func run() int
        \\    const callback: fallible(init int) Box(int) = Box(int).new
        \\    if callback(forbidden()) -> return 1
        \\    return 42
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(90);
    const body = try Fixture.functionBody(fixture.db, "run");
    const allocation_file = (try fixture.db.input(queries.StandardFile, @intFromEnum(standard_library.File.memory_allocation))).*;
    const allocation_source = (try fixture.db.input(queries.SourceText, allocation_file)).*;
    const edit = try std.mem.replaceOwned(u8, std.testing.allocator, allocation_source, "var storage = allocate(T, 1)", "var storage = allocate(T, -1)");
    defer std.testing.allocator.free(edit);
    try fixture.db.setInput(queries.SourceText, allocation_file, edit);
    try fixture.expectExit(42);
    try std.testing.expectEqual(body, try Fixture.functionBody(fixture.db, "run"));
    try fixture.db.setInput(queries.SourceText, allocation_file, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(90);
}

test "allocating initializer snapshots retain partial cleanup and consumption on failure" {
    for ([_][]const u8{ "fail_value()", "fail" }) |completion| {
        errdefer std.debug.print("allocating completion: {s}\n", .{completion});
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\struct Leaf
            \\    count: Ref(int, true)
            \\    move = fieldwise
            \\    copy = none
            \\    drop = func(deinit self: Leaf)
            \\        self.count[] = self.count[] + 1
            \\struct Item
            \\    move = none
            \\    first: Leaf
            \\    second: int
            \\fallible fail_value() int
            \\    1 == 0
            \\    return 0
            \\fallible run() int
            \\    var count = Box.new(40)
            \\    const callback: fallible(init Item) Box(Item) = Box(Item).new
            \\    const leaf = Leaf{{count = count.borrow_mut()}}
            \\    if callback(Item{{first = leaf^, second = if true == true -> {s} else 0}}) -> return 99
            \\    return count.borrow()[] + 1
            \\if const result = run() -> exit(result) else exit(98)
        , .{completion});
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Box.new(40)", "Box.new(39)");
        defer std.testing.allocator.free(edit);
        try fixture.db.setInput(queries.SourceText, 0, edit);
        try fixture.expectExit(41);
    }
}

test "raw slot initializer snapshots retain immovable destruction and recompute hooks and modes" {
    const source =
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Item
        \\    move = none
        \\    value: int
        \\    drop = func(deinit self: Item) -> exit(self.value)
        \\func make(value: int) Item -> Item{value = value}
        \\fallible initialize(mut storage: Allocation(Item), init item: Item) -> storage.unsafe_init(1, item)
        \\fallible run()
        \\    var storage = allocate(Item, 2)
        \\    const callback: fallible(mut Allocation(Item), init Item) unit = initialize
        \\    if callback(storage, make(42)) -> ()
        \\    else
        \\        deallocate(Item, storage)
        \\        fail
        \\    storage.unsafe_drop(1)
        \\    deallocate(Item, storage)
        \\if run() -> exit(99) else exit(98)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(fixture.db, "initialize");
    const hook_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "exit(self.value)", "exit(self.value + 1)");
    defer std.testing.allocator.free(hook_edit);
    try fixture.db.setInput(queries.SourceText, 0, hook_edit);
    try fixture.expectExit(43);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(fixture.db, "initialize"));
    const mode_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "init Item", "imm Item");
    defer std.testing.allocator.free(mode_edit);
    try fixture.db.setInput(queries.SourceText, 0, mode_edit);
    try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}
