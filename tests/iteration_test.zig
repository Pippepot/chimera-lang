const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "pull standard cursors deliver items and End directly" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var cursor = (2..=3).iter()
        \\    var sum = 0
        \\    match cursor.next()
        \\        first and first is int -> sum += first
        \\        _ -> return 90
        \\    match cursor.next()
        \\        second and second is int -> sum += second
        \\        _ -> return 91
        \\    if not (cursor.next() is End) -> return 92
        \\    if not (cursor.next() is End) -> return 93
        \\    var values = [12, 17]
        \\    var span_cursor = values.iter()
        \\    const captured = span_cursor.next()
        \\    match captured
        \\        int ->
        \\            ref first = captured
        \\            first += 13
        \\        _ -> return 94
        \\    match span_cursor.next()
        \\        ref _matched_second and _matched_second is int ->
        \\            ref second = _matched_second
        \\            second += sum
        \\        _ -> return 95
        \\    if not (span_cursor.next() is End) -> return 96
        \\    return values[0] + values[1] - sum
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 97
    , 42);
}

test "pull for polls next exactly once for owned items" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    value: int
        \\    calls: Ref(int)
        \\    func next(mut self: Cursor) int | End
        \\        self.calls.value += 1
        \\        if self.value >= 3 -> return End{}
        \\        const value = self.value
        \\        self.value += 1
        \\        return value
        \\func run() int
        \\    var calls = 0
        \\    var cursor = Cursor{value = 0, calls = Ref.from(calls)}
        \\    var sum = 0
        \\    for item in cursor -> sum += item
        \\    return calls * 10 + sum - 1
    , 42);
}

test "pull for preserves borrowed delivery and binding intent" {
    const declarations =
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\struct Cursor
        \\    source: Ref(Item)
        \\    ready: bool
        \\    func next(mut self: Cursor) ref Item | End
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return self.source.value
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var owner = Item{value = 12}
        \\    var cursor = Cursor{source = Ref.from(owner), ready = true}
        \\    for ref item in cursor -> item.value += 30
        \\    return owner.value
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const owner = Item{value = 42}
        \\    var cursor = Cursor{source = Ref.from(owner), ready = true}
        \\    for item in cursor -> return item.value
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\var owner = Item{value = 12}
        \\var cursor = Cursor{source = Ref.from(owner), ready = true}
        \\for item in cursor -> item.value += 30
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\var owner = Item{value = 12}
        \\var cursor = Cursor{source = Ref.from(owner), ready = true}
        \\for const item in cursor -> _ = item.value
    , .type_not_copyable);
    const conversion = "\nconverter(imm item: Item) int -> item.value\n";
    try Fixture.expectParity(declarations ++ conversion ++
        \\func run() int
        \\    const owner = Item{value = 42}
        \\    const value: int = owner
        \\    return value
    , 42);
    inline for (.{ "", "const", "var" }) |mode| {
        const body = try test_sources.renderTemplate(std.testing.allocator,
            \\func run() int
            \\    const owner = Item{value = 42}
            \\    var cursor = Cursor{source = Ref.from(owner), ready = true}
            \\    for $mode value: int in cursor -> return value
            \\    return 90
        , .{ .mode = mode });
        defer std.testing.allocator.free(body);
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ declarations, conversion, body });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "pull for transfers noncopyable owned delivery" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\struct Cursor
        \\    ready: bool
        \\    func next(mut self: Cursor) Item | End
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return Item{value = 42}
        \\func consume(var value: Item) int -> value.value
        \\func run() int
        \\    var cursor = Cursor{ready = true}
        \\    for item in cursor -> return consume(item^)
        \\    return 90
    , 42);
}

test "pull for binds fresh immovable owned payloads in place" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    value: int
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 10
        \\struct Cursor
        \\    ready: bool
        \\    trace: Ref(int)
        \\    func next(mut self: Cursor) Item | End
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return Item{value = 32, trace = self.trace}
        \\func run() int
        \\    var trace = 0
        \\    var cursor = Cursor{ready = true, trace = Ref.from(trace)}
        \\    var sum = 0
        \\    for item in cursor -> sum += item.value
        \\    return sum + trace
    , 42);
}

test "pull for supports borrowed whole carriers" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    item: int | End
        \\    ready: bool
        \\    func next(mut self: Cursor) ref (int | End)
        \\        if self.ready
        \\            self.ready = false
        \\            return self.item
        \\        self.item = End{}
        \\        return self.item
        \\func run() int
        \\    var cursor = Cursor{item = 42, ready = true}
        \\    var sum = 0
        \\    for item in cursor -> sum += item
        \\    return sum
    , 42);
}

test "pull for integrates range and collection factories" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values = [1, 2, 3]
        \\    for ref item in values -> item *= 7
        \\    var sum = 0
        \\    for item in values -> sum += item
        \\    if sum <> 42 -> return 90
        \\    for var item in values
        \\        item += 1
        \\        sum += item
        \\    if values[0] <> 7 -> return 91
        \\    for item in 2..=5 -> sum -= item
        \\    return sum - 31
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 92
    , 42);
}

test "pull for tracks reused buffer content lifetimes" {
    const declarations =
        \\struct Cursor
        \\    position: int
        \\    buffered: String
        \\    func next(mut self: Cursor) StringView | End | none
        \\        self.position += 1
        \\        if self.position > 2 -> return End{}
        \\        const checked_value_1 = self.buffered.append("next")
        \\        if not (checked_value_1 is unit) -> return none
        \\        return self.buffered.view()
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var total = 30
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    match cursor.next()
        \\        view and view is StringView -> total += view.byte_length()
        \\        _ -> ()
        \\    match cursor.next()
        \\        view and view is StringView -> total += view.byte_length()
        \\        _ -> ()
        \\    return total
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var total = 30
        \\    for outcome in Cursor{position = 0, buffered = ""}
        \\        const view = outcome
        \\        if not (view is StringView) -> return none
        \\        total += view.byte_length()
        \\    return total
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() unit | none
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    const retained = cursor.next()
        \\    _ = cursor.next()
        \\    match retained
        \\        StringView ->
        \\            ref view = retained
        \\            print(view)
        \\        _ -> ()
        \\    return ()
        \\if (calculate() is unit) -> exit(0)
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() unit | none
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    var retained: StringView | none = none
        \\    for outcome in cursor
        \\        const view = outcome
        \\        if not (view is StringView) -> return none
        \\        if retained is none -> retained = view
        \\    match retained
        \\        StringView ->
        \\            ref view = retained
        \\            print(view)
        \\        _ -> ()
        \\    return ()
        \\if (calculate() is unit) -> exit(0)
    , .borrow_outlives_source);
}

test "pull for preserves storage kinds across multiple item alternatives" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\struct Cursor
        \\    owner: Ref(Item)
        \\    position: int
        \\    func next(mut self: Cursor) ref Item | int | End
        \\        self.position += 1
        \\        if self.position == 1 -> return self.owner.value
        \\        if self.position == 2 -> return 12
        \\        return End{}
        \\func run() int
        \\    var owner = Item{value = 30}
        \\    var cursor = Cursor{owner = Ref.from(owner), position = 0}
        \\    var sum = 0
        \\    for item in cursor
        \\        match item
        \\            Item ->
        \\                ref borrowed = item
        \\                sum += borrowed.value
        \\            _ -> ()
        \\        match item
        \\            int ->
        \\                const owned = item
        \\                sum += owned
        \\            _ -> ()
        \\    return sum
    , 42);
    try Fixture.expectParity(
        \\struct Left
        \\    copy = none
        \\    pub value: int
        \\struct Right
        \\    copy = none
        \\    pub value: int
        \\struct Cursor
        \\    left: Ref(Left)
        \\    right: Ref(Right)
        \\    position: int
        \\    func next(mut self: Cursor) ref Left | ref Right | End
        \\        self.position += 1
        \\        if self.position == 1 -> return self.left.value
        \\        if self.position == 2 -> return self.right.value
        \\        return End{}
        \\func run() int
        \\    var left = Left{value = 12}
        \\    var right = Right{value = 30}
        \\    var cursor = Cursor{left = Ref.from(left), right = Ref.from(right), position = 0}
        \\    var sum = 0
        \\    for item in cursor
        \\        match item
        \\            Left ->
        \\                ref value = item
        \\                sum += value.value
        \\            _ -> ()
        \\        match item
        \\            Right ->
        \\                ref value = item
        \\                sum += value.value
        \\            _ -> ()
        \\    return sum
    , 42);
}

