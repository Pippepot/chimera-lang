const std = @import("std");
const test_sources = @import("test_sources");
const cache = test_sources.cache;
const modules = test_sources.modules;
const query = test_sources.query;
const queries = test_sources.queries;
const query_disk_cache = test_sources.query_disk_cache;
const structures = test_sources.structures;
const standard_library = @import("standard_library");

test "panic snapshots distinguish static arguments even when machine code is equal" {
    const source = "func stop(static N: int) int -> panic\nfunc run() int -> stop(1)\nexit(run())";
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const source_fixture: test_sources.SourceFixture = .{ .db = fixture.db };
    const original = try source_fixture.runIo("");
    defer std.testing.allocator.free(original.stdout);
    defer std.testing.allocator.free(original.stderr);
    try std.testing.expect(std.mem.indexOf(u8, original.stderr, "at stop(1) ") != null);
    const edited_source = try std.mem.replaceOwned(u8, std.testing.allocator, source, "stop(1)", "stop(2)");
    defer std.testing.allocator.free(edited_source);
    try fixture.db.setInput(queries.SourceText, 0, edited_source);
    const edited = try source_fixture.runIo("");
    defer std.testing.allocator.free(edited.stdout);
    defer std.testing.allocator.free(edited.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, edited.term);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "at stop(2) ") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "stop(1)") == null);
}

test "panic snapshots restore traces and refresh messages and source locations" {
    const source = "func run() int -> panic \"original\"\nexit(run())";
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const source_fixture: test_sources.SourceFixture = .{ .db = fixture.db };
    const original = try source_fixture.runIo("");
    defer std.testing.allocator.free(original.stdout);
    defer std.testing.allocator.free(original.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, original.term);
    try std.testing.expect(std.mem.indexOf(u8, original.stderr, "panic: original\n  at run (main.chi:1:19)") != null);
    try fixture.db.setInput(queries.SourceText, 0, "\nfunc run() int -> panic \"edited\"\nexit(run())");
    try fixture.db.setInput(queries.SourcePath, 0, "renamed.chi");
    const edited = try source_fixture.runIo("");
    defer std.testing.allocator.free(edited.stdout);
    defer std.testing.allocator.free(edited.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, edited.term);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "panic: edited\n  at run (renamed.chi:2:19)") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "main.chi") == null);
    try fixture.db.setInput(queries.SourceText, 0, "func run() int -> 42\nexit(run())");
    try fixture.expectExit(42);
}

