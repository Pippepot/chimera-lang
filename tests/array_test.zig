const std = @import("std");
const test_sources = @import("test_sources");
const query = test_sources.query;
const queries = test_sources.queries;
const structures = test_sources.structures;
const modules = test_sources.modules;
const runtime = test_sources.runtime;
const testing = std.testing;

const Fixture = struct {
    db: *query.Database,

    fn init(source: []const u8) !Fixture {
        const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
        errdefer db.deinit();
        try modules.registerSources(db, testing.allocator, source, &.{}, &.{});
        return .{ .db = db };
    }

    fn deinit(self: Fixture) void {
        self.db.deinit();
    }

    fn printDiagnostics(self: Fixture, source: []const u8) !void {
        std.debug.print("Chi entry source:\n{s}\n", .{source});
        const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
        defer testing.allocator.free(diagnostics);
        for (diagnostics) |diagnostic| std.debug.print("file {d} at {d}: {s}\n", .{
            diagnostic.file_id,
            if (diagnostic.span) |span| span.start else 0,
            @tagName(diagnostic.kind),
        });
    }

    fn expectExit(source: []const u8, status: u8) !void {
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        const executable = (try fixture.db.get(queries.BuildExecutable, 0)).*;
        if (executable == null) try fixture.printDiagnostics(source);
        try testing.expect(executable != null);
        try runtime.writeProgram(testing.io, executable.?.bytes);
        defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
        const actual_status = try runtime.runProg(testing.io, testing.allocator, &.{});
        if (actual_status != status) try fixture.printDiagnostics(source);
        try testing.expectEqual(status, actual_status);
    }

    fn expectParity(source: []const u8, status: u8) !void {
        for ([_][]const u8{ "exit(run())", "static answer = run()\nexit(answer)" }) |entry| {
            const program = try testing.allocator.print("{s}\n{s}", .{ source, entry });
            defer testing.allocator.free(program);
            try Fixture.expectExit(program, status);
        }
    }

    fn expectLimitedExit(source: []const u8, status: u8) !void {
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        const executable = (try fixture.db.get(queries.BuildExecutable, 0)).*;
        if (executable == null) try fixture.printDiagnostics(source);
        try testing.expect(executable != null);
        try runtime.writeProgram(testing.io, executable.?.bytes);
        defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
        var child = std.process.spawn(testing.io, .{ .argv = &.{ "prlimit", "--as=1048576", "--", "./prog" } }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        try testing.expectEqual(std.process.Child.Term{ .exited = status }, try child.wait(testing.io));
    }

    fn expectDiagnostic(source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        try testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
        defer testing.allocator.free(diagnostics);
        for (diagnostics) |diagnostic| if (std.meta.activeTag(diagnostic.kind) == kind) return;
        try fixture.printDiagnostics(source);
        return error.ExpectedDiagnostic;
    }

    fn expectRejected(source: []const u8) !void {
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        try testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
        defer testing.allocator.free(diagnostics);
        try testing.expect(diagnostics.len != 0);
    }
};

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
        \\    if const reference = values.get_mut(1)
        \\        reference[] += 1
        \\        reference[] *= 2
        \\        reference[] -= 2
        \\        reference[] /= 2
        \\    return values[0] + values[1] + 11
        \\func run() int
        \\    if const calculated = calculate() -> return calculated
        \\    return 90
    , 42);
}

