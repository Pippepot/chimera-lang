const std = @import("std");

pub const Category = enum {
    parsing,
    declarations,
    signatures,
    conversion_matching,
    body_overhead,
    body_build,
    body_typing,
    body_lifetimes,
    body_freeze,
    type_facts,
    comptime_execution,
    optimization,
    optimization_setup,
    optimization_graph,
    optimization_inline,
    optimization_sroa,
    optimization_promotion,
    optimization_canonicalize,
    optimization_numbering,
    optimization_dead_code,
    optimization_joins,
    optimization_cleanup,
    optimization_hoist,
    optimization_idioms,
    optimization_compaction,
    optimization_clone,
    codegen,
    query_other,
    dependency_wait,
};

pub fn queryCategory(comptime Query: type) Category {
    return if (@hasDecl(Query, "profile_category")) Query.profile_category else .query_other;
}

pub const Counter = struct {
    nanoseconds: i96 = 0,
    runs: usize = 0,
};

pub const Snapshot = struct {
    counters: [@typeInfo(Category).@"enum".field_names.len]Counter = std.mem.zeroes([@typeInfo(Category).@"enum".field_names.len]Counter),

    pub fn get(self: *const Snapshot, category: Category) Counter {
        return self.counters[@backingInt(category)];
    }

    pub fn since(self: Snapshot, previous: Snapshot) Snapshot {
        var result: Snapshot = .{};
        for (&result.counters, self.counters, previous.counters) |*counter, current, before| {
            counter.* = .{ .nanoseconds = current.nanoseconds - before.nanoseconds, .runs = current.runs - before.runs };
        }
        return result;
    }
};

pub const Collector = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    totals: Snapshot = .{},

    pub fn snapshot(self: *Collector) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.totals;
    }

    fn record(self: *Collector, category: Category, nanoseconds: i96) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const counter = &self.totals.counters[@backingInt(category)];
        counter.nanoseconds += nanoseconds;
        counter.runs += 1;
    }
};

threadlocal var active_scope: ?*Scope = null;

pub const Scope = struct {
    collector: ?*Collector = null,
    parent: ?*Scope = null,
    category: Category = undefined,
    started: std.Io.Timestamp = undefined,
    children_ns: i96 = 0,

    pub fn begin(self: *Scope, collector: ?*Collector, category: Category) void {
        self.* = .{ .collector = collector };
        const enabled = collector orelse return;
        self.parent = active_scope;
        self.category = category;
        self.started = std.Io.Clock.awake.now(enabled.io);
        active_scope = self;
    }

    pub fn beginCurrent(self: *Scope, category: Category) void {
        self.begin(if (active_scope) |parent| parent.collector else null, category);
    }

    pub fn end(self: *Scope) void {
        const collector = self.collector orelse return;
        std.debug.assert(active_scope == self);
        const elapsed = self.started.durationTo(std.Io.Clock.awake.now(collector.io)).toNanoseconds();
        std.debug.assert(elapsed >= self.children_ns);
        active_scope = self.parent;
        collector.record(self.category, elapsed - self.children_ns);
        if (self.parent) |parent| {
            parent.children_ns += self.started.durationTo(std.Io.Clock.awake.now(collector.io)).toNanoseconds();
        }
        self.collector = null;
    }
};

test "profiling snapshots subtract completed computation counters" {
    try std.testing.expectEqual(Category.parsing, comptime queryCategory(struct {
        pub const profile_category: Category = .parsing;
    }));
    try std.testing.expectEqual(Category.query_other, comptime queryCategory(struct {}));
    var collector: Collector = .{ .io = std.testing.io };
    collector.record(.parsing, 100);
    const before = collector.snapshot();
    collector.record(.parsing, 40);
    collector.record(.codegen, 70);
    const delta = collector.snapshot().since(before);
    try std.testing.expectEqual(@as(i96, 40), delta.get(.parsing).nanoseconds);
    try std.testing.expectEqual(@as(usize, 1), delta.get(.parsing).runs);
    try std.testing.expectEqual(@as(i96, 70), delta.get(.codegen).nanoseconds);
    try std.testing.expectEqual(@as(usize, 0), delta.get(.signatures).runs);
}

test "profiling scopes restore parents and leave disabled scopes unrecorded" {
    var collector: Collector = .{ .io = std.testing.io };
    var outer: Scope = .{};
    outer.begin(&collector, .body_overhead);
    var inner: Scope = .{};
    inner.beginCurrent(.body_typing);
    inner.end();
    try std.testing.expect(active_scope == &outer);
    outer.end();
    try std.testing.expect(active_scope == null);
    var disabled: Scope = .{};
    disabled.beginCurrent(.codegen);
    disabled.end();
    const totals = collector.snapshot();
    try std.testing.expectEqual(@as(usize, 1), totals.get(.body_overhead).runs);
    try std.testing.expectEqual(@as(usize, 1), totals.get(.body_typing).runs);
    try std.testing.expectEqual(@as(usize, 0), totals.get(.codegen).runs);
}

test "profiling scopes exclude nested work and collection overhead from parents" {
    const Clock = struct {
        const timestamps = [_]i96{ 0, 10, 20, 50, 55, 70, 77, 100 };
        next: usize = 0,

        fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
            std.debug.assert(clock == .awake);
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            const timestamp = timestamps[self.next];
            self.next += 1;
            return .fromNanoseconds(timestamp);
        }
    };
    var clock: Clock = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    var collector: Collector = .{ .io = .{ .userdata = &clock, .vtable = &vtable } };

    var outer: Scope = .{};
    outer.begin(&collector, .body_overhead);
    var waiting: Scope = .{};
    waiting.beginCurrent(.dependency_wait);
    var nested: Scope = .{};
    nested.beginCurrent(.body_typing);
    nested.end();
    waiting.end();
    outer.end();

    const totals = collector.snapshot();
    try std.testing.expectEqual(@as(i96, 30), totals.get(.body_typing).nanoseconds);
    try std.testing.expectEqual(@as(i96, 25), totals.get(.dependency_wait).nanoseconds);
    try std.testing.expectEqual(@as(i96, 33), totals.get(.body_overhead).nanoseconds);
    try std.testing.expectEqual(@as(usize, 1), totals.get(.body_typing).runs);
    try std.testing.expectEqual(@as(usize, 1), totals.get(.dependency_wait).runs);
    try std.testing.expectEqual(@as(usize, 1), totals.get(.body_overhead).runs);
    try std.testing.expectEqual(Clock.timestamps.len, clock.next);
    try std.testing.expect(active_scope == null);
}
