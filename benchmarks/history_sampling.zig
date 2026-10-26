const std = @import("std");

pub const minimum_samples = 2;
pub const maximum_samples = 5;
pub const compilation_maximum_samples = 3;
pub const relative_range_percent = 2;

pub const Sampling = struct {
    const Sample = struct { nanoseconds: u64, executable_bytes: usize };

    samples: [maximum_samples]Sample = undefined,
    count: usize = 0,
    fixed_count: ?usize = null,
    limit: usize = maximum_samples,

    pub fn add(self: *Sampling, elapsed: i96, size: usize) !void {
        std.debug.assert(self.count < maximum_samples);
        const nanoseconds = std.math.cast(u64, elapsed) orelse return error.InvalidMeasurement;
        self.samples[self.count] = .{ .nanoseconds = nanoseconds, .executable_bytes = size };
        self.count += 1;
    }

    pub fn stable(self: *const Sampling) bool {
        if (self.count < minimum_samples) return false;
        var sorted: [maximum_samples]u64 = undefined;
        for (self.samples[0..self.count], sorted[0..self.count]) |sample, *value| value.* = sample.nanoseconds;
        std.mem.sort(u64, sorted[0..self.count], {}, std.sort.asc(u64));
        const middle = self.count / 2;
        const median = if (self.count % 2 == 0)
            sorted[middle - 1] + (sorted[middle] - sorted[middle - 1]) / 2
        else
            sorted[middle];
        if (median == 0) return false;
        const spread = @as(u128, sorted[self.count - 1]) - sorted[0];
        return spread * 100 <= @as(u128, median) * relative_range_percent;
    }

    pub fn complete(self: *const Sampling) bool {
        if (self.fixed_count) |count| return self.count >= count;
        return self.count == self.limit or self.stable();
    }

    pub fn write(self: *const Sampling, writer: *std.Io.Writer, name: []const u8, lane: []const u8, phase: []const u8) !void {
        std.debug.assert(self.complete());
        for (self.samples[0..self.count], 0..) |sample, index| {
            try writer.print("{s},{s},{s},{d},{d},{d},{d},{}\n", .{
                name, lane, phase, index, sample.nanoseconds, sample.executable_bytes, self.count, self.stable(),
            });
        }
    }
};

test "stable sampling stops at two measured runs" {
    var sampling: Sampling = .{};
    try sampling.add(100_000, 42);
    try std.testing.expect(!sampling.complete());
    try sampling.add(102_000, 42);
    try std.testing.expect(sampling.complete());
    try std.testing.expect(sampling.stable());
}

test "noisy sampling retains outliers and stops at the cap" {
    var sampling: Sampling = .{};
    for (0..maximum_samples) |index| {
        try sampling.add(if (index == 1) 104_000 else 100_000, 42);
        try std.testing.expectEqual(index + 1 == maximum_samples, sampling.complete());
    }
    try std.testing.expect(!sampling.stable());
}

test "compilation sampling respects its smaller cap" {
    var sampling: Sampling = .{ .limit = compilation_maximum_samples };
    for (0..compilation_maximum_samples) |index| {
        try sampling.add(if (index == 1) 104_000 else 100_000, 42);
        try std.testing.expectEqual(index + 1 == compilation_maximum_samples, sampling.complete());
    }
    try std.testing.expect(!sampling.stable());
}

test "sampling supports explicit fixed probes without claiming stability" {
    var sampling: Sampling = .{ .fixed_count = 1 };
    try sampling.add(100_000, 42);
    try std.testing.expect(sampling.complete());
    try std.testing.expect(!sampling.stable());
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try sampling.write(&output.writer, "probe", "normal", "cold");
    try std.testing.expectEqualStrings("probe,normal,cold,0,100000,42,1,false\n", output.written());
}
