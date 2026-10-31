const std = @import("std");

pub const Type = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    isize,
    usize,
    f32,
    f64,

    pub fn zigType(comptime self: Type) type {
        return switch (self) {
            .i8 => i8,
            .i16 => i16,
            .i32 => i32,
            .i64, .isize => i64,
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .u64, .usize => u64,
            .f32 => f32,
            .f64 => f64,
        };
    }
    pub fn width(self: Type) u7 {
        return switch (self) {
            .i8, .u8 => 8,
            .i16, .u16 => 16,
            .i32, .u32, .f32 => 32,
            .i64, .u64, .isize, .usize, .f64 => 64,
        };
    }
    pub fn isFloat(self: Type) bool {
        return self == .f32 or self == .f64;
    }
    pub fn isSigned(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .isize => true,
            else => false,
        };
    }
    pub fn minimum(self: Type) i128 {
        return if (self.isSigned()) -(@as(i128, 1) << @intCast(self.width() - 1)) else 0;
    }
    pub fn maximum(self: Type) i128 {
        return (@as(i128, 1) << @intCast(self.width() - @intFromBool(self.isSigned()))) - 1;
    }
    pub fn supportsBinary(self: Type, operation: Binary) bool {
        return !self.isFloat() or operation == .add or operation == .sub or operation == .mul or operation == .div or operation.isComparison();
    }
    pub fn supportsUnary(self: Type, operation: Unary) bool {
        return !self.isFloat() or operation == .neg;
    }
    pub fn losslessTo(source: Type, target: Type) bool {
        if (source == target) return true;
        if (source.isFloat()) return target.isFloat() and target.width() >= source.width();
        if (target.isFloat()) return source.width() - @intFromBool(source.isSigned()) <= (if (target == .f32) @as(u7, 24) else 53);
        return source.minimum() >= target.minimum() and source.maximum() <= target.maximum();
    }
};

pub const Overflow = enum { checked, wrapping, saturating };
pub const Policy = enum { lossless, checked, wrap, saturate, round, truncate };
pub const Binary = enum {
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    pub fn isComparison(self: Binary) bool {
        return @backingInt(self) >= @backingInt(Binary.eq);
    }
};
pub const Unary = enum { neg, bit_not };
pub const Error = error{ Overflow, DivisionByZero, InvalidShift };

/// Canonical signed arbitrary-precision integer. Zero has one zero limb and a
/// positive sign. Limb storage belongs to the containing immutable result.
pub const Integer = struct {
    limbs: []const std.math.big.Limb,
    positive: bool,

    pub fn format(self: Integer, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.toInt(i128)) |integer| return writer.print("{d}", .{integer});
        try writer.writeAll(if (self.positive) "0x" else "-0x");
        var index = self.limbs.len;
        while (index != 0) {
            index -= 1;
            if (index == self.limbs.len - 1) try writer.print("{x}", .{self.limbs[index]}) else try writer.print("{x:0>16}", .{self.limbs[index]});
        }
    }
    pub fn big(self: Integer) std.math.big.int.Const {
        return .{ .limbs = self.limbs, .positive = self.positive };
    }
    pub fn toInt(self: Integer, comptime T: type) ?T {
        return self.big().toInt(T) catch null;
    }
    pub fn order(left: Integer, right: Integer) std.math.Order {
        return left.big().order(right.big());
    }
    pub fn fromInt(allocator: std.mem.Allocator, integer: anytype) !Integer {
        var number = try std.math.big.int.Managed.initSet(allocator, integer);
        defer number.deinit();
        return .{ .limbs = try allocator.dupe(std.math.big.Limb, number.toConst().limbs), .positive = number.toConst().positive };
    }
    pub fn parse(allocator: std.mem.Allocator, text: []const u8, negative: bool) !Integer {
        var digits: std.ArrayList(u8) = .empty;
        defer digits.deinit(allocator);
        var base: u8 = 10;
        var start: usize = 0;
        if (text.len >= 2 and text[0] == '0') {
            base = switch (text[1]) {
                'x', 'X' => 16,
                'b', 'B' => 2,
                'o', 'O' => 8,
                else => 10,
            };
            if (base != 10) start = 2;
        }
        for (text[start..], start..) |character, index| {
            if (character == '_') {
                if (index == start or index + 1 == text.len or text[index - 1] == '_') return error.InvalidCharacter;
            } else try digits.append(allocator, character);
        }
        if (digits.items.len == 0) return error.InvalidCharacter;
        var number = try std.math.big.int.Managed.init(allocator);
        defer number.deinit();
        try number.setString(base, digits.items);
        const constant = number.toConst();
        return .{ .limbs = try allocator.dupe(std.math.big.Limb, constant.limbs), .positive = !negative or constant.eqlZero() };
    }
    pub fn bits(self: Integer, target: Type) ?u64 {
        switch (target) {
            inline else => |kind| {
                const T = kind.zigType();
                if (comptime kind.isFloat()) {
                    const rounded = self.big().toFloat(T, .nearest_even);
                    if (rounded[1] != .exact or !std.math.isFinite(rounded[0])) return null;
                    return encode(T, rounded[0]);
                }
                return encode(T, self.toInt(T) orelse return null);
            },
        }
    }
};

