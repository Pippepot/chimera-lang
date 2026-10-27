const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "bare type patterns select variants aliases and nested tuple alternatives" {
    try Fixture.expectParity(
        \\static Number = int
        \\static Scalar = int | bool
        \\struct Wrapped(T: type)
        \\    value: T
        \\func select(value: int | bool | none) int
        \\    return match value
        \\        Number and 1 > 2 -> 90
        \\        Number -> 19
        \\        Scalar -> 23
        \\        none -> 91
        \\func nested(value: (int | bool, int) | none) int
        \\    return match value
        \\        (Number, extra) -> extra
        \\        (bool, _) -> 91
        \\        _ -> 92
        \\func specialized(value: Wrapped(int) | none) int
        \\    return match value
        \\        Wrapped(int) -> nested((19, select(true)))
        \\        none -> 93
        \\func run() int -> select(1) + specialized(Wrapped(int){value = 0})
    , 42);
    try Fixture.expectParity(
        \\func select(static T: type, value: T | none) int
        \\    return match value
        \\        T -> 19
        \\        none -> 23
        \\func run() int -> select(int, 1) + select(bool, none)
    , 42);
}

test "bare type patterns resolve qualified names" {
    const fixture = try Fixture.initFiles(
        \\import kinds
        \\func choose(value: int | bool) int
        \\    return match value
        \\        kinds.Number -> 19
        \\        bool -> 23
        \\static first = choose(1)
        \\exit(first + choose(true))
    , &.{.{ .path = "kinds/types.chi", .module_path = "kinds", .source = "pub static Number = int" }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "bare type patterns accept callable and tuple union types" {
    try Fixture.expectParity(
        \\func number() int -> 42
        \\func callable(value: (func() int) | none) int
        \\    return match value
        \\        func() int -> 19
        \\        none -> 90
        \\func tuple(value: (int, bool) | none) int
        \\    return match value
        \\        (int, bool) | none -> 23
        \\func run() int -> callable(number) + tuple((1, true))
    , 42);
    try Fixture.expectParity(
        \\func choose(value: ((ref int, int), bool) | none) int
        \\    return match value
        \\        ((ref int, int), bool) | none -> 42
        \\func run() int
        \\    var value = 19
        \\    const pair: (ref int, int) = (value, 23)
        \\    return choose((pair, true))
    , 42);
}

test "match rejects leading is and match specific as captures" {
    try Fixture.expectSourceDiagnostic(
        \\const value: int | bool = 1
        \\match value
        \\    is int -> 19
        \\    bool -> 23
    , .invalid_expression);
    for ([_][]const u8{
        "int as name",
        "0 as name",
        "_ as name",
        "name as other",
        "ref name as other",
        "(left, right) as pair",
    }) |pattern| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "match 0\n    {s} -> 42", .{pattern});
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .expected_token);
    }
}

test "type patterns narrow reads of the original subject" {
    try Fixture.expectSourceExit(
        \\func consume(value: int) int -> value
        \\func choose(value: int | none) int
        \\    return match value
        \\        int -> consume(value)
        \\        none -> 0
        \\exit(choose(42))
    , 42);
}

test "incremental type aliases change match dispatch and capture resolution" {
    const fixture = try Fixture.init(
        \\static Kind = int
        \\func select(value: int | bool) int
        \\    return match value
        \\        Kind -> 19
        \\        _ -> 23
        \\exit(select(1))
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 19);
    try fixture.expectExit(0, 19);
    const changed =
        \\static Kind = bool
        \\func select(value: int | bool) int
        \\    return match value
        \\        Kind -> 19
        \\        _ -> 23
        \\exit(select(1))
    ;
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectExit(0, 23);
    const value_name = try std.mem.replaceOwned(u8, std.testing.allocator, changed, "Kind = bool", "Kind = 1");
    defer std.testing.allocator.free(value_name);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, value_name);
    try fixture.expectDiagnostic(0, .duplicate_local_binding);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectExit(0, 23);
}

test "initializer inference captures nested tuple patterns and outer guard inputs" {
    try Fixture.expectParity(
        \\func materialize(init value: int) int -> value
        \\func probe() int | none
        \\    var threshold = 20
        \\    var increment = 1
        \\    return materialize(match ((19,), 22)
        \\        ((0,), _) -> 90
        \\        ((left,), right) and left < threshold -> left + right + increment
        \\        _ -> 91)
        \\func run() int
        \\    match probe()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 92
    , 42);
}

