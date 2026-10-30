const std = @import("std");
const test_sources = @import("test_sources");
const query = test_sources.query;
const Context = query.Context;
const Database = query.Database;
const Handle = query.Handle;
const testing = std.testing;
const allocation_failure_allocator = test_sources.allocation_failure_allocator;
const Control = union(enum) { exit: u8 };

fn testDatabase(worker_count: usize) !*Database {
    return Database.init(testing.allocator, .{ .worker_count = worker_count });
}

const Counter = struct {
    value: std.atomic.Value(usize) = .init(0),

    fn reset(counter: *Counter) void {
        counter.value.store(0, .monotonic);
    }

    fn increment(counter: *Counter) void {
        _ = counter.value.fetchAdd(1, .monotonic);
    }

    fn expect(counter: *Counter, expected: usize) !void {
        try testing.expectEqual(expected, counter.value.load(.monotonic));
    }
};

const OwnedDiagnostic = struct {
    file_id: u64,
    span: ?struct { start: usize, end: usize },
    message: []const u8,

    pub fn clone(gpa: std.mem.Allocator, value: OwnedDiagnostic) !OwnedDiagnostic {
        return .{
            .file_id = value.file_id,
            .span = value.span,
            .message = try gpa.dupe(u8, value.message),
        };
    }

    pub fn deinit(self: *OwnedDiagnostic, gpa: std.mem.Allocator) void {
        gpa.free(self.message);
        self.* = undefined;
    }

    pub fn eql(a: OwnedDiagnostic, b: OwnedDiagnostic) bool {
        return a.file_id == b.file_id and std.meta.eql(a.span, b.span) and std.mem.eql(u8, a.message, b.message);
    }
};

fn freeOwnedDiagnostics(diagnostics: []OwnedDiagnostic) void {
    for (diagnostics) |*diagnostic| diagnostic.deinit(testing.allocator);
    testing.allocator.free(diagnostics);
}

const Square = struct {
    pub const Input = i32;
    pub const Output = i32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        _ = ctx;
        return input_value * input_value;
    }
};

const Pair = struct {
    a: i32,
    b: i32,
};

const SumSquares = struct {
    pub const Input = Pair;
    pub const Output = i32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const a = try ctx.spawn(Square, input_value.a);
        const b = try ctx.spawn(Square, input_value.b);
        return (try a.wait()).* + (try b.wait()).*;
    }
};

const CycleA = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.get(CycleB, input_value)).*;
    }
};

const CycleB = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.get(CycleA, input_value)).*;
    }
};

const NumberInput = struct {
    pub const Key = u32;
    pub const Value = u32;
};

const ReadNumber = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.input(NumberInput, input_value)).*;
    }
};

const Parity = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(OwnedDiagnostic, .{ .file_id = input_value, .span = null, .message = "parity" });
        return value % 2;
    }
};

const ParityParent = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        return (try ctx.get(Parity, input_value)).*;
    }
};

const ParityWithDiagnostic = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(OwnedDiagnostic, .{
            .file_id = input_value,
            .span = null,
            .message = if (value == 2) "two" else "four",
        });
        return value % 2;
    }
};

const DiagnosticParent = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        return (try ctx.get(ParityWithDiagnostic, input_value)).*;
    }
};

const ConditionalControlLeaf = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) !Output {
        const value = (try ctx.input(NumberInput, input_value)).*;
        if (value != 0) try ctx.emit(Control, .{ .exit = @intCast(value) });
        return 1;
    }
};

const ConditionalControlMiddle = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) !Output {
        return (try ctx.get(ConditionalControlLeaf, input_value)).*;
    }
};

const ConditionalControlRoot = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) !Output {
        return (try ctx.get(ConditionalControlMiddle, input_value)).*;
    }
};

const SelectedNumber = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, selector_key: Input) anyerror!Output {
        executions.increment();
        const selected_key = (try ctx.input(NumberInput, selector_key)).*;
        return (try ctx.input(NumberInput, selected_key)).*;
    }
};

const OwnedOutput = struct {
    bytes: []u8,

    var deinits: Counter = .{};

    pub fn deinit(value: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(value.bytes);
        deinits.increment();
        value.* = undefined;
    }

    pub fn eql(a: @This(), b: @This()) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
};

const OwnedParity = struct {
    pub const Input = u32;
    pub const Output = OwnedOutput;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const value = (try ctx.input(NumberInput, input_value)).*;
        const bytes = try ctx.allocator().alloc(u8, 1);
        bytes[0] = @intCast(value % 2);
        return .{ .bytes = bytes };
    }
};

const RetryableFailure = struct {
    pub const Input = u32;
    pub const Output = OwnedOutput;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        executions.increment();
        const value = (try ctx.input(NumberInput, input_value)).*;
        try ctx.emit(OwnedDiagnostic, .{
            .file_id = input_value,
            .span = null,
            .message = if (value == 2) "initial" else "replacement",
        });
        if (value == 4) return error.TestInfrastructureFailure;

        const bytes = try ctx.allocator().alloc(u8, 1);
        bytes[0] = @intCast(value);
        return .{ .bytes = bytes };
    }
};

const CountedQuery = struct {
    pub const Input = u32;
    pub const Output = u32;

    var executions: Counter = .{};

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        _ = ctx;
        executions.increment();
        return input_value;
    }
};

const AwaitedLeaf = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(_: *Context, input_value: Input) anyerror!Output {
        return input_value;
    }
};

