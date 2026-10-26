const std = @import("std");
const test_sources = @import("test_sources");
const cache = test_sources.cache;
const modules = test_sources.modules;
const query = test_sources.query;
const queries = test_sources.queries;
const query_disk_cache = test_sources.query_disk_cache;
const structures = test_sources.structures;
const standard_library = @import("standard_library");

test "membership snapshots recompute bounds contains bodies and signatures" {
    const declarations =
        \\struct Choices
        \\    pub func contains(imm self: Choices, imm value: int) bool -> value in 19..=23
        \\func run() int
        \\    const choices = Choices{}
        \\    return match 23
        \\        value and value in choices -> 42
        \\        _ -> 19
    ;
    for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)" }) |entry| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ declarations, entry });
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "19..=23", "19..23");
        defer std.testing.allocator.free(changed);
        try fixture.db.setInput(queries.SourceText, 0, changed);
        try fixture.expectExit(19);
        const invalid = try std.mem.replaceOwned(u8, std.testing.allocator, source, "imm value: int", "var value: int");
        defer std.testing.allocator.free(invalid);
        try fixture.db.setInput(queries.SourceText, 0, invalid);
        try fixture.expectDiagnostic(.invalid_membership_signature);
        try fixture.db.setInput(queries.SourceText, 0, source);
        try fixture.expectExit(42);
    }
}

test "match snapshots recompute coverage captures and ownership capabilities" {
    const source =
        \\struct Item
        \\    copy = trivial
        \\    value: int
        \\func run() int
        \\    const owner: Item | none = Item{value = 42}
        \\    return match owner
        \\        none -> 90
        \\        Item ->
        \\            match owner
        \\                Item ->
        \\                    const selected = owner
        \\                    return selected.value
        \\                _ -> ()
        \\            return 91
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source, "        none -> 90\n", "");
    defer std.testing.allocator.free(missing);
    try fixture.db.setInput(queries.SourceText, 0, missing);
    try fixture.expectDiagnostic(.match_not_exhaustive);
    const redundant = try std.mem.replaceOwned(u8, std.testing.allocator, source, "        none -> 90\n", "        none -> 90\n        none -> 91\n");
    defer std.testing.allocator.free(redundant);
    try fixture.db.setInput(queries.SourceText, 0, redundant);
    try fixture.expectDiagnostic(.match_redundant_arm);
    const copyless = try std.mem.replaceOwned(u8, std.testing.allocator, source, "copy = trivial", "copy = none");
    defer std.testing.allocator.free(copyless);
    try fixture.db.setInput(queries.SourceText, 0, copyless);
    try fixture.expectDiagnostic(.type_not_copyable);
    const borrowed = try std.mem.replaceOwned(u8, std.testing.allocator, copyless, "const selected = owner", "ref selected = owner");
    defer std.testing.allocator.free(borrowed);
    try fixture.db.setInput(queries.SourceText, 0, borrowed);
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "match snapshots preserve cleanup and reference-valued result joins" {
    const declarations =
        \\struct Tracked
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Tracked) -> self.trace.value += 1
        \\func produce(ref trace: int) Tracked | none -> Tracked{trace = ((match Ref.from(trace)
        \\    _selected_result_0 and _selected_result_0 is Ref(int) -> _selected_result_0
        \\    _ -> panic "unexpected none"))}
        \\func select(ref owner: int, flag: bool) ref int
        \\    return match flag
        \\        true -> owner
        \\        false -> owner
        \\func run() int
        \\    var trace = 0
        \\    const result = match produce(trace)
        \\        none -> 90
        \\        Tracked -> 41
        \\    ref selected = select(trace, true)
        \\    selected += result
        \\    return trace
    ;
    for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)" }) |entry| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ declarations, entry });
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.trace.value += 1", "self.trace.value += 2");
        defer std.testing.allocator.free(changed);
        try fixture.db.setInput(queries.SourceText, 0, changed);
        try fixture.expectExit(43);
        try fixture.db.setInput(queries.SourceText, 0, source);
        try fixture.expectExit(42);
    }
}

test "List mutation snapshots preserve conservative captures and recompute removal edits" {
    const declarations =
        \\func remove(mut values: List(Ref(int)), index: int) Ref(int) | none -> values.remove(index)
        \\func calculate() int | none
        \\    var source = 21
        \\    var values: List(Ref(int)) = [Ref.from(source), Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        values[0] = Ref.from(source)
        \\        const removed = remove(values, 0)
        \\        if not (removed is Ref(int)) -> return none
        \\        if removed.value <> source -> return 90
        \\    return values[0].value * 2
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 91
    ;
    for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)" }) |entry| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ declarations, entry });
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const retained = try std.mem.replaceOwned(u8, std.testing.allocator, source, "values[0] = Ref.from(source)", "values[0] = Ref.from(temporary)");
        defer std.testing.allocator.free(retained);
        try fixture.db.setInput(queries.SourceText, 0, retained);
        try fixture.expectDiagnostic(.borrow_outlives_source);
        const wrong = try std.mem.replaceOwned(u8, std.testing.allocator, retained, "remove(values, 0)", "remove(values, 1)");
        defer std.testing.allocator.free(wrong);
        try fixture.db.setInput(queries.SourceText, 0, wrong);
        try fixture.expectDiagnostic(.borrow_outlives_source);
        try fixture.db.setInput(queries.SourceText, 0, source);
        try fixture.expectExit(42);
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var source = 21", "var source = 22");
        defer std.testing.allocator.free(changed);
        try fixture.db.setInput(queries.SourceText, 0, changed);
        try fixture.expectExit(44);
    }
}

test "List consuming snapshots track transfer intent and factory declarations" {
    const source =
        \\struct Item
        \\    copy = none
        \\    value: int
        \\func consume(deinit item: Item) int -> item.value
        \\func run() int
        \\    const values: List(Item) = [Item{value = 20}, Item{value = 22}]
        \\    var total = 0
        \\    for item in values^ -> total += consume(item^)
        \\    return total
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const borrowed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "in values^", "in values");
    defer std.testing.allocator.free(borrowed);
    try fixture.db.setInput(queries.SourceText, 0, borrowed);
    try fixture.expectDiagnostic(.ownership_transfer_requires_owned_place);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
    const allocation_file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.memory_allocation))).*;
    const allocation_source = standard_library.source("memory/allocation.chi");
    const renamed = try std.mem.replaceOwned(u8, std.testing.allocator, allocation_source, "pub func consume_iter", "pub func owning_iter");
    defer std.testing.allocator.free(renamed);
    try fixture.db.setInput(queries.SourceText, allocation_file, renamed);
    try fixture.expectDiagnostic(.ownership_transfer_requires_owned_place);
    try fixture.db.setInput(queries.SourceText, allocation_file, allocation_source);
    try fixture.expectExit(42);
}

test "collection snapshots retain static callback environments and recompute selections" {
    const source =
        \\func calculate() int | none
        \\    const callbacks: Array(func() int, 2) = [(struct
        \\        pub func amount() int -> i + 19
        \\    ).amount static for i in 0..4 static if i % 2 == 1]
        \\    return callbacks[0]() + callbacks[1]()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const selected = try std.mem.replaceOwned(u8, std.testing.allocator, source, "i % 2 == 1", "i % 2 == 0");
    defer std.testing.allocator.free(selected);
    try fixture.db.setInput(queries.SourceText, 0, selected);
    try fixture.expectExit(40);
    const bounds = try std.mem.replaceOwned(u8, std.testing.allocator, source, "0..4", "2..6");
    defer std.testing.allocator.free(bounds);
    try fixture.db.setInput(queries.SourceText, 0, bounds);
    try fixture.expectExit(46);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "top-level variant snapshots recompute outcomes and explicit handlers" {
    const source =
        \\func run() -> ()
        \\func check() unit | none -> if 1 < 2 -> () else none
        \\match check()
        \\    filtered_value_28 and filtered_value_28 is unit -> ()
        \\    _ -> exit(1)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(0);
    const rejected = try std.mem.replaceOwned(u8, std.testing.allocator, source, "1 < 2", "2 < 1");
    defer std.testing.allocator.free(rejected);
    try fixture.db.setInput(queries.SourceText, 0, rejected);
    try fixture.expectExit(1);
    const handled = try std.mem.replaceOwned(u8, std.testing.allocator, rejected, "else exit(1)", "else ()");
    defer std.testing.allocator.free(handled);
    try fixture.db.setInput(queries.SourceText, 0, handled);
    try fixture.expectExit(0);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0);
}

