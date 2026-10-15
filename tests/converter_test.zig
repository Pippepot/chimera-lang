const std = @import("std");
const sources = @import("test_sources");
const testing = std.testing;

const Fixture = sources.SourceFixture;

test "converter parameter writes retain newly installed loans" {
    const declarations =
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\struct Done
        \\    marker: int
        \\converter(imm input: Install) Done
        \\    input.target.value = input.source
        \\    return Done{marker = 0}
    ;
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func selected(ref initial: int) Ref(int)
        \\    var result = Ref.from(initial)
        \\    var local = 42
        \\    _ = Done(Install{target = Ref.from(result), source = Ref.from(local)})
        \\    return result
        \\var initial = 17
        \\exit(selected(initial).value)
    , .borrow_outlives_source);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func selected(ref initial: int, ref source: int) Ref(int)
        \\    var result = Ref.from(initial)
        \\    _ = Done(Install{target = Ref.from(result), source = Ref.from(source)})
        \\    return result
        \\func run() int
        \\    var initial = 17
        \\    var source = 42
        \\    return selected(initial, source).value
    , 42);
}

test "optional generic inference uses payload evidence and captures failure" {
    try Fixture.expectParity(
        \\func identity(static T: type, value: T | none) T | none -> value
        \\fallible absent() int -> fail
        \\func run() int
        \\    const found = identity(42)
        \\    if not (found is int) -> return 90
        \\    if identity(absent?()) is int -> return 91
        \\    if const answer = found as int -> return answer
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
        \\    if const answer = result as int -> return answer
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
        \\    if const found = identity(original) as Wrapper(int) -> return found.value
        \\    return 90
    , 42);
}

test "optional generic inference accepts none when another argument supplies the type" {
    try Fixture.expectParity(
        \\func before(static T: type, value: T | none, fallback: T) T
        \\    if const found = value as T -> return found
        \\    return fallback
        \\func after(static T: type, fallback: T, value: T | none) T
        \\    if const found = value as T -> return found
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
        \\    if const answer = wrapped.value as int -> return answer
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

test "collection literals construct infallible arrays without failure handling" {
    try Fixture.expectSourceExit(
        \\func count() int
        \\    const values: Array(int, 2) = [19, 23]
        \\    return values.len()
        \\exit(count())
    , 2);
}

test "consuming converters propagate initializer failure but cannot introduce unrelated failure" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\fallible unrelated() -> fail
        \\converter(static N: int, init value: collection_literal(int, N)) Target
        \\    const source: Array(int, N) = value
        \\    unrelated?()
        \\    return Target{value = source.len()}
        \\const target: Target = [42]
        \\exit(target.value)
    , .fallible_expression_outside_fallible_function);
}

test "consuming collection converters inherit concrete effects with native and interpreter parity" {
    try Fixture.expectParity(
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static N: int, init value: collection_literal(int, N)) Target
        \\    const source: Array(int, N) = value
        \\    return Target{value = source.len() + 40}
        \\fallible missing() int -> fail
        \\func run() int
        \\    const target: Target = [19, 23]
        \\    if const failed: Target = [missing?()] -> return 91
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
        \\if const selected = data as Data -> exit(selected.value) else exit(90)
        ,
        \\static struct Data
        \\    copy = trivial
        \\    value: int
        \\const data = Array(Data, 0).filled(Data{value = 42})
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
    try Fixture.expectAnySourceDiagnostic(declaration ++ "import std.memory.{Allocation}\nif const storage = Allocation(Data).allocate(1)\n    storage^.deallocate()\nexit(0)", .compile_time_only_type);
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
        \\if const selected = converted as Target -> exit(selected.value) else exit(90)
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
        \\const bytes = Array(byte, 1).filled(byte_value)
        \\if const selected = variant as int
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
        \\if const selected = result as int -> exit(selected) else exit(90)
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
        \\if const selected = result as int -> exit(selected) else exit(90)
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

test "conversion does not chain or preconvert source variants" {
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
}

test "builtin widening competes with member converters" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(value: Source) Target -> Target{value = value.value}
        \\const result: Source | Target = Source{value = 42}
        \\exit(0)
    , .ambiguous_conversion);
}