test "tuple snapshots restore values reference alternatives and member-kind edits" {
    const source =
        \\func pair() (int, int) -> (12, 30)
        \\static answer = pair()
        \\func capture(ref owner: int) ref int | End -> owner
        \\func run() int
        \\    var owner = answer.0
        \\    var carrier: ref int | End = capture(owner)
        \\    if ref item = carrier as int
        \\        carrier = End{}
        \\        item += answer.1
        \\        return owner
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "(12, 30)", "(13, 30)");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(43);
    const owned = try std.mem.replaceOwned(u8, std.testing.allocator, source, "ref int | End", "int | End");
    defer std.testing.allocator.free(owned);
    try fixture.db.setInput(queries.SourceText, 0, owned);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "readonly aggregate snapshots preserve independent owned and reference permissions" {
    const source =
        \\struct Views
        \\    copy = trivial
        \\    view: Span(int)
        \\    target: Ref(int)
        \\func snapshot(imm source: Views) Views -> source
        \\fallible calculate() int
        \\    var values = [19, 23]
        \\    var target = 41
        \\    var owner = Box.new?(snapshot(Views{view = values.span(), target = Ref.from(target)}))
        \\    ref copied = owner.borrow()
        \\    copied.target.value += 1
        \\    return copied.view[0] + copied.view[1] + target - 42
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "copied.target.value += 1", "copied.view[0] = 1");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "temporal reference snapshots recompute aliasing and mutation effects" {
    const source =
        \\struct Captures(T: type)
        \\    left: Ref(T)
        \\    right: Ref(T)
        \\fallible inspect(captures: Captures(String)) int
        \\    const view = captures.left.value.view()
        \\    captures.right.value.append?("x")
        \\    return view.byte_length() + 39
        \\fallible calculate() int
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    const captures = Captures(String){left = Ref.from(left), right = Ref.from(right)}
        \\    return inspect?(captures)
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const original = (try Fixture.functionBody(fixture.db, "inspect")).*.?;
    try std.testing.expect(original.reference_contract.exclusions.len > 0);
    const aliased = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Ref.from(right)", "Ref.from(left)");
    defer std.testing.allocator.free(aliased);
    try fixture.db.setInput(queries.SourceText, 0, aliased);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    const no_mutation = try std.mem.replaceOwned(u8, std.testing.allocator, aliased, "captures.right.value.append?(\"x\")", "_ = 0");
    defer std.testing.allocator.free(no_mutation);
    try fixture.db.setInput(queries.SourceText, 0, no_mutation);
    try fixture.expectExit(42);
    try std.testing.expectEqual(@as(usize, 0), (try Fixture.functionBody(fixture.db, "inspect")).*.?.reference_contract.exclusions.len);
    try fixture.db.setInput(queries.SourceText, 0, aliased);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "destructor snapshots recompute captured authority and mutation effects" {
    const source =
        \\struct Observer
        \\    owner: Ref(String)
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Observer)
        \\        self.trace.value += self.owner.value.byte_length()
        \\func discard(var observer: Observer) -> ()
        \\fallible calculate() int
        \\    var owner: String = "abc"
        \\    const view = owner.view()
        \\    var trace = 0
        \\    discard(Observer{owner = Ref.from(owner), trace = Ref.from(trace)})
        \\    return view.byte_length() + trace + 36
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const mutation = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.trace.value += self.owner.value.byte_length()", "if self.owner.value.append(\"x\") -> ()");
    defer std.testing.allocator.free(mutation);
    try fixture.db.setInput(queries.SourceText, 0, mutation);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var owner:", "const owner:");
    defer std.testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectExit(42);
    const readonly_mutation = try std.mem.replaceOwned(u8, std.testing.allocator, mutation, "var owner:", "const owner:");
    defer std.testing.allocator.free(readonly_mutation);
    try fixture.db.setInput(queries.SourceText, 0, readonly_mutation);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "pull cursor snapshots recompute delivery kind effects and protocol methods" {
    const source =
        \\struct Cursor
        \\    position: int
        \\    value: int
        \\    func next(mut self: Cursor) int | End
        \\        if self.position >= 2 -> return End{}
        \\        self.position += 1
        \\        self.value += 1
        \\        return self.value
        \\func run() int
        \\    var cursor = Cursor{position = 0, value = 0}
        \\    var sum = 0
        \\    for ref item in cursor
        \\        item += 10
        \\        sum += item
        \\    return sum + cursor.value + 17
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const borrowed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "int | End", "ref int | End");
    defer std.testing.allocator.free(borrowed);
    try fixture.db.setInput(queries.SourceText, 0, borrowed);
    try fixture.expectExit(72);
    const fallible = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func next", "fallible next");
    defer std.testing.allocator.free(fallible);
    try fixture.db.setInput(queries.SourceText, 0, fallible);
    try fixture.expectDiagnostic(.fallible_expression_outside_fallible_function);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func next", "func advance");
    defer std.testing.allocator.free(missing);
    try fixture.db.setInput(queries.SourceText, 0, missing);
    try fixture.expectDiagnostic(.unknown_namespace_member);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "range iteration snapshots restore runtime and compile-time results and recompute endpoints" {
    const source =
        \\func run() int
        \\    var total = 36
        \\    for value in (0..^3).reversed() -> total += value
        \\    return total
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const exclusive = try std.mem.replaceOwned(u8, std.testing.allocator, source, "0..^3", "0..3");
    defer std.testing.allocator.free(exclusive);
    try fixture.db.setInput(queries.SourceText, 0, exclusive);
    try fixture.expectExit(36);
    const longer = try std.mem.replaceOwned(u8, std.testing.allocator, source, "0..^3", "0..^4");
    defer std.testing.allocator.free(longer);
    try fixture.db.setInput(queries.SourceText, 0, longer);
    try fixture.expectExit(50);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "cursor iteration snapshots track method edits explicit factories and missing operations" {
    const source =
        \\import std.range.{RangeIterator}
        \\struct Cursor
        \\    position: int
        \\    pub func next(mut self: Cursor) int | End
        \\        if self.position >= 3 -> return End{}
        \\        self.position += 1
        \\        return self.position * 7
        \\func run() int
        \\    var cursor = Cursor{position = 0}
        \\    var total = 0
        \\    for value in cursor
        \\        total += value
        \\        break
        \\    for value in cursor -> total += value
        \\    return total
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.position * 7", "self.position * 8");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(48);
    const factory = try std.mem.replaceOwned(u8, std.testing.allocator, source, "    pub func next",
        \\    pub func iter(ref self: Cursor) RangeIterator
        \\        const values = 0..^3
        \\        return values.iter()
        \\    pub func next
    );
    defer std.testing.allocator.free(factory);
    try fixture.db.setInput(queries.SourceText, 0, factory);
    try fixture.expectExit(6);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source, "pub func next", "pub func removed");
    defer std.testing.allocator.free(missing);
    try fixture.db.setInput(queries.SourceText, 0, missing);
    try fixture.expectDiagnostic(.unknown_namespace_member);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "text operations remainder and precise mutable calls survive snapshots and source edits" {
    const source =
        \\struct Named
        \\    pub name: StringView
        \\    pub value: int
        \\func touch(imm source: Named, mut target: Named)
        \\    target.value += source.value
        \\func run() int
        \\    var first = Named{
        \\        name = "first",
        \\        value = 19,
        \\    }
        \\    var second = Named{
        \\        name = "second",
        \\        value = 23,
        \\    }
        \\    touch(first, second)
        \\    touch(second, first)
        \\    if first.name <> "first" -> return 90
        \\    return second.value + first.value % second.value - 19
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "value = 19,", "value = 20,");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(46);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

const Fixture = struct {
    db: *query.Database,

    fn restore(source: []const u8) !Fixture {
        return restoreSources(source, &.{}, &.{}, null);
    }

    fn restoreSources(source: []const u8, files: []const modules.SourceFile, restored_files: []const modules.SourceFile, rejected: ?std.meta.Tag(structures.Diagnostic.Kind)) !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const first = try query.Database.init(allocator, .{ .worker_count = 2 });
        defer first.deinit();
        try modules.registerSources(first, allocator, source, files, &.{});
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
        try modules.registerSources(second, allocator, source, restored_files, &.{});
        try std.testing.expect(try query_disk_cache.restoreQueries(second, payload, offset) > 0);
        if (rejected) |kind| {
            const fixture: Fixture = .{ .db = second };
            try fixture.expectDiagnostic(kind);
            return fixture;
        }
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
        try (test_sources.SourceFixture{ .db = self.db }).expectExit(0, status);
    }

    fn expectDiagnostic(self: Fixture, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        try std.testing.expect((try self.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
        try std.testing.expectEqual(kind, std.meta.activeTag(diagnostics[0].kind));
    }

    fn executable(db: *query.Database) !structures.Executable {
        return (test_sources.SourceFixture{ .db = db }).executable(0);
    }
};

test "cursor snapshots restore literal and empty spans and recompute source edits" {
    const source =
        \\static empty = Span(int).empty().as_imm()
        \\static bytes: BytesView = "\u{e9}"
        \\func run() int
        \\    const values = [19, 23]
        \\    const view = values.span()
        \\    if ref first = view.get(0)
        \\        if ref second = view.get(1)
        \\            if ref literal = bytes.get(0)
        \\                return first + second + empty.len() + bytes.byte_length() - 2 + byte_int(literal) - 195
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "[19, 23]", "[20, 23]");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(44);
}

test "nested span snapshots recompute slice bounds extent and readonly backing" {
    const source =
        \\fallible select(ref source: Ref(Span(int))) Span(int) -> source.value.slice?(0..2)
        \\fallible calculate() int
        \\    var values = [5, 17, 23, 29, 7]
        \\    var source = values.span()
        \\    var middle = source.slice?(1..4)
        \\    const carrier = Ref.from(middle)
        \\    var nested = select?(carrier)
        \\    nested[0] = nested[0]
        \\    return nested[0] + nested[1] + nested.len()
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const shifted = try std.mem.replaceOwned(u8, std.testing.allocator, source, "source.slice?(1..4)", "source.slice?(2..5)");
    defer std.testing.allocator.free(shifted);
    try fixture.db.setInput(queries.SourceText, 0, shifted);
    try fixture.expectExit(66);
    const shortened = try std.mem.replaceOwned(u8, std.testing.allocator, source, "[5, 17, 23, 29, 7]", "[5, 17]");
    defer std.testing.allocator.free(shortened);
    try fixture.db.setInput(queries.SourceText, 0, shortened);
    try fixture.expectExit(138);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var middle =", "const middle =");
    defer std.testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectDiagnostic(.reference_not_writable);
    const attenuated = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var source = values.span()", "var source = values.span().as_imm()");
    defer std.testing.allocator.free(attenuated);
    try fixture.db.setInput(queries.SourceText, 0, attenuated);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "range snapshots restore raw bounds and recompute omitted endpoint types" {
    const source =
        \\static bounds = 1..3
        \\fallible calculate() int
        \\    var values = [5, 17, 23, 29, 7]
        \\    const selected = values.slice?(bounds)
        \\    return selected[0] + selected[1] + selected.len()
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const cases = [_]struct { bounds: []const u8, status: u8 }{
        .{ .bounds = "2..4", .status = 66 },
        .{ .bounds = "..2", .status = 6 },
        .{ .bounds = "1..", .status = 46 },
        .{ .bounds = "..", .status = 12 },
        .{ .bounds = "3..1", .status = 138 },
        .{ .bounds = "0..^2147483647", .status = 138 },
        .{ .bounds = "1..^none", .status = 138 },
    };
    for (cases) |case| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "static bounds = {s}", .{case.bounds});
        defer std.testing.allocator.free(replacement);
        const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "static bounds = 1..3", replacement);
        defer std.testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        try fixture.expectExit(case.status);
        const restored = try Fixture.restore(edited);
        defer restored.db.deinit();
        try restored.expectExit(case.status);
    }
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "raw borrow snapshots recompute source and registered signature edits" {
    const source =
        \\import std.memory.{Allocation}
        \\fallible calculate() int
        \\    var storage = Allocation(int).allocate?(1)
        \\    if storage.unsafe_initialize(0, 20) -> unit
        \\    else
        \\        storage^.deallocate()
        \\        fail
        \\    ref item = storage.unsafe_borrow(0)
        \\    item += 22
        \\    const result = item
        \\    storage.unsafe_destroy(0)
        \\    storage^.deallocate()
        \\    return result
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "(0, 20)", "(0, 21)");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, source);
    const memory_module = try fixture.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const declarations = (try fixture.db.get(queries.ModuleDeclarations, memory_module)).*.?;
    const resolved = (try fixture.db.get(queries.ResolveItem, declarations.resolveFunction("unsafe_borrow").?)).*.?;
    const library_source = standard_library.source("memory/allocation.chi");
    const invalid = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        library_source,
        "pub extern func unsafe_borrow(static T: type, ref allocation: Allocation(T), index: int) ref T",
        "pub extern func unsafe_borrow(static T: type, imm allocation: Allocation(T), index: int) ref T",
    );
    defer std.testing.allocator.free(invalid);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, invalid);
    try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    var invalid_signature = false;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == .invalid_external_signature) invalid_signature = true;
    }
    try std.testing.expect(invalid_signature);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, library_source);
    try fixture.expectExit(42);
}

