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

test "flow reads and aliases select the same logical payload across owned and reference storage" {
    try Fixture.expectParity(
        \\func borrow(ref value: int) ref int | none -> value
        \\func choose(ref value: int, borrowed: bool) int | ref int | none
        \\    if borrowed -> return borrow(value)
        \\    return 19
        \\func update(ref value: int, borrowed: bool) int
        \\    var carrier = choose(value, borrowed)
        \\    if carrier is int
        \\        ref payload = carrier
        \\        payload += 23
        \\        return carrier
        \\    return 90
        \\func run() int
        \\    var value = 19
        \\    if update(value, false) <> 42 -> return 91
        \\    if value <> 19 -> return 92
        \\    if update(value, true) <> 42 -> return 93
        \\    return value
    , 42);
}

test "flow proof dependencies survive joins before a loop read" {
    try Fixture.expectSourceDiagnostic(
        \\func probe(flag: bool) int
        \\    var value: int | bool | none = 42
        \\    if not (value is int | bool) -> return 90
        \\    loop
        \\        if flag and value is int -> print(value)
        \\        const selected: int | bool = value
        \\        value = none
        \\        if flag -> break
        \\    return 42
        \\exit(probe(false))
    , .loop_invalidates_type_proof);
}

test "nested variant proofs retain the enclosing owners exact cleanup obligations" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\struct Owner
        \\    copy = none
        \\    token: Token | none
        \\    value: int
        \\func produce(present: bool) Owner
        \\    return Owner{token = if present -> Token{} else none, value = 19}
        \\func dispose(deinit token: Token) -> ()
        \\func choose(present: bool) int
        \\    var owner = produce(present)
        \\    if owner.token is none
        \\        owner.value += 23
        \\        return owner.value
        \\    const payload = owner.token^
        \\    match payload^
        \\        token and token is Token -> dispose(token)
        \\        _ -> ()
        \\    return 90
        \\func run() int -> choose(false)
    , 42);
}

test "saved bool copies survive joins and rebinding receives fresh proof versions" {
    try Fixture.expectParity(
        \\func select(value: int | none, flag: bool) int
        \\    const tested = value is int
        \\    var saved = tested
        \\    if flag -> saved = tested else saved = tested
        \\    if saved -> return value
        \\    return 0
        \\func run() int -> select(19, true) + select(23, false) + select(none, true)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func run() int
        \\    var value: int | none = 19
        \\    const tested = value is int
        \\    value = none
        \\    value = 23
        \\    if tested -> return value + 1
        \\    return 0
        \\exit(run())
    , .missing_operation);
}

test "callee writes invalidate the selected carrier and preserve sibling proofs" {
    try Fixture.expectParity(
        \\struct Pair
        \\    first: int | none
        \\    second: int | none
        \\func clear(mut value: int | none) -> value = none
        \\func run() int
        \\    var pair = Pair{first = 42, second = 90}
        \\    if pair.first is int
        \\        clear(pair.second)
        \\        return pair.first
        \\    return 1
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func clear(mut value: int | none) -> value = none
        \\func run() int
        \\    var value: int | none = 42
        \\    if value is int
        \\        clear(value)
        \\        return value + 1
        \\    return 0
        \\exit(run())
    , .missing_operation);
}

test "lost proof diagnostics identify the guard and the invalidating write" {
    const source =
        \\var value: int | none = 19
        \\if value is int
        \\    value = none
        \\    exit(value + 1)
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .missing_operation);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(test_sources.queries.BuildExecutable, 0, test_sources.structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    const notes = diagnostics[0].notes;
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqual(.type_proof, notes[0].kind);
    try std.testing.expectEqualStrings("value", source[notes[0].span.start..notes[0].span.end]);
    try std.testing.expectEqual(.proof_invalidated, notes[1].kind);
    try std.testing.expectEqualStrings("=", source[notes[1].span.start..notes[1].span.end]);
}