test "copied optional argument snapshots preserve loop growth and reject retained aliases" {
    const source =
        \\func must(static T: type, var outcome: T | none) T
        \\    match outcome^
        \\        value and value is T -> return value^
        \\        _ -> ()
        \\    panic "required operation failed"
        \\func calculate() int | none
        \\    var pending: List(int) = [1]
        \\    var head = 0
        \\    var total = 0
        \\    loop
        \\        if head == pending.len() -> break
        \\        const current = must(pending[head])
        \\        head += 1
        \\        total += current
        \\        if current < 4
        \\            const checked_value_1 = pending.append(current * 2)
        \\            if not (checked_value_1 is unit) -> return none
        \\            const checked_value_2 = pending.append(current * 2 + 1)
        \\            if not (checked_value_2 is unit) -> return none
        \\    return total + 14
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const shorter = try std.mem.replaceOwned(u8, std.testing.allocator, source, "current < 4", "current < 2");
    defer std.testing.allocator.free(shorter);
    try fixture.db.setInput(queries.SourceText, 0, shorter);
    try fixture.expectExit(20);
    const borrowed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "const current = must(pending[head])", "ref current = pending[head]");
    defer std.testing.allocator.free(borrowed);
    try fixture.db.setInput(queries.SourceText, 0, borrowed);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "string conversion snapshots refresh variant member constraints and bodies" {
    const source =
        \\struct Item
        \\    pub value: int
        \\pub converter(imm value: Item) String where 1 == 1 -> String(value.value)
        \\func run() int -> String([7, Item{value = 7}]).byte_length() + 36
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const body = try std.mem.replaceOwned(u8, std.testing.allocator, source, "String(value.value)", "String(value.value + 10)");
    defer std.testing.allocator.free(body);
    try fixture.db.setInput(queries.SourceText, 0, body);
    try fixture.expectExit(43);
    const constraint = try std.mem.replaceOwned(u8, std.testing.allocator, source, "where 1 == 1", "where 1 == 2");
    defer std.testing.allocator.free(constraint);
    try fixture.db.setInput(queries.SourceText, 0, constraint);
    try fixture.expectDiagnostic(.where_condition_failed);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "overload snapshots restore selection and refresh membership and signatures" {
    const prefix =
        \\func first(value: int) int -> value
        \\func second(value: int) int -> value + 1
        \\func boolean(value: bool) int -> 0
    ;
    const body = "\nfunc run() int -> choose(42)\nexit(run())";
    const source = prefix ++ "\noverload choose(first, boolean)" ++ body;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 0, prefix ++ "\noverload choose(second, boolean)" ++ body);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, prefix ++ "\noverload choose(first, second)" ++ body);
    try fixture.expectDiagnostic(.ambiguous_overload);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "value: bool", "value: int");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(.ambiguous_overload);
}

test "overload range snapshots retain backing and refresh reusable bounds" {
    const source =
        \\func calculate() int | none
        \\    var values = [12, 20, 30]
        \\    const bounds = 1..
        \\    var selected = values.slice(bounds)
        \\    if not (selected is Span(int)) -> return none
        \\    const checked_value_2 = selected.get(0)
        \\    if not (checked_value_2 is int) -> return none
        \\    ref first = checked_value_2
        \\    first = 28
        \\    return values[0] + values[1] + selected.len()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "1..", "2..");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(33);
    const shortened = try std.mem.replaceOwned(u8, std.testing.allocator, changed, "[12, 20, 30]", "[12, 20]");
    defer std.testing.allocator.free(shortened);
    try fixture.db.setInput(queries.SourceText, 0, shortened);
    try fixture.expectExit(90);
}

test "panic snapshots distinguish static arguments even when machine code is equal" {
    const source = "func stop(static N: int) int -> panic\nfunc run() int -> stop(1)\nexit(run())";
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const source_fixture: test_sources.SourceFixture = .{ .db = fixture.db };
    const original = try source_fixture.runIo("");
    defer std.testing.allocator.free(original.stdout);
    defer std.testing.allocator.free(original.stderr);
    try std.testing.expect(std.mem.indexOf(u8, original.stderr, "at stop(1) ") != null);
    const edited_source = try std.mem.replaceOwned(u8, std.testing.allocator, source, "stop(1)", "stop(2)");
    defer std.testing.allocator.free(edited_source);
    try fixture.db.setInput(queries.SourceText, 0, edited_source);
    const edited = try source_fixture.runIo("");
    defer std.testing.allocator.free(edited.stdout);
    defer std.testing.allocator.free(edited.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, edited.term);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "at stop(2) ") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "stop(1)") == null);
}

test "panic snapshots restore traces and refresh messages and source locations" {
    const source = "func run() int -> panic \"original\"\nexit(run())";
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const source_fixture: test_sources.SourceFixture = .{ .db = fixture.db };
    const original = try source_fixture.runIo("");
    defer std.testing.allocator.free(original.stdout);
    defer std.testing.allocator.free(original.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, original.term);
    try std.testing.expect(std.mem.indexOf(u8, original.stderr, "panic: original\n  at run (main.chi:1:19)") != null);
    try fixture.db.setInput(queries.SourceText, 0, "\nfunc run() int -> panic \"edited\"\nexit(run())");
    try fixture.db.setInput(queries.SourcePath, 0, "renamed.chi");
    const edited = try source_fixture.runIo("");
    defer std.testing.allocator.free(edited.stdout);
    defer std.testing.allocator.free(edited.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, edited.term);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "panic: edited\n  at run (renamed.chi:2:19)") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited.stderr, "main.chi") == null);
    try fixture.db.setInput(queries.SourceText, 0, "func run() int -> 42\nexit(run())");
    try fixture.expectExit(42);
}