test "span snapshots retain capabilities and recompute attenuation edits" {
    const source =
        \\func capture(ref owner: Array(int, 1)) Span(int) -> owner.span()
        \\func run() int
        \\    var owner = [12]
        \\    var view = capture(owner)
        \\    if ref item = view.get(0)
        \\        item += 30
        \\        return item
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "-> owner.span()", "-> owner.span().as_imm()");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "returned text borrows reject conflicting writes after snapshot restoration" {
    const source =
        \\fallible validate(imm view: Span(byte)) StringView -> BytesView.from_span(view.as_imm()).validate_utf8?()
        \\fallible inspect() int
        \\    var bytes: Array(byte, 1) = [65]
        \\    var writable = bytes.span()
        \\    const text = validate?(writable)
        \\    return text.byte_length() + 41
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "return text.byte_length() + 41", "writable[0] = 255\n    return text.byte_length() + 41");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "operation snapshots restore calls indexers and invalidate signature and visibility edits" {
    const library =
        \\pub struct Value
        \\    copy = fieldwise
        \\    pub value: int
        \\    pub func +(imm left: Value, imm right: Value) Value -> Value{value = left.value + right.value}
    ;
    const source =
        \\import library.{Value}
        \\fallible calculate() int
        \\    var values = [19, 23]
        \\    values[0] += 1
        \\    const sum = Value{value = values[0]} + Value{value = values[1]}
        \\    return sum.value - 1
        \\func run() int
        \\    if const calculated = calculate() -> return calculated
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const files = [_]modules.SourceFile{.{ .path = "library/value.chi", .module_path = "library", .source = library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const invalid = try std.mem.replaceOwned(u8, std.testing.allocator, library, "imm right: Value)", "imm right: Value, imm extra: Value)");
    defer std.testing.allocator.free(invalid);
    try fixture.db.setInput(queries.SourceText, 1, invalid);
    try fixture.expectDiagnostic(.invalid_operation_signature);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    const private = try std.mem.replaceOwned(u8, std.testing.allocator, library, "pub func +", "func +");
    defer std.testing.allocator.free(private);
    const private_files = [_]modules.SourceFile{.{ .path = "library/value.chi", .module_path = "library", .source = private }};
    const denied = try Fixture.restoreSources(source, &files, &private_files, .private_access);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, library);
    try denied.expectExit(42);
}

test "evaluation heap snapshots restore scalar results and recompute callee element and cleanup edits" {
    const source =
        \\struct Item
        \\    move = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value = self.trace.value + self.value
        \\func element() int -> 2
        \\fallible calculate(var trace: Ref(int)) int
        \\    const owner = Box(Item).new?(Item{trace = trace, value = element()})
        \\    return owner.borrow().value + 38
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if ref target = trace.get(0)
        \\        if const value = calculate(Ref.from(target)) -> return value + target
        \\    return 90
        \\static answer = run()
        \\exit(answer)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const callee = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func element() int -> 2", "func element() int -> 3");
    defer std.testing.allocator.free(callee);
    try fixture.db.setInput(queries.SourceText, 0, callee);
    try fixture.expectExit(44);
    const cleanup = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.trace.value + self.value", "self.trace.value + self.value + 1");
    defer std.testing.allocator.free(cleanup);
    try fixture.db.setInput(queries.SourceText, 0, cleanup);
    try fixture.expectExit(43);
    const fields = try std.mem.replaceOwned(u8, std.testing.allocator, source, "    value: int", "    value: int\n    padding: Array(int, 2)");
    defer std.testing.allocator.free(fields);
    const element_type = try std.mem.replaceOwned(u8, std.testing.allocator, fields, "value = element()}", "value = element(), padding = [0, 0]}");
    defer std.testing.allocator.free(element_type);
    try fixture.db.setInput(queries.SourceText, 0, element_type);
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "collection snapshots restore pending carriers heap destinations and initializer effects" {
    const source =
        \\func element() int -> 19
        \\func run() int
        \\    const fixed: Array(int, 1) = [element()]
        \\    const values: List(int) = [23]
        \\    if ref first = fixed.get(0)
        \\        if ref second = values.get(0)
        \\            return first + second
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const fallible = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func element()", "fallible element()");
    defer std.testing.allocator.free(fallible);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, fallible, "[element()]", "[element?()]");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(.fallible_expression_outside_fallible_function);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "converter snapshots restore calls literals and invalidate owner edits" {
    const library =
        \\pub struct Source
        \\    copy = trivial
        \\    pub value: int
        \\pub struct Target
        \\    copy = trivial
        \\    pub value: int
        \\pub converter(value: Source) Target -> Target{value = value.value}
    ;
    const source =
        \\import library.{Source, Target}
        \\func run() int
        \\    const converted: Target = Source{value = 42}
        \\    const literal: byte = 255
        \\    return converted.value
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const private = try std.mem.replaceOwned(u8, std.testing.allocator, library, "pub converter", "converter");
    defer std.testing.allocator.free(private);
    try fixture.db.setInput(queries.SourceText, 1, private);
    try fixture.expectDiagnostic(.local_type_mismatch);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    const private_files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = private }};
    const denied = try Fixture.restoreSources(source, &files, &private_files, .local_type_mismatch);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, library);
    try denied.expectExit(42);
}