test "converter lookup follows type ownership across unimported sibling files and privacy edits" {
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
        \\if const selected = select(1) as Target
        \\    if selected.value == assigned.value
        \\        if check(Source{value = 42}) == make().value
        \\            if const branch = choice as Target -> exit(branch.value)
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
        \\fallible unresolved(static T: type, init value: Target) int -> 42
        \\if const answer = unresolved(Source{value = 42}) -> exit(answer)
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
        \\fallible stop() unit -> exit(42)
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
                const source = try std.fmt.allocPrint(testing.allocator, "{s}converter(value: Source) Target where {s} -> Target{{value = value.value}}\nfallible unresolved(static T: type, {s}value: {s}) int -> 42\nif const answer = unresolved({s}) -> exit(answer)\nexit(90)", .{ declarations, constraint, mode, case.parameter, case.expression });
                defer testing.allocator.free(source);
                try Fixture.expectAnySourceDiagnostic(source, .static_argument_cannot_be_inferred);
            }
        }
    }
    try Fixture.expectAnySourceDiagnostic(declarations ++
        \\converter(value: Source) Target where 0 == 1 -> Target{value = value.value}
        \\fallible construct(init value: Wrapper) Wrapper -> value
        \\if const answer = construct(loop -> break Wrapper{inner = Source{value = 42}}) -> exit(answer.inner.value)
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
        \\fallible unresolved(static T: type, init value: Wrapper) int -> 42
        \\if const answer = unresolved(loop -> break Wrapper{inner = Source{value = 300}}) -> exit(answer)
        \\exit(90)
    , .static_argument_cannot_be_inferred);
    try Fixture.expectAnySourceDiagnostic(declarations ++
        \\fallible construct(init value: Wrapper) Wrapper -> value
        \\if const answer = construct(loop -> break Wrapper{inner = Source{value = 300}}) -> exit(answer.inner.value)
        \\exit(90)
    , .where_condition_failed);
    try Fixture.expectSourceExit(declarations ++
        \\fallible construct(init value: Wrapper) Wrapper -> value
        \\if const answer = construct(loop -> break Wrapper{inner = Source{value = 42}}) -> exit(answer.inner.value)
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
        \\fallible skip(init value: Target) Target -> fail
        \\fallible construct(static T: type, init value: Target, marker: T) Target -> value
        \\func run() int
        \\    var counter = 0
        \\    if const unused = skip(make(counter)) -> return 90
        \\    if counter == 0
        \\        if const target = construct(make(counter), 0)
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
        \\    if const selected = variant as int -> return direct + inferred + selected + take(literal) + infer(literal) + from_call + from_field + take(literalValue()) + literalValue() - 336
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
        \\    if const selected = variant as Source -> return selected.value else return 90
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
        \\    if const selected = target as Target -> return selected.value else return 90
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
        \\    if const selected = converted as Target -> return selected.value
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
        \\    if yes? and not no? and not identity? -> return 42
        \\    return 7
    , 42);
}

test "optional arguments capture nested failures and repeated reads preserve the outcome" {
    try Fixture.expectParity(
        \\fallible number(mut count: int) int
        \\    count += 1
        \\    fail
        \\func inspect(value: int | none) int
        \\    if const first = value as int -> return first
        \\    if value is int -> return 9
        \\    return 41
        \\func run() int
        \\    var count = 0
        \\    return inspect(number?(count)) + count
    , 42);
}

test "optional arguments are eager and a captured failure does not skip later arguments" {
    try Fixture.expectParity(
        \\fallible mark(mut order: int, digit: int) int
        \\    order = order * 10 + digit
        \\    if digit == 1 -> fail
        \\    return digit
        \\func receive(first: int | none, second: int | none, snapshot: int) int
        \\    if first is int -> return 99
        \\    if const value = second as int -> return snapshot + value
        \\    return 98
        \\func run() int
        \\    var order = 0
        \\    return receive(mark?(order, 1), mark?(order, 2), order)
    , 14);
}

