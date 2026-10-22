const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "match scalar literals captures and nested expressions" {
    try Fixture.expectParity(
        \\func choose(number: int) int
        \\    return match number
        \\        -1 -> 90
        \\        0 as zero -> zero + 19
        \\        other -> other + 22
        \\func run() int -> choose(0) + choose(1)
    , 42);
    try Fixture.expectParity(
        \\func add(a: int, b: int) int -> a + b
        \\func run() int
        \\    return add(
        \\        match true
        \\            true ->
        \\                match 1
        \\                    1 -> 19
        \\                    _ -> 90
        \\            false -> 91,
        \\        23)
    , 42);
}

test "match evaluates its subject once and chooses only one arm" {
    try Fixture.expectParity(
        \\func produce(mut calls: int) int | none
        \\    calls += 1
        \\    return 42
        \\func run() int
        \\    var calls = 0
        \\    const selected = match produce(calls)
        \\        none -> 90
        \\        0 -> 91
        \\        is int as value -> value
        \\    return selected + calls - 1
    , 42);
}

test "match immutable captures copy while explicit references alias" {
    try Fixture.expectParity(
        \\func run() int
        \\    var number = 19
        \\    const copied = match number
        \\        0 -> 90
        \\        item ->
        \\            number = 23
        \\            item
        \\    match number
        \\        ref alias -> alias += copied
        \\    return number
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var source: int | none = 19
        \\    match source
        \\        is int as ref item -> item += 23
        \\        none -> ()
        \\    if const result = source as int -> return result
        \\    return 90
    , 42);
}

test "match type arms permit partial overlap without residual capture typing" {
    try Fixture.expectParity(
        \\func choose(value: bool) int | bool | none -> value
        \\func run() int
        \\    return match choose(true)
        \\        is int -> 90
        \\        is int | bool as selected ->
        \\            if const flag = selected as bool
        \\                if flag? -> return 42
        \\            return 91
        \\        none -> 92
    , 42);
}

test "match finite domains distinguish false unit and none data" {
    try Fixture.expectParity(
        \\func run() int
        \\    const first = match false
        \\        true -> 90
        \\        false -> 19
        \\    const second = match ()
        \\        () -> 23
        \\    const third = match none
        \\        none -> 0
        \\    return first + second + third
    , 42);
}

test "match byte literals and integer default remain distinct" {
    try Fixture.expectParity(
        \\func run() int
        \\    const byte_value: byte = 1
        \\    const first = match byte_value
        \\        1 -> 19
        \\        _ -> 90
        \\    const number: int | byte = byte_value
        \\    const second = match number
        \\        1 -> 91
        \\        is byte -> 23
        \\        is int -> 92
        \\    return first + second
    , 42);
}

test "match text literals compare decoded bytes without copying Strings" {
    try Fixture.expectParity(
        \\func run() int
        \\    const text: String = "a\0b"
        \\    return match text
        \\        "other" -> 90
        \\        "a\u{0}b" -> 42
        \\        _ -> 91
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    const text: StringView = "hello"
        \\    return match text
        \\        "hello" -> 42
        \\        _ -> 90
    , 42);
}

test "match preserves expected result conversion and optional failure boundaries" {
    try Fixture.expectParity(
        \\fallible reject() int -> fail
        \\func run() int
        \\    const result: int | none = match true
        \\        true -> reject?()
        \\        false -> 90
        \\    return match result
        \\        none -> 42
        \\        is int -> 91
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    const view: StringView = match true
        \\        true -> "answer"
        \\        false -> "wrong"
        \\    if view == "answer" -> return 42
        \\    return 90
    , 42);
}

test "match subject failure and selected arm failure do not retry" {
    try Fixture.expectParity(
        \\fallible produce(mut calls: int) int | none
        \\    calls += 1
        \\    fail
        \\fallible select(mut calls: int) int
        \\    return match produce?(calls)
        \\        none ->
        \\            calls += 100
        \\            90
        \\        is int -> 91
        \\func run() int
        \\    var calls = 0
        \\    if const result = select(calls) -> return result
        \\    return calls + 41
    , 42);
    try Fixture.expectParity(
        \\fallible select(mut calls: int) int
        \\    return match 1
        \\        1 ->
        \\            calls += 1
        \\            fail
        \\        _ ->
        \\            calls += 100
        \\            90
        \\func run() int
        \\    var calls = 0
        \\    if const result = select(calls) -> return result
        \\    return calls + 41
    , 42);
}

