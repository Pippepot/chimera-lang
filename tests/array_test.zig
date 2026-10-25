const std = @import("std");
const test_sources = @import("test_sources");
const runtime = test_sources.runtime;
const testing = std.testing;

const Fixture = test_sources.SourceFixture;

fn expectLimitedExit(source: []const u8, status: u8) !void {
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    const executable = try fixture.executable(0);
    try runtime.writeProgram(testing.io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
    var child = std.process.spawn(testing.io, .{ .argv = &.{ "prlimit", "--as=1048576", "--", "./prog" } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try testing.expectEqual(std.process.Child.Term{ .exited = status }, try child.wait(testing.io));
}

test "operation indexing Array reads replacements and bounds have parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = [19, 23]
        \\    values[0] = 20
        \\    if const first: int = values.get(0)
        \\        if const second: int = values.get(1)
        \\            if const invalid: int = values.get(-1) -> return 91
        \\            if const invalid: int = values.get(2) -> return 92
        \\            const empty: Array(int, 0) = []
        \\            if const invalid: int = empty.get(0) -> return 93
        \\            return first + second - 1
        \\    return 90
    , 42);
}

test "discarded Array calls preserve effects and return storage" {
    try Fixture.expectParity(
        \\func produce(mut calls: int) Array(int, 3)
        \\    calls += 1
        \\    return [1, 2, 3]
        \\func produce_empty(mut calls: int) Array(int, 0)
        \\    calls += 1
        \\    return []
        \\func run() int
        \\    var calls = 40
        \\    produce(calls)
        \\    produce_empty(calls)
        \\    return calls
    , 42);
}

test "operation indexing compound assignments and reference assignments have parity" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values = [20, 10]
        \\    values[0] += 2
        \\    values[0] *= 2
        \\    values[0] -= 2
        \\    values[0] /= 2
        \\    if ref reference: int = values.get(1)
        \\        reference += 1
        \\        reference *= 2
        \\        reference -= 2
        \\        reference /= 2
        \\    return values[0] + values[1] + 11
        \\func run() int
        \\    if const calculated: int = calculate() -> return calculated
        \\    return 90
    , 42);
}

test "operation indexing List reads replacements and bounds use ordinary calls" {
    try Fixture.expectSourceExit(
        \\func calculate() int | none
        \\    var values: List(int) = [19, 23]
        \\    values[0] += 1
        \\    if const invalid: int = values.get(2) -> return 91
        \\    return values[0] + values[1] - 1
        \\func run() int
        \\    if const calculated: int = calculate() -> return calculated
        \\    return 90
        \\exit(run())
    , 42);
}

test "operation indexing evaluates owned replacements once and freezes the index" {
    try Fixture.expectParity(
        \\func offset(mut calls: int) int
        \\    calls += 1
        \\    return 0
        \\func replacement(mut calls: int) int
        \\    calls += 10
        \\    return 21
        \\func run() int
        \\    var calls = 0
        \\    var values = [19]
        \\    values[0] = replacement(calls)
        \\    if calls <> 10 -> return 92
        \\    calls = 0
        \\    values[offset(calls)] += replacement(calls)
        \\    if calls <> 11 -> return 93
        \\    if const stored: int = values.get(0) -> return stored
        \\    return 90
    , 42);
}

test "indexed replacements and compound updates read the same owner across container shapes" {
    for ([_][]const u8{
        "var values = [10, 20]",
        "var values: List(int) = [10, 20]",
        "var backing = [10, 20]\n    var values = backing.span()",
    }) |binding| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\func calculate() int
            \\    $binding
            \\    values[1] = values[0] + 1
            \\    values[1] += values[0]
            \\    return values[1] * 2
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 90
        , .{ .binding = binding });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "indexed nested array replacements finish conversion before mutable access" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values: Array(Array(int, 2), 2) = [[10, 20], [30, 40]]
        \\    values[1] = [values[0][0] + 1, values[0][1] + 11]
        \\    return values[1][0] + values[1][1]
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "optional replacement cleans its prepared owned value on mismatch" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value + self.value
        \\struct Sink
        \\    pub func replace(mut self: Sink, index: int, var item: Item) unit | none -> return none
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle: int = trace.get(0)
        \\        var sink = Sink{}
        \\        if const _: unit = sink.replace(99, Item{trace = Ref.from(handle), value = 42}) -> return 90
        \\        return handle
        \\    return 91
    , 42);
}

