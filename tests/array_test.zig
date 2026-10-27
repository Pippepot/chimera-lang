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
        \\    match values.get(0)
        \\        first and first is int ->
        \\            match values.get(1)
        \\                second and second is int ->
        \\                    match values.get(-1)
        \\                        invalid and invalid is int -> return 91
        \\                        _ -> ()
        \\                    match values.get(2)
        \\                        invalid and invalid is int -> return 92
        \\                        _ -> ()
        \\                    const empty: Array(int, 0) = []
        \\                    match empty.get(0)
        \\                        invalid and invalid is int -> return 93
        \\                        _ -> ()
        \\                    return first + second - 1
        \\                _ -> ()
        \\        _ -> ()
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
        \\    match values.get(1)
        \\        ref _matched_reference and _matched_reference is int ->
        \\            ref reference = _matched_reference
        \\            reference += 1
        \\            reference *= 2
        \\            reference -= 2
        \\            reference /= 2
        \\        _ -> ()
        \\    return values[0] + values[1] + 11
        \\func run() int
        \\    match calculate()
        \\        calculated and calculated is int -> return calculated
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "operation indexing List reads replacements and bounds use ordinary calls" {
    try Fixture.expectSourceExit(
        \\func calculate() int | none
        \\    var values: List(int) = [19, 23]
        \\    values[0] += 1
        \\    match values.get(2)
        \\        invalid and invalid is int -> return 91
        \\        _ -> ()
        \\    return values[0] + values[1] - 1
        \\func run() int
        \\    match calculate()
        \\        calculated and calculated is int -> return calculated
        \\        _ -> ()
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
        \\    match values.get(0)
        \\        stored and stored is int -> return stored
        \\        _ -> ()
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
            \\    match calculate()
            \\        result -> return result
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
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
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
        \\    match trace.get(0)
        \\        ref _matched_handle and _matched_handle is int ->
        \\            ref handle = _matched_handle
        \\            var sink = Sink{}
        \\            match sink.replace(99, Item{trace = Ref.from(handle), value = 42})
        \\                filtered_value_81 and filtered_value_81 is unit -> return 90
        \\                _ -> ()
        \\            return handle
        \\        _ -> ()
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
        \\    match values.get(99)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            target = replacement(calls)
        \\        _ -> ()
        \\    match values.get(0)
        \\        first and first is int -> return first + calls + 22
        \\        _ -> ()
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
        \\    const result = values.get(0)
        \\    match result
        \\        Item ->
        \\            const selected = result
        \\            return selected.value
        \\        _ -> ()
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
        \\    match original.get(0)
        \\        ref _matched_item and _matched_item is int ->
        \\            ref item = _matched_item
        \\            var values = [Ref.from(item)]
        \\            values[0] = Ref.from(item)
        \\            ref stored = values[0]
        \\            stored.value = 42
        \\            return item
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
        \\    return 91
    , 42);
}

test "operation indexing List and views use the same operator contract" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func calculate() int | none
        \\    var values = List(int).new(2)
        \\    if not (values is List(int)) -> return none
        \\    const checked_value_2 = values.append(19)
        \\    if not (checked_value_2 is unit) -> return none
        \\    const checked_value_3 = values.append(23)
        \\    if not (checked_value_3 is unit) -> return none
        \\    values[0] += 1
        \\    const view = values.slice(0..2)
        \\    if not (view is Span(int)) -> return none
        \\    return view[0] + view[1] - 1
        \\func run() int
        \\    match calculate()
        \\        calculated and calculated is int -> return calculated
        \\        _ -> ()
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
        \\    match values.get(0)
        \\        ref _matched_first and _matched_first is int ->
        \\            ref first = _matched_first
        \\            first = 20
        \\        _ -> ()
        \\    match values.get(0)
        \\        ref _matched_first and _matched_first is int ->
        \\            ref first = _matched_first
        \\            match values.get(1)
        \\                ref _matched_second and _matched_second is int ->
        \\                    ref second = _matched_second
        \\                    return first + second + empty.len() + bytes.len() - 3
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    , 42);
}