test "tuple match literals captures and conditions select one arm" {
    try Fixture.expectParity(
        \\func choose(point: (int, int)) int
        \\    return match point
        \\        (0, 0) -> 10
        \\        (x, y) and x > y -> x + y
        \\        (x, y) -> y - x
        \\func run() int -> choose((0, 0)) + choose((19, 3)) + choose((1, 11))
    , 42);
}

test "tuple match grouping singleton ignores and nested patterns" {
    try Fixture.expectParity(
        \\func choose(point: ((int, int), (int,))) int
        \\    return match point
        \\        ((0, _), _) -> 90
        \\        (((x), y), (z,)) and x > y and z > 0 -> x + y + z
        \\        _ -> 91
        \\func run() int -> choose(((19, 3), (20,)))
    , 42);
}

test "tuple match func conditions preserve effects and evaluate the subject once" {
    try Fixture.expectParity(
        \\func produce(mut calls: int) (int, int)
        \\    calls += 1
        \\    return (19, 23)
        \\func allowed(imm x: int, imm y: int, mut calls: int) unit | none
        \\    calls += 10
        \\    if not (x > y) -> return none
        \\    return ()
        \\func run() int
        \\    var calls = 0
        \\    const result = match produce(calls)
        \\        (x, y) and (allowed(x, y, calls) is unit) -> 90
        \\        (x, y) -> x + y
        \\    if calls <> 11 -> return 91
        \\    return result
    , 42);
}

test "tuple match conditions inspect the actual custom copy" {
    try Fixture.expectParity(
        \\struct Item
        \\    copies: Ref(int)
        \\    value: int
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{copies = self.copies, value = self.value + 1}
        \\func run() int
        \\    var copies = 0
        \\    const pair = (Item{copies = Ref.from(copies), value = 40}, 1)
        \\    const result = match pair
        \\        (item, extra) and item.value == 0 -> 90
        \\        (item, extra) and item.value == 41 -> item.value + extra
        \\        _ -> 91
        \\    if copies <> 2 -> return 92
        \\    return result
    , 42);
}

test "tuple match retains fresh noncopyable immovable fields through rejection" {
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func consume(deinit value: Fixed) int -> value.value
        \\func produce() (Fixed, int) -> (Fixed{value = 19}, 23)
        \\func run() int
        \\    return match produce()
        \\        (item, extra) and item.value > extra -> 90
        \\        (item, extra) -> consume(item) + extra
    , 42);
}

test "tuple match explicit references alias and remain writable after selection" {
    try Fixture.expectParity(
        \\func run() int
        \\    var pair = (19, 23)
        \\    match pair
        \\        (ref x, ref y) and x < y -> x += y
        \\        _ -> ()
        \\    return pair.0
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Fixed
        \\    copy = none
        \\    value: int
        \\const pair = (Fixed{value = 42}, 0)
        \\match pair
        \\    (item, _) -> item.value
    , .type_not_copyable);
}

test "tuple match conditions cannot mutate or consume protected places" {
    try Fixture.expectSourceDiagnostic(
        \\func change(ref value: int) unit -> value += 1
        \\var pair = (19, 23)
        \\match pair
        \\    (ref x, _) and (change(x) is unit) -> ()
        \\    _ -> ()
    , .match_guard_invalidates_subject);
    try Fixture.expectSourceDiagnostic(
        \\func change(ref value: (int, int)) unit -> value.0 += 1
        \\var pair = (19, 23)
        \\match pair
        \\    (x, y) and (change(pair) is unit) -> x + y
        \\    _ -> 0
    , .match_guard_invalidates_subject);
    try Fixture.expectSourceDiagnostic(
        \\func consume(deinit value: int) unit -> ()
        \\match (19, 23)
        \\    (x, y) and (consume(x) is unit) -> y
        \\    _ -> 0
    , .match_guard_invalidates_subject);
}

test "tuple match requires a structural remainder and distinct local names" {
    try Fixture.expectSourceDiagnostic(
        \\match (19, 23)
        \\    const (x, y) -> x + y
    , .invalid_expression);
    try Fixture.expectSourceDiagnostic(
        \\match (19, 23)
        \\    (x, y) and x < y -> x + y
    , .match_not_exhaustive);
    try Fixture.expectSourceDiagnostic(
        \\match (19, 23)
        \\    (x, x) -> x
    , .duplicate_local_binding);
    try Fixture.expectSourceDiagnostic(
        \\const x = 19
        \\match (19, 23)
        \\    (x, y) -> x + y
    , .duplicate_local_binding);
}