test "staged static conversion snapshots track source and converter changes" {
    const source =
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static source: Source) Target -> Target{value = source.value}
        \\func compute() int
        \\    var source = Source{value = 40}
        \\    source.value += 2
        \\    const target: Target = source
        \\    var literal: int_literal = 40
        \\    literal = 42
        \\    const defaulted: int = literal
        \\    return target.value + defaulted - 42
        \\static answer = compute()
        \\func run() int -> answer
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const source_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "source.value += 2", "source.value += 3");
    defer std.testing.allocator.free(source_edit);
    try fixture.db.setInput(queries.SourceText, 0, source_edit);
    try fixture.expectExit(43);
    const converter_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Target{value = source.value}", "Target{value = source.value + 1}");
    defer std.testing.allocator.free(converter_edit);
    try fixture.db.setInput(queries.SourceText, 0, converter_edit);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "converter snapshot probes retain inferred types and annotated literal locals" {
    const library =
        \\pub struct Source
        \\    copy = trivial
        \\    pub value: int
        \\pub struct Target
        \\    copy = trivial
        \\    pub value: int
        \\pub converter(static T: type, value: Source) T where T == Target -> T{value = value.value}
        \\pub converter(static value: int_literal) Target -> Target{value = value}
    ;
    const source =
        \\import library.{Source, Target}
        \\func compute() Target
        \\    var literal: int_literal = 19
        \\    literal = 21
        \\    return literal
        \\static answer = compute()
        \\func run() int
        \\    const converted: Target = Source{value = 21}
        \\    return converted.value + answer.value
        \\exit(run())
    ;
    const files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const literal_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "literal = 21", "literal = 22");
    defer std.testing.allocator.free(literal_edit);
    try fixture.db.setInput(queries.SourceText, 0, literal_edit);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, source);
    const converter_edit = try std.mem.replaceOwned(u8, std.testing.allocator, library, "T{value = value.value}", "T{value = value.value + 1}");
    defer std.testing.allocator.free(converter_edit);
    try fixture.db.setInput(queries.SourceText, 1, converter_edit);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
}

