const std = @import("std");
const sources = @import("test_sources");
const Fixture = sources.SourceFixture;
const structures = sources.structures;
const queries = sources.queries;

test "integer widths retain arithmetic shift bitwise and memory semantics in both engines" {
    for ([_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize" }) |kind| {
        const source = try sources.renderTemplate(std.testing.allocator,
            \\struct Pair
            \\    copy = trivial
            \\    pub first: $T
            \\    pub second: $T
            \\func calculate(left: $T, right: $T) $T
            \\    var value = left * right
            \\    value += 4
            \\    value <<= 1
            \\    value >>= 1
            \\    value ^= 7
            \\    value &= 63
            \\    value |= 2
            \\    return value
            \\func run() int
            \\    var pair = Pair{first = 3, second = 12}
            \\    pair.second = calculate(pair.first, pair.second)
            \\    if pair.second <> 47 -> return 90
            \\    if (~pair.first & 3) <> 0 -> return 91
            \\    if (pair.second ^ 5) <> 42 -> return 92
            \\    var array: Array($T, 2) = [19, 23]
            \\    array[0] = array[0] + array[1]
            \\    const result = checked(i32, array[0])
            \\    if result is int -> return result
            \\    return 93
        , .{ .T = kind });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "integer literals use all radices arbitrary magnitudes and contextual ranges" {
    try Fixture.expectParity(
        \\struct Huge
        \\    copy = trivial
        \\    pub value: bool
        \\converter(static value: int_literal) Huge where value == 340282366920938463463374607431768211456 -> Huge{value = true}
        \\func run() int
        \\    const a: u64 = 0xffff_ffff_ffff_ffff
        \\    const b: i64 = -0x8000_0000_0000_0000
        \\    const c: u16 = 0o177777
        \\    const d: u8 = 0b1111_1111
        \\    const huge: Huge = 340282366920938463463374607431768211456
        \\    const exact: f64 = 1267650600228229401496703205376
        \\    if not huge.value or exact <> 1.267650600228229401496703205376e30 -> return 90
        \\    if wrapping(a + 1) <> 0 or wrapping(b - 1) <> 9223372036854775807 -> return 91
        \\    if c <> 65535 or d <> 255 -> return 92
        \\    return 0x2e-4
    , 42);
    for ([_][]const u8{
        "const x: u64 = 18446744073709551616",
        "const x: i64 = -9223372036854775809",
        "const x: u8 = -1",
        "const x: f32 = 16777217",
    }) |source| try Fixture.expectSourceDiagnostic(source, .integer_literal_out_of_range);
}

test "wrapping saturation nested contexts and ordinary function boundaries agree" {
    try Fixture.expectParity(
        \\func ordinary(left: i8, right: i8) i8 -> saturating(left + right)
        \\func calculate(maximum: i8, minimum: i8, one: i8) int
        \\    if wrapping(maximum + one) <> minimum -> return 90
        \\    if saturating(maximum + one) <> maximum -> return 91
        \\    if saturating(maximum * one + one - one) <> 126 -> return 92
        \\    if wrapping(saturating(maximum + one) + one) <> minimum -> return 93
        \\    if saturating(wrapping(maximum + one) - one) <> minimum -> return 94
        \\    if wrapping(ordinary(maximum, one)) <> maximum -> return 95
        \\    if wrapping(minimum / -1) <> minimum -> return 96
        \\    if saturating(minimum / -1) <> maximum -> return 97
        \\    if minimum % -1 <> 0 or -7 % 3 <> -1 -> return 98
        \\    return 42
        \\func run() int -> calculate(127, -128, 1)
    , 42);
    try Fixture.expectSourceDiagnostic("const value: i8 = 127\nconst result = value + 1", .compile_time_integer_overflow);
    try Fixture.expectSourceDiagnostic("static result = 2147483647 + 1\nexit(result)", .compile_time_integer_overflow);
}

test "integer conversion policies distinguish exact modular and clamped results" {
    try Fixture.expectParity(
        \\func calculate(value: i64, high: u64) int
        \\    const small = checked(i8, value)
        \\    if not (small is none) -> return 90
        \\    if wrap(u8, value) <> 255 or saturate(i8, value) <> 127 -> return 91
        \\    if saturate(u8, i64(-20)) <> 0 -> return 92
        \\    if saturate(i64, high) <> 9223372036854775807 -> return 93
        \\    const signed = checked(i64, high)
        \\    if not (signed is none) -> return 94
        \\    const wide: i64 = i8(42)
        \\    const widened: f64 = i32(42)
        \\    if wide <> 42 or widened <> 42.0 -> return 95
        \\    return 42
        \\func run() int -> calculate(511, 18446744073709551615)
    , 42);
}

test "conversions read borrowed heap elements before their owner ends" {
    try Fixture.expectParity(
        \\func read(index: int) int | AllocationError
        \\    var values: List(byte) = []
        \\    _ = values.append(5)?
        \\    _ = values.append(37)?
        \\    return wrap(i32, values[index])
        \\func run() int
        \\    var values: List(i64) = []
        \\    if not (values.append(-1) is unit) -> return 92
        \\    if not (values.append(300) is unit) -> return 93
        \\    const saturated = saturate(u8, values[1])
        \\    const checked_value = checked(i16, values[1])
        \\    if not (checked_value is i16) -> return 90
        \\    if saturated <> 255 or checked_value <> 300 -> return 91
        \\    const result = read(1) catch -> return 94
        \\    return result + int(wrap(u8, values[0])) - 250
    , 42);
}

test "float formats preserve direct literal rounding subnormals NaNs and signed zero" {
    try Fixture.expectParity(
        \\func calculate(value: f32, negative: f64) int
        \\    if value <> 1.00000011920928955078125 -> return 90
        \\    if negative <> 0.0 or 1.0 / negative <> -f64.inf -> return 91
        \\    if f32.nan == f32.nan or not (f64.nan <> f64.nan) -> return 92
        \\    if f32.nan < 1.0 or f32.nan >= 1.0 -> return 93
        \\    const tiny: f32 = 1.401298464324817070923729583289916131280e-45
        \\    if tiny == 0.0 or tiny / 2.0 <> 0.0 -> return 94
        \\    if f32.inf + -f32.inf == 0.0 -> return 95
        \\    return 42
        \\func run() int -> calculate(1.000000059604644775390625000000000000000000000000001, -0.0)
    , 42);
    for ([_][]const u8{ "const x: f32 = 1e40", "const x: f32 = 3.4028235e38", "const x: f32 = 1e-60", "const x = 1e400", "const x = 1e-4000" }) |source|
        try Fixture.expectSourceDiagnostic(source, .float_literal_out_of_range);
}

test "float conversion policies preserve ties invalid results and unsigned high half" {
    try Fixture.expectParity(
        \\func calculate(half: f64, negative: f64, high: u64) int
        \\    const even = round(i32, half)
        \\    if not (even is int) -> return 90
        \\    if even <> 42 -> return 91
        \\    const odd = round(i32, half + 1.0)
        \\    if not (odd is int) -> return 92
        \\    if odd <> 44 -> return 93
        \\    const truncated = truncate(i8, negative)
        \\    if not (truncated is i8) -> return 94
        \\    if truncated <> -42 -> return 95
        \\    const exact = checked(i32, half)
        \\    if not (exact is none) -> return 96
        \\    const nan = saturate(u64, f64.nan)
        \\    if not (nan is none) -> return 97
        \\    const clamped = saturate(i8, f64.inf)
        \\    if not (clamped is i8) -> return 98
        \\    if clamped <> 127 -> return 99
        \\    const encoded = checked(f64, high)
        \\    if not (encoded is f64) -> return 100
        \\    const decoded = checked(u64, encoded)
        \\    if not (decoded is u64) -> return 101
        \\    if decoded <> high -> return 102
        \\    const overflow = round(f32, f64.inf)
        \\    if overflow <> f32.inf -> return 103
        \\    return 42
        \\func run() int -> calculate(42.5, -42.9, 9223372036854777856)
    , 42);
}

test "numeric edits invalidate typed widths policies and recover diagnostics" {
    const fixture = try Fixture.init("const value: i8 = 126\nexit(i32(value + 1))");
    defer fixture.deinit();
    try fixture.expectExit(0, 127);
    try fixture.db.setInput(queries.SourceText, 0, "const value: i8 = 127\nexit(i32(value + 1))");
    try fixture.expectDiagnostic(0, .compile_time_integer_overflow);
    try fixture.db.setInput(queries.SourceText, 0, "const value: i8 = 127\nexit(i32(saturating(value + 1)))");
    try fixture.expectExit(0, 127);
    try fixture.db.setInput(queries.SourceText, 0, "const value: i16 = 127\nexit(i32(value + 1))");
    try fixture.expectExit(0, 128);
}

test "runtime checked operations retain panics when their results are discarded" {
    for ([_][]const u8{
        "func fail(value: int)\n    value + 1\nfail(2147483647)",
        "func fail(value: i8)\n    -value\nfail(-128)",
        "func fail(value: u64)\n    value * 2\nfail(18446744073709551615)",
        "func fail(value: int)\n    wrapping(value / 0)\nfail(42)",
        "func fail(value: int)\n    saturating(value << 32)\nfail(42)",
    }) |source| {
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        const result = try fixture.runIo("");
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
        try std.testing.expect(std.mem.startsWith(u8, result.stderr, "panic: invalid numeric operation\n"));
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, "at fail ") != null);
    }
}

test "overflow contexts survive deferred initialization and nested panic relocations" {
    try Fixture.expectParity(
        \\func build(value: i8) int
        \\    var owner = wrapping(Box(i8).new(value + 1))
        \\    if not (owner is Box(i8)) -> return 90
        \\    if owner.borrow() <> -128 -> return 91
        \\    return 42
        \\func run() int -> build(127)
    , 42);
    const fixture = try Fixture.init("func build(value: int)\n    var owner = Box(int).new(value + 1)\nbuild(2147483647)");
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "at build ") != null);
}