test "false guards retry while selected bodies return their explicit results" {
    try Fixture.expectParity(
        \\func selected() int | none
        \\    return match (19, 23)
        \\        (x, y) and true -> return none
        \\        _ -> 90
        \\func run() int
        \\    match selected()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return match (19, 23)
        \\        (x, y) and false -> 91
        \\        (x, y) -> x + y
    , 42);
}

test "tuple match guards protect referents tested by earlier arms during cleanup" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    copy = trivial
        \\    target: Ref(int)
        \\    drop = func(deinit self: Item) -> self.target.value = 0
        \\func reject() unit | none -> return none
        \\func run() int
        \\    var number = 19
        \\    const pair: (ref int, Item) = (number, Item{target = Ref.from(number)})
        \\    return match pair
        \\        (0, _) -> 90
        \\        (_, item) and (reject() is unit) -> 91
        \\        (_, _) -> 42
        \\exit(run())
    , .match_guard_invalidates_subject);
}

test "tuple match incremental edits update bindings guards coverage and nested shapes" {
    const queries = test_sources.queries;
    const fixture = try Fixture.init(
        \\const answer = match (19, 23)
        \\    (x, y) and x < y -> x + y
        \\    _ -> 90
        \\exit(answer)
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0,
        \\const answer = match (19, 23)
        \\    (x, y) and x > y -> x + y
        \\    _ -> 23
        \\exit(answer)
    );
    try fixture.expectExit(0, 23);
    try fixture.db.setInput(queries.SourceText, 0,
        \\const answer = match (19, 23)
        \\    (x, y) and x > y -> x + y
        \\exit(answer)
    );
    try fixture.expectDiagnostic(0, .match_not_exhaustive);
    try fixture.db.setInput(queries.SourceText, 0,
        \\const answer = match ((19,), 23)
        \\    ((first,), second) and first < second -> first + second
        \\    _ -> 90
        \\exit(answer)
    );
    try fixture.expectExit(0, 42);
}

test "tuple match guarded fresh explicit drop captures commit only on selection" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\    value: int
        \\func dispose(deinit token: Token) int -> token.value
        \\func run() int
        \\    return match (Token{value = 19}, 23)
        \\        (token, extra) and token.value > extra -> dispose(token) + extra
        \\        (token, extra) -> dispose(token) + extra
    , 42);
}

test "tuple match guard derived references survive stable ownership commit" {
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Fixed) -> self.drops.value += 1
        \\func remember(imm item: Fixed, mut saved: Ref(Fixed) | none) unit
        \\    saved = Ref.from(item)
        \\func run() int
        \\    var drops = 0
        \\    var saved: Ref(Fixed) | none = none
        \\    const result = match (Fixed{value = 42, drops = Ref.from(drops)}, 0
        \\    )
        \\        (item, _) and (remember(item, saved) is unit) ->
        \\            match saved
        \\                Ref(Fixed) ->
        \\                    ref view = saved
        \\                    view.value.value
        \\                _ -> 90
        \\        _ -> 91
        \\    if drops <> 1 -> return 92
        \\    return result
    , 42);
}

test "tuple match variant alternatives preserve element types and separate SSA paths" {
    try Fixture.expectParity(
        \\func produce(flag: bool) (int, int) | (bool, int)
        \\    if flag
        \\        const pair: (int, int) = (19, 23)
        \\        return pair
        \\    const pair: (bool, int) = (false, 19)
        \\    return pair
        \\func choose(flag: bool) int
        \\    return match produce(flag)
        \\        (0, _) -> 90
        \\        (_, value) -> value
        \\func run() int -> choose(true) + choose(false)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func produce() (int, int) | (bool, int)
        \\    const pair: (int, int) = (19, 23)
        \\    return pair
        \\match produce()
        \\    (x, y) -> y
    , .match_tuple_capture_type_ambiguous);
}

test "tuple match nested variant products retain explicit remainder coverage" {
    try Fixture.expectParity(
        \\func produce() ((int, int) | (int,), int)
        \\    const pair: (int, int) = (19, 20)
        \\    return (pair, 3)
        \\func run() int
        \\    return match produce()
        \\        ((x, y), z) and x < y -> x + y + z
        \\        ((x,), z) -> x + z
        \\        _ -> 90
    , 42);
}