test "match keeps fresh noncopyable payloads through rejected tests" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func produce() Item | int | none -> Item{value = 42}
        \\func consume(deinit item: Item) int -> item.value
        \\func run() int
        \\    return match produce()
        \\        none -> 90
        \\        0 -> 91
        \\        is int -> 92
        \\        is Item as selected -> consume(selected^)
    , 42);
}

test "match selected and rejected owners are dropped once with ASAP timing" {
    try Fixture.expectParity(
        \\struct Tracked
        \\    copy = none
        \\    trace: Ref(int)
        \\    digit: int
        \\    drop = func(deinit self: Tracked)
        \\        self.trace.value = self.trace.value * 10 + self.digit
        \\func produce(ref trace: int) Tracked | int | none -> Tracked{trace = Ref.from(trace), digit = 1}
        \\func observe(imm first: Tracked, imm second: Tracked) -> ()
        \\func run() int
        \\    var trace = 0
        \\    const outer = Tracked{trace = Ref.from(trace), digit = 2}
        \\    match produce(trace)
        \\        none -> ()
        \\        0 -> ()
        \\        is int -> ()
        \\        is Tracked ->
        \\            const inner = Tracked{trace = Ref.from(trace), digit = 3}
        \\            observe(outer, inner)
        \\    if trace == 132 -> return 42
        \\    return trace
    , 42);
}

test "match narrows explicit drop obligations across continuations" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\    number: int
        \\struct Tracked
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Tracked) -> self.trace.value += 1
        \\func dispose(deinit token: Token) -> ()
        \\func produce(ref trace: int, token: bool) Token | Tracked | none
        \\    if token? -> return Token{number = 19}
        \\    return Tracked{trace = Ref.from(trace)}
        \\func inspect(ref trace: int, token: bool) int
        \\    return match produce(trace, token)
        \\        none -> 90
        \\        is Token as selected ->
        \\            const result = selected.number
        \\            dispose(selected)
        \\            result
        \\        is Tracked -> 22
        \\func run() int
        \\    var trace = 0
        \\    const first = inspect(trace, true)
        \\    const second = inspect(trace, false)
        \\    return first + second + trace
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Token
        \\    drop = explicit
        \\func produce() Token | none -> none
        \\match produce()
        \\    _ -> ()
    , .value_requires_explicit_drop);
}

test "match fresh immovable payloads hand off without relocation" {
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func produce() Fixed | none -> Fixed{value = 42}
        \\func consume(deinit item: Fixed) int -> item.value
        \\func run() int
        \\    return match produce()
        \\        none -> 90
        \\        is Fixed as selected -> consume(selected)
    , 42);
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func produce() Fixed -> Fixed{value = 42}
        \\func run() int
        \\    return match produce()
        \\        selected -> selected.value
    , 42);
}

test "match subset capture reconstructs the selected variant layout" {
    try Fixture.expectParity(
        \\struct Wide
        \\    ref value: int
        \\func produce() Wide | int | bool -> 42
        \\func run() int
        \\    return match produce()
        \\        is Wide -> 90
        \\        is int | bool as selected ->
        \\            if const number = selected as int -> return number
        \\            return 91
    , 42);
}

test "match borrowed noncopyable sources need explicit ref captures" {
    const declarations =
        \\struct Item
        \\    copy = none
        \\    value: int
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const owner: Item | none = Item{value = 42}
        \\    return match owner
        \\        is Item as ref selected -> selected.value
        \\        none -> 90
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\const owner: Item | none = Item{value = 42}
        \\const result = match owner
        \\    is Item as selected -> selected.value
        \\    none -> 90
    , .type_not_copyable);
    try Fixture.expectSourceDiagnostic(
        \\const owner: int | none = 41
        \\match owner
        \\    is int as ref selected -> selected += 1
        \\    none -> ()
    , .reference_not_writable);
}

test "match reference alternatives preserve authority and may outlive their carrier" {
    try Fixture.expectParity(
        \\func capture(ref owner: int) ref int | none -> owner
        \\func select(ref owner: int) ref int
        \\    return match capture(owner)
        \\        is int as ref selected -> selected
        \\        none -> owner
        \\func run() int
        \\    var owner = 19
        \\    ref selected = select(owner)
        \\    selected += 23
        \\    return owner
    , 42);
    try Fixture.expectParity(
        \\func capture(ref owner: int) ref int | none -> owner
        \\func run() int
        \\    var owner = 19
        \\    const result = match capture(owner)
        \\        is int as selected ->
        \\            owner = 23
        \\            selected
        \\        none -> 90
        \\    return result + owner
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    value: int
        \\func produce() Item -> Item{value = 42}
        \\func invalid() ref int
        \\    return match produce()
        \\        ref selected -> selected.value
        \\ref result = invalid()
    , .borrow_outlives_source);
}