test "64 bit signed and unsigned arithmetic preserve overflow and division policies" {
    try Fixture.expectParity(
        \\func signed(maximum: i64, minimum: i64, one: i64) bool
        \\    if wrapping(maximum + one) <> minimum -> return false
        \\    if saturating(maximum * 2) <> maximum -> return false
        \\    if saturating(minimum * 2) <> minimum -> return false
        \\    if saturating(-minimum) <> maximum -> return false
        \\    if wrapping(minimum / -one) <> minimum -> return false
        \\    if saturating(minimum / -one) <> maximum -> return false
        \\    if minimum % -one <> 0 -> return false
        \\    if minimum >> 63 <> -one -> return false
        \\    return true
        \\func unsigned(maximum: u64, one: u64) bool
        \\    if wrapping(maximum + one) <> 0 -> return false
        \\    if saturating(maximum + one) <> maximum -> return false
        \\    if saturating(maximum * maximum) <> maximum -> return false
        \\    if wrapping(maximum * maximum) <> one -> return false
        \\    if saturating(one - maximum) <> 0 -> return false
        \\    if maximum / 2 <> 9223372036854775807 -> return false
        \\    if maximum >> 63 <> one -> return false
        \\    return true
        \\func run() int
        \\    if not signed(9223372036854775807, -9223372036854775808, 1) -> return 90
        \\    if not unsigned(18446744073709551615, 1) -> return 91
        \\    return 42
    , 42);
}