const WaitingParent = struct {
    pub const Input = u32;
    pub const Output = u32;

    var started: std.atomic.Value(bool) = .init(false);
    var may_wait: std.atomic.Value(bool) = .init(false);

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        const leaf = try ctx.spawn(AwaitedLeaf, input_value);
        started.store(true, .release);
        while (!may_wait.load(.acquire)) std.atomic.spinLoopHint();
        return (try leaf.wait()).*;
    }
};

const ParentDependentSibling = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return (try ctx.get(WaitingParent, input_value)).*;
    }
};

const DynamicCycleA = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return if ((try ctx.input(NumberInput, 10)).* == 0)
            (try ctx.get(DynamicCycleB, input_value)).*
        else
            1;
    }
};

const DynamicCycleB = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Context, input_value: Input) anyerror!Output {
        return if ((try ctx.input(NumberInput, 11)).* != 0)
            (try ctx.get(DynamicCycleA, input_value)).*
        else
            0;
    }
};

const EmitDiagnostic = struct {
    pub const Input = u64;
    pub const Output = u32;

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        try ctx.emit(OwnedDiagnostic, .{
            .file_id = file_id,
            .span = .{ .start = 0, .end = 1 },
            .message = "leaf",
        });
        return 10;
    }
};

const CallEmitDiagnostic = struct {
    pub const Input = u64;
    pub const Output = u32;

    pub fn run(ctx: *Context, file_id: Input) anyerror!Output {
        try ctx.emit(OwnedDiagnostic, .{
            .file_id = file_id,
            .span = null,
            .message = "root",
        });
        return (try ctx.get(EmitDiagnostic, file_id)).* + 1;
    }
};

test "typed queries memoize and spawned dependencies can overlap" {
    const db = try testDatabase(4);
    defer db.deinit();

    try testing.expectEqual(@as(i32, 25), (try db.get(SumSquares, .{ .a = 3, .b = 4 })).*);
    try testing.expectEqual(@as(i32, 25), (try db.get(SumSquares, .{ .a = 3, .b = 4 })).*);
}

test "prefetches settle owned results without observing diagnostics or stale memos" {
    const Child = struct {
        pub const Input = u32;
        pub const Output = OwnedOutput;
        var executions: Counter = .{};

        pub fn run(ctx: *Context, key: Input) !Output {
            executions.increment();
            const value = (try ctx.input(NumberInput, key)).*;
            try ctx.emit(u32, value);
            const bytes = try ctx.allocator().alloc(u8, 1);
            bytes[0] = @intCast(value);
            return .{ .bytes = bytes };
        }
    };
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        var executions: Counter = .{};

        pub fn run(ctx: *Context, key: Input) !Output {
            executions.increment();
            const selector = (try ctx.input(NumberInput, key)).*;
            try ctx.prefetch(Child, key + 1);
            try ctx.prefetch(Child, key + 1);
            if (selector == 1) return (try ctx.get(Child, key + 1)).bytes[0];
            return selector + 42;
        }
    };
    for ([_]usize{ 0, 1, 4 }) |workers| {
        const db = try testDatabase(workers);
        defer db.deinit();
        Child.executions.reset();
        Parent.executions.reset();
        try db.addInput(NumberInput, 0, 0);
        try db.addInput(NumberInput, 1, 7);
        const first = try db.get(Parent, 0);
        try testing.expectEqual(@as(u32, 42), first.*);
        try Child.executions.expect(1);
        const ignored = try db.transitiveAccumulatorValues(Parent, 0, u32, testing.allocator);
        defer testing.allocator.free(ignored);
        try testing.expectEqual(@as(usize, 0), ignored.len);

        try db.setInput(NumberInput, 1, 8);
        try testing.expectEqual(first, try db.get(Parent, 0));
        try Parent.executions.expect(1);
        try Child.executions.expect(1);
        try db.setInput(NumberInput, 0, 2);
        try testing.expectEqual(@as(u32, 44), (try db.get(Parent, 0)).*);
        try Parent.executions.expect(2);
        try Child.executions.expect(1);

        try db.setInput(NumberInput, 0, 1);
        try testing.expectEqual(@as(u32, 8), (try db.get(Parent, 0)).*);
        try Child.executions.expect(2);
        const observed = try db.transitiveAccumulatorValues(Parent, 0, u32, testing.allocator);
        defer testing.allocator.free(observed);
        try testing.expectEqualSlices(u32, &.{8}, observed);
        try db.setInput(NumberInput, 1, 9);
        try testing.expectEqual(@as(u32, 9), (try db.get(Parent, 0)).*);
        try Child.executions.expect(3);
    }
}

test "independent prefetches overlap without waiting for an ordinary demand" {
    const Child = struct {
        pub const Input = u32;
        pub const Output = u32;
        var started: std.atomic.Value(u32) = .init(0);
        var released: std.atomic.Value(bool) = .init(false);

        pub fn run(_: *Context, key: Input) !Output {
            _ = started.fetchOr(key, .release);
            while (!released.load(.acquire)) std.atomic.spinLoopHint();
            return key;
        }
    };
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(ctx: *Context, _: Input) !Output {
            try ctx.prefetch(Child, 1);
            errdefer Child.released.store(true, .release);
            try ctx.prefetch(Child, 2);
            while (Child.started.load(.acquire) != 3) std.atomic.spinLoopHint();
            Child.released.store(true, .release);
            return 42;
        }
    };
    const db = try testDatabase(2);
    defer db.deinit();
    Child.started.store(0, .monotonic);
    Child.released.store(false, .monotonic);
    try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
    try db.addInput(NumberInput, 0, 1);
}