test "tuple snapshots restore values reference alternatives and member-kind edits" {
    const source =
        \\func pair() (int, int) -> (12, 30)
        \\static answer = pair()
        \\func capture(ref owner: int) ref int | End -> owner
        \\func run() int
        \\    var owner = answer.0
        \\    var carrier: ref int | End = capture(owner)
        \\    match carrier
        \\        int ->
        \\            ref item = carrier
        \\            carrier = End{}
        \\            item += answer.1
        \\            return owner
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "(12, 30)", "(13, 30)");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(43);
    const owned = try std.mem.replaceOwned(u8, std.testing.allocator, source, "ref int | End", "int | End");
    defer std.testing.allocator.free(owned);
    try fixture.db.setInput(queries.SourceText, 0, owned);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "readonly aggregate snapshots preserve independent owned and reference permissions" {
    const source =
        \\struct Views
        \\    copy = trivial
        \\    view: Span(int)
        \\    target: Ref(int)
        \\func snapshot(imm source: Views) Views -> source
        \\func calculate() int | none
        \\    var values = [19, 23]
        \\    var target = 41
        \\    var owner = Box.new(snapshot(Views{view = values.span(), target = ((match Ref.from(target)
        \\        _selected_result_0 and _selected_result_0 is Ref(int) -> _selected_result_0
        \\        _ -> panic "unexpected none"))}))
        \\    if not (owner is Box(Views)) -> return none
        \\    ref copied = owner.borrow()
        \\    copied.target.value += 1
        \\    return copied.view[0] + copied.view[1] + target - 42
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "copied.target.value += 1", "copied.view[0] = 1");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "temporal reference snapshots recompute aliasing and mutation effects" {
    const source =
        \\struct Captures(T: type)
        \\    left: Ref(T)
        \\    right: Ref(T)
        \\func inspect(captures: Captures(String)) int | none
        \\    const view = captures.left.value.view()
        \\    const checked_value_1 = captures.right.value.append("x")
        \\    if not (checked_value_1 is unit) -> return none
        \\    return view.byte_length() + 39
        \\func calculate() int | none
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    const captures = Captures(String){left = ((match Ref.from(left)
        \\        _selected_result_0 and _selected_result_0 is Ref(String) -> _selected_result_0
        \\        _ -> return none)), right = ((match Ref.from(right)
        \\            _selected_result_1 and _selected_result_1 is Ref(String) -> _selected_result_1
        \\            _ -> return none))}
        \\    return ((match inspect(captures)
        \\        _selected_result_2 and _selected_result_2 is int -> _selected_result_2
        \\        _ -> return none))
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const original = (try Fixture.functionBody(fixture.db, "inspect")).*.?;
    try std.testing.expect(original.reference_contract.exclusions.len > 0);
    const aliased = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Ref.from(right)", "Ref.from(left)");
    defer std.testing.allocator.free(aliased);
    try fixture.db.setInput(queries.SourceText, 0, aliased);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    const no_mutation = try std.mem.replaceOwned(u8, std.testing.allocator, aliased, "const _: unit = captures.right.value.append(\"x\") else return none", "_ = 0");
    defer std.testing.allocator.free(no_mutation);
    try fixture.db.setInput(queries.SourceText, 0, no_mutation);
    try fixture.expectExit(42);
    try std.testing.expectEqual(@as(usize, 0), (try Fixture.functionBody(fixture.db, "inspect")).*.?.reference_contract.exclusions.len);
    try fixture.db.setInput(queries.SourceText, 0, aliased);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "destructor snapshots recompute captured authority and mutation effects" {
    const source =
        \\struct Observer
        \\    owner: Ref(String)
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Observer)
        \\        self.trace.value += self.owner.value.byte_length()
        \\func discard(var observer: Observer) -> ()
        \\func calculate() int | none
        \\    var owner: String = "abc"
        \\    const view = owner.view()
        \\    var trace = 0
        \\    discard(Observer{owner = ((match Ref.from(owner)
        \\        _selected_result_0 and _selected_result_0 is Ref(String) -> _selected_result_0
        \\        _ -> return none)), trace = ((match Ref.from(trace)
        \\            _selected_result_1 and _selected_result_1 is Ref(int) -> _selected_result_1
        \\            _ -> return none))})
        \\    return view.byte_length() + trace + 36
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const mutation = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.trace.value += self.owner.value.byte_length()", "const _: unit = self.owner.value.append(\"x\") else return");
    defer std.testing.allocator.free(mutation);
    try fixture.db.setInput(queries.SourceText, 0, mutation);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var owner:", "const owner:");
    defer std.testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectExit(42);
    const readonly_mutation = try std.mem.replaceOwned(u8, std.testing.allocator, mutation, "var owner:", "const owner:");
    defer std.testing.allocator.free(readonly_mutation);
    try fixture.db.setInput(queries.SourceText, 0, readonly_mutation);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "pull cursor snapshots recompute delivery kind effects and protocol methods" {
    const source =
        \\struct Cursor
        \\    position: int
        \\    value: int
        \\    func next(mut self: Cursor) int | End
        \\        if self.position >= 2 -> return End{}
        \\        self.position += 1
        \\        self.value += 1
        \\        return self.value
        \\func run() int
        \\    var cursor = Cursor{position = 0, value = 0}
        \\    var sum = 0
        \\    for ref item in cursor
        \\        item += 10
        \\        sum += item
        \\    return sum + cursor.value + 17
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const borrowed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "int | End", "ref int | End");
    defer std.testing.allocator.free(borrowed);
    try fixture.db.setInput(queries.SourceText, 0, borrowed);
    try fixture.expectExit(72);
    const changed_result = try std.mem.replaceOwned(u8, std.testing.allocator, source, "int | End", "bool | End");
    defer std.testing.allocator.free(changed_result);
    try fixture.db.setInput(queries.SourceText, 0, changed_result);
    try fixture.expectDiagnostic(.return_type_mismatch);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func next", "func advance");
    defer std.testing.allocator.free(missing);
    try fixture.db.setInput(queries.SourceText, 0, missing);
    try fixture.expectDiagnostic(.unknown_namespace_member);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "range iteration snapshots restore runtime and compile-time results and recompute endpoints" {
    const source =
        \\func run() int
        \\    var total = 36
        \\    for value in (0..=3).reversed() -> total += value
        \\    return total
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const exclusive = try std.mem.replaceOwned(u8, std.testing.allocator, source, "0..=3", "0..3");
    defer std.testing.allocator.free(exclusive);
    try fixture.db.setInput(queries.SourceText, 0, exclusive);
    try fixture.expectExit(36);
    const longer = try std.mem.replaceOwned(u8, std.testing.allocator, source, "0..=3", "0..=4");
    defer std.testing.allocator.free(longer);
    try fixture.db.setInput(queries.SourceText, 0, longer);
    try fixture.expectExit(50);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "cursor iteration snapshots track method edits explicit factories and missing operations" {
    const source =
        \\import std.range.{RangeIterator}
        \\struct Cursor
        \\    position: int
        \\    pub func next(mut self: Cursor) int | End
        \\        if self.position >= 3 -> return End{}
        \\        self.position += 1
        \\        return self.position * 7
        \\func run() int
        \\    var cursor = Cursor{position = 0}
        \\    var total = 0
        \\    for value in cursor
        \\        total += value
        \\        break
        \\    for value in cursor -> total += value
        \\    return total
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.position * 7", "self.position * 8");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(48);
    const factory = try std.mem.replaceOwned(u8, std.testing.allocator, source, "    pub func next",
        \\    pub func iter(ref self: Cursor) RangeIterator
        \\        const values = 0..=3
        \\        return values.iter()
        \\    pub func next
    );
    defer std.testing.allocator.free(factory);
    try fixture.db.setInput(queries.SourceText, 0, factory);
    try fixture.expectExit(6);
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, source, "pub func next", "pub func removed");
    defer std.testing.allocator.free(missing);
    try fixture.db.setInput(queries.SourceText, 0, missing);
    try fixture.expectDiagnostic(.unknown_namespace_member);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "text operations remainder and precise mutable calls survive snapshots and source edits" {
    const source =
        \\struct Named
        \\    pub name: StringView
        \\    pub value: int
        \\func touch(imm source: Named, mut target: Named)
        \\    target.value += source.value
        \\func run() int
        \\    var first = Named{
        \\        name = "first",
        \\        value = 19,
        \\    }
        \\    var second = Named{
        \\        name = "second",
        \\        value = 23,
        \\    }
        \\    touch(first, second)
        \\    touch(second, first)
        \\    if first.name <> "first" -> return 90
        \\    return second.value + first.value % second.value - 19
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "value = 19,", "value = 20,");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(46);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

const Fixture = struct {
    db: *query.Database,

    fn restore(source: []const u8) !Fixture {
        return restoreSources(source, &.{}, &.{}, null);
    }

    fn restoreSources(source: []const u8, files: []const modules.SourceFile, restored_files: []const modules.SourceFile, rejected: ?std.meta.Tag(structures.Diagnostic.Kind)) !Fixture {
        const allocator = std.testing.allocator;
        const io = std.testing.io;
        const first = try query.Database.init(allocator, .{ .worker_count = 2 });
        defer first.deinit();
        try modules.registerSources(first, allocator, source, files, &.{});
        const original = try executable(first);
        const original_body = try functionBody(first, "run");
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(directory);
        const digest = cache.querySnapshotKey(try cache.compilerDigest(io), "main.chi", &.{});
        try query_disk_cache.save(io, allocator, directory, digest, first);
        const payload = (try cache.load(io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
        defer allocator.free(payload);
        const second = try query.Database.init(allocator, .{ .worker_count = 2 });
        errdefer second.deinit();
        const offset = try query_disk_cache.restoreInterns(second, allocator, payload);
        try modules.registerSources(second, allocator, source, restored_files, &.{});
        try std.testing.expect(try query_disk_cache.restoreQueries(second, payload, offset) > 0);
        if (rejected) |kind| {
            const fixture: Fixture = .{ .db = second };
            try fixture.expectDiagnostic(kind);
            return fixture;
        }
        if (!structures.FunctionBodyAnalysis.eql(original_body.*.?, (try functionBody(second, "run")).*.?)) {
            std.debug.print("restored run body changed\n", .{});
            return error.TestUnexpectedResult;
        }
        const restored = try executable(second);
        try std.testing.expectEqualSlices(u8, original.bytes, restored.bytes);
        return .{ .db = second };
    }

    fn functionBody(db: *query.Database, name: []const u8) !*const ?structures.FunctionBodyAnalysis {
        const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
        return db.get(queries.AnalyzeFunctionInstance, .{ .item = scope.resolveFunction(name).? });
    }

    fn expectExit(self: Fixture, status: u8) !void {
        try (test_sources.SourceFixture{ .db = self.db }).expectExit(0, status);
    }

    fn expectDiagnostic(self: Fixture, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        try std.testing.expect((try self.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
        defer std.testing.allocator.free(diagnostics);
        try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
        try std.testing.expectEqual(kind, std.meta.activeTag(diagnostics[0].kind));
    }

    fn executable(db: *query.Database) !structures.Executable {
        return (test_sources.SourceFixture{ .db = db }).executable(0);
    }
};

test "cursor snapshots restore literal and empty spans and recompute source edits" {
    const source =
        \\static empty = Span(int).empty().as_imm()
        \\static bytes: BytesView = "\u{e9}"
        \\func run() int
        \\    const values = [19, 23]
        \\    const view = values.span()
        \\    match view.get(0)
        \\        ref first and first is int ->
        \\            match view.get(1)
        \\                ref second and second is int ->
        \\                    match bytes.get(0)
        \\                        ref literal and literal is byte -> return first + second + empty.len() + bytes.byte_length() - 2 + byte_int(literal) - 195
        \\                        _ -> ()
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "[19, 23]", "[20, 23]");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(44);
}

test "nested span snapshots recompute slice bounds extent and readonly backing" {
    const source =
        \\func select(ref source: Ref(Span(int))) Span(int) | none -> source.value.slice(0..2)
        \\func calculate() int | none
        \\    var values = [5, 17, 23, 29, 7]
        \\    var source = values.span()
        \\    var middle = source.slice(1..4)
        \\    if not (middle is Span(int)) -> return none
        \\    const carrier = Ref.from(middle)
        \\    var nested = select(carrier)
        \\    if not (nested is Span(int)) -> return none
        \\    nested[0] = nested[0]
        \\    return nested[0] + nested[1] + nested.len()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const shifted = try std.mem.replaceOwned(u8, std.testing.allocator, source, "source.slice(1..4)", "source.slice(2..5)");
    defer std.testing.allocator.free(shifted);
    try fixture.db.setInput(queries.SourceText, 0, shifted);
    try fixture.expectExit(66);
    const shortened = try std.mem.replaceOwned(u8, std.testing.allocator, source, "[5, 17, 23, 29, 7]", "[5, 17]");
    defer std.testing.allocator.free(shortened);
    try fixture.db.setInput(queries.SourceText, 0, shortened);
    try fixture.expectExit(138);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var middle: Span(int)", "const middle: Span(int)");
    defer std.testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectDiagnostic(.reference_not_writable);
    const attenuated = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var source = values.span()", "var source = values.span().as_imm()");
    defer std.testing.allocator.free(attenuated);
    try fixture.db.setInput(queries.SourceText, 0, attenuated);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "range snapshots restore raw bounds and recompute runtime endpoint presence" {
    const source =
        \\static bounds = 1..3
        \\func calculate() int | none
        \\    var values = [5, 17, 23, 29, 7]
        \\    const selected = values.slice(bounds)
        \\    if not (selected is Span(int)) -> return none
        \\    return selected[0] + selected[1] + selected.len()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const cases = [_]struct { bounds: []const u8, status: u8 }{
        .{ .bounds = "2..4", .status = 66 },
        .{ .bounds = "1..^2", .status = 42 },
        .{ .bounds = "^4..^2", .status = 42 },
        .{ .bounds = "^4..=^3", .status = 42 },
        .{ .bounds = "..^0", .status = 12 },
        .{ .bounds = "..2", .status = 6 },
        .{ .bounds = "1..", .status = 46 },
        .{ .bounds = "..", .status = 12 },
        .{ .bounds = "3..1", .status = 138 },
        .{ .bounds = "0..=2147483647", .status = 138 },
        .{ .bounds = "1..=none", .status = 138 },
        .{ .bounds = "1..=^0", .status = 138 },
        .{ .bounds = "^6..", .status = 138 },
    };
    for (cases) |case| {
        const replacement = try std.fmt.allocPrint(std.testing.allocator, "static bounds = {s}", .{case.bounds});
        defer std.testing.allocator.free(replacement);
        const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "static bounds = 1..3", replacement);
        defer std.testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        try fixture.expectExit(case.status);
        const restored = try Fixture.restore(edited);
        defer restored.db.deinit();
        try restored.expectExit(case.status);
    }
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "raw borrow snapshots recompute source and registered signature edits" {
    const source =
        \\import std.memory.{Allocation}
        \\func calculate() int | none
        \\    var storage = Allocation(int).allocate(1)
        \\    if not (storage is Allocation(int)) -> return none
        \\    if (storage.unsafe_initialize(0, 20) is unit) -> unit
        \\    else
        \\        storage^.deallocate()
        \\        return none
        \\    ref item = storage.unsafe_borrow(0)
        \\    item += 22
        \\    const result = item
        \\    storage.unsafe_destroy(0)
        \\    storage^.deallocate()
        \\    return result
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "(0, 20)", "(0, 21)");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, source);
    const memory_module = try fixture.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const declarations = (try fixture.db.get(queries.ModuleDeclarations, memory_module)).*.?;
    const resolved = (try fixture.db.get(queries.ResolveItem, declarations.resolveFunction("unsafe_borrow").?)).*.?;
    const library_source = standard_library.source("memory/allocation.chi");
    const invalid = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        library_source,
        "pub extern func unsafe_borrow(static T: type, ref allocation: Allocation(T), index: int) ref T",
        "pub extern func unsafe_borrow(static T: type, imm allocation: Allocation(T), index: int) ref T",
    );
    defer std.testing.allocator.free(invalid);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, invalid);
    try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    var invalid_signature = false;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind == .invalid_external_signature) invalid_signature = true;
    }
    try std.testing.expect(invalid_signature);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, library_source);
    try fixture.expectExit(42);
}

