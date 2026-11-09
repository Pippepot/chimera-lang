const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "unsafe_at reads and writes in range elements of Array List and Span" {
    try Fixture.expectParity(
        \\func run() int
        \\    var array = [1, 2, 3, 4]
        \\    var list = List(int).filled(0, 4)
        \\    if not (list is List(int)) -> return 90
        \\    for index in 0..4
        \\        list.unsafe_at(index) = array.unsafe_at(3 - index) * 10
        \\    var view = list[1..4]
        \\    view.unsafe_at(0) += 1
        \\    array.unsafe_at(0) = view.unsafe_at(2)
        \\    if list[0] <> 40 or list[1] <> 31 or list[2] <> 20 or list[3] <> 10 -> return 91
        \\    if array[0] <> 10 or array[3] <> 4 -> return 92
        \\    return 42
    , 42);
}

test "collection search methods accept array literals and type-qualified calls" {
    try Fixture.expectParity(
        \\func is_at(imm result: int | none, expected: int) bool
        \\    if not (result is int) -> return false
        \\    return result == expected
        \\func shifted(imm element: int, imm needle: int) bool -> element + 1 == needle
        \\func run() int
        \\    if not is_at([1, 2, 3].index_of(2), 1) -> return 90
        \\    if not is_at([1, 2, 3].index_of(3, shifted), 1) -> return 91
        \\    const values = [19, 23, 23]
        \\    const needle = [23, 23]
        \\    const shifted_needle = [24, 24]
        \\    const empty: Array(int, 0) = []
        \\    if not is_at(values.index_of(23), 1) -> return 92
        \\    if not is_at(Array(int, 3).index_of(values, 23), 1) -> return 93
        \\    if not is_at(values.index_of(24, shifted), 1) -> return 94
        \\    if not is_at(Array(int, 3).index_of(values, 24, shifted), 1) -> return 95
        \\    if not is_at(values.index_of_sequence(needle.span()), 1) -> return 96
        \\    if not is_at([19, 23, 23].index_of_sequence(needle.span()), 1) -> return 97
        \\    if not is_at(Array(int, 3).index_of_sequence(values, needle.span()), 1) -> return 98
        \\    if not is_at(values.index_of_sequence(shifted_needle.span(), shifted), 1) -> return 99
        \\    if not is_at(Array(int, 3).index_of_sequence(values, shifted_needle.span(), shifted), 1) -> return 100
        \\    if values.index_of(42) is int or empty.index_of(23) is int -> return 101
        \\    if not is_at(empty.index_of_sequence(empty.span()), 0) -> return 102
        \\    return 42
    , 42);
}

test "collection search methods accept list and span receivers and type-qualified calls" {
    try Fixture.expectParity(
        \\func is_at(imm result: int | none, expected: int) bool
        \\    if not (result is int) -> return false
        \\    return result == expected
        \\func shifted(imm element: int, imm needle: int) bool -> element + 1 == needle
        \\func run() int
        \\    const values: List(int) = [19, 23, 23]
        \\    const view = values.span()
        \\    const needle = [23, 23]
        \\    const shifted_needle = [24, 24]
        \\    const empty = Span(int).empty()
        \\    const empty_list: List(int) = []
        \\    if not is_at(values.index_of(23), 1) -> return 90
        \\    if not is_at(List(int).index_of(values, 23), 1) -> return 91
        \\    if not is_at(values.index_of(24, shifted), 1) -> return 92
        \\    if not is_at(List(int).index_of(values, 24, shifted), 1) -> return 93
        \\    if not is_at(values.index_of_sequence(needle.span()), 1) -> return 94
        \\    if not is_at(List(int).index_of_sequence(values, needle.span()), 1) -> return 95
        \\    if not is_at(values.index_of_sequence(shifted_needle.span(), shifted), 1) -> return 96
        \\    if not is_at(List(int).index_of_sequence(values, shifted_needle.span(), shifted), 1) -> return 97
        \\    if not is_at(view.index_of(23), 1) -> return 98
        \\    if not is_at(Span(int).index_of(view, 23), 1) -> return 99
        \\    if not is_at(view.index_of(24, shifted), 1) -> return 100
        \\    if not is_at(Span(int).index_of(view, 24, shifted), 1) -> return 101
        \\    if not is_at(view.index_of_sequence(needle.span()), 1) -> return 102
        \\    if not is_at(Span(int).index_of_sequence(view, needle.span()), 1) -> return 103
        \\    if not is_at(view.index_of_sequence(shifted_needle.span(), shifted), 1) -> return 104
        \\    if not is_at(Span(int).index_of_sequence(view, shifted_needle.span(), shifted), 1) -> return 105
        \\    if values.index_of(42) is int or view.index_of(42) is int -> return 106
        \\    if empty.index_of(23) is int or empty_list.index_of(23) is int -> return 107
        \\    if not is_at(empty.index_of_sequence(empty), 0) -> return 108
        \\    if not is_at(empty_list.index_of_sequence(empty), 0) -> return 109
        \\    return 42
    , 42);
}