test "match supports mixed owned and reference alternatives without storage selection" {
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref owner: int) ref int | End -> owner
        \\func choose(ref owner: int, borrowed: bool) int | ref int | End
        \\    if borrowed? -> return capture(owner)
        \\    return 19
        \\func update(ref owner: int, borrowed: bool) int
        \\    return match choose(owner, borrowed)
        \\        is int as ref selected ->
        \\            selected += 23
        \\            selected
        \\        is End -> 90
        \\func run() int
        \\    var owner = 19
        \\    if update(owner, false) <> 42 -> return 91
        \\    if update(owner, true) <> 42 -> return 92
        \\    return owner
    , 42);
}

test "match integrates direct immovable construction and consuming arm results" {
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func produce(flag: bool) Fixed
        \\    return match flag
        \\        true -> Fixed{value = 19}
        \\        false -> Fixed{value = 23}
        \\func consume(deinit item: Fixed) int -> item.value
        \\func run() int
        \\    const first = produce(true)
        \\    const second = produce(false)
        \\    const a = consume(first)
        \\    const b = consume(second)
        \\    return a + b
    , 42);
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func consume(deinit item: Fixed) int -> item.value
        \\func run() int
        \\    const first = Fixed{value = 19}
        \\    const second = Fixed{value = 42}
        \\    return consume(match false
        \\        true -> first
        \\        false -> second)
    , 42);
}

test "match break and continue use the surrounding loop" {
    try Fixture.expectParity(
        \\func run() int
        \\    var total = 0
        \\    for item in 0..4
        \\        match item
        \\            0 -> continue
        \\            3 -> break
        \\            value -> total += value
        \\    return total * 14
    , 42);
}

test "match nonlocal exits clean retained owned subjects" {
    const declarations =
        \\struct Tracked
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Tracked) -> self.trace.value += 1
        \\func produce(ref trace: int) Tracked | none -> Tracked{trace = Ref.from(trace), value = 41}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func choose(ref trace: int) int
        \\    return match produce(trace)
        \\        none -> 90
        \\        is Tracked as selected -> return selected.value
        \\func run() int
        \\    var trace = 0
        \\    const result = choose(trace)
        \\    return result + trace
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\fallible reject(ref trace: int) int
        \\    return match produce(trace)
        \\        none -> 90
        \\        is Tracked as selected -> fail
        \\func run() int
        \\    var trace = 0
        \\    if const result = reject(trace) -> return result
        \\    return trace + 41
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var trace = 0
        \\    for index in 0..3
        \\        match produce(trace)
        \\            none -> ()
        \\            is Tracked ->
        \\                if index == 0 -> continue
        \\                break
        \\    return trace + 40
    , 42);
}

test "match byte domain is exhaustive only after all 256 values" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("func choose(value: byte) int\n    return match value\n");
    for (0..256) |index| try source.writer.print("        {d} -> {d}\n", .{ index, if (index == 255) @as(usize, 42) else 0 });
    try source.writer.writeAll("func run() int\n    const last: byte = 255\n    return choose(last)\n");
    try Fixture.expectParity(source.written(), 42);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source.written(), "        255 -> 42\n", "");
    defer std.testing.allocator.free(missing);
    const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{missing});
    defer std.testing.allocator.free(rejected);
    try Fixture.expectSourceDiagnostic(rejected, .match_not_exhaustive);
}

test "match normalizes decoded literal coverage and respects type coverage" {
    try Fixture.expectSourceDiagnostic(
        \\const result = match "a\0b"
        \\    "a\0b" -> 1
        \\    "a\u{0}b" -> 2
        \\    _ -> 3
    , .match_redundant_arm);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: int | bool | none) int
        \\    return match value
        \\        is int -> 1
        \\        is bool -> 2
        \\        is int | bool -> 3
        \\        none -> 4
        \\exit(choose(1))
    , .match_redundant_arm);
}