test "span snapshots retain capabilities and recompute attenuation edits" {
    const source =
        \\func capture(ref owner: Array(int, 1)) Span(int) -> owner.span()
        \\func run() int
        \\    var owner = [12]
        \\    var view = capture(owner)
        \\    match view.get(0)
        \\        ref item and item is int ->
        \\            item += 30
        \\            return item
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "-> owner.span()", "-> owner.span().as_imm()");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(.reference_not_writable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "returned text borrows reject conflicting writes after snapshot restoration" {
    const source =
        \\func validate(imm view: Span(byte)) StringView | none -> ((match BytesView.from_span(view.as_imm()).validate_utf8()
        \\    _selected_result_0 and _selected_result_0 is StringView -> _selected_result_0
        \\    _ -> return none))
        \\func inspect() int | none
        \\    var bytes: Array(byte, 1) = [65]
        \\    var writable = bytes.span()
        \\    const text = validate(writable)
        \\    if not (text is StringView) -> return none
        \\    return text.byte_length() + 41
        \\func run() int
        \\    match inspect()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "return text.byte_length() + 41", "writable[0] = 255\n    return text.byte_length() + 41");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(.borrow_outlives_source);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "operation snapshots restore calls indexers and invalidate signature and visibility edits" {
    const library =
        \\pub struct Value
        \\    copy = fieldwise
        \\    pub value: int
        \\    pub func +(imm left: Value, imm right: Value) Value -> Value{value = left.value + right.value}
    ;
    const source =
        \\import library.{Value}
        \\func calculate() int | none
        \\    var values = [19, 23]
        \\    values[0] += 1
        \\    const sum = Value{value = values[0]} + Value{value = values[1]}
        \\    return sum.value - 1
        \\func run() int
        \\    match calculate()
        \\        calculated and calculated is int -> return calculated
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const files = [_]modules.SourceFile{.{ .path = "library/value.chi", .module_path = "library", .source = library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const invalid = try std.mem.replaceOwned(u8, std.testing.allocator, library, "imm right: Value)", "imm right: Value, imm extra: Value)");
    defer std.testing.allocator.free(invalid);
    try fixture.db.setInput(queries.SourceText, 1, invalid);
    try fixture.expectDiagnostic(.invalid_operation_signature);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    const private = try std.mem.replaceOwned(u8, std.testing.allocator, library, "pub func +", "func +");
    defer std.testing.allocator.free(private);
    const private_files = [_]modules.SourceFile{.{ .path = "library/value.chi", .module_path = "library", .source = private }};
    const denied = try Fixture.restoreSources(source, &files, &private_files, .private_access);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, library);
    try denied.expectExit(42);
}

test "evaluation heap snapshots restore scalar results and recompute callee element and cleanup edits" {
    const source =
        \\struct Item
        \\    move = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value = self.trace.value + self.value
        \\func element() int -> 2
        \\func calculate(var trace: Ref(int)) int | none
        \\    const owner = Box(Item).new(Item{trace = trace, value = element()})
        \\    if not (owner is Box(Item)) -> return none
        \\    return owner.borrow().value + 38
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if not (trace is Array(int, 1)) -> panic "unexpected none"
        \\    match trace.get(0)
        \\        ref target and target is int ->
        \\            match calculate(Ref.from(target))
        \\                value and value is int -> return value + target
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(answer)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const callee = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func element() int -> 2", "func element() int -> 3");
    defer std.testing.allocator.free(callee);
    try fixture.db.setInput(queries.SourceText, 0, callee);
    try fixture.expectExit(44);
    const cleanup = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.trace.value + self.value", "self.trace.value + self.value + 1");
    defer std.testing.allocator.free(cleanup);
    try fixture.db.setInput(queries.SourceText, 0, cleanup);
    try fixture.expectExit(43);
    const fields = try std.mem.replaceOwned(u8, std.testing.allocator, source, "    value: int", "    value: int\n    padding: Array(int, 2)");
    defer std.testing.allocator.free(fields);
    const element_type = try std.mem.replaceOwned(u8, std.testing.allocator, fields, "value = element()}", "value = element(), padding = [0, 0]}");
    defer std.testing.allocator.free(element_type);
    try fixture.db.setInput(queries.SourceText, 0, element_type);
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "collection snapshots restore pending carriers heap destinations and initializer effects" {
    const source =
        \\func element() int -> 19
        \\func run() int
        \\    const fixed: Array(int, 1) = [element()]
        \\    const values: List(int) = [23]
        \\    match fixed.get(0)
        \\        ref first and first is int ->
        \\            match values.get(0)
        \\                ref second and second is int -> return first + second
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed_result = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func element() int", "func element() bool");
    defer std.testing.allocator.free(changed_result);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, changed_result, "-> 19", "-> true");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(.struct_initializer_field_type_mismatch);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "converter snapshots restore calls literals and invalidate owner edits" {
    const library =
        \\pub struct Source
        \\    copy = trivial
        \\    pub value: int
        \\pub struct Target
        \\    copy = trivial
        \\    pub value: int
        \\pub converter(value: Source) Target -> Target{value = value.value}
    ;
    const source =
        \\import library.{Source, Target}
        \\func run() int
        \\    const converted: Target = Source{value = 42}
        \\    const literal: byte = 255
        \\    return converted.value
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const private = try std.mem.replaceOwned(u8, std.testing.allocator, library, "pub converter", "converter");
    defer std.testing.allocator.free(private);
    try fixture.db.setInput(queries.SourceText, 1, private);
    try fixture.expectDiagnostic(.local_type_mismatch);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    const private_files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = private }};
    const denied = try Fixture.restoreSources(source, &files, &private_files, .local_type_mismatch);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, library);
    try denied.expectExit(42);
}

test "conversion snapshot misses invalidate after a converter is added" {
    const library =
        \\pub struct Source
        \\    pub value: int
        \\pub struct Target
        \\    pub value: int
    ;
    const converted = library ++ "\npub converter(value: Source) Target -> Target{value = value.value}\n";
    const source =
        \\import library.{Source, Target}
        \\func run(imm value: Source) int where not (Source.Target is func(imm Source) Target) -> 42
        \\exit(run(Source{value = 0}))
    ;
    const original_files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const changed_files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = converted }};
    const fixture = try Fixture.restoreSources(source, &original_files, &changed_files, .where_condition_failed);
    defer fixture.db.deinit();
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, converted);
    try fixture.expectDiagnostic(.where_condition_failed);
}