test "pull for validates owned exhaustion alternatives at the protocol boundary" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Cursor
        \\    func next(mut self: Cursor) int | bool -> 42
        \\var cursor = Cursor{}
        \\for item in cursor -> break
    , .iterator_result_requires_end);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Cursor
        \\    end: End
        \\    func next(mut self: Cursor) int | ref End -> self.end
        \\var cursor = Cursor{end = End{}}
        \\for item in cursor -> break
    , .iterator_result_requires_end);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Cursor
        \\    func next(mut self: Cursor) int -> 42
        \\var cursor = Cursor{}
        \\for item in cursor -> break
    , .iterator_result_requires_end);
}

test "pull for exhaustion identity is independent of caller scope" {
    try Fixture.expectParity(
        \\struct End
        \\    value: int
        \\func run() int
        \\    var sum = 0
        \\    for value in 1..=3 -> sum += value
        \\    return sum * 7
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\struct End
        \\    value: int
        \\struct Cursor
        \\    func next(mut self: Cursor) int | End -> End{value = 0}
        \\var cursor = Cursor{}
        \\for item in cursor -> break
    , .iterator_result_requires_end);
    try Fixture.expectParity(
        \\import std.prelude.{}
        \\import std.exit.{exit}
        \\func run() int
        \\    var sum = 0
        \\    for value in 1..=3 -> sum += value
        \\    return sum * 7
    , 42);
}

test "pull generic map handles owned and borrowed inputs without metadata" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\import std.memory.{SpanIterator}
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\struct Mapped(S: type, A: type, B: type)
        \\    source: S
        \\    callback: func(A) B
        \\    func next(mut self: Mapped(S, A, B)) B | End
        \\        const result = self.source.next()
        \\        match result
        \\            A ->
        \\                ref item = result
        \\                return self.callback(item)
        \\            _ -> ()
        \\        return End{}
        \\func scale(value: int) int -> value * 7
        \\func read(item: Item) int -> item.value
        \\func run() int
        \\    var mapped = Mapped(RangeIterator, int, int){source = (1..=3).iter(), callback = scale}
        \\    var sum = 0
        \\    loop
        \\        match mapped.next()
        \\            item and item is int -> sum += item
        \\            _ -> break
        \\    if sum <> 42 -> return 90
        \\    const values = [Item{value = 12}, Item{value = 30}]
        \\    var borrowed = Mapped(SpanIterator(Item), Item, int){source = values.iter(), callback = read}
        \\    var total = 0
        \\    loop
        \\        match borrowed.next()
        \\            item and item is int -> total += item
        \\            _ -> break
        \\    return total
    , 42);
}

test "adapter feasibility type factories select owned or borrowed delivery" {
    inline for (.{ false, true }) |borrowed| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\import std.range.{RangeIterator}
            \\import std.memory.{SpanIterator}
            \\struct Item
            \\    copy = none
            \\    pub value: int
            \\func Filtered(static S: type, static T: type, static borrowed: bool) type
            \\    if borrowed
            \\        return struct
            \\            source: S
            \\            predicate: func(T) bool
            \\            func next(mut self: Filtered(S, T, borrowed)) ref T | End
            \\                loop
            \\                    const result = self.source.next()
            \\                    match result
            \\                        T ->
            \\                            ref item = result
            \\                            if self.predicate(item) -> return item
            \\                        _ -> return End{}
            \\    return struct
            \\        source: S
            \\        predicate: func(T) bool
            \\        func next(mut self: Filtered(S, T, borrowed)) T | End
            \\            loop
            \\                const result = self.source.next()
            \\                match result^
            \\                    item and item is T -> if self.predicate(item) -> return item^
            \\                    _ -> return End{}
            \\func accept(item: $item_type) bool -> $predicate
            \\func run() int
            \\    var values = [Item{value = 19}, Item{value = 21}]
            \\    var filtered = Filtered($source_type, $item_type, $borrowed){source = $source, predicate = accept}
            \\    var total = 0
            \\    loop
            \\        const result = filtered.next()
            \\        match result
            \\            $item_type ->
            \\                ref item = result
            \\                $sum
            \\            _ -> break
            \\    return total * $scale
        , .{
            .item_type = if (borrowed) "Item" else "int",
            .predicate = if (borrowed) "item.value > 0" else "item > 0",
            .source_type = if (borrowed) "SpanIterator(Item)" else "RangeIterator",
            .borrowed = if (borrowed) "true" else "false",
            .source = if (borrowed) "values.iter()" else "(1..=2).iter()",
            .sum = if (borrowed) "item.value += 1\n                total += item.value" else "total += item",
            .scale = if (borrowed) "1" else "14",
        });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "adapter feasibility structural type construction and callable inference limits" {
    try Fixture.expectParity(
        \\func Pair(static A: type, static B: type) type -> (A, B)
        \\func run() int
        \\    const pair: Pair(int, int) = (12, 30)
        \\    return pair.0 + pair.1
    , 42);
    const declarations =
        \\struct Source
        \\    value: int
        \\    func next(mut self: Source) int | End -> self.value
        \\func NextType(static S: type, static R: type, operation: func(mut S) R) type -> R
        \\func TypeOf(static T: type, value: T) type -> T
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var source = Source{value = 42}
        \\    const result: NextType(Source, int | End, Source.next) = source.next()
        \\    match result
        \\        int ->
        \\            const item = result
        \\            return item
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var source = Source{value = 42}
        \\    const poll: TypeOf(Source.next) = Source.next
        \\    const result = poll(source)
        \\    match result
        \\        int ->
        \\            const item = result
        \\            return item
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func run() int
        \\    var source = Source{value = 42}
        \\    const result: NextType(Source.next) = source.next()
        \\    match result
        \\        int ->
        \\            const item = result
        \\            return item
        \\        _ -> ()
        \\    return 90
        \\_ = run()
    , .static_argument_cannot_be_inferred);
}

test "adapter feasibility logical matching cannot preserve a mixed physical carrier" {
    const declarations =
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\func capture(ref owner: Item) ref Item | End -> owner
        \\func choose(ref owner: Item, borrowed: bool) Item | ref Item | End
        \\    if borrowed -> return capture(owner)
        \\    return Item{value = 12}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var owner = Item{value = 41}
        \\    var result = choose(owner, true)
        \\    match result
        \\        Item ->
        \\            ref item = result
        \\            item.value += 1
        \\        _ -> ()
        \\    return owner.value
    , 42);
    inline for (.{ "const", "ref" }) |mode| {
        const source = try test_sources.renderTemplate(std.testing.allocator, declarations ++ "\n" ++
            \\func narrow(ref owner: Item) (Item | ref Item, int) | End
            \\    var result = choose(owner, true)
            \\    if result is Item
            \\        $mode item = result
            \\        const pair: (Item | ref Item, int) = ($item, 0)
            \\        return pair^
            \\    return End{}
            \\func run() int
            \\    var owner = Item{value = 42}
            \\    const result = narrow(owner)
            \\    if result is End -> return 90
            \\    return 42
            \\_ = run()
        , .{ .mode = mode, .item = if (std.mem.eql(u8, mode, "const")) "item^" else "item" });
        defer std.testing.allocator.free(source);
        try Fixture.expectAnySourceDiagnostic(source, if (std.mem.eql(u8, mode, "const")) .type_not_copyable else .ambiguous_variant_member);
    }
}

test "pull generic borrowed filter handles predicate failure as rejection" {
    try Fixture.expectParity(
        \\import std.memory.{SpanIterator}
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\struct Filtered(S: type, T: type)
        \\    source: S
        \\    predicate: func(T) (bool | none)
        \\    func next(mut self: Filtered(S, T)) ref T | End
        \\        loop
        \\            match self.source.next()
        \\                ref _matched_item and _matched_item is T ->
        \\                    ref item = _matched_item
        \\                    match self.predicate(item)
        \\                        accepted and accepted is bool -> if accepted -> return item
        \\                        _ -> ()
        \\                _ -> return End{}
        \\func accept(item: Item) bool | none
        \\    if item.value % 2 == 0 -> return true
        \\    return none
        \\func run() int
        \\    const values = [Item{value = 1}, Item{value = 20}, Item{value = 3}, Item{value = 22}]
        \\    var filtered = Filtered(SpanIterator(Item), Item){source = values.iter(), predicate = accept}
        \\    var sum = 0
        \\    loop
        \\        match filtered.next()
        \\            ref _matched_item and _matched_item is Item ->
        \\                ref item = _matched_item
        \\                sum += item.value
        \\            _ -> break
        \\    return sum
    , 42);
}