test "operation indexing List reads replacements and bounds use ordinary calls" {
    try Fixture.expectExit(
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

test "operation indexing bounds failure skips initialization and index evaluates once" {
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
        \\    if calls <> 0 -> return 92
        \\    if values[offset(calls)] += replacement(calls)
        \\        if calls <> 11 -> return 93
        \\        if const stored = values[0] -> return stored + 2
        \\    return 90
    , 42);
}

test "operation indexing respects immutability and existing element ownership restrictions" {
    try Fixture.expectDiagnostic(
        \\const values = [19]
        \\if values[0] = 42 -> exit(91)
        \\exit(90)
    , .mutable_argument_requires_mutable_place);
    try Fixture.expectDiagnostic(
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
    try Fixture.expectExit(
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

test "operation indexing replacement preserves reference origin restrictions" {
    try Fixture.expectDiagnostic(
        \\var original = [42]
        \\if const reference = original.get(0)
        \\    var values = [reference]
        \\    if values[0] = reference -> exit(91)
        \\exit(90)
    , .borrow_write_cannot_store_borrow);
}

test "operation indexing Buffer and views use the same operator contract" {
    try Fixture.expectExit(
        \\import std.memory.{Buffer}
        \\fallible calculate() int
        \\    var values = Buffer(int).new?(2)
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
    try Fixture.expectExit(
        \\func run() int
        \\    var values: List(int) = [19, 23]
        \\    const empty: List(int) = []
        \\    const bytes: List(byte) = [1, 2]
        \\    if const first = values.get_mut(0)
        \\        first.replace(20)
        \\    if const first = values.get(0)
        \\        if const second = values.get(1)
        \\            return first[] + second[] + empty.len() + bytes.len() - 3
        \\    return 90
        \\exit(run())
    , 42);
}

test "List literal failure drops an immovable prefix in reverse and skips later elements" {
    try Fixture.expectExit(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int, true)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.replace(self.trace[] * 10 + self.value)
        \\fallible missing(imm trace: Ref(int, true)) Item -> fail
        \\func skipped(imm trace: Ref(int, true)) Item
        \\    exit(91)
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if const target = trace.get_mut(0)
        \\        if const values: List(Item) = [Item{trace = target, value = 2}, Item{trace = target, value = 4}, missing?(target), skipped(target)]
        \\            return 92
        \\    if const result = trace.get(0) -> return result[]
        \\    return 93
        \\exit(run())
    , 42);
}

test "List explicit fallible factory infers length and preserves ordinary element failure" {
    try Fixture.expectExit(
        \\fallible missing() int -> fail
        \\func run() int
        \\    if const values = List(int).from([19, 23])
        \\        if const first = values.get(0)
        \\            if const second = values.get(1)
        \\                if const failed = List(int).from([missing?()]) -> return 91
        \\                return first[] + second[]
        \\    return 90
        \\exit(run())
    , 42);
}

test "List implicit allocation failure terminates before element evaluation and cannot be caught" {
    try Fixture.expectLimitedExit(
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
    try Fixture.expectLimitedExit(
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
    try Fixture.expectLimitedExit(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int, true)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.replace(self.trace[] * 10 + self.value)
        \\fallible missing(imm trace: Ref(int, true)) Item -> fail
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if const target = trace.get_mut(0)
        \\        var iteration = 0
        \\        loop
        \\            if iteration == 384 -> break
        \\            target.replace(0)
        \\            if const values: List(Item) = [Item{trace = target, value = 2}, Item{trace = target, value = 4}, missing?(target)]
        \\                return 91
        \\            if target[] == 42
        \\                iteration += 1
        \\            else
        \\                return 92
        \\        target.replace(0)
        \\        const complete: List(Item) = [Item{trace = target, value = 2}, Item{trace = target, value = 4}]
        \\        complete.len()
        \\    if const result = trace.get(0) -> return result[]
        \\    return 93
        \\exit(run())
    , 42);
}

test "List construction and borrowing preserve stored external reference origins" {
    try Fixture.expectExit(
        \\func make(imm value: Ref(int, false)) List(Ref(int, false)) -> [value]
        \\func run() int
        \\    const original = Array(int, 1).filled(42)
        \\    if const reference = original.get(0)
        \\        const values = make(reference)
        \\        if const stored = values.get(0)
        \\            const result = stored[]
        \\            return result[]
        \\    return 90
        \\exit(run())
    , 42);
}

test "collection pending type cannot be constructed or published as a value" {
    try Fixture.expectDiagnostic("func count(imm value: collection_literal(int, 2)) int -> 42\nconst pending = collection_literal(int, 2){}\nexit(count(pending))", .compile_time_only_type);
    try Fixture.expectDiagnostic("func count(imm value: collection_literal(int, 2)) int -> 42\nstatic pending = collection_literal(int, 2){}\nstatic result = count(pending)\nexit(result)", .compile_time_only_type);
}

test "collection initializer consumers infer the pending shape and construct each element once" {
    try Fixture.expectParity(
        \\fallible count(static T: type, static N: int, init values: collection_literal(T, N)) int
        \\    const array: Array(T, N) = values
        \\    return array.len()
        \\func element(imm trace: Ref(int, true)) int
        \\    trace.replace(trace[] + 1)
        \\    return 19
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if const target = trace.get_mut(0)
        \\        if const size = count([element(target), element(target)])
        \\            return target[] + size + 38
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
        \\    if const first = values.get(0)
        \\        if const last = nested.get(0)
        \\            if const second = last[].get(1)
        \\                return first[] + second[] + empty.len() + bytes.len() - 2
        \\    return 90
    , 42);
}

test "collection literal failure drops the completed prefix in reverse and skips remaining elements" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    trace: Ref(int, true)
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        self.trace.replace(self.trace[] * 10 + self.value)
        \\fallible missing(imm trace: Ref(int, true)) Item -> fail
        \\func skipped(imm trace: Ref(int, true)) Item
        \\    exit(91)
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if const target = trace.get_mut(0)
        \\        if const values: Array(Item, 4) = [Item{trace = target, value = 2}, Item{trace = target, value = 4}, missing?(target), skipped(target)]
        \\            return 92
        \\    if const result = trace.get(0) -> return result[]
        \\    return 93
    , 42);
}

test "collection literal element failure cannot escape an ordinary function" {
    try Fixture.expectDiagnostic(
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
        \\    if const middle = values.get_mut(1) -> middle.replace(22)
        \\    else return 90
        \\    if const first = values.get(0)
        \\        if const middle = values.get(1) -> return first[] + middle[]
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
        \\    if const last = values.get(3) -> return last[] + calls
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
        \\    if empty.get_mut(0) -> return 92
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
        \\    if values.get_mut(-1) -> return 92
        \\    if values.get_mut(2) -> return 93
        \\    if const last = values.get(1) -> return last[]
        \\    return 94
    , 42);
}

test "Array nested fill and element borrows retain shape" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\func run() int
        \\    const row = Array(int, 3).filled(42)
        \\    const matrix = Array(Array(int, 3), 2).filled(row)
        \\    if const selected = matrix.get(1)
        \\        if const cell = selected[].get(2) -> return cell[]
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
        \\    if const selected = copied.get(2) -> return selected[].value
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
        \\    if const selected = moved.get(2) -> return selected[].value
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
        \\    if const selected = copied.get(1)
        \\        if const cell = selected[].get(2) -> return cell[].value
        \\    return 90
    , 42);
}

test "Array automatic cleanup drops elements in reverse index order" {
    try Fixture.expectExit(
        \\import std.array.{Array}
        \\struct Item
        \\    value: int
        \\    copy = fieldwise
        \\    drop = func(deinit self: Item)
        \\        if self.value == 41 -> exit(41)
        \\        if self.value == 42 -> exit(42)
        \\func run()
        \\    var values = Array(Item, 2).filled(Item{value = 0})
        \\    if const first = values.get_mut(0) -> first.replace(Item{value = 41})
        \\    if const last = values.get_mut(1) -> last.replace(Item{value = 42})
        \\    if const first = values.get(0)
        \\        if const last = values.get(1)
        \\            if first[].value + last[].value <> 83 -> exit(90)
        \\run()
        \\exit(91)
    , 42);
}

test "Array empty cleanup does not call element destructors" {
    try Fixture.expectExit(
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
    try Fixture.expectDiagnostic(
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
    try Fixture.expectDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref}
        \\func bad() Ref(int, false)
        \\    const values = Array(int, 2).filled(42)
        \\    if const selected = values.get(1) -> return selected
        \\    return bad()
        \\const reference = bad()
        \\exit(reference[])
    , .borrow_outlives_source);
}

test "Array fill cannot return references to a local source" {
    try Fixture.expectDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref, borrow_local}
        \\func bad() Array(Ref(int, false), 2)
        \\    const value = 42
        \\    return Array(Ref(int, false), 2).filled(borrow_local(int, value))
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array fill and nested reference reads preserve runtime source dependencies" {
    try Fixture.expectParity(
        \\import std.array.{Array}
        \\import std.memory.{Ref, borrow_local}
        \\func fill(imm source: Ref(int, false)) Array(Ref(int, false), 2)
        \\    return Array(Ref(int, false), 2).filled(source)
        \\func run() int
        \\    const value = 42
        \\    const values = fill(borrow_local(int, value))
        \\    if const selected = values.get(1) -> return selected[][]
        \\    return 90
    , 42);
}