test "explicit checked reference acquisition skips the replacement on bounds failure" {
    try Fixture.expectParity(
        \\func replacement(mut calls: int) int
        \\    calls += 1
        \\    return 42
        \\func run() int
        \\    var values = [20]
        \\    var calls = 0
        \\    if ref target: int = values.get(99)
        \\        target = replacement(calls)
        \\    if const first: int = values.get(0) -> return first + calls + 22
        \\    return 90
    , 42);
}

test "operation indexing respects immutability and existing element ownership restrictions" {
    try Fixture.expectAnySourceDiagnostic(
        \\const values = [19]
        \\values[0] = 42
        \\exit(90)
    , .mutable_argument_requires_mutable_place);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    value: int
        \\var values = [Item{value = 19}]
        \\values[0] = Item{value = 42}
        \\exit(90)
    , .borrow_write_requires_direct_move);
}

test "operation indexing reads invoke ordinary copy hooks" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func run() int
        \\    const values = [Item{value = 41}]
        \\    if const selected: Item = values.get(0) -> return selected.value
        \\    return 90
    , 42);
}

test "operation indexing replacement destroys the previous element" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        if self.value == 19 -> exit(42)
        \\        exit(91)
        \\var values = [Item{value = 19}]
        \\values[0] = Item{value = 21}
        \\exit(92)
        \\exit(90)
    , 42);
}

test "operation indexing replacement retains stored reference origins" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var original = [17]
        \\    if ref item: int = original.get(0)
        \\        var values = [(if const _selected_result_0: Ref(int) = Ref.from(item) -> _selected_result_0 else return none)]
        \\        values[0] = (if const _selected_result_1: Ref(int) = Ref.from(item) -> _selected_result_1 else return none)
        \\        ref stored = values[0]
        \\        stored.value = 42
        \\        return item
        \\    return 90
        \\func run() int
        \\    if const answer: int = calculate() -> return answer
        \\    return 91
    , 42);
}

test "operation indexing List and views use the same operator contract" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func calculate() int | none
        \\    var values: List(int) = List(int).new(2) else return none
        \\    const _: unit = values.append(19) else return none
        \\    const _: unit = values.append(23) else return none
        \\    values[0] += 1
        \\    const view: Span(int) = values.slice(0..2) else return none
        \\    return view[0] + view[1] - 1
        \\func run() int
        \\    if const calculated: int = calculate() -> return calculated
        \\    return 90
        \\exit(run())
    , 42);
}

test "List literal constructs contextual empty and byte lists in heap storage" {
    try Fixture.expectSourceExit(
        \\func run() int
        \\    var values: List(int) = [19, 23]
        \\    const empty: List(int) = []
        \\    const bytes: List(byte) = [1, 2]
        \\    if ref first: int = values.get(0)
        \\        first = 20
        \\    if ref first: int = values.get(0)
        \\        if ref second: int = values.get(1)
        \\            return first + second + empty.len() + bytes.len() - 3
        \\    return 90
        \\exit(run())
    , 42);
}

test "List growth retains zero-sized logical elements and their destruction" {
    try Fixture.expectParity(
        \\struct Item
        \\    drop = func(deinit self: Item) -> exit(42)
        \\func exercise() int | none
        \\    var values: List(Item) = List(Item).new(0) else return none
        \\    const _: unit = values.append(Item{}) else return none
        \\    const _: unit = values.append(Item{}) else return none
        \\    const _: unit = values.append(Item{}) else return none
        \\    if values.len() <> 3 -> exit(91)
        \\    if values.capacity() <> 4 -> exit(92)
        \\    return 93
        \\func run() int
        \\    if const result: int = exercise() -> return result
        \\    return 94
    , 42);
}

test "List prefix cleanup on explicit mismatch is reversed and skips later work" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value * 10 + self.value
        \\func missing(var trace: Ref(int)) Item | none -> return none
        \\func skipped(var trace: Ref(int)) Item
        \\    exit(91)
        \\func construct(var trace: Ref(int)) unit | none
        \\    const prefix: List(Item) = [Item{trace = trace, value = 2}, Item{trace = trace, value = 4}]
        \\    prefix.len()
        \\    const _: Item = missing(trace) else return none
        \\    skipped(trace)
        \\    return unit
        \\func run() int
        \\    var trace: Array(int, 1) = Array(int, 1).filled(0) else panic "unexpected none"
        \\    if ref target: int = trace.get(0)
        \\        if const _: unit = construct(Ref.from(target))
        \\            return 92
        \\    if ref result: int = trace.get(0) -> return result
        \\    return 93
        \\exit(run())
    , 42);
}

