const std = @import("std");
const structures = @import("../structures.zig");
const canonicalize = @import("canonicalize.zig");

const ValueId = structures.FunctionValueId;
const min_int = std.math.minInt(i32);
const max_int = std.math.maxInt(i32);

/// Bounds on the successful i32 values of an integer. A trapping producer stays
/// live independently, so narrowing its successful result never hides a panic.
pub const Interval = struct {
    lower: i64 = min_int,
    upper: i64 = max_int,

    pub fn point(number: i64) Interval {
        return .{ .lower = number, .upper = number };
    }

    pub fn join(self: Interval, other: Interval) Interval {
        return .{ .lower = @min(self.lower, other.lower), .upper = @max(self.upper, other.upper) };
    }

    pub fn fits(self: Interval) bool {
        return self.lower >= min_int and self.upper <= max_int;
    }

    fn clamped(self: Interval) Interval {
        return .{ .lower = std.math.clamp(self.lower, min_int, max_int), .upper = std.math.clamp(self.upper, min_int, max_int) };
    }

    pub fn arithmetic(operation: structures.numeric.Binary, left: Interval, right: Interval) Interval {
        switch (operation) {
            .add => return .{ .lower = left.lower + right.lower, .upper = left.upper + right.upper },
            .sub => return .{ .lower = left.lower - right.upper, .upper = left.upper - right.lower },
            .mul => {
                const products = [_]i64{ left.lower * right.lower, left.lower * right.upper, left.upper * right.lower, left.upper * right.upper };
                return .{ .lower = std.mem.min(i64, &products), .upper = std.mem.max(i64, &products) };
            },
            else => unreachable,
        }
    }

    pub fn refine(self: *Interval, operation: structures.PredicateOperation, bound: i64) void {
        switch (operation) {
            .lti => self.upper = @min(self.upper, bound - 1),
            .lei => self.upper = @min(self.upper, bound),
            .gti => self.lower = @max(self.lower, bound + 1),
            .gei => self.lower = @max(self.lower, bound),
            .eqi => {
                self.lower = @max(self.lower, bound);
                self.upper = @min(self.upper, bound);
            },
            .nei => {
                if (self.lower == bound) self.lower += 1;
                if (self.upper == bound) self.upper -= 1;
            },
            else => unreachable,
        }
    }

    pub fn known(self: Interval, operation: structures.PredicateOperation, bound: i64) ?bool {
        return switch (operation) {
            .lti => if (self.upper < bound) true else if (self.lower >= bound) false else null,
            .lei => if (self.upper <= bound) true else if (self.lower > bound) false else null,
            .gti => if (self.lower > bound) true else if (self.upper <= bound) false else null,
            .gei => if (self.lower >= bound) true else if (self.upper < bound) false else null,
            .eqi => if (self.lower == bound and self.upper == bound) true else if (bound < self.lower or bound > self.upper) false else null,
            .nei => if (self.lower == bound and self.upper == bound) false else if (bound < self.lower or bound > self.upper) true else null,
            else => unreachable,
        };
    }
};

/// The one range engine. A context names the function and answers what its
/// analysis knows beyond definitions: `trusted(value)` admits stable scalars,
/// `leaf(value, depth)` bounds block parameters and fields of joins,
/// `narrow(value, range)` applies guards at the query point, and
/// `facts(value, range, user)` applies facts that hold once `user` executes.
pub fn bounds(context: anytype, value: ValueId, depth: u32) Interval {
    if (depth == 0) return .{};
    const function = context.function;
    const resolved = function.find(value);
    if (!context.trusted(resolved)) return .{};
    const range = structure(context, resolved, depth) orelse context.leaf(resolved, depth) orelse return context.narrow(resolved, .{});
    return context.narrow(resolved, range);
}

/// The unclamped result of an integer `+ - *` over its operands' bounds.
pub fn exact(context: anytype, operation: structures.NumericBinary, user: ?ValueId, depth: u32) ?Interval {
    if (operation.type_id != .int) return null;
    switch (operation.operation) {
        .add, .sub, .mul => {},
        else => return null,
    }
    const left = context.facts(operation.operands.lhs, bounds(context, operation.operands.lhs, depth - 1), user);
    const right = context.facts(operation.operands.rhs, bounds(context, operation.operands.rhs, depth - 1), user);
    return Interval.arithmetic(operation.operation, left, right);
}

fn structure(context: anytype, value: ValueId, depth: u32) ?Interval {
    const function = context.function;
    const definition = function.definition(value) orelse return null;
    switch (definition) {
        .const_int => |number| return Interval.point(number),
        .value_copy => |copy| return bounds(context, copy.source, depth - 1),
        .select => |selection| return bounds(context, selection.then_value, depth - 1).join(bounds(context, selection.else_value, depth - 1)),
        .shrsi => |operands| {
            const count = function.constantInt(operands.rhs) orelse return .{};
            if (count < 0 or count >= 32) return .{};
            const source = bounds(context, operands.lhs, depth - 1);
            return .{ .lower = source.lower >> @intCast(count), .upper = source.upper >> @intCast(count) };
        },
        .negi => |operand| {
            const source = bounds(context, operand, depth - 1);
            if (source.lower == min_int) return .{};
            return .{ .lower = -source.upper, .upper = -source.lower };
        },
        .numeric_binary, .addi, .subi, .muli => {
            const operation = canonicalize.integerOperation(definition).?;
            const range = exact(context, operation, value, depth) orelse return .{};
            if (operation.overflow == .wrapping and !range.fits()) return .{};
            return range.clamped();
        },
        else => return null,
    }
}