test "pull generic owned filter discharges rejected and delivered items" {
    const source =
        \\struct Item
        \\    copy = none
        \\    value: int
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 1
        \\struct Source
        \\    position: int
        \\    trace: Ref(int)
        \\    func next(mut self: Source) Item | End
        \\        self.position += 1
        \\        if self.position > 4 -> return End{}
        \\        return Item{value = self.position, trace = self.trace}
        \\struct Filtered(S: type, T: type)
        \\    source: S
        \\    predicate: func(T) bool
        \\    func next(mut self: Filtered(S, T)) T | End
        \\        loop
        \\            match self.source.next()
        \\                item and item is T -> if self.predicate(item) -> return item^
        \\                _ -> return End{}
        \\func accept(item: Item) bool -> item.value % 2 == 0
        \\func run() int
        \\    var trace = 0
        \\    var filtered = Filtered(Source, Item){source = Source{position = 0, trace = Ref.from(trace)}, predicate = accept}
        \\    var sum = 0
        \\    loop
        \\        match filtered.next()
        \\            item and item is Item -> sum += item.value
        \\            _ -> break
        \\    return sum + trace * 9
    ;
    try Fixture.expectParity(source, 42);
    const explicit = try std.mem.replaceOwned(u8, std.testing.allocator, source ++ "\n_ = run()", "drop = func(deinit self: Item) -> self.trace.value += 1", "drop = explicit");
    defer std.testing.allocator.free(explicit);
    try Fixture.expectAnySourceDiagnostic(explicit, .value_requires_explicit_drop);
}

test "pull generic filter uses explicitly supplied disposal for explicit-drop items" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    drop = explicit
        \\    value: int
        \\    trace: Ref(int)
        \\struct Source
        \\    position: int
        \\    trace: Ref(int)
        \\    func next(mut self: Source) Item | End
        \\        self.position += 1
        \\        if self.position > 4 -> return End{}
        \\        return Item{value = self.position, trace = self.trace}
        \\struct Filtered(S: type, T: type)
        \\    source: S
        \\    predicate: func(T) bool
        \\    dispose: func(deinit T) unit
        \\    func next(mut self: Filtered(S, T)) T | End
        \\        loop
        \\            match self.source.next()
        \\                item and item is T ->
        \\                    if self.predicate(item) -> return item^
        \\                    self.dispose(item^)
        \\                _ -> return End{}
        \\func accept(item: Item) bool -> item.value % 2 == 0
        \\func dispose(deinit item: Item) -> item.trace.value += 1
        \\func run() int
        \\    var trace = 0
        \\    var filtered = Filtered(Source, Item){source = Source{position = 0, trace = Ref.from(trace)}, predicate = accept, dispose = dispose}
        \\    var sum = 0
        \\    loop
        \\        match filtered.next()
        \\            item and item is Item ->
        \\                sum += item.value
        \\                dispose(item^)
        \\            _ -> break
        \\    return sum + trace * 9
    , 42);
}

test "pull generic func filter propagates producer failure after rejected predicates" {
    try Fixture.expectParity(
        \\struct Source
        \\    polls: Ref(int)
        \\    func next(mut self: Source) int | End | none
        \\        self.polls.value += 1
        \\        if self.polls.value > 2 -> return none
        \\        if self.polls.value == 1 -> return 1
        \\        return 20
        \\struct Filtered(S: type, T: type)
        \\    source: S
        \\    predicate: func(T) bool
        \\    func next(mut self: Filtered(S, T)) T | End | none
        \\        loop
        \\            const result = self.source.next()
        \\            if not (result is int | End) -> return none
        \\            match result^
        \\                item and item is T -> if self.predicate(item) -> return item^
        \\                _ -> return End{}
        \\func accept(item: int) bool -> item % 2 == 0
        \\func calculate(ref polls: int) int | none
        \\    var filtered = Filtered(Source, int){source = Source{polls = Ref.from(polls)}, predicate = accept}
        \\    const first = filtered.next()
        \\    if not (first is int | End) -> return none
        \\    match first
        \\        int ->
        \\            const item = first
        \\            if item <> 20 -> return 93
        \\            const second = filtered.next()
        \\            if not (second is int | End) -> return none
        \\            match second
        \\                int ->
        \\                    const impossible = second
        \\                    return 90
        \\                _ -> ()
        \\        _ -> ()
        \\    return 91
        \\func run() int
        \\    var polls = 0
        \\    match calculate(polls)
        \\        impossible and impossible is int -> return 92
        \\        _ -> ()
        \\    return polls * 14
    , 42);
}

test "pull generic mixed zip composes nested owned and reference tuples" {
    const source =
        \\import std.range.{RangeIterator}
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\struct Once(T: type)
        \\    source: Ref(T)
        \\    ready: bool
        \\    func next(mut self: Once(T)) ref T | End
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return self.source.value
        \\struct Zip(L: type, R: type, A: type, B: type)
        \\    left: L
        \\    right: R
        \\    func next(mut self: Zip(L, R, A, B)) (A, ref B) | End
        \\        const left_result = self.left.next()
        \\        match left_result^
        \\            left_item and left_item is A ->
        \\                const right_result = self.right.next()
        \\                match right_result
        \\                    B ->
        \\                        ref right_item = right_result
        \\                        const pair: (A, ref B) = (left_item^, right_item)
        \\                        return pair^
        \\                    _ -> ()
        \\            _ -> ()
        \\        return End{}
        \\struct NestedZip(L: type, M: type, R: type, A: type, B: type, C: type)
        \\    left: Zip(L, M, A, B)
        \\    right: R
        \\    func next(mut self: NestedZip(L, M, R, A, B, C)) ((A, ref B), ref C) | End
        \\        const left_result = self.left.next()
        \\        match left_result^
        \\            left_item and left_item is (A, ref B) ->
        \\                const right_result = self.right.next()
        \\                match right_result
        \\                    C ->
        \\                        ref right_item = right_result
        \\                        const pair: ((A, ref B), ref C) = (left_item^, right_item)
        \\                        return pair^
        \\                    _ -> ()
        \\            _ -> ()
        \\        return End{}
        \\func run() int
        \\    var item = Item{value = 30}
        \\    const other = Item{value = 7}
        \\    var inner = Zip(RangeIterator, Once(Item), int, Item){left = (12..=12).iter(), right = Once(Item){source = Ref.from(item), ready = true}}
        \\    var nested = NestedZip(RangeIterator, Once(Item), Once(Item), int, Item, Item){left = inner^, right = Once(Item){source = Ref.from(other), ready = true}}
        \\    const result = nested.next()
        \\    match result
        \\        pair and pair is ((int, ref Item), ref Item) ->
        \\            if pair.0.0 <> 12 -> return 90
        \\            if pair.1.value <> 7 -> return 91
        \\            pair.0.1.value += 12
        \\            return item.value
        \\        _ -> ()
        \\    return 92
    ;
    try Fixture.expectParity(source, 42);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source ++ "\n_ = run()", "pair.0.1.value += 12", "pair.1.value += 12");
    defer std.testing.allocator.free(readonly);
    try Fixture.expectAnySourceDiagnostic(readonly, .reference_not_writable);
}

test "pull generic zip polls left first and drops unmatched owned items" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += 100
        \\struct Left
        \\    trace: Ref(int)
        \\    ready: bool
        \\    func next(mut self: Left) Item | End
        \\        self.trace.value += 1
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return Item{trace = self.trace, value = 30}
        \\struct Right
        \\    trace: Ref(int)
        \\    source: Ref(int)
        \\    ready: bool
        \\    func next(mut self: Right) ref int | End
        \\        self.trace.value += 10
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return self.source.value
        \\struct Zip(L: type, R: type, A: type, B: type)
        \\    left: L
        \\    right: R
        \\    func next(mut self: Zip(L, R, A, B)) (A, ref B) | End
        \\        const left_result = self.left.next()
        \\        match left_result^
        \\            left_item and left_item is A ->
        \\                const right_result = self.right.next()
        \\                match right_result
        \\                    B ->
        \\                        ref right_item = right_result
        \\                        const pair: (A, ref B) = (left_item^, right_item)
        \\                        return pair^
        \\                    _ -> ()
        \\            _ -> ()
        \\        return End{}
        \\func exhaust(ref trace: int, left_ready: bool, right_ready: bool)
        \\    const owner = 12
        \\    var zipped = Zip(Left, Right, Item, int){left = Left{trace = Ref.from(trace), ready = left_ready}, right = Right{trace = Ref.from(trace), source = Ref.from(owner), ready = right_ready}}
        \\    if not (zipped.next() is End) -> exit(90)
        \\func deliver(ref trace: int) int
        \\    const owner = 12
        \\    var zipped = Zip(Left, Right, Item, int){left = Left{trace = Ref.from(trace), ready = true}, right = Right{trace = Ref.from(trace), source = Ref.from(owner), ready = true}}
        \\    const result = zipped.next()
        \\    match result^
        \\        pair and pair is (Item, ref int) -> return pair.0.value + pair.1
        \\        _ -> ()
        \\    return 91
        \\func run() int
        \\    var trace = 0
        \\    exhaust(trace, false, true)
        \\    if trace <> 1 -> return 92
        \\    trace = 0
        \\    exhaust(trace, true, false)
        \\    if trace <> 111 -> return 93
        \\    trace = 0
        \\    const result = deliver(trace)
        \\    if trace <> 111 -> return 94
        \\    return result
    , 42);
}