test "tuple match combines finite and nested type partitions exhaustively" {
    try Fixture.expectParity(
        \\func choose(value: (bool, int)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (false, number) -> number + 1
        \\func nested(value: ((int | bool, bool), int) | none) int
        \\    return match value
        \\        ((int, true), number) -> number
        \\        ((int, false), number) -> number + 1
        \\        ((bool, _), number) -> number + 2
        \\        none -> 3
        \\func run() int
        \\    return choose((true, 5)) + choose((false, 6)) + nested(((1, true), 7)) + nested(((1, false), 8)) + nested(((false, true), 9)) + nested(none)
    , 42);
    try Fixture.expectParity(
        \\func choose(value: (bool, int) | (bool,)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (false, number) -> number + 1
        \\        (true,) -> 10
        \\        (false,) -> 20
        \\func run() int
        \\    const first: (bool, int) = (true, 5)
        \\    const second: (bool, int) = (false, 6)
        \\    const third: (bool,) = (true,)
        \\    const fourth: (bool,) = (false,)
        \\    return choose(first) + choose(second) + choose(third) + choose(fourth)
    , 42);
}

test "tuple match finite partitions distinguish unit none and reference fields" {
    try Fixture.expectParity(
        \\func choose(value: (unit | none, bool)) int
        \\    return match value
        \\        ((), true) -> 5
        \\        ((), false) -> 7
        \\        (none, _) -> 15
        \\func run() int -> choose(((), true)) + choose(((), false)) + choose((none, true)) + choose((none, false))
    , 42);
    try Fixture.expectParity(
        \\func choose(value: (ref bool, int) | (bool, int)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (false, number) -> number + 1
        \\func run() int
        \\    var flag = true
        \\    const borrowed: (ref bool, int) = (flag, 19)
        \\    const owned: (bool, int) = (false, 22)
        \\    return choose(borrowed) + choose(owned)
    , 42);
}

test "tuple match preserves product correlations through overlapping arms" {
    try Fixture.expectParity(
        \\func choose(value: (bool, bool)) int
        \\    return match value
        \\        (true, _) -> 10
        \\        (_, true) -> 20
        \\        (false, false) -> 2
        \\func run() int -> choose((true, true)) + choose((true, false)) + choose((false, true)) + choose((false, false))
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: (bool, bool)) int
        \\    return match value
        \\        (true, true) -> 1
        \\        (false, false) -> 2
        \\exit(choose((true, true)))
    , .match_not_exhaustive);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: (int, int)) int
        \\    return match value
        \\        (0, _) -> 1
        \\        (_, 0) -> 2
        \\exit(choose((0, 0)))
    , .match_not_exhaustive);
}

test "tuple match rejects duplicate subsumed and collectively covered arms" {
    const patterns = [_][]const u8{
        "(true, _) -> 1\n        (true, _) -> 2",
        "(true, _) -> 1\n        (true, false) -> 2",
        "(true, _) -> 1\n        (_, true) -> 2\n        (true, true) -> 3",
        "(true, true) -> 1\n        (false, true) -> 2\n        (_, true) -> 3",
        "(true, _) -> 1\n        (false, _) -> 2\n        (bool, bool) -> 3",
        "(true, _) -> 1\n        (true, _) and false -> 2",
    };
    for (patterns) |arms| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "func choose(value: (bool, bool)) int\n    return match value\n        {s}\n        _ -> 4\nexit(choose((true, true)))",
            .{arms},
        );
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .match_redundant_arm);
    }
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: ((int, int), bool)) int
        \\    return match value
        \\        ((0, _), _) -> 1
        \\        ((0, 42), true) -> 2
        \\        _ -> 3
        \\exit(choose(((0, 42), true)))
    , .match_redundant_arm);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: (StaticString, int)) int
        \\    return match value
        \\        ("a\0b", _) -> 1
        \\        ("a\u{0}b", 42) -> 2
        \\        _ -> 3
        \\exit(choose(("a\0b", 42)))
    , .match_redundant_arm);
}

test "tuple match guards preserve uncovered products and retry effects" {
    try Fixture.expectParity(
        \\func reject(ref attempts: int) bool
        \\    attempts += 1
        \\    return false
        \\func choose(value: (bool, int), ref attempts: int) int
        \\    return match value
        \\        (true, number) and reject(attempts) -> 90
        \\        (true, number) -> number
        \\        (false, number) -> number + 1
        \\func run() int
        \\    var attempts = 0
        \\    const result = choose((true, 19), attempts) + choose((false, 21), attempts)
        \\    return result + attempts
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: (bool, int)) int
        \\    return match value
        \\        (true, number) and true -> number
        \\        (false, number) -> number
        \\exit(choose((true, 42)))
    , .match_not_exhaustive);
}