test "failure handlers include nested predicate operands and queried calls" {
    try Fixture.expectParity(
        \\fallible number() int -> fail
        \\fallible flag() bool -> fail
        \\func run() int
        \\    if number?() < 3 -> return 1
        \\    if flag?()? -> return 2
        \\    const result = bool(number?() < 3)
        \\    if not result? -> return 42
        \\    return 3
    , 42);
}

test "optional argument types survives callable values and forwarding" {
    try Fixture.expectParity(
        \\fallible missing() int -> fail
        \\func value_or(value: int | none, fallback: int) int
        \\    if const found = value as int -> return found
        \\    return fallback
        \\func forward(value: int | none) int -> value_or(value, 42)
        \\func apply(handler: func(int | none) int, value: int | none) int -> handler(value)
        \\func run() int -> apply(forward, missing?())
    , 42);
}

test "optional arguments use ordinary mutable variant places and optional references" {
    try Fixture.expectParity(
        \\func change(mut value: int | none)
        \\    if const found = value as int -> value = found + 1
        \\func forward(mut value: int | none) -> change(value)
        \\func update(reference: Ref(int) | none)
        \\    if const found = reference as Ref(int) -> found.value += 1
        \\fallible missing() Ref(int) -> fail
        \\func run() int
        \\    var value: int | none = 40
        \\    forward(value)
        \\    var array = [0]
        \\    update(Ref.from(array.get?(0)))
        \\    update(missing?())
        \\    if const found = value as int
        \\        if const last = array[0] -> return found + last
        \\    return 0
    , 42);
}

test "optional arguments forward owned payloads and clean up after later argument failure" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        if self.value <> 42 -> exit(91)
        \\fallible missing() int -> fail
        \\func consume(var item: Item | none, value: int)
        \\    if item is Item -> ()
        \\fallible work()
        \\    consume(Item{value = 42}, missing?())
        \\func run() int
        \\    if work?() -> return 7
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
        \\fallible missing() int -> fail
        \\func consume(var item: Item, final: int) -> ()
        \\fallible work(imm trace: Ref(int))
        \\    const original = Item{value = 21, trace = trace}
        \\    consume(original, missing?())
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle = trace.get(0)
        \\        if work(Ref.from(handle)) -> return 91
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
        \\fallible make(imm trace: Ref(int), value: int, enabled: bool) Item
        \\    if not enabled? -> fail
        \\    return Item{value = value, trace = trace}
        \\fallible missing() int -> fail
        \\func consume(var first: Item | none, var second: Item | none, var third: Item | none, final: int) -> ()
        \\fallible work(imm trace: Ref(int))
        \\    consume(make?(trace, 10, false), make?(trace, 11, false), make?(trace, 42, true), missing?())
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle = trace.get(0)
        \\        if work(Ref.from(handle)) -> return 91
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
        \\fallible make(imm trace: Ref(int), value: int, enabled: bool) Item
        \\    if not enabled? -> fail
        \\    return Item{value = value, trace = trace}
        \\fallible finish(enabled: bool) int
        \\    if not enabled? -> fail
        \\    return 0
        \\func consume(var first: Item | none, var second: Item | none, var third: Item | none, final: int) -> ()
        \\fallible work(imm trace: Ref(int), mask: int)
        \\    consume(make?(trace, 1, mask % 2 == 1), make?(trace, 2, mask / 2 % 2 == 1), make?(trace, 4, mask / 4 % 2 == 1), finish?(mask / 8 == 1))
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle = trace.get(0)
        \\        var mask = 0
        \\        loop
        \\            if mask == 16 -> break
        \\            if work(Ref.from(handle), mask) -> ()
        \\            mask += 1
        \\        return handle
        \\    return 92
    , 56);
}

test "optional arguments preserve variant values in deferred initializer captures" {
    try Fixture.expectParity(
        \\fallible missing() int -> fail
        \\fallible construct(init value: int | none) int | none -> value
        \\func receive(value: int | none) int
        \\    if const found = construct?(value) as int -> return found
        \\    return 42
        \\func run() int -> receive(missing?())
    , 42);
}