test "guard and callee effect edits recompute flow facts in an existing database" {
    const source =
        \\func update(mut value: int | none) -> ()
        \\func run() int
        \\    var value: int | none = 42
        \\    if value is int
        \\        update(value)
        \\        return value
        \\    return 0
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "-> ()", "-> value = none");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(0, .return_type_mismatch);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
    const guarded = try std.mem.replaceOwned(u8, std.testing.allocator, source, "value is int", "value is none");
    defer std.testing.allocator.free(guarded);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, guarded);
    try fixture.expectDiagnostic(0, .return_type_mismatch);
}

test "owned fields transfer through narrowed variant parents and retain sibling cleanup" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\struct Tracked
        \\    copy = none
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Tracked) -> self.drops.value += 1
        \\struct Pair
        \\    copy = none
        \\    token: Token
        \\    tracked: Tracked
        \\func produce(ref drops: int) Pair | none -> Pair{token = Token{}, tracked = Tracked{drops = Ref.from(drops)}}
        \\func dispose(deinit token: Token) -> ()
        \\func select(ref drops: int, explicit: bool) int
        \\    var owner = produce(drops)
        \\    if not (owner is Pair) -> return 90
        \\    if explicit
        \\        const token = owner.token^
        \\        dispose(token)
        \\    else
        \\        dispose(owner.token)
        \\    return 20
        \\func run() int
        \\    var drops = 0
        \\    const value = select(drops, true) + select(drops, false)
        \\    return value + drops
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\struct Pair
        \\    token: Token
        \\func dispose(deinit token: Token) -> ()
        \\var source: Pair | none = none
        \\ref alias = source
        \\if alias is Pair -> dispose(alias.token)
    , .ownership_transfer_requires_owned_place);
}

test "a bound reference retains its own proof through an unknown element index" {
    try Fixture.expectParity(
        \\func select(index: int) int
        \\    var items: Array(int | none, 2) = [19, none]
        \\    ref selected = items[index]
        \\    if selected is int
        \\        ref alias = selected
        \\        alias += 23
        \\        return selected
        \\    return 0
        \\func run() int -> select(0) + select(1)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func select(index: int) int
        \\    var items: Array(int | none, 2) = [19, none]
        \\    if items[index] is int -> return items[index] + 1
        \\    return 0
        \\exit(select(0))
    , .missing_operation);
}

test "successive guarded loops preserve shared binding identity ancestors" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("func run() int\n  var total = 0\n");
    for (0..24) |index| try source.writer.print("  var v{d}: int | none = {d}\n", .{ index, index });
    for (0..24) |index| try source.writer.print(
        "  const selected{d} = v{d} is int\n  if selected{d}\n    ref alias{d} = v{d}\n    loop\n      alias{d} += 1\n      break\n    total += v{d}\n",
        .{ index, index, index, index, index, index, index },
    );
    try source.writer.writeAll("  return total - 258\n");
    try Fixture.expectParity(source.written(), 42);
}

test "successive guarded loops preserve proofs and references across real backedges" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("func run() int\n  var total = 0\n");
    for (0..24) |index| try source.writer.print("  var v{d}: int | none = {d}\n", .{ index, index });
    for (0..24) |index| try source.writer.print(
        "  const selected{d} = v{d} is int\n  if selected{d}\n    ref alias{d} = v{d}\n    loop\n      alias{d} += 1\n      if alias{d} >= {d} -> break\n    total += v{d}\n",
        .{ index, index, index, index, index, index, index, index + 2, index },
    );
    try source.writer.writeAll("  return total - 282\n");
    try Fixture.expectParity(source.written(), 42);
}

test "single pass loops retain writes that invalidate an incoming proof" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int
        \\    var value: int | none = 42
        \\    if value is int
        \\        loop
        \\            value = none
        \\            break
        \\        return value + 1
        \\    return 0
        \\exit(run())
    , .missing_operation);
}
