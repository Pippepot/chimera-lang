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