test "failed requesters settle prefetches and retain their original error" {
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(ctx: *Context, key: Input) !Output {
            try ctx.prefetch(ReadNumber, key);
            return error.TestInfrastructureFailure;
        }
    };
    for ([_]usize{ 0, 1, 4 }) |workers| {
        const db = try testDatabase(workers);
        defer db.deinit();
        try db.addInput(NumberInput, 0, 7);
        try testing.expectError(error.TestInfrastructureFailure, db.get(Parent, 0));
        try db.setInput(NumberInput, 0, 8);
        try testing.expectEqual(@as(u32, 8), (try db.get(ReadNumber, 0)).*);
        // The missing child's error must not replace the requester's error.
        try testing.expectError(error.TestInfrastructureFailure, db.get(Parent, 1));
        try db.addInput(NumberInput, 1, 9);
        try testing.expectEqual(@as(u32, 9), (try db.get(ReadNumber, 1)).*);
    }
}

test "prefetch allocation failure rolls back an unpublished query" {
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(ctx: *Context, key: Input) !Output {
            const scratch = ctx.scratch_allocator;
            var failing = testing.FailingAllocator.init(scratch, .{ .fail_index = 0 });
            ctx.scratch_allocator = failing.allocator();
            defer ctx.scratch_allocator = scratch;
            try testing.expectError(error.OutOfMemory, ctx.prefetch(ReadNumber, key));
            try testing.expect(failing.has_induced_failure);
            ctx.scratch_allocator = scratch;
            try ctx.prefetch(ReadNumber, key);
            return (try ctx.get(ReadNumber, key)).*;
        }
    };
    const db = try testDatabase(2);
    defer db.deinit();
    try db.addInput(NumberInput, 0, 42);
    try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
    try db.setInput(NumberInput, 0, 43);
    try testing.expectEqual(@as(u32, 43), (try db.get(ReadNumber, 0)).*);
}

test "prefetch wait cycles reject real dependencies and unused hints can recover" {
    const Queries = struct {
        const Parent = struct {
            pub const Input = u32;
            pub const Output = u32;

            pub fn run(ctx: *Context, key: Input) anyerror!Output {
                try ctx.prefetch(Child, key);
                if (key == 1) return (try ctx.get(Child, key)).*;
                return 42;
            }
        };
        const Child = struct {
            pub const Input = u32;
            pub const Output = u32;

            pub fn run(ctx: *Context, key: Input) anyerror!Output {
                return (try ctx.get(Parent, key)).*;
            }
        };
    };
    for ([_]usize{ 0, 1, 4 }) |workers| {
        const db = try testDatabase(workers);
        defer db.deinit();
        try testing.expectEqual(@as(u32, 42), (try db.get(Queries.Parent, 0)).*);
        try testing.expectEqual(@as(u32, 42), (try db.get(Queries.Child, 0)).*);
        try testing.expectError(error.QueryCycle, db.get(Queries.Parent, 1));
        try db.addInput(NumberInput, 0, 1);
    }
}

test "append-only inputs can be read by queries" {
    const db = try testDatabase(2);
    defer db.deinit();

    try db.addInput(NumberInput, 7, 42);
    try testing.expectError(error.DuplicateInput, db.addInput(NumberInput, 7, 99));
    try testing.expectEqual(@as(u32, 42), (try db.get(ReadNumber, 7)).*);
    try testing.expectError(error.InputNotFound, db.get(ReadNumber, 8));
}

test "dependency cycles are reported" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectError(error.QueryCycle, db.get(CycleA, 1));
}

test "waiting workers run the demanded dependency instead of unrelated queued work" {
    const db = try testDatabase(1);
    defer db.deinit();

    WaitingParent.started.store(false, .monotonic);
    WaitingParent.may_wait.store(false, .monotonic);
    const parent = try db.spawn(WaitingParent, 42);
    while (!WaitingParent.started.load(.acquire)) std.atomic.spinLoopHint();
    const sibling = try db.spawn(ParentDependentSibling, 42);
    WaitingParent.may_wait.store(true, .release);

    try testing.expectEqual(@as(u32, 42), (try sibling.wait()).*);
    try testing.expectEqual(@as(u32, 42), (try parent.wait()).*);
}