test "conversion callable snapshots refresh stored references after converter edits" {
    const source =
        \\struct Source
        \\    value: int
        \\struct Target
        \\    value: int
        \\converter(imm value: Source) Target where 1 == 1 -> Target{value = value.value}
        \\static convert = Source.Target
        \\func run() int -> convert(Source{value = 42}).value
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const body = try std.mem.replaceOwned(u8, std.testing.allocator, source, "value = value.value", "value = value.value + 1");
    defer std.testing.allocator.free(body);
    try fixture.db.setInput(queries.SourceText, 0, body);
    try fixture.expectExit(43);
    const constraint = try std.mem.replaceOwned(u8, std.testing.allocator, source, "where 1 == 1", "where 1 == 2");
    defer std.testing.allocator.free(constraint);
    try fixture.db.setInput(queries.SourceText, 0, constraint);
    try fixture.expectDiagnostic(.where_condition_failed);
    const removed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "converter(imm value: Source) Target where 1 == 1 -> Target{value = value.value}", "");
    defer std.testing.allocator.free(removed);
    try fixture.db.setInput(queries.SourceText, 0, removed);
    try fixture.expectDiagnostic(.unknown_namespace_member);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "staged static conversion snapshots track source and converter changes" {
    const source =
        \\static struct Source
        \\    copy = trivial
        \\    value: int
        \\struct Target
        \\    copy = trivial
        \\    value: int
        \\converter(static source: Source) Target -> Target{value = source.value}
        \\func compute() int
        \\    var source = Source{value = 40}
        \\    source.value += 2
        \\    const target: Target = source
        \\    var literal: int_literal = 40
        \\    literal = 42
        \\    const defaulted: int = literal
        \\    return target.value + defaulted - 42
        \\static answer = compute()
        \\func run() int -> answer
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const source_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "source.value += 2", "source.value += 3");
    defer std.testing.allocator.free(source_edit);
    try fixture.db.setInput(queries.SourceText, 0, source_edit);
    try fixture.expectExit(43);
    const converter_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Target{value = source.value}", "Target{value = source.value + 1}");
    defer std.testing.allocator.free(converter_edit);
    try fixture.db.setInput(queries.SourceText, 0, converter_edit);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "converter snapshot probes retain inferred types and annotated literal locals" {
    const library =
        \\pub struct Source
        \\    copy = trivial
        \\    pub value: int
        \\pub struct Target
        \\    copy = trivial
        \\    pub value: int
        \\pub converter(static T: type, value: Source) T where T == Target -> T{value = value.value}
        \\pub converter(static value: int_literal) Target -> Target{value = value}
    ;
    const source =
        \\import library.{Source, Target}
        \\func compute() Target
        \\    var literal: int_literal = 19
        \\    literal = 21
        \\    return literal
        \\static answer = compute()
        \\func run() int
        \\    const converted: Target = Source{value = 21}
        \\    return converted.value + answer.value
        \\exit(run())
    ;
    const files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const literal_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "literal = 21", "literal = 22");
    defer std.testing.allocator.free(literal_edit);
    try fixture.db.setInput(queries.SourceText, 0, literal_edit);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 0, source);
    const converter_edit = try std.mem.replaceOwned(u8, std.testing.allocator, library, "T{value = value.value}", "T{value = value.value + 1}");
    defer std.testing.allocator.free(converter_edit);
    try fixture.db.setInput(queries.SourceText, 1, converter_edit);
    try fixture.expectExit(43);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
}

test "static struct modifier edits invalidate restored runtime bodies" {
    const library =
        \\pub struct Data
        \\    copy = trivial
        \\    pub value: int
        \\pub func make() Data -> Data{value = 42}
    ;
    const source =
        \\import library.{make}
        \\func run() int -> make().value
        \\exit(run())
    ;
    const static_library = try std.mem.replaceOwned(u8, std.testing.allocator, library, "pub struct Data", "pub static struct Data");
    defer std.testing.allocator.free(static_library);
    const files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = library }};
    const static_files = [_]modules.SourceFile{.{ .path = "library/types.chi", .module_path = "library", .source = static_library }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, static_library);
    try fixture.expectDiagnostic(.compile_time_only_type);
    try fixture.db.setInput(queries.SourceText, 1, library);
    try fixture.expectExit(42);
    const denied = try Fixture.restoreSources(source, &files, &static_files, .compile_time_only_type);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, library);
    try denied.expectExit(42);
}

fn checkFieldVisibilitySnapshot(generated: bool) !void {
    const allocator = std.testing.allocator;
    const public_source = if (generated)
        \\pub func Cell(static T: type) type
        \\  return struct
        \\    pub value: T
        \\pub func make() Cell(int) -> Cell(int){value = 40}
    else
        \\pub struct Cell
        \\  pub value: int
        \\pub func make() Cell -> Cell{value = 40}
    ;
    const private_source = try std.mem.replaceOwned(u8, allocator, public_source, "pub value", "value");
    defer allocator.free(private_source);
    const source = try allocator.print(
        \\import library
        \\static Selected = library.Cell{s}
        \\func run() int
        \\  var item = library.make()
        \\  item.value += 1
        \\  return item.value + Selected{{value = 1}}.value
        \\static answer = run()
        \\exit(run() + answer - 42)
    , .{if (generated) "(int)" else ""});
    defer allocator.free(source);
    const public_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = public_source }};
    const private_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = private_source }};
    const fixture = try Fixture.restoreSources(source, &public_files, &public_files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    for ([_]bool{ false, true, false, true }) |is_public| {
        try fixture.db.setInput(queries.SourceText, 1, if (is_public) public_source else private_source);
        if (is_public) {
            try fixture.expectExit(42);
        } else {
            try fixture.expectDiagnostic(.private_struct_field);
        }
    }

    const denied = try Fixture.restoreSources(source, &public_files, &private_files, .private_struct_field);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, public_source);
    try denied.expectExit(42);
}

test "field visibility declared snapshots restore public fields and invalidate denied foreign access" {
    try checkFieldVisibilitySnapshot(false);
}

test "field visibility foreign generated snapshots restore public fields and invalidate denied access" {
    try checkFieldVisibilitySnapshot(true);
}

fn checkFieldVisibilityAnnotationSnapshot(generated: bool) !void {
    const allocator = std.testing.allocator;
    const public_source = if (generated)
        \\static Hidden = int
        \\pub static Visible = int
        \\pub func Cell(static T: type) type
        \\  return struct
        \\    pub value: Visible
        \\pub func make() Cell(int) -> Cell(int){value = 42}
    else
        \\static Hidden = int
        \\pub static Visible = int
        \\pub struct Cell
        \\  pub value: Visible
        \\pub func make() Cell -> Cell{value = 42}
    ;
    const hidden_source = try std.mem.replaceOwned(u8, allocator, public_source, "pub value: Visible", "pub value: Hidden");
    defer allocator.free(hidden_source);
    const private_source = try std.mem.replaceOwned(u8, allocator, hidden_source, "pub value", "value");
    defer allocator.free(private_source);
    const source = try allocator.print(
        \\import library
        \\static Selected = library.Cell{s}
        \\func run() int
        \\  const item: Selected = library.make()
        \\  return 42
        \\static answer = run()
        \\exit(run() + answer - 42)
    , .{if (generated) "(int)" else ""});
    defer allocator.free(source);
    const public_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = public_source }};
    const hidden_files = [_]modules.SourceFile{.{ .path = "library/cell.chi", .module_path = "library", .source = hidden_source }};
    const fixture = try Fixture.restoreSources(source, &public_files, &public_files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, hidden_source);
    try fixture.expectDiagnostic(.public_field_private_type);
    try fixture.db.setInput(queries.SourceText, 1, private_source);
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, hidden_source);
    try fixture.expectDiagnostic(.public_field_private_type);
    try fixture.db.setInput(queries.SourceText, 1, public_source);
    try fixture.expectExit(42);

    const denied = try Fixture.restoreSources(source, &public_files, &hidden_files, .public_field_private_type);
    defer denied.db.deinit();
    try denied.db.setInput(queries.SourceText, 1, public_source);
    try denied.expectExit(42);
}

test "field visibility declared snapshots invalidate public hidden type annotations and recover" {
    try checkFieldVisibilityAnnotationSnapshot(false);
}

test "field visibility generated snapshots invalidate public hidden type annotations and recover" {
    try checkFieldVisibilityAnnotationSnapshot(true);
}

