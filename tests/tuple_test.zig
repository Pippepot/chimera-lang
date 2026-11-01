const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "tuple depth subtyping preserves structural identity arity and reference members" {
    try Fixture.expectParity(
        \\static Narrow: type = (int, (bool,))
        \\static Wide: type = (int | none, (bool | int,))
        \\static Identical: type = (int, (bool,))
        \\func accept(static T: type) int where T is Wide and T == Identical -> 42
        \\func run() int -> accept(Narrow)
    , 42);
    for ([_]struct { actual: []const u8, expected: []const u8 }{
        .{ .actual = "(int, int, int)", .expected = "(int, int)" },
        .{ .actual = "(ref int,)", .expected = "(ref (int | none),)" },
        .{ .actual = "(ref int,)", .expected = "(int,)" },
        .{ .actual = "(int | bool, int | none)", .expected = "(int, int) | (bool, none)" },
    }) |types| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\static Actual: type = $actual
            \\func accept(static T: type) int where T is $expected -> 42
            \\exit(accept(Actual))
        , types);
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .where_condition_failed);
    }
}

test "tuple value subtyping constructs the destination representation" {
    try Fixture.expectParity(
        \\func pair() (int, int) -> (19, 23)
        \\func inspect(imm value: (int | none, int)) int
        \\    if value.0 is int -> return value.0 + value.1
        \\    return 90
        \\func run() int
        \\    const source = pair()
        \\    const widened: (int | none, int) = source
        \\    if inspect(widened) <> 42 -> return 91
        \\    return inspect(pair())
    , 42);
}

test "tuple element converters borrow existing members and run once in order" {
    try Fixture.expectParity(
        \\struct Source
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\struct Target
        \\    value: int
        \\converter(imm source: Source) Target
        \\    source.trace.value = source.trace.value * 10 + source.value
        \\    return Target{value = source.value}
        \\func run() int
        \\    var trace = 0
        \\    const source = (Source{trace = Ref.from(trace), value = 1}, (Source{trace = Ref.from(trace), value = 2},))
        \\    const converted: (Target, (Target,)) = source
        \\    return trace + converted.0.value + converted.1.0.value + source.0.value + 26
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Source
        \\struct Middle
        \\struct Target
        \\converter(imm source: Source) Middle -> Middle{}
        \\converter(imm source: Middle) Target -> Target{}
        \\const source = (Source{},)
        \\const target: (Target,) = source
    , .struct_initializer_field_type_mismatch);
}

test "tuple subtyping composes with unions and preserves active alternatives" {
    try Fixture.expectParity(
        \\func choose(imm flag: bool) (int, int) | (bool, int)
        \\    if flag
        \\        const value: (int, int) = (19, 23)
        \\        return value
        \\    const value: (bool, int) = (false, 42)
        \\    return value
        \\func run() int
        \\    const first: (int | bool, int) = choose(true)
        \\    const second: (int | bool, int) = choose(false)
        \\    const wrapped: (int | bool, int) | none = choose(true)
        \\    if not (first.0 is int and second.0 is bool) -> return 90
        \\    if wrapped is (int | bool, int)
        \\        if wrapped.0 is int -> return wrapped.0 + wrapped.1
        \\    return 91
    , 42);
}

test "tuple runtime membership and matches retain the source representation" {
    try Fixture.expectParity(
        \\func run() int
        \\    var value = (19, 23)
        \\    if not (value is (int | none, int)) -> return 90
        \\    match value
        \\        (int | none, int) -> return value.0 + value.1
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\const source = (19, 23)
        \\const target: (int | none, int) | (int | bool, int) = source
    , .ambiguous_variant_member);
}

