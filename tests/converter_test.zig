const std = @import("std");
const sources = @import("test_sources");
const testing = std.testing;

const Fixture = sources.SourceFixture;

const ConversionConsumer = struct {
    pub const Input = struct { consumer: u32, request: sources.queries.ConversionCandidates.Input };
    pub const Output = usize;

    pub fn run(ctx: anytype, key: Input) !Output {
        return ((try ctx.get(sources.queries.ConversionCandidates, key.request)).* orelse return error.TestUnexpectedResult).len;
    }
};

fn conversionType(db: *sources.query.Database, file: sources.structures.FileId, name: []const u8) !sources.structures.TypeId {
    const scope = (try db.get(sources.queries.BuildModuleScope, file)).*.?;
    const value = (try db.get(sources.queries.ResolveStatic, scope.resolveStatic(name).?)).*.?;
    return (try db.lookupInterned(sources.queries.CompileTimeValues, value)).type;
}

test "conversion matching shares work and isolates unrelated index and header edits" {
    const original =
        \\struct Source
        \\    value: int
        \\struct Target
        \\    value: int
        \\converter(value: Source) Target where 1 == 1 -> Target{value = value.value}
    ;
    var profile: sources.profiling.Collector = .{ .io = testing.io };
    const db = try sources.query.Database.init(testing.allocator, .{ .worker_count = 2, .profile = &profile });
    defer db.deinit();
    try sources.modules.registerSources(db, testing.allocator, original, &.{}, &.{});
    const request: sources.queries.ConversionCandidates.Input = .{
        .source = .{ .typed = try conversionType(db, 0, "Source") },
        .target = try conversionType(db, 0, "Target"),
        .requester = (try db.input(sources.queries.FileModule, 0)).*,
    };
    const before = profile.snapshot().get(.conversion_matching).runs;
    for (0..16) |consumer| try testing.expectEqual(@as(usize, 1), (try db.get(ConversionConsumer, .{ .consumer = @intCast(consumer), .request = request })).*);
    try testing.expectEqual(before + 1, profile.snapshot().get(.conversion_matching).runs);

    const unrelated = original ++ "\nstruct Other\n    value: int\nconverter(value: Other) Target -> Target{value = value.value}\nstatic unrelated = 0\n";
    try db.setInput(sources.queries.SourceText, 0, unrelated);
    try testing.expectEqual(@as(usize, 1), (try db.get(ConversionConsumer, .{ .consumer = 16, .request = request })).*);
    try testing.expectEqual(before + 1, profile.snapshot().get(.conversion_matching).runs);

    const body_edit = try std.mem.replaceOwned(u8, testing.allocator, unrelated, "value = value.value}", "value = value.value + 1}");
    defer testing.allocator.free(body_edit);
    try db.setInput(sources.queries.SourceText, 0, body_edit);
    try testing.expectEqual(@as(usize, 1), (try db.get(ConversionConsumer, .{ .consumer = 17, .request = request })).*);
    try testing.expectEqual(before + 1, profile.snapshot().get(.conversion_matching).runs);

    const constraint_edit = try std.mem.replaceOwned(u8, testing.allocator, body_edit, "where 1 == 1", "where 1 == 2");
    defer testing.allocator.free(constraint_edit);
    try db.setInput(sources.queries.SourceText, 0, constraint_edit);
    try testing.expectEqual(@as(usize, 1), (try db.get(ConversionConsumer, .{ .consumer = 18, .request = request })).*);
    try testing.expectEqual(before + 1, profile.snapshot().get(.conversion_matching).runs);

    try db.setInput(sources.queries.SourceText, 0, unrelated ++ "\nconverter(value: Source) Target -> Target{value = 42}\n");
    try testing.expectEqual(@as(usize, 2), (try db.get(ConversionConsumer, .{ .consumer = 19, .request = request })).*);
    try testing.expectEqual(before + 2, profile.snapshot().get(.conversion_matching).runs);
    try db.setInput(sources.queries.SourceText, 0, original);
    try testing.expectEqual(@as(usize, 1), (try db.get(ConversionConsumer, .{ .consumer = 20, .request = request })).*);

    var missing = request;
    missing.source = .{ .typed = .bool };
    try testing.expectEqual(@as(usize, 0), (try db.get(ConversionConsumer, .{ .consumer = 21, .request = missing })).*);
    try db.setInput(sources.queries.SourceText, 0, original ++ "\nconverter(value: bool) Target -> Target{value = 42}\n");
    try testing.expectEqual(@as(usize, 1), (try db.get(ConversionConsumer, .{ .consumer = 22, .request = missing })).*);
}

test "conversion caches retain requester visibility and refresh published converters" {
    const declaration =
        \\pub struct Source
        \\    value: int
        \\pub struct Target
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
    ;
    const fixture = try Fixture.initFiles("import lib.{Source, Target}", &.{.{ .path = "lib/types.chi", .module_path = "lib", .source = declaration }});
    defer fixture.deinit();
    const db = fixture.db;
    var request: sources.queries.ConversionCandidates.Input = .{
        .source = .{ .typed = try conversionType(db, 1, "Source") },
        .target = try conversionType(db, 1, "Target"),
        .requester = (try db.input(sources.queries.FileModule, 0)).*,
    };
    try testing.expectEqual(@as(usize, 0), (try db.get(sources.queries.ConversionCandidates, request)).*.?.len);
    request.requester = (try db.input(sources.queries.FileModule, 1)).*;
    try testing.expectEqual(@as(usize, 1), (try db.get(sources.queries.ConversionCandidates, request)).*.?.len);
    request.requester = (try db.input(sources.queries.FileModule, 0)).*;
    const published = try std.mem.replaceOwned(u8, testing.allocator, declaration, "converter(", "pub converter(");
    defer testing.allocator.free(published);
    try db.setInput(sources.queries.SourceText, 1, published);
    try testing.expectEqual(@as(usize, 1), (try db.get(sources.queries.ConversionCandidates, request)).*.?.len);
    try db.setInput(sources.queries.SourceText, 1, declaration);
    try testing.expectEqual(@as(usize, 0), (try db.get(sources.queries.ConversionCandidates, request)).*.?.len);
}

test "static conversion matches specialize by canonical source value" {
    const fixture = try Fixture.init(
        \\struct Target
        \\    value: int
        \\converter(static value: int_literal) Target -> Target{value = int(value)}
    );
    defer fixture.deinit();
    const db = fixture.db;
    const target = try conversionType(db, 0, "Target");
    const module = (try db.input(sources.queries.FileModule, 0)).*;
    var instances: [2]sources.structures.InstanceId = undefined;
    for (&instances, 0..) |*instance, index| {
        const value = try db.intern(sources.queries.CompileTimeValues, .{ .runtime = .{ .type_id = .int_literal, .value = .{ .int_literal = @intCast(index) } } });
        const candidates = (try db.get(sources.queries.ConversionCandidates, .{ .source = .{ .constant = value }, .target = target, .requester = module })).*.?;
        try testing.expectEqual(@as(usize, 1), candidates.len);
        instance.* = candidates[0].instance;
    }
    try testing.expect(!std.meta.eql(instances[0], instances[1]));
}

test "converter indexing leaves unrelated computed annotations unevaluated" {
    try Fixture.expectParity(
        \\struct Source
        \\    value: int
        \\struct Other
        \\struct Target
        \\    value: int
        \\func computed() type -> panic "index must not evaluate this annotation"
        \\converter(value: Other) computed() -> panic "unrelated converter"
        \\converter(value: Source) Target -> Target{value = value.value}
        \\func run() int -> Target(Source{value = 42}).value
    , 42);
    try Fixture.expectParity(
        \\struct Source
        \\    value: int
        \\struct Target
        \\    value: int
        \\converter(value: Source) Target | never -> Target{value = value.value}
        \\func run() int -> Target(Source{value = 42}).value
    , 42);
}

test "conversion members expose declared callables without executing bodies" {
    try Fixture.expectParity(
        \\struct Source
        \\    copy = none
        \\struct Target
        \\    copy = none
        \\converter(imm value: Source) Target -> panic "lookup must not execute this body"
        \\func accepts(static T: type, static U: type) int
        \\where T.U is func(imm T) U
        \\where T.copy is func(imm T) T or not (T.copy is func(imm T) T)
        \\    return 42
        \\func run() int -> accepts(Source, Target)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func accepts(imm value: int) int where value > 0 -> 42
        \\exit(accepts(1))
    , .comptime_runtime_capture);
}

test "conversion members are callable values at runtime and compile time" {
    try Fixture.expectParity(
        \\struct Source
        \\    value: int
        \\struct Target
        \\    value: int
        \\converter(imm value: Source) Target -> Target{value = value.value + 1}
        \\func apply(callback: func(imm Source) Target, imm value: Source) int -> callback(value).value
        \\static answer = Source.Target(Source{value = 40}).value
        \\func run() int -> apply(Source.Target, Source{value = answer})
    , 42);
}

test "conversion members resolve target aliases and generic specializations" {
    try Fixture.expectParity(
        \\struct Source(T: type)
        \\    value: T
        \\struct Target(T: type)
        \\    value: T
        \\converter(static T: type, imm value: Source(T)) Target(T) -> Target(T){value = value.value}
        \\static Destination = Target(int)
        \\func apply(static T: type, static U: type, imm value: T) U
        \\where T.U is func(imm T) U
        \\    return T.U(value)
        \\func run() int -> apply(Source(int), Destination, Source(int){value = 42}).value
    , 42);
}

test "conversion member calls retain source borrows and reject escaping results" {
    const declarations =
        \\struct Source
        \\    copy = none
        \\    value: Ref(int)
        \\struct Target
        \\    value: Ref(int)
        \\converter(imm value: Source) Target -> Target{value = value.value}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var value = 42
        \\    const source = Source{value = Ref.from(value)}
        \\    const convert: func(imm Source) Target = Source.Target
        \\    const result = convert(source)
        \\    return source.value.value + result.value.value - 42
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() Target
        \\    var value = 42
        \\    return Source.Target(Source{value = Ref.from(value)})
        \\exit(invalid().value.value)
    , .borrow_outlives_source);
}