test "typed accumulators expose direct and transitive diagnostics" {
    const db = try testDatabase(2);
    defer db.deinit();

    try testing.expectEqual(@as(u32, 11), (try db.get(CallEmitDiagnostic, 3)).*);

    const direct = try db.directAccumulatorValues(CallEmitDiagnostic, 3, OwnedDiagnostic);
    try testing.expectEqual(@as(usize, 1), direct.len);
    try testing.expectEqualStrings("root", direct[0].message);

    const all = try db.transitiveAccumulatorValues(CallEmitDiagnostic, 3, OwnedDiagnostic, testing.allocator);
    defer freeOwnedDiagnostics(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("root", all[0].message);
    try testing.expectEqualStrings("leaf", all[1].message);
}

test "verified ancestors expose newly emitted transitive accumulators" {
    const db = try testDatabase(1);
    defer db.deinit();

    try db.addInput(NumberInput, 1, 0);
    try testing.expectEqual(@as(u32, 1), (try db.get(ConditionalControlRoot, 1)).*);
    try db.setInput(NumberInput, 1, 42);

    const controls = try db.transitiveAccumulatorValues(
        ConditionalControlRoot,
        1,
        Control,
        testing.allocator,
    );
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(Control, &.{.{ .exit = 42 }}, controls);

    try db.setInput(NumberInput, 1, 0);
    const cleared = try db.transitiveAccumulatorValues(
        ConditionalControlRoot,
        1,
        Control,
        testing.allocator,
    );
    defer testing.allocator.free(cleared);
    try testing.expectEqual(@as(usize, 0), cleared.len);
}

test "query profiling counts computations rather than memo hits" {
    const profile_module = @import("test_sources").profiling;
    const engine = @import("test_sources").query;
    const Probe = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(_: anytype, value: Input) !Output {
            return value + 2;
        }
    };
    var profile: profile_module.Collector = .{ .io = std.testing.io };
    const db = try engine.Database.init(std.testing.allocator, .{ .worker_count = 1, .profile = &profile });
    defer db.deinit();
    try std.testing.expectEqual(@as(u32, 42), (try db.get(Probe, 40)).*);
    try std.testing.expectEqual(@as(u32, 42), (try db.get(Probe, 40)).*);
    try std.testing.expectEqual(@as(usize, 1), profile.snapshot().get(.query_other).runs);
    _ = try db.get(Probe, 41);
    try std.testing.expectEqual(@as(usize, 2), profile.snapshot().get(.query_other).runs);
}

test "dependency verification skips waiting for settled children and observes their changes" {
    const profiling = @import("test_sources").profiling;
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(ctx: *Context, key: Input) !Output {
            var total: u32 = 0;
            for (key..key + 64) |child| total += (try ctx.get(ReadNumber, @intCast(child))).*;
            return total;
        }
    };
    for ([_]usize{ 0, 2, 4 }) |worker_count| {
        var profile: profiling.Collector = .{ .io = std.testing.io };
        const db = try Database.init(testing.allocator, .{ .worker_count = worker_count, .profile = &profile });
        defer db.deinit();

        for (0..65) |key| try db.addInput(NumberInput, @intCast(key), if (key == 0) 40 else 0);
        try testing.expectEqual(@as(u32, 40), (try db.get(Parent, 0)).*);
        try db.setInput(NumberInput, 64, 1);
        for (0..64) |key| _ = try db.get(ReadNumber, @intCast(key));

        const before = profile.snapshot();
        var scope: profiling.Scope = .{};
        scope.begin(&profile, .query_other);
        const result = db.get(Parent, 0);
        scope.end();
        try testing.expectEqual(@as(u32, 40), (try result).*);
        try testing.expectEqual(@as(usize, 1), profile.snapshot().since(before).get(.dependency_wait).runs);

        try db.setInput(NumberInput, 32, 2);
        try testing.expectEqual(@as(u32, 2), (try db.get(ReadNumber, 32)).*);
        try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
        try db.setInput(NumberInput, 32, 3);
        try testing.expectEqual(@as(u32, 43), (try db.get(Parent, 0)).*);
    }
}

test "equal recomputed child does not recompute parent" {
    const db = try testDatabase(1);
    defer db.deinit();

    Parity.executions.reset();
    ParityParent.executions.reset();

    try db.addInput(NumberInput, 1, 2);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    const diagnostics_before = try db.directAccumulatorValues(Parity, 1, OwnedDiagnostic);

    try db.setInput(NumberInput, 1, 2);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    try Parity.executions.expect(1);
    try ParityParent.executions.expect(1);

    try db.setInput(NumberInput, 1, 4);
    try testing.expectEqual(@as(u32, 0), (try db.get(ParityParent, 1)).*);
    const diagnostics_after = try db.directAccumulatorValues(Parity, 1, OwnedDiagnostic);

    try Parity.executions.expect(2);
    try ParityParent.executions.expect(1);
    try testing.expectEqual(diagnostics_before.ptr, diagnostics_after.ptr);
}