test "tuple adaptation preserves reference authority and rejects pointee widening" {
    try Fixture.expectParity(
        \\func choose(ref number: int, ref flag: bool, first: bool) ref int | ref bool
        \\    if first -> return number
        \\    return flag
        \\func run() int
        \\    var number = 19
        \\    var flag = false
        \\    const source: (ref int | ref bool, int) = (choose(number, flag, true), 23)
        \\    const widened: (ref int | ref bool | none, int | none) = source
        \\    match widened.0
        \\        int ->
        \\            ref selected = widened.0
        \\            selected += 23
        \\        _ -> return 90
        \\    return number
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func accept(ref value: (int | none, int)) -> ()
        \\var value = (19, 23)
        \\accept(value)
    , .call_argument_type_mismatch);
    try Fixture.expectSourceDiagnostic(
        \\func escaped() (ref int, int | none)
        \\    var owner = 19
        \\    const value: (ref int, int) = (owner, 23)
        \\    return value
        \\_ = escaped()
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\func view(imm value: (int | none, int)) ref (int | none, int) -> value
        \\func escaped(ref source: (int, int)) ref (int | none, int) -> view(source)
        \\var source = (19, 23)
        \\ref result = escaped(source)
        \\_ = result.1
    , .borrow_outlives_source);
}

test "tuple construction runs custom copies and drops exactly once" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    copy = func(imm self: Item) Item
        \\        self.trace.value += 1
        \\        return Item{trace = self.trace}
        \\    drop = func(deinit self: Item) -> self.trace.value += 100
        \\func run() int
        \\    var trace = 0
        \\    if true
        \\        const source = (Item{trace = Ref.from(trace)}, 23)
        \\        const widened: (Item, int | none) = source
        \\        if trace <> 1 -> return 90
        \\        if source.1 <> 23 -> return 91
        \\        if not (widened.1 is int) -> return 92
        \\    return trace - 159
    , 42);
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    copy = func(imm self: Item) Item -> Item{trace = self.trace}
        \\    drop = func(deinit self: Item) -> self.trace.value += 21
        \\func missing() int | none -> none
        \\func consume(var value: (Item, int | none), final: int) -> ()
        \\func work(trace: Ref(int)) unit | none
        \\    const source = (Item{trace = trace}, 23)
        \\    consume(source, ((match missing()
        \\        int -> 0
        \\        _ -> return none)))
        \\    return ()
        \\func run() int
        \\    var trace = 0
        \\    if work(Ref.from(trace)) is unit -> return 90
        \\    return trace
    , 42);
}

test "tuple construction transfers noncopyable members" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func run() int
        \\    const source = (Item{value = 19}, 23)
        \\    const widened: (Item, int | none) = source^
        \\    if widened.1 is int -> return widened.0.value + widened.1
        \\    return 90
    , 42);
}

test "tuple construction accepts fresh but not stored immovable members" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func run() int
        \\    const widened: (Item, int | none) = (Item{value = 19}, 23)
        \\    if widened.1 is int -> return widened.0.value + widened.1
        \\    return 90
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\const source = (Item{}, 23)
        \\const widened: (Item, int | none) = source
    , .type_not_copyable);
}

test "tuple adaptation uses custom moves through owning calls and returns" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    move = func(deinit self: Item) Item
        \\        self.trace.value += 1
        \\        return Item{trace = self.trace, value = self.value}
        \\func narrow(ref trace: int) (Item, int) -> (Item{trace = Ref.from(trace), value = 19}, 23)
        \\func wide(ref trace: int) (Item, int | none) -> narrow(trace)
        \\func take(var value: (Item, int | none)) int
        \\    if value.1 is int -> return value.0.value + value.1
        \\    return 90
        \\func run() int
        \\    var trace = 0
        \\    const source = narrow(trace)
        \\    const result = take(source^)
        \\    if trace <> 2 -> return 91
        \\    return take(wide(trace)) + result - 42
    , 42);
}

test "tuple subtyping initializes custom-move union alternatives" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\    move = func(deinit self: Item) Item -> Item{value = self.value}
        \\func choose(first: bool) (Item, int) | (Item, bool)
        \\    if first
        \\        const value: (Item, int) = (Item{value = 19}, 23)
        \\        return value^
        \\    const value: (Item, bool) = (Item{value = 19}, false)
        \\    return value^
        \\func run() int
        \\    const first: (Item, int | bool) = choose(true)
        \\    const second: (Item, int | bool) | none = choose(false)
        \\    if first.1 is int and second is (Item, int | bool)
        \\        if second.1 is bool -> return first.0.value + first.1
        \\    return 90
    , 42);
}

