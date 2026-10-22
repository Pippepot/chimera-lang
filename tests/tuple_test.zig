const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

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
        \\    if const first = values[0] -> return first + y
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
        \\    if const [a, b] = List(int).from([19, 23]) -> return a + b
        \\    return 90
    , 42);
}

test "fallible result patterns bind only on success" {
    try Fixture.expectParity(
        \\fallible point(value: int) (int, int)
        \\    value > 0
        \\    return (19, 23)
        \\func run() int
        \\    if const (a, b) = point(0) -> return 90
        \\    if const (a, b) = point(1) -> return a + b
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
        \\    if true?
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
        \\    if true?
        \\        const [a, _] = [Item{trace = Ref.from(trace), value = 19}, Item{trace = Ref.from(trace), value = 23}]
        \\    return trace
    , 42);
}

test "runtime and static comprehensions destructure nested item shapes" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [x + y for (x, y) in [(19, 1), (20, 2)]]
        \\    if const a = values[0]
        \\        if const b = values[1] -> return a + b
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
        \\    if true?
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
        \\    if const (ref a, b) = subject as (Item, int)
        \\        a.value += 1
        \\        if const (ref x, y) = subject as (Item, int) -> return x.value + y - 1
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func consume(deinit item: Item) int -> item.value
        \\func produce() (Item, int) | none -> (Item{value = 19}, 23)
        \\func run() int
        \\    if const (a, b) = produce() as (Item, int) -> return consume(a^) + b
        \\    return 90
    , 42);
}

test "annotated conditional patterns contextualize fallible tuple results" {
    try Fixture.expectParity(
        \\fallible point() (int, int) -> (19, 23)
        \\func run() int
        \\    if const (a, b): (int, int) = point() -> return a + b
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