test "optional arguments include nested construction and extraction failures" {
    try Fixture.expectParity(
        \\struct Pair
        \\    copy = trivial
        \\    first: int
        \\    second: int
        \\fallible missing() int -> fail
        \\func receive(pair: Pair | none) int
        \\    if const found = pair as Pair -> return found.first
        \\    return 40
        \\func value_or(value: int | none, fallback: int) int
        \\    if const found = value as int -> return found
        \\    return fallback
        \\func run() int
        \\    const variant: int | none = none
        \\    return receive(Pair{first = 1, second = missing?()}) + value_or(variant as int, 2)
    , 42);
}

test "optional arguments capture complete loop expressions in converters" {
    try Fixture.expectParity(
        \\func run() int
        \\    const result = bool(loop -> break 2 < 1)
        \\    if not result? -> return 42
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
        \\fallible make() Pinned -> Pinned{value = 42}
        \\func receive(var value: Pinned | none) int
        \\    if ref found = value as Pinned -> return found.value
        \\    return 7
        \\func run() int -> receive(make?())
    , 42);
}

test "optional converter inputs handle whole expressions through ordinary variants" {
    try Fixture.expectParity(
        \\struct Number
        \\    copy = trivial
        \\    value: int
        \\converter(value: int | none) Number
        \\    if const found = value as int -> return Number{value = found}
        \\    return Number{value = 42}
        \\fallible missing() int -> fail
        \\func run() int -> Number(missing?() + 1).value
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
        \\    if ref found = item as Item -> return found.value
        \\    return 7
        \\func run() int
        \\    const existing: Item | none = Item{value = 21}
        \\    return inspect(existing) + inspect(Item{value = 21})
    , 42);
}

test "optional arguments capture failure-only extraction without a fake payload" {
    try Fixture.expectParity(
        \\func receive(value: int | none) int
        \\    if const found = value as int -> return found
        \\    return 42
        \\func run() int
        \\    const value: int | none = 1
        \\    return receive(value as bool)
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
        \\    if ref found = item as Item -> return found.value
        \\    return 0
        \\fallible absent() Item -> fail
        \\func run() int -> inspect(Item{value = 42}) + inspect(absent?())
    , 42);
}

test "optional arguments and predicates preserve declared function failure permission" {
    try Fixture.expectAnySourceDiagnostic(
        \\func bad(value: int | none) int -> value as int
        \\exit(bad(42))
    , .fallible_expression_outside_fallible_function);
    try Fixture.expectAnySourceDiagnostic(
        \\func bad() unit -> 2 < 1
        \\bad()
    , .fallible_expression_outside_fallible_function);
    try Fixture.expectParity(
        \\fallible propagate(value: int | none) int -> value as int
        \\fallible absent() int -> fail
        \\func run() int
        \\    if const found = propagate?(absent?()) -> return found
        \\    return 42
    , 42);
}

test "optional callable inputs preserve the callable failure permission" {
    try Fixture.expectParity(
        \\fallible identity(value: int) int -> value
        \\func apply(handler: fallible(int) int) int
        \\    if const value = handler?(42) -> return value
        \\    return 0
        \\func accepted(handler: (fallible(int) int) | none) int
        \\    if const callable = handler as fallible(int) int
        \\        if const value = callable?(42) -> return value
        \\    return 0
        \\func relay(handler: func((fallible(int) int) | none) int) int -> handler(identity)
        \\func ordinary(handler: func(fallible(int) int) int) int -> handler(identity)
        \\func run() int -> relay(accepted) + ordinary(apply) - 42
    , 42);
}