test "tuple subtyping materializes annotated static values" {
    try Fixture.expectParity(
        \\static source: (int, int) = (19, 23)
        \\static widened: (int | none, int) = source
        \\func run() int
        \\    const value = widened
        \\    if value.0 is int -> return value.0 + value.1
        \\    return 90
    , 42);
}

test "tuple element conversion preserves marked errors unless explicitly converted" {
    const source =
        \\struct Failure
        \\    error = true
        \\struct Target
        \\    value: int
        \\converter(imm failure: Failure) Target -> Target{value = 19}
    ;
    try Fixture.expectSourceDiagnostic(source ++ "\n" ++
        \\const source = (Failure{}, 23)
        \\const converted: (Target, int) = source
    , .struct_initializer_field_type_mismatch);
    try Fixture.expectParity(source ++ "\n" ++
        \\static Pair: type = (Target, int)
        \\func run() int
        \\    const source = (Failure{}, 23)
        \\    const converted = Pair(source)
        \\    return converted.0.value + converted.1
    , 42);
}

test "tuple converter dependencies invalidate and recover incrementally" {
    const declarations =
        \\pub struct Source
        \\    pub value: int
        \\pub struct Target
        \\    pub value: int
    ;
    const converter = "\npub converter(imm value: Source) Target -> Target{value = value.value}\n";
    const fixture = try Fixture.initFiles(
        \\import model.{Source, Target}
        \\const source = (Source{value = 19}, 23)
        \\const converted: (Target, int) = source
        \\exit(converted.0.value + converted.1)
    , &.{.{ .path = "model/model.chi", .module_path = "model", .source = declarations ++ converter }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, declarations ++ "\npub converter(imm value: Source) Target -> Target{value = value.value + 1}\n");
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, declarations);
    try fixture.expectDiagnostic(0, .struct_initializer_field_type_mismatch);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, declarations ++ converter);
    try fixture.expectExit(0, 42);
}

test "structural tuples infer nested and singleton values and type factories" {
    try Fixture.expectParity(
        \\func Pair(static A: type, static B: type) type -> (A, B)
        \\func run() int
        \\    const grouped = (12)
        \\    const singleton = (grouped,)
        \\    const nested = (singleton, (30, true))
        \\    const typed: Pair(int, int) = (nested.0.0, nested.1.0)
        \\    const one: (int,) = (typed.0,)
        \\    return one.0 + typed.1
    , 42);
}

test "tuple and array patterns nest and evaluate their source once" {
    try Fixture.expectParity(
        \\func point(mut calls: int) ((int,), Array(int, 2))
        \\    calls += 1
        \\    return ((12,), [10, 20])
        \\func run() int
        \\    var calls = 0
        \\    const ((x,), [y, z]) = point(calls)
        \\    return x + y + z + calls - 1
    , 42);
}

test "patterns copy existing owners and preserve independent reference authority" {
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 19
        \\    const pair: (ref int, int) = (owner, 23)
        \\    const (ref x, var y) = pair
        \\    x += 1
        \\    y -= 1
        \\    return owner + y
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var values = [19, 23]
        \\    const [ref x, var y] = values
        \\    x += 1
        \\    y -= 1
        \\    match values.get(0)
        \\        first and first is int -> return first + y
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "fresh tuples and arrays hand noncopyable members to bindings" {
    const item =
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func consume(deinit item: Item) int -> item.value
    ;
    try Fixture.expectParity(item ++ "\n" ++
        \\func run() int
        \\    const (x, y) = (Item{value = 19}, Item{value = 23})
        \\    return consume(x^) + consume(y^)
    , 42);
    try Fixture.expectParity(item ++ "\n" ++
        \\func run() int
        \\    const [x, y] = [Item{value = 19}, Item{value = 23}]
        \\    return consume(x^) + consume(y^)
    , 42);
}

test "loop patterns preserve borrowed delivery and allow explicit copies and aliases" {
    try Fixture.expectParity(
        \\func run() int
        \\    var pairs = [(19, 1), (20, 2)]
        \\    var total = 0
        \\    for (ref x, const y) in pairs
        \\        x += y
        \\        total += x
        \\    return total
    , 42);
}

test "sequence patterns reject statically wrong lengths and wrong shapes" {
    try Fixture.expectSourceDiagnostic(
        \\const [x, y] = [1]
    , .destructure_length_mismatch);
    try Fixture.expectSourceDiagnostic(
        \\const (x, y) = (1, 2, 3)
    , .destructure_length_mismatch);
    try Fixture.expectSourceDiagnostic(
        \\const [x, y] = (1, 2)
    , .destructure_requires_sequence);
    try Fixture.expectSourceDiagnostic(
        \\const (x, y) = [1, 2]
    , .destructure_requires_tuple);
    try Fixture.expectSourceDiagnostic(
        \\const (x, x) = (1, 2)
    , .duplicate_local_binding);
}

test "List and Span patterns check exact lengths through ordinary failure flow" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values: List(int) = [19, 23]
        \\    if const [a] = values -> return 90
        \\    if const [a, b, c] = values -> return 91
        \\    if const [ref a, b] = values
        \\        a += 1
        \\        var view = values.span()
        \\        if const [x, y] = view -> return x + y - 1
        \\    return 92
    , 42);
}

