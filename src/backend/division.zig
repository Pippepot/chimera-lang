//! Division by constants without a divide instruction.
//!
//! Dividends of every width reach these forms sign- or zero-extended to 64 bits,
//! so one 64-bit algorithm per signedness serves all integer types. The 32-bit
//! form uses a 64-bit multiply and serves the lowered `int` division.
const std = @import("std");

/// Multiply-and-shift form of truncating 32-bit signed division by a constant
/// whose magnitude is not a power of two (powers of two use shifts instead).
/// With m = ceil(2^(32+shift) / |d|), floor(x * m / 2^(32+shift)) equals
/// trunc(x / |d|) for nonnegative x and one less for negative x.
pub const Int32 = struct {
    /// Low 32 bits of m; the multiplier is 2^32 + this value when `high`.
    multiplier: u32,
    shift: u6,
    high: bool,

    pub fn of(divisor: i32) ?Int32 {
        const magnitude: u64 = @abs(@as(i64, divisor));
        if (magnitude < 2 or std.math.isPowerOfTwo(magnitude)) return null;
        const shift: u7 = @intCast(std.math.log2_int_ceil(u64, magnitude));
        const multiplier = ((@as(u128, 1) << 32 + shift) + magnitude - 1) / magnitude;
        return .{ .multiplier = @truncate(multiplier), .shift = @intCast(shift), .high = multiplier >> 32 != 0 };
    }

    pub fn divide(self: Int32, dividend: i32, negative: bool) i32 {
        const x: i64 = dividend;
        const multiplier: i64 = self.multiplier;
        const floored = if (self.high) ((x * multiplier >> 32) + x) >> @intCast(self.shift) else x * multiplier >> @intCast(32 + self.shift);
        const quotient = floored + @as(i64, @intCast(@as(u32, @bitCast(dividend)) >> 31));
        return @truncate(if (negative) -quotient else quotient);
    }
};

/// Truncating signed 64-bit division by a constant of magnitude two or more:
/// q = ((n + high(m * n)) >> shift) + (n < 0), negated for a negative divisor
/// (Granlund and Montgomery). Powers of two take the same form.
pub const Signed = struct {
    multiplier: i64,
    /// Arithmetic shift after the addition, ceil(log2 |d|) - 1.
    shift: u6,
    negative: bool,

    pub fn of(divisor: i64) ?Signed {
        const magnitude: u128 = @abs(@as(i128, divisor));
        if (magnitude < 2) return null;
        const bits: u7 = @intCast(std.math.log2_int_ceil(u128, magnitude));
        const multiplier = 1 + (@as(u128, 1) << 63 + bits) / magnitude;
        return .{
            .multiplier = @truncate(@as(i128, @intCast(multiplier)) - (@as(i128, 1) << 64)),
            .shift = @intCast(bits - 1),
            .negative = divisor < 0,
        };
    }

    pub fn divide(self: Signed, dividend: i64) i64 {
        const high: i64 = @intCast(@as(i128, self.multiplier) * dividend >> 64);
        const total = dividend +% high;
        const quotient = (total >> self.shift) + @as(i64, @intCast(@as(u64, @bitCast(dividend)) >> 63));
        return if (self.negative) 0 -% quotient else quotient;
    }
};

/// Unsigned 64-bit division by a constant that is not a power of two:
/// t = high(m * n); q = (t + ((n - t) >> 1)) >> (ceil(log2 d) - 1).
pub const Unsigned = struct {
    multiplier: u64,
    shift: u6,

    pub fn of(divisor: u64) ?Unsigned {
        if (divisor < 2 or std.math.isPowerOfTwo(divisor)) return null;
        const bits: u7 = @intCast(std.math.log2_int_ceil(u64, divisor));
        const multiplier = (((@as(u128, 1) << bits) - divisor) << 64) / divisor + 1;
        return .{ .multiplier = @intCast(multiplier), .shift = @intCast(bits - 1) };
    }

    pub fn divide(self: Unsigned, dividend: u64) u64 {
        const high: u64 = @intCast(@as(u128, self.multiplier) * dividend >> 64);
        return (high + ((dividend - high) >> 1)) >> self.shift;
    }
};