test "numeric form names honor ordinary declarations and incremental absence dependencies" {
    try Fixture.expectParity(
        \\func checked(value: int) int -> value
        \\func wrapping(value: int) int -> value + 2
        \\func run() int -> wrapping(checked(40))
    , 42);
    const fixture = try Fixture.init("exit(wrapping(40 + 2))");
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, "func wrapping(value: int) int -> value + 1\nexit(wrapping(40 + 2))");
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(queries.SourceText, 0, "exit(wrapping(40 + 2))");
    try fixture.expectExit(0, 42);
}

test "native numeric parameters exercise boundaries without inlining" {
    const source =
        \\func signed(value: i16, minimum: i16, maximum: i16) bool
        \\    if saturating(value * maximum) <> maximum -> return false
        \\    if saturating(minimum - value) <> minimum -> return false
        \\    if wrapping(-minimum) <> minimum -> return false
        \\    if minimum % -1 <> 0 or minimum / 2 <> -16384 -> return false
        \\    if minimum >> 15 <> -1 or wrapping(minimum << 1) <> 0 -> return false
        \\    return true
        \\func unsigned(maximum: u32, one: u32) bool
        \\    if saturating(maximum * maximum) <> maximum -> return false
        \\    if wrapping(maximum * maximum) <> one -> return false
        \\    if saturating(one - maximum) <> 0 or saturating(-one) <> 0 -> return false
        \\    if maximum / 2 <> 2147483647 or maximum % 2 <> one -> return false
        \\    if maximum >> 31 <> one -> return false
        \\    return true
        \\func conversions(value: f64, maximum: u64) bool
        \\    const rounded = round(u8, value)
        \\    if not (rounded is u8) -> return false
        \\    if rounded <> 0 -> return false
        \\    const too_large = checked(f64, maximum)
        \\    if not (too_large is none) -> return false
        \\    if round(f64, maximum) <> 18446744073709551616.0 -> return false
        \\    const too_small = truncate(i8, -129.0 + value)
        \\    if not (too_small is none) -> return false
        \\    return true
        \\func run() int
        \\    if not signed(2, -32768, 32767) -> return 90
        \\    if not unsigned(4294967295, 1) -> return 91
        \\    if not conversions(-0.5, 18446744073709551615) -> return 92
        \\    return 42
    ;
    try Fixture.expectParity(source, 42);
    const fixture = try Fixture.init(source ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
}

test "removing equality loops preserves checked recurrence panics" {
    const fixture = try Fixture.init(
        \\func spin(start: int)
        \\    var index = start
        \\    loop
        \\        if index == 0 -> break
        \\        index -= 1
        \\spin(-2147483648)
    );
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
}

test "stored integer literals use the same contextual numeric union targets" {
    try Fixture.expectParity(
        \\static literal: int_literal = 42
        \\func run() int
        \\    const signed: i64 | none = literal
        \\    const unsigned: u64 | none = literal
        \\    const floating: f32 | none = literal
        \\    if not (signed is i64) or not (unsigned is u64) or not (floating is f32) -> return 90
        \\    if signed <> 42 or unsigned <> 42 or floating <> 42.0 -> return 91
        \\    return 42
    , 42);
    try Fixture.expectSourceExit(
        \\func literal_value() int_literal -> 42
        \\func calculate() int
        \\    var literal: int_literal = 40
        \\    literal = 42
        \\    const signed: i64 | none = literal
        \\    const unsigned: u64 | none = literal_value()
        \\    if not (signed is i64) or not (unsigned is u64) -> return 90
        \\    if signed <> 42 or unsigned <> 42 -> return 91
        \\    return 42
        \\static answer = calculate()
        \\exit(answer)
    , 42);
    try Fixture.expectSourceDiagnostic("func choose(static n: int) int -> n\nexit(choose(4__2))", .invalid_numeric_literal);
}

test "wrapping contexts do not specialize user defined numeric operators" {
    const fixture = try Fixture.init(
        \\struct Number
        \\    copy = trivial
        \\    pub value: int
        \\    pub func +(imm left: Number, imm right: Number) Number -> Number{value = left.value * right.value}
        \\func calculate(value: int) int -> wrapping((Number{value = value} + Number{value = 2}).value)
        \\exit(calculate(1073741824))
    );
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
}

test "cold numeric traps preserve the failed operation source location" {
    for ([_][]const u8{ "2147483647, 1", "1, 2147483647" }, [_]u8{ 2, 3 }) |arguments, line| {
        const source = try std.testing.allocator.print(
            \\func fail(left: int, right: int) int
            \\    const sum = left + 1
            \\    const product = right * 2
            \\    return sum + product
            \\exit(fail({s}))
        , .{arguments});
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        try fixture.db.addInput(queries.InlineLimit, {}, 0);
        const result = try fixture.runIo("");
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);
        const location = try std.testing.allocator.print("at fail (main.chi:{d}:", .{line});
        defer std.testing.allocator.free(location);
        errdefer std.debug.print("{s}\n", .{result.stderr});
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
        try std.testing.expect(std.mem.indexOf(u8, result.stderr, location) != null);
    }
}

