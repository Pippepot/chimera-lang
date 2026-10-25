const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "typed binding selects a value and keeps false distinct from none" {
    try Fixture.expectParity(
        \\func present() bool | none -> false
        \\func absent() bool | none -> none
        \\func run() int
        \\    const selected: bool = present() else return 1
        \\    if selected -> return 2
        \\    if const missing: bool = absent() -> return 3
        \\    const optional = absent()
        \\    if optional is none -> return 42
        \\    return 4
    , 42);
}

test "typed binding source runs once and mismatch can return an explicit error" {
    try Fixture.expectParity(
        \\struct Error
        \\    code: int
        \\func get(mut count: int) int | none
        \\    count += 1
        \\    return none
        \\func choose(mut count: int) int | Error
        \\    const value: int = get(count) else return Error{code = 41}
        \\    return value
        \\func run() int
        \\    var count = 0
        \\    return match choose(count)
        \\        error: Error -> error.code + count
        \\        value: int -> value
    , 42);
}

test "explicit variants allocate and index collections" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values: List(int) = List(int).new(2) else return 1
        \\    const _: unit = values.append(19) else return 2
        \\    const _: unit = values.append(23) else return 3
        \\    const first: int = values.get(0) else return 4
        \\    if const missing: int = values.get(2) -> return missing
        \\    return first + values[1]
    , 42);
}

test "plain optional conditions and implicit narrowing are rejected" {
    try Fixture.expectSourceDiagnostic(
        \\const value: bool | none = false
        \\if value -> exit(1)
    , .condition_not_bool);
    try Fixture.expectSourceDiagnostic(
        \\func optional() int | none -> none
        \\const value: int = optional()
    , .local_type_mismatch);
    try Fixture.expectSourceDiagnostic(
        \\func optional() int | none -> none
        \\const value: int = optional() else ()
    , .binding_else_must_exit);
}

test "typed patterns never invoke converters" {
    try Fixture.expectParity(
        \\struct Input
        \\    value: int
        \\struct Output
        \\    value: int
        \\pub converter(imm value: Input) Output -> exit(99)
        \\func run() int
        \\    const input: Input | none = Input{value = 19}
        \\    if const value: Output = input -> return value.value
        \\    return 42
    , 42);
}

test "reference binding updates the selected payload in its owner" {
    try Fixture.expectParity(
        \\func run() int
        \\    var input: int | none = 19
        \\    if ref value: int = input -> value += 23
        \\    const result: int = input else return 1
        \\    return result
    , 42);
}

test "reference binding handles certain and disjoint selections" {
    try Fixture.expectParity(
        \\func run() int
        \\    var number = 19
        \\    if ref missing: bool = number -> return 90
        \\    if ref selected: int = number -> selected += 23
        \\    return number
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var number = 19
        \\    ref selected: int = number else return 90
        \\    selected += 23
        \\    return number
    , 42);
}

test "typed match capture commits an immovable explicit owner after its guard" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    move = none
        \\    drop = explicit
        \\    value: int
        \\func dispose(deinit token: Token) int -> token.value
        \\func produce() Token | none -> Token{value = 42}
        \\func run() int
        \\    return match produce()
        \\        token: Token and false -> dispose(token)
        \\        token: Token -> dispose(token)
        \\        none -> 0
    , 42);
}

test "typed borrowed match captures copy once per matching attempt" {
    try Fixture.expectParity(
        \\struct Item
        \\    copies: Ref(int)
        \\    value: int
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{copies = self.copies, value = self.value}
        \\func run() int
        \\    var copies = 0
        \\    const input: Item | none = Item{copies = Ref.from(copies), value = 40}
        \\    const value = match input
        \\        item: Item and false -> 0
        \\        item: Item -> item.value
        \\        none -> 1
        \\    return value + copies
    , 42);
}

test "owned pattern mismatch cleans its temporary before its handler" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 1
        \\func produce(ref trace: int) Item | none -> Item{trace = Ref.from(trace)}
        \\func run() int
        \\    var trace = 0
        \\    const value: int = produce(trace) else return trace + 41
        \\    return value
    , 42);
}