test "List growth retains zero-sized logical elements and their destruction" {
    try Fixture.expectParity(
        \\struct Item
        \\    drop = func(deinit self: Item) -> exit(42)
        \\func exercise() int | none
        \\    var values = List(Item).new(0)
        \\    if not (values is List(Item)) -> return none
        \\    const checked_value_2 = values.append(Item{})
        \\    if not (checked_value_2 is unit) -> return none
        \\    const checked_value_3 = values.append(Item{})
        \\    if not (checked_value_3 is unit) -> return none
        \\    const checked_value_4 = values.append(Item{})
        \\    if not (checked_value_4 is unit) -> return none
        \\    if values.len() <> 3 -> exit(91)
        \\    if values.capacity() <> 4 -> exit(92)
        \\    return 93
        \\func run() int
        \\    match exercise()
        \\        result and result is int -> return result
        \\        _ -> ()
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
        \\    const checked_value_1 = missing(trace)
        \\    if not (checked_value_1 is Item) -> return none
        \\    skipped(trace)
        \\    return unit
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if not (trace is Array(int, 1)) -> panic "unexpected none"
        \\    match trace.get(0)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            match construct(Ref.from(target))
        \\                filtered_value_153 and filtered_value_153 is unit -> return 92
        \\                _ -> ()
        \\        _ -> ()
        \\    match trace.get(0)
        \\        ref _matched_result and _matched_result is int ->
        \\            ref result = _matched_result
        \\            return result
        \\        _ -> ()
        \\    return 93
        \\exit(run())
    , 42);
}

test "List explicit factory infers length and optional elements remain ordinary data" {
    try Fixture.expectSourceExit(
        \\func missing() int | none -> return none
        \\func run() int
        \\    match List(int).from([19, 23])
        \\        values and values is List(int) ->
        \\            match values.get(0)
        \\                ref _matched_first and _matched_first is int ->
        \\                    ref first = _matched_first
        \\                    match values.get(1)
        \\                        ref _matched_second and _matched_second is int ->
        \\                            ref second = _matched_second
        \\                            const optional = List(int | none).from([missing()])
        \\                            if not (optional is List(int | none)) -> return 91
        \\                            match optional[0]
        \\                                filtered_value_75 and filtered_value_75 is none -> return first + second
        \\                                _ -> ()
        \\                            return 92
        \\                        _ -> ()
        \\                _ -> ()
        \\        _ -> ()
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
        \\    match List(Array(int, 262144)).from([skipped()])
        \\        values and values is List(Array(int, 262144)) -> return 92
        \\        _ -> ()
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
        \\    const checked_value_1 = missing(trace)
        \\    if not (checked_value_1 is Item) -> return none
        \\    return unit
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if not (trace is Array(int, 1)) -> panic "unexpected none"
        \\    match trace.get(0)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            var iteration = 0
        \\            loop
        \\                if iteration == 384 -> break
        \\                target = 0
        \\                match construct(Ref.from(target))
        \\                    filtered_value_145 and filtered_value_145 is unit -> return 91
        \\                    _ -> ()
        \\                if target == 42
        \\                    iteration += 1
        \\                else
        \\                    return 92
        \\            target = 0
        \\            const complete: List(Item) = [Item{trace = Ref.from(target), value = 2}, Item{trace = Ref.from(target), value = 4}]
        \\            complete.len()
        \\        _ -> ()
        \\    match trace.get(0)
        \\        ref _matched_result and _matched_result is int ->
        \\            ref result = _matched_result
        \\            return result
        \\        _ -> ()
        \\    return 93
        \\exit(run())
    , 42);
}