test "borrowed span search finds first elements and subsequences in both engines" {
    try Fixture.expectParity(
        \\import std.search.{index_of, index_of_sequence, starts_with, ends_with}
        \\func run() int
        \\    const values = [19, 23, 23]
        \\    const needle = [23, 23]
        \\    const empty: Array(int, 0) = []
        \\    const element = index_of(values.span(), 23)
        \\    if not (element is int) -> return 90
        \\    if element <> 1 -> return 91
        \\    const sequence = index_of_sequence(values.span(), needle.span())
        \\    if not (sequence is int) -> return 92
        \\    if sequence <> 1 -> return 93
        \\    if index_of(values.span(), 42) is int -> return 94
        \\    if index_of(empty.span(), 23) is int -> return 95
        \\    if index_of_sequence(empty.span(), needle.span()) is int -> return 96
        \\    const empty_match = index_of_sequence(empty.span(), empty.span())
        \\    if not (empty_match is int) -> return 97
        \\    if empty_match <> 0 -> return 98
        \\    if not starts_with(values.span(), values.span()) -> return 99
        \\    if not ends_with(values.span(), needle.span()) -> return 100
        \\    if starts_with(values.span(), needle.span()) -> return 101
        \\    if not starts_with(empty.span(), empty.span()) -> return 102
        \\    if not ends_with(empty.span(), empty.span()) -> return 103
        \\    return 42
    , 42);
}

test "collection search methods accept heterogeneous custom matchers without equality" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\func shifted(imm item: Item, imm needle: int) bool -> item.value + 19 == needle
        \\func run() int
        \\    const values = [Item{value = 19}, Item{value = 23}, Item{value = 23}]
        \\    const shifted_needle = [42, 42]
        \\    const direct = values.index_of(42, shifted)
        \\    if not (direct is int) -> return 90
        \\    if direct <> 1 -> return 91
        \\    const direct_sequence = values.index_of_sequence(shifted_needle.span(), shifted)
        \\    if not (direct_sequence is int) -> return 92
        \\    if direct_sequence <> 1 -> return 93
        \\    const view = values.span()
        \\    const span_result = view.index_of(42, shifted)
        \\    const span_sequence = view.index_of_sequence(shifted_needle.span(), shifted)
        \\    if not (span_result is int) or not (span_sequence is int) -> return 94
        \\    if span_result <> 1 or span_sequence <> 1 -> return 95
        \\    const list: List(Item) = [Item{value = 19}, Item{value = 23}, Item{value = 23}]
        \\    const list_result = list.index_of(42, shifted)
        \\    const list_sequence = list.index_of_sequence(shifted_needle.span(), shifted)
        \\    if not (list_result is int) or not (list_sequence is int) -> return 96
        \\    if list_result <> 1 or list_sequence <> 1 -> return 97
        \\    return values[0].value + values[1].value
    , 42);
}

test "collection search methods preserve immovable owners and permit later list growth" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    pub value: int
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Item) -> self.drops.value += 1
        \\    pub func ==(imm item: Item, imm needle: int) bool -> item.value == needle
        \\func locate(ref drops: int) int
        \\    const values = [Item{value = 19, drops = Ref.from(drops)}, Item{value = 23, drops = Ref.from(drops)}]
        \\    const needle = [19, 23]
        \\    const element = values.index_of(23)
        \\    if not (element is int) -> return 90
        \\    const sequence = values.index_of_sequence(needle.span())
        \\    if not (sequence is int) -> return 91
        \\    if element <> 1 or sequence <> 0 or drops <> 0 -> return 92
        \\    const view = values.span()
        \\    const span_element = view.index_of(23)
        \\    const span_sequence = view.index_of_sequence(needle.span())
        \\    if not (span_element is int) or not (span_sequence is int) -> return 100
        \\    if span_element <> 1 or span_sequence <> 0 or drops <> 0 -> return 101
        \\    return values[0].value + values[1].value
        \\func locate_list(ref drops: int) int
        \\    const values: List(Item) = [Item{value = 19, drops = Ref.from(drops)}, Item{value = 23, drops = Ref.from(drops)}]
        \\    const needle = [19, 23]
        \\    const element = values.index_of(23)
        \\    const sequence = values.index_of_sequence(needle.span())
        \\    if not (element is int) or not (sequence is int) -> return 102
        \\    if element <> 1 or sequence <> 0 or drops <> 0 -> return 103
        \\    return values[0].value + values[1].value
        \\func run() int
        \\    var drops = 0
        \\    if locate(drops) <> 42 or drops <> 2 -> return 93
        \\    var list_drops = 0
        \\    if locate_list(list_drops) <> 42 or list_drops <> 2 -> return 104
        \\    var list: List(int) = [19, 23]
        \\    const result = list.index_of(23)
        \\    if not (result is int) -> return 94
        \\    if not (list.append(7) is unit) -> return 95
        \\    list[0] = 8
        \\    if list.len() <> 3 or list[1] <> 23 -> return 96
        \\    const words = ["hello", "world"]
        \\    const word: StringView = "world"
        \\    const selected = words.index_of(word)
        \\    if not (selected is int) -> return 97
        \\    const phrase: Array(StringView, 1) = ["world"]
        \\    const selected_sequence = words.index_of_sequence(phrase.span())
        \\    if not (selected_sequence is int) -> return 98
        \\    if selected <> 1 or selected_sequence <> 1 or words[1] <> "world" -> return 99
        \\    return result + 41
    , 42);
}