test "conversion members preserve initializer parameter modes" {
    try Fixture.expectParity(
        \\struct Target
        \\    value: int
        \\converter(static N: int, init value: collection_literal(int, N)) Target
        \\    const values: Array(int, N) = value
        \\    if const first = values[0] -> return Target{value = first}
        \\    panic "empty source"
        \\static Source = collection_literal(int, 1)
        \\func accepts() int where Source.Target is func(init Source) Target -> 42
        \\func run() int -> Source.Target([accepts()]).value
    , 42);
}

test "conversion members require concrete values for static source specialization" {
    try Fixture.expectParity(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    value: int
        \\converter(static value: Source) Target -> Target{value = value.value}
        \\func accepts() int where not (Source.Target is func(imm Source) Target) -> 42
        \\func run() int -> Target(Source{value = accepts()}).value
    , 42);
}

test "ordinary members take precedence over conversion target names" {
    try Fixture.expectParity(
        \\struct Target
        \\    value: int
        \\static Destination = Target
        \\struct Source
        \\    value: int
        \\    func Target(imm value: Source) int -> 7
        \\converter(imm value: Source) Target -> Target{value = value.value}
        \\func run() int
        \\    const value = Source{value = 35}
        \\    return Source.Target(value) + Source.Destination(value).value
    , 42);
}

test "conversion members retain actual parameter types and do not synthesize adapters" {
    try Fixture.expectParity(
        \\struct Source
        \\struct Other
        \\struct Target
        \\converter(imm value: Source | Other) Target -> Target{}
        \\static Inputs = Source | Other
        \\static Destination = Target | none
        \\func accepts() int
        \\where Source.Target is func(imm Source | Other) Target
        \\where Inputs.Target is func(imm Inputs) Target
        \\where not (Source.Target is func(imm Source) Target)
        \\where not (Source.Destination is func(imm Source) Destination)
        \\where not (int.int is func(imm int) int)
        \\where not (String.String is func(imm String) String)
        \\    return 42
        \\func run() int -> accepts()
    , 42);
}

test "conversion member constraints fail without running bodies" {
    try Fixture.expectParity(
        \\struct Source
        \\struct Target
        \\converter(imm value: Source) Target where 1 == 2 -> panic "body must not run"
        \\func accepts() int where not (Source.Target is func(imm Source) Target) -> 42
        \\func run() int -> accepts()
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Source
        \\struct Target
        \\converter(imm value: Source) Target where 1 == 2 -> Target{}
        \\func accepts(static T: type) int where T.Target is func(imm T) Target -> 42
        \\exit(accepts(Source))
    , .where_condition_failed);
    try Fixture.expectSourceDiagnostic(
        \\struct Source
        \\struct Target
        \\converter(imm value: Source) Target where 1 == 2 -> Target{}
        \\_ = Source.Target
    , .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\struct Target
        \\func valid() int -> panic "invalid converter constraint"
        \\converter(imm value: Source) Target where valid() > 0 -> Target{}
        \\func accepts() int where not (Source.Target is func(imm Source) Target) -> 42
        \\exit(accepts())
    , .compile_time_panic);
}

test "conversion members reject ambiguity and do not chain converters" {
    const declarations =
        \\struct Source
        \\struct Middle
        \\struct Target
        \\converter(imm value: Source) Middle -> Middle{}
        \\converter(imm value: Middle) Target -> Target{}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func accepts() int where not (Source.Target is func(imm Source) Target) -> 42
        \\func run() int -> accepts()
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\converter(imm value: Source) Target -> Target{}
        \\converter(imm value: Source) Target -> Target{}
        \\func accepts() int where not (Source.Target is func(imm Source) Target) -> 42
        \\func run() int -> accepts()
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\converter(imm value: Source) Target -> Target{}
        \\converter(imm value: Source) Target -> Target{}
        \\exit(Source.Target(Source{}).Middle)
    , .ambiguous_conversion);
}

test "where predicates still execute ordinary value conversions" {
    try Fixture.expectParity(
        \\func accepts() int where int(42) > 0 -> 42
        \\func run() int -> accepts()
    , 42);
}

test "conversion members follow owner visibility and incremental edits" {
    const definition =
        \\import std.text.{String}
        \\pub struct Source
        \\    copy = none
        \\pub converter(imm value: Source) String where 1 == 1 -> "source"
    ;
    const fixture = try Fixture.initFiles(
        \\import library.{Source}
        \\func check(static T: type) int where T.String is func(imm T) String -> 42
        \\exit(check(Source))
    , &.{.{ .path = "library/source.chi", .module_path = "library", .source = definition }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const rejected = try std.mem.replaceOwned(u8, testing.allocator, definition, "where 1 == 1", "where 1 == 2");
    defer testing.allocator.free(rejected);
    try fixture.db.setInput(sources.queries.SourceText, 1, rejected);
    try fixture.expectDiagnostic(0, .where_condition_failed);
    const private = try std.mem.replaceOwned(u8, testing.allocator, definition, "pub converter", "converter");
    defer testing.allocator.free(private);
    try fixture.db.setInput(sources.queries.SourceText, 1, private);
    try fixture.expectDiagnostic(0, .where_condition_failed);
    try fixture.db.setInput(sources.queries.SourceText, 1, definition);
    try fixture.expectExit(0, 42);
}

test "conversion members diagnose circular constraints" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\converter(imm value: Source) String where Source.String is func(imm Source) String -> "source"
        \\func accepts() int where Source.String is func(imm Source) String -> 42
        \\exit(accepts())
    , .declaration_cycle);
}

test "converter inputs preserve captured authority and results retain borrowed origins" {
    const install =
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\struct Done
        \\    marker: int
        \\converter(imm input: Install) Done
        \\    input.target.value = input.source
        \\    return Done{marker = 0}
    ;
    try Fixture.expectParity(install ++ "\n" ++
        \\func run() int
        \\    var initial = 17
        \\    var result = Ref.from(initial)
        \\    var source = 42
        \\    _ = Done(Install{target = Ref.from(result), source = Ref.from(source)})
        \\    return result.value
    , 42);
    try Fixture.expectAnySourceDiagnostic(install ++ "\n" ++
        \\var initial = 17
        \\const result = Ref.from(initial)
        \\var source = 42
        \\_ = Done(Install{target = Ref.from(result), source = Ref.from(source)})
        \\exit(0)
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Input
        \\    value: int
        \\struct Done
        \\    marker: int
        \\converter(imm input: Input) Done
        \\    input.value = 42
        \\    return Done{marker = input.value}
        \\_ = Done(Input{value = 17})
    , .reference_not_writable);
    const declarations =
        \\struct Install
        \\    source: Ref(int)
        \\struct Done
        \\    source: Ref(int)
        \\converter(imm input: Install) Done
        \\    return Done{source = input.source}
    ;
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func selected(ref initial: int) Ref(int)
        \\    var result = Ref.from(initial)
        \\    var local = 42
        \\    result = Done(Install{source = Ref.from(local)}).source
        \\    return result
        \\var initial = 17
        \\exit(selected(initial).value)
    , .borrow_outlives_source);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func selected(ref initial: int, ref source: int) Ref(int)
        \\    var result = Ref.from(initial)
        \\    result = Done(Install{source = Ref.from(source)}).source
        \\    return result
        \\func run() int
        \\    var initial = 17
        \\    var source = 42
        \\    return selected(initial, source).value
    , 42);
}

test "converters preserve temporal conflicts between captured referents" {
    const declarations =
        \\struct Input
        \\    left: Ref(String)
        \\    right: Ref(String)
        \\struct Done
        \\    value: int
        \\converter(imm input: Input) Done
        \\    const view = input.left.value.view()
        \\    if (input.right.value.append("x") is unit) -> ()
        \\    return Done{value = view.byte_length() + 39}
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    const result: Done = Input{left = Ref.from(left), right = Ref.from(right)}
        \\    return result.value
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var buffer: String = "abc"
        \\    const result: Done = Input{left = Ref.from(buffer), right = Ref.from(buffer)}
        \\    return result.value
        \\_ = run()
    , .borrow_outlives_source);
}

test "converter mutations invalidate caller retained reads precisely" {
    const declarations =
        \\struct Input
        \\    target: Ref(String)
        \\struct Done
        \\    value: int
        \\converter(imm input: Input) Done
        \\    if (input.target.value.append("x") is unit) -> ()
        \\    return Done{value = 0}
        \\func inspect(ref left: String, ref right: String) int | none
        \\    const view = left.view()
        \\    const result: Done = Input{target = Ref.from(right)}
        \\    return view.byte_length() + result.value + 39
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    return inspect(left, right)
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var buffer: String = "abc"
        \\    return inspect(buffer, buffer)
        \\_ = run()
    , .borrow_outlives_source);
}

test "optional generic inference uses payload evidence and preserves ordinary absence" {
    try Fixture.expectParity(
        \\func identity(static T: type, value: T | none) T | none -> value
        \\func absent() int | none -> return none
        \\func run() int
        \\    const found = identity(42)
        \\    if not (found is int) -> return 90
        \\    if identity(absent()) is int -> return 91
        \\    if const answer: int = found -> return answer
        \\    return 92
    , 42);
}

test "optional generic inference strips fixed members independent of arm order" {
    try Fixture.expectParity(
        \\static Absent: type = none
        \\func identity(static T: type, value: Absent | T) T | none -> value
        \\func run() int
        \\    const original: int | bool | none = 42
        \\    const result = identity(original)
        \\    if const answer: int = result -> return answer
        \\    return 90
    , 42);
}