test "Array get_mut requires mutable source storage" {
    try Fixture.expectRejected(
        \\import std.array.{Array}
        \\const values = Array(int, 2).filled(42)
        \\if const selected = values.get_mut(0) -> selected.replace(1)
        \\exit(42)
    );
}

test "Array whole copy hooks invalidate pending borrowed owners" {
    try Fixture.expectDiagnostic(
        \\import std.array.{Array}
        \\import std.memory.{Ref, borrow_box, borrow_mut_box}
        \\struct Handle
        \\    target: Ref(Box(int), true)
        \\    copy = func(imm self: Handle) Handle
        \\        if const replacement = Box.new(17) -> self.target.replace(replacement^)
        \\        return Handle{target = self.target}
        \\func inspect(imm earlier: Ref(int, false), imm values: Array(Handle, 2)) int -> earlier[] + values.len()
        \\fallible run() int
        \\    var owner = Box.new?(Box.new?(42))
        \\    const source = Handle{target = owner.borrow_mut()}
        \\    const values = Array(Handle, 2).filled(source)
        \\    return inspect(owner.borrow()[].borrow(), values.copy())
        \\if const result = run() -> exit(result) else exit(90)
    , .borrow_outlives_source);
}

test "Array static nested values publish into runtime storage" {
    try Fixture.expectExit(
        \\static row = Array(int, 2).filled(20)
        \\static matrix = Array(Array(int, 2), 2).filled(row)
        \\func run() int
        \\    const values = matrix
        \\    if const selected = values.get(1)
        \\        if const value = selected[].get(0) -> return value[] + row.len() + 20
        \\    return 90
        \\exit(run())
    , 42);
}