test "static struct modifier edits invalidate restored runtime bodies" {
    const library =
        \\pub struct Data
        \\    copy = trivial
        \\    pub value: int
        \\pub func make() Data -> Data{value = 42}
    ;
    const source =
        \\import library.{make}
        \\func run() int -> make().value
        \\exit(run())
    ;
    const static_library = try std.mem.replaceOwned(u8, std.testing.allocator, library, "pub struct Data", "pub static struct Data");
    defer std.testing.allocator.free(static_library);
    const files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const static_files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = static_library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, static_library);
    try fixture.expectDiagnostic(.compile_time_only_type);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    const denied = try Fixture.restoreSources(source, &files, &static_files, .compile_time_only_type);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, library);
    try denied.expectExit(42);
}

fn checkFieldVisibilitySnapshot(generated: bool) !void {
    const allocator = std.testing.allocator;
    const public_source = if (generated)
        \\pub func Cell(static T: type) type
        \\  return struct
        \\    pub value: T
        \\pub func make() Cell(int) -> Cell(int){value = 40}
    else
        \\pub struct Cell
        \\  pub value: int
        \\pub func make() Cell -> Cell{value = 40}
    ;
    const private_source = try std.mem.replaceOwned(u8, allocator, public_source, "pub value", "value");
    defer allocator.free(private_source);
    const source = try allocator.print(
        \\import library
        \\static Selected = library.Cell{s}
        \\func run() int
        \\  var item = library.make()
        \\  item.value += 1
        \\  return item.value + Selected{{value = 1}}.value
        \\static answer = run()
        \\exit(run() + answer - 42)
    , .{if (generated) "(int)" else ""});
    defer allocator.free(source);
    const public_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = public_source }};
    const private_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = private_source }};
    const fixture = try Fixture.restoreSources(source, &public_files, &public_files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    for ([_]bool{ false, true, false, true }) |is_public| {
        try fixture.db.setInput(queries.SourceText, 1, if (is_public) public_source else private_source);
        if (is_public) {
            try fixture.expectExit(42);
        } else {
            try fixture.expectDiagnostic(.private_struct_field);
        }
    }

    const denied = try Fixture.restoreSources(source, &public_files, &private_files, .private_struct_field);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, public_source);
    try denied.expectExit(42);
}

test "field visibility declared snapshots restore public fields and invalidate denied foreign access" {
    try checkFieldVisibilitySnapshot(false);
}

test "field visibility foreign generated snapshots restore public fields and invalidate denied access" {
    try checkFieldVisibilitySnapshot(true);
}

fn checkFieldVisibilityAnnotationSnapshot(generated: bool) !void {
    const allocator = std.testing.allocator;
    const public_source = if (generated)
        \\static Hidden = int
        \\pub static Visible = int
        \\pub func Cell(static T: type) type
        \\  return struct
        \\    pub value: Visible
        \\pub func make() Cell(int) -> Cell(int){value = 42}
    else
        \\static Hidden = int
        \\pub static Visible = int
        \\pub struct Cell
        \\  pub value: Visible
        \\pub func make() Cell -> Cell{value = 42}
    ;
    const hidden_source = try std.mem.replaceOwned(u8, allocator, public_source, "pub value: Visible", "pub value: Hidden");
    defer allocator.free(hidden_source);
    const private_source = try std.mem.replaceOwned(u8, allocator, hidden_source, "pub value", "value");
    defer allocator.free(private_source);
    const source = try allocator.print(
        \\import library
        \\static Selected = library.Cell{s}
        \\func run() int
        \\  const item: Selected = library.make()
        \\  return 42
        \\static answer = run()
        \\exit(run() + answer - 42)
    , .{if (generated) "(int)" else ""});
    defer allocator.free(source);
    const public_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = public_source }};
    const hidden_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = hidden_source }};
    const fixture = try Fixture.restoreSources(source, &public_files, &public_files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, hidden_source);
    try fixture.expectDiagnostic(.public_field_private_type);
    try fixture.db.setInput(queries.SourceText, 1, private_source);
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, hidden_source);
    try fixture.expectDiagnostic(.public_field_private_type);
    try fixture.db.setInput(queries.SourceText, 1, public_source);
    try fixture.expectExit(42);

    const denied = try Fixture.restoreSources(source, &public_files, &hidden_files, .public_field_private_type);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, public_source);
    try denied.expectExit(42);
}