pub fn validSeparators(text: []const u8) bool {
    for (text, 0..) |character, index| {
        if (character != '_') continue;
        if (index == 0 or index + 1 == text.len) return false;
        const previous = text[index - 1];
        const next = text[index + 1];
        if (!std.ascii.isHex(previous) or !std.ascii.isHex(next)) return false;
        if (index == 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X' or text[1] == 'b' or text[1] == 'B')) return false;
    }
    return true;
}

pub fn isFloatLiteral(text: []const u8) bool {
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X' or text[1] == 'b' or text[1] == 'B' or text[1] == 'o' or text[1] == 'O')) return false;
    return std.mem.indexOfAny(u8, text, ".eE") != null;
}

pub fn floatLiteral(allocator: std.mem.Allocator, text: []const u8, negative: bool, target: Type) !u64 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(allocator);
    if (negative) try cleaned.append(allocator, '-');
    for (text, 0..) |character, index| {
        if (character == '_') {
            if (index == 0 or index + 1 == text.len or !std.ascii.isDigit(text[index - 1]) or !std.ascii.isDigit(text[index + 1])) return error.InvalidCharacter;
        } else try cleaned.append(allocator, character);
    }
    if (target == .f32) return parseFloat(f32, cleaned.items);
    std.debug.assert(target == .f64);
    return parseFloat(f64, cleaned.items);
}
fn parseFloat(comptime T: type, text: []const u8) !u64 {
    const result = try std.fmt.parseFloat(T, text);
    if (!std.math.isFinite(result) or outsideFiniteRange(T, text)) return error.Overflow;
    if (result == 0) {
        const significand_end = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
        for (text[0..significand_end]) |character| if (character >= '1' and character <= '9') return error.Underflow;
    }
    return encode(T, result);
}