test "tuple match finite partitions preserve noncopyable ownership and references" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    move = none
        \\    drop = explicit
        \\    value: int
        \\func dispose(deinit token: Token) int -> token.value
        \\func choose(flag: bool) int
        \\    return match (flag, Token{value = 19})
        \\        (true, token) and false -> dispose(token)
        \\        (true, token) -> dispose(token)
        \\        (false, token) -> dispose(token) + 4
        \\func run() int -> choose(true) + choose(false)
    , 42);
    try Fixture.expectParity(
        \\func update(ref pair: (bool, int)) unit
        \\    match pair
        \\        (true, ref number) -> number += 19
        \\        (false, ref number) -> number += 23
        \\func run() int
        \\    var first = (true, 0)
        \\    var second = (false, 0)
        \\    update(first)
        \\    update(second)
        \\    return first.1 + second.1
    , 42);
}

test "tuple match byte partitions cover the complete finite domain" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("func choose(value: (byte, int)) int\n    return match value\n");
    for (0..256) |index| try source.writer.print("        ({d}, number) -> number + {d}\n", .{ index, if (index == 255) @as(usize, 19) else 0 });
    try source.writer.writeAll("func run() int\n    const last: byte = 255\n    return choose((last, 23))\n");
    try Fixture.expectParity(source.written(), 42);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source.written(), "        (255, number) -> number + 19\n", "");
    defer std.testing.allocator.free(missing);
    const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{missing});
    defer std.testing.allocator.free(rejected);
    try Fixture.expectSourceDiagnostic(rejected, .match_not_exhaustive);
}