test "List construction and borrowing preserve stored external reference origins" {
    try Fixture.expectSourceExit(
        \\func make(imm value: Ref(int)) List(Ref(int)) -> [value]
        \\func run() int
        \\    const original = Array(int, 1).filled(42)
        \\    if not (original is Array(int, 1)) -> panic "unexpected none"
        \\    match original.get(0)
        \\        ref _matched_reference and _matched_reference is int ->
        \\            ref reference = _matched_reference
        \\            const values = make(Ref.from(reference))
        \\            match values.get(0)
        \\                ref _matched_stored and _matched_stored is Ref(int) ->
        \\                    ref stored = _matched_stored
        \\                    const result = stored
        \\                    return result.value
        \\                _ -> ()
        \\        _ -> ()
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
        \\    var trace = Array(int, 1).filled(0)
        \\    if not (trace is Array(int, 1)) -> panic "unexpected none"
        \\    match trace.get(0)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            match count([element(Ref.from(target)), element(Ref.from(target))
        \\            ])
        \\                size and size is int -> return target + size + 38
        \\                _ -> ()
        \\        _ -> ()
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
        \\    match values.get(0)
        \\        ref _matched_first and _matched_first is int ->
        \\            ref first = _matched_first
        \\            match nested.get(0)
        \\                ref _matched_last and _matched_last is Array(int, 2) ->
        \\                    ref last = _matched_last
        \\                    match last.get(1)
        \\                        ref _matched_second and _matched_second is int ->
        \\                            ref second = _matched_second
        \\                            return first + second + empty.len() + bytes.len() - 2
        \\                        _ -> ()
        \\                _ -> ()
        \\        _ -> ()
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
        \\    const checked_value_1 = missing(trace)
        \\    if not (checked_value_1 is Item) -> return none
        \\    skipped(trace)
        \\    return unit
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if not (trace is Array(int, 1)) -> panic "unexpected none"
        \\    match trace.get(0)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            match construct(Ref.from(target))
        \\                filtered_value_154 and filtered_value_154 is unit -> return 92
        \\                _ -> ()
        \\        _ -> ()
        \\    match trace.get(0)
        \\        ref _matched_result and _matched_result is int ->
        \\            ref result = _matched_result
        \\            return result
        \\        _ -> ()
        \\    return 93
    , 42);
}

test "Array integer fill get and get_mut have native and comptime parity" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    var values = Array(int, 3).filled(20)
        \\    if not (values is Array(int, 3)) -> panic "unexpected none"
        \\    match values.get(1)
        \\        ref _matched_middle and _matched_middle is int ->
        \\            ref middle = _matched_middle
        \\            middle = 22
        \\        _ -> return 90
        \\    match values.get(0)
        \\        ref _matched_first and _matched_first is int ->
        \\            ref first = _matched_first
        \\            match values.get(1)
        \\                ref _matched_middle and _matched_middle is int ->
        \\                    ref middle = _matched_middle
        \\                    return first + middle
        \\                _ -> ()
        \\        _ -> ()
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
        \\    const values = Array(int, 4).filled(next(calls))
        \\    if not (values is Array(int, 4)) -> panic "unexpected none"
        \\    match values.get(3)
        \\        ref _matched_last and _matched_last is int ->
        \\            ref last = _matched_last
        \\            return last + calls
        \\        _ -> ()
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
        \\    var empty = Array(int, 0).filled(next(calls))
        \\    if not (empty is Array(int, 0)) -> panic "unexpected none"
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
        \\    var values = Array(int, 2).filled(42)
        \\    if not (values is Array(int, 2)) -> panic "unexpected none"
        \\    if (values.get(-1) is int) -> return 90
        \\    if (values.get(2) is int) -> return 91
        \\    if (values.get(-1) is int) -> return 92
        \\    if (values.get(2) is int) -> return 93
        \\    match values.get(1)
        \\        ref _matched_last and _matched_last is int ->
        \\            ref last = _matched_last
        \\            return last
        \\        _ -> ()
        \\    return 94
    , 42);
}