test "field visibility declared snapshots invalidate public hidden type annotations and recover" {
    try checkFieldVisibilityAnnotationSnapshot(false);
}

test "field visibility generated snapshots invalidate public hidden type annotations and recover" {
    try checkFieldVisibilityAnnotationSnapshot(true);
}

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
        \\fallible forward(init item: int) int -> return materialize?(materialize?(item))
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

    const single_use_edit = try std.mem.replaceOwned(u8, allocator, source, "fallible forward(init item: int) int -> return materialize?(materialize?(item))", "fallible forward(init item: int) int\n    const first = materialize?(item)\n    return materialize?(item)");
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
        \\fallible forward(init item: Item) Item -> return materialize?(item)
        \\fallible run() int
        \\    var value = 1
        \\    const source = Item{value = 2}
        \\    const callback: fallible(init Item) Item = forward
        \\    const result = callback?(if true == true
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
        \\fallible forward(init item: int) int -> return materialize?(item)
        \\func run(imm base: int) int
        \\    var offset = 2
        \\    const callback: fallible(init int) int = forward
        \\    if const value = callback(materialize?(produce?(base + offset))) -> return value
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
        \\fallible own(init item: Item) Box(Item) -> create?(item)
        \\func copied() Item
        \\    const local = Item{value = 19}
        \\    return local
        \\func moved() Item
        \\    const local = Item{value = 20}
        \\    return local^
        \\fallible run() int
        \\    const callback: fallible(init Item) Box(Item) = own
        \\    const first = callback?(copied())
        \\    const second = callback?(moved())
        \\    return first.borrow().value + second.borrow().value
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
        "fallible own(init item: Item) Box(Item) -> create?(item)",
    }, [_][]const u8{
        "copy = none",
        "move = none",
        "fallible own(init item: Item) Box(Item)\n    const first = create?(item)\n    return create?(item)",
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
    const allocation_file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.memory_allocation))).*;
    const allocation_source = (try fixture.db.input(queries.SourceText, allocation_file)).*;
    const edit = try std.mem.replaceOwned(u8, std.testing.allocator, allocation_source, "var storage = allocate?(T, 1)", "var storage = allocate?(T, -1)");
    defer std.testing.allocator.free(edit);
    try fixture.db.setInput(queries.SourceText, allocation_file, edit);
    try fixture.expectExit(42);
    try std.testing.expectEqual(body, try Fixture.functionBody(fixture.db, "run"));
    try fixture.db.setInput(queries.SourceText, allocation_file, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(90);
}

test "allocating initializer snapshots retain partial cleanup and consumption on failure" {
    for ([_][]const u8{ "fail_value?()", "fail" }) |completion| {
        errdefer std.debug.print("allocating completion: {s}\n", .{completion});
        const source = try std.testing.allocator.print(
            \\struct Leaf
            \\    count: Ref(int)
            \\    move = fieldwise
            \\    copy = none
            \\    drop = func(deinit self: Leaf)
            \\        self.count.value = self.count.value + 1
            \\struct Item
            \\    move = none
            \\    first: Leaf
            \\    second: int
            \\fallible fail_value() int
            \\    1 == 0
            \\    return 0
            \\fallible run() int
            \\    var count = Box.new?(40)
            \\    const callback: fallible(init Item) Box(Item) = Box(Item).new
            \\    var leaf = Leaf{{count = Ref.from(count.borrow())}}
            \\    if callback(Item{{first = leaf^, second = if true == true -> {s} else 0}}) -> return 99
            \\    return count.borrow() + 1
            \\if const result = run() -> exit(result) else exit(98)
        , .{completion});
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Box.new?(40)", "Box.new?(39)");
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
        \\    drop = func(deinit self: Item) -> exit(self.value + 0)
        \\func make(value: int) Item -> Item{value = value}
        \\fallible initialize(mut storage: Allocation(Item), init item: Item) -> storage.unsafe_initialize?(1, item)
        \\fallible run()
        \\    var storage = allocate?(Item, 2)
        \\    const callback: fallible(mut Allocation(Item), init Item) unit = initialize
        \\    if callback(storage, make(42)) -> ()
        \\    else
        \\        deallocate(Item, storage)
        \\        fail
        \\    storage.unsafe_destroy(1)
        \\    deallocate(Item, storage)
        \\if run() -> exit(99) else exit(98)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(fixture.db, "initialize");
    const hook_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "exit(self.value + 0)", "exit(self.value + 1)");
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

test "array snapshots restore native and comptime fill reads writes and bounds" {
    const source =
        \\import std.array.{Array}
        \\func run() int
        \\    var values = Array(int, 3).filled(20)
        \\    if ref middle = values.get(1) -> middle = 22
        \\    else return 90
        \\    if values.get(-1) -> return 91
        \\    if values.get(3) -> return 92
        \\    if values.get(-1) -> return 93
        \\    if values.get(3) -> return 94
        \\    if ref first = values.get(0)
        \\        if ref middle = values.get(1) -> return first + middle
        \\    return 95
    ;
    for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)", "static answer = run()\nexit(run() + answer - 42)" }) |entry| {
        const program = try std.testing.allocator.print("{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try Fixture.restore(program);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
    }
}