test "tuple match incremental edits recompute product coverage" {
    const fixture = try Fixture.init(
        \\func choose(value: (bool, int)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (false, number) -> number + 1
        \\exit(choose((false, 41)))
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 0,
        \\func choose(value: (bool, int)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (false, number) and true -> number + 1
        \\exit(choose((false, 41)))
    );
    try fixture.expectDiagnostic(0, .match_not_exhaustive);
    try fixture.db.setInput(test_sources.queries.SourceText, 0,
        \\func choose(value: (bool, int)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (true, number) -> number + 1
        \\        _ -> 42
        \\exit(choose((false, 41)))
    );
    try fixture.expectDiagnostic(0, .match_redundant_arm);
    try fixture.db.setInput(test_sources.queries.SourceText, 0,
        \\func choose(value: (bool, int)) int
        \\    return match value
        \\        (true, number) -> number
        \\        (false, number) -> number + 1
        \\exit(choose((false, 41)))
    );
    try fixture.expectExit(0, 42);
}

test "range patterns compose recursively with tuple type and literal patterns" {
    try Fixture.expectParity(
        \\func choose(value: ((int | bool, int), bool)) int
        \\    return match value
        \\        ((0..10, number), false) -> number
        \\        ((10..=20, number), false) -> number + 1
        \\        ((bool, number), _) -> number + 2
        \\        _ -> 0
        \\func run() int
        \\    return choose(((0, 5), false)) + choose(((9, 6), false)) + choose(((10, 7), false)) + choose(((20, 8), false)) + choose(((true, 12), true)) + choose(((21, 99), false)) + choose(((-1, 99), false))
    , 42);
    try Fixture.expectParity(
        \\func choose(value: (int,)) int
        \\    return match value
        \\        ((0..10),) -> 19
        \\        _ -> 23
        \\func run() int -> choose((9,)) + choose((10,))
    , 42);
}

test "range patterns combine open partitions and full integer boundaries" {
    try Fixture.expectParity(
        \\func choose(value: int) int
        \\    return match value
        \\        ..0 -> 5
        \\        0 -> 7
        \\        1..2147483647 -> 10
        \\        2147483647.. -> 20
        \\func run() int -> choose(-2147483648) + choose(0) + choose(2147483646) + choose(2147483647)
    , 42);
    try Fixture.expectParity(
        \\func choose(value: (int, bool)) int
        \\    return match value
        \\        (..=0, true) -> 19
        \\        (1.., true) -> 23
        \\        (.., false) -> 0
        \\func run() int -> choose((-2147483648, true)) + choose((2147483647, true)) + choose((0, false))
    , 42);
    try Fixture.expectParity(
        \\func choose(value: int) int
        \\    return match value
        \\        -9223372036854775808..=9223372036854775807 -> 21
        \\func run() int -> choose(-2147483648) + choose(2147483647)
    , 42);
}

test "range patterns use byte domains and preserve integer preference" {
    try Fixture.expectParity(
        \\func choose(value: (byte, bool)) int
        \\    return match value
        \\        (0..128, true) -> 5
        \\        (128..256, true) -> 7
        \\        (..=255, false) -> 15
        \\func run() int
        \\    const low: byte = 0
        \\    const high: byte = 255
        \\    return choose((low, true)) + choose((high, true)) + choose((low, false)) + choose((high, false))
    , 42);
    try Fixture.expectParity(
        \\func choose(value: int | byte | bool) int
        \\    return match value
        \\        0..10 -> 19
        \\        int -> 0
        \\        byte -> 23
        \\        bool -> 0
        \\func run() int
        \\    const byte_value: byte = 5
        \\    return choose(5) + choose(byte_value)
    , 42);
}

test "range patterns evaluate static bounds and permit ordinary guards" {
    try Fixture.expectParity(
        \\static Low = -2
        \\func upper() int -> 10
        \\func choose(static limit: int, value: (int, int)) int
        \\    return match value
        \\        (Low + 2..upper(), number) and number > limit -> number
        \\        (0..10, number) -> number + 1
        \\        _ -> 0
        \\func run() int -> choose(10, (0, 19)) + choose(30, (9, 22))
    , 42);
    try Fixture.expectParity(
        \\static NoLimit = none
        \\func choose(value: int) int
        \\    return match value
        \\        NoLimit..0 -> 19
        \\        0..NoLimit -> 23
        \\func run() int -> choose(-2147483648) + choose(2147483647)
    , 42);
}

test "range patterns retain owners until selection and protect projected references" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    move = none
        \\    drop = explicit
        \\    value: int
        \\func dispose(deinit token: Token) int -> token.value
        \\func choose(number: int) int
        \\    return match (number, Token{value = 19})
        \\        (..5, token) -> dispose(token)
        \\        (5..10, token) and false -> dispose(token)
        \\        (5..10, token) -> dispose(token)
        \\        (10.., token) -> dispose(token) + 4
        \\func run() int -> choose(5) + choose(10)
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var pair = (5, 19)
        \\    match pair
        \\        (0..10, ref number) -> number += 23
        \\        _ -> ()
        \\    return pair.1
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func change(ref number: int) bool
        \\    number += 1
        \\    return false
        \\var number = 5
        \\const pair: (ref int, int) = (number, 0)
        \\match pair
        \\    (0..10, _) and change(number) -> ()
        \\    _ -> ()
    , .match_guard_invalidates_subject);
}

test "range coverage rejects gaps redundancy empty bounds and runtime captures" {
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: (int, bool)) int
        \\    return match value
        \\        (..0, _) -> 1
        \\        (1.., _) -> 2
        \\exit(choose((1, true)))
    , .match_not_exhaustive);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: (int, bool)) int
        \\    return match value
        \\        (..0, _) -> 1
        \\        (0..10, _) -> 2
        \\        (-5..5, true) -> 3
        \\        _ -> 4
        \\exit(choose((1, true)))
    , .match_redundant_arm);
    try Fixture.expectSourceDiagnostic(
        \\match (5, true)
        \\    (0..10, _) -> 1
        \\    (5, _) -> 2
        \\    _ -> 3
    , .match_redundant_arm);
    try Fixture.expectSourceDiagnostic(
        \\func choose(value: int) int
        \\    return match value
        \\        ..0 and true -> 1
        \\        0.. -> 2
        \\exit(choose(1))
    , .match_not_exhaustive);
    for ([_][]const u8{ "0..0", "10..=0", "..-9223372036854775808" }) |pattern| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "match 0\n    {s} -> 1\n    _ -> 2", .{pattern});
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .match_range_empty);
    }
    try Fixture.expectSourceDiagnostic(
        \\static Low = false
        \\match 5
        \\    Low..10 -> 1
        \\    _ -> 2
    , .match_range_bound_not_integer);
    try Fixture.expectSourceDiagnostic(
        \\const low = 0
        \\match 5
        \\    low..10 -> 1
        \\    _ -> 2
    , .comptime_runtime_capture);
    try Fixture.expectSourceDiagnostic(
        \\const value: byte = 0
        \\match value
        \\    256..300 -> 1
        \\    _ -> 2
    , .match_pattern_incompatible);
}