test "optional generic inference recovers nominal payload specialization" {
    try Fixture.expectParity(
        \\struct Wrapper(T: type)
        \\    copy = trivial
        \\    value: T
        \\func identity(static T: type, value: Wrapper(T) | none) Wrapper(T) | none -> value
        \\func run() int
        \\    const original: Wrapper(int) | none = Wrapper(int){value = 42}
        \\    if const found: Wrapper(int) = identity(original) -> return found.value
        \\    return 90
    , 42);
}

test "optional generic inference accepts none when another argument supplies the type" {
    try Fixture.expectParity(
        \\func before(static T: type, value: T | none, fallback: T) T
        \\    if const found: T = value -> return found
        \\    return fallback
        \\func after(static T: type, fallback: T, value: T | none) T
        \\    if const found: T = value -> return found
        \\    return fallback
        \\func run() int -> before(none, 20) + after(22, none)
    , 42);
}

test "optional generic inference does not guess a payload from none or ambiguous arms" {
    try Fixture.expectAnySourceDiagnostic(
        \\func identity(static T: type, value: T | none) T | none -> value
        \\_ = identity(none)
    , .static_argument_cannot_be_inferred);
    try Fixture.expectAnySourceDiagnostic(
        \\func ambiguous(static T: type, static U: type, value: T | U | none) unit -> ()
        \\ambiguous(42)
    , .static_argument_cannot_be_inferred);
    try Fixture.expectAnySourceDiagnostic(
        \\func inconsistent(static T: type, optional: T | none, value: T) unit -> ()
        \\inconsistent(42, true)
    , .static_argument_inference_conflict);
}

test "optional generic struct fields infer from successful payloads" {
    try Fixture.expectParity(
        \\struct Optional(T: type)
        \\    copy = fieldwise
        \\    value: T | none
        \\func run() int
        \\    const wrapped = Optional{value = 42}
        \\    if const answer: int = wrapped.value -> return answer
        \\    return 90
    , 42);
}

test "optional generic converter inputs infer their payload type" {
    try Fixture.expectParity(
        \\struct Answer
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, value: T | none) Answer
        \\    if value is T -> return Answer{value = 42}
        \\    return Answer{value = 90}
        \\func run() int
        \\    const answer: Answer = 7
        \\    return answer.value
    , 42);
}

test "optional generic inference recomputes after payload signature edits" {
    const source =
        \\func receive(static T: type, optional: T | none, fallback: T) int -> 42
        \\exit(receive(7, 42))
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const changed =
        \\func receive(static T: type, optional: bool | none, fallback: T) int -> 42
        \\exit(receive(7, 42))
    ;
    try fixture.db.setInput(sources.queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(0, .call_argument_type_mismatch);
    try fixture.db.setInput(sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "collection literals construct infunc arrays without failure handling" {
    try Fixture.expectSourceExit(
        \\func count() int
        \\    const values: Array(int, 2) = [19, 23]
        \\    return values.len()
        \\exit(count())
    , 2);
}

test "consuming collection converters preserve optional element data with native and interpreter parity" {
    try Fixture.expectParity(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static N: int, init value: collection_literal(int | none, N)) Target
        \\    const source: Array(int | none, N) = value
        \\    return Target{value = source.len() + 40}
        \\func missing() int | none -> return none
        \\func run() int
        \\    const target: Target = [19, 23]
        \\    const absent: Target = [missing()]
        \\    if absent.value <> 41 -> return 91
        \\    return target.value
    , 42);
}

test "collection converters derive contextual element types including empty literals from targets" {
    try Fixture.expectParity(
        \\struct Wrapper(T: type)
        \\    copy = trivial
        \\    size: int
        \\converter(static T: type, static N: int, init value: collection_literal(T, N)) Wrapper(T)
        \\    const source: Array(T, N) = value
        \\    return Wrapper(T){size = source.len()}
        \\func run() int
        \\    const values: Wrapper(byte) = [1, 2]
        \\    const empty: Wrapper(byte) = []
        \\    return values.size + empty.size + 40
    , 42);
}

test "static structs permit ordinary compile-time local construction and mutation" {
    try Fixture.expectSourceExit(
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\func compute() int
        \\    var data = Data{value = 40}
        \\    data.value += 2
        \\    return data.value
        \\static answer = compute()
        \\exit(answer)
    , 42);
}

test "static structs cannot occupy runtime storage" {
    try Fixture.expectAnySourceDiagnostic(
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\const data = Data{value = 42}
        \\exit(data.value)
    , .compile_time_only_type);
}

test "static-only types and empty containing arrays have no native layout" {
    const fixture = try Fixture.init(
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\static Empty = Array(Data, 0)
        \\exit(0)
    );
    defer fixture.deinit();
    const scope = (try fixture.db.get(sources.queries.BuildModuleScope, 0)).*.?;
    for ([_][]const u8{ "Data", "Empty" }) |name| {
        const value_id = (try fixture.db.get(sources.queries.ResolveStatic, scope.resolve(name).?)).*.?;
        const type_id = (try fixture.db.lookupInterned(sources.queries.CompileTimeValues, value_id)).type;
        try testing.expectError(error.Unavailable, fixture.db.get(sources.queries.HostTypeLayout, type_id));
        try testing.expect((try fixture.db.get(sources.queries.StructLayout, type_id)).* == null);
    }
    try testing.expectError(error.Unavailable, fixture.db.get(sources.queries.HostTypeLayout, .int_literal));
}

test "static struct hooks aliases and namespace members obey ordinary compile-time rules" {
    try Fixture.expectSourceExit(
        \\static struct Data
        \\    value: int
        \\    copy = func(imm self: Data) Data -> Data{value = self.value + 1}
        \\    drop = func(deinit self: Data)
        \\        if self.value == 41 -> () else
        \\            if self.value == 42 -> () else exit(90)
        \\    pub func answer(static value: Data) int -> value.value
        \\static Alias = Data
        \\func compute() int
        \\    const source = Alias{value = 41}
        \\    const copied = source
        \\    return copied.value
        \\static result = compute()
        \\exit(Data.answer(Data{value = result}))
    , 42);
}

test "static struct generated values can specialize runtime functions" {
    try Fixture.expectSourceExit(
        \\static struct Data(T: type)
        \\    copy = trivial
        \\    value: T
        \\func answer(static data: Data(int)) int -> data.value
        \\exit(answer(Data(int){value = 42}))
    , 42);
}

test "static struct eligibility propagates through stored aggregates" {
    for ([_][]const u8{
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\struct Wrapper
        \\    copy = fieldwise
        \\    data: Data
        \\const data = Wrapper{data = Data{value = 42}}
        \\exit(data.data.value)
        ,
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\const data: Data | none = Data{value = 42}
        \\if const selected: Data = data -> exit(selected.value) else exit(90)
        ,
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\const data: Array(Data, 0) = Array(Data, 0).filled(Data{value = 42}) else panic "unexpected none"
        \\exit(data.len())
        ,
    }) |source| try Fixture.expectAnySourceDiagnostic(source, .compile_time_only_type);
}

test "compile-time-only types reject runtime calls and raw heap storage" {
    const declaration =
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\
    ;
    try Fixture.expectAnySourceDiagnostic(declaration ++ "func make() Data -> Data{value = 42}\nconst data = make()\nexit(data.value)", .compile_time_only_type);
    try Fixture.expectAnySourceDiagnostic(declaration ++ "func use(data: Data) int -> data.value\nexit(use(Data{value = 42}))", .compile_time_only_type);
    try Fixture.expectAnySourceDiagnostic(declaration ++ "import std.memory.{Allocation}\nif const storage: Allocation(Data) = Allocation(Data).allocate(1)\n    storage^.deallocate()\nexit(0)", .compile_time_only_type);
    try Fixture.expectSourceExit(declaration ++ "func make() Data -> Data{value = 42}\nfunc compute() int -> make().value\nstatic answer = compute()\nexit(answer)", 42);
}

test "direct converters initialize expected bindings fields arguments and returns" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value + 1}
        \\struct Holder
        \\    copy = fieldwise
        \\    value: Target
        \\func answer(imm value: Target) int -> value.value
        \\func converted() Target -> Source{value = 41}
        \\const direct: Target = Source{value = 41}
        \\const holder = Holder{value = Source{value = 41}}
        \\if answer(Source{value = 41}) == direct.value
        \\    if holder.value.value == converted().value -> exit(42)
        \\exit(90)
    , 42);
}

test "explicit converter calls support aliases and specialized factories" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target(T: type)
        \\    copy = fieldwise
        \\    value: T
        \\converter(static T: type, value: Source) Target(T) -> Target(T){value = value.value}
        \\static Alias = Target(int)
        \\const first = Alias(Source{value = 42})
        \\const second = Target(int)(Source{value = 42})
        \\if first.value == second.value -> exit(first.value) else exit(90)
    , 42);
}

test "converter ambiguity is diagnosed only at unequal expected uses" {
    const declarations =
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\converter(value: Source) Target -> Target{value = value.value + 1}
        \\
    ;
    try Fixture.expectSourceExit(declarations ++ "const source: Source = Source{value = 42}\nexit(source.value)", 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "const target: Target = Source{value = 42}\nexit(target.value)", .ambiguous_conversion);
}

test "converter to a variant member widens its result" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\const converted: Target | none = Source{value = 42}
        \\if const selected: Target = converted -> exit(selected.value) else exit(90)
    , 42);
}

test "static source converter constructs runtime values without runtime source storage" {
    try Fixture.expectSourceExit(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: Source) Target -> Target{value = value.value}
        \\const converted: Target = Source{value = 42}
        \\exit(converted.value)
    , 42);
}