test "optional arguments consume deferred initializers within the receiving failure handler" {
    try Fixture.expectParity(
        \\fallible absent(mut count: int) unit
        \\    count += 1
        \\    fail
        \\func outcome(init value: unit) bool -> bool(value)
        \\func queried(init value: bool) int
        \\    if value? -> return 2
        \\    return 1
        \\func run() int
        \\    var count = 0
        \\    const flag = outcome(absent?(count))
        \\    if flag? -> return 99
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
        \\    if const owned = item as Item -> return owned.value
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
        \\fallible make() String
        \\    var value = String.empty()
        \\    value.append?("42")
        \\    return value^
        \\func selected(text: String | none) StringView
        \\    if ref found = text as String -> return found.view()
        \\    return ""
        \\func run() int
        \\    const view = selected(make?())
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
        \\    if const found = token^ as Token -> return dispose(found)
        \\    return 0
        \\fallible absent() Token -> fail
        \\func run() int -> accepted(Token{value = 42}) + accepted(absent?())
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
        \\    if const found = value as int -> return found
        \\    return 42
        \\func forward(value: int | none) int -> materialize(value)
        \\fallible missing() int -> fail
        \\func run() int -> forward(missing?())
    , 42);
}

test "expected optional variants capture bindings assignments fields and returns" {
    try Fixture.expectParity(
        \\struct Holder
        \\    copy = fieldwise
        \\    number: int | none
        \\    predicate: unit | none
        \\    flag: bool
        \\fallible missing() int -> fail
        \\func optional() int | none -> missing?() + 1
        \\func run() int
        \\    const saved: int | none = missing?()
        \\    var assigned: int | none = 42
        \\    assigned = missing?() + 1
        \\    const holder = Holder{number = missing?(), predicate = 2 < 1, flag = 1 < 2}
        \\    const numbers: Array(int | none, 2) = [missing?(), 42]
        \\    if saved is none and assigned is none and holder.number is none and holder.predicate is none
        \\        if holder.flag? and optional() is none
        \\            if numbers[0] is none
        \\                if const found = numbers[1] as int -> return found
        \\    return 0
    , 42);
}

test "optional variants capture compound expressions exactly once without rollback" {
    try Fixture.expectParity(
        \\fallible step(mut count: int, succeeds: bool) int
        \\    count += 1
        \\    if not succeeds? -> fail
        \\    return count
        \\func inspect(value: int | none, count: int) int
        \\    if value is none and value is none -> return count
        \\    return 90
        \\func run() int
        \\    var count = 0
        \\    const seen = inspect(step?(count, true) + step?(count, false) + step?(count, true), count)
        \\    return seen + count + 38
    , 42);
}

test "variants without none propagate failure and skip later arguments" {
    try Fixture.expectParity(
        \\fallible step(mut count: int, succeeds: bool) int
        \\    count += 1
        \\    if not succeeds? -> fail
        \\    return count
        \\func receive(value: int | bool, later: int) unit -> exit(91)
        \\fallible work(mut count: int)
        \\    receive(step?(count, false), step?(count, true))
        \\func run() int
        \\    var count = 0
        \\    if work(count) -> return 92
        \\    return count + 41
    , 42);
}

test "captured none and successful none are ordinary identical variant values" {
    try Fixture.expectParity(
        \\fallible missing() int | none -> fail
        \\func inspect(value: int | none) int
        \\    if const found = value as int -> return found
        \\    if value -> return 14
        \\    return 90
        \\func run() int
        \\    const yes = bool(unit)
        \\    const no = bool(none)
        \\    if yes? and not no? -> return inspect(none) + inspect(missing?()) + inspect(14)
        \\    return 91
    , 42);
}

test "optional variant failure destroys partially constructed successful prefixes" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 42
        \\struct Pair
        \\    copy = none
        \\    first: Item
        \\    second: int
        \\fallible missing() int -> fail
        \\func receive(value: Pair | none) unit
        \\    if not (value is none) -> exit(91)
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle = trace.get(0)
        \\        receive(Pair{first = Item{trace = Ref.from(handle)}, second = missing?()})
        \\        return handle
        \\    return 92
    , 42);
}

test "optional receiver types catch failure while resolving methods on successful types" {
    try Fixture.expectParity(
        \\struct Number
        \\    copy = trivial
        \\    value: int
        \\    pub func fallback(self: Number | none) int
        \\        if const found = self as Number -> return found.value
        \\        return 42
        \\fallible absent() Number -> fail
        \\func run() int -> absent?().fallback()
    , 42);
}

