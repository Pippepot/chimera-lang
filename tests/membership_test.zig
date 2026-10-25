const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "bounded integer membership respects inclusivity emptiness and integer limits" {
    try Fixture.expectParity(
        \\func accepted(value: int) int | none
        \\    if not (value in 19..=23) -> return none
        \\    return value
        \\func run() int
        \\    if not (0 in 0..10) -> return 90
        \\    if 10 in 0..10 -> return 91
        \\    if not (10 in 0..=10) -> return 92
        \\    if 5 in 5..5 -> return 93
        \\    if not (5 in 5..=5) -> return 94
        \\    if 5 in 10..0 -> return 95
        \\    if 5 in 10..=0 -> return 96
        \\    if not (-2147483648 in -2147483648..=2147483647) -> return 97
        \\    if not (2147483647 in -2147483648..=2147483647) -> return 98
        \\    var low = 19
        \\    var high = 23
        \\    if not (low in low..high) -> return 99
        \\    if const first: int = accepted(19)
        \\        if const second: int = accepted(23) -> return first + second
        \\    return 100
    , 42);
}

test "membership rejects omitted and end relative range bounds through ordinary failure" {
    try Fixture.expectParity(
        \\import std.range as ranges
        \\func run() int
        \\    if 5 in ..10 -> return 90
        \\    if 5 in 0.. -> return 91
        \\    if 5 in (..) -> return 92
        \\    if 5 in ^0..10 -> return 93
        \\    if 5 in 0..^1 -> return 94
        \\    if 5 in ^0..=^1 -> return 95
        \\    if 5 in ranges.inclusive(0, none) -> return 96
        \\    var bounds = 0..10
        \\    bounds.first = none
        \\    if 5 in bounds -> return 97
        \\    bounds.first = 0
        \\    if not (5 in bounds) -> return 98
        \\    return 42
    , 42);
}

test "custom membership borrows noncopyable immovable operands" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    value: int
        \\struct Choices
        \\    copy = none
        \\    move = none
        \\    value: int
        \\    pub func contains(imm self: Choices, imm item: Item) bool
        \\        if not (self.value == item.value) -> return false
        \\        return true
        \\func run() int
        \\    const item = Item{value = 19}
        \\    const choices = Choices{value = 19}
        \\    if item in choices -> return item.value + choices.value + 4
        \\    return 90
    , 42);
}

test "membership resolves generic and overloaded contains methods" {
    try Fixture.expectParity(
        \\struct Choice(T: type)
        \\    value: T
        \\    pub func contains(imm self: Choice(T), imm value: T) bool -> self.value == value
        \\struct Choices
        \\    func integer(imm self: Choices, imm value: int) bool -> value == 19
        \\    func boolean(imm self: Choices, imm value: bool) bool -> value
        \\    pub overload contains(integer, boolean)
        \\func run() int
        \\    const choices = Choices{}
        \\    if not (19 in choices) -> return 90
        \\    if not (true in choices) -> return 91
        \\    if false in choices -> return 92
        \\    if not (23 in Choice(int){value = 23}) -> return 93
        \\    return 42
    , 42);
    try Fixture.expectParity(
        \\struct Any
        \\    pub func contains(imm self: Any, static T: type, imm value: T) bool -> true
        \\func run() int
        \\    if 19 in Any{} and true in Any{} -> return 42
        \\    return 90
    , 42);
}

test "membership evaluates source operands once from left to right" {
    try Fixture.expectParity(
        \\struct Choices
        \\    trace: Ref(int)
        \\    pub func contains(imm self: Choices, imm value: int) bool
        \\        self.trace.value = self.trace.value * 10 + 3
        \\        if not (value == 19) -> return false
        \\        return true
        \\func produce_value(ref trace: int) int
        \\    trace = trace * 10 + 1
        \\    return 19
        \\func choices(ref trace: int) Choices
        \\    trace = trace * 10 + 2
        \\    return Choices{trace = (if const _selected_result_0: Ref(int) = Ref.from(trace) -> _selected_result_0 else panic "unexpected none")}
        \\func run() int
        \\    var trace = 0
        \\    if produce_value(trace) in choices(trace)
        \\        if trace == 123 -> return 42
        \\    return 90
    , 42);
}