test "integer literal defaults and standard byte converter preserve distinct types" {
    try Fixture.expectSourceExit(
        \\const minimum: int = -2147483648
        \\const byte_value: byte = 42
        \\const variant: int | byte = 42
        \\const bytes: Array(byte, 1) = Array(byte, 1).filled(byte_value) else panic "unexpected none"
        \\if const selected: int = variant
        \\    if minimum < 0 -> exit(selected)
        \\exit(90)
    , 42);
    try Fixture.expectAnySourceDiagnostic("const value: byte = 256\nexit(0)", .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic("const value: byte = -1\nexit(0)", .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic("const value = 2147483648\nexit(0)", .integer_literal_out_of_range);
    try Fixture.expectAnySourceDiagnostic("const number = 42\nconst value: byte = number\nexit(0)", .local_type_mismatch);
}

test "direct converters can return a whole variant" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) int | none -> value.value
        \\const result: int | none = Source{value = 42}
        \\if const selected: int = result -> exit(selected) else exit(90)
    , 42);
}

test "converter where is demanded only after selection" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Unused
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Unused where 1 == 2 -> Unused{value = value.value}
        \\const result: int | none = 42
        \\if const selected: int = result -> exit(selected) else exit(90)
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target where 1 == 2 -> Target{value = value.value}
        \\const result: Target = Source{value = 42}
        \\exit(result.value)
    , .where_condition_failed);
}

test "variant conversion checks requirements and dispatches every member in both engines" {
    try Fixture.expectParity(
        \\struct First
        \\    move = none
        \\    copy = none
        \\    value: int
        \\struct Second
        \\    copy = trivial
        \\    value: int
        \\converter(imm value: First) int -> value.value
        \\converter(imm value: Second) int -> value.value
        \\func number(static T: type, imm value: T) int -> int(value)
        \\func first() First | Second | int -> First{value = 10}
        \\func second() First | Second | int -> Second{value = 12}
        \\func integer() First | Second | int -> 20
        \\func run() int -> number(first()) + number(second()) + number(integer())
    , 42);
}

test "variant conversion evaluates once borrows payloads and runs only the active converter" {
    try Fixture.expectParity(
        \\struct First
        \\    move = none
        \\    copy = none
        \\    calls: Ref(int)
        \\    drops: Ref(int)
        \\    drop = func(deinit self: First) -> self.drops.value += 1
        \\struct Second
        \\    move = none
        \\    copy = none
        \\    calls: Ref(int)
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Second) -> self.drops.value += 1
        \\converter(imm value: First) int
        \\    value.calls.value += 10
        \\    return 19
        \\converter(imm value: Second) int
        \\    value.calls.value += 10
        \\    return 23
        \\func make(choose: bool, calls: Ref(int), drops: Ref(int)) First | Second
        \\    calls.value += 1
        \\    if choose -> return First{calls = calls, drops = drops}
        \\    return Second{calls = calls, drops = drops}
        \\func run() int
        \\    var calls = 0
        \\    var drops = 0
        \\    const total = int(make(true, (if const _selected_result_0: Ref(int) = Ref.from(calls) -> _selected_result_0 else panic "unexpected none"), (if const _selected_result_1: Ref(int) = Ref.from(drops) -> _selected_result_1 else panic "unexpected none"))) + int(make(false, (if const _selected_result_2: Ref(int) = Ref.from(calls) -> _selected_result_2 else panic "unexpected none"), (if const _selected_result_3: Ref(int) = Ref.from(drops) -> _selected_result_3 else panic "unexpected none")))
        \\    if calls <> 22 or drops <> 2 -> return 90
        \\    return total
    , 42);
}

test "whole variant converters take precedence over member dispatch" {
    try Fixture.expectParity(
        \\struct First
        \\struct Second
        \\struct Target
        \\    value: int
        \\converter(imm value: First) Target -> panic "member converter must not run"
        \\converter(imm value: Second) Target -> panic "member converter must not run"
        \\converter(imm value: First | Second) Target -> Target{value = 21}
        \\func first() First | Second -> First{}
        \\func second() First | Second -> Second{}
        \\func run() int -> Target(first()).value + Target(second()).value
    , 42);
}

test "variant conversion joins borrowed identity and owned results with exact cleanup" {
    try Fixture.expectParity(
        \\struct Source
        \\    drops: Ref(int)
        \\struct Target
        \\    copy = none
        \\    value: int
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Target) -> self.drops.value += 1
        \\converter(imm value: Source) Target -> Target{value = 19, drops = value.drops}
        \\func inspect(imm value: Target) int -> value.value
        \\func calculate(drops: Ref(int)) int
        \\    const source: Source | Target = Source{drops = drops}
        \\    const identity: Source | Target = Target{value = 23, drops = drops}
        \\    const total = inspect(Target(source)) + inspect(Target(identity))
        \\    if drops.value <> 1 -> return 90
        \\    if ref selected: Target = identity
        \\        if selected.value <> 23 -> return 92
        \\    else
        \\        return 93
        \\    return total
        \\func run() int
        \\    var drops = 0
        \\    const total = calculate((if const _selected_result_0: Ref(int) = Ref.from(drops) -> _selected_result_0 else panic "unexpected none"))
        \\    if drops <> 2 -> return 91
        \\    return total
    , 42);
}

test "variant conversion constructs immovable results into bindings fields arguments and returns" {
    try Fixture.expectParity(
        \\struct First
        \\struct Second
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\struct Wrapper
        \\    item: Pinned
        \\converter(imm value: First) Pinned -> Pinned{value = 19}
        \\converter(imm value: Second) Pinned -> Pinned{value = 23}
        \\func make(choose: bool) First | Second -> if choose -> First{} else Second{}
        \\func convert(imm value: First | Second) Pinned -> value
        \\func receive(var value: Pinned) int -> value.value
        \\func run() int
        \\    const first: Pinned = make(true)
        \\    const wrapper = Wrapper{item = make(false)}
        \\    if first.value + wrapper.item.value <> 42 -> return 90
        \\    return receive(make(true)) + convert(make(false)).value
    , 42);
}

test "diverging variant member conversions leave no result join" {
    const declarations =
        \\struct First
        \\struct Second
        \\converter(imm value: First) never -> exit(42)
        \\converter(imm value: Second) never -> exit(42)
        \\func stop(imm value: First | Second) never -> never(value)
    ;
    inline for (.{ "First{}", "Second{}" }) |constructor| {
        try Fixture.expectParity(declarations ++ "\nfunc run() int\n    stop(" ++ constructor ++ ")\n", 42);
    }
}

test "variant conversion combines member conversion and builtin widening" {
    try Fixture.expectParity(
        \\struct Source
        \\converter(imm value: Source) bool -> true
        \\func convert(imm value: Source | int) int | bool -> value
        \\func run() int
        \\    if const integer: int = convert(40)
        \\        if const boolean: bool = convert(Source{})
        \\            if boolean -> return integer + 2
        \\    return 90
    , 42);
}

test "variant conversion bodies reject missing ambiguous and constrained members" {
    const declarations =
        \\struct First
        \\struct Second
        \\converter(imm value: First) int -> 19
        \\func check(imm value: First | Second) int -> int(value)
    ;
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\nexit(check(First{}))", .local_type_mismatch);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\converter(imm value: Second) int where 1 == 2 -> 23
        \\exit(check(First{}))
    , .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\converter(imm value: Second) int -> 23
        \\converter(imm value: Second) int -> 24
        \\exit(check(First{}))
    , .ambiguous_conversion);
}

test "conversion does not chain converters for scalars or variant members" {
    const declarations =
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Middle
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Middle -> Middle{value = value.value}
        \\converter(value: Middle) Target -> Target{value = value.value}
        \\
    ;
    try Fixture.expectAnySourceDiagnostic(declarations ++ "const result: Target = Source{value = 42}\nexit(0)", .local_type_mismatch);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "const source: Source | Middle = Source{value = 42}\nconst result: Target = source\nexit(0)", .local_type_mismatch);
}

test "builtin widening preserves members before converters" {
    try Fixture.expectParity(
        \\struct Source
        \\    move = none
        \\    copy = none
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> panic "widening must not run converters"
        \\func run() int
        \\    const result: Source | Target = Source{value = 42}
        \\    if ref selected: Source = result -> return selected.value
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    const number = 10
        \\    const literal = [10, "Hello", [1, 2, 3]]
        \\    const bound = [number, "Hello", [1, 2, 3]]
        \\    if const first: int = literal[0]
        \\        if const second: int = bound[0] -> return first + second + 22
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func render(value: int) String -> value
        \\func accept(imm value: String) int -> value.byte_length()
        \\func run() int
        \\    const number = 10
        \\    const bound: String = number
        \\    const returned = render(number)
        \\    const explicit = String(number)
        \\    return bound.byte_length() + returned.byte_length() + explicit.byte_length() + accept(number) + 34
    , 42);
}

