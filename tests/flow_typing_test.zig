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

test "calculus correspondence keeps saved tests bound to their original place" {
    try Fixture.expectParity(
        \\struct Pair
        \\    first: int | none
        \\    second: int | none
        \\func choose(value: int | none) int
        \\    var pair = Pair{first = value, second = none}
        \\    var selected = Ref.from(pair.first)
        \\    const tested = selected.value is int
        \\    selected = Ref.from(pair.second)
        \\    selected.value = none
        \\    if tested -> return pair.first
        \\    return 0
        \\func run() int -> choose(42) + choose(none)
    , 42);
}

test "calculus correspondence preserves copied negated tests through sibling writes" {
    try Fixture.expectParity(
        \\struct Pair
        \\    first: int | none
        \\    second: int | none
        \\func choose(value: int | none) int
        \\    var pair = Pair{first = value, second = none}
        \\    ref selected = pair.first
        \\    ref chained = selected
        \\    ref sibling = pair.second
        \\    const tested = chained is int
        \\    const copied = tested
        \\    sibling = none
        \\    if not copied
        \\        const absent: none = chained
        \\        return 0
        \\    return chained
        \\func run() int -> choose(42) + choose(none)
    , 42);
}

test "calculus correspondence checks declared writes and fresh tests" {
    try Fixture.expectParity(
        \\func replace(value: int | none) int
        \\    var subject = value
        \\    if subject is int
        \\        subject = none
        \\        if subject is none -> return 21
        \\        return 90
        \\    const absent: none = subject
        \\    return 0
        \\func retest(value: int | none) int
        \\    var subject = value
        \\    subject = none
        \\    if subject is int -> return subject
        \\    const absent: none = subject
        \\    return 42
        \\func resave(value: int | none) int
        \\    var subject = value
        \\    var tested = subject is int
        \\    subject = none
        \\    tested = false
        \\    if tested -> return 90
        \\    if subject is none -> return 21
        \\    return 91
        \\func run() int
        \\    if replace(42) <> 21 -> return 90
        \\    if replace(none) <> 0 -> return 91
        \\    if resave(42) <> 21 -> return 92
        \\    if resave(none) <> 21 -> return 93
        \\    if retest(none) <> 42 -> return 90
        \\    return retest(19)
    , 42);
}

test "calculus correspondence rejects copied evidence after alias writes and joins" {
    for ([_][]const u8{
        \\func choose(var value: int | none) int
        \\    ref selected = value
        \\    const tested = value is int
        \\    const copied = tested
        \\    selected = none
        \\    if copied -> return value + 1
        \\    return 0
        \\exit(choose(41))
        ,
        \\func choose(var value: int | none, flag: bool) int
        \\    ref selected = value
        \\    const tested = value is int
        \\    if flag -> selected = none
        \\    if tested -> return value + 1
        \\    return 0
        \\exit(choose(41, true))
        ,
        \\func choose(value: int | none) int -> value + 1
        \\exit(choose(41))
        ,
    }) |source| {
        try Fixture.expectSourceDiagnostic(source, .missing_operation);
    }
}

test "calculus correspondence rejects writes outside the declared variant" {
    try Fixture.expectSourceDiagnostic(
        \\var value: int | none = 42
        \\value = true
    , .assignment_type_mismatch);
}

test "calculus correspondence narrows post-write source reads" {
    for ([_][]const u8{
        \\func choose(value: int | none) none
        \\    var subject = value
        \\    if subject is int
        \\        subject = none
        \\        return subject
        \\    return subject
        \\func run() int
        \\    _ = choose(42)
        \\    _ = choose(none)
        \\    return 42
        ,
        \\func choose(value: int | none) none
        \\    var subject = value
        \\    var tested = subject is int
        \\    subject = none
        \\    tested = false
        \\    if tested -> return none
        \\    return subject
        \\func run() int
        \\    _ = choose(42)
        \\    _ = choose(none)
        \\    return 42
        ,
        \\func choose(value: int | none) int
        \\    var subject = value
        \\    const tested = subject is int
        \\    subject = none
        \\    if tested
        \\        const absent: none = subject
        \\        return 42
        \\    return 0
        \\func run() int -> choose(42) + choose(none)
        ,
    }) |source| {
        try Fixture.expectParity(source, 42);
    }
}

test "assignment narrowing follows locals fields aliases and handles" {
    try Fixture.expectParity(
        \\struct Pair
        \\    first: int | none
        \\    second: int | none
        \\func run() int
        \\    var value: int | none = none
        \\    ref selected = value
        \\    selected = 19
        \\    var pair = Pair{first = none, second = 90}
        \\    pair.first = 23
        \\    const handle = Ref.from(pair.second)
        \\    handle.value = none
        \\    const absent: none = handle.value
        \\    return value + pair.first
    , 42);
}

test "assignment narrowing keeps selected handles separate from possible targets" {
    try Fixture.expectParity(
        \\func choose(flag: bool) int
        \\    var first: int | none = none
        \\    var second: int | none = none
        \\    const selected = if flag -> Ref.from(first) else Ref.from(second)
        \\    selected.value = 21
        \\    return selected.value
        \\func run() int -> choose(true) + choose(false)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func choose(flag: bool) int
        \\    var first: int | none = none
        \\    var second: int | none = none
        \\    const selected = if flag -> Ref.from(first) else Ref.from(second)
        \\    selected.value = 21
        \\    return first + second
        \\exit(choose(true))
    , .missing_operation);
}

test "assignment narrowing joins freshly written alternatives" {
    try Fixture.expectParity(
        \\func choose(flag: bool) int | none
        \\    var value: int | bool | none = false
        \\    if flag
        \\        value = 21
        \\    else
        \\        value = none
        \\    return value
        \\func run() int
        \\    const first = choose(true)
        \\    if not (first is int) -> return 90
        \\    const second = choose(false)
        \\    if not (second is none) -> return 91
        \\    return first * 2
    , 42);
}

test "assignment narrowing recomputes after source edits" {
    const source =
        \\func run() int
        \\    var value: int | none = none
        \\    value = 42
        \\    return value
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "value = 42", "value = none");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(0, .return_type_mismatch);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "calculus correspondence checks literal-unreachable source branches" {
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: int | none) int
        \\    if true
        \\        return 42
        \\    else
        \\        return value + 1
        \\exit(choose(none))
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
        \\func choose(replacement: int | none) int
        \\    var value: int | none = 19
        \\    const tested = value is int
        \\    value = none
        \\    value = replacement
        \\    if tested -> return value + 1
        \\    return 0
        \\exit(choose(none))
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
        \\func choose(replacement: int | none) int
        \\    var value: int | none = 19
        \\    if value is int
        \\        value = replacement
        \\        return value + 1
        \\    return 0
        \\exit(choose(none))
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