test "division and remainder by constants match runtime divisors across the integer range" {
    const divisors = [_]i32{ 2, 3, 4, 5, 6, 7, 8, 10, 25, 60, 63, 65, 100, 641, 1024, 65535, 65537, 1000003, 1073741824, 1073741825, 2147483647, -2, -3, -4, -7, -8, -1000, -65537, -2147483647, -2147483648 };
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(std.testing.allocator);
    try program.appendSlice(std.testing.allocator,
        \\func zero(n: int) int
        \\    if n <= 0 -> return 0
        \\    return zero(n - 1)
        \\func check(x: int) int
        \\
    );
    for (divisors, 0..) |divisor, index| {
        // The literal divisor is a compile-time constant; zero(3) hides the variable one from the optimizer.
        try program.print(std.testing.allocator,
            \\    const v{d} = wrapping({d} + zero(3))
            \\    if x / {d} <> x / v{d} -> return {d}
            \\    if x % {d} <> x % v{d} -> return {d}
            \\
        , .{ index, divisor, divisor, index, 100 + index, divisor, index, 200 + index });
    }
    try program.appendSlice(std.testing.allocator,
        \\    return 0
        \\func run() int
        \\    const edges = [0, 1, -1, 2, -2, 7, -7, 2147483647, 2147483646, -2147483647, wrapping(0 - 2147483647 - 1)]
        \\    for edge in edges
        \\        const bad = check(edge)
        \\        if bad <> 0 -> return bad
        \\    var state = 12345
        \\    for step in 0..400
        \\        state = wrapping(state * 1103515245 + 12345)
        \\        var x = state
        \\        if step % 4 == 1 -> x = state / 65536
        \\        if step % 4 == 2 -> x = state / 16777216
        \\        const bad = check(x)
        \\        if bad <> 0 -> return bad
        \\    return 42
    );
    try Fixture.expectParity(program.items, 42);
}