test "initializer consumers select explicit variants and survive snapshots" {
    const source =
        \\func materialize(init item: int | none) int | none -> item
        \\func recover(init item: int | none) int
        \\    match materialize(item)
        \\        value and value is int -> return value
        \\        _ -> ()
        \\    return 40
        \\func run() int
        \\    const callback: func(init int | none) int = recover
        \\    const first = callback(if 1 == 1 -> none else 0)
        \\    return first + callback(2)
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "initializer variant writes survive snapshots and completion single use and mode edits" {
    const allocator = std.testing.allocator;
    const source =
        \\func materialize(init item: int | none) int | none -> return item
        \\func forward(init item: int | none) int | none -> return materialize(materialize(item))
        \\func run() int
        \\    var value = 0
        \\    const callback: func(init int | none) int | none = forward
        \\    if (callback(if true == true
        \\        value = 42
        \\        none
        \\    else 0) is int) -> return 99
        \\    return value
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const second = fixture.db;
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(second, "materialize");

    const effect_edit = try std.mem.replaceOwned(u8, allocator, source, "value = 42", "value = 41");
    defer allocator.free(effect_edit);
    try second.setInput(queries.SourceText, 0, effect_edit);
    try fixture.expectExit(40);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(second, "materialize"));

    const failure_edit = try std.mem.replaceOwned(u8, allocator, source, "        none", "        7");
    defer allocator.free(failure_edit);
    try second.setInput(queries.SourceText, 0, failure_edit);
    try fixture.expectExit(156);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(second, "materialize"));

    const single_use_edit = try std.mem.replaceOwned(u8, allocator, source, "func forward(init item: int | none) int | none -> return materialize(materialize(item))", "func forward(init item: int | none) int | none\n    const first = materialize(item)\n    return materialize(item)");
    defer allocator.free(single_use_edit);
    try second.setInput(queries.SourceText, 0, single_use_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);

    const mode_edit = try std.mem.replaceOwned(u8, allocator, source, "init item", "imm item");
    defer allocator.free(mode_edit);
    try second.setInput(queries.SourceText, 0, mode_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    const signature_edit = try std.mem.replaceOwned(u8, allocator, source, "func(init int | none) int | none", "func(init bool | none) bool | none");
    defer allocator.free(signature_edit);
    try second.setInput(queries.SourceText, 0, signature_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    try second.setInput(queries.SourceText, 0, source);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* != null);
}

test "initializer capture effects survive snapshots and capability edits" {
    const allocator = std.testing.allocator;
    const source =
        \\struct Item
        \\    value: int
        \\    move = trivial
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 2 -> return else exit(99)
        \\func materialize(init item: Item) Item -> return item
        \\func forward(init item: Item) Item -> return materialize(item)
        \\func run() int | none
        \\    var value = 1
        \\    const source = Item{value = 2}
        \\    const callback: func(init Item) Item = forward
        \\    const result = callback(if true == true
        \\        value = 40
        \\        source^
        \\    else Item{value = 0})
        \\    return value + result.value
        \\match run()
        \\    result and result is int -> exit(result)
        \\    _ -> exit(98)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const second = fixture.db;
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(second, "materialize");
    const effect_edit = try std.mem.replaceOwned(u8, allocator, source, "value = 40", "value = 39");
    defer allocator.free(effect_edit);
    try second.setInput(queries.SourceText, 0, effect_edit);
    try fixture.expectExit(41);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(second, "materialize"));
    const capability_edit = try std.mem.replaceOwned(u8, allocator, source, "move = trivial", "move = none");
    defer allocator.free(capability_edit);
    try second.setInput(queries.SourceText, 0, capability_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    const mode_edit = try std.mem.replaceOwned(u8, allocator, source, "init item", "imm item");
    defer allocator.free(mode_edit);
    try second.setInput(queries.SourceText, 0, mode_edit);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    try second.setInput(queries.SourceText, 0, source);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* != null);
}

test "initializer regions and native callbacks survive cache reuse and mode edits" {
    const allocator = std.testing.allocator;
    const source =
        \\func produce(imm value: int) int | none
        \\    if not (value > 0) -> return none
        \\    return value
        \\func materialize(init item: int) int -> return item
        \\func forward(init item: int) int -> return materialize(item)
        \\func run(imm base: int) int
        \\    var offset = 2
        \\    const callback: func(init int) int = forward
        \\    match callback(materialize(((match produce(base + offset)
        \\        _selected_result_2 and _selected_result_2 is int -> _selected_result_2
        \\        _ -> panic "unexpected none"))))
        \\        value and value is int -> return value
        \\        _ -> ()
        \\    return 0
        \\exit(run(40))
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    const second = fixture.db;
    try fixture.expectExit(42);
    const body = (try Fixture.functionBody(second, "run")).*.?;
    try std.testing.expect(body.initializer_regions.len > 0);
    try std.testing.expect(body.initializer_regions[0].initializer_regions.len > 0);

    const edited = try std.mem.replaceOwned(u8, allocator, source, "init item", "imm item");
    defer allocator.free(edited);
    try second.setInput(queries.SourceText, 0, edited);
    try std.testing.expect((try second.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try second.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, allocator);
    defer allocator.free(diagnostics);
    var rejected_mode = false;
    for (diagnostics) |diagnostic| if (diagnostic.kind == .local_type_mismatch) {
        rejected_mode = true;
    };
    try std.testing.expect(rejected_mode);
}

test "allocating initializer snapshots retain named return hooks and invalidate capabilities and single use" {
    const source =
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\    move = func(deinit self: Item) Item -> Item{value = self.value + 2}
        \\static Owner = Box(Item)
        \\static create = Owner.new
        \\func own(init item: Item) Box(Item) | none -> create(item)
        \\func copied() Item
        \\    const local = Item{value = 19}
        \\    return local
        \\func moved() Item
        \\    const local = Item{value = 20}
        \\    return local^
        \\func run() int | none
        \\    const callback: func(init Item) Box(Item) | none = own
        \\    const first = callback(copied())
        \\    if not (first is Box(Item)) -> return none
        \\    const second = callback(moved())
        \\    if not (second is Box(Item)) -> return none
        \\    return first.borrow().value + second.borrow().value
        \\match run()
        \\    value and value is int -> exit(value)
        \\    _ -> exit(99)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(fixture.db, "own");
    const hook_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "self.value + 1", "self.value + 2");
    defer std.testing.allocator.free(hook_edit);
    try fixture.db.setInput(queries.SourceText, 0, hook_edit);
    try fixture.expectExit(43);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(fixture.db, "own"));
    for ([_][]const u8{
        "copy = func(imm self: Item) Item -> Item{value = self.value + 1}",
        "move = func(deinit self: Item) Item -> Item{value = self.value + 2}",
        "func own(init item: Item) Box(Item) | none -> create(item)",
    }, [_][]const u8{
        "copy = none",
        "move = none",
        "func own(init item: Item) Box(Item) | none\n    const first = create(item)\n    return create(item)",
    }) |original, replacement| {
        const edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, original, replacement);
        defer std.testing.allocator.free(edit);
        try fixture.db.setInput(queries.SourceText, 0, edit);
        try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    }
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "allocating initializer snapshots retain skipped evaluation after allocator edits" {
    const source =
        \\func forbidden() int -> exit(90)
        \\func run() int
        \\    const callback: func(init int) Box(int) | none = Box(int).new
        \\    if (callback(forbidden()) is Box(int)) -> return 1
        \\    return 42
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(90);
    const body = try Fixture.functionBody(fixture.db, "run");
    const allocation_file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.memory_allocation))).*;
    const allocation_source = (try fixture.db.input(queries.SourceText, allocation_file)).*;
    const edit = try std.mem.replaceOwned(u8, std.testing.allocator, allocation_source, "allocate(T, 1)", "allocate(T, -1)");
    defer std.testing.allocator.free(edit);
    try fixture.db.setInput(queries.SourceText, allocation_file, edit);
    try fixture.expectExit(42);
    try std.testing.expectEqual(body, try Fixture.functionBody(fixture.db, "run"));
    try fixture.db.setInput(queries.SourceText, allocation_file, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(90);
}

test "allocating initializer snapshots retain partial cleanup and consumption on variant mismatch" {
    for ([_][]const u8{ "missing()", "none" }) |completion| {
        errdefer std.debug.print("allocating completion: {s}\n", .{completion});
        const source = try std.testing.allocator.print(
            \\struct Leaf
            \\    count: Ref(int)
            \\    move = fieldwise
            \\    copy = none
            \\    drop = func(deinit self: Leaf)
            \\        self.count.value = self.count.value + 1
            \\struct Item
            \\    move = none
            \\    first: Leaf
            \\    second: int
            \\func missing() int | none -> none
            \\func assemble(var first: Leaf, second: int | none) Item | none
            \\    const value = second
            \\    if not (value is int) -> return none
            \\    return Item{{first = first^, second = value}}
            \\func run() int
            \\    var count = Box.new(40)
            \\    if not (count is Box(int)) -> panic "unexpected allocation refusal"
            \\    const callback: func(init Item | none) Box(Item | none) | none = Box(Item | none).new
            \\    var leaf = Leaf{{count = Ref.from(count.borrow())}}
            \\    const owner = callback(assemble(leaf^, {s}))
            \\    if not (owner is Box(Item | none)) -> return 91
            \\    if owner.borrow() is Item -> return 99
            \\    return count.borrow() + 1
            \\match run()
            \\    result -> exit(result)
        , .{completion});
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "Box.new(40)", "Box.new(39)");
        defer std.testing.allocator.free(edit);
        try fixture.db.setInput(queries.SourceText, 0, edit);
        try fixture.expectExit(41);
    }
}