test "pull generic func zip cleans up the retained left item on right failure" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 100
        \\struct Left
        \\    trace: Ref(int)
        \\    func next(mut self: Left) Item | End
        \\        self.trace.value += 1
        \\        return Item{trace = self.trace}
        \\struct Right
        \\    trace: Ref(int)
        \\    func next(mut self: Right) ref int | End | none
        \\        self.trace.value += 10
        \\        return none
        \\struct Zip(L: type, R: type, A: type, B: type)
        \\    left: L
        \\    right: R
        \\    func next(mut self: Zip(L, R, A, B)) (A, ref B) | End | none
        \\        const left_result = self.left.next()
        \\        match left_result^
        \\            left_item and left_item is A ->
        \\                const right_result = self.right.next()
        \\                if not (right_result is ref B | End) -> return none
        \\                match right_result
        \\                    B ->
        \\                        ref right_item = right_result
        \\                        const pair: (A, ref B) = (left_item^, right_item)
        \\                        return pair^
        \\                    _ -> ()
        \\            _ -> ()
        \\        return End{}
        \\func calculate(ref trace: int) unit | none
        \\    var zipped = Zip(Left, Right, Item, int){left = Left{trace = Ref.from(trace)}, right = Right{trace = Ref.from(trace)}}
        \\    const result = zipped.next()
        \\    if not (result is End | (Item, ref int)) -> return none
        \\    _ = result
        \\    return ()
        \\func run() int
        \\    var trace = 0
        \\    if (calculate(trace) is unit) -> return 90
        \\    return trace - 69
    , 42);
}

test "pull generic zip rejects actual retained-view invalidation not unrelated mutation" {
    const declarations =
        \\struct Left
        \\    source: Ref(String)
        \\    func next(mut self: Left) StringView | End -> self.source.value.view()
        \\struct Right
        \\    source: Ref(String)
        \\    func next(mut self: Right) int | End | none
        \\        const checked_value_1 = self.source.value.append("x")
        \\        if not (checked_value_1 is unit) -> return none
        \\        return 39
        \\struct Zip(L: type, R: type, A: type, B: type)
        \\    left: L
        \\    right: R
        \\    func next(mut self: Zip(L, R, A, B)) (A, B) | End | none
        \\        const left_result = self.left.next()
        \\        match left_result^
        \\            left_item and left_item is A ->
        \\                const right_result = self.right.next()
        \\                if not (right_result is B | End) -> return none
        \\                match right_result^
        \\                    right_item and right_item is B ->
        \\                        const pair: (A, B) = (left_item^, right_item^)
        \\                        return pair^
        \\                    _ -> ()
        \\            _ -> ()
        \\        return End{}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var owner: String = "abc"
        \\    var unrelated: String = ""
        \\    var zipped = Zip(Left, Right, StringView, int){left = Left{source = Ref.from(owner)}, right = Right{source = Ref.from(unrelated)}}
        \\    const result = zipped.next()
        \\    match result^
        \\        pair and pair is (StringView, int) -> return pair.0.byte_length() + pair.1
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 91
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var owner: String = "abc"
        \\    var zipped = Zip(Left, Right, StringView, int){left = Left{source = Ref.from(owner)}, right = Right{source = Ref.from(owner)}}
        \\    const result = zipped.next()
        \\    match result^
        \\        pair and pair is (StringView, int) -> return pair.0.byte_length() + pair.1
        \\        _ -> ()
        \\    return 90
        \\match calculate()
        \\    result and result is int -> exit(result)
        \\    _ -> ()
    , .borrow_outlives_source);
}

test "ranges construct ordinary cursors with native and comptime parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    const bounds = 2..=5
        \\    var cursor = bounds.iter()
        \\    var result = 0
        \\    loop
        \\        match cursor.next()
        \\            value and value is int -> result += value
        \\            _ -> break
        \\    if not (cursor.next() is End) -> return 90
        \\    return result * 3
    , 42);
}

test "ranges retain one value type while endpoint presence changes at runtime" {
    try Fixture.expectParity(
        \\import std.range.{Range}
        \\func select(first: int | none, limit: int | none) Range -> first..limit
        \\func run() int
        \\    var bounds = select(1, 4)
        \\    var total = 0
        \\    for value in bounds -> total += value
        \\    bounds = select(none, 4)
        \\    if String(bounds) <> "..4" -> return 90
        \\    bounds.first = 2
        \\    bounds.limit = none
        \\    if String(bounds) <> "2.." -> return 91
        \\    bounds = (..)
        \\    if String(bounds) <> ".." -> return 92
        \\    return total + 36
    , 42);
}

test "end relative ranges resolve stored bounds with checked native and comptime parity" {
    try Fixture.expectParity(
        \\import std.range.{RangeSequence}
        \\func calculate() int | none
        \\    const distance = ^2
        \\    const bounds = 1..distance
        \\    const first = bounds.resolve(5)
        \\    if not (first is (int, int)) -> return none
        \\    const second = bounds.resolve(8)
        \\    if not (second is (int, int)) -> return none
        \\    if not (first.0 == 1 and first.1 == 3) -> return none
        \\    if not (second.0 == 1 and second.1 == 6) -> return none
        \\    const suffix = (^2..).resolve(5)
        \\    if not (suffix is (int, int)) -> return none
        \\    if not (suffix.0 == 3 and suffix.1 == 5) -> return none
        \\    const included = (..=^1).resolve(5)
        \\    if not (included is (int, int)) -> return none
        \\    if not (included.0 == 0 and included.1 == 5) -> return none
        \\    const empty = (^0..).resolve(0)
        \\    if not (empty is (int, int)) -> return none
        \\    if not (empty.0 == 0 and empty.1 == 0) -> return none
        \\    if ((..=^0).resolve(5) is (int, int)) -> return 90
        \\    if ((^6..).resolve(5) is (int, int)) -> return 91
        \\    if ((..^(-1)).resolve(5) is (int, int)) -> return 92
        \\    if ((^(-2147483648)..).resolve(5) is (int, int)) -> return 93
        \\    if ((..^2147483647).resolve(5) is (int, int)) -> return 94
        \\    if ((3..^3).resolve(5) is (int, int)) -> return 95
        \\    if (bounds.step_by(1) is RangeSequence) -> return 96
        \\    if not (String(bounds) == "1..^2") -> return none
        \\    if not (String(^2..=^1) == "^2..=^1") -> return none
        \\    return 42
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 97
    , 42);
}

test "unresolved range stepping fails and infunc traversal panics" {
    try Fixture.expectParity(
        \\import std.range.{RangeSequence}
        \\func run() int
        \\    const ranges = [(..3), (2..), (..), (^1..2), (1..^1), (^2..^1)]
        \\    for bounds in ranges
        \\        match bounds.step_by(1)
        \\            sequence and sequence is RangeSequence -> return 90
        \\            _ -> ()
        \\    return 42
    , 42);
    for ([_][]const u8{ "..3", "2..", "..", "^1..2", "1..^1", "^2..^1" }) |bounds| {
        for ([_][]const u8{ "iter", "reversed" }) |method| {
            const source = try std.testing.allocator.print("const bounds = {s}\n_ = bounds.{s}()\nexit(90)", .{ bounds, method });
            defer std.testing.allocator.free(source);
            const fixture = try Fixture.init(source);
            defer fixture.deinit();
            const result = try fixture.runIo("");
            defer std.testing.allocator.free(result.stdout);
            defer std.testing.allocator.free(result.stderr);
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires both endpoints") != null);
        }
    }
    try Fixture.expectAnySourceDiagnostic("static cursor = (..3).iter()\n_ = cursor\nexit(0)", .compile_time_panic);
}

test "for ranges lower through ordinary loops with parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    var result = 0
        \\    for value in 2..=5
        \\        result += value
        \\    return result * 3
    , 42);
}