test "fresh and explicitly transferred Lists destructure noncopyable elements" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func consume(deinit item: Item) int -> item.value
        \\func run() int
        \\    var values: List(Item) = [Item{value = 19}, Item{value = 23}]
        \\    if const [a, b] = values^ -> return consume(a^) + consume(b^)
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    if const [a, b] = ((match List(int).from([19, 23])
        \\        _selected_result_0 and _selected_result_0 is List(int) -> _selected_result_0^
        \\        _ -> panic "unexpected none")) -> return a + b
        \\    return 90
    , 42);
}

test "optional tuple result patterns select only the matching payload" {
    try Fixture.expectParity(
        \\func point(value: int) (int, int) | none
        \\    if not (value > 0) -> return none
        \\    return (19, 23)
        \\func run() int
        \\    const absent = point(0)
        \\    if absent is (int, int) -> return 90
        \\    const present = point(1)
        \\    if present is (int, int)
        \\        const (a, b): (int, int) = present
        \\        return a + b
        \\    return 91
    , 42);
}

test "patterns drop ignored and extracted owners exactly once" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\func run() int
        \\    var trace = 0
        \\    if true
        \\        const (a, _) = (Item{trace = Ref.from(trace), value = 19}, Item{trace = Ref.from(trace), value = 23})
        \\    return trace
    , 42);
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\func run() int
        \\    var trace = 0
        \\    if true
        \\        const [a, _] = [Item{trace = Ref.from(trace), value = 19}, Item{trace = Ref.from(trace), value = 23}]
        \\    return trace
    , 42);
}

test "runtime and static comprehensions destructure nested item shapes" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [x + y for (x, y) in [(19, 1), (20, 2)]]
        \\    match values.get(0)
        \\        a and a is int ->
        \\            match values.get(1)
        \\                b and b is int -> return a + b
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [x + y static for (x, [y]) in [(19, [1]), (20, [2])]]
        \\    const [a, b] = values
        \\    return a + b
    , 42);
}

test "patterns borrow fresh immovable tuple and array members in place" {
    for ([_][]const u8{ "const (ref a, ref b) = (Item{value = 19}, Item{value = 23})", "const [ref a, ref b] = [Item{value = 19}, Item{value = 23}]" }) |binding| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Item
            \\    copy = none
            \\    move = none
            \\    value: int
            \\func run() int
            \\    $binding
            \\    return a.value + b.value
        , .{ .binding = binding });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "destructuring preserves borrowing limits and explicit drop obligations" {
    try Fixture.expectSourceDiagnostic(
        \\const values = [19, 23]
        \\const [ref a, ref b] = values
        \\a += 1
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    copy = none
        \\const values = (Item{}, Item{})
        \\const (a, b) = values
    , .type_not_copyable);
    try Fixture.expectSourceDiagnostic(
        \\func escaped() ref int
        \\    const (ref a,) = (42,)
        \\    return a
        \\_ = escaped()
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    drop = explicit
        \\const (_, _) = (Item{}, Item{})
    , .value_requires_explicit_drop);
}