test "borrowed span search skips callbacks for impossible matches and accepts directional matching" {
    try Fixture.expectParity(
        \\import std.search.{index_of, index_of_sequence}
        \\func forbidden(imm element: int, imm needle: int) bool -> panic "unexpected comparison"
        \\func before(imm element: int, imm needle: int) bool -> element < needle
        \\func run() int
        \\    const empty: Array(int, 0) = []
        \\    const values = [2, 4, 7]
        \\    const needle = [3, 5]
        \\    if index_of(empty.span(), 2, forbidden) is int -> return 90
        \\    if index_of_sequence(empty.span(), needle.span(), forbidden) is int -> return 91
        \\    const empty_match = index_of_sequence(values.span(), empty.span(), forbidden)
        \\    if not (empty_match is int) -> return 92
        \\    if empty_match <> 0 -> return 93
        \\    const element = index_of(values.span(), 5, before)
        \\    if not (element is int) -> return 94
        \\    const sequence = index_of_sequence(values.span(), needle.span(), before)
        \\    if not (sequence is int) -> return 95
        \\    if element <> 0 or sequence <> 0 -> return 96
        \\    return 42
    , 42);
}

test "borrowed span search visits candidates and pairs in order and stops at the first match" {
    const fixture = try Fixture.init(
        \\import std.search.{index_of_sequence}
        \\func traced(imm element: int, imm needle: int) bool
        \\    print(element * 10 + needle)
        \\    return element == needle
        \\const values = [1, 1, 2, 9]
        \\const needle = [1, 2]
        \\const result = index_of_sequence(values.span(), needle.span(), traced)
        \\if not (result is int) -> exit(90)
        \\exit(result + 41)
    );
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
    try std.testing.expectEqualStrings("11\n12\n11\n22\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "collection search methods recompute after custom matcher edits" {
    const entry =
        \\const values = [19, 23]
        \\const result = values.index_of(42, matches)
        \\if not (result is int) -> exit(90)
        \\const view = values.span()
        \\const span_result = Span(int).index_of(view, 42, matches)
        \\if not (span_result is int) -> exit(91)
        \\const list: List(int) = [19, 23]
        \\const list_result = List(int).index_of(list, 42, matches)
        \\if not (list_result is int) -> exit(92)
        \\if span_result <> result or list_result <> result -> exit(93)
        \\exit(result + 42)
    ;
    const original = "pub func matches(imm element: int, imm needle: int) bool -> element + 19 == needle";
    const fixture = try Fixture.initFiles(entry, &.{.{ .path = "matcher.chi", .module_path = "", .source = original }});
    defer fixture.deinit();
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, "pub func matches(imm element: int, imm needle: int) bool -> element + 23 == needle");
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, original);
    try fixture.expectExit(0, 43);
}

