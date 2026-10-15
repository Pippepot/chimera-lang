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
        \\    if values[0] = 20
        \\        if const first = values[0]
        \\            if const second = values[1]
        \\                if const invalid = values[-1] -> return 91
        \\                if const invalid = values[2] -> return 92
        \\                const empty: Array(int, 0) = []
        \\                if const invalid = empty[0] -> return 93
        \\                return first + second - 1
        \\    return 90
    , 42);
}

test "operation indexing compound assignments and reference assignments have parity" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var values = [20, 10]
        \\    values[0] += 2
        \\    values[0] *= 2
        \\    values[0] -= 2
        \\    values[0] /= 2
        \\    if ref reference = values.get(1)
        \\        reference += 1
        \\        reference *= 2
        \\        reference -= 2
        \\        reference /= 2
        \\    return values[0] + values[1] + 11
        \\func run() int
        \\    if const calculated = calculate() -> return calculated
        \\    return 90
    , 42);
}

test "operation indexing List reads replacements and bounds use ordinary calls" {
    try Fixture.expectSourceExit(
        \\fallible calculate() int
        \\    var values: List(int) = [19, 23]
        \\    values[0] += 1
        \\    if const invalid = values[2] -> return 91
        \\    return values[0] + values[1] - 1
        \\func run() int
        \\    if const calculated = calculate() -> return calculated
        \\    return 90
        \\exit(run())
    , 42);
}

test "operation indexing evaluates owned replacements before setter bounds and freezes the index" {
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
        \\    if values[1] = replacement(calls) -> return 91
        \\    if calls <> 10 -> return 92
        \\    calls = 0
        \\    if values[offset(calls)] += replacement(calls)
        \\        if calls <> 11 -> return 93
        \\        if const stored = values[0] -> return stored + 2
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
            \\fallible calculate() int
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
        \\fallible calculate() int
        \\    var values: Array(Array(int, 2), 2) = [[10, 20], [30, 40]]
        \\    values[1] = [values[0][0] + 1, values[0][1] + 11]
        \\    return values[1][0] + values[1][1]
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "invalid indexed replacement cleans its prepared owned value" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value + self.value
        \\struct Sink
        \\    pub fallible []=(mut self: Sink, index: int, var item: Item) unit -> fail
        \\func run() int
        \\    var trace = [0]
        \\    if ref handle = trace.get(0)
        \\        var sink = Sink{}
        \\        if sink[99] = Item{trace = Ref.from(handle), value = 42} -> return 90
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
        \\    if ref target = values.get(99)
        \\        target = replacement(calls)
        \\    if const first = values[0] -> return first + calls + 22
        \\    return 90
    , 42);
}

test "operation indexing respects immutability and existing element ownership restrictions" {
    try Fixture.expectAnySourceDiagnostic(
        \\const values = [19]
        \\if values[0] = 42 -> exit(91)
        \\exit(90)
    , .mutable_argument_requires_mutable_place);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    value: int
        \\var values = [Item{value = 19}]
        \\if values[0] = Item{value = 42} -> exit(91)
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
        \\    if const selected = values[0] -> return selected.value
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
        \\if values[0] = Item{value = 21} -> exit(92)
        \\exit(90)
    , 42);
}

test "operation indexing replacement retains stored reference origins" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var original = [17]
        \\    if ref item = original.get(0)
        \\        var values = [Ref.from(item)]
        \\        values[0] = Ref.from(item)
        \\        ref stored = values[0]
        \\        stored.value = 42
        \\        return item
        \\    return 90
        \\func run() int
        \\    if const answer = calculate() -> return answer
        \\    return 91
    , 42);
}

test "operation indexing List and views use the same operator contract" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\fallible calculate() int
        \\    var values = List(int).new?(2)
        \\    values.append?(19)
        \\    values.append?(23)
        \\    values[0] += 1
        \\    const view = values.view?(0, 2)
        \\    return view[0] + view[1] - 1
        \\func run() int
        \\    if const calculated = calculate() -> return calculated
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
        \\    if ref first = values.get(0)
        \\        first = 20
        \\    if ref first = values.get(0)
        \\        if ref second = values.get(1)
        \\            return first + second + empty.len() + bytes.len() - 3
        \\    return 90
        \\exit(run())
    , 42);
}