test "constant division and remainder agree with runtime divisors for every integer width" {
    const Case = struct { name: []const u8, signed: bool, bits: u7 };
    const cases = [_]Case{
        .{ .name = "i8", .signed = true, .bits = 8 },    .{ .name = "i16", .signed = true, .bits = 16 },
        .{ .name = "i32", .signed = true, .bits = 32 },  .{ .name = "i64", .signed = true, .bits = 64 },
        .{ .name = "u8", .signed = false, .bits = 8 },   .{ .name = "u16", .signed = false, .bits = 16 },
        .{ .name = "u32", .signed = false, .bits = 32 }, .{ .name = "u64", .signed = false, .bits = 64 },
    };
    const divisors = [_]i128{ 2, 3, 4, 5, 6, 7, 8, 10, 16, 25, 100, 127, 128, 255, 256, 641, 1000, 32767, 32768, 65535, 65537, 1000003, 2147483647, 2147483648, 4294967295, 4294967297, 1099511627776, 9223372036854775807, 9223372036854775808, 18446744073709551615, -2, -3, -4, -7, -8, -100, -128, -1000, -32768, -2147483648, -9223372036854775808 };
    for (cases) |case| {
        var program: std.ArrayList(u8) = .empty;
        defer program.deinit(std.testing.allocator);
        try program.appendSlice(std.testing.allocator,
            \\func zero(n: int) int
            \\    if n <= 0 -> return 0
            \\    return zero(n - 1)
            \\
        );
        try program.print(std.testing.allocator, "func check(x: {s}) int\n", .{case.name});
        const minimum: i128 = if (case.signed) -(@as(i128, 1) << (case.bits - 1)) else 0;
        const maximum: i128 = if (case.signed) (@as(i128, 1) << (case.bits - 1)) - 1 else (@as(i128, 1) << case.bits) - 1;
        var slot: usize = 0;
        for (divisors) |divisor| {
            if (divisor < minimum or divisor > maximum) continue;
            // The literal divisor is a compile-time constant; zero(3) hides the variable one from the optimizer.
            try program.print(std.testing.allocator,
                \\    const v{d}: {s} = wrapping(wrap({s}, zero(3)) + {d})
                \\    if x / {d} <> x / v{d} -> return {d}
                \\    if x % {d} <> x % v{d} -> return {d}
                \\
            , .{ slot, case.name, case.name, divisor, divisor, slot, 100 + slot, divisor, slot, 200 + slot });
            slot += 1;
        }
        try program.print(std.testing.allocator,
            \\    return 0
            \\func run() int
            \\    const edges: Array({s}, 7) = [0, 1, 2, 100, {d}, {d}, {d}]
            \\    for edge in edges
            \\        const bad = check(edge)
            \\        if bad <> 0 -> return bad
            \\    var state: i64 = 12345
            \\    for step in 0..300
            \\        state = wrapping(state * 6364136223846793005 + 1442695040888963407)
            \\        var x = wrap({s}, state)
            \\        if step % 3 == 1 -> x = wrap({s}, state >> 20)
            \\        if step % 3 == 2 -> x = wrap({s}, state >> 44)
            \\        const bad = check(x)
            \\        if bad <> 0 -> return bad
            \\    return 42
        , .{ case.name, maximum, minimum, minimum + 1, case.name, case.name, case.name });
        try Fixture.expectParity(program.items, 42);
    }
}