test "Array nested fill and element borrows retain shape" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    const row = Array(int, 3).filled(42)
        \\    if not (row is Array(int, 3)) -> panic "unexpected none"
        \\    const matrix = Array(Array(int, 3), 2).filled(row)
        \\    if not (matrix is Array(Array(int, 3), 2)) -> panic "unexpected none"
        \\    match matrix.get(1)
        \\        ref _matched_selected and _matched_selected is Array(int, 3) ->
        \\            ref selected = _matched_selected
        \\            match selected.get(2)
        \\                ref _matched_cell and _matched_cell is int ->
        \\                    ref cell = _matched_cell
        \\                    return cell
        \\                _ -> ()
        \\        _ -> ()
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
        \\    const values = Array(Item, 3).filled(original)
        \\    if not (values is Array(Item, 3)) -> panic "unexpected none"
        \\    const copied = values.copy()
        \\    if original.value <> 40 -> return 90
        \\    match copied.get(2)
        \\        ref _matched_selected and _matched_selected is Item ->
        \\            ref selected = _matched_selected
        \\            return selected.value
        \\        _ -> ()
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
        \\    const values = Array(Item, 3).filled(original)
        \\    if not (values is Array(Item, 3)) -> panic "unexpected none"
        \\    const moved = values.move()
        \\    match moved.get(2)
        \\        ref _matched_selected and _matched_selected is Item ->
        \\            ref selected = _matched_selected
        \\            return selected.value
        \\        _ -> ()
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
        \\    const row = Array(Item, 3).filled(original)
        \\    if not (row is Array(Item, 3)) -> panic "unexpected none"
        \\    const matrix = Array(Array(Item, 3), 2).filled(row)
        \\    if not (matrix is Array(Array(Item, 3), 2)) -> panic "unexpected none"
        \\    const copied = matrix.copy()
        \\    match copied.get(1)
        \\        ref _matched_selected and _matched_selected is Array(Item, 3) ->
        \\            ref selected = _matched_selected
        \\            match selected.get(2)
        \\                ref _matched_cell and _matched_cell is Item ->
        \\                    ref cell = _matched_cell
        \\                    return cell.value
        \\                _ -> ()
        \\        _ -> ()
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
        \\    var values = Array(Item, 2).filled(Item{value = 0})
        \\    if not (values is Array(Item, 2)) -> panic "unexpected none"
        \\    match values.get(0)
        \\        ref _matched_first and _matched_first is Item ->
        \\            ref first = _matched_first
        \\            first = Item{value = 41}
        \\        _ -> ()
        \\    match values.get(1)
        \\        ref _matched_last and _matched_last is Item ->
        \\            ref last = _matched_last
        \\            last = Item{value = 42}
        \\        _ -> ()
        \\    match values.get(0)
        \\        ref _matched_first and _matched_first is Item ->
        \\            ref first = _matched_first
        \\            match values.get(1)
        \\                ref _matched_last and _matched_last is Item ->
        \\                    ref last = _matched_last
        \\                    if first.value + last.value <> 83 -> exit(90)
        \\                _ -> ()
        \\        _ -> ()
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
        \\    const empty = Array(Item, 0).filled(original)
        \\    if not (empty is Array(Item, 0)) -> panic "unexpected none"
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
        \\    const values = Array(Item, 2).filled(original)
        \\    if not (values is Array(Item, 2)) -> panic "unexpected none"
        \\    return values.len()
        \\exit(run(Item{}))
    , .value_requires_explicit_drop);
}