test "raw slot initializer snapshots retain immovable destruction and recompute hooks and modes" {
    const source =
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Item
        \\    move = none
        \\    value: int
        \\    drop = func(deinit self: Item) -> exit(self.value + 0)
        \\func make(value: int) Item -> Item{value = value}
        \\func initialize(mut storage: Allocation(Item), init item: Item) unit | none -> storage.unsafe_initialize(1, item)
        \\func run() unit | none
        \\    var storage = allocate(Item, 2)
        \\    if not (storage is Allocation(Item)) -> return none
        \\    const callback: func(mut Allocation(Item), init Item) unit | none = initialize
        \\    match callback(storage, make(42))
        \\        filtered_value_111 and filtered_value_111 is unit -> ()
        \\        _ ->
        \\            deallocate(Item, storage)
        \\            return none
        \\    storage.unsafe_destroy(1)
        \\    deallocate(Item, storage)
        \\    return ()
        \\if (run() is unit) -> exit(99) else exit(98)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const consumer_body = try Fixture.functionBody(fixture.db, "initialize");
    const hook_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "exit(self.value + 0)", "exit(self.value + 1)");
    defer std.testing.allocator.free(hook_edit);
    try fixture.db.setInput(queries.SourceText, 0, hook_edit);
    try fixture.expectExit(43);
    try std.testing.expectEqual(consumer_body, try Fixture.functionBody(fixture.db, "initialize"));
    const mode_edit = try std.mem.replaceOwned(u8, std.testing.allocator, source, "init Item", "imm Item");
    defer std.testing.allocator.free(mode_edit);
    try fixture.db.setInput(queries.SourceText, 0, mode_edit);
    try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "array snapshots restore native and comptime fill reads writes and bounds" {
    const source =
        \\import std.array.{Array}
        \\func run() int
        \\    var values = Array(int, 3).filled(20)
        \\    if not (values is Array(int, 3)) -> panic "unexpected none"
        \\    match values.get(1)
        \\        ref middle and middle is int -> middle = 22
        \\        _ -> return 90
        \\    if (values.get(-1) is int) -> return 91
        \\    if (values.get(3) is int) -> return 92
        \\    if (values.get(-1) is int) -> return 93
        \\    if (values.get(3) is int) -> return 94
        \\    match values.get(0)
        \\        ref first and first is int ->
        \\            match values.get(1)
        \\                ref middle and middle is int -> return first + middle
        \\                _ -> ()
        \\        _ -> ()
        \\    return 95
    ;
    for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)", "static answer = run()\nexit(run() + answer - 42)" }) |entry| {
        const program = try std.testing.allocator.print("{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try Fixture.restore(program);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
    }
}

test "array snapshots restore empty and nested runtime tuple shapes" {
    for ([_]u32{ 0, 2 }) |length| {
        const source = try std.testing.allocator.print(
            \\import std.array.{{Array}}
            \\func run() int
            \\    const row = Array(int, {d}).filled(40)
            \\    const matrix = Array(Array(int, {d}), 2).filled(row)
            \\    match matrix.get(1)
            \\        ref selected and selected is Array(int, {d}) ->
            \\            match selected.get(0)
            \\                ref cell and cell is int -> return cell + selected.len()
            \\                _ -> ()
            \\            return 42
            \\        _ -> ()
            \\    return 90
            \\static answer = run()
            \\exit(run() + answer - 42)
        , .{ length, length, length });
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
    }
}

test "array snapshots recompute element types and counts and retain canonical interning" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.array.{Array}
        \\static Element = int
        \\static Count = 2
        \\static Shape = Array(Element, Count)
        \\func number(value: int | none) int
        \\    match value
        \\        int ->
        \\            ref selected = value
        \\            return selected
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    const values = Shape.filled(40)
        \\    match values.get(1)
        \\        selected and selected is Element -> return number(selected) + values.len()
        \\        _ -> ()
        \\    return 91
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
    const shape_item = scope.resolveStatic("Shape").?;
    const shape_value = (try fixture.db.get(queries.ResolveStatic, shape_item)).*.?;
    const original_type = (try fixture.db.lookupInterned(queries.CompileTimeValues, shape_value)).type;
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = fixture.db };
    for ([_][]const u8{ "static Element = int", "static Count = 2" }, [_][]const u8{ "static Element = int | none", "static Count = 3" }, [_]u8{ 42, 44 }) |original, replacement, status| {
        const edit = try std.mem.replaceOwned(u8, allocator, source, original, replacement);
        defer allocator.free(edit);
        try fixture.db.setInput(queries.SourceText, 0, edit);
        try fixture.expectExit(status);
        const edited_scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
        const edited_value = (try fixture.db.get(queries.ResolveStatic, edited_scope.resolveStatic("Shape").?)).*.?;
        const edited_type = (try fixture.db.lookupInterned(queries.CompileTimeValues, edited_value)).type;
        try std.testing.expect(edited_type != original_type);
        const array = (try types.arrayType(edited_type)).?;
        try std.testing.expectEqual(edited_type, structures.TypeId.fromInterned(try fixture.db.intern(queries.Types, .{ .array = array })));
        try fixture.db.setInput(queries.SourceText, 0, source);
        try fixture.expectExit(42);
        const restored_scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
        const restored_value = (try fixture.db.get(queries.ResolveStatic, restored_scope.resolveStatic("Shape").?)).*.?;
        try std.testing.expectEqual(original_type, (try fixture.db.lookupInterned(queries.CompileTimeValues, restored_value)).type);
    }
}

test "array snapshots invalidate element copy hook bodies and capabilities" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.array.{Array}
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func run() int
        \\    const original = Item{value = 40}
        \\    const values = Array(Item, 2).filled(original)
        \\    if not (values is Array(Item, 2)) -> panic "unexpected none"
        \\    const copied = values.copy()
        \\    match copied.get(1)
        \\        ref selected and selected is Item -> return selected.value
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const hook_edit = try std.mem.replaceOwned(u8, allocator, source, "self.value + 1", "self.value + 2");
    defer allocator.free(hook_edit);
    try fixture.db.setInput(queries.SourceText, 0, hook_edit);
    try fixture.expectExit(46);
    const capability_edit = try std.mem.replaceOwned(u8, allocator, source, "copy = func(imm self: Item) Item -> Item{value = self.value + 1}", "copy = none");
    defer allocator.free(capability_edit);
    try fixture.db.setInput(queries.SourceText, 0, capability_edit);
    try std.testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "array snapshots invalidate source indices and standard bounds checks" {
    const allocator = std.testing.allocator;
    const source =
        \\import std.array.{Array}
        \\func run() int
        \\    const values = Array(int, 2).filled(42)
        \\    if not (values is Array(int, 2)) -> panic "unexpected none"
        \\    match values.get(1)
        \\        ref selected and selected is int -> return selected
        \\        _ -> ()
        \\    return 89
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const index_edit = try std.mem.replaceOwned(u8, allocator, source, "values.get(1)", "values.get(2)");
    defer allocator.free(index_edit);
    try fixture.db.setInput(queries.SourceText, 0, index_edit);
    try fixture.expectExit(136);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
    const array_file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.array))).*;
    const array_source = try allocator.dupe(u8, (try fixture.db.input(queries.SourceText, array_file)).*);
    defer allocator.free(array_source);
    const bounds_edit = try std.mem.replaceOwned(u8, allocator, array_source, "index >= N", "index >= N - 1");
    defer allocator.free(bounds_edit);
    try std.testing.expect(!std.mem.eql(u8, array_source, bounds_edit));
    try fixture.db.setInput(queries.SourceText, array_file, bounds_edit);
    try fixture.expectExit(136);
    try fixture.db.setInput(queries.SourceText, array_file, array_source);
    try fixture.expectExit(42);
}

test "array intern snapshots preserve nested tuple values and reuse identical type identities" {
    const allocator = std.testing.allocator;
    const first = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer first.deinit();
    const row_data: structures.TypeData = .{ .array = .{ .element_type = .int, .length = 0 } };
    const row_id = try first.intern(queries.Types, row_data);
    const row_type: structures.TypeId = .fromInterned(row_id);
    const empty_tuple = try first.intern(queries.CompileTimeValueTuples, .{ .values = &.{} });
    const row_value = try first.intern(queries.CompileTimeValues, .{ .runtime = .{ .type_id = row_type, .value = .{ .structure = empty_tuple } } });
    const matrix_data: structures.TypeData = .{ .array = .{ .element_type = row_type, .length = 2 } };
    const matrix_id = try first.intern(queries.Types, matrix_data);
    const matrix_type: structures.TypeId = .fromInterned(matrix_id);
    const tuple = try first.intern(queries.CompileTimeValueTuples, .{ .values = &.{ row_value, row_value } });
    const matrix_value = try first.intern(queries.CompileTimeValues, .{ .runtime = .{ .type_id = matrix_type, .value = .{ .structure = tuple } } });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(directory);
    const digest = cache.querySnapshotKey(try cache.compilerDigest(std.testing.io), "main.chi", &.{});
    try query_disk_cache.save(std.testing.io, allocator, directory, digest, first);
    const payload = (try cache.load(std.testing.io, allocator, directory, digest)) orelse return error.TestUnexpectedResult;
    defer allocator.free(payload);
    const next_value: structures.CompileTimeValue = .{ .runtime = .{ .type_id = .int, .value = .{ .int = 31337 } } };
    const next_id = try first.intern(queries.CompileTimeValues, next_value);
    const second = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer second.deinit();
    const offset = try query_disk_cache.restoreInterns(second, allocator, payload);
    try std.testing.expectEqual(@as(usize, 0), try query_disk_cache.restoreQueries(second, payload, offset));
    try std.testing.expectEqual(row_id, try second.intern(queries.Types, row_data));
    try std.testing.expectEqual(matrix_id, try second.intern(queries.Types, matrix_data));
    const restored = (try second.lookupInterned(queries.CompileTimeValues, matrix_value)).runtime;
    try std.testing.expectEqual(matrix_type, restored.type_id);
    try std.testing.expectEqual(tuple, restored.value.structure);
    try std.testing.expectEqualSlices(structures.CompileTimeValueId, &.{ row_value, row_value }, (try second.lookupInterned(queries.CompileTimeValueTuples, tuple)).values);
    try std.testing.expectEqual(matrix_value, try second.intern(queries.CompileTimeValues, .{ .runtime = restored }));
    try std.testing.expectEqual(next_id, try second.intern(queries.CompileTimeValues, next_value));
}