test "match rejects nonexhaustive redundant incompatible and duplicate captures" {
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: bool) int
        \\    return match value
        \\        true -> 1
        \\exit(choose(true))
    , .match_not_exhaustive);
    try Fixture.expectSourceDiagnostic(
        \\const value = match 1
        \\    1 -> 2
        \\    1 -> 3
        \\    _ -> 4
    , .match_redundant_arm);
    try Fixture.expectSourceDiagnostic(
        \\const value = match true
        \\    true -> 1
        \\    false -> 2
        \\    _ -> 3
    , .match_redundant_arm);
    try Fixture.expectSourceDiagnostic(
        \\const value = match 1
        \\    is bool -> 2
        \\    _ -> 3
    , .match_pattern_incompatible);
    try Fixture.expectSourceDiagnostic(
        \\const value = match 1
        \\    x as y -> x + y
    , .match_multiple_captures);
    try Fixture.expectSourceDiagnostic(
        \\const value = match 1
        \\    var x -> x
    , .match_capture_must_be_immutable);
}

test "match captures use ordinary copy hooks and explicit transfer" {
    try Fixture.expectParity(
        \\struct Item
        \\    copies: Ref(int)
        \\    value: int
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{copies = self.copies, value = self.value}
        \\func run() int
        \\    var copies = 0
        \\    const owner = Item{copies = Ref.from(copies), value = 14}
        \\    const first = match owner
        \\        selected -> selected.value
        \\    const second = match Item{copies = Ref.from(copies), value = 14}
        \\        selected -> selected.value
        \\    const third = match owner^
        \\        selected -> selected.value
        \\    if copies <> 1 -> return 90
        \\    return first + second + third
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\var owner: int | none = 42
        \\match owner^
        \\    none -> ()
        \\    is int -> ()
        \\const invalid = owner
    , .use_after_transfer);
}

test "match overlapping owning captures retain only feasible drop obligations" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\struct Tracked
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Tracked) -> self.trace.value += 1
        \\func dispose(deinit token: Token) -> ()
        \\func produce(ref trace: int) Token | Tracked | none -> Tracked{trace = Ref.from(trace)}
        \\func run() int
        \\    var trace = 0
        \\    const result = match produce(trace)
        \\        is Token as selected ->
        \\            dispose(selected)
        \\            90
        \\        is Token | Tracked as selected ->
        \\            var retained = selected^
        \\            const finished = loop
        \\                break if trace == 0
        \\                    retained^
        \\                else
        \\                    retained^
        \\            match finished^
        \\                is Token as token ->
        \\                    dispose(token)
        \\                    92
        \\                is Tracked -> 41
        \\        none -> 91
        \\    return result + trace
    , 42);
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\func dispose(deinit token: Token) -> ()
        \\func produce() Token | int | none -> 42
        \\func run() int
        \\    return match produce()
        \\        is Token as token ->
        \\            dispose(token)
        \\            90
        \\        selected ->
        \\            const retained = selected^
        \\            match retained^
        \\                is Token as token ->
        \\                    dispose(token)
        \\                    91
        \\                is int as number -> number
        \\                none -> 92
    , 42);
}

test "match rejects borrowed subset layouts and ambiguous text domains" {
    try Fixture.expectSourceDiagnostic(
        \\struct Wide
        \\    ref value: int
        \\var owner: Wide | int | bool = 42
        \\match owner
        \\    is Wide -> ()
        \\    is int | bool as ref selected -> ()
    , .reference_projection_requires_member);
    try Fixture.expectSourceDiagnostic(
        \\func choose(view: StringView) String | StringView -> view
        \\const result = match choose("x")
        \\    "x" -> 42
        \\    _ -> 90
    , .match_literal_ambiguous);
}

test "match literals do not invoke user converters or equality" {
    try Fixture.expectSourceDiagnostic(
        \\struct Wrapped
        \\    value: int
        \\    pub fallible ==(imm left: Wrapped, imm right: Wrapped) unit -> ()
        \\converter(static value: int_literal) Wrapped -> Wrapped{value = int(value)}
        \\const result = match Wrapped{value = 42}
        \\    42 -> 1
        \\    _ -> 2
    , .match_pattern_incompatible);
    try Fixture.expectSourceDiagnostic(
        \\const owner: byte = 0
        \\const result = match owner
        \\    -1 -> 1
        \\    _ -> 2
    , .match_pattern_incompatible);
    try Fixture.expectSourceDiagnostic(
        \\const owner: int = 0
        \\const result = match owner
        \\    2147483648 -> 1
        \\    _ -> 2
    , .integer_literal_out_of_range);
}

test "match static specialization and sibling capture scopes stay independent" {
    try Fixture.expectParity(
        \\func choose(static number: int_literal) int
        \\    return match number
        \\        1 as selected -> int(selected) + 18
        \\        selected -> int(selected) + 21
        \\func run() int -> choose(1) + choose(2)
    , 42);
}