test "optional converter inputs preserve ordinary target construction" {
    try Fixture.expectParity(
        \\struct Number
        \\    copy = trivial
        \\    value: int
        \\converter(value: int | none) Number
        \\    if const found = value as int -> return Number{value = found}
        \\    return Number{value = 21}
        \\struct Holder
        \\    number: Number
        \\    flag: bool
        \\fallible missing() int -> fail
        \\func run() int
        \\    const holder = Holder{number = missing?(), flag = 1 < 2}
        \\    const saved: Number = missing?()
        \\    if holder.flag? -> return holder.number.value + saved.value
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
        \\    if const found = value as int -> return Pinned{value = found}
        \\    return Pinned{value = 21}
        \\func receive(var value: Pinned | none) int
        \\    if ref found = value as Pinned -> return found.value
        \\    return 0
        \\fallible missing() int -> fail
        \\func run() int -> receive(21) + receive(missing?())
    , 42);
}

test "specialized optional parameter types capture inferred integer inputs" {
    try Fixture.expectParity(
        \\func value_or(static T: type, value: T | none, fallback: T) T
        \\    if const found = value as T -> return found
        \\    return fallback
        \\fallible missing() int -> fail
        \\func run() int -> value_or(missing?(), 40) + value_or(2, 0)
    , 42);
}

test "optional converters accept expressions with no successful payload" {
    try Fixture.expectParity(
        \\fallible missing() never -> fail
        \\func run() int
        \\    const value: int | none = 1
        \\    const first = bool(value as bool)
        \\    const second = bool(missing?())
        \\    if not first? and not second? -> return 42
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

test "converter selection captures failure only inputs independently of placement" {
    try Fixture.expectParity(
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\struct Holder
        \\    item: Pinned
        \\converter(value: int | none) Pinned
        \\    if const found = value as int -> return Pinned{value = found}
        \\    return Pinned{value = 21}
        \\fallible absent() never -> fail
        \\func borrowed(imm value: Pinned) int -> value.value
        \\func owned(var value: Pinned) int -> value.value
        \\func optional_borrowed(imm value: Pinned | none) int
        \\    if value is none -> return 90
        \\    return 21
        \\func optional_owned(var value: Pinned | none) int
        \\    if value is none -> return 91
        \\    return 21
        \\func make() Pinned -> absent?()
        \\func run() int
        \\    const saved: Pinned = absent?()
        \\    const holder = Holder{item = absent?()}
        \\    const returned = make()
        \\    if saved.value == 21 and holder.item.value == 21 and returned.value == 21
        \\        if borrowed(absent?()) == 21 and owned(absent?()) == 21
        \\            if optional_borrowed(absent?()) == 21 and optional_owned(absent?()) == 21 -> return 42
        \\    return 92
    , 42);
}

test "optional boolean variants preserve explicit none before considering converters" {
    try Fixture.expectParity(
        \\func score(value: bool | none) int
        \\    if const found = value as bool
        \\        if found? -> return 10
        \\        return 0
        \\    return 12
        \\func run() int
        \\    const saved: bool | none = none
        \\    var assigned: bool | none = true
        \\    assigned = none
        \\    const converted = bool(none)
        \\    if converted? -> return 91
        \\    return score(saved) + score(assigned) + score(none) + 6
    , 42);
}

test "conditional literal conversions preserve permanent views and nested defaults" {
    try Fixture.expectParity(
        \\func choose(flag: bool) StringView -> if flag? -> "yes" else "no"
        \\func run() int
        \\    const first = choose(true)
        \\    const second = choose(false)
        \\    if first == "yes" and second == "no" -> return 42
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\fallible append(mut count: int) int
        \\    var text = ""
        \\    count += 1
        \\    text.append?(if count == 1 -> "a" else if count == 2 -> "bb" else "ccc")
        \\    return text.byte_length() + count + 40
        \\func run() int
        \\    var count = 0
        \\    if const result = append(count) -> return result
        \\    return 90
    , 42);
}