test "Array zero-sized fill does not skip custom copy" {
    try Fixture.expectExit(
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
        \\    if const selected = holder.values.get_mut(1) -> selected.replace(22)
        \\    else return 90
        \\    const copied = holder.copy()
        \\    if const selected = copied.values.get(1) -> return selected[] + 20
        \\    return 91
    , 42);
}

test "Array boxed inline storage retains mutable element references" {
    try Fixture.expectExit(
        \\fallible run() int
        \\    var owner = Box.new?(Array(int, 3).filled(20))
        \\    borrow mut values = owner.borrow_mut()[]
        \\    if const selected = values.get_mut(1) -> selected.replace(22)
        \\    else return 90
        \\    if const selected = values.get(1) -> return selected[] + 20
        \\    return 91
        \\if const answer = run() -> exit(answer) else exit(92)
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
        \\        if const element = selected.get(1) -> return element[].value
        \\    return 90
    , 42);
}

test "Array zero-sized logical elements retain custom destruction" {
    try Fixture.expectExit(
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
        \\import std.memory.{borrow_local}
        \\func duplicate(imm values: Array(Ref(int, false), 2)) Array(Ref(int, false), 2)
        \\    return values.copy()
        \\func run() int
        \\    const source = 42
        \\    const original = Array(Ref(int, false), 2).filled(borrow_local(int, source))
        \\    const values = duplicate(original)
        \\    if const selected = values.get(1) -> return selected[][]
        \\    return 90
    , 42);
    try Fixture.expectDiagnostic(
        \\import std.memory.{borrow_local}
        \\func bad() Array(Ref(int, false), 2)
        \\    const source = 42
        \\    const values = Array(Ref(int, false), 2).filled(borrow_local(int, source))
        \\    return values.copy()
        \\const values = bad()
        \\exit(values.len())
    , .borrow_outlives_source);
}