test "for range endpoints empty ranges and signed boundaries have parity" {
    const cases = [_]struct { range: []const u8, count: []const u8, sum: []const u8 }{
        .{ .range = "0..4", .count = "4", .sum = "6" },
        .{ .range = "0..=4", .count = "5", .sum = "10" },
        .{ .range = "2..2", .count = "0", .sum = "0" },
        .{ .range = "2..=2", .count = "1", .sum = "2" },
        .{ .range = "3..2", .count = "0", .sum = "0" },
        .{ .range = "3..=2", .count = "0", .sum = "0" },
        .{ .range = "2147483647..=2147483647", .count = "1", .sum = "2147483647" },
        .{ .range = "2147483646..=2147483647", .count = "2", .sum = "-3" },
        .{ .range = "2147483646..2147483647", .count = "1", .sum = "2147483646" },
        .{ .range = "-2147483648..=-2147483648", .count = "1", .sum = "-2147483648" },
        .{ .range = "-2147483648..-2147483646", .count = "2", .sum = "1" },
        .{ .range = "-2..=2", .count = "5", .sum = "0" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\func run() int
            \\    var count = 0
            \\    var sum = 0
            \\    for value in $range
            \\        count += 1
            \\        sum = wrapping(sum + value)
            \\        if count > 10 -> return 91
            \\    if count <> $count -> return 92
            \\    if sum <> $sum -> return 93
            \\    return 42
        , case);
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "for continue break and nested loops target the nearest loop" {
    try Fixture.expectParity(
        \\func run() int
        \\    var sum = 0
        \\    for value in 0..10
        \\        if value == 1 -> continue
        \\        if value == 5 -> break
        \\        sum += value
        \\    for outer in 0..3
        \\        for inner in 0..3
        \\            if inner == 1 -> break
        \\            sum += outer
        \\    return sum + 30
    , 42);
}

test "for break values join with unit exhaustion" {
    try Fixture.expectParity(
        \\func run() int
        \\    const found = for value in 0..10
        \\        if value == 7 -> break value
        \\    match found
        \\        int ->
        \\            const result = found
        \\            return result * 6
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "for body values do not become loop results" {
    try Fixture.expectParity(
        \\func run() int
        \\    const exhausted: unit = for value in 0..3 -> value * 100
        \\    const empty: unit = for value in 5..3 -> 99
        \\    return 42
    , 42);
}

test "for return exits the containing function" {
    try Fixture.expectParity(
        \\func first() int
        \\    for value in 6..10 -> return value
        \\    return 90
        \\func run() int -> first() * 7
    , 42);
}

test "for borrows existing cursors and resumes after early break" {
    try Fixture.expectParity(
        \\func run() int
        \\    const bounds = 0..10
        \\    var cursor = bounds.iter()
        \\    var sum = 0
        \\    var last = -1
        \\    for value in cursor
        \\        sum += value
        \\        if value == 2 -> break
        \\    for value in cursor
        \\        sum += value
        \\        last = value
        \\        break
        \\    if last <> 3 -> return 90
        \\    return sum * 7
    , 42);
}

test "for range values are reusable rather than shared cursors" {
    try Fixture.expectParity(
        \\func run() int
        \\    const bounds = 1..=3
        \\    var sum = 0
        \\    for value in bounds -> sum += value
        \\    for value in bounds -> sum += value
        \\    return sum + 30
    , 42);
}

test "for evaluates range endpoints once from left to right" {
    try Fixture.expectParity(
        \\func endpoint(mut trace: int, digit: int, result: int) int
        \\    trace = trace * 10 + digit
        \\    return result
        \\func run() int
        \\    var trace = 0
        \\    var sum = 0
        \\    for value in endpoint(trace, 1, 2)..=endpoint(trace, 2, 5)
        \\        sum += value
        \\    if trace <> 12 -> return 90
        \\    return sum * 3
    , 42);
}

test "for item bindings cannot escape their lexical scope" {
    try Fixture.expectSourceDiagnostic(
        \\for value in 0..3 -> ()
        \\exit(value)
    , .unknown_value);
}

test "for bare item bindings remain readonly" {
    try Fixture.expectSourceDiagnostic(
        \\for value in 0..3 -> value += 1
    , .assignment_to_immutable);
}

test "for collections share borrowed span iteration with parity" {
    for ([_][]const u8{
        "const values = [12, 14, 16]",
        "const values: List(int) = [12, 14, 16]",
        "const backing = [12, 14, 16]\n    const values = backing.span()",
    }) |binding| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\func run() int
            \\    $binding
            \\    var sum = 0
            \\    for value in values -> sum += value
            \\    return sum
        , .{ .binding = binding });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "for ref collection items preserve writable backing" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values = [1, 2, 3]
        \\    for ref value in values -> value *= 7
        \\    return values[0] + values[1] + values[2]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "for bare collection items borrow copyless immovable elements" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    pub value: int
        \\func run() int
        \\    var sum = 0
        \\    for item in [Item{value = 20}, Item{value = 22}]
        \\        sum += item.value
        \\    return sum
    , 42);
}

test "for owns fresh immovable next results without relocating them" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    pub value: int
        \\struct Cursor
        \\    position: int
        \\    pub func next(mut self: Cursor) Item | End
        \\        if self.position >= 2 -> return End{}
        \\        self.position += 1
        \\        return Item{value = self.position * 14}
        \\func run() int
        \\    var total = 0
        \\    for item in Cursor{position = 0} -> total += item.value
        \\    return total
    , 42);
}

test "for constructs fresh immovable sources and factory cursors in place" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    copy = none
        \\    move = none
        \\    position: int
        \\    limit: int
        \\    pub func next(mut self: Cursor) int | End
        \\        if self.position >= self.limit -> return End{}
        \\        self.position += 1
        \\        return self.position * 14
        \\struct Source
        \\    copy = none
        \\    move = none
        \\    limit: int
        \\    pub func iter(ref self: Source) Cursor -> Cursor{position = 0, limit = self.limit}
        \\func run() int
        \\    var total = 0
        \\    for value in Source{limit = 2} -> total += value
        \\    return total
    , 42);
}

test "for valued breaks construct fresh immovable results at the destination" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    pub value: int
        \\func run() int
        \\    const result: Item | unit = for value in 0..1 -> break Item{value = 42}
        \\    match result
        \\        Item ->
        \\            ref item = result
        \\            return item.value
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "for explicit owned collection bindings copy through ordinary hooks" {
    for ([_][]const u8{ "const", "var" }) |mode| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Item
            \\    pub value: int
            \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
            \\func run() int
            \\    const values = [Item{value = 20}, Item{value = 20}]
            \\    var sum = 0
            \\    for $mode item in values -> sum += item.value
            \\    return sum
        , .{ .mode = mode });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "for var collection bindings change copies rather than backing elements" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values = [5, 7]
        \\    var sum = 0
        \\    for var value in values
        \\        value *= 3
        \\        sum += value
        \\    if values[0] <> 5 -> return 90
        \\    if values[1] <> 7 -> return 91
        \\    return sum + 6
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 92
    , 42);
}

test "for explicit owning bindings reject copyless borrowed elements" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\const values = [Item{value = 42}]
        \\for const item in values -> exit(item.value)
    , .type_not_copyable);
}

test "for ref aliases owned poll payloads only within their carrier lifetime" {
    try Fixture.expectParity(
        \\func run() int
        \\    var total = 0
        \\    for ref value in 0..3
        \\        value += 13
        \\        total += value
        \\    return total
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func invalid() Ref(int)
        \\    for ref value in 0..3 -> return Ref.from(value)
        \\    exit(90)
        \\const result = invalid()
        \\exit(result.value)
    , .borrow_outlives_source);
}

test "for bare collection bindings cannot mutate fields" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    pub value: int
        \\var values = [Item{value = 42}]
        \\for item in values -> item.value = 0
    , .reference_not_writable);
}

test "for ref cannot upgrade readonly collection backing" {
    try Fixture.expectSourceDiagnostic(
        \\const values = [42]
        \\for ref value in values -> value = 0
    , .reference_not_writable);
}

test "for annotated binding modes preserve item semantics" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = [20, 22]
        \\    var sum = 0
        \\    for value: int in values -> sum += value
        \\    for ref value: int in values -> value += 1
        \\    for var value: int in 0..2 -> value += 100
        \\    return sum
    , 42);
}

test "for collection item references can outlive the cursor when backing remains" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = [42]
        \\    var retained: Ref(int) | none = none
        \\    for ref value in values -> retained = Ref.from(value)
        \\    match retained
        \\        Ref(int) ->
        \\            ref handle = retained
        \\            return handle.value
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "for polling delivers ordinary absence for explicit handling rather than exhaustion" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    position: int
        \\    pub func next(mut self: Cursor) int | End | none
        \\        if self.position == 2 -> return none
        \\        self.position += 1
        \\        return self.position
        \\func walk(mut sum: int) unit | none
        \\    var cursor = Cursor{position = 0}
        \\    for outcome in cursor
        \\        const value = outcome
        \\        if not (value is int) -> return none
        \\        sum += value
        \\    sum = 90
        \\    return ()
        \\func run() int
        \\    var sum = 0
        \\    if (walk(sum) is unit) -> return 91
        \\    if sum == 3 -> return 42
        \\    return 92
    , 42);
}