test "static comprehensions select shape while elements retain runtime evaluation" {
    try Fixture.expectParity(
        \\func element(mut calls: int, value: int) int
        \\    calls += 1
        \\    return value
        \\func calculate() int | none
        \\    var calls = 0
        \\    const offset = 19
        \\    const values = [element(calls, i + offset) static for i in 0..4 static if i % 2 == 0]
        \\    return values[0] + values[1] + calls
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "nested static comprehension bindings distinguish evaluation environments" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    const values = [i * 10 + j static for i in 1..3 static for j in 0..2]
        \\    return values[0] + values[3] + values.len() + 7
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "static empty and excluded comprehension bodies remain unanalyzed" {
    try Fixture.expectParity(
        \\func run() int
        \\    const runtime = 99
        \\    const a: Array(int, 0) = [unknown(i) static for i in 0..3 static if i < 0]
        \\    const b: Array(int, 0) = [missing static for i in 0..0]
        \\    const c: Array(int, 0) = [x static for x in Array(int, 0)([runtime static if 1 < 0])]
        \\    return a.len() + b.len() + c.len() + 42
    , 42);
}

test "static comprehensions traverse canonical arrays" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    const values = [x static for x in [19, 23]]
        \\    return values[0] + values[1]
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "Array spreading retains structural size and source order" {
    try Fixture.expectParity(
        \\func source(mut calls: int) Array(int, 2)
        \\    calls += 1
        \\    return [18, 17]
        \\func calculate() int | none
        \\    var calls = 0
        \\    const values = [1, ..source(calls), 5]
        \\    return values[0] + values[1] + values[2] + values[3] + calls
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "empty typed Array spreads determine element type" {
    try Fixture.expectParity(
        \\func run() int
        \\    const empty: Array(byte, 0) = []
        \\    const values = [..empty]
        \\    return values.len() + 42
    , 42);
}

test "runtime filtered comprehensions construct Lists" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    const values = [x * 2 for x in [10, -1, 11] if x > 0]
        \\    if not (values.len() == 2) -> return none
        \\    return values[0] + values[1]
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "runtime collection clauses emit immutable parameters" {
    try Fixture.expectParity(
        \\func repeated(imm value: int) List(int) -> [value for i in 0..2]
        \\func selected(imm value: int) List(int) -> [value if value > 0]
        \\func calculate() int | none
        \\    const first = repeated(19)
        \\    const second = selected(23)
        \\    return first[0] + second[0]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "diverging collection elements preserve inferred bottom types and empty results" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [exit(42) for i in 0..1]
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func ignored(ref item: never) int -> 91
        \\func forward(ref item: never) int -> ignored(item)
        \\func run() int
        \\    const values = [exit(90) for i in 0..0]
        \\    match values.get(0)
        \\        ref _matched_item and _matched_item is never ->
        \\            ref item = _matched_item
        \\            return forward(item)
        \\        _ -> ()
        \\    if (values.get(0) is never) -> return 92
        \\    return values.len() + 42
    , 42);
}

test "Array spreads retain structural shape when source construction diverges" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [..[exit(42)]]
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    const values: Array(int, 1) = [..[exit(42)]]
        \\    return 90
    , 42);
}

test "fixed Array variant context precedes List and competing converter contexts" {
    try Fixture.expectParity(
        \\struct Other
        \\    count: int
        \\converter(static N: int, init values: collection_literal(byte, N)) Other
        \\    const data: Array(byte, N) = values
        \\    return Other{count = N}
        \\func calculate() int | none
        \\    const first = 19
        \\    const second = 23
        \\    const with_list: Array(int, 2) | List(byte) = [first, second]
        \\    const with_converter: Array(int, 2) | Other = [first, second]
        \\    const contextual: Array(byte, 2) | List(int) = [19, 23]
        \\    const empty: Array(byte, 0) | List(int) = []
        \\    if not (with_list is Array(int, 2)) -> return none
        \\    const a = with_list
        \\    if not (with_converter is Array(int, 2)) -> return none
        \\    const b = with_converter
        \\    if not (contextual is Array(byte, 2)) -> return none
        \\    const c = contextual
        \\    if not (empty is Array(byte, 0)) -> return none
        \\    const d = empty
        \\    return a[0] + b[1] + byte_int(c[0]) - 19 + d.len()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "multiple matching Array members retain ordinary element inference" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    const values: Array(byte, 2) | Array(int, 2) | List(byte) = [19, 23]
        \\    if not (values is Array(int, 2)) -> return none
        \\    const integers = values
        \\    return integers[0] + integers[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "runtime comprehensions nest and support mixed items and spreads" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    const input: List(int) = [9, 10]
        \\    const values = [1, ..input, x + y for x in 10..12 for y in 0..2, 4]
        \\    return values[0] + values[1] + values[2] + values[3] + values[7] + 8
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "bounded runtime comprehension stores ordinary absence and cleans immovable payloads" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value * 10 + self.value
        \\func make(imm trace: Ref(int), value: int) Item | none
        \\    if not (value < 6) -> return none
        \\    return Item{trace = trace, value = value}
        \\func run() int
        \\    var trace = 0
        \\    if true
        \\        const values: List(Item | none) = [make(Ref.from(trace), i) for i in [2, 4, 6]]
        \\        if values.len() <> 3 -> return 90
        \\        match values.get(2)
        \\            ref _matched_item and _matched_item is Item ->
        \\                ref item = _matched_item
        \\                return 91
        \\            _ -> ()
        \\    return trace
    , 42);
}

test "runtime collection growth retains external reference origins" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var original = 41
        \\    const values = [Ref.from(original) for i in 0..3]
        \\    original = 42
        \\    return values[2].value
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "runtime comprehension List destinations construct inside their consumers" {
    try Fixture.expectParity(
        \\struct Holder
        \\    values: List(byte)
        \\func make() List(byte) -> [x for x in Array(byte, 2)([19, 23])]
        \\func calculate() int | none
        \\    var holder = Holder{values = [x for x in Array(byte, 2)([1, 2])]}
        \\    holder.values = make()
        \\    const collected = List(byte).collect([x for x in Array(byte, 2)([19, 23])])
        \\    if not (collected is List(byte)) -> return none
        \\    return byte_int(holder.values[0]) + byte_int(collected[1])
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "runtime sized construction rejects an expected fixed Array" {
    try Fixture.expectSourceDiagnostic(
        \\const values: Array(int, 2) = [x for x in [19, 23]]
    , .collection_requires_static_count);
}

test "static comprehension clauses reject runtime capture" {
    try Fixture.expectSourceDiagnostic(
        \\func build(limit: int) Array(int, 2) -> [x static for x in 0..limit]
        \\build(2)
    , .comptime_runtime_capture);
    try Fixture.expectSourceDiagnostic(
        \\func build(selected: bool) Array(int, 1) -> [42 static if selected]
        \\build(true)
    , .comptime_runtime_capture);
}

test "collection static bounds and predicates recompute after edits" {
    const source =
        \\static limit = 4
        \\func calculate() int | none
        \\    const values = [i + 19 static for i in 0..limit static if i % 2 == 0]
        \\    return values[0] + values[values.len() - 1] + values.len()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "limit = 4", "limit = 6");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectExit(0, 45);
    const filtered = try std.mem.replaceOwned(u8, std.testing.allocator, source, "i % 2 == 0", "i % 2 == 1");
    defer std.testing.allocator.free(filtered);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, filtered);
    try fixture.expectExit(0, 44);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "static traversal snapshots borrowed items without custom copies" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 10}
        \\func calculate() int | none
        \\    const values = [item.value static for item in [Item{value = 19}, Item{value = 23}]]
        \\    return values[0] + values[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "Array spread uses ordinary custom copies and retains the source" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    value: int
        \\    count: Ref(int)
        \\    copy = func(imm self: Item) Item
        \\        self.count.value += 1
        \\        return Item{value = self.value, count = self.count}
        \\func calculate() int | none
        \\    var copies = 0
        \\    const input = [Item{value = 19, count = Ref.from(copies)}, Item{value = 21, count = Ref.from(copies)}]
        \\    const values = [..input]
        \\    return values[0].value + values[1].value + copies
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "runtime filtering releases owned cursor payloads including rejected items" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\struct Cursor
        \\    trace: Ref(int)
        \\    position: int
        \\    func next(mut self: Cursor) Item | End
        \\        if self.position >= 3 -> return End{}
        \\        self.position += 1
        \\        return Item{trace = self.trace, value = self.position}
        \\func calculate() int | none
        \\    var trace = 0
        \\    const values = [item.value for item in Cursor{trace = Ref.from(trace), position = 0} if item.value % 2 == 0]
        \\    return trace + values[0] + 34
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "producer absence remains item data and preserves named cursor state and cleanup" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value = self.trace.value * 10 + self.value
        \\struct Cursor
        \\    position: int
        \\    func next(mut self: Cursor) int | End | none
        \\        self.position += 1
        \\        if self.position > 3 -> return End{}
        \\        if self.position == 3 -> return none
        \\        return self.position * 2
        \\func run() int
        \\    var trace = 0
        \\    var cursor = Cursor{position = 0}
        \\    if true
        \\        const values: List(Item | none) = [(match value
        \\            int ->
        \\                const selected = value
        \\                Item{value = selected, trace = Ref.from(trace)}
        \\            _ -> none) for value in cursor]
        \\        if values.len() <> 3 -> return 90
        \\        match values.get(2)
        \\            ref _matched_item and _matched_item is Item ->
        \\                ref item = _matched_item
        \\                return 91
        \\            _ -> ()
        \\    return trace + cursor.position - 4
    , 42);
}

test "runtime collection optional destinations retain contextual element types" {
    try Fixture.expectParity(
        \\func make() List(byte) | none | AllocationError -> [7 for i in [0, 1]]
        \\func calculate() int | none
        \\    match make()
        \\        values and values is List(byte) -> return byte_int(values[0]) + byte_int(values[1]) + 28
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 91
    , 42);
}

test "static clauses diagnose mutable binding modes" {
    try Fixture.expectSourceDiagnostic("const values = [x static for var x in 0..2]", .static_iteration_binding_mode);
    try Fixture.expectSourceDiagnostic("const values = [x static for ref x in [1, 2]]", .static_iteration_binding_mode);
}

test "mixed runtime construction spreads Arrays structurally after iter edits" {
    const source =
        \\func calculate() int | none
        \\    const input = [19, 23]
        \\    const fixed = [..input]
        \\    const dynamic = [i for i in 0..0, ..input]
        \\    return fixed[0] + dynamic[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const array_file = (try fixture.db.input(test_sources.queries.StandardFile, @backingInt(@import("standard_library").File.array))).*;
    const array_source = (try fixture.db.input(test_sources.queries.SourceText, array_file)).*;
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, array_source, "var view = self.span()", "var view = Span(T).empty()");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(test_sources.queries.SourceText, array_file, edited);
    try fixture.expectExit(0, 42);
}

test "static iteration environments specialize ordinary calls" {
    try Fixture.expectParity(
        \\func element(static index: int) int -> index + 19
        \\func calculate() int | none
        \\    const values = [element(i) static for i in [1, 3]]
        \\    return values[0] + values[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "static expansion preserves generated method environments" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    const values = [(struct
        \\        pub func amount() int -> i + 19
        \\    ).amount() static for i in [1, 3]]
        \\    return values[0] + values[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

fn expectLimitedExit(source: []const u8, status: u8, limit: []const u8) !void {
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    const executable = try fixture.executable(0);
    try test_sources.runtime.writeProgram(std.testing.io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
    var child = std.process.spawn(std.testing.io, .{ .argv = &.{ "prlimit", limit, "--", "./prog" }, .stdout = .ignore, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(std.process.Child.Term{ .exited = status }, try child.wait(std.testing.io));
}

test "collection allocation policy runs before bounded element evaluation" {
    try expectLimitedExit(
        \\func skipped() Array(int, 262144) -> exit(91)
        \\func run() int
        \\    match List(Array(int, 262144)).collect([skipped() for i in [1]])
        \\        values and values is List(Array(int, 262144)) -> return 92
        \\        _ -> ()
        \\    return 42
        \\exit(run())
    , 42, "--as=1048576");
    try expectLimitedExit(
        \\func skipped() Array(int, 262144) -> exit(91)
        \\func run() int
        \\    const values: List(Array(int, 262144)) = [skipped() for i in [1]]
        \\    return values.len() + 91
        \\exit(run())
    , 134, "--as=1048576");
}

test "collection results reject references to local owners" {
    try Fixture.expectSourceDiagnostic(
        \\func make() List(Ref(int))
        \\    var local = 42
        \\    return [Ref.from(local) for i in 0..2]
        \\make()
    , .borrow_outlives_source);
}

test "collection results reject cursor views invalidated by later polls" {
    try Fixture.expectSourceDiagnostic(
        \\struct Cursor
        \\    position: int
        \\    buffered: String
        \\    pub func next(mut self: Cursor) StringView | End | AllocationError
        \\        self.position += 1
        \\        if self.position > 2 -> return End{}
        \\        _ = self.buffered.append("next")?
        \\        return self.buffered.view()
        \\func run() unit | none | AllocationError
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    const values = [view for view in cursor if view is StringView]
        \\    print(values)
        \\    return ()
        \\if (run() is unit) -> exit(0)
    , .borrow_outlives_source);
}

test "recoverable growth allocation failure destroys only the completed prefix" {
    try expectLimitedExit(
        \\struct Item
        \\    payload: Array(int, 65536)
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 1
        \\func run() int
        \\    var trace = 0
        \\    match List(Item).collect([Item{payload = Array(int, 65536).filled(0), trace = Ref.from(trace)} for i in 0..100
        \\    ])
        \\        values and values is List(Item) -> return 90
        \\        _ -> ()
        \\    if trace == 8 -> return 42
        \\    return 91
        \\exit(run())
    , 42, "--as=6000000");
}

test "bounded zero-sized immovable collection elements run cleanup" {
    try Fixture.expectParity(
        \\struct Token
        \\    move = none
        \\    copy = none
        \\    drop = func(deinit self: Token) -> exit(42)
        \\func run() int
        \\    const values = [Token{} for i in [0, 1]]
        \\    return values.len()
    , 42);
}

test "entry static expansion owns generated declarations in its own scope" {
    try Fixture.expectSourceExit(
        \\const values = [(struct
        \\    pub func amount() int -> i + 19
        \\).amount() static for i in [1, 3]]
        \\exit(values[0] + values[1])
    , 42);
}

test "entry static expansion retains lexical environments in callable values" {
    try Fixture.expectSourceExit(
        \\const callbacks: Array(func() int, 2) = [(struct
        \\    pub func amount() int -> i + 19
        \\).amount static for i in [1, 3]]
        \\exit(callbacks[0]() + callbacks[1]())
    , 42);
}

test "collection references cannot escape fresh iteration sources" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\    const values = [Ref.from(item) for item in [19, 23]]
        \\    print(values)
        \\    return ()
        \\if (run() is unit) -> exit(0)
    , .borrow_outlives_source);
}

test "recoverable construction follows init parameter types through callable values" {
    try Fixture.expectParity(
        \\func forward(init values: collection_sequence(int)) List(int) | AllocationError
        \\    return List(int).collect(values)
        \\func invoke(imm collect: func(init collection_sequence(int)) (List(int) | AllocationError)) int | AllocationError
        \\    const fixed = collect([19, 23])?
        \\    const dynamic = collect([value for value in fixed])?
        \\    return dynamic[0] + dynamic[1]
        \\func run() int
        \\    match invoke(forward)
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "callable collection construction retains contained reference origins" {
    try Fixture.expectParity(
        \\func invoke(imm collect: func(init collection_sequence(Ref(int))) (List(Ref(int)) | AllocationError), ref source: Array(int, 2)) List(Ref(int)) | AllocationError
        \\    return collect([Ref.from(value) for ref value in source])
        \\func calculate() int | AllocationError
        \\    var source = [19, 23]
        \\    const values = invoke(List(Ref(int)).collect, source)?
        \\    return values[0].value + values[1].value
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func invoke(imm collect: func(init collection_sequence(Ref(int))) (List(Ref(int)) | AllocationError)) List(Ref(int)) | AllocationError
        \\    var local = 42
        \\    return collect([Ref.from(local) for i in [0]])
        \\match invoke(List(Ref(int)).collect)
        \\    values and values is List(Ref(int)) -> print(values)
        \\    _ -> ()
    , .borrow_outlives_source);
}

test "indirect collection allocation failure precedes element evaluation" {
    try expectLimitedExit(
        \\func skipped() Array(int, 262144) -> exit(91)
        \\func invoke(imm collect: func(init collection_sequence(Array(int, 262144))) (List(Array(int, 262144)) | AllocationError)) List(Array(int, 262144)) | AllocationError
        \\    return collect([skipped() for i in [1]])
        \\func run() int
        \\    match invoke(List(Array(int, 262144)).collect)
        \\        values and values is List(Array(int, 262144)) -> return 92
        \\        _ -> ()
        \\    return 42
        \\exit(run())
    , 42, "--as=1048576");
}

test "collection sequence carriers cannot become ordinary values" {
    try Fixture.expectAnySourceDiagnostic("const pending = collection_sequence(int){}\nprint(pending)", .compile_time_only_type);
    try Fixture.expectAnySourceDiagnostic("static pending = collection_sequence(int){}\nprint(pending)", .compile_time_only_type);
    try Fixture.expectSourceDiagnostic("const pending: collection_sequence(int) = [1, 2]\nprint(pending)", .local_type_mismatch);
}

test "generic sequence consumers infer fixed runtime and forwarded element types" {
    try Fixture.expectParity(
        \\func gather(static T: type, init values: collection_sequence(T)) List(T) | AllocationError
        \\    return List(T).collect(values)
        \\func forward(static T: type, init values: collection_sequence(T)) List(T) | AllocationError
        \\    return gather(values)
        \\func calculate() int | AllocationError
        \\    const fixed = gather([19, 23])?
        \\    const dynamic = forward([value for value in fixed])?
        \\    return dynamic[0] + dynamic[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "collection permutation shares Array List and sliced Span storage" {
    try Fixture.expectFilesParity(
        \\import std.memory.{exchange_slots}
        \\func run() int
        \\    var values = [1, 2, 3, 4, 5]
        \\    var whole = values.span()
        \\    exchange_slots(whole, 0, 4)
        \\    values.reverse()
        \\    if values[0] <> 1 or values[1] <> 4 or values[4] <> 5 -> return 90
        \\    var middle = values[1..4]
        \\    middle.reverse()
        \\    exchange_slots(middle, 0, 2)
        \\    var list: List(int) = [10, 20, 30, 40]
        \\    const capacity = list.capacity()
        \\    list.reverse()
        \\    var list_view = list.span()
        \\    exchange_slots(list_view, 0, 3)
        \\    if list.len() <> 4 or list.capacity() <> capacity -> return 91
        \\    var empty: Array(int, 0) = []
        \\    empty.reverse()
        \\    var single = [42]
        \\    single.reverse()
        \\    var single_view = single.span()
        \\    exchange_slots(single_view, 0, 0)
        \\    if values[0] <> 1 or values[1] <> 4 or values[2] <> 3 or values[3] <> 2 or values[4] <> 5 -> return 92
        \\    if list[0] <> 10 or list[1] <> 30 or list[2] <> 20 or list[3] <> 40 -> return 93
        \\    return single[0]
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }}, 42);
}

test "collection permutation moves noncopyable elements and preserves nested referents" {
    try Fixture.expectFilesParity(
        \\import std.memory.{exchange_slots}
        \\struct Item
        \\    copy = none
        \\    pub target: Ref(int)
        \\func run() int
        \\    var left = 11
        \\    var right = 20
        \\    var array = [Item{target = Ref.from(left)}, Item{target = Ref.from(right)}]
        \\    array.reverse()
        \\    array[0].target.value += 10
        \\    array[1].target.value += 1
        \\    if left <> 12 or right <> 30 -> return 90
        \\    var list: List(Item) = [Item{target = Ref.from(left)}, Item{target = Ref.from(right)}]
        \\    var view = list[..]
        \\    exchange_slots(view, 0, 1)
        \\    view.reverse()
        \\    list[0].target.value += 1
        \\    list[1].target.value -= 1
        \\    if left <> 13 or right <> 29 -> return 91
        \\    return left + right
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }}, 42);
}

test "collection permutation invokes move hooks without copying or premature drops" {
    try Fixture.expectFilesParity(
        \\import std.memory.{exchange_slots}
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\    moves: Ref(int)
        \\    drops: Ref(int)
        \\    move = func(deinit self: Item) Item
        \\        self.moves.value += 1
        \\        return Item{value = self.value, moves = self.moves, drops = self.drops}
        \\    drop = func(deinit self: Item) -> self.drops.value += self.value
        \\func calculate(ref moves: int, ref drops: int) int
        \\    var values = [Item{value = 19, moves = Ref.from(moves), drops = Ref.from(drops)}, Item{value = 23, moves = Ref.from(moves), drops = Ref.from(drops)}]
        \\    var view = values.span()
        \\    exchange_slots(view, 0, 0)
        \\    if moves <> 0 or drops <> 0 -> return 90
        \\    values.reverse()
        \\    if drops <> 0 -> return 91
        \\    if moves <> 4 -> return 92
        \\    return values[0].value + values[1].value
        \\func run() int
        \\    var moves = 0
        \\    var drops = 0
        \\    const answer = calculate(moves, drops)
        \\    if drops <> 42 -> return 93
        \\    return answer
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }}, 42);
}

test "collection permutation retains readonly element captures" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid()
        \\    const readonly = 19
        \\    var writable = 23
        \\    var values = [Ref.from(readonly), Ref.from(writable)]
        \\    values[0].value += 1
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\func invalid()
        \\    const readonly = 19
        \\    var writable = 23
        \\    var values = [Ref.from(readonly), Ref.from(writable)]
        \\    values.reverse()
        \\    values[1].value += 1
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\func invalid()
        \\    var values = [19, 23]
        \\    const source = values.span()
        \\    var copy = source
        \\    copy.reverse()
        \\invalid()
    , .reference_not_writable);
}

test "collection permutation rejects loans into relocated element storage" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid()
        \\    var values: Array(List(int), 2) = [[19], [23]]
        \\    ref first = values[0][0]
        \\    values.reverse()
        \\    print(first)
        \\invalid()
    , .borrow_outlives_source);
}

test "collection permutation recomputes changed callee effects" {
    const readonly =
        \\pub func permute(mut values: Array(List(int), 2)) -> ()
    ;
    const reversing =
        \\pub func permute(mut values: Array(List(int), 2)) -> values.reverse()
    ;
    const fixture = try Fixture.initFiles(
        \\import library.{permute}
        \\var values: Array(List(int), 2) = [[19], [23]]
        \\ref first = values[0][0]
        \\permute(values)
        \\exit(first + 23)
    , &.{.{ .path = "library/algorithm.chi", .module_path = "library", .source = readonly }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, reversing);
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, readonly);
    try fixture.expectExit(0, 42);
}

test "collection permutation preserves stable scalar slot references" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = [19, 23]
        \\    ref first = values[0]
        \\    values.reverse()
        \\    return first + values[1]
    , 42);
}