/// Compare the exact decimal magnitude against the largest finite value. The
/// rounded result alone cannot reject values just beyond the finite endpoint.
fn outsideFiniteRange(comptime T: type, text: []const u8) bool {
    const maximum = comptime blk: {
        @setEvalBranchQuota(20000);
        const IntegerType = @Int(.unsigned, if (T == f32) 128 else 1024);
        const precision = if (T == f32) 24 else 53;
        const shift = if (T == f32) 104 else 971;
        const integer: IntegerType = ((@as(IntegerType, 1) << precision) - 1) << shift;
        break :blk std.fmt.comptimePrint("{d}", .{integer});
    };
    const exponent_start = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
    const significand = text[0..exponent_start];
    var first_nonzero: ?usize = null;
    var significant_digits: i128 = 0;
    var fraction_digits: i128 = 0;
    var fraction = false;
    for (significand, 0..) |character, index| {
        if (character == '.') fraction = true;
        if (!std.ascii.isDigit(character)) continue;
        if (fraction) fraction_digits += 1;
        if (first_nonzero == null and character != '0') first_nonzero = index;
        if (first_nonzero != null) significant_digits += 1;
    }
    if (first_nonzero == null) return false;
    const exponent: i128 = if (exponent_start == text.len) 0 else std.fmt.parseInt(i128, text[exponent_start + 1 ..], 10) catch return text[exponent_start + 1] != '-';
    // Finite parse results have a small effective exponent; saturating addition
    // keeps even deliberately excessive exponent spellings a source error.
    const whole_digits = significant_digits +| exponent -| fraction_digits;
    if (whole_digits != maximum.len) return whole_digits > maximum.len;
    var position: usize = 0;
    for (significand[first_nonzero.?..]) |character| {
        if (character == '.') continue;
        const bound: u8 = if (position < maximum.len) maximum[position] else '0';
        if (character != bound) return character > bound;
        position += 1;
    }
    while (position < maximum.len) : (position += 1) {
        if (maximum[position] != '0') return false;
    }
    return false;
}

pub fn encode(comptime T: type, number: T) u64 {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    return @as(Bits, @bitCast(number));
}
pub fn decode(comptime T: type, bits: u64) T {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    return @bitCast(@as(Bits, @truncate(bits)));
}