test "converter lookup follows type ownership across source annotation and privacy edits" {
    const source =
        \\import library.{Source, Target}
        \\const result: Target = Source{value = 42}
        \\exit(result.value)
    ;
    const definition =
        \\pub struct Source
        \\    copy = trivial
        \\    pub value: int
        \\pub struct Target
        \\    copy = trivial
        \\    pub value: int
    ;
    const public = "pub converter(value: Source) Target -> Target{value = value.value}";
    const private = "converter(value: Source) Target -> Target{value = value.value}";
    const fixture = try Fixture.initFiles(source, &.{
        .{ .path = "library/types.chi", .module_path = "library", .source = definition },
        .{ .path = "library/conversion.chi", .module_path = "library", .source = public },
    });
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(sources.queries.SourceText, 2, "pub converter(value: int) Target -> Target{value = value}");
    try testing.expect((try fixture.db.get(sources.queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(sources.queries.SourceText, 2, public);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(sources.queries.SourceText, 2, private);
    try testing.expect((try fixture.db.get(sources.queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(sources.queries.SourceText, 2, public);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(sources.queries.SourceText, 2, public ++ "\n" ++ public);
    try testing.expect((try fixture.db.get(sources.queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(sources.queries.SourceText, 2, public);
    try fixture.expectExit(0, 42);
}

test "converter inputs remain borrowed and immovable outputs construct in bindings and fields" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = none
        \\    value: int
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\converter(value: Source) Pinned -> Pinned{value = value.value}
        \\struct Holder
        \\    move = none
        \\    copy = none
        \\    value: Pinned
        \\const source = Source{value = 21}
        \\const direct: Pinned = source
        \\const holder = Holder{value = source}
        \\exit(direct.value + holder.value.value)
    , 42);
}

test "converters run through ordinary compile-time calls" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value + 1}
        \\func run() int
        \\    const converted: Target = Source{value = 20}
        \\    const bytes: byte = 42
        \\    return converted.value
        \\static result = run()
        \\exit(run() + result)
    , 42);
}

test "converter declarations reject invalid source modes and foreign ownership even unused" {
    for ([_][]const u8{
        "converter(mut value: Source) Target -> Target{value = value.value}",
        "converter(var value: Source) Target -> Target{value = value.value}",
        "converter(deinit value: Source) Target -> Target{value = value.value}",
        "converter(init value: Source) Target -> Target{value = value.value}",
        "converter(static value: Source) Target -> Target{value = value.value}",
        "converter(first: Source, second: Source) Target -> Target{value = first.value}",
    }) |declaration| {
        const source = try testing.allocator.print("struct Source\n    copy = trivial\n    value: int\nstruct Target\n    copy = trivial\n    value: int\n{s}\nexit(0)", .{declaration});
        defer testing.allocator.free(source);
        try Fixture.expectAnySourceDiagnostic(source, .invalid_converter);
    }
    try Fixture.expectAnySourceDiagnostic("converter(value: int) byte -> 42\nexit(0)", .invalid_converter_owner);
}

test "converter declaration parameters must infer from the source or target" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, value: Source) int -> value.value
        \\exit(0)
    , .invalid_converter);
    try Fixture.expectAnySourceDiagnostic("struct Data\n    converter(value: int) byte -> 42\nexit(0)", .invalid_converter);
    try Fixture.expectAnySourceDiagnostic("func unused()\n    converter(value: int) byte -> 42\nexit(0)", .invalid_converter);
}

test "static converter source annotations infer generic parameters and accept calls" {
    try Fixture.expectSourceExit(
        \\static struct Source(T: type)
        \\    copy = fieldwise
        \\    value: T
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, static value: Source(T)) Target -> Target{value = value.value}
        \\func make() Source(int) -> Source(int){value = 42}
        \\const first: Target = Source{value = 42}
        \\const second: Target = make()
        \\if first.value == second.value -> exit(first.value) else exit(90)
    , 42);
}

test "immovable converter outputs construct in returns variants branches and arguments" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    move = none
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\func make() Target -> Source{value = 42}
        \\func select(flag: int) Target | none
        \\    if flag == 1 -> return Source{value = 42}
        \\    return none
        \\func check(var value: Target) int -> value.value
        \\var assigned: Target = Source{value = 40}
        \\assigned = Source{value = 42}
        \\const choice: Target | none = if 1 == 1 -> Source{value = 42} else none
        \\if const selected: Target = select(1)
        \\    if selected.value == assigned.value
        \\        if check(Source{value = 42}) == make().value
        \\            if const branch: Target = choice -> exit(branch.value)
        \\exit(90)
    , 42);
}

test "converter reference returns retain ordinary conservative input origins" {
    const declarations =
        \\struct Source
        \\    move = none
        \\    value: int
        \\converter(value: Source) Ref(Source) -> Ref.from(value)
        \\
    ;
    try Fixture.expectSourceExit(declarations ++ "const source = Source{value = 42}\nconst reference: Ref(Source) = source\nexit(reference.value.value)", 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "func escape() Ref(Source)\n    const source = Source{value = 42}\n    return source\nconst reference = escape()\nexit(reference.value.value)", .borrow_outlives_source);
}

test "converter constraints are not evaluated to infer a generic operation" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target where 1 == 0 -> Target{value = value.value}
        \\func unresolved(static T: type, value: Target) int -> value.value
        \\exit(unresolved(Source{value = 42}))
    , .static_argument_cannot_be_inferred);
}

test "initializer inference fails before converter constraints are evaluated" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target where 0 == 1 -> Target{value = value.value}
        \\func unresolved(static T: type, init value: Target) int | none -> 42
        \\if const answer: int = unresolved(Source{value = 42}) -> exit(answer)
        \\exit(90)
    , .static_argument_cannot_be_inferred);
}

test "nested conversions defer constraints until argument inference succeeds" {
    const declarations =
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\struct Wrapper
        \\    copy = trivial
        \\    inner: Target
        \\func stop() unit | none -> exit(42)
        \\
    ;
    const cases = [_]struct { parameter: []const u8, expression: []const u8 }{
        .{ .parameter = "Wrapper", .expression = "Wrapper{inner = Source{value = 42}}" },
        .{ .parameter = "Wrapper", .expression = "loop -> break Wrapper{inner = Source{value = 42}}" },
        .{ .parameter = "Array(Wrapper, 1)", .expression = "[Wrapper{inner = Source{value = 42}}]" },
        .{ .parameter = "Array(Wrapper, 1)", .expression = "loop -> break [Wrapper{inner = Source{value = 42}}]" },
    };
    for ([_][]const u8{ "0 == 1", "stop()" }) |constraint| {
        for ([_][]const u8{ "", "init " }) |mode| {
            for (cases) |case| {
                const source = try std.fmt.allocPrint(testing.allocator, "{s}converter(value: Source) Target where {s} -> Target{{value = value.value}}\nfunc unresolved(static T: type, {s}value: {s}) int -> 42\nif const answer: int = unresolved({s}) -> exit(answer)\nexit(90)", .{ declarations, constraint, mode, case.parameter, case.expression });
                defer testing.allocator.free(source);
                try Fixture.expectAnySourceDiagnostic(source, .static_argument_cannot_be_inferred);
            }
        }
    }
    try Fixture.expectAnySourceDiagnostic(declarations ++
        \\converter(value: Source) Target where 0 == 1 -> Target{value = value.value}
        \\func construct(init value: Wrapper) Wrapper | none -> value
        \\if const answer: Wrapper = construct(loop -> break Wrapper{inner = Source{value = 42}}) -> exit(answer.inner.value)
        \\exit(90)
    , .where_condition_failed);
}

test "initializer inference does not execute converters inside static sources" {
    const declarations =
        \\static struct Source
        \\    copy = trivial
        \\    value: byte
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: Source) Target -> Target{value = 42}
        \\struct Wrapper
        \\    copy = trivial
        \\    inner: Target
        \\
    ;
    try Fixture.expectAnySourceDiagnostic(declarations ++
        \\func unresolved(static T: type, init value: Wrapper) int | none -> 42
        \\if const answer: int = unresolved(loop -> break Wrapper{inner = Source{value = 300}}) -> exit(answer)
        \\exit(90)
    , .static_argument_cannot_be_inferred);
    try Fixture.expectAnySourceDiagnostic(declarations ++
        \\func construct(init value: Wrapper) Wrapper | none -> value
        \\if const answer: Wrapper = construct(loop -> break Wrapper{inner = Source{value = 300}}) -> exit(answer.inner.value)
        \\exit(90)
    , .where_condition_failed);
    try Fixture.expectSourceExit(declarations ++
        \\func construct(init value: Wrapper) Wrapper | none -> value
        \\if const answer: Wrapper = construct(loop -> break Wrapper{inner = Source{value = 42}}) -> exit(answer.inner.value)
        \\exit(90)
    , 42);
}

test "specialized init arguments convert once only when constructed" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    move = none
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\func make(mut counter: int) Source
        \\    counter += 1
        \\    return Source{value = 42}
        \\func skip(init value: Target) Target | none -> return none
        \\func construct(static T: type, init value: Target, marker: T) Target | none -> value
        \\func run() int
        \\    var counter = 0
        \\    if const unused: Target = skip(make(counter)) -> return 90
        \\    if counter == 0
        \\        if const target: Target = construct(make(counter), 0)
        \\            if counter == 1 -> return target.value
        \\    return 91
        \\static result = run()
        \\exit(run() + result - 42)
    , 42);
}

test "literal converters inspect wide signed values without defaulting to int" {
    try Fixture.expectSourceExit(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: int_literal) Target where value > 2147483647 -> Target{value = 42}
        \\const first: Target = 9223372036854775807
        \\if first.value == 42 -> exit(first.value) else exit(90)
    , 42);
    try Fixture.expectSourceExit(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: int_literal) Target where value == -9223372036854775808 -> Target{value = 42}
        \\const selected: Target = -9223372036854775808
        \\exit(selected.value)
    , 42);
    try Fixture.expectAnySourceDiagnostic("const value: byte = 9223372036854775807\nexit(0)", .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic("const value: byte = -9223372036854775808\nexit(0)", .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic("const value = -0xff\nexit(0)", .integer_literal_not_decimal);
    try Fixture.expectAnySourceDiagnostic("const value = -1.5\nexit(0)", .float_literal_not_supported);
    try Fixture.expectSourceExit("static literal: int_literal = 42\nconst value: byte = literal\nfunc take(imm item: byte) int -> 42\nexit(take(value))", 42);
}

test "compile-time local literal values retain checked int defaults" {
    try Fixture.expectSourceExit(
        \\func take(value: int) int -> value
        \\func infer(static T: type, value: T) int where T == int -> value
        \\func literalValue() int_literal -> 42
        \\struct Holder
        \\    copy = fieldwise
        \\    literal: int_literal
        \\func compute() int
        \\    var literal: int_literal = 40
        \\    literal = 42
        \\    const direct: int = literal
        \\    const inferred = literal
        \\    const variant: int | byte = literal
        \\    const from_call = literalValue()
        \\    const holder = Holder{literal = 42}
        \\    const from_field = holder.literal
        \\    if const selected: int = variant -> return direct + inferred + selected + take(literal) + infer(literal) + from_call + from_field + take(literalValue()) + literalValue() - 336
        \\    return 90
        \\static answer = compute()
        \\exit(answer)
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\func compute() int
        \\    const literal: int_literal = 2147483648
        \\    const value: int = literal
        \\    return value
        \\static answer = compute()
        \\exit(answer)
    , .integer_literal_out_of_range);
}

test "static converter candidates skip other source factories without specialization errors" {
    try Fixture.expectSourceExit(
        \\static struct First(T: type)
        \\    copy = fieldwise
        \\    value: T
        \\static struct Second(T: type)
        \\    copy = fieldwise
        \\    value: T
        \\struct Target(T: type)
        \\    copy = fieldwise
        \\    value: T
        \\converter(static T: type, static value: First(T)) Target(T) -> Target(T){value = value.value}
        \\converter(static T: type, static value: Second(T)) Target(T) -> Target(T){value = value.value}
        \\const first: Target(int) = First(int){value = 40}
        \\const second: Target(int) = Second(int){value = 2}
        \\exit(first.value + second.value)
    , 42);
}

test "converters accept compile-time-only aggregate source annotations" {
    try Fixture.expectSourceExit(
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\struct Wrapper
        \\    copy = fieldwise
        \\    data: Data
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: Wrapper) Target -> Target{value = value.data.value}
        \\converter(static value: Array(Data, 0)) Target -> Target{value = 42}
        \\const wrapped: Target = Wrapper{data = Data{value = 42}}
        \\const empty: Target = Array(Data, 0).filled(Data{value = 0})
        \\exit(wrapped.value + empty.value - 42)
    , 42);
}