test "array snapshots restore empty and nested runtime tuple shapes" {
    for ([_]u32{ 0, 2 }) |length| {
        const source = try std.testing.allocator.print(
            \\import std.array.{{Array}}
            \\func run() int
            \\    const row = Array(int, {d}).filled(40)
            \\    const matrix = Array(Array(int, {d}), 2).filled(row)
            \\    if ref selected = matrix.get(1)
            \\        if ref cell = selected.get(0) -> return cell + selected.len()
            \\        return 42
            \\    return 90
            \\static answer = run()
            \\exit(run() + answer - 42)
        , .{ length, length });
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
    }
}

test "array snapshots recompute element types and counts and retain canonical interning" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.array.{Array}
        \\static Element = int
        \\static Count = 2
        \\static Shape = Array(Element, Count)
        \\func number(value: int | none) int
        \\    if ref selected = value as int -> return selected
        \\    return 90
        \\func run() int
        \\    const values = Shape.filled(40)
        \\    if ref selected = values.get(1) -> return number(selected) + values.len()
        \\    return 91
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
    const shape_item = scope.resolveStatic("Shape").?;
    const shape_value = (try fixture.db.get(queries.ResolveStatic, shape_item)).*.?;
    const original_type = (try fixture.db.lookupInterned(queries.CompileTimeValues, shape_value)).type;
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = fixture.db };
    for ([_][]const u8{ "static Element = int", "static Count = 2" }, [_][]const u8{ "static Element = int | none", "static Count = 3" }, [_]u8{ 42, 44 }) |original, replacement, status| {
        const edit = try std.mem.replaceOwned(u8, allocator, source, original, replacement);
        defer allocator.free(edit);
        try fixture.db.setInput(queries.SourceText, 0, edit);
        try fixture.expectExit(status);
        const edited_scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
        const edited_value = (try fixture.db.get(queries.ResolveStatic, edited_scope.resolveStatic("Shape").?)).*.?;
        const edited_type = (try fixture.db.lookupInterned(queries.CompileTimeValues, edited_value)).type;
        try std.testing.expect(edited_type != original_type);
        const array = (try types.arrayType(edited_type)).?;
        try std.testing.expectEqual(edited_type, structures.TypeId.fromInterned(try fixture.db.intern(queries.Types, .{ .array = array })));
        try fixture.db.setInput(queries.SourceText, 0, source);
        try fixture.expectExit(42);
        const restored_scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
        const restored_value = (try fixture.db.get(queries.ResolveStatic, restored_scope.resolveStatic("Shape").?)).*.?;
        try std.testing.expectEqual(original_type, (try fixture.db.lookupInterned(queries.CompileTimeValues, restored_value)).type);
    }
}

test "array snapshots invalidate element copy hook bodies and capabilities" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.array.{Array}
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func run() int
        \\    const original = Item{value = 40}
        \\    const values = Array(Item, 2).filled(original)
        \\    const copied = values.copy()
        \\    if ref selected = copied.get(1) -> return selected.value
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const hook_edit = try std.mem.replaceOwned(u8, allocator, source, "self.value + 1", "self.value + 2");
    defer allocator.free(hook_edit);
    try fixture.db.setInput(queries.SourceText, 0, hook_edit);
    try fixture.expectExit(46);
    const capability_edit = try std.mem.replaceOwned(u8, allocator, source, "copy = func(imm self: Item) Item -> Item{value = self.value + 1}", "copy = none");
    defer allocator.free(capability_edit);
    try fixture.db.setInput(queries.SourceText, 0, capability_edit);
    try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "array snapshots invalidate source indices and standard bounds checks" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.array.{Array}
        \\func run() int
        \\    const values = Array(int, 2).filled(42)
        \\    if ref selected = values.get(1) -> return selected
        \\    return 89
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const index_edit = try std.mem.replaceOwned(u8, allocator, source, "values.get(1)", "values.get(2)");
    defer allocator.free(index_edit);
    try fixture.db.setInput(queries.SourceText, 0, index_edit);
    try fixture.expectExit(136);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
    const array_file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.array))).*;
    const array_source = try allocator.dupe(u8, (try fixture.db.input(queries.SourceText, array_file)).*);
    defer allocator.free(array_source);
    const bounds_edit = try std.mem.replaceOwned(u8, allocator, array_source, "index < N", "index < N - 1");
    defer allocator.free(bounds_edit);
    try std.testing.expect(!std.mem.eql(u8, array_source, bounds_edit));
    try fixture.db.setInput(queries.SourceText, array_file, bounds_edit);
    try fixture.expectExit(136);
    try fixture.db.setInput(queries.SourceText, array_file, array_source);
    try fixture.expectExit(42);
}