test "membership prepares scalar reads and conversions before the collection" {
    try Fixture.expectParity(
        \\func change(ref value: int) int
        \\    value = 23
        \\    return 20
        \\struct Item
        \\    value: int
        \\struct Source
        \\    trace: Ref(int)
        \\converter(imm source: Source) Item
        \\    source.trace.value = source.trace.value * 10 + 1
        \\    return Item{value = 19}
        \\struct Choices
        \\    pub func contains(imm self: Choices, imm value: Item) bool -> value.value == 19
        \\func choices(ref trace: int) Choices
        \\    trace = trace * 10 + 2
        \\    return Choices{}
        \\func run() int
        \\    var number = 19
        \\    if not (number in 0..change(number)) -> return 90
        \\    if number <> 23 -> return 91
        \\    var trace = 0
        \\    const source = Source{trace = (if const _selected_result_0: Ref(int) = Ref.from(trace) -> _selected_result_0 else panic "unexpected none")}
        \\    if source in choices(trace)
        \\        if trace == 12 -> return 42
        \\    return 92
    , 42);
}

test "explicit optional selection short circuits membership and preserves cleanup" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 10
        \\struct Choices
        \\    pub func contains(imm self: Choices, imm item: Item) bool -> return false
        \\func missing(ref trace: int) Item | none
        \\    trace += 1
        \\    return none
        \\func choices(ref trace: int) Choices
        \\    trace += 100
        \\    return Choices{}
        \\func absent(ref trace: int) Choices | none
        \\    trace += 1
        \\    return none
        \\func checked_membership(ref trace: int) bool | none
        \\    const item = Item{trace = Ref.from(trace)}
        \\    const selected: Choices = absent(trace) else return none
        \\    return item in selected
        \\func run() int
        \\    var trace = 0
        \\    if const item: Item = missing(trace)
        \\        if item in choices(trace) -> return 90
        \\    if trace <> 1 -> return 91
        \\    if const result: bool = checked_membership(trace) -> return 92
        \\    if trace <> 12 -> return 93
        \\    if Item{trace = Ref.from(trace)} in Choices{} -> return 94
        \\    return trace + 20
    , 42);
}

test "membership composes with loops comprehensions and match guards" {
    try Fixture.expectParity(
        \\func run() int
        \\    var total = 0
        \\    for value in 0..10
        \\        if value in 2..5 -> total += value
        \\    const values = [value for value in 0..5 if value in 2..4]
        \\    const chosen = match total
        \\        value and value in 9..=9 -> 28
        \\        _ -> 90
        \\    if not (1 + 2 in 1..4 and not (4 in 1..4) or 99 in 0..1) -> return 91
        \\    if const first: int = values.get(0)
        \\        if const second: int = values.get(1) -> return total + first + second + chosen
        \\    return 92
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\match 19
        \\    value and value in 0..100 -> 42
    , .match_not_exhaustive);
}

test "membership in a match condition protects the subject through contains effects" {
    try Fixture.expectSourceDiagnostic(
        \\struct Choices
        \\    target: Ref(int)
        \\    pub func contains(imm self: Choices, imm item: int) bool
        \\        self.target.value += 1
        \\        if not (item == 19) -> return false
        \\        return true
        \\var subject = 19
        \\const choices = Choices{target = Ref.from(subject)}
        \\match subject
        \\    value and value in choices -> value
        \\    _ -> 0
    , .match_guard_invalidates_subject);
}

test "membership validates the selected contains contract" {
    for ([_][]const u8{
        "pub func contains(imm self: Choices, imm value: int) int -> value",
        "pub func contains(imm self: Choices, imm value: int) unit | none -> none",
        "pub func contains(mut self: Choices, imm value: int) bool -> true",
        "pub func contains(imm self: Choices, var value: int) bool -> true",
    }) |method| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "struct Choices\n    {s}\nif 19 in Choices{{}} -> exit(42)", .{method});
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .invalid_membership_signature);
    }
    try Fixture.expectSourceDiagnostic("if 19 in 0..10 -> exit(42)\nif true in 0..10 -> exit(0)", .call_argument_type_mismatch);
    try Fixture.expectSourceDiagnostic("struct Choices\nif 19 in Choices{} -> exit(42)", .unknown_namespace_member);
}

test "membership edits recompute dispatch bounds and contains signatures" {
    const source =
        \\struct Choices
        \\    pub func contains(imm self: Choices, imm value: int) bool -> value in 19..=23
        \\if 23 in Choices{} -> exit(42)
        \\else exit(19)
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.expectExit(0, 42);
    const exclusive = try std.mem.replaceOwned(u8, std.testing.allocator, source, "19..=23", "19..23");
    defer std.testing.allocator.free(exclusive);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, exclusive);
    try fixture.expectExit(0, 19);
    const invalid = try std.mem.replaceOwned(u8, std.testing.allocator, source, "imm value: int", "var value: int");
    defer std.testing.allocator.free(invalid);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, invalid);
    try fixture.expectDiagnostic(0, .invalid_membership_signature);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}