test "for item mismatch exits explicitly without an extra poll" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    position: int
        \\    pub func next(mut self: Cursor) int | End | none
        \\        self.position += 1
        \\        if self.position == 2 -> return none
        \\        return self.position
        \\func walk(mut sum: int) unit | none
        \\    var cursor = Cursor{position = 0}
        \\    for outcome in cursor
        \\        const value = outcome
        \\        if not (value is int) -> return none
        \\        sum += value
        \\    sum = 90
        \\    return ()
        \\func run() int
        \\    var sum = 0
        \\    if (walk(sum) is unit) -> return 91
        \\    if sum == 1 -> return 42
        \\    return 92
    , 42);
}

test "optional iterator factories require explicit selection before traversal" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\struct Source
        \\    pub func iter(ref self: Source) RangeIterator | none -> return none
        \\func walk(mut sum: int) unit | none
        \\    const source = Source{}
        \\    var cursor = source.iter()
        \\    if not (cursor is RangeIterator) -> return none
        \\    for value in cursor -> sum += value
        \\    return ()
        \\func run() int
        \\    var sum = 42
        \\    if (walk(sum) is unit) -> return 90
        \\    return sum
    , 42);
}

test "range stepping and reversal compose as sequence operations" {
    const cases = [_]struct { expression: []const u8, digits: []const u8, count: []const u8 }{
        .{ .expression = "step(0..10, 4)", .digits = "48", .count = "3" },
        .{ .expression = "step(0..10, 4).reversed()", .digits = "840", .count = "3" },
        .{ .expression = "step((0..10).reversed(), 4)", .digits = "951", .count = "3" },
        .{ .expression = "step(step(0..10, 2), 2)", .digits = "48", .count = "3" },
        .{ .expression = "step(step((0..10).reversed(), 2), 2)", .digits = "951", .count = "3" },
        .{ .expression = "step((3..3).reversed(), 2)", .digits = "0", .count = "0" },
        .{ .expression = "step((3..=3).reversed(), 2147483647)", .digits = "3", .count = "1" },
        .{ .expression = "step(0..10, 2147483647)", .digits = "0", .count = "1" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\import std.range.{RangeSequence}
            \\func step(static S: type, values: S, factor: int) RangeSequence
            \\    const selected = values.step_by(factor)
            \\    if not (selected is RangeSequence) -> panic "invalid step"
            \\    return selected
            \\func calculate() int
            \\    const values = $expression
            \\    var digits = 0
            \\    var count = 0
            \\    for value in values
            \\        digits = digits * 10 + value
            \\        count += 1
            \\        if count > 10 -> return 90
            \\    if digits <> $digits -> return 91
            \\    if count <> $count -> return 92
            \\    return 42
            \\func run() int
            \\    match calculate()
            \\        result -> return result
            \\    return 93
        , case);
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "range stepping rejects zero and negative factors" {
    try Fixture.expectParity(
        \\import std.range.{RangeSequence}
        \\func run() int
        \\    const values = 0..10
        \\    match values.step_by(0)
        \\        invalid and invalid is RangeSequence -> return 90
        \\        _ -> ()
        \\    match values.step_by(-1)
        \\        invalid and invalid is RangeSequence -> return 91
        \\        _ -> ()
        \\    return 42
    , 42);
}

test "range stepping supports distances and composed strides wider than int" {
    try Fixture.expectParity(
        \\import std.range.{RangeSequence}
        \\func calculate() int | none
        \\    const complete = -2147483648..=2147483647
        \\    const initial = complete.step_by(2147483647)
        \\    if not (initial is RangeSequence) -> return none
        \\    const huge = initial.step_by(2)
        \\    if not (huge is RangeSequence) -> return none
        \\    var count = 0
        \\    var sum = 0
        \\    for value in huge
        \\        count += 1
        \\        sum += value
        \\        if count > 2 -> return 90
        \\    if count <> 2 -> return 91
        \\    if sum <> -2 -> return 92
        \\    var reversed = huge.reversed().iter()
        \\    match reversed.next()
        \\        first and first is int -> if first <> 2147483646 -> return 94
        \\        _ -> return 93
        \\    match reversed.next()
        \\        second and second is int -> if second <> -2147483648 -> return 96
        \\        _ -> return 95
        \\    if not (reversed.next() is End) -> return 97
        \\    const singleton = huge.step_by(2)
        \\    if not (singleton is RangeSequence) -> return none
        \\    var single_count = 0
        \\    for value in singleton -> single_count += 1
        \\    if single_count <> 1 -> return 98
        \\    return 42
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 99
    , 42);
}

test "range wide boundary matrix matches independent selected sequences" {
    const allocator = std.testing.allocator;
    const endpoints = [_]i64{ -2147483648, -2147483647, -1073741824, -1, 0, 1, 1073741824, 2147483646, 2147483647 };
    const initial_factors = [_]i64{ 1073741823, 1073741824, 2147483647 };
    const following_factors = [_]usize{ 1, 2, 3, 2147483647 };
    var checks: std.Io.Writer.Allocating = .init(allocator);
    defer checks.deinit();
    for (endpoints, 0..) |first, first_index| {
        for (endpoints, 0..) |limit, limit_index| {
            for ([_]bool{ false, true }) |inclusive| {
                const case_index = first_index * endpoints.len + limit_index + @intFromBool(inclusive);
                const initial_factor = initial_factors[case_index % initial_factors.len];
                const following_factor = following_factors[case_index % following_factors.len];
                const reverse_source = case_index % 2 == 0;
                const reverse_middle = case_index % 3 == 0;
                const reverse_result = case_index % 5 == 0;
                const last = limit - @intFromBool(!inclusive);
                var expected: [5]i64 = undefined;
                var count: usize = 0;
                if (first <= last) {
                    var selected = if (reverse_source) last else first;
                    while (if (reverse_source) selected >= first else selected <= last) {
                        expected[count] = selected;
                        count += 1;
                        selected += if (reverse_source) -initial_factor else initial_factor;
                    }
                }
                if (reverse_middle) std.mem.reverse(i64, expected[0..count]);
                var selected_count: usize = 0;
                var selected_index: usize = 0;
                while (selected_index < count) : (selected_index += following_factor) {
                    expected[selected_count] = expected[selected_index];
                    selected_count += 1;
                }
                if (reverse_result) std.mem.reverse(i64, expected[0..selected_count]);
                try checks.writer.print("    check({d}, step(step(({d}..{s}{d})", .{ selected_count, first, if (inclusive) "=" else "", limit });
                if (reverse_source) try checks.writer.writeAll(".reversed()");
                try checks.writer.print(", {d})", .{initial_factor});
                if (reverse_middle) try checks.writer.writeAll(".reversed()");
                try checks.writer.print(", {d})", .{following_factor});
                if (reverse_result) try checks.writer.writeAll(".reversed()");
                try checks.writer.writeAll(", [");
                for (expected[0..selected_count], 0..) |value, value_index| {
                    if (value_index != 0) try checks.writer.writeAll(", ");
                    try checks.writer.print("{d}", .{value});
                }
                try checks.writer.writeAll("])\n");
            }
        }
    }
    const source = try test_sources.renderTemplate(allocator,
        \\import std.range.{RangeSequence}
        \\func step(static S: type, values: S, factor: int) RangeSequence
        \\    const selected = values.step_by(factor)
        \\    if not (selected is RangeSequence) -> panic "invalid step"
        \\    return selected
        \\func check(static N: int, values: RangeSequence, imm expected: Array(int, N))
        \\    var cursor = values.iter()
        \\    for value in expected
        \\        const actual = cursor.next()
        \\        if actual is int
        \\            if actual <> value -> panic "wrong element"
        \\        else
        \\            panic "early exhaustion"
        \\    if not (cursor.next() is End) -> panic "extra element"
        \\func calculate() int
        \\$checks
        \\    return 42
        \\func run() int
        \\    return calculate()
        \\    return 90
    , .{ .checks = checks.written() });
    defer allocator.free(source);
    try Fixture.expectParity(source, 42);
}

test "for owned cursors and items clean up on continue and break" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    pub value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += self.value
        \\struct Cursor
        \\    trace: Ref(int)
        \\    position: int
        \\    drop = func(deinit self: Cursor)
        \\        self.trace.value += 39
        \\    pub func next(mut self: Cursor) Item | End
        \\        if self.position >= 5 -> return End{}
        \\        self.position += 1
        \\        return Item{trace = self.trace, value = self.position}
        \\func run() int
        \\    var trace = 0
        \\    for item in Cursor{trace = Ref.from(trace), position = 0}
        \\        if item.value == 1 -> continue
        \\        break
        \\    return trace
    , 42);
}