test "Array borrowed element cannot escape its local array" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\func bad() Ref(int)
        \\    const values = Array(int, 2).filled(42)
        \\    if not (values is Array(int, 2)) -> panic "unexpected none"
        \\    match values.get(1)
        \\        ref _matched_selected and _matched_selected is int ->
        \\            ref selected = _matched_selected
        \\            return Ref.from(selected)
        \\        _ -> ()
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
        \\    return Array(Ref(int), 2).filled(Ref.from(value))
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array fill and nested reference reads preserve runtime source dependencies" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\func fill(imm source: Ref(int)) Array(Ref(int), 2)
        \\    return Array(Ref(int), 2).filled(source)
        \\func run() int
        \\    const value = 42
        \\    const values = fill(Ref.from(value))
        \\    match values.get(1)
        \\        ref _matched_selected and _matched_selected is Ref(int) ->
        \\            ref selected = _matched_selected
        \\            return selected.value
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "Array get_mut requires mutable source storage" {
    try Fixture.expectRejected(
        \\import std.array.{Array}
        \\const values = Array(int, 2).filled(42)
        \\if not (values is Array(int, 2)) -> panic "unexpected none"
        \\match values.get(0)
        \\    ref _matched_selected and _matched_selected is int ->
        \\        ref selected = _matched_selected
        \\        selected = 1
        \\    _ -> ()
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
        \\        match Box.new(17)
        \\            replacement and replacement is Box(int) -> self.target.value = replacement^
        \\            _ -> ()
        \\        return Handle{target = self.target}
        \\func inspect(imm earlier: Ref(int), imm values: Array(Handle, 2)) int -> earlier.value + values.len()
        \\func run() int | none
        \\    var owner = Box.new(((match Box.new(42)
        \\        _selected_result_0 and _selected_result_0 is Box(int) -> _selected_result_0^
        \\        _ -> panic "unexpected none")))
        \\    if not (owner is Box(Box(int))) -> return none
        \\    var source = Handle{target = Ref.from(owner.borrow())}
        \\    const values = Array(Handle, 2).filled(source)
        \\    if not (values is Array(Handle, 2)) -> return none
        \\    return inspect(Ref.from(owner.borrow().borrow()), values.copy())
        \\match run()
        \\    result and result is int -> exit(result)
        \\    _ -> exit(90)
    , .borrow_outlives_source);
}

test "Array static nested values publish into runtime storage" {
    try Fixture.expectSourceExit(
        \\static row = Array(int, 2).filled(20)
        \\static matrix = Array(Array(int, 2), 2).filled(row)
        \\func run() int
        \\    const values = matrix
        \\    match values.get(1)
        \\        ref _matched_selected and _matched_selected is Array(int, 2) ->
        \\            ref selected = _matched_selected
        \\            match selected.get(0)
        \\                ref _matched_value and _matched_value is int ->
        \\                    ref value = _matched_value
        \\                    return value + row.len() + 20
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    , 42);
}

test "Array zero-sized fill does not skip custom copy" {
    try Fixture.expectSourceExit(
        \\struct Empty
        \\    copy = func(imm self: Empty) Empty -> exit(42)
        \\func run() int
        \\    const values = Array(Empty, 3).filled(Empty{})
        \\    if not (values is Array(Empty, 3)) -> panic "unexpected none"
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
        \\    var holder = Holder{values = Array(int, 3).filled(20)}
        \\    match holder.values.get(1)
        \\        ref _matched_selected and _matched_selected is int ->
        \\            ref selected = _matched_selected
        \\            selected = 22
        \\        _ -> return 90
        \\    const copied = holder.copy()
        \\    match copied.values.get(1)
        \\        ref _matched_selected and _matched_selected is int ->
        \\            ref selected = _matched_selected
        \\            return selected + 20
        \\        _ -> ()
        \\    return 91
    , 42);
}