test "changed diagnostic makes an equal value observable" {
    const db = try testDatabase(1);
    defer db.deinit();

    DiagnosticParent.executions.reset();
    try db.addInput(NumberInput, 1, 2);
    _ = try db.get(DiagnosticParent, 1);

    try db.setInput(NumberInput, 1, 4);
    _ = try db.get(DiagnosticParent, 1);
    try DiagnosticParent.executions.expect(2);

    const diagnostics = try db.transitiveAccumulatorValues(DiagnosticParent, 1, OwnedDiagnostic, testing.allocator);
    defer freeOwnedDiagnostics(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("four", diagnostics[0].message);
}

test "recomputation replaces dynamic input dependencies" {
    const db = try testDatabase(1);
    defer db.deinit();

    SelectedNumber.executions.reset();
    try db.addInput(NumberInput, 0, 1);
    try db.addInput(NumberInput, 1, 10);
    try db.addInput(NumberInput, 2, 20);
    try testing.expectEqual(@as(u32, 10), (try db.get(SelectedNumber, 0)).*);

    try db.setInput(NumberInput, 0, 2);
    try testing.expectEqual(@as(u32, 20), (try db.get(SelectedNumber, 0)).*);

    try db.setInput(NumberInput, 1, 11);
    try testing.expectEqual(@as(u32, 20), (try db.get(SelectedNumber, 0)).*);
    try SelectedNumber.executions.expect(2);
}

test "query imports retain equal live results and their computed dependencies" {
    const Version = struct {
        pub const Key = void;
        pub const Value = u32;
    };
    const Text = struct {
        pub const Input = void;
        pub const Output = ?OwnedOutput;

        pub fn run(ctx: *Context, _: void) !Output {
            const version = (try ctx.input(Version, {})).*;
            return .{ .bytes = try ctx.allocator().dupe(u8, if (version == 0) "current" else "updated") };
        }

        pub fn eqlOutput(left: Output, right: Output) bool {
            if (left == null or right == null) return left == null and right == null;
            return std.mem.eql(u8, left.?.bytes, right.?.bytes);
        }
    };
    const db = try Database.init(testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try db.addInput(Version, {}, 0);
    const retained = try db.get(Text, {});
    const imported: OwnedOutput = .{ .bytes = try testing.allocator.dupe(u8, "current") };
    try db.importCompletedQuery(Text, {}, imported, &.{}, &.{});
    try testing.expectEqual(retained, try db.get(Text, {}));
    try testing.expectEqualStrings("current", retained.*.?.bytes);
    const mismatched: OwnedOutput = .{ .bytes = try testing.allocator.dupe(u8, "different") };
    defer testing.allocator.free(mismatched.bytes);
    try testing.expectError(error.InvalidCache, db.importCompletedQuery(Text, {}, mismatched, &.{}, &.{}));
    try db.setInput(Version, {}, 1);
    try testing.expectEqualStrings("updated", (try db.get(Text, {})).*.?.bytes);
}

test "query storage releases scratch before retaining published bytes" {
    const ScratchQuery = struct {
        pub const Input = u32;
        pub const Output = OwnedOutput;

        pub fn run(ctx: *Context, _: Input) !Output {
            const temporary = try ctx.allocator().alloc(u8, 4 * 1024 * 1024);
            defer ctx.allocator().free(temporary);
            @memset(temporary, 42);
            return .{ .bytes = try ctx.allocator().dupe(u8, "ok") };
        }
    };
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    const db = try Database.init(tracking.allocator(), .{ .worker_count = 1 });
    defer db.deinit();
    const initial_live = tracking.allocated_bytes - tracking.freed_bytes;
    const published = try db.get(ScratchQuery, 0);
    try testing.expectEqualStrings("ok", published.bytes);
    try testing.expect(published == try db.get(ScratchQuery, 0));
    try testing.expect(tracking.allocated_bytes - tracking.freed_bytes - initial_live < 1024 * 1024);
}

test "direct result arenas transfer ownership and release scratch on success and failure" {
    const Implementation = struct {
        var published: [*]u8 = undefined;

        fn run(ctx: *Context, key: u32) !OwnedOutput {
            const value = (try ctx.input(NumberInput, key)).*;
            const temporary = try ctx.allocator().alloc(u8, 4 * 1024 * 1024);
            @memset(temporary, 42);
            const bytes = try ctx.resultAllocator().alloc(u8, 1);
            bytes[0] = @intCast(value % 2);
            if (value == 4) return error.TestInfrastructureFailure;
            published = bytes.ptr;
            return .{ .bytes = bytes };
        }
    };
    const Direct = query.Query("direct-result", .query_other, Implementation.run, .{ .result_arena = true });
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    const db = try Database.init(tracking.allocator(), .{ .worker_count = 1 });
    var live = true;
    defer if (live) db.deinit();
    OwnedOutput.deinits.reset();
    try db.addInput(NumberInput, 0, 2);
    const initial_live = tracking.allocated_bytes - tracking.freed_bytes;
    const first = try db.get(Direct, 0);
    try testing.expectEqual(Implementation.published, first.bytes.ptr);
    try testing.expectEqual(@as(u8, 0), first.bytes[0]);
    try testing.expect(tracking.allocated_bytes - tracking.freed_bytes - initial_live < 1024 * 1024);

    try db.setInput(NumberInput, 0, 4);
    try testing.expectError(error.TestInfrastructureFailure, db.get(Direct, 0));
    try OwnedOutput.deinits.expect(0);
    try testing.expectEqual(@as(u8, 0), first.bytes[0]);
    try testing.expect(tracking.allocated_bytes - tracking.freed_bytes - initial_live < 1024 * 1024);

    try db.setInput(NumberInput, 0, 6);
    try testing.expectEqual(first, try db.get(Direct, 0));
    try OwnedOutput.deinits.expect(1);
    try db.setInput(NumberInput, 0, 7);
    const changed = try db.get(Direct, 0);
    try testing.expectEqual(Implementation.published, changed.bytes.ptr);
    try testing.expectEqual(@as(u8, 1), changed.bytes[0]);
    try OwnedOutput.deinits.expect(2);
    db.deinit();
    live = false;
    try OwnedOutput.deinits.expect(3);
}

test "direct result queries copy memo provider outputs into persistent storage" {
    const Implementation = struct {
        fn run(_: *Context, _: u32) !OwnedOutput {
            return error.TestUnexpectedResult;
        }
    };
    const Direct = query.Query("direct-restored-result", .query_other, Implementation.run, .{ .result_arena = true });
    const Provider = struct {
        pub const query_types = .{Direct};

        pub fn load(_: *@This(), comptime Q: type, ctx: *Context, key: Q.Input) !?Q.Output {
            const value = (try ctx.input(NumberInput, key)).*;
            return .{ .bytes = try ctx.allocator().dupe(u8, if (value == 0) "restored" else "updated") };
        }

        pub fn deinit(_: *@This()) void {}
    };
    var provider: Provider = .{};
    const db = try testDatabase(1);
    defer db.deinit();
    try db.installMemoProvider(Provider, &provider);
    try db.addInput(NumberInput, 0, 0);
    try testing.expectEqualStrings("restored", (try db.get(Direct, 0)).bytes);
    try db.setInput(NumberInput, 0, 1);
    try testing.expectEqualStrings("updated", (try db.get(Direct, 0)).bytes);
}

test "query storage preserves large aligned identities during recomputation" {
    const AlignedQuery = struct {
        pub const Input = struct {
            key: u32,
            padding: [64]u8 align(64) = @splat(0),
        };
        pub const Output = u32;

        pub fn run(ctx: *Context, input_value: Input) !Output {
            return (try ctx.input(NumberInput, input_value.key)).*;
        }
    };
    const db = try Database.init(testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try db.addInput(NumberInput, 0, 12);
    try db.addInput(NumberInput, 1, 99);
    try testing.expectEqual(12, (try db.get(AlignedQuery, .{ .key = 0 })).*);
    const retained = try db.get(AlignedQuery, .{ .key = 1 });
    try db.setInput(NumberInput, 0, 42);
    try testing.expectEqual(42, (try db.get(AlignedQuery, .{ .key = 0 })).*);
    try testing.expect(retained == try db.get(AlignedQuery, .{ .key = 1 }));
    try testing.expectEqual(99, retained.*);
}

test "owned outputs are retained or replaced exactly once" {
    const db = try testDatabase(1);
    var db_live = true;
    defer if (db_live) db.deinit();

    OwnedOutput.deinits.reset();
    try db.addInput(NumberInput, 1, 2);
    const first = try db.get(OwnedParity, 1);

    try db.setInput(NumberInput, 1, 4);
    const equal = try db.get(OwnedParity, 1);
    try testing.expectEqual(first, equal);
    try OwnedOutput.deinits.expect(1);

    try db.setInput(NumberInput, 1, 5);
    const changed = try db.get(OwnedParity, 1);
    try testing.expect(first != changed);
    try OwnedOutput.deinits.expect(2);

    db.deinit();
    db_live = false;
    try OwnedOutput.deinits.expect(3);
}

test "failed recomputation preserves retained state and is retryable" {
    const db = try testDatabase(1);
    var db_live = true;
    defer if (db_live) db.deinit();

    OwnedOutput.deinits.reset();
    RetryableFailure.executions.reset();
    try db.addInput(NumberInput, 1, 2);
    const initial = try db.get(RetryableFailure, 1);

    try db.setInput(NumberInput, 1, 4);
    try testing.expectError(error.TestInfrastructureFailure, db.get(RetryableFailure, 1));
    try testing.expectError(error.TestInfrastructureFailure, db.get(RetryableFailure, 1));
    try RetryableFailure.executions.expect(3);
    try OwnedOutput.deinits.expect(0);

    try db.setInput(NumberInput, 1, 6);
    const replacement = try db.get(RetryableFailure, 1);
    try testing.expect(initial != replacement);
    try RetryableFailure.executions.expect(4);
    try OwnedOutput.deinits.expect(1);

    const diagnostics = try db.directAccumulatorValues(RetryableFailure, 1, OwnedDiagnostic);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqualStrings("replacement", diagnostics[0].message);

    db.deinit();
    db_live = false;
    try OwnedOutput.deinits.expect(2);
}

test "concurrent requests observe one committed result" {
    const db = try testDatabase(4);
    defer db.deinit();

    CountedQuery.executions.reset();
    var handles: [16]Handle(CountedQuery) = undefined;
    for (&handles) |*handle| handle.* = try db.spawn(CountedQuery, 7);
    for (handles) |handle| try testing.expectEqual(@as(u32, 7), (try handle.wait()).*);
    try CountedQuery.executions.expect(1);
}

test "stale dependencies do not create false cycles" {
    const db = try testDatabase(2);
    defer db.deinit();

    try db.addInput(NumberInput, 10, 0);
    try db.addInput(NumberInput, 11, 0);
    try testing.expectEqual(@as(u32, 0), (try db.get(DynamicCycleA, 1)).*);

    try db.setInput(NumberInput, 10, 1);
    try db.setInput(NumberInput, 11, 1);
    try testing.expectEqual(@as(u32, 1), (try db.get(DynamicCycleB, 1)).*);
}

test "cycles introduced during dependency verification reject retry and recover" {
    for ([_]usize{ 1, 4 }) |worker_count| {
        const db = try testDatabase(worker_count);
        defer db.deinit();

        try db.addInput(NumberInput, 10, 0);
        try db.addInput(NumberInput, 11, 0);
        const initial = try db.get(DynamicCycleA, 1);
        try testing.expectEqual(@as(u32, 0), initial.*);

        try db.setInput(NumberInput, 11, 1);
        try testing.expectError(error.QueryCycle, db.get(DynamicCycleA, 1));
        try testing.expectError(error.QueryCycle, db.get(DynamicCycleA, 1));

        try db.setInput(NumberInput, 11, 0);
        try testing.expectEqual(initial, try db.get(DynamicCycleA, 1));
        try db.setInput(NumberInput, 10, 1);
        try db.setInput(NumberInput, 11, 1);
        try testing.expectEqual(@as(u32, 1), (try db.get(DynamicCycleB, 1)).*);
    }
}

test "database initialization frees state when worker allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, Database.init(failing.allocator(), .{ .worker_count = 1 }));
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "discarded spawn handles settle scalar accumulators before parent publication" {
    const Child = struct {
        pub const Input = u32;
        pub const Output = u32;

        pub fn run(ctx: *Context, value: Input) !Output {
            try ctx.emit(u32, value);
            return value;
        }
    };
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        var started: std.atomic.Value(bool) = .init(false);

        pub fn run(ctx: *Context, value: Input) !Output {
            started.store(true, .release);
            _ = try ctx.spawn(Child, value);
            return value;
        }
    };
    const db = try testDatabase(1);
    defer db.deinit();
    Parent.started.store(false, .monotonic);
    const parent = try db.spawn(Parent, 42);
    while (!Parent.started.load(.acquire)) std.atomic.spinLoopHint();
    try testing.expectEqual(@as(u32, 42), (try parent.wait()).*);
    const emitted = try db.transitiveAccumulatorValues(Parent, 42, u32, testing.allocator);
    defer testing.allocator.free(emitted);
    try testing.expectEqualSlices(u32, &.{42}, emitted);
    try db.addInput(NumberInput, 0, 1);
}

test "failed query publication preserves borrowed dependency storage" {
    const Payload = struct {
        rows: []const []const u8,

        pub fn eql(first: @This(), second: @This()) bool {
            if (first.rows.len != second.rows.len) return false;
            for (first.rows, second.rows) |left, right| if (!std.mem.eql(u8, left, right)) return false;
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.rows) |*row| {
                allocator.free(row.*);
                @constCast(row).* = &.{};
            }
            allocator.free(self.rows);
        }
    };
    const Source = struct {
        pub const Input = void;
        pub const Output = Payload;

        pub fn run(ctx: *Context, _: Input) !Output {
            const rows = try ctx.allocator().alloc([]const u8, 2);
            rows[0] = try ctx.allocator().dupe(u8, "stable");
            const large = try ctx.allocator().alloc(u8, 2 * 1024 * 1024);
            @memset(large, 'x');
            rows[1] = large;
            return .{ .rows = rows };
        }
    };
    const Borrowed = struct {
        pub const Input = void;
        pub const Output = Payload;
        var failing: *testing.FailingAllocator = undefined;

        pub fn run(ctx: *Context, _: Input) !Output {
            const source = (try ctx.get(Source, {})).*;
            failing.fail_index = failing.alloc_index;
            return source;
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const db = try Database.init(failing.allocator(), .{ .worker_count = 0 });
    defer db.deinit();
    Borrowed.failing = &failing;
    const source = try db.get(Source, {});
    try testing.expectError(error.OutOfMemory, db.get(Borrowed, {}));
    failing.fail_index = std.math.maxInt(usize);
    const retained = try db.get(Source, {});
    try testing.expectEqual(source, retained);
    try testing.expectEqualStrings("stable", retained.rows[0]);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), retained.rows[1].len);
    try testing.expectEqual(@as(u8, 'x'), retained.rows[1][0]);
    try testing.expectEqual(@as(u8, 'x'), retained.rows[1][retained.rows[1].len - 1]);
}

test "failed dependency registration leaves stale queries idle and retryable" {
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        var failing: *testing.FailingAllocator = undefined;

        pub fn run(ctx: *Context, value: Input) !Output {
            failing.fail_index = failing.alloc_index;
            for (0..value) |key| _ = try ctx.get(CountedQuery, @intCast(key));
            return value;
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const db = try Database.init(failing.allocator(), .{ .worker_count = 1 });
    defer db.deinit();
    Parent.failing = &failing;
    try db.addInput(NumberInput, 0, 1);
    const dependency_count = 8192;
    for (0..dependency_count) |key| _ = try db.get(CountedQuery, @intCast(key));
    try db.setInput(NumberInput, 0, 2);
    try testing.expectError(error.OutOfMemory, db.get(Parent, dependency_count));
    failing.fail_index = std.math.maxInt(usize);
    try db.setInput(NumberInput, 0, 3);
    try testing.expectEqual(@as(u32, 42), (try db.get(CountedQuery, 42)).*);
}

test "adding a previously missing input invalidates cached fallback results" {
    if (!@import("test_options").allocation_failures) return testMissingInputRegistration(testing.allocator);
    try testing.checkAllAllocationFailures(allocation_failure_allocator, testMissingInputRegistration, .{});
}

fn testMissingInputRegistration(gpa: std.mem.Allocator) !void {
    const OptionalInput = struct {
        pub const Key = u32;
        pub const Value = u32;
    };
    const ReadOptional = struct {
        pub const Input = u32;
        pub const Output = u32;
        pub fn run(ctx: *Context, key: Input) !Output {
            const value = ctx.input(OptionalInput, key) catch |err| switch (err) {
                error.InputNotFound => return 0,
                else => return err,
            };
            return value.*;
        }
    };
    const db = try Database.init(gpa, .{ .worker_count = 0 });
    defer db.deinit();
    try testing.expectEqual(@as(u32, 0), (try db.get(ReadOptional, 1)).*);
    try testing.expectError(error.InputNotFound, db.setInput(OptionalInput, 1, 42));
    try db.addInput(OptionalInput, 1, 42);
    try testing.expectEqual(@as(u32, 42), (try db.get(ReadOptional, 1)).*);
    try testing.expectError(error.DuplicateInput, db.addInput(OptionalInput, 1, 5));
    try db.setInput(OptionalInput, 1, 24);
    try testing.expectEqual(@as(u32, 24), (try db.get(ReadOptional, 1)).*);
}

test "handled child failures recompute without publishing stale accumulators" {
    const Child = struct {
        pub const Input = u32;
        pub const Output = u32;
        pub fn run(ctx: *Context, key: Input) !Output {
            const value = (try ctx.input(NumberInput, key)).*;
            if (value == 0) return error.NotAvailable;
            try ctx.emit(u32, value);
            return value;
        }
    };
    const Parent = struct {
        pub const Input = u32;
        pub const Output = u32;
        pub fn run(ctx: *Context, key: Input) !Output {
            const value = ctx.get(Child, key) catch |err| switch (err) {
                error.NotAvailable => return 0,
                else => return err,
            };
            return value.*;
        }
    };
    const db = try testDatabase(1);
    defer db.deinit();
    try db.addInput(NumberInput, 0, 42);
    try db.addInput(NumberInput, 1, 0);
    try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
    try db.setInput(NumberInput, 0, 0);
    try testing.expectEqual(@as(u32, 0), (try db.get(Parent, 0)).*);
    const accumulated = try db.transitiveAccumulatorValues(Parent, 0, u32, testing.allocator);
    defer testing.allocator.free(accumulated);
    try testing.expectEqual(@as(usize, 0), accumulated.len);
    try db.setInput(NumberInput, 1, 1);
    try testing.expectEqual(@as(u32, 0), (try db.get(Parent, 0)).*);
    try db.setInput(NumberInput, 0, 42);
    try testing.expectEqual(@as(u32, 42), (try db.get(Child, 0)).*);
    try testing.expectEqual(@as(u32, 42), (try db.get(Parent, 0)).*);
    const recovered = try db.transitiveAccumulatorValues(Parent, 0, u32, testing.allocator);
    defer testing.allocator.free(recovered);
    try testing.expectEqualSlices(u32, &.{42}, recovered);
}

test "custom query and input keys preserve aliases collisions and incremental dependencies" {
    const CacheKey = struct { id: u32, spelling: u32 };
    const Setting = struct {
        pub const Key = CacheKey;
        pub const Value = u32;
        pub fn hashKey(_: Key) u64 {
            return 0;
        }
        pub fn eqlKey(left: Key, right: Key) bool {
            return left.id == right.id;
        }
    };
    const Read = struct {
        pub const Input = CacheKey;
        pub const Output = u32;
        pub const hash = Setting.hashKey;
        pub const eql = Setting.eqlKey;
        var runs: Counter = .{};
        pub fn run(ctx: *Context, key: Input) !Output {
            runs.increment();
            return (try ctx.input(Setting, key)).*;
        }
    };
    const db = try Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    const first: CacheKey = .{ .id = 1, .spelling = 10 };
    const alias: CacheKey = .{ .id = 1, .spelling = 20 };
    const other: CacheKey = .{ .id = 2, .spelling = 10 };
    try db.addInput(Setting, first, 42);
    try db.addInput(Setting, other, 7);
    try testing.expectError(error.DuplicateInput, db.addInput(Setting, alias, 99));
    try testing.expectEqual(@as(u32, 42), (try db.get(Read, first)).*);
    try testing.expectEqual(@as(u32, 42), (try db.get(Read, alias)).*);
    try Read.runs.expect(1);
    try testing.expectEqual(@as(u32, 7), (try db.get(Read, other)).*);
    try Read.runs.expect(2);
    try db.setInput(Setting, alias, 43);
    try testing.expectEqual(@as(u32, 43), (try db.get(Read, first)).*);
    try Read.runs.expect(3);
    try testing.expectEqual(@as(u32, 7), (try db.get(Read, other)).*);
    try Read.runs.expect(3);

    const Graph = struct {
        const Root = struct {
            pub const Input = u32;
            pub const Output = u32;
            pub fn hash(_: Input) u64 {
                return comptime std.hash.Wyhash.hash(0, @typeName(Read)) ^ std.hash.Wyhash.hash(0, @typeName(@This()));
            }
            pub fn run(ctx: *Context, key: Input) !Output {
                return (try ctx.get(Parent, key)).*;
            }
        };
        const Parent = struct {
            pub const Input = u32;
            pub const Output = u32;
            pub fn run(ctx: *Context, key: Input) !Output {
                var total: u32 = 0;
                for (0..96) |index| total += (try ctx.get(Read, .{ .id = @intCast(index), .spelling = 10 })).*;
                for (0..3) |_| {
                    if (ctx.get(Root, key)) |_| return error.ExpectedCycle else |err| {
                        if (err != error.QueryCycle) return err;
                    }
                    var repeated: u32 = 0;
                    for (0..96) |index| repeated += (try ctx.get(Read, .{ .id = @intCast(index), .spelling = 20 })).*;
                    if (repeated != total) return error.InconsistentDependency;
                }
                return total;
            }
        };
    };
    for (0..96) |index| {
        if (index == first.id or index == other.id) continue;
        try db.addInput(Setting, .{ .id = @intCast(index), .spelling = 10 }, @intCast(index));
    }
    try testing.expectEqual(@as(u32, 4607), (try db.get(Graph.Root, 0)).*);
    try Read.runs.expect(97);
    try db.setInput(Setting, .{ .id = 31, .spelling = 20 }, 1000);
    try testing.expectEqual(@as(u32, 5576), (try db.get(Graph.Root, 0)).*);
    try Read.runs.expect(98);
}