test "List explicit factory infers length and optional elements remain ordinary data" {
    try Fixture.expectSourceExit(
        \\func missing() int | none -> return none
        \\func run() int
        \\    if const values: List(int) = List(int).from([19, 23])
        \\        if ref first: int = values.get(0)
        \\            if ref second: int = values.get(1)
        \\                const optional: List(int | none) = List(int | none).from([missing()]) else return 91
        \\                if const _: none = optional[0] -> return first + second
        \\                return 92
        \\    return 90
        \\exit(run())
    , 42);
}

test "List implicit allocation failure terminates before element evaluation and cannot be caught" {
    try expectLimitedExit(
        \\func skipped() Array(int, 262144)
        \\    exit(91)
        \\func run() int
        \\    const values: List(Array(int, 262144)) = [skipped()]
        \\    return values.len() + 91
        \\exit(run())
    , 134);
}

test "List explicit allocation failure is recoverable and skips element evaluation" {
    try expectLimitedExit(
        \\func skipped() Array(int, 262144)
        \\    exit(91)
        \\func run() int
        \\    if const values: List(Array(int, 262144)) = List(Array(int, 262144)).from([skipped()])
        \\        return 92
        \\    return 42
        \\exit(run())
    , 42);
}

test "List cleanup releases failed allocations and destroys completed lists in reverse" {
    try expectLimitedExit(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value * 10 + self.value
        \\func missing(var trace: Ref(int)) Item | none -> return none
        \\func construct(var trace: Ref(int)) unit | none
        \\    const prefix: List(Item) = [Item{trace = trace, value = 2}, Item{trace = trace, value = 4}]
        \\    prefix.len()
        \\    const _: Item = missing(trace) else return none
        \\    return unit
        \\func run() int
        \\    var trace: Array(int, 1) = Array(int, 1).filled(0) else panic "unexpected none"
        \\    if ref target: int = trace.get(0)
        \\        var iteration = 0
        \\        loop
        \\            if iteration == 384 -> break
        \\            target = 0
        \\            if const _: unit = construct(Ref.from(target))
        \\                return 91
        \\            if target == 42
        \\                iteration += 1
        \\            else
        \\                return 92
        \\        target = 0
        \\        const complete: List(Item) = [Item{trace = (if const _selected_result_4: Ref(int) = Ref.from(target) -> _selected_result_4 else panic "unexpected none"), value = 2}, Item{trace = (if const _selected_result_5: Ref(int) = Ref.from(target) -> _selected_result_5 else panic "unexpected none"), value = 4}]
        \\        complete.len()
        \\    if ref result: int = trace.get(0) -> return result
        \\    return 93
        \\exit(run())
    , 42);
}

test "List construction and borrowing preserve stored external reference origins" {
    try Fixture.expectSourceExit(
        \\func make(imm value: Ref(int)) List(Ref(int)) -> [value]
        \\func run() int
        \\    const original: Array(int, 1) = Array(int, 1).filled(42) else panic "unexpected none"
        \\    if ref reference: int = original.get(0)
        \\        const values = make((if const _selected_result_0: Ref(int) = Ref.from(reference) -> _selected_result_0 else panic "unexpected none"))
        \\        if ref stored: Ref(int) = values.get(0)
        \\            const result = stored
        \\            return result.value
        \\    return 90
        \\exit(run())
    , 42);
}

test "collection pending type cannot be constructed or published as a value" {
    try Fixture.expectAnySourceDiagnostic("func count(imm value: collection_literal(int, 2)) int -> 42\nconst pending = collection_literal(int, 2){}\nexit(count(pending))", .compile_time_only_type);
    try Fixture.expectAnySourceDiagnostic("func count(imm value: collection_literal(int, 2)) int -> 42\nstatic pending = collection_literal(int, 2){}\nstatic result = count(pending)\nexit(result)", .compile_time_only_type);
}