test "an affine initializer may be skipped without consuming its captured owner" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 1
        \\func decline(init value: Item) unit -> ()
        \\func run() int
        \\    var trace = 0
        \\    const item = Item{trace = Ref.from(trace)}
        \\    decline(item^)
        \\    return trace + 41
    , 42);
}

test "typed binding result alternatives recompute after edits" {
    const source =
        \\func choose() int | bool | none -> 42
        \\if const number: int = choose() -> exit(number)
        \\else exit(19)
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const std = @import("std");
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "-> 42", "-> false");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectExit(0, 19);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "range indexing preserves writable backing and checked slices return variants" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = [10, 20, 30]
        \\    var view = values[1..]
        \\    view[0] = 22
        \\    const tail: Span(int) = values.slice(2..) else return 1
        \\    return values[0] + values[1] + tail[0] - 20
    , 42);
}

test "standalone patterns support mutation and loop mismatch exits" {
    try Fixture.expectParity(
        \\func run() int
        \\    var total: int = if true -> 0 else none else return 1
        \\    const values: Array(int | none, 3) = [none, 19, 23]
        \\    for candidate in values
        \\        const value: int = candidate else continue
        \\        total += value
        \\    return total
    , 42);
}

test "affine initializers reject repeated construction" {
    try Fixture.expectSourceDiagnostic(
        \\func twice(init value: int) int
        \\    const first = value
        \\    const second = value
        \\    return first + second
        \\exit(twice(1))
    , .initializer_already_consumed);
}