test "Array boxed inline storage retains mutable element references" {
    try Fixture.expectParity(
        \\import std.memory
        \\func calculate() int | none
        \\    var owner = Box.new(Array(int, 3).filled(20))
        \\    if not (owner is Box(Array(int, 3))) -> return none
        \\    var values = Ref.from(owner.borrow())
        \\    if not (values is Ref(Array(int, 3))) -> return none
        \\    match values.value.get(1)
        \\        ref _matched_selected and _matched_selected is int ->
        \\            ref selected = _matched_selected
        \\            selected = 22
        \\        _ -> return 90
        \\    match values.value.get(1)
        \\        ref _matched_selected and _matched_selected is int ->
        \\            ref selected = _matched_selected
        \\            return selected + 20
        \\        _ -> ()
        \\    return 91
        \\func run() int
        \\    match calculate()
        \\        answer and answer is int -> return answer
        \\        _ -> ()
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
        \\    const values = Array(Item, 2).filled(Item{value = 39})
        \\    if not (values is Array(Item, 2)) -> panic "unexpected none"
        \\    const possible = widen(values)
        \\    match possible
        \\        Array(Item, 2) ->
        \\            const selected = possible
        \\            match selected.get(1)
        \\                ref _matched_element and _matched_element is Item ->
        \\                    ref element = _matched_element
        \\                    return element.value
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "Array zero-sized logical elements retain custom destruction" {
    try Fixture.expectSourceExit(
        \\struct Empty
        \\    copy = trivial
        \\    drop = func(deinit self: Empty) -> exit(42)
        \\func run(deinit source: Empty)
        \\    const values = Array(Empty, 3).filled(source)
        \\    if not (values is Array(Empty, 3)) -> panic "unexpected none"
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
        \\    const original = Array(Ref(int), 2).filled(Ref.from(source))
        \\    if not (original is Array(Ref(int), 2)) -> panic "unexpected none"
        \\    const values = duplicate(original)
        \\    match values.get(1)
        \\        ref _matched_selected and _matched_selected is Ref(int) ->
        \\            ref selected = _matched_selected
        \\            return selected.value
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Ref}
        \\func bad() Array(Ref(int), 2)
        \\    const source = 42
        \\    const values = Array(Ref(int), 2).filled(Ref.from(source))
        \\    if not (values is Array(Ref(int), 2)) -> panic "unexpected none"
        \\    return values.copy()
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array element references observe whole storage replacement" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = Array(int, 2).filled(42)
        \\    if not (values is Array(int, 2)) -> panic "unexpected none"
        \\    match values.get(1)
        \\        ref _matched_selected and _matched_selected is int ->
        \\            ref selected = _matched_selected
        \\            values = Array(int, 2).filled(17)
        \\            return selected
        \\        _ -> ()
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
        \\    const values = Array(Item, 2).filled(source)
        \\    if not (values is Array(Item, 2)) -> return none
        \\    const checked_value_2 = values.get(0)
        \\    if not (checked_value_2 is Item) -> return none
        \\    ref first = checked_value_2
        \\    const checked_value_3 = values.get(1)
        \\    if not (checked_value_3 is Item) -> return none
        \\    ref second = checked_value_3
        \\    return first.value + second.value
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
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
        \\    var selected = Ref.from(source)
        \\    if not (selected is Ref(int)) -> panic "unexpected none"
        \\    advance(selected.value)
        \\    return source
    , 42);
}

test "Array mutable alias calls retain newly stored reference origins" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = Array(Ref(int), 1).filled(reference)
        \\func run() int
        \\    const original = 42
        \\    var values = Array(Ref(int), 1).filled(Ref.from(original))
        \\    if not (values is Array(Ref(int), 1)) -> panic "unexpected none"
        \\    if 1 == 1
        \\        const temporary = 17
        \\        ref selected = values
        \\        overwrite(selected, Ref.from(temporary))
        \\    match values.get(0)
        \\        ref _matched_selected and _matched_selected is Ref(int) ->
        \\            ref selected = _matched_selected
        \\            return selected.value
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    , .borrow_outlives_source);
}

test "Array dereferenced mutable aliases cannot retain short-lived references" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = Array(Ref(int), 1).filled(reference)
        \\func run() int | none
        \\    const original = 42
        \\    var owner = Box.new(Array(Ref(int), 1).filled(Ref.from(original)))
        \\    if not (owner is Box(Array(Ref(int), 1))) -> return none
        \\    if 1 == 1
        \\        const temporary = 17
        \\        var selected = Ref.from(owner.borrow())
        \\        overwrite(selected.value, Ref.from(temporary))
        \\    var selected = Ref.from(owner.borrow())
        \\    match selected.value.get(0)
        \\        ref _matched_element and _matched_element is Ref(int) ->
        \\            ref element = _matched_element
        \\            return element.value
        \\        _ -> ()
        \\    return 90
        \\match run()
        \\    answer and answer is int -> exit(answer)
        \\    _ -> exit(91)
    , .borrow_outlives_source);
}