test "generic wrapper converter source mode follows specialized contained types" {
    try Fixture.expectSourceExit(
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\struct Wrapper(T: type)
        \\    copy = fieldwise
        \\    value: T
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, static source: Wrapper(T)) Target -> Target{value = source.value.value}
        \\const converted: Target = Wrapper(Data){value = Data{value = 42}}
        \\exit(converted.value)
    , 42);
}

test "converted values cannot borrow mutable authority from the original source place" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\func change(mut value: Target)
        \\    value.value = 42
        \\var source = Source{value = 20}
        \\change(source)
        \\exit(source.value)
    , .mutable_argument_requires_place);
}

test "generic calls convert known parameters only after loop argument inference" {
    try Fixture.expectSourceExit(
        \\func take(static T: type, value: T, literal: byte) int -> value
        \\exit(take(loop -> break 42, 255))
    , 42);
}

test "generic inference preserves converter evaluation before later argument writes" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    move = none
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\func take(static T: type, first: Target, later: T) int -> first.value
        \\var source = Source{value = 42}
        \\exit(take(source, loop
        \\    source.value = 90
        \\    break 0))
    , 42);
}

test "static converters accept ordinary compile-time parameters" {
    try Fixture.expectSourceExit(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static source: Source) Target -> Target{value = source.value}
        \\func convert(imm source: Source) int
        \\    const target: Target = source
        \\    return target.value
        \\static result = convert(Source{value = 42})
        \\exit(result)
    , 42);
}

test "compile-time static-only values retain builtin variant widening" {
    try Fixture.expectSourceExit(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\func compute() int
        \\    var source = Source{value = 40}
        \\    source.value += 2
        \\    const variant: Source | none = source
        \\    if const selected: Source = variant -> return selected.value else return 90
        \\static result = compute()
        \\exit(result)
    , 42);
}

test "static converters accept mutated compile-time local sources" {
    try Fixture.expectSourceExit(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    move = none
        \\    copy = trivial
        \\    value: int
        \\converter(static source: Source) Target -> Target{value = source.value}
        \\func compute() int
        \\    var source = Source{value = 40}
        \\    source.value += 2
        \\    const converted: Target = source
        \\    return converted.value
        \\static result = compute()
        \\exit(result)
    , 42);
}

test "staged static field sources support immovable assignments and returns" {
    try Fixture.expectSourceExit(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Holder
        \\    copy = fieldwise
        \\    source: Source
        \\struct Target
        \\    move = none
        \\    copy = trivial
        \\    value: int
        \\converter(static source: Source) Target -> Target{value = source.value}
        \\func convert(imm holder: Holder) Target -> holder.source
        \\func run() int
        \\    var holder = Holder{source = Source{value = 40}}
        \\    var target: Target = holder.source
        \\    holder.source.value += 2
        \\    target = holder.source
        \\    return target.value + convert(holder).value - 42
        \\static answer = run()
        \\exit(answer)
    , 42);
}

test "staged static conversion specializes and checks the current source value" {
    const declaration =
        \\static struct Source(T: type)
        \\    copy = trivial
        \\    value: T
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, static source: Source(T)) Target where source.value >= 0 -> Target{value = source.value}
        \\
    ;
    try Fixture.expectSourceExit(declaration ++
        \\func compute() int
        \\    var source = Source(int){value = 40}
        \\    source.value += 2
        \\    const target: Target | none = source
        \\    if const selected: Target = target -> return selected.value else return 90
        \\static result = compute()
        \\exit(result)
    , 42);
    try Fixture.expectAnySourceDiagnostic(declaration ++
        \\func compute() int
        \\    var source = Source(int){value = 40}
        \\    source.value = -1
        \\    const target: Target = source
        \\    return target.value
        \\static result = compute()
        \\exit(result)
    , .where_condition_failed);
    try Fixture.expectAnySourceDiagnostic(declaration ++
        \\func compute() int
        \\    var source = Source(int){value = 40}
        \\    source.value += 2
        \\    const target: Target = source
        \\    return target.value
        \\exit(compute())
    , .compile_time_only_type);
}

test "converter candidates match source types before validating source modes" {
    try Fixture.expectSourceExit(
        \\struct RuntimeSource
        \\    copy = trivial
        \\    value: int
        \\static struct StaticSource
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: RuntimeSource) Target -> Target{value = value.value}
        \\converter(static value: StaticSource) Target -> Target{value = value.value}
        \\converter(static value: int_literal) Target -> Target{value = value}
        \\func run() int
        \\    const runtime: Target = RuntimeSource{value = 10}
        \\    const constant: Target = StaticSource{value = 20}
        \\    const literal: Target = 12
        \\    return runtime.value + constant.value + literal.value
        \\func compute() int
        \\    var source = StaticSource{value = 40}
        \\    source.value += 2
        \\    const converted: Target | none = source
        \\    if const selected: Target = converted -> return selected.value
        \\    return 90
        \\static answer = compute()
        \\exit(run() + answer - 42)
    , 42);
}

test "converter signature probes retain bare inferred source and target types" {
    try Fixture.expectSourceExit(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, value: T) Target where T == int -> Target{value = value}
        \\func run() int
        \\    const source = 42
        \\    const converted: Target = source
        \\    return converted.value
        \\static answer = run()
        \\exit(run() + answer - 42)
    , 42);
    try Fixture.expectSourceExit(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, value: Source) T where T == int -> value.value
        \\func run() int -> Source{value = 42}
        \\static answer = run()
        \\exit(run() + answer - 42)
    , 42);
}

test "static converter source type parameters resolve after inference" {
    try Fixture.expectSourceExit(
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static T: type, static source: T) Target -> Target{value = source.value}
        \\func compute() int
        \\    var source = Source{value = 40}
        \\    source.value += 2
        \\    const converted: Target = source
        \\    return converted.value
        \\static answer = compute()
        \\const direct: Target = Source{value = 42}
        \\exit(answer + direct.value - 42)
    , 42);
}

test "annotated compile-time literal locals retain byte conversion after mutation" {
    const fixture = try Fixture.init(
        \\func compute() byte
        \\    var source: int_literal = 40
        \\    source = 42
        \\    const copied: int_literal = source
        \\    const converted: byte = copied
        \\    return converted
        \\static answer = compute()
        \\func use(value: byte) int -> 42
        \\exit(use(answer))
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const scope = (try fixture.db.get(sources.queries.BuildModuleScope, 0)).*.?;
    const answer = (try fixture.db.get(sources.queries.ResolveStatic, scope.resolve("answer").?)).*.?;
    const value = try fixture.db.lookupInterned(sources.queries.CompileTimeValues, answer);
    try testing.expectEqual(@as(u8, 42), value.runtime.value.byte);
}

test "annotated compile-time literals preserve wide signed values for converters" {
    try Fixture.expectSourceExit(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: int_literal) Target
        \\    if value == 9223372036854775807 -> return Target{value = 20}
        \\    if value == -9223372036854775808 -> return Target{value = 22}
        \\    return Target{value = 90}
        \\func compute() int
        \\    const maximum: int_literal = 9223372036854775807
        \\    const minimum: int_literal = -9223372036854775808
        \\    const first: Target = maximum
        \\    const second: Target = minimum
        \\    return first.value + second.value
        \\static answer = compute()
        \\exit(answer)
    , 42);
}

test "optional arguments convert predicate outcomes and query boolean data" {
    try Fixture.expectParity(
        \\func run() int
        \\    const yes = bool(1 < 2)
        \\    const no = bool(2 < 1)
        \\    const identity = bool(false)
        \\    if yes and not no and not identity -> return 42
        \\    return 7
    , 42);
}

test "optional arguments preserve ordinary absence through repeated reads" {
    try Fixture.expectParity(
        \\func number(mut count: int) int | none
        \\    count += 1
        \\    return none
        \\func inspect(value: int | none) int
        \\    if const first: int = value -> return first
        \\    if value is int -> return 9
        \\    return 41
        \\func run() int
        \\    var count = 0
        \\    return inspect(number(count)) + count
    , 42);
}

test "optional arguments are eager and ordinary absence does not skip later arguments" {
    try Fixture.expectParity(
        \\func mark(mut order: int, digit: int) int | none
        \\    order = order * 10 + digit
        \\    if digit == 1 -> return none
        \\    return digit
        \\func receive(first: int | none, second: int | none, snapshot: int) int
        \\    if first is int -> return 99
        \\    if const value: int = second -> return snapshot + value
        \\    return 98
        \\func run() int
        \\    var order = 0
        \\    return receive(mark(order, 1), mark(order, 2), order)
    , 14);
}