test "range pattern edits recompute nested coverage and static dependencies" {
    const fixture = try Fixture.initFiles(
        \\import bounds
        \\func choose(value: (int, bool)) int
        \\    return match value
        \\        (..bounds.Split, _) -> 19
        \\        (10.., _) -> 42
        \\exit(choose((10, true)))
    , &.{.{ .path = "bounds/limits.chi", .module_path = "bounds", .source = "pub static Split = 10" }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, "pub static Split = 9");
    try fixture.expectDiagnostic(0, .match_not_exhaustive);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, "pub static Split = 11");
    try fixture.expectExit(0, 19);
}

test "guarded match catch all copies retain feasible cleanup without changing their type" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = trivial
        \\    drop = explicit
        \\struct Item
        \\    copy = trivial
        \\    drops: Ref(int)
        \\    drop = func(deinit self: Item) -> self.drops.value += 1
        \\func dispose(deinit token: Token) unit -> ()
        \\func run() int
        \\    var drops = 0
        \\    const owner: Token | Item = Item{drops = Ref.from(drops)}
        \\    const answer = match owner
        \\        Token ->
        \\            match owner
        \\                Token ->
        \\                    const token = owner
        \\                    dispose(token)
        \\                _ -> ()
        \\            90
        \\        selected and selected is Item -> 42
        \\        selected -> 91
        \\    match owner^
        \\        token and token is Token -> dispose(token)
        \\        _ -> ()
        \\    if drops <> 2 -> return 92
        \\    return answer
    , 42);
}