test "collection initializer consumers infer the pending shape and construct each element once" {
    try Fixture.expectParity(
        \\func count(static T: type, static N: int, init values: collection_literal(T, N)) int | none
        \\    const array: Array(T, N) = values
        \\    return array.len()
        \\func element(var trace: Ref(int)) int
        \\    trace.value = trace.value + 1
        \\    return 19
        \\func run() int
        \\    var trace: Array(int, 1) = Array(int, 1).filled(0) else panic "unexpected none"
        \\    if ref target: int = trace.get(0)
        \\        if const size: int = count([element((if const _selected_result_0: Ref(int) = Ref.from(target) -> _selected_result_0 else panic "unexpected none")), element((if const _selected_result_1: Ref(int) = Ref.from(target) -> _selected_result_1 else panic "unexpected none"))])
        \\            return target + size + 38
        \\    return 90
    , 42);
}

test "collection literals default contextual empty nested and byte arrays have parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [19, 23]
        \\    const empty: Array(int, 0) = []
        \\    const bytes: Array(byte, 2) = [1, 2]
        \\    const nested: Array(Array(int, 2), 1) = [[19, 23]]
        \\    if ref first: int = values.get(0)
        \\        if ref last: Array(int, 2) = nested.get(0)
        \\            if ref second: int = last.get(1)
        \\                return first + second + empty.len() + bytes.len() - 2
        \\    return 90
    , 42);
}

test "Array prefix cleanup on explicit mismatch is reversed and skips later work" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value * 10 + self.value
        \\func missing(var trace: Ref(int)) Item | none -> return none
        \\func skipped(var trace: Ref(int)) Item
        \\    exit(91)
        \\func construct(var trace: Ref(int)) unit | none
        \\    const prefix: Array(Item, 2) = [Item{trace = trace, value = 2}, Item{trace = trace, value = 4}]
        \\    prefix.len()
        \\    const _: Item = missing(trace) else return none
        \\    skipped(trace)
        \\    return unit
        \\func run() int
        \\    var trace: Array(int, 1) = Array(int, 1).filled(0) else panic "unexpected none"
        \\    if ref target: int = trace.get(0)
        \\        if const _: unit = construct(Ref.from(target))
        \\            return 92
        \\    if ref result: int = trace.get(0) -> return result
        \\    return 93
    , 42);
}

test "Array integer fill get and get_mut have native and comptime parity" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    var values: Array(int, 3) = Array(int, 3).filled(20) else panic "unexpected none"
        \\    if ref middle: int = values.get(1) -> middle = 22
        \\    else return 90
        \\    if ref first: int = values.get(0)
        \\        if ref middle: int = values.get(1) -> return first + middle
        \\    return 91
    , 42);
}

test "Array filled evaluates its source once" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func next(mut calls: int) int
        \\    calls += 1
        \\    return 41
        \\func run() int
        \\    var calls = 0
        \\    const values: Array(int, 4) = Array(int, 4).filled(next(calls)) else panic "unexpected none"
        \\    if ref last: int = values.get(3) -> return last + calls
        \\    return 90
    , 42);
}

test "Array empty fill evaluates once and all bounds fail" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func next(mut calls: int) int
        \\    calls += 1
        \\    return 41
        \\func run() int
        \\    var calls = 0
        \\    var empty: Array(int, 0) = Array(int, 0).filled(next(calls)) else panic "unexpected none"
        \\    if (empty.get(-1) is int) -> return 90
        \\    if (empty.get(0) is int) -> return 91
        \\    if (empty.get(0) is int) -> return 92
        \\    if empty.len() <> 0 -> return 93
        \\    return calls + 41
    , 42);
}

test "Array populated bounds reject negative and past end indices" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    var values: Array(int, 2) = Array(int, 2).filled(42) else panic "unexpected none"
        \\    if (values.get(-1) is int) -> return 90
        \\    if (values.get(2) is int) -> return 91
        \\    if (values.get(-1) is int) -> return 92
        \\    if (values.get(2) is int) -> return 93
        \\    if ref last: int = values.get(1) -> return last
        \\    return 94
    , 42);
}

test "Array nested fill and element borrows retain shape" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    const row: Array(int, 3) = Array(int, 3).filled(42) else panic "unexpected none"
        \\    const matrix: Array(Array(int, 3), 2) = Array(Array(int, 3), 2).filled(row) else panic "unexpected none"
        \\    if ref selected: Array(int, 3) = matrix.get(1)
        \\        if ref cell: int = selected.get(2) -> return cell
        \\    return 90
    , 42);
}