test "integer comparisons branch select and materialize identically in both engines for every width" {
    const Case = struct { name: []const u8, signed: bool, bits: u7 };
    const cases = [_]Case{
        .{ .name = "i8", .signed = true, .bits = 8 },    .{ .name = "i16", .signed = true, .bits = 16 },
        .{ .name = "i32", .signed = true, .bits = 32 },  .{ .name = "i64", .signed = true, .bits = 64 },
        .{ .name = "u8", .signed = false, .bits = 8 },   .{ .name = "u16", .signed = false, .bits = 16 },
        .{ .name = "u32", .signed = false, .bits = 32 }, .{ .name = "u64", .signed = false, .bits = 64 },
    };
    for (cases) |case| {
        const minimum: i128 = if (case.signed) -(@as(i128, 1) << (case.bits - 1)) else 0;
        const maximum: i128 = if (case.signed) (@as(i128, 1) << (case.bits - 1)) - 1 else (@as(i128, 1) << case.bits) - 1;
        var buffers: [4][48]u8 = undefined;
        const source = try sources.renderTemplate(std.testing.allocator,
            \\func relations(a: $T, b: $T) int
            \\    var total = 0
            \\    if a < b -> total += 1
            \\    if a <= b -> total += 2
            \\    if a > b -> total += 4
            \\    if a >= b -> total += 8
            \\    if a == b -> total += 16
            \\    if a <> b -> total += 32
            \\    const less = a < b
            \\    const equal = a == b
            \\    if less == equal -> total += 64
            \\    var low = a
            \\    if b < low -> low = b
            \\    var high = a
            \\    if b > high -> high = b
            \\    if low == b -> total += 128
            \\    if high == b -> total += 256
            \\    var chosen = 0
            \\    if a >= b -> chosen = 1
            \\    else chosen = 2
            \\    return total + chosen * 512
            \\func constants(a: $T) int
            \\    var total = 0
            \\    if a < 100 -> total += 1
            \\    if a >= 100 -> total += 2
            \\    if a == 0 -> total += 4
            \\    if a <> 1 -> total += 8
            \\    if a > 2 -> total += 16
            \\    if a <= 127 -> total += 32
            \\    return total
            \\func run() int
            \\    const values: Array($T, 9) = [0, 1, 2, 100, 127, $maximum, $minimum, $minimum_next, $maximum_prev]
            \\    var checksum = 0
            \\    for a in values
            \\        checksum = (checksum * 7 + constants(a)) % 1000003
            \\        for b in values
            \\            checksum = (checksum * 31 + relations(a, b)) % 1000003
            \\    return checksum % 251
        , .{ .T = case.name, .maximum = try std.fmt.bufPrint(&buffers[0], "{d}", .{maximum}), .minimum = try std.fmt.bufPrint(&buffers[1], "{d}", .{minimum}), .minimum_next = try std.fmt.bufPrint(&buffers[2], "{d}", .{minimum + 1}), .maximum_prev = try std.fmt.bufPrint(&buffers[3], "{d}", .{maximum - 1}) });
        defer std.testing.allocator.free(source);
        try Fixture.expectEnginesAgree(source);
    }
}