test "collection permutation transfers explicit drop obligations" {
    try Fixture.expectParity(
        \\struct Token
        \\    drop = explicit
        \\    pub value: int
        \\func dispose(deinit token: Token) int -> token.value
        \\func run() int
        \\    var values = [Token{value = 19}, Token{value = 23}]
        \\    var view = values[..]
        \\    view.reverse()
        \\    const [first, second] = values^
        \\    const selected = first.value
        \\    const total = dispose(first^) + dispose(second^)
        \\    if selected <> 23 -> return 90
        \\    return total
    , 42);
}

test "collection permutation handles zero sized elements and drop counts" {
    const fixture = try Fixture.initFiles(
        \\import std.memory.{exchange_slots}
        \\struct Token
        \\    copy = none
        \\    drop = func(deinit self: Token) -> print("drop")
        \\func run()
        \\    var values = [Token{}, Token{}, Token{}]
        \\    values.reverse()
        \\    var view = values.span()
        \\    exchange_slots(view, 1, 1)
        \\run()
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }});
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("drop\ndrop\ndrop\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "collection exchange remains a private library helper" {
    try Fixture.expectSourceDiagnostic(
        \\var values = [19, 23]
        \\values.swap(0, 1)
    , .unknown_namespace_member);
}

const cursor_test_library =
    \\pub func exchange_slots(static T: type, mut source: Span(T), first: int, second: int)
    \\    swap_elements(T, source.data, first, second)
    \\pub func take_slot(static T: type, mut storage: Allocation(T), index: int) T
    \\    var cursor = allocation_cursor(T, storage)
    \\    return cursor_take(T, cursor, index)
    \\pub func destroy_slot(static T: type, mut storage: Allocation(T), index: int)
    \\    var cursor = allocation_cursor(T, storage)
    \\    cursor_destroy(T, cursor, index)