test "Array fill and whole copy invoke immovable element custom copies" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\struct Item
        \\    move = none
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func run() int
        \\    const original = Item{value = 40}
        \\    const values: Array(Item, 3) = Array(Item, 3).filled(original) else panic "unexpected none"
        \\    const copied = values.copy()
        \\    if original.value <> 40 -> return 90
        \\    if ref selected: Item = copied.get(2) -> return selected.value
        \\    return 91
    , 42);
}

test "Array whole move invokes element custom moves" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\struct Item
        \\    value: int
        \\    copy = fieldwise
        \\    move = func(deinit self: Item) Item -> Item{value = self.value + 1}
        \\func run() int
        \\    const original = Item{value = 41}
        \\    const values: Array(Item, 3) = Array(Item, 3).filled(original) else panic "unexpected none"
        \\    const moved = values.move()
        \\    if ref selected: Item = moved.get(2) -> return selected.value
        \\    return 90
    , 42);
}

test "Array nested whole copies invoke every element custom copy" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func run() int
        \\    const original = Item{value = 39}
        \\    const row: Array(Item, 3) = Array(Item, 3).filled(original) else panic "unexpected none"
        \\    const matrix: Array(Array(Item, 3), 2) = Array(Array(Item, 3), 2).filled(row) else panic "unexpected none"
        \\    const copied = matrix.copy()
        \\    if ref selected: Array(Item, 3) = copied.get(1)
        \\        if ref cell: Item = selected.get(2) -> return cell.value
        \\    return 90
    , 42);
}

test "Array automatic cleanup drops elements in reverse index order" {
    try Fixture.expectSourceExit(
        \\import std.array.{Array}
        \\struct Item
        \\    value: int
        \\    copy = fieldwise
        \\    drop = func(deinit self: Item)
        \\        if self.value == 41 -> exit(41)
        \\        if self.value == 42 -> exit(42)
        \\func run()
        \\    var values: Array(Item, 2) = Array(Item, 2).filled(Item{value = 0}) else panic "unexpected none"
        \\    if ref first: Item = values.get(0) -> first = Item{value = 41}
        \\    if ref last: Item = values.get(1) -> last = Item{value = 42}
        \\    if ref first: Item = values.get(0)
        \\        if ref last: Item = values.get(1)
        \\            if first.value + last.value <> 83 -> exit(90)
        \\run()
        \\exit(91)
    , 42);
}

test "Array empty cleanup does not call element destructors" {
    try Fixture.expectSourceExit(
        \\import std.array.{Array}
        \\struct Item
        \\    copy = trivial
        \\    drop = func(deinit self: Item) -> exit(90)
        \\func run(deinit original: Item) int
        \\    const empty: Array(Item, 0) = Array(Item, 0).filled(original) else panic "unexpected none"
        \\    return empty.len() + 42
        \\exit(run(Item{}))
    , 42);
}

test "Array filled rejects noncopyable elements even for zero length" {
    for ([_]u32{ 0, 2 }) |length| {
        const source = try testing.allocator.print(
            \\import std.array.{{Array}}
            \\struct Item
            \\    copy = none
            \\const original = Item{{}}
            \\const values = Array(Item, {d}).filled(original)
            \\exit(values.len())
        , .{length});
        defer testing.allocator.free(source);
        try Fixture.expectRejected(source);
    }
}

test "Array owning elements retain explicit drop obligations" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.array.{Array}
        \\struct Item
        \\    copy = trivial
        \\    drop = explicit
        \\func run(imm original: Item) int
        \\    const values: Array(Item, 2) = Array(Item, 2).filled(original) else panic "unexpected none"
        \\    return values.len()
        \\exit(run(Item{}))
    , .value_requires_explicit_drop);
}

test "Array borrowed element cannot escape its local array" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\func bad() Ref(int)
        \\    const values: Array(int, 2) = Array(int, 2).filled(42) else panic "unexpected none"
        \\    if ref selected: int = values.get(1) -> return Ref.from(selected)
        \\    return bad()
        \\const reference = bad()
        \\exit(reference.value)
    , .borrow_outlives_source);
}

