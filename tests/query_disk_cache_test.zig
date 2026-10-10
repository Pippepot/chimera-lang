const std = @import("std");
const test_sources = @import("test_sources");
const cache = test_sources.cache;
const modules = test_sources.modules;
const query = test_sources.query;
const queries = test_sources.queries;
const query_disk_cache = test_sources.query_disk_cache;
const structures = test_sources.structures;
const standard_library = @import("standard_library");

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
        \\    trace: Ref(int, true)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.replace(self.trace[] + self.value)
        \\func element() int -> 2
        \\fallible calculate(imm trace: Ref(int, true)) int
        \\    const owner = Box(Item).new?(Item{trace = trace, value = element()})
        \\    return owner.borrow()[].value + 38
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if const target = trace.get_mut(0)
        \\        if const value = calculate(target) -> return value + target[]
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
    const cleanup = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.trace[] + self.value)", "self.trace[] + self.value + 1)");
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
        \\    if const first = fixed.get(0)
        \\        if const second = values.get(0)
        \\            return first[] + second[]
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
            \\    var count = Box.new?(40)
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
        \\    drop = func(deinit self: Item) -> exit(self.value)
        \\func make(value: int) Item -> Item{value = value}
        \\fallible initialize(mut storage: Allocation(Item), init item: Item) -> storage.unsafe_init?(1, item)
        \\fallible run()
        \\    var storage = allocate?(Item, 2)
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

test "array snapshots restore native and comptime fill reads writes and bounds" {
    const source =
        \\import std.array.{Array}
        \\func run() int
        \\    var values = Array(int, 3).filled(20)
        \\    if const middle = values.get_mut(1) -> middle.replace(22)
        \\    else return 90
        \\    if values.get(-1) -> return 91
        \\    if values.get(3) -> return 92
        \\    if values.get_mut(-1) -> return 93
        \\    if values.get_mut(3) -> return 94
        \\    if const first = values.get(0)
        \\        if const middle = values.get(1) -> return first[] + middle[]
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
            \\    if const selected = matrix.get(1)
            \\        if const cell = selected[].get(0) -> return cell[] + selected[].len()
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
        \\    if const selected = value as int -> return selected
        \\    return 90
        \\func run() int
        \\    const values = Shape.filled(40)
        \\    if const selected = values.get(1) -> return number(selected[]) + values.len()
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
        \\    if const selected = copied.get(1) -> return selected[].value
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
        \\    if const selected = values.get(1) -> return selected[]
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
        \\    if const selected = values.get(1)
        \\        if const value = selected[].get(0) -> return value[] + row.len() + 20
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