test "for discards still acquire and destroy exactly one item per step" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += 1
        \\struct Cursor
        \\    trace: Ref(int)
        \\    position: int
        \\    pub func next(mut self: Cursor) Item | End
        \\        if self.position >= 3 -> return End{}
        \\        self.position += 1
        \\        self.trace.value += 10
        \\        return Item{trace = self.trace}
        \\func run() int
        \\    var trace = 9
        \\    for _ in Cursor{trace = Ref.from(trace), position = 0} -> ()
        \\    return trace
    , 42);
}

test "for source temporaries retain borrowed items through their final use" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    pub value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += self.value
        \\func run() int
        \\    var trace = 0
        \\    var sum = 0
        \\    for item in [Item{trace = Ref.from(trace), value = 20}, Item{trace = Ref.from(trace), value = 22}
        \\    ]
        \\        if trace <> 0 -> return 90
        \\        sum += item.value
        \\    if sum <> 42 -> return 91
        \\    return trace
    , 42);
}

test "for named cursor cleanup remains with its caller" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    trace: Ref(int)
        \\    position: int
        \\    drop = func(deinit self: Cursor)
        \\        self.trace.value += 40
        \\    pub func next(mut self: Cursor) int | End
        \\        self.position += 1
        \\        return self.position
        \\func run() int
        \\    var trace = 0
        \\    var cursor = Cursor{trace = Ref.from(trace), position = 0}
        \\    for value in cursor -> break
        \\    if trace <> 0 -> return 90
        \\    for value in cursor -> break
        \\    if cursor.position <> 2 -> return 91
        \\    return trace + 2
    , 42);
}

test "for optional payload items never become exhaustion" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values: Array(int | none, 3) = [10, none, 30]
        \\    var count = 0
        \\    var sum = 0
        \\    for value in values
        \\        count += 1
        \\        match value
        \\            int ->
        \\                const number = value
        \\                sum += number
        \\            _ -> ()
        \\    if count <> 3 -> return 90
        \\    return sum + 2
    , 42);
}

test "for explicit drop items require consumption on every exit" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    drop = explicit
        \\for value in [Item{}] -> break
    , .value_requires_explicit_drop);
}

test "for map filter take compose without repeated materialization or overpull" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\struct Mapped
        \\    source: RangeIterator
        \\    trace: Ref(int)
        \\    pub func next(mut self: Mapped) int | End
        \\        match self.source.next()
        \\            value and value is int ->
        \\                self.trace.value += 1
        \\                return value * 2
        \\            _ -> ()
        \\        return End{}
        \\struct Filtered
        \\    source: Mapped
        \\    pub func next(mut self: Filtered) int | End
        \\        loop
        \\            match self.source.next()
        \\                value and value is int -> if value % 4 == 0 -> return value
        \\                _ -> return End{}
        \\struct Taken
        \\    source: Filtered
        \\    remaining: int
        \\    pub func next(mut self: Taken) int | End
        \\        if self.remaining == 0 -> return End{}
        \\        match self.source.next()
        \\            value and value is int ->
        \\                self.remaining -= 1
        \\                return value
        \\            _ -> ()
        \\        return End{}
        \\func run() int
        \\    var trace = 0
        \\    const bounds = 0..100
        \\    var cursor = Taken{
        \\        source = Filtered{
        \\            source = Mapped{source = bounds.iter(), trace = Ref.from(trace)},
        \\        },
        \\        remaining = 3,
        \\    }
        \\    var sum = 0
        \\    for value in cursor -> sum += value
        \\    if trace <> 5 -> return 90
        \\    if sum <> 12 -> return 91
        \\    return 42
    , 42);
}

test "range progression matrix matches explicit small integer sequences" {
    try Fixture.expectParity(
        \\import std.range.{RangeSequence}
        \\func check(values: RangeSequence, first: int, last: int, stride: int, descending: bool) unit | none
        \\    var cursor = values.iter()
        \\    var expected = first
        \\    loop
        \\        if descending
        \\            if expected < last -> break
        \\        else
        \\            if expected > last -> break
        \\        match cursor.next()
        \\            value and value is int -> if not (value == expected) -> return none
        \\            _ -> return none
        \\        if descending -> expected -= stride
        \\        else expected += stride
        \\    if not (cursor.next() is End) -> return none
        \\    return ()
        \\func calculate() int | none
        \\    for first in -4..=4
        \\        for limit in -4..=4
        \\            for stride in 1..=4
        \\                const exclusive = (first..limit).step_by(stride)
        \\                if not (exclusive is RangeSequence) -> return none
        \\                const inclusive = (first..=limit).step_by(stride)
        \\                if not (inclusive is RangeSequence) -> return none
        \\                const checked_value_3 = check(exclusive, first, limit - 1, stride, false)
        \\                if not (checked_value_3 is unit) -> return none
        \\                const checked_value_4 = check(inclusive, first, limit, stride, false)
        \\                if not (checked_value_4 is unit) -> return none
        \\                if first < limit
        \\                    const end = first + ((limit - first - 1) / stride) * stride
        \\                    const checked_value_5 = check(exclusive.reversed(), end, first, stride, true)
        \\                    if not (checked_value_5 is unit) -> return none
        \\                else
        \\                    const checked_value_6 = check(exclusive.reversed(), 0, 1, stride, true)
        \\                    if not (checked_value_6 is unit) -> return none
        \\                if first <= limit
        \\                    const end = first + ((limit - first) / stride) * stride
        \\                    const checked_value_7 = check(inclusive.reversed(), end, first, stride, true)
        \\                    if not (checked_value_7 is unit) -> return none
        \\                else
        \\                    const checked_value_8 = check(inclusive.reversed(), 0, 1, stride, true)
        \\                    if not (checked_value_8 is unit) -> return none
        \\                const twice = inclusive.step_by(3)
        \\                if not (twice is RangeSequence) -> return none
        \\                const checked_value_10 = check(twice, first, limit, stride * 3, false)
        \\                if not (checked_value_10 is unit) -> return none
        \\    return 42
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "for filter can buffer and transfer move only owned items once" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item)
        \\        self.trace.value += 1
        \\struct Filtered
        \\    trace: Ref(int)
        \\    position: int
        \\    buffered: Item | none
        \\    pub func next(mut self: Filtered) Item | End
        \\        loop
        \\            self.position += 1
        \\            if self.position > 4 -> return End{}
        \\            self.buffered = Item{value = self.position, trace = self.trace}
        \\            match self.buffered
        \\                Item ->
        \\                    ref item = self.buffered
        \\                    if item.value % 2 == 0
        \\                        match self.buffered^
        \\                            selected and selected is Item ->
        \\                                self.buffered = none
        \\                                return selected^
        \\                            _ -> ()
        \\                _ -> ()
        \\            self.buffered = none
        \\func run() int
        \\    var trace = 0
        \\    var sum = 0
        \\    for item in Filtered{trace = Ref.from(trace), position = 0, buffered = none}
        \\        sum += item.value
        \\    if trace <> 4 -> return 90
        \\    return sum * 7
    , 42);
}

test "for gives explicit iterator factories precedence over cursor fallback" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\struct Source
        \\    calls: Ref(int)
        \\    pub func iter(ref self: Source) RangeIterator
        \\        self.calls.value += 1
        \\        const values = 20..=22
        \\        return values.iter()
        \\    pub func next(mut self: Source) int | End -> 99
        \\func run() int
        \\    var calls = 0
        \\    const source = Source{calls = Ref.from(calls)}
        \\    var sum = 0
        \\    for value in source -> sum += value
        \\    if calls <> 1 -> return 90
        \\    return sum - 21
    , 42);
}

test "for invalid explicit iterator factories do not silently use fallback" {
    try Fixture.expectSourceDiagnostic(
        \\struct Source
        \\    pub func iter(ref self: Source) int -> 0
        \\    pub func next(mut self: Source) int | End -> 42
        \\var source = Source{}
        \\for value in source -> exit(value)
    , .unknown_namespace_member);
}

test "for next must return an exhaustion-bearing variant rather than payload data" {
    const result_types = [_][]const u8{ "int", "unit", "bool", "int | none", "unit | none", "bool | none" };
    const results = [_][]const u8{ "0", "()", "true", "none", "none", "none" };
    for (result_types, results) |result_type, result| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Cursor
            \\    pub func next(mut self: Cursor) $result_type -> $result
            \\func run()
            \\    var cursor = Cursor{}
            \\    for value in cursor -> exit(value)
            \\run()
        , .{ .result_type = result_type, .result = result });
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .iterator_result_requires_end);
    }
    try Fixture.expectSourceDiagnostic(
        \\struct Cursor
        \\    pub func advance(mut self: Cursor) bool -> true
        \\    pub func current(ref self: Cursor) int -> 42
        \\var cursor = Cursor{}
        \\for value in cursor -> exit(value)
    , .unknown_namespace_member);
}

