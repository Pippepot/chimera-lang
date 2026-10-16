const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "ranges construct ordinary cursors with native and comptime parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    const bounds = 2..^5
        \\    var cursor = bounds.iter()
        \\    var result = 0
        \\    loop
        \\        if not cursor.advance()? -> break
        \\        result += cursor.current()
        \\    if cursor.advance()? -> return 90
        \\    return result * 3
    , 42);
}

test "for ranges lower through ordinary loops with parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    var result = 0
        \\    for value in 2..^5
        \\        result += value
        \\    return result * 3
    , 42);
}

test "for range endpoints empty ranges and signed boundaries have parity" {
    const cases = [_]struct { range: []const u8, count: []const u8, sum: []const u8 }{
        .{ .range = "0..4", .count = "4", .sum = "6" },
        .{ .range = "0..^4", .count = "5", .sum = "10" },
        .{ .range = "2..2", .count = "0", .sum = "0" },
        .{ .range = "2..^2", .count = "1", .sum = "2" },
        .{ .range = "3..2", .count = "0", .sum = "0" },
        .{ .range = "3..^2", .count = "0", .sum = "0" },
        .{ .range = "2147483647..^2147483647", .count = "1", .sum = "2147483647" },
        .{ .range = "2147483646..^2147483647", .count = "2", .sum = "-3" },
        .{ .range = "2147483646..2147483647", .count = "1", .sum = "2147483646" },
        .{ .range = "-2147483648..^-2147483648", .count = "1", .sum = "-2147483648" },
        .{ .range = "-2147483648..-2147483646", .count = "2", .sum = "1" },
        .{ .range = "-2..^2", .count = "5", .sum = "0" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\func run() int
            \\    var count = 0
            \\    var sum = 0
            \\    for value in $range
            \\        count += 1
            \\        sum += value
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
        \\    if const result = found as int -> return result * 6
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
        \\    for value in cursor
        \\        sum += value
        \\        if value == 2 -> break
        \\    for value in cursor
        \\        sum += value
        \\        break
        \\    if cursor.current() <> 3 -> return 90
        \\    return sum * 7
    , 42);
}

test "for range values are reusable rather than shared cursors" {
    try Fixture.expectParity(
        \\func run() int
        \\    const bounds = 1..^3
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
        \\    for value in endpoint(trace, 1, 2)..^endpoint(trace, 2, 5)
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
        \\fallible calculate() int
        \\    var values = [1, 2, 3]
        \\    for ref value in values -> value *= 7
        \\    return values[0] + values[1] + values[2]
        \\func run() int
        \\    if const result = calculate() -> return result
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

test "for owns fresh immovable current results without relocating them" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    move = none
        \\    pub value: int
        \\struct Cursor
        \\    position: int
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return bool(self.position <= 2)
        \\    pub func current(ref self: Cursor) Item -> Item{value = self.position * 14}
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
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return bool(self.position <= self.limit)
        \\    pub func current(ref self: Cursor) int -> self.position * 14
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
        \\    if ref item = result as Item -> return item.value
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
        \\fallible calculate() int
        \\    var values = [5, 7]
        \\    var sum = 0
        \\    for var value in values
        \\        value *= 3
        \\        sum += value
        \\    if values[0] <> 5 -> return 90
        \\    if values[1] <> 7 -> return 91
        \\    return sum + 6
        \\func run() int
        \\    if const result = calculate() -> return result
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

test "for ref cannot alias owned current results" {
    try Fixture.expectSourceDiagnostic(
        \\for ref value in 0..3 -> value += 1
    , .borrow_requires_place);
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
        \\    if ref handle = retained as Ref(int) -> return handle.value
        \\    return 90
    , 42);
}

test "for fallible advance propagates failure rather than exhausting" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    position: int
        \\    pub fallible advance(mut self: Cursor) bool
        \\        if self.position == 2 -> fail
        \\        self.position += 1
        \\        return true
        \\    pub func current(ref self: Cursor) int -> self.position
        \\fallible walk(mut sum: int)
        \\    var cursor = Cursor{position = 0}
        \\    for value in cursor -> sum += value
        \\    sum = 90
        \\func run() int
        \\    var sum = 0
        \\    if walk(sum) -> return 91
        \\    if sum == 3 -> return 42
        \\    return 92
    , 42);
}