pub fn binary(kind: Type, operation: Binary, overflow: Overflow, left: u64, right: u64) Error!u64 {
    std.debug.assert(kind.supportsBinary(operation));
    switch (kind) {
        inline else => |known| return typedBinary(known.zigType(), operation, overflow, left, right),
    }
}
fn typedBinary(comptime T: type, operation: Binary, overflow: Overflow, left: u64, right: u64) Error!u64 {
    @setFloatMode(.strict);
    const lhs = decode(T, left);
    const rhs = decode(T, right);
    if (operation.isComparison()) return @intFromBool(switch (operation) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt => lhs < rhs,
        .gt => lhs > rhs,
        .le => lhs <= rhs,
        .ge => lhs >= rhs,
        else => unreachable,
    });
    if (@typeInfo(T) == .float) {
        const result: T = switch (operation) {
            .add => lhs + rhs,
            .sub => lhs - rhs,
            .mul => lhs * rhs,
            .div => lhs / rhs,
            else => unreachable,
        };
        return encode(T, result);
    }
    switch (operation) {
        .add, .sub, .mul => {
            const result = switch (operation) {
                .add => @addWithOverflow(lhs, rhs),
                .sub => @subWithOverflow(lhs, rhs),
                .mul => @mulWithOverflow(lhs, rhs),
                else => unreachable,
            };
            if (result[1] == 0 or overflow == .wrapping) return encode(T, result[0]);
            if (overflow == .checked) return error.Overflow;
            return encode(T, switch (operation) {
                .add => lhs +| rhs,
                .sub => lhs -| rhs,
                .mul => lhs *| rhs,
                else => unreachable,
            });
        },
        .div, .rem => {
            if (rhs == 0) return error.DivisionByZero;
            if (@typeInfo(T).int.signedness == .signed and lhs == std.math.minInt(T) and rhs == -1) {
                if (operation == .rem) return 0;
                return switch (overflow) {
                    .checked => error.Overflow,
                    .wrapping => encode(T, lhs),
                    .saturating => encode(T, std.math.maxInt(T)),
                };
            }
            return encode(T, if (operation == .div) @divTrunc(lhs, rhs) else @rem(lhs, rhs));
        },
        .bit_and => return encode(T, lhs & rhs),
        .bit_or => return encode(T, lhs | rhs),
        .bit_xor => return encode(T, lhs ^ rhs),
        .shl, .shr => {
            if (rhs < 0 or rhs >= @bitSizeOf(T)) return error.InvalidShift;
            const count: std.math.Log2Int(T) = @intCast(rhs);
            return encode(T, if (operation == .shl) lhs << count else lhs >> count);
        },
        else => unreachable,
    }
}
pub fn unary(kind: Type, operation: Unary, overflow: Overflow, bits: u64) Error!u64 {
    std.debug.assert(kind.supportsUnary(operation));
    switch (kind) {
        inline else => |known| {
            const T = known.zigType();
            const value = decode(T, bits);
            if (comptime known.isFloat()) return encode(T, -value);
            if (operation == .bit_not) return encode(T, ~value);
            return binary(kind, .sub, overflow, 0, bits);
        },
    }
}
pub fn asInteger(kind: Type, bits: u64) i128 {
    switch (kind) {
        inline else => |known| {
            if (comptime known.isFloat()) unreachable;
            return decode(known.zigType(), bits);
        },
    }
}
pub fn asFloat(kind: Type, bits: u64) f128 {
    switch (kind) {
        inline else => |known| {
            if (comptime known.isFloat()) return decode(known.zigType(), bits);
            return @floatFromInt(decode(known.zigType(), bits));
        },
    }
}
pub fn nearestEven(value: f128) f128 {
    if (!std.math.isFinite(value) or value == 0) return value;
    const lower = @floor(value);
    const fraction = value - lower;
    if (fraction < 0.5) return lower;
    if (fraction > 0.5) return lower + 1;
    return if (@mod(lower, 2) == 0) lower else lower + 1;
}
pub fn conversionIsOptional(source: Type, target: Type, policy: Policy) bool {
    return policy == .checked or (source.isFloat() and !target.isFloat() and (policy == .round or policy == .truncate or policy == .saturate));
}
pub fn validConversion(source: Type, target: Type, policy: Policy) bool {
    return switch (policy) {
        .lossless => source.losslessTo(target),
        .checked => true,
        .wrap => !source.isFloat() and !target.isFloat(),
        .saturate => !target.isFloat(),
        .round => target.isFloat() or source.isFloat(),
        .truncate => source.isFloat() and !target.isFloat(),
    };
}
/// null is an ordinary failed optional conversion, never an execution failure.
pub fn convert(source: Type, target: Type, policy: Policy, bits: u64) ?u64 {
    @setFloatMode(.strict);
    std.debug.assert(validConversion(source, target, policy));
    if (target.isFloat()) {
        switch (target) {
            inline .f32, .f64 => |kind| {
                const T = kind.zigType();
                const result: T = if (source.isFloat()) @floatCast(asFloat(source, bits)) else @floatFromInt(asInteger(source, bits));
                if (policy == .checked and (@as(f128, result) != asFloat(source, bits) or std.math.isNan(result))) return null;
                return encode(T, result);
            },
            else => unreachable,
        }
    }
    var integer: i128 = undefined;
    if (source.isFloat()) {
        var value = asFloat(source, bits);
        if (std.math.isNan(value)) return null;
        if (policy == .round) value = nearestEven(value);
        if (policy == .truncate) value = @trunc(value);
        const lower: f128 = @floatFromInt(target.minimum());
        const upper: f128 = @floatFromInt(target.maximum());
        if (policy == .saturate) value = @trunc(@min(@max(value, lower), upper));
        if (!std.math.isFinite(value) or value < lower or value > upper or @trunc(value) != value) return null;
        integer = @intFromFloat(value);
    } else integer = asInteger(source, bits);
    if (policy == .saturate) integer = @min(@max(integer, target.minimum()), target.maximum());
    if (policy != .wrap and (integer < target.minimum() or integer > target.maximum())) return null;
    const mask = (@as(u128, 1) << @intCast(target.width())) - 1;
    return @intCast(@as(u128, @bitCast(integer)) & mask);
}