test "for zip polls independent borrowed cursors from left to right" {
    try Fixture.expectParity(
        \\import std.memory.{SpanIterator}
        \\struct Pair
        \\    pub ref left: int
        \\    pub ref right: int
        \\struct Zipped
        \\    left: SpanIterator(int)
        \\    right: SpanIterator(int)
        \\    ended: bool
        \\    pub func next(mut self: Zipped) Pair | End
        \\        if self.ended -> return End{}
        \\        const left = self.left.next()
        \\        match left
        \\            int ->
        \\                ref first = left
        \\                const right = self.right.next()
        \\                match right
        \\                    int ->
        \\                        ref second = right
        \\                        return Pair{left = first, right = second}
        \\                    _ -> ()
        \\            _ -> ()
        \\        self.ended = true
        \\        return End{}
        \\func run() int
        \\    var left = [10, 20, 99]
        \\    var right = [5, 7]
        \\    var cursor = Zipped{left = left.iter(), right = right.iter(), ended = false}
        \\    var sum = 0
        \\    for pair in cursor -> sum += pair.left + pair.right
        \\    if not (cursor.next() is End) -> return 90
        \\    return sum
    , 42);
}

test "for flatten stores outer and active inner cursor state without suspension" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\struct Flattened
        \\    outer: RangeIterator
        \\    inner: RangeIterator | none
        \\    pub func next(mut self: Flattened) int | End
        \\        loop
        \\            match self.inner
        \\                RangeIterator ->
        \\                    ref inner = self.inner
        \\                    match inner.next()
        \\                        value and value is int -> return value
        \\                        _ -> ()
        \\                _ -> ()
        \\            self.inner = none
        \\            match self.outer.next()
        \\                limit and limit is int ->
        \\                    const values = 0..limit
        \\                    self.inner = values.iter()
        \\                _ -> return End{}
        \\func run() int
        \\    const values = 0..4
        \\    var sum = 0
        \\    var count = 0
        \\    for value in Flattened{outer = values.iter(), inner = none}
        \\        sum += value
        \\        count += 1
        \\    if count <> 6 -> return 90
        \\    return sum + 38
    , 42);
}

test "for temporary collection references cannot escape their backing lifetime" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() Ref(int)
        \\    for ref value in [42] -> return Ref.from(value)
        \\    exit(90)
        \\const result = invalid()
        \\exit(result.value)
    , .borrow_outlives_source);
}

test "for retained cursor buffer references respect content invalidation" {
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
        \\    var retained: StringView | none = none
        \\    for value in cursor
        \\        if retained is none -> retained = value
        \\    match retained
        \\        StringView ->
        \\            ref view = retained
        \\            print(view)
        \\        _ -> ()
        \\    return ()
        \\if (run() is unit) -> exit(0)
    , .borrow_outlives_source);
}

test "for cursor lifetimes permit lending reused buffer views within each body" {
    for ([_][]const u8{ "StringView", "StringView | none" }) |result_type| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Cursor
            \\    position: int
            \\    buffered: String
            \\    pub func next(mut self: Cursor) StringView | End
            \\        self.position += 1
            \\        if self.position > 2 -> return End{}
            \\        const checked_value_1 = self.buffered.append("next")
            \\        if not (checked_value_1 is unit) -> panic "append failed"
            \\        const view = self.view()
            \\        if not (view is StringView) -> panic "missing view"
            \\        return view
            \\    pub func view(ref self: Cursor) $result_type -> self.buffered.view()
            \\func calculate() int
            \\    var total = 30
            \\    for view in Cursor{position = 0, buffered = ""}
            \\        total += view.byte_length()
            \\    return total
            \\func run() int
            \\    match calculate()
            \\        result -> return result
            \\    return 90
        , .{ .result_type = result_type });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "for cursor lifetimes preserve borrowed factory results and resume their state" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    position: int
        \\    pub func next(mut self: Cursor) int | End
        \\        if self.position >= 2 -> return End{}
        \\        self.position += 1
        \\        return self.position * 14
        \\struct Source
        \\    copy = none
        \\    move = none
        \\    cursor: Cursor
        \\    pub func iter(ref self: Source) ref Cursor -> self.cursor
        \\func run() int
        \\    var source = Source{cursor = Cursor{position = 0}}
        \\    var total = 0
        \\    for value in source
        \\        total += value
        \\        break
        \\    for value in source -> total += value
        \\    for value in Source{cursor = Cursor{position = 0}} -> total += value
        \\    return total - 42
    , 42);
}

test "for cursor lifetimes clean owned sources cursors and items on all failure stages" {
    const stages = [_]struct { factory: []const u8, poll: []const u8, prepare: []const u8, body: []const u8, expected: u8 }{
        .{ .factory = "none", .poll = "_ = 0", .prepare = "return Item{trace = self.trace}", .body = "return none", .expected = 30 },
        .{ .factory = "Cursor{trace = self.trace}", .poll = "return none", .prepare = "return Item{trace = self.trace}", .body = "return none", .expected = 40 },
        .{ .factory = "Cursor{trace = self.trace}", .poll = "_ = 0", .prepare = "return none", .body = "return none", .expected = 40 },
        .{ .factory = "Cursor{trace = self.trace}", .poll = "_ = 0", .prepare = "return Item{trace = self.trace}", .body = "return none", .expected = 41 },
    };
    for (stages) |stage| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Item
            \\    trace: Ref(int)
            \\    drop = func(deinit self: Item)
            \\        self.trace.value += 1
            \\struct Cursor
            \\    trace: Ref(int)
            \\    drop = func(deinit self: Cursor)
            \\        self.trace.value += 10
            \\    pub func next(mut self: Cursor) Item | End | none
            \\        $poll
            \\        $prepare
            \\struct Source
            \\    trace: Ref(int)
            \\    drop = func(deinit self: Source)
            \\        self.trace.value += 30
            \\    pub func iter(ref self: Source) Cursor | none -> $factory
            \\func walk(mut trace: int) unit | none
            \\    const source = Source{trace = Ref.from(trace)}
            \\    var cursor = source.iter()
            \\    if not (cursor is Cursor) -> return none
            \\    for outcome in cursor
            \\        const item = outcome^
            \\        if not (item is Item) -> return none
            \\        $body
            \\    return unit
            \\func run() int
            \\    var trace = 0
            \\    match walk(trace)
            \\        filtered_value_138 and filtered_value_138 is unit -> return 90
            \\        _ -> ()
            \\    return trace
        , .{ .factory = stage.factory, .poll = stage.poll, .prepare = stage.prepare, .body = stage.body });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, stage.expected);
    }
}

test "cursor method invalidation rejects a view retained across two calls" {
    try Fixture.expectSourceDiagnostic(
        \\struct Cursor
        \\    buffered: String
        \\    pub func next(mut self: Cursor) StringView | End | none
        \\        const checked_value_1 = self.buffered.append("next")
        \\        if not (checked_value_1 is unit) -> return none
        \\        return self.buffered.view()
        \\func run() unit | none
        \\    var cursor = Cursor{buffered = ""}
        \\    const result = cursor.next()
        \\    if not (result is StringView | End) -> return none
        \\    match result
        \\        StringView ->
        \\            const retained = result
        \\            cursor.next()
        \\            print(retained)
        \\        _ -> ()
        \\    return ()
        \\if (run() is unit) -> exit(0)
    , .borrow_outlives_source);
}

test "cursor method invalidation rejects a view retained across manual loop iterations" {
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
        \\    var retained: StringView | none = none
        \\    loop
        \\        const result = cursor.next()
        \\        if not (result is StringView | End) -> return none
        \\        match result
        \\            StringView ->
        \\                const value = result
        \\                if retained is none -> retained = value
        \\            _ -> break
        \\    match retained
        \\        StringView ->
        \\            ref view = retained
        \\            print(view)
        \\        _ -> ()
        \\    return ()
        \\if (run() is unit) -> exit(0)
    , .borrow_outlives_source);
}

test "for live list cursors reject backing relocation" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\    var values: List(int) = [1, 2]
        \\    for value in values
        \\        print("value")
        \\        const checked_value_1 = values.reserve(100)
        \\        if not (checked_value_1 is unit) -> return none
        \\    return ()
        \\if (run() is unit) -> exit(0)
    , .borrow_outlives_source);
}