test "32 bit constant division matches truncating division" {
    var random: std.Random.DefaultPrng = .init(0);
    const divisors = [_]i32{ 3, 5, 6, 7, 10, 25, 63, 65, 100, 129, 1000, 65535, 65537, 1000003, 1073741825, 2147483647, std.math.minInt(i32) + 1, -3, -7, -65537, -1000003 };
    for (divisors) |divisor| {
        const magic = Int32.of(divisor).?;
        for ([_]i32{ 0, 1, -1, 2, -2, std.math.maxInt(i32), std.math.minInt(i32), std.math.minInt(i32) + 1, divisor, -divisor, divisor -% 1, divisor +% 1 }) |dividend|
            try std.testing.expectEqual(@divTrunc(dividend, divisor), magic.divide(dividend, divisor < 0));
        for (0..20000) |_| {
            const dividend = random.random().int(i32);
            try std.testing.expectEqual(@divTrunc(dividend, divisor), magic.divide(dividend, divisor < 0));
        }
    }
    try std.testing.expect(Int32.of(8) == null);
    try std.testing.expect(Int32.of(std.math.minInt(i32)) == null);
    try std.testing.expect(Int32.of(1) == null);
}

test "signed 64 bit constant division matches truncating division for every narrow width" {
    // Narrow dividends reach the 64-bit form sign-extended, so exhausting 16 bits covers 8 as well.
    for ([_]i64{ 2, 3, 4, 5, 6, 7, 10, 25, 100, 255, 256, 641, 1000, 32767, 32768, -2, -3, -4, -7, -10, -255, -1000, -32768 }) |divisor| {
        const magic = Signed.of(divisor).?;
        var dividend: i64 = std.math.minInt(i16);
        while (dividend <= std.math.maxInt(i16)) : (dividend += 1)
            try std.testing.expectEqual(@divTrunc(dividend, divisor), magic.divide(dividend));
    }
}

test "wide constant division matches truncating division at the 64 bit extremes" {
    var random: std.Random.DefaultPrng = .init(1);
    const signed_divisors = [_]i64{ 2, 3, 5, 7, 10, 100, 1000003, 4294967295, 4294967296, 4294967297, 1 << 40, (1 << 62) + 1, std.math.maxInt(i64), -2, -3, -7, -1000, -4294967297, std.math.minInt(i64) + 1, std.math.minInt(i64) };
    for (signed_divisors) |divisor| {
        const magic = Signed.of(divisor).?;
        for ([_]i64{ 0, 1, -1, 2, -2, std.math.maxInt(i64), std.math.minInt(i64), std.math.minInt(i64) + 1, std.math.maxInt(i32), std.math.minInt(i32), divisor, divisor -% 1, divisor +% 1 }) |dividend| {
            // MIN / -1 is the one overflowing quotient; it never reaches a constant form.
            if (dividend == std.math.minInt(i64) and divisor == -1) continue;
            try std.testing.expectEqual(@divTrunc(dividend, divisor), magic.divide(dividend));
        }
        for (0..20000) |_| {
            const dividend = random.random().int(i64);
            try std.testing.expectEqual(@divTrunc(dividend, divisor), magic.divide(dividend));
            const small = random.random().int(i32);
            try std.testing.expectEqual(@divTrunc(@as(i64, small), divisor), magic.divide(small));
        }
    }
    const unsigned_divisors = [_]u64{ 3, 5, 6, 7, 10, 100, 1000003, 4294967295, 4294967297, (1 << 40) + 1, (1 << 63) - 1, (1 << 63) + 1, std.math.maxInt(u64), std.math.maxInt(u64) - 1 };
    for (unsigned_divisors) |divisor| {
        const magic = Unsigned.of(divisor).?;
        for ([_]u64{ 0, 1, 2, std.math.maxInt(u64), std.math.maxInt(u64) - 1, 1 << 63, (1 << 63) - 1, std.math.maxInt(u32), divisor, divisor -% 1, divisor +% 1 }) |dividend|
            try std.testing.expectEqual(dividend / divisor, magic.divide(dividend));
        for (0..20000) |_| {
            const dividend = random.random().int(u64);
            try std.testing.expectEqual(dividend / divisor, magic.divide(dividend));
        }
    }
    var dividend: u64 = 0;
    while (dividend <= std.math.maxInt(u16)) : (dividend += 1) {
        for ([_]u64{ 3, 5, 7, 10, 100, 255, 641, 1000, 65535 }) |divisor|
            try std.testing.expectEqual(dividend / divisor, Unsigned.of(divisor).?.divide(dividend));
    }
    try std.testing.expect(Unsigned.of(8) == null);
    try std.testing.expect(Signed.of(1) == null);
    try std.testing.expect(Signed.of(-1) == null);
}