test "Array fill cannot return references to a local source" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\func bad() Array(Ref(int), 2)
        \\    const value = 42
        \\    return (if const _selected_result_0: Array(Ref(int), 2) = Array(Ref(int), 2).filled(Ref.from(value)) -> _selected_result_0^ else panic "unexpected none")
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array fill and nested reference reads preserve runtime source dependencies" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\func fill(imm source: Ref(int)) Array(Ref(int), 2)
        \\    return (if const _selected_result_0: Array(Ref(int), 2) = Array(Ref(int), 2).filled(source) -> _selected_result_0^ else panic "unexpected none")
        \\func run() int
        \\    const value = 42
        \\    const values = fill((if const _selected_result_1: Ref(int) = Ref.from(value) -> _selected_result_1 else panic "unexpected none"))
        \\    if ref selected: Ref(int) = values.get(1) -> return selected.value
        \\    return 90
    , 42);
}

test "Array get_mut requires mutable source storage" {
    try Fixture.expectRejected(
        \\import std.array.{Array}
        \\const values: Array(int, 2) = Array(int, 2).filled(42) else panic "unexpected none"
        \\if ref selected: int = values.get(0) -> selected = 1
        \\exit(42)
    );
}

test "Array copy hooks cannot invalidate pending borrows" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\struct Handle
        \\    target: Ref(Box(int))
        \\    copy = func(imm self: Handle) Handle
        \\        if const replacement: Box(int) = Box.new(17) -> self.target.value = replacement^
        \\        return Handle{target = self.target}
        \\func inspect(imm earlier: Ref(int), imm values: Array(Handle, 2)) int -> earlier.value + values.len()
        \\func run() int | none
        \\    var owner: Box(Box(int)) = Box.new((if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else panic "unexpected none")) else return none
        \\    var source = Handle{target = Ref.from(owner.borrow())}
        \\    const values: Array(Handle, 2) = Array(Handle, 2).filled(source) else return none
        \\    return inspect(Ref.from(owner.borrow().borrow()), values.copy())
        \\if const result: int = run() -> exit(result) else exit(90)
    , .borrow_outlives_source);
}

test "Array static nested values publish into runtime storage" {
    try Fixture.expectSourceExit(
        \\static row = (if const _selected_result_0: Array(int, 2) = Array(int, 2).filled(20) -> _selected_result_0^ else panic "unexpected none")
        \\static matrix = (if const _selected_result_1: Array(Array(int, 2), 2) = Array(Array(int, 2), 2).filled(row) -> _selected_result_1^ else panic "unexpected none")
        \\func run() int
        \\    const values = matrix
        \\    if ref selected: Array(int, 2) = values.get(1)
        \\        if ref value: int = selected.get(0) -> return value + row.len() + 20
        \\    return 90
        \\exit(run())
    , 42);
}

test "Array zero-sized fill does not skip custom copy" {
    try Fixture.expectSourceExit(
        \\struct Empty
        \\    copy = func(imm self: Empty) Empty -> exit(42)
        \\func run() int
        \\    const values: Array(Empty, 3) = Array(Empty, 3).filled(Empty{}) else panic "unexpected none"
        \\    return values.len()
        \\exit(run())
    , 42);
}

test "Array embedded storage supports checked mutable access" {
    try Fixture.expectParity(
        \\struct Holder
        \\    values: Array(int, 3)
        \\    copy = fieldwise
        \\func run() int
        \\    var holder = Holder{values = (if const _selected_result_0: Array(int, 3) = Array(int, 3).filled(20) -> _selected_result_0^ else panic "unexpected none")}
        \\    if ref selected: int = holder.values.get(1) -> selected = 22
        \\    else return 90
        \\    const copied = holder.copy()
        \\    if ref selected: int = copied.values.get(1) -> return selected + 20
        \\    return 91
    , 42);
}

test "Array boxed inline storage retains mutable element references" {
    try Fixture.expectParity(
        \\import std.memory
        \\func calculate() int | none
        \\    var owner: Box(Array(int, 3)) = Box.new((if const _selected_result_0: Array(int, 3) = Array(int, 3).filled(20) -> _selected_result_0^ else panic "unexpected none")) else return none
        \\    var values: Ref(Array(int, 3)) = Ref.from(owner.borrow()) else return none
        \\    if ref selected: int = values.value.get(1) -> selected = 22
        \\    else return 90
        \\    if ref selected: int = values.value.get(1) -> return selected + 20
        \\    return 91
        \\func run() int
        \\    if const answer: int = calculate() -> return answer
        \\    return 92
    , 42);
}