;

test "collection cursor extraction detaches contained references from allocation storage" {
    try Fixture.expectFilesParity(
        \\import std.memory.{Allocation, take_slot}
        \\func run() int
        \\    var target = 19
        \\    var storage = Allocation(Ref(int)).allocate(1)
        \\    if not (storage is Allocation(Ref(int))) -> return 90
        \\    storage.unsafe_initialize(0, Ref.from(target))
        \\    var saved = take_slot(storage, 0)
        \\    storage.deallocate()
        \\    saved.value += 23
        \\    return target
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }}, 42);
}

test "collection cursor destruction handles immovable values in their original slots" {
    try Fixture.expectFilesParity(
        \\import std.memory.{Allocation, destroy_slot}
        \\struct Token
        \\    move = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Token) -> self.trace.value += 23
        \\func run() int
        \\    var trace = 19
        \\    var storage = Allocation(Token).allocate(1)
        \\    if not (storage is Allocation(Token)) -> return 90
        \\    storage.unsafe_initialize(0, Token{trace = Ref.from(trace)})
        \\    destroy_slot(storage, 0)
        \\    storage.deallocate()
        \\    return trace
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }}, 42);
}

test "collection permutation rejects immovable elements at the public capability boundary" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Token
        \\    move = none
        \\var values = [Token{}, Token{}]
        \\values.reverse()
    , .where_condition_failed);
}