test "List growth retains zero-sized logical elements and their destruction" {
    try Fixture.expectParity(
        \\struct Item
        \\    drop = func(deinit self: Item) -> exit(42)
        \\fallible exercise() int
        \\    var values = List(Item).new?(0)
        \\    values.append?(Item{})
        \\    values.append?(Item{})
        \\    values.append?(Item{})
        \\    if values.len() <> 3 -> exit(91)
        \\    if values.capacity() <> 4 -> exit(92)
        \\    return 93
        \\func run() int
        \\    if const result = exercise() -> return result
        \\    return 94
    , 42);
}

test "List literal failure drops an immovable prefix in reverse and skips later elements" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value * 10 + self.value
        \\fallible missing(var trace: Ref(int)) Item -> fail
        \\func skipped(var trace: Ref(int)) Item
        \\    exit(91)
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if ref target = trace.get(0)
        \\        if const values: List(Item) = [Item{trace = Ref.from(target), value = 2}, Item{trace = Ref.from(target), value = 4}, missing?(Ref.from(target)), skipped(Ref.from(target))]
        \\            return 92
        \\    if ref result = trace.get(0) -> return result
        \\    return 93
        \\exit(run())
    , 42);
}

test "List explicit fallible factory infers length and preserves ordinary element failure" {
    try Fixture.expectSourceExit(
        \\fallible missing() int -> fail
        \\func run() int
        \\    if const values = List(int).from([19, 23])
        \\        if ref first = values.get(0)
        \\            if ref second = values.get(1)
        \\                if const failed = List(int).from([missing?()]) -> return 91
        \\                return first + second
        \\    return 90
        \\exit(run())
    , 42);
}

test "List implicit allocation failure terminates before element evaluation and cannot be caught" {
    try expectLimitedExit(
        \\fallible skipped() Array(int, 262144)
        \\    exit(91)
        \\func run() int
        \\    if const values: List(Array(int, 262144)) = [skipped?()]
        \\        return 92
        \\    return 42
        \\exit(run())
    , 134);
}

test "List explicit allocation failure is recoverable and skips element evaluation" {
    try expectLimitedExit(
        \\func skipped() Array(int, 262144)
        \\    exit(91)
        \\func run() int
        \\    if const values = List(Array(int, 262144)).from([skipped()])
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
        \\fallible missing(var trace: Ref(int)) Item -> fail
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if ref target = trace.get(0)
        \\        var iteration = 0
        \\        loop
        \\            if iteration == 384 -> break
        \\            target = 0
        \\            if const values: List(Item) = [Item{trace = Ref.from(target), value = 2}, Item{trace = Ref.from(target), value = 4}, missing?(Ref.from(target))]
        \\                return 91
        \\            if target == 42
        \\                iteration += 1
        \\            else
        \\                return 92
        \\        target = 0
        \\        const complete: List(Item) = [Item{trace = Ref.from(target), value = 2}, Item{trace = Ref.from(target), value = 4}]
        \\        complete.len()
        \\    if ref result = trace.get(0) -> return result
        \\    return 93
        \\exit(run())
    , 42);
}

test "List construction and borrowing preserve stored external reference origins" {
    try Fixture.expectSourceExit(
        \\func make(imm value: Ref(int)) List(Ref(int)) -> [value]
        \\func run() int
        \\    const original = Array(int, 1).filled(42)
        \\    if ref reference = original.get(0)
        \\        const values = make(Ref.from(reference))
        \\        if ref stored = values.get(0)
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
        \\fallible count(static T: type, static N: int, init values: collection_literal(T, N)) int
        \\    const array: Array(T, N) = values
        \\    return array.len()
        \\func element(var trace: Ref(int)) int
        \\    trace.value = trace.value + 1
        \\    return 19
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if ref target = trace.get(0)
        \\        if const size = count([element(Ref.from(target)), element(Ref.from(target))])
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
        \\    if ref first = values.get(0)
        \\        if ref last = nested.get(0)
        \\            if ref second = last.get(1)
        \\                return first + second + empty.len() + bytes.len() - 2
        \\    return 90
    , 42);
}

test "collection literal failure drops the completed prefix in reverse and skips remaining elements" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.value = self.trace.value * 10 + self.value
        \\fallible missing(var trace: Ref(int)) Item -> fail
        \\func skipped(var trace: Ref(int)) Item
        \\    exit(91)
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if ref target = trace.get(0)
        \\        if const values: Array(Item, 4) = [Item{trace = Ref.from(target), value = 2}, Item{trace = Ref.from(target), value = 4}, missing?(Ref.from(target)), skipped(Ref.from(target))]
        \\            return 92
        \\    if ref result = trace.get(0) -> return result
        \\    return 93
    , 42);
}