test "match scalar literals captures and nested expressions" {
    try Fixture.expectParity(
        \\func choose(number: int) int
        \\    return match number
        \\        -1 -> 90
        \\        0 -> number + 19
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
        \\        int -> 42
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
        \\        int ->
        \\            match source
        \\                int ->
        \\                    ref item = source
        \\                    item += 23
        \\                _ -> ()
        \\        none -> ()
        \\    match source
        \\        int ->
        \\            const result = source
        \\            return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "match type arms permit partial overlap with ordinary payload extraction" {
    try Fixture.expectParity(
        \\func choose(value: bool) int | bool | none -> value
        \\func run() int
        \\    const subject: int | bool | none = choose(true)
        \\    return match subject
        \\        int -> 90
        \\        int | bool ->
        \\            match subject
        \\                bool ->
        \\                    const flag = subject
        \\                    if flag -> return 42
        \\                _ -> ()
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
        \\        byte -> 23
        \\        int -> 92
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

test "match preserves expected conversion and optional results" {
    try Fixture.expectParity(
        \\func reject() int | none -> return none
        \\func run() int
        \\    const result: int | none = match true
        \\        true -> reject()
        \\        false -> 90
        \\    return match result
        \\        none -> 42
        \\        int -> 91
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

test "match handles none subjects and selected none results without retry" {
    try Fixture.expectParity(
        \\func produce(mut calls: int) int | none
        \\    calls += 1
        \\    return none
        \\func select(mut calls: int) int | none
        \\    return match produce(calls)
        \\        none ->
        \\            calls += 100
        \\            none
        \\        int -> 91
        \\func run() int
        \\    var calls = 0
        \\    match select(calls)
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return calls - 59
    , 42);
    try Fixture.expectParity(
        \\func select(mut calls: int) int | none
        \\    return match 1
        \\        1 ->
        \\            calls += 1
        \\            return none
        \\        _ ->
        \\            calls += 100
        \\            90
        \\func run() int
        \\    var calls = 0
        \\    match select(calls)
        \\        result and result is int -> return result
        \\        _ -> ()
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
        \\        int -> 92
        \\        selected ->
        \\            match selected^
        \\                item and item is Item -> return consume(item^)
        \\                _ -> ()
        \\            return 93
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
        \\        int -> ()
        \\        Tracked ->
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
        \\    if token -> return Token{number = 19}
        \\    return Tracked{trace = Ref.from(trace)}
        \\func inspect(ref trace: int, token: bool) int
        \\    return match produce(trace, token)
        \\        none -> 90
        \\        Tracked -> 22
        \\        selected ->
        \\            match selected^
        \\                item and item is Token ->
        \\                    const result = item.number
        \\                    dispose(item)
        \\                    return result
        \\                _ -> ()
        \\            return 91
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

test "match fresh immovable whole captures hand off without relocation" {
    try Fixture.expectParity(
        \\struct Fixed
        \\    copy = none
        \\    move = none
        \\    value: int
        \\func produce() Fixed | none -> Fixed{value = 42}
        \\func consume(deinit item: Fixed | none) int
        \\    match item
        \\        Fixed ->
        \\            ref value = item
        \\            return value.value
        \\        _ -> ()
        \\    return 91
        \\func run() int
        \\    return match produce()
        \\        none -> 90
        \\        selected -> consume(selected)
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

test "match whole capture permits ordinary subset extraction" {
    try Fixture.expectParity(
        \\struct Wide
        \\    ref value: int
        \\func produce() Wide | int | bool -> 42
        \\func run() int
        \\    return match produce()
        \\        Wide -> 90
        \\        selected ->
        \\            match selected^
        \\                subset and subset is int | bool ->
        \\                    match subset
        \\                        int ->
        \\                            const number = subset
        \\                            return number
        \\                        _ -> ()
        \\                _ -> ()
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
        \\        none -> 90
        \\        ref selected ->
        \\            match selected
        \\                Item ->
        \\                    ref item = selected
        \\                    return item.value
        \\                _ -> ()
        \\            return 91
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\const owner: Item | none = Item{value = 42}
        \\const result = match owner
        \\    none -> 90
        \\    selected -> 91
    , .type_not_copyable);
    try Fixture.expectSourceDiagnostic(
        \\const owner: int | none = 41
        \\match owner
        \\    none -> ()
        \\    ref selected ->
        \\        match selected
        \\            int ->
        \\                ref number = selected
        \\                number += 1
        \\            _ -> ()
    , .reference_not_writable);
}

test "match reference alternatives preserve authority and may outlive their carrier" {
    try Fixture.expectParity(
        \\func capture(ref owner: int) ref int | none -> owner
        \\func select(ref owner: int) ref int
        \\    return match capture(owner)
        \\        none -> owner
        \\        ref selected ->
        \\            match selected
        \\                int ->
        \\                    ref number = selected
        \\                    return number
        \\                _ -> ()
        \\            return owner
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
        \\        none -> 90
        \\        selected ->
        \\            match selected
        \\                int ->
        \\                    const number = selected
        \\                    owner = 23
        \\                    number
        \\                _ -> 91
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
        \\    if borrowed -> return capture(owner)
        \\    return 19
        \\func update(ref owner: int, borrowed: bool) int
        \\    return match choose(owner, borrowed)
        \\        End -> 90
        \\        ref selected ->
        \\            match selected
        \\                int ->
        \\                    ref number = selected
        \\                    number += 23
        \\                    return number
        \\                _ -> ()
        \\            return 91
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
        \\        selected ->
        \\            match selected^
        \\                item and item is Tracked -> return item.value
        \\                _ -> ()
        \\            return 91
        \\func run() int
        \\    var trace = 0
        \\    const result = choose(trace)
        \\    return result + trace
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func reject(ref trace: int) int | none
        \\    return match produce(trace)
        \\        none -> 90
        \\        Tracked -> return none
        \\func run() int
        \\    var trace = 0
        \\    match reject(trace)
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return trace + 41
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var trace = 0
        \\    for index in 0..3
        \\        match produce(trace)
        \\            none -> ()
        \\            Tracked ->
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
        \\        int -> 1
        \\        bool -> 2
        \\        int | bool -> 3
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
        \\    bool -> 2
        \\    _ -> 3
    , .match_pattern_incompatible);
    try Fixture.expectSourceDiagnostic(
        \\const value = match 1
        \\    x as y -> x + y
    , .expected_token);
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
        \\    int -> ()
        \\const invalid = owner
    , .use_after_transfer);
}

test "match whole owning captures retain only feasible drop obligations" {
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
        \\        none -> 90
        \\        selected ->
        \\            const retained = selected^
        \\            match retained^
        \\                token and token is Token ->
        \\                    dispose(token)
        \\                    return 91
        \\                _ -> ()
        \\            41
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
        \\        selected ->
        \\            const retained = selected^
        \\            match retained^
        \\                token and token is Token ->
        \\                    dispose(token)
        \\                    return 90
        \\                _ -> ()
        \\            42
    , 42);
}

test "match rejects borrowed subset layouts and ambiguous text domains" {
    try Fixture.expectSourceDiagnostic(
        \\struct Wide
        \\    ref value: int
        \\var owner: Wide | int | bool = 42
        \\match owner
        \\    Wide -> ()
        \\    ref selected ->
        \\        match selected
        \\            int | bool ->
        \\                ref subset = selected
        \\                exit(0)
        \\            _ -> ()
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
        \\    pub func ==(imm left: Wrapped, imm right: Wrapped) bool -> ()
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
        \\        1 -> int(number) + 18
        \\        selected -> int(selected) + 21
        \\func run() int -> choose(1) + choose(2)
    , 42);
}