test "array intern snapshots preserve nested tuple values and reuse identical type identities" {
    const allocator = std.testing.allocator;
    const first = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer first.deinit();
    const row_data: structures.TypeData = .{ .array = .{ .element_type = .int, .length = 0 } };
    const row_id = try first.intern(queries.Types, row_data);
    const row_type: structures.TypeId = .fromInterned(row_id);
    const empty_tuple = try first.intern(queries.CompileTimeValueTuples, .{ .values = &.{} });
    const row_value = try first.intern(queries.CompileTimeValues, .{ .runtime = .{ .type_id = row_type, .value = .{ .structure = empty_tuple } } });
    const matrix_data: structures.TypeData = .{ .array = .{ .element_type = row_type, .length = 2 } };
    const matrix_id = try first.intern(queries.Types, matrix_data);
    const matrix_type: structures.TypeId = .fromInterned(matrix_id);
    const tuple = try first.intern(queries.CompileTimeValueTuples, .{ .values = &.{ row_value, row_value } });
    const matrix_value = try first.intern(queries.CompileTimeValues, .{ .runtime = .{ .type_id = matrix_type, .value = .{ .structure = tuple } } });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    const digest = cache.querySnapshotKey(try cache.compilerDigest(std.testing.io), "main.chi", &.{});
    try query_disk_cache.save(std.testing.io, allocator, directory, digest, first);
    const payload = (try cache.load(std.testing.io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);
    const next_value: structures.CompileTimeValue = .{ .runtime = .{ .type_id = .int, .value = .{ .int = 31337 } } };
    const next_id = try first.intern(queries.CompileTimeValues, next_value);
    const second = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer second.deinit();
    const offset = try query_disk_cache.restoreInterns(second, allocator, payload);
    try std.testing.expectEqual(@as(usize, 0), try query_disk_cache.restoreQueries(second, payload, offset));
    try std.testing.expectEqual(row_id, try second.intern(queries.Types, row_data));
    try std.testing.expectEqual(matrix_id, try second.intern(queries.Types, matrix_data));
    const restored = (try second.lookupInterned(queries.CompileTimeValues, matrix_value)).runtime;
    try std.testing.expectEqual(matrix_type, restored.type_id);
    try std.testing.expectEqual(tuple, restored.value.structure);
    try std.testing.expectEqualSlices(structures.CompileTimeValueId, &.{ row_value, row_value }, (try second.lookupInterned(queries.CompileTimeValueTuples, tuple)).values);
    try std.testing.expectEqual(matrix_value, try second.intern(queries.CompileTimeValues, .{ .runtime = restored }));
    try std.testing.expectEqual(next_id, try second.intern(queries.CompileTimeValues, next_value));
}

test "array snapshots publish static nested values into runtime storage" {
    const fixture = try Fixture.restore(
        \\static row = Array(int, 2).filled(20)
        \\static matrix = Array(Array(int, 2), 2).filled(row)
        \\func run() int
        \\    const values = matrix
        \\    if ref selected = values.get(1)
        \\        if ref value = selected.get(0) -> return value + row.len() + 20
        \\    return 90
        \\exit(run())
    );
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "text snapshots restore symbolic data borrowed projections and invalidate literal edits" {
    const source =
        \\import words.{greeting}
        \\fallible inspect() int
        \\    const view = greeting.view()
        \\    const bytes = view.as_bytes()
        \\    const first = bytes.get?(0)
        \\    return byte_int(first) - 62
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
        \\exit(run())
    ;
    const files = [_]modules.SourceFile{.{ .path = "words/text.chi", .module_path = "words", .source = "pub static greeting = \"hello\\0é\"" }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, "pub static greeting = \"jello\\0é\"");
    try fixture.expectExit(44);
    try fixture.db.setInput(queries.SourceText, 1, files[0].source);
    try fixture.expectExit(42);
}

test "text snapshots restore owned string cleanup and standard stream artifacts" {
    const source =
        \\import std.io.{write_text, stdout}
        \\fallible length() int
        \\    var text = "hé"
        \\    text.append?("llo")
        \\    write_text?(stdout, "")
        \\    return text.byte_length() + 36
        \\func run() int
        \\    if const answer = length() -> return answer
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "optional argument snapshots restore variant values and converters" {
    const fixture = try Fixture.restore(
        \\fallible missing() int -> fail
        \\func value_or(value: int | none) int
        \\    if const found = value as int -> return found
        \\    return 42
        \\func run() int
        \\    const good = bool(value_or(missing?()) == 42)
        \\    if good? -> return 42
        \\    return 7
        \\exit(run())
    );
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "captured owner cleanup survives snapshots and source edits" {
    const source =
        \\struct Item
        \\    value: int
        \\    trace: Ref(int)
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value + self.value
        \\fallible make(var trace: Ref(int), value: int, enabled: bool) Item
        \\    if not enabled? -> fail
        \\    return Item{value = value, trace = trace}
        \\fallible missing() int -> fail
        \\func consume(var first: Item | none, var second: Item | none, var third: Item | none, final: int) -> ()
        \\fallible work(var trace: Ref(int))
        \\    consume(make?(trace, 10, false), make?(trace, 11, false), make?(trace, 42, true), missing?())
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle = trace.get(0)
        \\        if work(Ref.from(handle)) -> return 91
        \\        return handle
        \\    return 92
        \\static answer = run()
        \\exit(answer + run() - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "make?(trace, 42, true)", "make?(trace, 43, true)");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(44);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}