test "float arithmetic and ordered comparisons agree between engines including NaN and infinities" {
    for ([_][]const u8{ "f32", "f64" }) |kind| {
        const source = try sources.renderTemplate(std.testing.allocator,
            \\func zero(n: int) $T
            \\    if n <= 0 -> return 0.0
            \\    return zero(n - 1)
            \\func relations(a: $T, b: $T) int
            \\    var total = 0
            \\    if a < b -> total += 1
            \\    if a <= b -> total += 2
            \\    if a > b -> total += 4
            \\    if a >= b -> total += 8
            \\    if a == b -> total += 16
            \\    if a <> b -> total += 32
            \\    const greater = a > b
            \\    const less = b < a
            \\    if greater == less -> total += 64
            \\    if not (a < b) and not (a >= b) -> total += 128
            \\    if (a > b or a == b) -> total += 256
            \\    return total
            \\func arithmetic(a: $T, b: $T) int
            \\    const sum = a + b
            \\    const difference = a - b
            \\    const product = a * b
            \\    const quotient = a / b
            \\    var total = 0
            \\    if sum > a -> total += 1
            \\    if difference < a -> total += 2
            \\    if product >= b -> total += 4
            \\    if quotient <= a -> total += 8
            \\    if sum == difference -> total += 16
            \\    return total
            \\func run() int
            \\    const z = zero(2)
            \\    const nan = z / z
            \\    const infinity = (z + 1.0) / z
            \\    const values: Array($T, 7) = [z, z + 1.5, z - 2.25, z + 100.0, nan, infinity, z - infinity]
            \\    var checksum = 0
            \\    for a in values
            \\        for b in values
            \\            checksum = (checksum * 31 + relations(a, b)) % 1000003
            \\            checksum = (checksum * 7 + arithmetic(a, b)) % 1000003
            \\    return checksum % 251
        , .{ .T = kind });
        defer std.testing.allocator.free(source);
        try Fixture.expectEnginesAgree(source);
    }
}