test "predicate operands and optional Boolean results require explicit selection" {
    try Fixture.expectParity(
        \\func number() int | none -> return none
        \\func flag() bool | none -> return none
        \\func below() bool | none
        \\    const value: int = number() else return none
        \\    return value < 3
        \\func run() int
        \\    if const result: bool = below()
        \\        if result -> return 1
        \\    if const _: bool = flag() -> return 2
        \\    if below() is none -> return 42
        \\    return 3
    , 42);
}

test "optional argument types survives callable values and forwarding" {
    try Fixture.expectParity(
        \\func missing() int | none -> return none
        \\func value_or(value: int | none, fallback: int) int
        \\    if const found: int = value -> return found
        \\    return fallback
        \\func forward(value: int | none) int -> value_or(value, 42)
        \\func apply(handler: func(int | none) int, value: int | none) int -> handler(value)
        \\func run() int -> apply(forward, missing())
    , 42);
}

test "optional arguments use ordinary mutable variant places and optional references" {
    try Fixture.expectParity(
        \\func change(mut value: int | none)
        \\    if const found: int = value -> value = found + 1
        \\func forward(mut value: int | none) -> change(value)
        \\func update(var reference: Ref(int) | none)
        \\    if ref found: Ref(int) = reference -> found.value += 1
        \\func missing() Ref(int) | none -> return none
        \\func run() int
        \\    var value: int | none = 40
        \\    forward(value)
        \\    var array = [0]
        \\    update(Ref.from(array[0]))
        \\    update(missing())
        \\    if const found: int = value
        \\        if const last: int = array.get(0) -> return found + last
        \\    return 0
    , 42);
}

test "optional arguments forward owned payloads and clean up after later argument failure" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        if self.value <> 42 -> exit(91)
        \\func missing() int | none -> return none
        \\func consume(var item: Item | none, value: int)
        \\    if item is Item -> ()
        \\func work() unit | none
        \\    consume(Item{value = 42}, (if const _selected_result_0: int = missing() -> _selected_result_0 else return none))
        \\    return ()
        \\func run() int
        \\    if (work() is unit) -> return 7
        \\    return 42
    , 42);
}

test "ordinary arguments destroy prepared copies after later failure" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    trace: Ref(int)
        \\    copy = func(imm self: Item) Item -> Item{value = self.value, trace = self.trace}
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += self.value
        \\func missing() int | none -> return none
        \\func consume(var item: Item, final: int) -> ()
        \\func work(imm trace: Ref(int)) unit | none
        \\    const original = Item{value = 21, trace = trace}
        \\    consume(original, (if const _selected_result_0: int = missing() -> _selected_result_0 else return none))
        \\    return ()
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle: int = trace.get(0)
        \\        if (work((if const _selected_result_1: Ref(int) = Ref.from(handle) -> _selected_result_1 else panic "unexpected none")) is unit) -> return 91
        \\        return handle
        \\    return 92
    , 42);
}

test "optional arguments destroy captured owners after later ordinary failure" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    trace: Ref(int)
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += self.value
        \\func make(imm trace: Ref(int), value: int, enabled: bool) Item | none
        \\    if not enabled -> return none
        \\    return Item{value = value, trace = trace}
        \\func missing() int | none -> return none
        \\func consume(var first: Item | none, var second: Item | none, var third: Item | none, final: int) -> ()
        \\func work(imm trace: Ref(int)) unit | none
        \\    consume(make(trace, 10, false), make(trace, 11, false), make(trace, 42, true), (if const final: int = missing() -> final else return none))
        \\    return ()
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle: int = trace.get(0)
        \\        if (work((if const _selected_result_4: Ref(int) = Ref.from(handle) -> _selected_result_4 else panic "unexpected none")) is unit) -> return 91
        \\        return handle
        \\    return 92
    , 42);

    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    trace: Ref(int)
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += self.value
        \\func make(imm trace: Ref(int), value: int, enabled: bool) Item | none
        \\    if not enabled -> return none
        \\    return Item{value = value, trace = trace}
        \\func finish(enabled: bool) int | none
        \\    if not enabled -> return none
        \\    return 0
        \\func consume(var first: Item | none, var second: Item | none, var third: Item | none, final: int) -> ()
        \\func work(imm trace: Ref(int), mask: int) unit | none
        \\    consume(make(trace, 1, mask % 2 == 1), make(trace, 2, mask / 2 % 2 == 1), make(trace, 4, mask / 4 % 2 == 1), (if const final: int = finish(mask / 8 == 1) -> final else return none))
        \\    return ()
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle: int = trace.get(0)
        \\        var mask = 0
        \\        loop
        \\            if mask == 16 -> break
        \\            if (work((if const _selected_result_4: Ref(int) = Ref.from(handle) -> _selected_result_4 else panic "unexpected none"), mask) is unit) -> ()
        \\            mask += 1
        \\        return handle
        \\    return 92
    , 56);
}

test "optional arguments preserve variant values in deferred initializer captures" {
    try Fixture.expectParity(
        \\func missing() int | none -> return none
        \\func construct(init value: int | none) int | none -> value
        \\func receive(value: int | none) int
        \\    if const found: int = construct(value) -> return found
        \\    return 42
        \\func run() int -> receive(missing())
    , 42);
}

test "optional arguments include nested construction and extraction failures" {
    try Fixture.expectParity(
        \\struct Pair
        \\    copy = trivial
        \\    first: int
        \\    second: int
        \\func missing() int | none -> return none
        \\func construct() Pair | none
        \\    return Pair{first = 1, second = (if const second: int = missing() -> second else return none)}
        \\func receive(pair: Pair | none) int
        \\    if const found: Pair = pair -> return found.first
        \\    return 40
        \\func value_or(value: int | none, fallback: int) int
        \\    if const found: int = value -> return found
        \\    return fallback
        \\func run() int
        \\    const variant: int | none = none
        \\    return receive(construct()) + value_or(variant, 2)
    , 42);
}

test "optional arguments capture complete loop expressions in converters" {
    try Fixture.expectParity(
        \\func run() int
        \\    const result = bool(loop -> break 2 < 1)
        \\    if not result -> return 42
        \\    return 7
    , 42);
}

test "optional arguments accept immovable payloads without relocation" {
    try Fixture.expectParity(
        \\import std.memory
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\func make() Pinned | none -> Pinned{value = 42}
        \\func receive(var value: Pinned | none) int
        \\    if ref found: Pinned = value -> return found.value
        \\    return 7
        \\func run() int -> receive(make())
    , 42);
}

test "optional converter inputs handle whole expressions through ordinary variants" {
    try Fixture.expectParity(
        \\struct Number
        \\    copy = trivial
        \\    value: int
        \\converter(value: int | none) Number
        \\    if const found: int = value -> return Number{value = found}
        \\    return Number{value = 42}
        \\func missing() int | none -> return none
        \\func increment() int | none
        \\    const value: int = missing() else return none
        \\    return value + 1
        \\func run() int -> Number(increment()).value
    , 42);
}

test "optional arguments borrow existing variants and own newly constructed payloads" {
    try Fixture.expectParity(
        \\import std.memory
        \\struct Item
        \\    copy = none
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.value = 0
        \\func inspect(item: Item | none) int
        \\    if ref found: Item = item -> return found.value
        \\    return 7
        \\func run() int
        \\    const existing: Item | none = Item{value = 21}
        \\    return inspect(existing) + inspect(Item{value = 21})
    , 42);
}

test "optional arguments receive explicit type mismatch results without a fake payload" {
    try Fixture.expectParity(
        \\func receive(value: int | none) int
        \\    if const found: int = value -> return found
        \\    return 42
        \\func run() int
        \\    const value: int | none = 1
        \\    return receive(if const _: bool = value -> 0 else none)
    , 42);
}

test "optional deinit arguments use ordinary variant construction and cleanup" {
    try Fixture.expectParity(
        \\import std.memory
        \\struct Item
        \\    copy = none
        \\    value: int
        \\    drop = func(deinit self: Item) -> ()
        \\func inspect(deinit item: Item | none) int
        \\    if ref found: Item = item -> return found.value
        \\    return 0
        \\func absent() Item | none -> return none
        \\func run() int -> inspect(Item{value = 42}) + inspect(absent())
    , 42);
}

test "optional callable inputs preserve ordinary variant return types" {
    try Fixture.expectParity(
        \\func identity(value: int) int | none -> value
        \\func apply(handler: func(int) (int | none)) int
        \\    if const value: int = handler(42) -> return value
        \\    return 0
        \\func accepted(handler: (func(int) (int | none)) | none) int
        \\    if const callable: func(int) (int | none) = handler
        \\        if const value: int = callable(42) -> return value
        \\    return 0
        \\func relay(handler: func((func(int) (int | none)) | none) int) int -> handler(identity)
        \\func ordinary(handler: func(func(int) (int | none)) int) int -> handler(identity)
        \\func run() int -> relay(accepted) + ordinary(apply) - 42
    , 42);
}

test "optional deferred initializers are selected explicitly by their receiver" {
    try Fixture.expectParity(
        \\func absent(mut count: int) unit | none
        \\    count += 1
        \\    return none
        \\func outcome(init value: unit | none) bool -> value is unit
        \\func queried(init value: bool) int
        \\    if value -> return 2
        \\    return 1
        \\func run() int
        \\    var count = 0
        \\    const flag = outcome(absent(count))
        \\    if flag -> return 99
        \\    return queried(false) + count + 40
    , 42);
}

test "optional arguments bind owned copies of borrowed successful payloads" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\    drop = func(deinit self: Item) -> self.value = 0
        \\func copied(item: Item | none) int
        \\    if const owned: Item = item -> return owned.value
        \\    return 0
        \\func run() int
        \\    var item = Item{value = 41}
        \\    const result = copied(item)
        \\    return result + item.value - 41
    , 42);
}

