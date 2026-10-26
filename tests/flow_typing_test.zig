const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "flow types follow branches short circuit tests and exiting negative paths" {
    try Fixture.expectParity(
        \\func choose(value: int | none) int
        \\    if value is int and value > 0 -> return value
        \\    return 0
        \\func checked(value: int | none) int
        \\    if not (value is int) -> return 0
        \\    const selected = value
        \\    return selected
        \\func run() int -> choose(19) + choose(none) + checked(23) + checked(none)
    , 42);
}

test "flow types project tuple fields without changing their containing layout" {
    try Fixture.expectParity(
        \\func choose(value: (int | none, int)) int
        \\    if value.0 is int -> return value.0 + value.1
        \\    return 0
        \\func run() int -> choose((19, 23)) + choose((none, 90))
    , 42);
}

test "flow types preserve declared assignment types and invalidate written places" {
    try Fixture.expectSourceDiagnostic(
        \\var value: int | none = 19
        \\if value is int
        \\    value = none
        \\    exit(value + 1)
    , .missing_operation);
}

test "match flow facts refine named subjects nested fields and remaining captures" {
    try Fixture.expectParity(
        \\func choose(value: int | none) int
        \\    return match value
        \\        int -> value
        \\        none -> 0
        \\func remaining(value: int | none) int
        \\    return match value
        \\        none -> 0
        \\        number -> number
        \\func nested(pair: ((int | none, int), bool)) int
        \\    return match pair
        \\        ((int, number), true) -> pair.0.0 + number
        \\        _ -> 0
        \\func run() int -> choose(7) + remaining(12) + nested(((19, 4), true))
    , 42);
}

test "saved boolean proofs track the version they tested" {
    try Fixture.expectParity(
        \\func choose(value: int | none) int
        \\    const number = value is int
        \\    if number -> return value
        \\    return 0
        \\func run() int -> choose(42) + choose(none)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\var value: int | none = 19
        \\const number = value is int
        \\value = none
        \\if number -> exit(value + 1)
    , .missing_operation);
}

test "loop backedges cannot reuse a proof from an earlier iteration" {
    try Fixture.expectSourceDiagnostic(
        \\var value: int | none = 19
        \\if value is int
        \\    loop
        \\        const number = value + 1
        \\        value = none
        \\        if number > 20 -> break
    , .loop_invalidates_type_proof);
}

test "narrowed payloads retain their place for reference bindings and field writes" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = trivial
        \\    value: int
        \\func run() int
        \\    var source: Item | none = Item{value = 19}
        \\    if source is Item
        \\        ref selected = source
        \\        selected.value += 23
        \\        return source.value
        \\    return 90
    , 42);
}

test "a narrowed owner can be handed off without acquiring ownership through a reference" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    drop = explicit
        \\    value: int
        \\func consume(deinit item: Item) int -> item.value
        \\func produce() Item | none -> Item{value = 42}
        \\func run() int
        \\    const source = produce()
        \\    if source is Item -> return consume(source^)
        \\    return 90
    , 42);
}

test "conversions preserve the original parameter across differently narrowed branches" {
    try Fixture.expectParity(
        \\struct Wrapped
        \\    value: int
        \\    drop = func(deinit self: Wrapped) -> ()
        \\converter(imm value: int) Wrapped -> Wrapped{value = value}
        \\func choose(value: int | bool | none) int
        \\    if value is int -> return Wrapped(value).value
        \\    if value is bool -> return 23
        \\    return 0
        \\func run() int -> choose(19) + choose(true) + choose(none)
    , 42);
}

test "loop invariants survive payload writes and explicit tests can reestablish them" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = trivial
        \\    value: int
        \\func bump(mut item: Item) -> item.value += 1
        \\func run() int
        \\    var source: Item | none = Item{value = 39}
        \\    if not (source is Item) -> return 90
        \\    loop
        \\        bump(source)
        \\        if source.value == 42 -> break
        \\    return source.value
    , 42);
}