test "collection literal element failure cannot escape an ordinary function" {
    try Fixture.expectAnySourceDiagnostic(
        \\fallible missing() int -> fail
        \\func run() int
        \\    const values: Array(int, 2) = [1, missing?()]
        \\    return values.len()
        \\exit(run())
    , .fallible_expression_outside_fallible_function);
}

test "Array integer fill get and get_mut have native and comptime parity" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    var values = Array(int, 3).filled(20)
        \\    if ref middle = values.get(1) -> middle = 22
        \\    else return 90
        \\    if ref first = values.get(0)
        \\        if ref middle = values.get(1) -> return first + middle
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
        \\    if ref last = values.get(3) -> return last + calls
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
        \\    if empty.get(-1) -> return 90
        \\    if empty.get(0) -> return 91
        \\    if empty.get(0) -> return 92
        \\    if empty.len() <> 0 -> return 93
        \\    return calls + 41
    , 42);
}

test "Array populated bounds reject negative and past end indices" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    var values = Array(int, 2).filled(42)
        \\    if values.get(-1) -> return 90
        \\    if values.get(2) -> return 91
        \\    if values.get(-1) -> return 92
        \\    if values.get(2) -> return 93
        \\    if ref last = values.get(1) -> return last
        \\    return 94
    , 42);
}

test "Array nested fill and element borrows retain shape" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    const row = Array(int, 3).filled(42)
        \\    const matrix = Array(Array(int, 3), 2).filled(row)
        \\    if ref selected = matrix.get(1)
        \\        if ref cell = selected.get(2) -> return cell
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
        \\    const copied = values.copy()
        \\    if original.value <> 40 -> return 90
        \\    if ref selected = copied.get(2) -> return selected.value
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
        \\    const moved = values.move()
        \\    if ref selected = moved.get(2) -> return selected.value
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
        \\    const matrix = Array(Array(Item, 3), 2).filled(row)
        \\    const copied = matrix.copy()
        \\    if ref selected = copied.get(1)
        \\        if ref cell = selected.get(2) -> return cell.value
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
        \\    if ref first = values.get(0) -> first = Item{value = 41}
        \\    if ref last = values.get(1) -> last = Item{value = 42}
        \\    if ref first = values.get(0)
        \\        if ref last = values.get(1)
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
        \\    const empty = Array(Item, 0).filled(original)
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
        \\    if ref selected = values.get(1) -> return Ref.from(selected)
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
        \\    if ref selected = values.get(1) -> return selected.value
        \\    return 90
    , 42);
}

test "Array get_mut requires mutable source storage" {
    try Fixture.expectRejected(
        \\import std.array.{Array}
        \\const values = Array(int, 2).filled(42)
        \\if ref selected = values.get(0) -> selected = 1
        \\exit(42)
    );
}

test "Array copy hooks preserve transitive readonly access" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\struct Handle
        \\    target: Ref(Box(int))
        \\    copy = func(imm self: Handle) Handle
        \\        if const replacement = Box.new(17) -> self.target.value = replacement^
        \\        return Handle{target = self.target}
        \\func inspect(imm earlier: Ref(int), imm values: Array(Handle, 2)) int -> earlier.value + values.len()
        \\fallible run() int
        \\    var owner = Box.new?(Box.new?(42))
        \\    var source = Handle{target = Ref.from(owner.borrow())}
        \\    const values = Array(Handle, 2).filled(source)
        \\    return inspect(Ref.from(owner.borrow().borrow()), values.copy())
        \\if const result = run() -> exit(result) else exit(90)
    , .reference_not_writable);
}

test "Array static nested values publish into runtime storage" {
    try Fixture.expectSourceExit(
        \\static row = Array(int, 2).filled(20)
        \\static matrix = Array(Array(int, 2), 2).filled(row)
        \\func run() int
        \\    const values = matrix
        \\    if ref selected = values.get(1)
        \\        if ref value = selected.get(0) -> return value + row.len() + 20
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
        \\    if ref selected = holder.values.get(1) -> selected = 22
        \\    else return 90
        \\    const copied = holder.copy()
        \\    if ref selected = copied.values.get(1) -> return selected + 20
        \\    return 91
    , 42);
}