test "integer arithmetic and bitwise operands in registers stack slots and constants agree between engines" {
    for ([_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64" }) |kind| {
        const source = try sources.renderTemplate(std.testing.allocator,
            \\func fold(value: $T) int -> wrap(i32, value)
            \\func mix(a: $T, b: $T, c: $T, d: $T) int
            \\    const e = wrapping(a + b)
            \\    const f = wrapping(b - c)
            \\    const g = wrapping(c * d)
            \\    const h = a & d
            \\    const i = b | c
            \\    const j = c ^ a
            \\    const k = wrapping(e + f)
            \\    const l = wrapping(g - h)
            \\    const m = wrapping(i * j)
            \\    const n = (k & l) | (m ^ e)
            \\    const o = wrapping(a + 7)
            \\    const p = wrapping(b * 3)
            \\    const q = wrapping(c - 100)
            \\    const r = d & 15
            \\    const s = a | 1
            \\    const t = b ^ 85
            \\    const u = wrapping(o + p) ^ wrapping(q - r)
            \\    var total = 0
            \\    total = wrapping(total * 31 + fold(e))
            \\    total = wrapping(total * 31 + fold(f))
            \\    total = wrapping(total * 31 + fold(g))
            \\    total = wrapping(total * 31 + fold(h))
            \\    total = wrapping(total * 31 + fold(i))
            \\    total = wrapping(total * 31 + fold(j))
            \\    total = wrapping(total * 31 + fold(k))
            \\    total = wrapping(total * 31 + fold(l))
            \\    total = wrapping(total * 31 + fold(m))
            \\    total = wrapping(total * 31 + fold(n))
            \\    total = wrapping(total * 31 + fold(o))
            \\    total = wrapping(total * 31 + fold(p))
            \\    total = wrapping(total * 31 + fold(q))
            \\    total = wrapping(total * 31 + fold(r))
            \\    total = wrapping(total * 31 + fold(s))
            \\    total = wrapping(total * 31 + fold(t))
            \\    total = wrapping(total * 31 + fold(u))
            \\    return total
            \\func divisible(value: $T) int
            \\    var total = 0
            \\    if value % 2 == 0 -> total += 1
            \\    if value % 8 <> 0 -> total += 2
            \\    if value % 64 == 0 -> total += 4
            \\    if value % 3 == 0 -> total += 8
            \\    return total
            \\func run() int
            \\    const values: Array($T, 8) = [0, 1, 2, 3, 100, $maximum, $minimum, $odd]
            \\    var checksum = 0
            \\    for a in values
            \\        checksum = wrapping(checksum * 7 + divisible(a))
            \\        for b in values
            \\            checksum = wrapping(checksum * 13 + mix(a, b, a, b) + mix(b, a, b, a))
            \\            checksum = wrapping(checksum * 13 + mix(a, b, wrapping(a + b), wrapping(a - b)))
            \\    return checksum % 251
        , .{ .T = kind, .maximum = maximumLiteral(kind), .minimum = minimumLiteral(kind), .odd = oddLiteral(kind) });
        defer std.testing.allocator.free(source);
        try Fixture.expectEnginesAgree(source);
    }
}

fn maximumLiteral(kind: []const u8) []const u8 {
    return std.StaticStringMap([]const u8).initComptime(.{
        .{ "i8", "127" }, .{ "i16", "32767" }, .{ "i32", "2147483647" }, .{ "i64", "9223372036854775807" },
        .{ "u8", "255" }, .{ "u16", "65535" }, .{ "u32", "4294967295" }, .{ "u64", "18446744073709551615" },
    }).get(kind).?;
}

fn minimumLiteral(kind: []const u8) []const u8 {
    return std.StaticStringMap([]const u8).initComptime(.{
        .{ "i8", "-128" }, .{ "i16", "-32768" }, .{ "i32", "-2147483648" }, .{ "i64", "-9223372036854775808" },
        .{ "u8", "0" },    .{ "u16", "0" },      .{ "u32", "0" },           .{ "u64", "0" },
    }).get(kind).?;
}

fn oddLiteral(kind: []const u8) []const u8 {
    return if (kind.len == 2 and kind[1] == '8') "77" else "12345";
}

test "std numeric helpers preserve widths bounds and floating comparison behavior" {
    try Fixture.expectParity(
        \\import std.math.{min, max, clamp}
        \\func run() int
        \\    const lo: i64 = -5000000000
        \\    const hi: i64 = 5000000000
        \\    if min(lo, hi) <> lo -> return 90
        \\    if max(lo, hi) <> hi -> return 91
        \\    if clamp(hi, lo, i64(42)) <> i64(42) -> return 92
        \\    const low: byte = 19
        \\    const high: byte = 23
        \\    if min(low, high) <> low -> return 93
        \\    if max(low, high) <> high -> return 94
        \\    if clamp(byte(42), low, high) <> high -> return 95
        \\    const small: f32 = 1.5
        \\    const large: f32 = 2.5
        \\    if min(small, large) <> small -> return 96
        \\    if max(small, large) <> large -> return 97
        \\    if clamp(f32(9.5), small, large) <> large -> return 98
        \\    if clamp(0, 23, 19) <> 23 -> return 99
        \\    return min(50, 42)
    , 42);
}