test "for fallible current propagates failure without an extra advance" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    position: int
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return true
        \\    pub fallible current(ref self: Cursor) int
        \\        if self.position == 2 -> fail
        \\        return self.position
        \\fallible walk(mut sum: int)
        \\    var cursor = Cursor{position = 0}
        \\    for value in cursor -> sum += value
        \\    sum = 90
        \\func run() int
        \\    var sum = 0
        \\    if walk(sum) -> return 91
        \\    if sum == 1 -> return 42
        \\    return 92
    , 42);
}

test "for fallible iterator factory propagates before the body" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\struct Source
        \\    pub fallible iter(ref self: Source) RangeIterator -> fail
        \\fallible walk(mut sum: int)
        \\    const source = Source{}
        \\    for value in source -> sum += value
        \\func run() int
        \\    var sum = 42
        \\    if walk(sum) -> return 90
        \\    return sum
    , 42);
}

test "range stepping and reversal compose as sequence operations" {
    const cases = [_]struct { expression: []const u8, digits: []const u8, count: []const u8 }{
        .{ .expression = "(0..10).step_by?(4)", .digits = "48", .count = "3" },
        .{ .expression = "(0..10).step_by?(4).reversed()", .digits = "840", .count = "3" },
        .{ .expression = "(0..10).reversed().step_by?(4)", .digits = "951", .count = "3" },
        .{ .expression = "(0..10).step_by?(2).step_by?(2)", .digits = "48", .count = "3" },
        .{ .expression = "(0..10).reversed().step_by?(2).step_by?(2)", .digits = "951", .count = "3" },
        .{ .expression = "(3..3).reversed().step_by?(2)", .digits = "0", .count = "0" },
        .{ .expression = "(3..^3).reversed().step_by?(2147483647)", .digits = "3", .count = "1" },
        .{ .expression = "(0..10).step_by?(2147483647)", .digits = "0", .count = "1" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\fallible calculate() int
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
            \\    if const result = calculate() -> return result
            \\    return 93
        , case);
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "range stepping rejects zero and negative factors" {
    try Fixture.expectParity(
        \\func run() int
        \\    const values = 0..10
        \\    if const invalid = values.step_by(0) -> return 90
        \\    if const invalid = values.step_by(-1) -> return 91
        \\    return 42
    , 42);
}

test "range stepping supports distances and composed strides wider than int" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    const complete = -2147483648..^2147483647
        \\    const huge = complete.step_by?(2147483647).step_by?(2)
        \\    var count = 0
        \\    var sum = 0
        \\    for value in huge
        \\        count += 1
        \\        sum += value
        \\        if count > 2 -> return 90
        \\    if count <> 2 -> return 91
        \\    if sum <> -2 -> return 92
        \\    var reversed = huge.reversed().iter()
        \\    if not reversed.advance()? -> return 93
        \\    if reversed.current() <> 2147483646 -> return 94
        \\    if not reversed.advance()? -> return 95
        \\    if reversed.current() <> -2147483648 -> return 96
        \\    if reversed.advance()? -> return 97
        \\    const singleton = huge.step_by?(2)
        \\    var single_count = 0
        \\    for value in singleton -> single_count += 1
        \\    if single_count <> 1 -> return 98
        \\    return 42
        \\func run() int
        \\    if const result = calculate() -> return result
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
                try checks.writer.print("    check?({d}, ({d}..{s}{d})", .{ selected_count, first, if (inclusive) "^" else "", limit });
                if (reverse_source) try checks.writer.writeAll(".reversed()");
                try checks.writer.print(".step_by?({d})", .{initial_factor});
                if (reverse_middle) try checks.writer.writeAll(".reversed()");
                try checks.writer.print(".step_by?({d})", .{following_factor});
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
        \\import std.range.{Range}
        \\fallible check(static N: int, values: Range, imm expected: Array(int, N))
        \\    var cursor = values.iter()
        \\    for value in expected
        \\        cursor.advance()?
        \\        cursor.current() == value
        \\    not cursor.advance()?
        \\fallible calculate() int
        \\$checks
        \\    return 42
        \\func run() int
        \\    if const result = calculate() -> return result
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
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return bool(self.position <= 5)
        \\    pub func current(ref self: Cursor) Item
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
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return bool(self.position <= 3)
        \\    pub func current(ref self: Cursor) Item
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
        \\    for item in [Item{trace = Ref.from(trace), value = 20}, Item{trace = Ref.from(trace), value = 22}]
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
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return true
        \\    pub func current(ref self: Cursor) int -> self.position
        \\func run() int
        \\    var trace = 0
        \\    var cursor = Cursor{trace = Ref.from(trace), position = 0}
        \\    for value in cursor -> break
        \\    if trace <> 0 -> return 90
        \\    for value in cursor -> break
        \\    if cursor.current() <> 2 -> return 91
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
        \\        if const number = value as int -> sum += number
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
        \\    value: int
        \\    pub func advance(mut self: Mapped) bool
        \\        if not self.source.advance()? -> return false
        \\        self.trace.value += 1
        \\        self.value = self.source.current() * 2
        \\        return true
        \\    pub func current(ref self: Mapped) int -> self.value
        \\struct Filtered
        \\    source: Mapped
        \\    value: int
        \\    pub func advance(mut self: Filtered) bool
        \\        loop
        \\            if not self.source.advance()? -> return false
        \\            const value = self.source.current()
        \\            if value % 4 == 0
        \\                self.value = value
        \\                return true
        \\    pub func current(ref self: Filtered) int -> self.value
        \\struct Taken
        \\    source: Filtered
        \\    remaining: int
        \\    pub func advance(mut self: Taken) bool
        \\        if self.remaining == 0 -> return false
        \\        if not self.source.advance()? -> return false
        \\        self.remaining -= 1
        \\        return true
        \\    pub func current(ref self: Taken) int -> self.source.current()
        \\func run() int
        \\    var trace = 0
        \\    const bounds = 0..100
        \\    var cursor = Taken{
        \\        source = Filtered{
        \\            source = Mapped{source = bounds.iter(), trace = Ref.from(trace), value = 0},
        \\            value = 0,
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
        \\import std.range.{Range}
        \\fallible check(values: Range, first: int, last: int, stride: int, descending: bool)
        \\    var cursor = values.iter()
        \\    var expected = first
        \\    loop
        \\        if descending?
        \\            if expected < last -> break
        \\        else
        \\            if expected > last -> break
        \\        cursor.advance()?
        \\        cursor.current() == expected
        \\        if descending? -> expected -= stride
        \\        else expected += stride
        \\    not cursor.advance()?
        \\fallible calculate() int
        \\    for first in -4..^4
        \\        for limit in -4..^4
        \\            for stride in 1..^4
        \\                const exclusive = (first..limit).step_by?(stride)
        \\                const inclusive = (first..^limit).step_by?(stride)
        \\                check?(exclusive, first, limit - 1, stride, false)
        \\                check?(inclusive, first, limit, stride, false)
        \\                if first < limit
        \\                    const end = first + ((limit - first - 1) / stride) * stride
        \\                    check?(exclusive.reversed(), end, first, stride, true)
        \\                else
        \\                    check?(exclusive.reversed(), 0, 1, stride, true)
        \\                if first <= limit
        \\                    const end = first + ((limit - first) / stride) * stride
        \\                    check?(inclusive.reversed(), end, first, stride, true)
        \\                else
        \\                    check?(inclusive.reversed(), 0, 1, stride, true)
        \\                const twice = inclusive.step_by?(3)
        \\                check?(twice, first, limit, stride * 3, false)
        \\    return 42
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "for filter can buffer and transfer move only owned items once" {
    try Fixture.expectParity(
        \\import std.exit.{exit}
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
        \\    pub func advance(mut self: Filtered) bool
        \\        loop
        \\            self.position += 1
        \\            if self.position > 4 -> return false
        \\            self.buffered = Item{value = self.position, trace = self.trace}
        \\            if ref item = self.buffered as Item
        \\                if item.value % 2 == 0 -> return true
        \\            self.buffered = none
        \\    pub func current(mut self: Filtered) Item
        \\        if const item = self.buffered^ as Item
        \\            self.buffered = none
        \\            return item^
        \\        self.buffered = none
        \\        exit(134)
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
        \\        const values = 20..^22
        \\        return values.iter()
        \\    pub func advance(mut self: Source) bool -> false
        \\    pub func current(ref self: Source) int -> 99
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
        \\    pub func advance(mut self: Source) bool -> false
        \\    pub func current(ref self: Source) int -> 42
        \\var source = Source{}
        \\for value in source -> exit(value)
    , .unknown_namespace_member);
}

test "for advance must return bool rather than success payload data" {
    const result_types = [_][]const u8{ "int", "unit" };
    const results = [_][]const u8{ "0", "()" };
    const effects = [_][]const u8{ "func", "fallible" };
    for (result_types, results) |result_type, result| {
        for (effects) |effect| {
            const source = try test_sources.renderTemplate(std.testing.allocator,
                \\struct Cursor
                \\    pub $effect advance(mut self: Cursor) $result_type -> $result
                \\    pub func current(ref self: Cursor) int -> 42
                \\fallible run()
                \\    var cursor = Cursor{}
                \\    for value in cursor -> exit(value)
                \\if run() -> exit(0)
            , .{ .effect = effect, .result_type = result_type, .result = result });
            defer std.testing.allocator.free(source);
            try Fixture.expectSourceDiagnostic(source, .query_operand_not_bool);
        }
    }
}

test "for zip advances independent borrowed cursors from left to right" {
    try Fixture.expectParity(
        \\import std.memory.{SpanIterator}
        \\struct Pair
        \\    pub ref left: int
        \\    pub ref right: int
        \\struct Zipped
        \\    left: SpanIterator(int)
        \\    right: SpanIterator(int)
        \\    ended: bool
        \\    pub func advance(mut self: Zipped) bool
        \\        if self.ended? -> return false
        \\        if self.left.advance()?
        \\            if self.right.advance()? -> return true
        \\        self.ended = true
        \\        return false
        \\    pub func current(ref self: Zipped) Pair
        \\        return Pair{left = self.left.current(), right = self.right.current()}
        \\func run() int
        \\    var left = [10, 20, 99]
        \\    var right = [5, 7]
        \\    var cursor = Zipped{left = left.iter(), right = right.iter(), ended = false}
        \\    var sum = 0
        \\    for pair in cursor -> sum += pair.left + pair.right
        \\    if cursor.advance()? -> return 90
        \\    return sum
    , 42);
}

test "for flatten stores outer and active inner cursor state without suspension" {
    try Fixture.expectParity(
        \\import std.range.{RangeIterator}
        \\import std.exit.{exit}
        \\struct Flattened
        \\    outer: RangeIterator
        \\    inner: RangeIterator | none
        \\    pub func advance(mut self: Flattened) bool
        \\        loop
        \\            if ref inner = self.inner as RangeIterator
        \\                if inner.advance()? -> return true
        \\            self.inner = none
        \\            if not self.outer.advance()? -> return false
        \\            const values = 0..self.outer.current()
        \\            self.inner = values.iter()
        \\    pub func current(ref self: Flattened) int
        \\        if ref inner = self.inner as RangeIterator -> return inner.current()
        \\        exit(134)
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
        \\    pub fallible advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        if self.position > 2 -> return false
        \\        self.buffered.append?("next")
        \\        return true
        \\    pub func current(ref self: Cursor) StringView -> self.buffered.view()
        \\fallible run()
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    var retained: StringView | none = none
        \\    for value in cursor
        \\        if retained is none -> retained = value
        \\    if ref view = retained as StringView -> print(view)
        \\if run() -> exit(0)
    , .borrow_outlives_source);
}

test "for cursor lifetimes permit lending reused buffer views within each body" {
    for ([_][]const u8{ "func", "fallible" }) |effect| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Cursor
            \\    position: int
            \\    buffered: String
            \\    pub fallible advance(mut self: Cursor) bool
            \\        self.position += 1
            \\        if self.position > 2 -> return false
            \\        self.buffered.append?("next")
            \\        return true
            \\    pub $effect current(ref self: Cursor) StringView -> self.buffered.view()
            \\fallible calculate() int
            \\    var total = 30
            \\    for view in Cursor{position = 0, buffered = ""}
            \\        total += view.byte_length()
            \\    return total
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 90
        , .{ .effect = effect });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "for cursor lifetimes preserve borrowed factory results and resume their state" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    position: int
        \\    pub func advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        return bool(self.position <= 2)
        \\    pub func current(ref self: Cursor) int -> self.position * 14
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
    const stages = [_]struct { factory: []const u8, advance: []const u8, current: []const u8, body: []const u8, expected: u8 }{
        .{ .factory = "fail", .advance = "true", .current = "Item{trace = self.trace}", .body = "fail", .expected = 30 },
        .{ .factory = "Cursor{trace = self.trace}", .advance = "fail", .current = "Item{trace = self.trace}", .body = "fail", .expected = 40 },
        .{ .factory = "Cursor{trace = self.trace}", .advance = "true", .current = "fail", .body = "fail", .expected = 40 },
        .{ .factory = "Cursor{trace = self.trace}", .advance = "true", .current = "Item{trace = self.trace}", .body = "fail", .expected = 41 },
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
            \\    pub fallible advance(mut self: Cursor) bool -> $advance
            \\    pub fallible current(ref self: Cursor) Item -> $current
            \\struct Source
            \\    trace: Ref(int)
            \\    drop = func(deinit self: Source)
            \\        self.trace.value += 30
            \\    pub fallible iter(ref self: Source) Cursor -> $factory
            \\fallible walk(mut trace: int)
            \\    for item in Source{trace = Ref.from(trace)} -> $body
            \\func run() int
            \\    var trace = 0
            \\    if walk(trace) -> return 90
            \\    return trace
        , .{ .factory = stage.factory, .advance = stage.advance, .current = stage.current, .body = stage.body });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, stage.expected);
    }
}

test "cursor method invalidation rejects a view retained across two calls" {
    try Fixture.expectSourceDiagnostic(
        \\struct Cursor
        \\    buffered: String
        \\    pub fallible advance(mut self: Cursor)
        \\        self.buffered.append?("next")
        \\    pub func current(ref self: Cursor) StringView -> self.buffered.view()
        \\fallible run()
        \\    var cursor = Cursor{buffered = ""}
        \\    cursor.advance?()
        \\    const retained = cursor.current()
        \\    cursor.advance?()
        \\    print(retained)
        \\if run() -> exit(0)
    , .borrow_outlives_source);
}

test "cursor method invalidation rejects a view retained across manual loop iterations" {
    try Fixture.expectSourceDiagnostic(
        \\struct Cursor
        \\    position: int
        \\    buffered: String
        \\    pub fallible advance(mut self: Cursor) bool
        \\        self.position += 1
        \\        if self.position > 2 -> return false
        \\        self.buffered.append?("next")
        \\        return true
        \\    pub func current(ref self: Cursor) StringView -> self.buffered.view()
        \\fallible run()
        \\    var cursor = Cursor{position = 0, buffered = ""}
        \\    var retained: StringView | none = none
        \\    loop
        \\        if not cursor.advance?()? -> break
        \\        const value = cursor.current()
        \\        if retained is none -> retained = value
        \\    if ref view = retained as StringView -> print(view)
        \\if run() -> exit(0)
    , .borrow_outlives_source);
}

test "for live list cursors reject backing relocation" {
    try Fixture.expectSourceDiagnostic(
        \\fallible run()
        \\    var values: List(int) = [1, 2]
        \\    for value in values
        \\        print("value")
        \\        values.reserve?(100)
        \\if run() -> exit(0)
    , .borrow_outlives_source);
}
