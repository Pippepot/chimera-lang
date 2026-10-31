const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

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
        \\func make() List(byte) | none -> [7 for i in [0, 1]]
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
        \\    pub func next(mut self: Cursor) StringView | End | none
        \\        self.position += 1
        \\        if self.position > 2 -> return End{}
        \\        const checked_value_1 = self.buffered.append("next")
        \\        if not (checked_value_1 is unit) -> return none
        \\        return self.buffered.view()
        \\func run() unit | none
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    const values = [view for view in cursor]
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
        \\func forward(init values: collection_sequence(int)) List(int) | none
        \\    return List(int).collect(values)
        \\func invoke(imm collect: func(init collection_sequence(int)) (List(int) | none)) int | none
        \\    const fixed = collect([19, 23])
        \\    if not (fixed is List(int)) -> return none
        \\    const dynamic = collect([value for value in fixed])
        \\    if not (dynamic is List(int)) -> return none
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
        \\func invoke(imm collect: func(init collection_sequence(Ref(int))) (List(Ref(int)) | none), ref source: Array(int, 2)) List(Ref(int)) | none
        \\    return collect([Ref.from(value) for ref value in source])
        \\func calculate() int | none
        \\    var source = [19, 23]
        \\    const values = invoke(List(Ref(int)).collect, source)
        \\    if not (values is List(Ref(int))) -> return none
        \\    return values[0].value + values[1].value
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func invoke(imm collect: func(init collection_sequence(Ref(int))) (List(Ref(int)) | none)) List(Ref(int)) | none
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
        \\func invoke(imm collect: func(init collection_sequence(Array(int, 262144))) (List(Array(int, 262144)) | none)) List(Array(int, 262144)) | none
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
        \\func gather(static T: type, init values: collection_sequence(T)) List(T) | none
        \\    return List(T).collect(values)
        \\func forward(static T: type, init values: collection_sequence(T)) List(T) | none
        \\    return gather(values)
        \\func calculate() int | none
        \\    const fixed = gather([19, 23])
        \\    if not (fixed is List(int)) -> return none
        \\    const dynamic = forward([value for value in fixed])
        \\    if not (dynamic is List(int)) -> return none
        \\    return dynamic[0] + dynamic[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}