test "Array boxed inline storage retains mutable element references" {
    try Fixture.expectParity(
        \\import std.memory
        \\fallible calculate() int
        \\    var owner = Box.new?(Array(int, 3).filled(20))
        \\    var values = Ref.from(owner.borrow())
        \\    if ref selected = values.value.get(1) -> selected = 22
        \\    else return 90
        \\    if ref selected = values.value.get(1) -> return selected + 20
        \\    return 91
        \\func run() int
        \\    if const answer = calculate() -> return answer
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
        \\    const possible = widen(values)
        \\    if const selected = possible as Array(Item, 2)
        \\        if ref element = selected.get(1) -> return element.value
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
        \\    const values = duplicate(original)
        \\    if ref selected = values.get(1) -> return selected.value
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\import std.memory.{Ref}
        \\func bad() Array(Ref(int), 2)
        \\    const source = 42
        \\    const values = Array(Ref(int), 2).filled(Ref.from(source))
        \\    return values.copy()
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array element references observe whole storage replacement" {
    try Fixture.expectParity(
        \\func run() int
        \\    var values = Array(int, 2).filled(42)
        \\    if ref selected = values.get(1)
        \\        values = Array(int, 2).filled(17)
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
        \\fallible calculate() int
        \\    const source = Item{value = 20}
        \\    const values = Array(Item, 2).filled(source)
        \\    ref first = values.get?(0)
        \\    ref second = values.get?(1)
        \\    return first.value + second.value
        \\func run() int
        \\    if const result = calculate() -> return result
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
        \\    if 1 == 1
        \\        const temporary = 17
        \\        ref selected = values
        \\        overwrite(selected, Ref.from(temporary))
        \\    if ref selected = values.get(0) -> return selected.value
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
        \\fallible run() int
        \\    const original = 42
        \\    var owner = Box.new?(Array(Ref(int), 1).filled(Ref.from(original)))
        \\    if 1 == 1
        \\        const temporary = 17
        \\        var selected = Ref.from(owner.borrow())
        \\        overwrite(selected.value, Ref.from(temporary))
        \\    var selected = Ref.from(owner.borrow())
        \\    if ref element = selected.value.get(0) -> return element.value
        \\    return 90
        \\if const answer = run() -> exit(answer) else exit(91)
    , .borrow_outlives_source);
}

test "Array boxed mutable aliases retain long-lived reference origins" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\import std.memory.{Ref}
        \\func overwrite(mut values: Array(Ref(int), 1), imm reference: Ref(int))
        \\    values = Array(Ref(int), 1).filled(reference)
        \\fallible run() int
        \\    const original = 17
        \\    const replacement = 42
        \\    var owner = Box.new?(Array(Ref(int), 1).filled(Ref.from(original)))
        \\    if 1 == 1
        \\        var selected = Ref.from(owner.borrow())
        \\        overwrite(selected.value, Ref.from(replacement))
        \\    var selected = Ref.from(owner.borrow())
        \\    if ref element = selected.value.get(0) -> return element.value
        \\    return 90
        \\if const answer = run() -> exit(answer) else exit(91)
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
        \\fallible run() int
        \\    const original = 42
        \\    var owner = Box.new?(Array(Ref(int), 1).filled(Ref.from(original)))
        \\    change(Ref.from(owner.borrow()), Ref.from(original))
        \\    return 42
        \\if const answer = run() -> exit(answer) else exit(91)
    , 42);
}

test "compile-time direct scalar arguments copy caller storage before mutation" {
    try Fixture.expectParity(
        \\func observe(imm captured: int, var target: Ref(int)) int
        \\    target.value = 22
        \\    return captured + 22
        \\func run() int
        \\    var values = Array(int, 1).filled(20)
        \\    if ref target = values.get(0) -> return observe(target, Ref.from(target))
        \\    return 90
    , 42);
}

test "compile-time variant coercion preserves returned reference payloads" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int)) Ref(int) | none -> reference
        \\func run() int
        \\    const values = Array(int, 1).filled(42)
        \\    if ref reference = values.get(0)
        \\        if const selected = choose(Ref.from(reference)) as Ref(int) -> return selected.value
        \\    return 90
    , 42);
}

test "Array immutable arguments permit widening address-passed movable values" {
    try Fixture.expectParity(
        \\func inspect(imm possible: Array(int, 2) | none) int
        \\    if const values = possible as Array(int, 2)
        \\        if ref selected = values.get(1) -> return selected
        \\    return 90
        \\func run() int
        \\    const values = Array(int, 2).filled(42)
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
        \\    if ref reference = values.get(0)
        \\        const possible = choose(Ref.from(reference))
        \\        if const selected = widen(possible) as Ref(int) -> return selected.value
        \\    return 90
    , 42);
}