test "Array element references are invalidated by whole storage replacement" {
    try Fixture.expectDiagnostic(
        \\func run() int
        \\    var values = Array(int, 2).filled(42)
        \\    if const selected = values.get(1)
        \\        values = Array(int, 2).filled(17)
        \\        return selected[]
        \\    return 90
        \\exit(run())
    , .borrow_outlives_source);
}

test "Array fill invokes exactly N ordinary element copies" {
    try Fixture.expectExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    copy = func(imm self: Item) Item
        \\        self.counter.replace(self.counter[] + 1)
        \\        return Item{counter = self.counter}
        \\fallible run() int
        \\    var counter = Box.new?(37)
        \\    const source = Item{counter = counter.borrow_mut()}
        \\    const values = Array(Item, 5).filled(source)
        \\    if values.len() <> 5 -> return 90
        \\    return counter.borrow()[]
        \\if const answer = run() -> exit(answer) else exit(91)
    , 42);
}

test "mutable alias call arguments write direct values back to their referents" {
    try Fixture.expectParity(
        \\func advance(mut value: int)
        \\    value += 2
        \\func run() int
        \\    var source = 40
        \\    borrow mut selected = source
        \\    advance(selected)
        \\    return source
    , 42);
}

test "Array mutable alias calls retain newly stored reference origins" {
    try Fixture.expectDiagnostic(
        \\import std.memory.{borrow_local}
        \\func overwrite(mut values: Array(Ref(int, false), 1), imm reference: Ref(int, false))
        \\    values = Array(Ref(int, false), 1).filled(reference)
        \\func run() int
        \\    const original = 42
        \\    var values = Array(Ref(int, false), 1).filled(borrow_local(int, original))
        \\    if 1 == 1
        \\        const temporary = 17
        \\        borrow mut selected = values
        \\        overwrite(selected, borrow_local(int, temporary))
        \\    if const selected = values.get(0) -> return selected[][]
        \\    return 90
        \\exit(run())
    , .borrow_outlives_source);
}

test "Array dereferenced mutable aliases cannot retain short-lived references" {
    try Fixture.expectDiagnostic(
        \\import std.memory.{borrow_local}
        \\func overwrite(mut values: Array(Ref(int, false), 1), imm reference: Ref(int, false))
        \\    values = Array(Ref(int, false), 1).filled(reference)
        \\fallible run() int
        \\    const original = 42
        \\    var owner = Box.new?(Array(Ref(int, false), 1).filled(borrow_local(int, original)))
        \\    if 1 == 1
        \\        const temporary = 17
        \\        borrow mut selected = owner.borrow_mut()[]
        \\        overwrite(selected, borrow_local(int, temporary))
        \\    borrow selected = owner.borrow()[]
        \\    if const element = selected.get(0) -> return element[][]
        \\    return 90
        \\if const answer = run() -> exit(answer) else exit(91)
    , .borrow_outlives_source);
}