test "optional arguments retain temporary owners behind returned borrows" {
    try Fixture.expectParity(
        \\import std.memory
        \\func make() String | none
        \\    var value = String.empty()
        \\    const _: unit = value.append("42") else return none
        \\    return value^
        \\func selected(text: String | none) StringView
        \\    if ref found: String = text -> return found.view()
        \\    return ""
        \\func run() int
        \\    const view = selected(make())
        \\    if view == "42" -> return 42
        \\    return 0
    , 42);
}

test "optional arguments require explicit destruction only for present owned payloads" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\    value: int
        \\func dispose(deinit token: Token) int -> token.value
        \\func accepted(var token: Token | none) int
        \\    if const found: Token = token^ -> return dispose(found)
        \\    return 0
        \\func absent() Token | none -> return none
        \\func run() int -> accepted(Token{value = 42}) + accepted(absent())
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Token
        \\    drop = explicit
        \\    value: int
        \\func ignored(var token: Token | none) -> ()
        \\ignored(Token{value = 42})
    , .value_requires_explicit_drop);
}

test "optional values forward through deferred initializer captures" {
    try Fixture.expectParity(
        \\func materialize(init value: int | none) int
        \\    if const found: int = value -> return found
        \\    return 42
        \\func forward(value: int | none) int -> materialize(value)
        \\func missing() int | none -> return none
        \\func run() int -> forward(missing())
    , 42);
}

test "ordinary optional variants work in bindings assignments fields and returns" {
    try Fixture.expectParity(
        \\struct Holder
        \\    copy = fieldwise
        \\    number: int | none
        \\    predicate: bool
        \\    flag: bool
        \\func missing() int | none -> return none
        \\func optional() int | none
        \\    const value: int = missing() else return none
        \\    return value + 1
        \\func run() int
        \\    const saved: int | none = missing()
        \\    var assigned: int | none = 42
        \\    assigned = optional()
        \\    const holder = Holder{number = missing(), predicate = 2 < 1, flag = 1 < 2}
        \\    const numbers: Array(int | none, 2) = [missing(), 42]
        \\    if saved is none and assigned is none and holder.number is none and not holder.predicate
        \\        if holder.flag and optional() is none
        \\            if numbers[0] is none
        \\                if const found: int = numbers[1] -> return found
        \\    return 0
    , 42);
}

test "explicit mismatch exits compound expressions exactly once without rollback" {
    try Fixture.expectParity(
        \\func step(mut count: int, succeeds: bool) int | none
        \\    count += 1
        \\    if not succeeds -> return none
        \\    return count
        \\func total(mut count: int) int | none
        \\    const first: int = step(count, true) else return none
        \\    const second: int = step(count, false) else return none
        \\    const third: int = step(count, true) else return none
        \\    return first + second + third
        \\func inspect(value: int | none, count: int) int
        \\    if value is none and value is none -> return count
        \\    return 90
        \\func run() int
        \\    var count = 0
        \\    const seen = inspect(total(count), count)
        \\    return seen + count + 38
    , 42);
}

test "variants without none propagate failure and skip later arguments" {
    try Fixture.expectParity(
        \\func step(mut count: int, succeeds: bool) int | none
        \\    count += 1
        \\    if not succeeds -> return none
        \\    return count
        \\func receive(value: int | bool, later: int) unit -> exit(91)
        \\func work(mut count: int) unit | none
        \\    receive((if const _selected_result_0: int = step(count, false) -> _selected_result_0 else return none), (if const _selected_result_1: int = step(count, true) -> _selected_result_1 else return none))
        \\    return ()
        \\func run() int
        \\    var count = 0
        \\    if (work(count) is unit) -> return 92
        \\    return count + 41
    , 42);
}

test "captured none and successful none are ordinary identical variant values" {
    try Fixture.expectParity(
        \\func missing() int | none -> return none
        \\func inspect(value: int | none) int
        \\    if const found: int = value -> return found
        \\    if value is none -> return 14
        \\    return 90
        \\func run() int
        \\    const yes = unit is unit
        \\    const no = none is int
        \\    if yes and not no -> return inspect(none) + inspect(missing()) + inspect(14)
        \\    return 91
    , 42);
}

test "explicit mismatch destroys partially constructed successful prefixes" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 42
        \\struct Pair
        \\    copy = none
        \\    first: Item
        \\    second: int
        \\func missing() int | none -> return none
        \\func construct(trace: Ref(int)) Pair | none
        \\    return Pair{first = Item{trace = trace}, second = (if const value: int = missing() -> value else return none)}
        \\func receive(value: Pair | none) unit
        \\    if not (value is none) -> exit(91)
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle: int = trace.get(0)
        \\        receive(construct(Ref.from(handle)))
        \\        return handle
        \\    return 92
    , 42);
}

test "optional receiver parameters accept ordinary variant values" {
    try Fixture.expectParity(
        \\struct Number
        \\    copy = trivial
        \\    value: int
        \\    pub func fallback(self: Number | none) int
        \\        if const found: Number = self -> return found.value
        \\        return 42
        \\func absent() Number | none -> return none
        \\func run() int -> Number.fallback(absent()) + Number{value = 21}.fallback() - 21
    , 42);
}

test "optional converter inputs preserve ordinary target construction" {
    try Fixture.expectParity(
        \\struct Number
        \\    copy = trivial
        \\    value: int
        \\converter(value: int | none) Number
        \\    if const found: int = value -> return Number{value = found}
        \\    return Number{value = 21}
        \\struct Holder
        \\    number: Number
        \\    flag: bool
        \\func missing() int | none -> return none
        \\func run() int
        \\    const holder = Holder{number = missing(), flag = 1 < 2}
        \\    const saved: Number = missing()
        \\    if holder.flag -> return holder.number.value + saved.value
        \\    return 0
    , 42);
}

test "optional converter outputs construct immovable members in their final variant storage" {
    try Fixture.expectParity(
        \\import std.memory
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\converter(value: int | none) Pinned
        \\    if const found: int = value -> return Pinned{value = found}
        \\    return Pinned{value = 21}
        \\func receive(var value: Pinned | none) int
        \\    if ref found: Pinned = value -> return found.value
        \\    return 0
        \\func missing() int | none -> return none
        \\func run() int -> receive(21) + receive(Pinned(missing()))
    , 42);
}

test "specialized optional parameter types capture inferred integer inputs" {
    try Fixture.expectParity(
        \\func value_or(static T: type, value: T | none, fallback: T) T
        \\    if const found: T = value -> return found
        \\    return fallback
        \\func missing() int | none -> return none
        \\func run() int -> value_or(missing(), 40) + value_or(2, 0)
    , 42);
}

test "optional converters accept ordinary absence without a successful payload" {
    try Fixture.expectParity(
        \\func missing() never | none -> return none
        \\struct Flag
        \\    value: bool
        \\converter(value: int | none) Flag -> Flag{value = value is int}
        \\func run() int
        \\    const value: int | none = 1
        \\    const first: Flag = if const _: bool = value -> 0 else none
        \\    const second: Flag = missing()
        \\    if not first.value and not second.value -> return 42
        \\    return 0
    , 42);
}

test "converter selection preserves static literal converters before integer defaults" {
    try Fixture.expectParity(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static value: int_literal) Target -> Target{value = 42}
        \\converter(value: int | none) Target -> Target{value = 99}
        \\func run() int
        \\    const small: Target = 7
        \\    const wide: Target = 2147483648
        \\    if small.value == 42 and wide.value == 42 -> return 42
        \\    return 90
    , 42);
}

test "converter selection handles absence independently of placement" {
    try Fixture.expectParity(
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\struct Holder
        \\    item: Pinned
        \\converter(value: int | none) Pinned
        \\    if const found: int = value -> return Pinned{value = found}
        \\    return Pinned{value = 21}
        \\func absent() never | none -> return none
        \\func borrowed(imm value: Pinned) int -> value.value
        \\func owned(var value: Pinned) int -> value.value
        \\func optional_borrowed(imm value: Pinned | none) int
        \\    if value is none -> return 90
        \\    return 21
        \\func optional_owned(var value: Pinned | none) int
        \\    if value is none -> return 91
        \\    return 21
        \\func make() Pinned -> absent()
        \\func run() int
        \\    const saved: Pinned = absent()
        \\    const holder = Holder{item = absent()}
        \\    const returned = make()
        \\    if saved.value == 21 and holder.item.value == 21 and returned.value == 21
        \\        if borrowed(absent()) == 21 and owned(absent()) == 21
        \\            if optional_borrowed(absent()) <> 90 or optional_owned(absent()) <> 91 -> return 93
        \\            if optional_borrowed(Pinned(absent())) == 21 and optional_owned(Pinned(absent())) == 21 -> return 42
        \\    return 92
    , 42);
}

test "optional boolean variants preserve explicit none before considering converters" {
    try Fixture.expectParity(
        \\func score(value: bool | none) int
        \\    if const found: bool = value
        \\        if found -> return 10
        \\        return 0
        \\    return 12
        \\func run() int
        \\    const saved: bool | none = none
        \\    var assigned: bool | none = true
        \\    assigned = none
        \\    const converted: bool | none = none
        \\    if const _: bool = converted -> return 91
        \\    return score(saved) + score(assigned) + score(none) + 6
    , 42);
}

test "conditional literal conversions preserve permanent views and nested defaults" {
    try Fixture.expectParity(
        \\func choose(flag: bool) StringView -> if flag -> "yes" else "no"
        \\func run() int
        \\    const first = choose(true)
        \\    const second = choose(false)
        \\    if first == "yes" and second == "no" -> return 42
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func append(mut count: int) int | none
        \\    var text = ""
        \\    count += 1
        \\    const _: unit = text.append(if count == 1 -> "a" else if count == 2 -> "bb" else "ccc") else return none
        \\    return text.byte_length() + count + 40
        \\func run() int
        \\    var count = 0
        \\    if const result: int = append(count) -> return result
        \\    return 90
    , 42);
}