test "array snapshots publish static nested values into runtime storage" {
    const fixture = try Fixture.restore(
        \\static row = ((match Array(int, 2).filled(20)
        \\    _selected_result_0 and _selected_result_0 is Array(int, 2) -> _selected_result_0^
        \\    _ -> panic "unexpected none"))
        \\static matrix = ((match Array(Array(int, 2), 2).filled(row)
        \\    _selected_result_1 and _selected_result_1 is Array(Array(int, 2), 2) -> _selected_result_1^
        \\    _ -> panic "unexpected none"))
        \\func run() int
        \\    const values = matrix
        \\    match values.get(1)
        \\        ref selected and selected is Array(int, 2) ->
        \\            match selected.get(0)
        \\                ref value and value is int -> return value + row.len() + 20
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    );
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "text snapshots restore symbolic data borrowed projections and invalidate literal edits" {
    const source =
        \\import words.{greeting}
        \\func inspect() int | none
        \\    const view = greeting.view()
        \\    const bytes = view.as_bytes()
        \\    const first = bytes.get(0)
        \\    if not (first is byte) -> return none
        \\    return byte_int(first) - 62
        \\func run() int
        \\    match inspect()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const files = [_]modules.SourceFile{.{ .path = "words/text.chi", .module_path = "words", .source = "pub static greeting = \"hello\\0é\"" }};
    const fixture = try Fixture.restoreSources(source, &files, &files, null);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    try fixture.db.setInput(queries.SourceText, 1, "pub static greeting = \"jello\\0é\"");
    try fixture.expectExit(44);
    try fixture.db.setInput(queries.SourceText, 1, files[0].source);
    try fixture.expectExit(42);
}

test "text snapshots restore owned string cleanup and standard stream artifacts" {
    const source =
        \\import std.io.{write_text, stdout}
        \\func length() int | none
        \\    var text = "hé"
        \\    const checked_value_1 = text.append("llo")
        \\    if not (checked_value_1 is unit) -> return none
        \\    const checked_value_2 = write_text(stdout, "")
        \\    if not (checked_value_2 is unit) -> return none
        \\    return text.byte_length() + 36
        \\func run() int
        \\    match length()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "optional argument snapshots restore variant values and converters" {
    const fixture = try Fixture.restore(
        \\func missing() int | none -> return none
        \\func value_or(value: int | none) int
        \\    match value
        \\        int ->
        \\            const found = value
        \\            return found
        \\        _ -> ()
        \\    return 42
        \\func run() int
        \\    const good = value_or(missing()) == 42
        \\    if good -> return 42
        \\    return 7
        \\exit(run())
    );
    defer fixture.db.deinit();
    try fixture.expectExit(42);
}

test "captured owner cleanup survives snapshots and source edits" {
    const source =
        \\struct Item
        \\    value: int
        \\    trace: Ref(int)
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value + self.value
        \\func make(var trace: Ref(int), value: int, enabled: bool) Item | none
        \\    if not enabled -> return none
        \\    return Item{value = value, trace = trace}
        \\func missing() int | none -> return none
        \\func consume(var first: Item | none, var second: Item | none, var third: Item | none, final: int) -> ()
        \\func work(var trace: Ref(int)) unit | none
        \\    consume(make(trace, 10, false), make(trace, 11, false), make(trace, 42, true), ((match missing()
        \\        selected and selected is int -> selected
        \\        _ -> return none)))
        \\    return ()
        \\func run() int
        \\    var trace = [0]
        \\    match trace.get(0)
        \\        ref handle and handle is int ->
        \\            if (work(((match Ref.from(handle)
        \\                _selected_result_4 and _selected_result_4 is Ref(int) -> _selected_result_4
        \\                _ -> panic "unexpected none"))) is unit) -> return 91
        \\            return handle
        \\        _ -> ()
        \\    return 92
        \\static answer = run()
        \\exit(answer + run() - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const edited = try std.mem.replaceOwned(u8, std.testing.allocator, source, "make(trace, 42, true)", "make(trace, 43, true)");
    defer std.testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(44);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "collection snapshots restore static environments runtime builders and edited shapes" {
    const source =
        \\static limit = 4
        \\func run() int
        \\    const runtime = 99
        \\    const ignored: Array(int, 0) = [value static for value in Array(int, 0)([runtime static if 1 < 0])]
        \\    const expanded = [i + 19 static for i in 0..limit static if i % 2 == 0]
        \\    const values = [x for x in expanded if x > 0]
        \\    return values.len() + ignored.len() + 40
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "limit = 4", "limit = 6");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(44);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "collection snapshots retain generated callable lexical environments" {
    const source =
        \\func run() int
        \\    const callbacks: Array(func() int, 2) = [(struct
        \\        pub func amount() int -> i + 19
        \\    ).amount static for i in [1, 3]]
        \\    match callbacks.get(0)
        \\        first and first is func() int ->
        \\            match callbacks.get(1)
        \\                second and second is func() int -> return first() + second()
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "i + 19", "i + 20");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(46);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "collection snapshots restore sequence carriers and callable reference origins" {
    const source =
        \\func gather(imm collect: func(init collection_sequence(Ref(int))) List(Ref(int)) | none, ref source: Array(int, 2)) int | none
        \\    const values = collect([Ref.from(item) for ref item in source])
        \\    if not (values is List(Ref(int))) -> return none
        \\    return values[0].value + values[1].value
        \\func run() int
        \\    var source = [19, 23]
        \\    match gather(List(Ref(int)).collect, source)
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "19, 23", "20, 24");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(46);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "collection snapshots restore inferred generic sequence construction" {
    const source =
        \\func gather(static T: type, init values: collection_sequence(T)) List(T) | none
        \\    return List(T).collect(values)
        \\func run() int
        \\    match gather([value for value in [19, 23]])
        \\        values and values is List(int) -> return values.len() + 40
        \\        _ -> ()
        \\    return 90
        \\static answer = run()
        \\exit(run() + answer - 42)
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "19, 23", "19, 23, 29");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(44);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(42);
}

test "structural tuple snapshots restore singleton inference and recompute pattern shapes and permissions" {
    const source =
        \\static base = (19,)
        \\func run() int
        \\    var fields = (base, [23])
        \\    const ((ref first,), [second]) = fields
        \\    first += 0
        \\    return first + second
        \\exit(run())
    ;
    const fixture = try Fixture.restore(source);
    defer fixture.db.deinit();
    try fixture.expectExit(42);
    for ([_]struct { before: []const u8, after: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .before = "[second]", .after = "[second, extra]", .diagnostic = .destructure_length_mismatch },
        .{ .before = "var fields", .after = "const fields", .diagnostic = .reference_not_writable },
    }) |edit| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, edit.before, edit.after);
        defer std.testing.allocator.free(changed);
        try fixture.db.setInput(queries.SourceText, 0, changed);
        try fixture.expectDiagnostic(edit.diagnostic);
        try fixture.db.setInput(queries.SourceText, 0, source);
        try fixture.expectExit(42);
    }
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, "(19,)", "(20,)");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(43);
}

test "List pattern snapshots track counted transfer helper changes" {
    for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)" }) |entry| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\func run() int
            \\    var values: List(int) = [19, 23]
            \\    if const [a, b] = values^ -> return a - b + 46
            \\    return 90
            \\{s}
        , .{entry});
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.restore(source);
        defer fixture.db.deinit();
        try fixture.expectExit(42);
        const allocation_file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.memory_allocation))).*;
        const allocation_source = standard_library.source("memory/allocation.chi");
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, allocation_source, "return [unsafe_take(T, owner.storage, index) static for index in 0..N]", "return [unsafe_take(T, owner.storage, N - 1 - index) static for index in 0..N]");
        defer std.testing.allocator.free(changed);
        try std.testing.expect(!std.mem.eql(u8, allocation_source, changed));
        try fixture.db.setInput(queries.SourceText, allocation_file, changed);
        try fixture.expectExit(50);
        try fixture.db.setInput(queries.SourceText, allocation_file, allocation_source);
        try fixture.expectExit(42);
    }
}