test "Array variant payload copies immovable nested elements in place" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    move = none
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func widen(imm values: Array(Item, 2)) Array(Item, 2) | none -> values
        \\func run() int
        \\    const values: Array(Item, 2) = Array(Item, 2).filled(Item{value = 39}) else panic "unexpected none"
        \\    const possible = widen(values)
        \\    if const selected: Array(Item, 2) = possible
        \\        if ref element: Item = selected.get(1) -> return element.value
        \\    return 90
    , 42);
}

test "Array zero-sized logical elements retain custom destruction" {
    try Fixture.expectSourceExit(
        \\struct Empty
        \\    copy = trivial
        \\    drop = func(deinit self: Empty) -> exit(42)
        \\func run(deinit source: Empty)
        \\    const values: Array(Empty, 3) = Array(Empty, 3).filled(source) else panic "unexpected none"
        \\    _ = values.len()
        \\run(Empty{})
        \\exit(90)
    , 42);
}

test "Array whole copies retain contained reference origins" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func duplicate(imm values: Array(Ref(int), 2)) Array(Ref(int), 2)
        \\    return values.copy()
        \\func run() int
        \\    const source = 42
        \\    const original: Array(Ref(int), 2) = Array(Ref(int), 2).filled((if const _selected_result_0: Ref(int) = Ref.from(source) -> _selected_result_0 else panic "unexpected none")) else panic "unexpected none"
        \\    const values = duplicate(original)
        \\    if ref selected: Ref(int) = values.get(1) -> return selected.value
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Ref}
        \\func bad() Array(Ref(int), 2)
        \\    const source = 42
        \\    const values: Array(Ref(int), 2) = Array(Ref(int), 2).filled(Ref.from(source)) else panic "unexpected none"
        \\    return values.copy()
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array element references observe whole storage replacement" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values: Array(int, 2) = Array(int, 2).filled(42) else panic "unexpected none"
        \\    if ref selected: int = values.get(1)
        \\        values = (if const _selected_result_0: Array(int, 2) = Array(int, 2).filled(17) -> _selected_result_0^ else panic "unexpected none")
        \\        return selected
        \\    return 90
        \\exit(run())
    , 17);
}

test "Array fill invokes an ordinary copy for each initialized element" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func calculate() int | none
        \\    const source = Item{value = 20}
        \\    const values: Array(Item, 2) = Array(Item, 2).filled(source) else return none
        \\    ref first: Item = values.get(0) else return none
        \\    ref second: Item = values.get(1) else return none
        \\    return first.value + second.value
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "mutable alias call arguments write direct values back to their referents" {
    try Fixture.expectParity(
        \\import std.memory
        \\func advance(mut value: int)
        \\    value += 2
        \\func run() int
        \\    var source = 40
        \\    var selected: Ref(int) = Ref.from(source) else panic "unexpected none"
        \\    advance(selected.value)
        \\    return source
    , 42);
}

test "Array mutable alias calls retain newly stored reference origins" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = (if const _selected_result_0: Array(Ref(int), 1) = Array(Ref(int), 1).filled(reference) -> _selected_result_0^ else panic "unexpected none")
        \\func run() int
        \\    const original = 42
        \\    var values: Array(Ref(int), 1) = Array(Ref(int), 1).filled(Ref.from(original)) else panic "unexpected none"
        \\    if 1 == 1
        \\        const temporary = 17
        \\        ref selected = values
        \\        overwrite(selected, Ref.from(temporary))
        \\    if ref selected: Ref(int) = values.get(0) -> return selected.value
        \\    return 90
        \\exit(run())
    , .borrow_outlives_source);
}

test "Array dereferenced mutable aliases cannot retain short-lived references" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = (if const _selected_result_0: Array(Ref(int), 1) = Array(Ref(int), 1).filled(reference) -> _selected_result_0^ else panic "unexpected none")
        \\func run() int | none
        \\    const original = 42
        \\    var owner: Box(Array(Ref(int), 1)) = Box.new((if const _selected_result_1: Array(Ref(int), 1) = Array(Ref(int), 1).filled(Ref.from(original)) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\    if 1 == 1
        \\        const temporary = 17
        \\        var selected = Ref.from(owner.borrow())
        \\        overwrite(selected.value, Ref.from(temporary))
        \\    var selected = Ref.from(owner.borrow())
        \\    if ref element: Ref(int) = selected.value.get(0) -> return element.value
        \\    return 90
        \\if const answer: int = run() -> exit(answer) else exit(91)
    , .borrow_outlives_source);
}