test "Array boxed mutable aliases retain long-lived reference origins" {
    try Fixture.expectExit(
        \\import std.memory.{borrow_local}
        \\func overwrite(mut values: Array(Ref(int, false), 1), imm reference: Ref(int, false))
        \\    values = Array(Ref(int, false), 1).filled(reference)
        \\fallible run() int
        \\    const original = 17
        \\    const replacement = 42
        \\    var owner = Box.new?(Array(Ref(int, false), 1).filled(borrow_local(int, original)))
        \\    if 1 == 1
        \\        borrow mut selected = owner.borrow_mut()[]
        \\        overwrite(selected, borrow_local(int, replacement))
        \\    borrow selected = owner.borrow()[]
        \\    if const element = selected.get(0) -> return element[][]
        \\    return 90
        \\if const answer = run() -> exit(answer) else exit(91)
    , 42);
}

test "Array mutable aliases reject reference writes without a tracked owner" {
    try Fixture.expectDiagnostic(
        \\import std.memory.{borrow_local}
        \\func overwrite(mut values: Array(Ref(int, false), 1), imm reference: Ref(int, false))
        \\    values = Array(Ref(int, false), 1).filled(reference)
        \\func change(imm target: Ref(Array(Ref(int, false), 1), true), imm replacement: Ref(int, false))
        \\    borrow mut selected = target[]
        \\    overwrite(selected, replacement)
        \\fallible run() int
        \\    const original = 42
        \\    var owner = Box.new?(Array(Ref(int, false), 1).filled(borrow_local(int, original)))
        \\    change(owner.borrow_mut(), borrow_local(int, original))
        \\    return 42
        \\if const answer = run() -> exit(answer) else exit(91)
    , .borrow_write_cannot_store_borrow);
}

test "compile-time direct scalar arguments copy caller storage before mutation" {
    try Fixture.expectParity(
        \\func observe(imm captured: int, imm target: Ref(int, true)) int
        \\    target.replace(22)
        \\    return captured + 22
        \\func run() int
        \\    var values = Array(int, 1).filled(20)
        \\    if const target = values.get_mut(0) -> return observe(target[], target)
        \\    return 90
    , 42);
}

test "compile-time variant coercion preserves returned reference payloads" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int, false)) Ref(int, false) | none -> reference
        \\func run() int
        \\    const values = Array(int, 1).filled(42)
        \\    if const reference = values.get(0)
        \\        if const selected = choose(reference) as Ref(int, false) -> return selected[]
        \\    return 90
    , 42);
}

test "Array immutable arguments permit widening address-passed movable values" {
    try Fixture.expectParity(
        \\func inspect(imm possible: Array(int, 2) | none) int
        \\    if const values = possible as Array(int, 2)
        \\        if const selected = values.get(1) -> return selected[]
        \\    return 90
        \\func run() int
        \\    const values = Array(int, 2).filled(42)
        \\    return inspect(values)
    , 42);
}

test "compile-time direct reference arguments copy handles without copying referents" {
    try Fixture.expectParity(
        \\import std.memory.{borrow_local}
        \\func retarget(mut reference: Ref(int, false), imm replacement: Ref(int, false))
        \\    reference = replacement
        \\func run() int
        \\    const original = 20
        \\    const replacement = 22
        \\    var reference = borrow_local(int, original)
        \\    const captured = reference
        \\    retarget(reference, borrow_local(int, replacement))
        \\    return captured[] + reference[]
    , 42);
}

test "compile-time reference variants support widening and conditional results" {
    try Fixture.expectParity(
        \\func choose(imm reference: Ref(int, false)) Ref(int, false) | none
        \\    return if 1 == 1 -> reference else none
        \\func widen(imm possible: Ref(int, false) | none) Ref(int, false) | none | bool -> possible
        \\func run() int
        \\    const values = Array(int, 1).filled(42)
        \\    if const reference = values.get(0)
        \\        const possible = choose(reference)
        \\        if const selected = widen(possible) as Ref(int, false) -> return selected[]
        \\    return 90
    , 42);
}