test "explicit absent results preserve deferred root field and conditional transfer cleanup" {
    const std = @import("std");
    const cases = [_]struct { setup: []const u8, payload: []const u8, capture: []const u8, after: []const u8 = "", first: []const u8, second: []const u8 }{
        .{ .setup = "var source = Pair{first = Item{value = 1, trace = Ref.from(trace)}, second = Item{value = 2, trace = Ref.from(trace)}}", .payload = "Pair", .capture = "source^", .first = "303", .second = "303" },
        .{ .setup = "var source = FixedPair{first = Item{value = 1, trace = Ref.from(trace)}, second = Item{value = 2, trace = Ref.from(trace)}}", .payload = "Item", .capture = "source.first^", .first = "103", .second = "103" },
        .{ .setup = "var source = FixedPair{first = Item{value = 1, trace = Ref.from(trace)}, second = Item{value = 2, trace = Ref.from(trace)}}", .payload = "Item", .capture = "source.second^", .first = "203", .second = "203" },
        .{ .setup = "var source = Outer{pair = FixedPair{first = Item{value = 1, trace = Ref.from(trace)}, second = Item{value = 2, trace = Ref.from(trace)}}, spare = Item{value = 4, trace = Ref.from(trace)}}", .payload = "Item", .capture = "source.pair.first^", .first = "107", .second = "107" },
        .{ .setup = "var source = Item{value = 1, trace = Ref.from(trace)}\n        var other = FixedPair{first = Item{value = 2, trace = Ref.from(trace)}, second = Item{value = 4, trace = Ref.from(trace)}}", .payload = "Item", .capture = "if flag -> source^ else other.first^", .first = "107", .second = "207" },
        .{ .setup = "var source = Item{value = 1, trace = Ref.from(trace)}", .payload = "Item", .capture = "source^", .after = "source = Item{value = 8, trace = Ref.from(trace)}\n        _ = source", .first = "109", .second = "109" },
        .{ .setup = "var source = FixedPair{first = Item{value = 1, trace = Ref.from(trace)}, second = Item{value = 2, trace = Ref.from(trace)}}", .payload = "Item", .capture = "source.first^", .after = "source.first = Item{value = 8, trace = Ref.from(trace)}\n        _ = source", .first = "111", .second = "111" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Item
            \\    value: int
            \\    trace: Ref(int)
            \\    copy = none
            \\    move = func(deinit self: Item) Item
            \\        self.trace.value += self.value * 100
            \\        return Item{value = self.value, trace = self.trace}
            \\    drop = func(deinit self: Item) -> self.trace.value += self.value
            \\struct Pair
            \\    first: Item
            \\    second: Item
            \\struct FixedPair
            \\    move = none
            \\    first: Item
            \\    second: Item
            \\struct Outer
            \\    move = none
            \\    pair: FixedPair
            \\    spare: Item
            \\func produce(static T: type, init value: T, init remainder: int | none) T | none
            \\    const owned = value
            \\    const _: int = remainder else return none
            \\    return owned^
            \\func receive(static T: type, init value: T | none) int
            \\    const owned: T = value else return 42
            \\    _ = owned
            \\    return 0
            \\func calculate(flag: bool) int
            \\    var trace = 0
            \\    if true
            \\        $setup
            \\        const status = receive($payload, produce($payload, $capture, none))
            \\        if status <> 42 -> return 99
            \\        $after
            \\    return trace
            \\func run() int
            \\    if calculate(true) <> $first -> return 1
            \\    if calculate(false) <> $second -> return 2
            \\    return 42
        , .{ .setup = case.setup, .payload = case.payload, .capture = case.capture, .after = case.after, .first = case.first, .second = case.second });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "deferred optional results forward through generic and indirect calls" {
    try Fixture.expectParity(
        \\func materialize(static T: type, init value: T) T -> value
        \\func forward(init value: int | none) int | none -> materialize(value)
        \\func invoke(imm callback: func(init int | none) int | none, init value: int | none) int | none -> callback(value)
        \\func run() int
        \\    const missing = invoke(forward, none)
        \\    const answer: int = invoke(forward, 42) else return 1
        \\    if missing is none -> return answer
        \\    return 2
    , 42);
}

test "an explicit optional initializer preserves immovable storage and completed writes" {
    try Fixture.expectParity(
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Pinned) -> self.drops.value += 1
        \\func produce(present: bool, ref drops: int) Pinned | none
        \\    if not present -> return none
        \\    return Pinned{value = 21, drops = Ref.from(drops)}
        \\func receive(mut calls: int, init value: Pinned | none) int | none
        \\    calls += 1
        \\    const item: Pinned = value else return none
        \\    return item.value
        \\func run() int
        \\    var calls = 0
        \\    var drops = 0
        \\    if const unexpected: int = receive(calls, produce(false, drops)) -> return unexpected
        \\    const value: int = receive(calls, produce(true, drops)) else return 1
        \\    if drops <> 1 -> return 2
        \\    return value + calls + 19
    , 42);
}

test "a Box owns an optional immovable producer result in place" {
    try Fixture.expectParity(
        \\struct Pinned
        \\    move = none
        \\    copy = none
        \\    value: int
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Pinned) -> self.drops.value += 1
        \\func produce(ref drops: int) Pinned | none -> Pinned{value = 21, drops = Ref.from(drops)}
        \\func run() int
        \\    var drops = 0
        \\    var owner: Box(Pinned | none) = Box.new(produce(drops)) else return 1
        \\    const value = if ref item: Pinned = owner.borrow() -> item.value else 0
        \\    return value + drops + 20
    , 42);
}

test "an explicit absent producer cleans partial fields before a Box stores none" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\struct Pair
        \\    copy = none
        \\    move = none
        \\    first: Item
        \\    second: Item
        \\func second(present: bool, ref trace: int) Item | none
        \\    if not present -> return none
        \\    return Item{value = 2, trace = Ref.from(trace)}
        \\func produce(present: bool, ref trace: int) Pair | none
        \\    return Pair{
        \\        first = Item{value = 1, trace = Ref.from(trace)},
        \\        second = if const item: Item = second(present, trace) -> item^ else return none,
        \\    }
        \\func run() int
        \\    var trace = 0
        \\    const owner: Box(Pair | none) = Box.new(produce(false, trace)) else return 1
        \\    if owner.borrow() is none and trace == 1 -> return 42
        \\    return 2
    , 42);
}