test "collection permutation exports custom hook alias exclusions to callers" {
    const source =
        \\struct Item
        \\    pub value: int
        \\    pub target: Ref(int)
        \\    move = func(deinit self: Item) Item
        \\        self.target.value += 1
        \\        return Item{value = self.value, target = self.target}
        \\func invalid()
        \\    var external = 0
        \\    var values = [Item{value = 19, target = Ref.from(external)}, Item{value = 23, target = Ref.from(external)}]
        \\    values[0].target = Ref.from(values[1].value)
        \\    values.reverse()
        \\invalid()
    ;
    const unchanged = try std.mem.replaceOwned(u8, std.testing.allocator, source, "values.reverse()", "unit");
    defer std.testing.allocator.free(unchanged);
    const fixture = try Fixture.init(unchanged);
    defer fixture.deinit();
    try fixture.expectExit(0, 0);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "collection permutation preserves active variants containing owners and reference handles" {
    try Fixture.expectFilesParity(
        \\import std.memory.{exchange_slots}
        \\struct Token
        \\    pub value: int
        \\func run() int
        \\    var target = 23
        \\    var values: Array(Token | Ref(int) | none, 3) = [Token{value = 19}, Ref.from(target), none]
        \\    values.reverse()
        \\    if not (values[0] is none) -> return 90
        \\    var view = values.span()
        \\    exchange_slots(view, 0, 1)
        \\    ref first = values[0]
        \\    if not (first is Ref(int)) -> return 91
        \\    var selected = first
        \\    selected.value += 19
        \\    ref last = values[2]
        \\    if not (last is Token) -> return 92
        \\    if last.value <> 19 -> return 93
        \\    return target
    , &.{.{ .path = "cursor_test.chi", .module_path = "std.memory", .source = cursor_test_library }}, 42);
}

test "collection permutation without custom moves preserves references into stable backing slots" {
    try Fixture.expectParity(
        \\struct Item
        \\    pub value: int
        \\    pub target: Ref(int)
        \\func run() int
        \\    var external = 0
        \\    var values = [Item{value = 19, target = Ref.from(external)}, Item{value = 23, target = Ref.from(external)}]
        \\    values[0].target = Ref.from(values[1].value)
        \\    values.reverse()
        \\    var selected = values[1].target
        \\    selected.value += 23
        \\    if values[1].value <> 42 -> return 90
        \\    return values[1].value
    , 42);
}