test "Array boxed mutable aliases retain long-lived reference origins" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = (if const _selected_result_0: Array(Ref(int), 1) = Array(Ref(int), 1).filled(reference) -> _selected_result_0^ else panic "unexpected none")
        \\func run() int | none
        \\    const original = 17
        \\    const replacement = 42
        \\    var owner: Box(Array(Ref(int), 1)) = Box.new((if const _selected_result_1: Array(Ref(int), 1) = Array(Ref(int), 1).filled(Ref.from(original)) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\    if 1 == 1
        \\        var selected = Ref.from(owner.borrow())
        \\        overwrite(selected.value, Ref.from(replacement))
        \\    var selected = Ref.from(owner.borrow())
        \\    if ref element: Ref(int) = selected.value.get(0) -> return element.value
        \\    return 90
        \\if const answer: int = run() -> exit(answer) else exit(91)
    , 42);
}

test "Array reference parameters retain caller origins when storing other inputs" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = (if const _selected_result_0: Array(Ref(int), 1) = Array(Ref(int), 1).filled(reference) -> _selected_result_0^ else panic "unexpected none")
        \\func change(var target: Ref(Array(Ref(int), 1)), replacement: Ref(int))
        \\    var selected = Ref.from(target.value)
        \\    overwrite(selected.value, replacement)
        \\func run() int | none
        \\    const original = 42
        \\    var owner: Box(Array(Ref(int), 1)) = Box.new((if const _selected_result_1: Array(Ref(int), 1) = Array(Ref(int), 1).filled(Ref.from(original)) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\    change(Ref.from(owner.borrow()), Ref.from(original))
        \\    return 42
        \\if const answer: int = run() -> exit(answer) else exit(91)
    , 42);
}

test "compile-time direct scalar arguments copy caller storage before mutation" {
    try Fixture.expectParity(
        \\func observe(imm captured: int, var target: Ref(int)) int
        \\    target.value = 22
        \\    return captured + 22
        \\func run() int
        \\    var values: Array(int, 1) = Array(int, 1).filled(20) else panic "unexpected none"
        \\    if ref target: int = values.get(0) -> return observe(target, (if const _selected_result_0: Ref(int) = Ref.from(target) -> _selected_result_0 else panic "unexpected none"))
        \\    return 90
    , 42);
}

test "compile-time variant coercion preserves returned reference payloads" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int)) Ref(int) | none -> reference
        \\func run() int
        \\    const values: Array(int, 1) = Array(int, 1).filled(42) else panic "unexpected none"
        \\    if ref reference: int = values.get(0)
        \\        if const selected: Ref(int) = choose((if const _selected_result_0: Ref(int) = Ref.from(reference) -> _selected_result_0 else panic "unexpected none")) -> return selected.value
        \\    return 90
    , 42);
}

test "Array immutable arguments permit widening address-passed movable values" {
    try Fixture.expectParity(
        \\func inspect(imm possible: Array(int, 2) | none) int
        \\    if const values: Array(int, 2) = possible
        \\        if ref selected: int = values.get(1) -> return selected
        \\    return 90
        \\func run() int
        \\    const values: Array(int, 2) = Array(int, 2).filled(42) else panic "unexpected none"
        \\    return inspect(values)
    , 42);
}

test "compile-time direct reference arguments copy handles without copying referents" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func retarget(mut reference: Ref(int), imm replacement: Ref(int))
        \\    reference = replacement
        \\func run() int
        \\    const original = 20
        \\    const replacement = 22
        \\    var reference: Ref(int) = Ref.from(original) else panic "unexpected none"
        \\    const captured = reference
        \\    retarget(reference, (if const _selected_result_0: Ref(int) = Ref.from(replacement) -> _selected_result_0 else panic "unexpected none"))
        \\    return captured.value + reference.value
    , 42);
}

test "compile-time reference variants support widening and conditional results" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int)) Ref(int) | none
        \\    return if 1 == 1 -> reference else none
        \\func widen(imm possible: Ref(int) | none) Ref(int) | none | bool -> possible
        \\func run() int
        \\    const values: Array(int, 1) = Array(int, 1).filled(42) else panic "unexpected none"
        \\    if ref reference: int = values.get(0)
        \\        const possible = choose((if const _selected_result_0: Ref(int) = Ref.from(reference) -> _selected_result_0 else panic "unexpected none"))
        \\        if const selected: Ref(int) = widen(possible) -> return selected.value
        \\    return 90
    , 42);
}