test "empty patterns retain unit and zero element array identity" {
    try Fixture.expectParity(
        \\func run() int
        \\    const () = ()
        \\    const []: Array(int, 0) = []
        \\    const (answer) = 42
        \\    return answer
    , 42);
}

test "owned List patterns use counts independently of End and immovable elements" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values: List(End) = [End{}, End{}]
        \\    if const [a, b] = values^ -> return 42
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func run() int
        \\    var values: List(Item) = [Item{value = 19}, Item{value = 23}]
        \\    if const [ref a, ref b] = values^ -> return a.value + b.value
        \\    return 90
    , 42);
}

test "nested pattern failure cleans all owners and preserves borrowed sources" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\func produce(trace: Ref(int)) (Item, List(Item))
        \\    return (Item{trace = trace, value = 10}, [Item{trace = trace, value = 12}, Item{trace = trace, value = 20}])
        \\func run() int
        \\    var trace = 0
        \\    if const (first, [second]) = produce(Ref.from(trace)) -> return 90
        \\    return trace
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var values: List(int) = [19, 23]
        \\    if const [a] = values -> return 90
        \\    if const [a, b] = values -> return a + b
        \\    return 91
    , 42);
}

test "tuple type factories retain reference and singleton member kinds" {
    try Fixture.expectParity(
        \\func Pair(static T: type) type -> (ref T, T)
        \\func Single(static T: type) type -> (T,)
        \\func run() int
        \\    var owner = 19
        \\    const pair: Pair(int) = (owner, 23)
        \\    const (ref first, second) = pair
        \\    first += 1
        \\    const result: Single(int) = (first + second - 1,)
        \\    const (answer,) = result
        \\    return answer
    , 42);
}

test "loop pattern carriers keep immovable payloads in place and clean early exits" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\struct Cursor
        \\    trace: Ref(int)
        \\    func next(mut self: Cursor) (Item, Item) | End
        \\        return (Item{trace = self.trace, value = 19}, Item{trace = self.trace, value = 23})
        \\func run() int
        \\    var trace = 0
        \\    for (ref a, ref b) in Cursor{trace = Ref.from(trace)}
        \\        if a.value + b.value <> 42 -> return 90
        \\        break
        \\    return trace
    , 42);
}

test "counted List transfer keeps captured references and drops each moved element once" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\func run() int
        \\    var trace = 0
        \\    if true
        \\        const values: List(Item) = [Item{trace = Ref.from(trace), value = 19}, Item{trace = Ref.from(trace), value = 23}]
        \\        if const [first, _] = values^
        \\            ()
        \\        else
        \\            return 90
        \\    return trace
    , 42);
}

test "variant payload patterns preserve the subject ownership and reference authority" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func produce() (Item, int) | none -> (Item{value = 19}, 23)
        \\func run() int
        \\    var subject = produce()
        \\    if subject is (Item, int)
        \\        const (ref a, b): (Item, int) = subject
        \\        a.value += 1
        \\        const (ref x, y): (Item, int) = subject
        \\        return x.value + y - 1
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func consume(deinit item: Item) int -> item.value
        \\func produce() (Item, int) | none -> (Item{value = 19}, 23)
        \\func run() int
        \\    const subject = produce()
        \\    if subject is (Item, int)
        \\        const (a, b): (Item, int) = subject^
        \\        return consume(a^) + b
        \\    return 90
    , 42);
}

test "annotated patterns destructure an already narrowed optional tuple result" {
    try Fixture.expectParity(
        \\func point() (int, int) | none -> (19, 23)
        \\func run() int
        \\    const subject = point()
        \\    if subject is (int, int)
        \\        const (a, b): (int, int) = subject
        \\        return a + b
        \\    return 90
    , 42);
}

test "static pattern headers validate modes and names even for empty traversals" {
    try Fixture.expectSourceDiagnostic(
        \\const values: Array(int, 0) = [x static for var x in 0..0]
    , .static_iteration_binding_mode);
    try Fixture.expectSourceDiagnostic(
        \\const values: Array(int, 0) = [x static for (x, x) in 0..0]
    , .duplicate_local_binding);
}