test "Array boxed mutable aliases retain long-lived reference origins" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = Array(Ref(int), 1).filled(reference)
        \\func run() int | none
        \\    const original = 17
        \\    const replacement = 42
        \\    var owner = Box.new(Array(Ref(int), 1).filled(Ref.from(original)))
        \\    if not (owner is Box(Array(Ref(int), 1))) -> return none
        \\    if 1 == 1
        \\        var selected = Ref.from(owner.borrow())
        \\        overwrite(selected.value, Ref.from(replacement))
        \\    var selected = Ref.from(owner.borrow())
        \\    match selected.value.get(0)
        \\        ref _matched_element and _matched_element is Ref(int) ->
        \\            ref element = _matched_element
        \\            return element.value
        \\        _ -> ()
        \\    return 90
        \\match run()
        \\    answer and answer is int -> exit(answer)
        \\    _ -> exit(91)
    , 42);
}

test "Array reference parameters retain caller origins when storing other inputs" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = Array(Ref(int), 1).filled(reference)
        \\func change(var target: Ref(Array(Ref(int), 1)), replacement: Ref(int))
        \\    var selected = Ref.from(target.value)
        \\    overwrite(selected.value, replacement)
        \\func run() int | none
        \\    const original = 42
        \\    var owner = Box.new(Array(Ref(int), 1).filled(Ref.from(original)))
        \\    if not (owner is Box(Array(Ref(int), 1))) -> return none
        \\    change(Ref.from(owner.borrow()), Ref.from(original))
        \\    return 42
        \\match run()
        \\    answer and answer is int -> exit(answer)
        \\    _ -> exit(91)
    , 42);
}

test "compile-time direct scalar arguments copy caller storage before mutation" {
    try Fixture.expectParity(
        \\func observe(imm captured: int, var target: Ref(int)) int
        \\    target.value = 22
        \\    return captured + 22
        \\func run() int
        \\    var values = Array(int, 1).filled(20)
        \\    if not (values is Array(int, 1)) -> panic "unexpected none"
        \\    match values.get(0)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            return observe(target, Ref.from(target))
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "compile-time variant coercion preserves returned reference payloads" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int)) Ref(int) | none -> reference
        \\func run() int
        \\    const values = Array(int, 1).filled(42)
        \\    if not (values is Array(int, 1)) -> panic "unexpected none"
        \\    match values.get(0)
        \\        ref _matched_reference and _matched_reference is int ->
        \\            ref reference = _matched_reference
        \\            match choose(Ref.from(reference))
        \\                selected and selected is Ref(int) -> return selected.value
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "Array immutable arguments permit widening address-passed movable values" {
    try Fixture.expectParity(
        \\func inspect(imm possible: Array(int, 2) | none) int
        \\    match possible
        \\        Array(int, 2) ->
        \\            const values = possible
        \\            match values.get(1)
        \\                ref _matched_selected and _matched_selected is int ->
        \\                    ref selected = _matched_selected
        \\                    return selected
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    const values = Array(int, 2).filled(42)
        \\    if not (values is Array(int, 2)) -> panic "unexpected none"
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
        \\    var reference = Ref.from(original)
        \\    if not (reference is Ref(int)) -> panic "unexpected none"
        \\    const captured = reference
        \\    retarget(reference, Ref.from(replacement))
        \\    return captured.value + reference.value
    , 42);
}

test "compile-time reference variants support widening and conditional results" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int)) Ref(int) | none
        \\    return if 1 == 1 -> reference else none
        \\func widen(imm possible: Ref(int) | none) Ref(int) | none | bool -> possible
        \\func run() int
        \\    const values = Array(int, 1).filled(42)
        \\    if not (values is Array(int, 1)) -> panic "unexpected none"
        \\    match values.get(0)
        \\        ref _matched_reference and _matched_reference is int ->
        \\            ref reference = _matched_reference
        \\            const possible = choose(Ref.from(reference))
        \\            match widen(possible)
        \\                selected and selected is Ref(int) -> return selected.value
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
}
