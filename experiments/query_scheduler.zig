const std = @import("std");

fn yieldThread() void {
    std.Thread.yield() catch {};
}

/// A tiny synchronous query scheduler with work stealing, typed queries,
/// runtime-discovered dependencies, in-flight deduplication, and memoization.
///
/// A query is a type with this shape:
///
///     const MyQuery = struct {
///         pub const Input = ...;
///         pub const Output = ...;
///
///         pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
///             var left = try ctx.spawn(LeftQuery, input.left);
///             var right = try ctx.spawn(RightQuery, input.right);
///
///             const a = try left.wait();
///             const b = try right.wait();
///             ...
///         }
///
///         // Optional, for inputs that std.hash.autoHash/std.meta.eql cannot
///         // represent correctly, such as slices.
///         pub fn hash(input: Input) u64 { ... }
///         pub fn eql(a: Input, b: Input) bool { ... }
///     };
///
/// Root calls are synchronous:
///
///     const value = try scheduler.run(MyQuery, input);
///
/// Query inputs and outputs are stored by value. In practice, inputs
/// should be stable while cached, and outputs should be copyable values or
/// references to storage owned elsewhere.
///
/// ============================================================================
/// Core
/// ============================================================================
///
/// Scheduler owns the whole runtime: the memo table, worker queues, worker
/// threads, and the single lock protecting shared state.
pub const Scheduler = struct {
    const Self = @This();
    const State = enum { queued, running, done };

    /// Context is passed to Query.run. It is the typed API surface for
    /// dynamically declaring dependencies.
    pub const Context = struct {
        scheduler: *Self,
        worker_index: ?usize,
        current: ?*ErasedEntry,

        pub fn spawn(ctx: *Context, comptime Query: type, input: Query.Input) anyerror!Handle(Query) {
            return ctx.scheduler.spawnFromContext(ctx.current, ctx.worker_index, Query, input);
        }

        pub fn call(ctx: *Context, comptime Query: type, input: Query.Input) anyerror!Query.Output {
            var handle = try ctx.spawn(Query, input);
            return handle.wait();
        }
    };

    /// ErasedEntry is the untyped cache/work-queue record shared by all query
    /// types. It stores the key metadata, execution state, intrusive queue node,
    /// and type-erased operations needed by the scheduler.
    const ErasedEntry = struct {
        queue_node: std.DoublyLinkedList.Node = .{},
        hash: u64,
        type_name: []const u8,
        state: State = .queued,
        err: ?anyerror = null,
        parent: ?*ErasedEntry,
        execute: *const fn (*Self, ?usize, *ErasedEntry) void,
        matches: *const fn (*ErasedEntry, *const anyopaque) bool,
        destroy: *const fn (*Self, *ErasedEntry) void,
    };

    /// Entry(Query) is the typed storage behind an ErasedEntry: the concrete
    /// input and result for exactly one query type.
    fn Entry(comptime Query: type) type {
        _ = Query.Input;
        _ = Query.Output;
        _ = Query.run;

        return struct {
            base: ErasedEntry,
            input: Query.Input,
            result: Query.Output = undefined,

            const EntrySelf = @This();

            fn init(input: Query.Input, hash: u64, parent: ?*ErasedEntry) EntrySelf {
                return .{
                    .base = .{
                        .hash = hash,
                        .type_name = @typeName(Query),
                        .parent = parent,
                        .execute = execute,
                        .matches = matches,
                        .destroy = destroy,
                    },
                    .input = input,
                };
            }

            fn execute(scheduler: *Self, worker_index: ?usize, base: *ErasedEntry) void {
                const entry: *EntrySelf = @fieldParentPtr("base", base);

                var ctx = Context{
                    .scheduler = scheduler,
                    .worker_index = worker_index,
                    .current = base,
                };

                const maybe_result = Query.run(&ctx, entry.input);
                scheduler.finishEntry(Query, entry, maybe_result);
            }

            fn matches(base: *ErasedEntry, input_ptr: *const anyopaque) bool {
                const entry: *EntrySelf = @fieldParentPtr("base", base);
                const input: *const Query.Input = @ptrCast(@alignCast(input_ptr));
                return inputEql(Query, entry.input, input.*);
            }

            fn destroy(scheduler: *Self, base: *ErasedEntry) void {
                const entry: *EntrySelf = @fieldParentPtr("base", base);
                scheduler.allocator.destroy(entry);
            }
        };
    }

    /// Handle(Query) is a typed view of a cached or in-flight entry. Waiting on
    /// it returns Query.Output while helping the scheduler run other work.
    pub fn Handle(comptime Query: type) type {
        return struct {
            scheduler: *Self,
            worker_index: ?usize,
            entry: ?*Entry(Query),

            pub fn wait(handle: *@This()) anyerror!Query.Output {
                const entry = handle.entry orelse return error.HandleAlreadyWaited;
                handle.entry = null;

                return handle.scheduler.waitForEntry(handle.worker_index, Query, entry);
            }
        };
    }

    allocator: std.mem.Allocator,
    state_mutex: std.atomic.Mutex = .unlocked,
    /// std.DoublyLinkedList is intrusive and untyped: it stores only Node links.
    /// ErasedEntry embeds a Node, so popping work requires @fieldParentPtr.
    queues: []std.DoublyLinkedList,
    entries: std.ArrayList(*ErasedEntry),
    threads: []std.Thread,
    threads_started: usize = 0,
    started: bool = false,
    shutdown: std.atomic.Value(bool) = .init(false),
    next_queue: usize = 0,

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !Self {
        const count = if (worker_count == 0) 1 else worker_count;

        const queues = try allocator.alloc(std.DoublyLinkedList, count);
        errdefer allocator.free(queues);
        for (queues) |*queue| {
            queue.* = .{};
        }

        const threads = try allocator.alloc(std.Thread, count);
        errdefer allocator.free(threads);

        return .{
            .allocator = allocator,
            .queues = queues,
            .entries = try std.ArrayList(*ErasedEntry).initCapacity(allocator, 0),
            .threads = threads,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stopWorkers();

        for (self.entries.items) |entry| {
            entry.destroy(self, entry);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.queues);
        self.allocator.free(self.threads);
        self.* = undefined;
    }

    pub fn run(self: *Self, comptime Query: type, input: Query.Input) anyerror!Query.Output {
        if (!self.started) try self.startWorkers();

        var handle = try self.spawnFromContext(null, null, Query, input);
        return handle.wait();
    }

    fn spawnFromContext(
        self: *Self,
        parent: ?*ErasedEntry,
        worker_index: ?usize,
        comptime Query: type,
        input: Query.Input,
    ) anyerror!Handle(Query) {
        if (!self.started) try self.startWorkers();

        const hash = inputHash(Query, input);

        self.stateLock();
        defer self.stateUnlock();

        const entry = try self.getOrCreateEntryLocked(Query, input, hash, parent);
        if (parent != null and chainContains(parent, &entry.base)) {
            return error.QueryCycle;
        }

        return .{
            .scheduler = self,
            .worker_index = worker_index,
            .entry = entry,
        };
    }

    fn getOrCreateEntryLocked(
        self: *Self,
        comptime Query: type,
        input: Query.Input,
        hash: u64,
        parent: ?*ErasedEntry,
    ) !*Entry(Query) {
        const type_name = @typeName(Query);
        for (self.entries.items) |base| {
            if (base.hash != hash) continue;
            if (!std.mem.eql(u8, base.type_name, type_name)) continue;
            if (!base.matches(base, @ptrCast(&input))) continue;

            const entry: *Entry(Query) = @fieldParentPtr("base", base);
            return entry;
        }

        const entry = try self.allocator.create(Entry(Query));
        entry.* = Entry(Query).init(input, hash, parent);
        try self.entries.append(self.allocator, &entry.base);
        self.enqueueLocked(&entry.base);
        return entry;
    }

    fn enqueueLocked(self: *Self, entry: *ErasedEntry) void {
        const index = self.next_queue;
        self.next_queue = (self.next_queue + 1) % self.queues.len;
        entry.state = .queued;
        self.queues[index].append(&entry.queue_node);
    }

    fn waitForEntry(
        self: *Self,
        worker_index: ?usize,
        comptime Query: type,
        entry: *Entry(Query),
    ) anyerror!Query.Output {
        while (true) {
            if (self.tryReadResult(Query, entry)) |result| return result;

            const helper_start = worker_index orelse 0;
            if (self.takeWork(helper_start)) |work| {
                work.execute(self, worker_index, work);
                continue;
            }

            yieldThread();
        }
    }

    fn tryReadResult(self: *Self, comptime Query: type, entry: *Entry(Query)) ?anyerror!Query.Output {
        self.stateLock();
        defer self.stateUnlock();

        if (entry.base.state != .done) return null;
        if (entry.base.err) |err| return err;
        return entry.result;
    }

    fn takeWork(self: *Self, start_index: usize) ?*ErasedEntry {
        self.stateLock();
        defer self.stateUnlock();

        var offset: usize = 0;
        while (offset < self.queues.len) : (offset += 1) {
            const index = (start_index + offset) % self.queues.len;
            const maybe_node = if (offset == 0)
                self.queues[index].pop()
            else
                self.queues[index].popFirst();

            if (maybe_node) |node| {
                const entry: *ErasedEntry = @fieldParentPtr("queue_node", node);
                entry.state = .running;
                return entry;
            }
        }

        return null;
    }

    fn finishEntry(
        self: *Self,
        comptime Query: type,
        entry: *Entry(Query),
        maybe_result: anyerror!Query.Output,
    ) void {
        self.stateLock();
        defer self.stateUnlock();

        if (maybe_result) |result| {
            entry.result = result;
            entry.base.err = null;
        } else |err| {
            entry.base.err = err;
        }
        entry.base.state = .done;
    }

    fn startWorkers(self: *Self) !void {
        self.shutdown.store(false, .release);

        errdefer self.stopWorkers();
        while (self.threads_started < self.threads.len) : (self.threads_started += 1) {
            self.threads[self.threads_started] = try std.Thread.spawn(
                .{},
                workerLoop,
                .{ self, self.threads_started },
            );
        }

        self.started = true;
    }

    fn workerLoop(self: *Self, worker_index: usize) void {
        while (!self.shutdown.load(.acquire)) {
            if (self.takeWork(worker_index)) |entry| {
                entry.execute(self, worker_index, entry);
                continue;
            }
            yieldThread();
        }
    }

    fn stopWorkers(self: *Self) void {
        self.shutdown.store(true, .release);

        var index: usize = 0;
        while (index < self.threads_started) : (index += 1) {
            self.threads[index].join();
        }

        self.threads_started = 0;
        self.started = false;
    }

    fn stateLock(self: *Self) void {
        while (!self.state_mutex.tryLock()) {
            yieldThread();
        }
    }

    fn stateUnlock(self: *Self) void {
        self.state_mutex.unlock();
    }

    fn chainContains(parent: ?*ErasedEntry, target: *ErasedEntry) bool {
        var current = parent;
        while (current) |entry| : (current = entry.parent) {
            if (entry.state == .done) return false;
            if (entry == target) return true;
        }
        return false;
    }
};

fn inputHash(comptime Query: type, input: Query.Input) u64 {
    if (comptime @hasDecl(Query, "hash")) {
        return Query.hash(input);
    }

    var hasher = std.hash.Wyhash.init(typeHash(Query));
    std.hash.autoHash(&hasher, input);
    return hasher.final();
}

fn inputEql(comptime Query: type, a: Query.Input, b: Query.Input) bool {
    if (comptime @hasDecl(Query, "eql")) {
        return Query.eql(a, b);
    }

    return std.meta.eql(a, b);
}

fn typeHash(comptime Query: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(Query));
}

// ============================================================================
// Tests
// ============================================================================

const Fib = struct {
    pub const Input = u32;
    pub const Output = u64;

    pub fn run(ctx: *Scheduler.Context, n: Input) anyerror!Output {
        if (n < 2) return n;

        var left = try ctx.spawn(Fib, n - 1);
        var right = try ctx.spawn(Fib, n - 2);

        const a = try left.wait();
        const b = try right.wait();
        return a + b;
    }
};

const UnderLimit = struct {
    pub const Input = struct {
        n: u32,
        limit: u64,
    };
    pub const Output = bool;

    pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
        const value = try ctx.call(Fib, input.n);
        return value < input.limit;
    }
};

const GateSide = enum {
    left,
    right,
};

var gate_started = std.atomic.Value(u32).init(0);

const Gate = struct {
    pub const Input = GateSide;
    pub const Output = u32;

    pub fn run(ctx: *Scheduler.Context, side: Input) anyerror!Output {
        _ = ctx;

        _ = gate_started.fetchAdd(1, .acq_rel);

        var spins: usize = 0;
        while (gate_started.load(.acquire) < 2) : (spins += 1) {
            if (spins > 1_000_000) return error.DependencyDidNotStartInParallel;
            std.Thread.yield() catch {};
        }

        return switch (side) {
            .left => 10,
            .right => 32,
        };
    }
};

const ParallelSum = struct {
    pub const Input = void;
    pub const Output = u32;

    pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
        _ = input;

        var left = try ctx.spawn(Gate, .left);
        var right = try ctx.spawn(Gate, .right);

        return try left.wait() + try right.wait();
    }
};

var counted_runs = std.atomic.Value(u32).init(0);

const Counted = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
        _ = ctx;
        _ = counted_runs.fetchAdd(1, .acq_rel);
        return input * 2;
    }
};

const DuplicateDeps = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
        var a = try ctx.spawn(Counted, input);
        var b = try ctx.spawn(Counted, input);
        return try a.wait() + try b.wait();
    }
};

const CycleA = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
        return ctx.call(CycleB, input);
    }
};

const CycleB = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn run(ctx: *Scheduler.Context, input: Input) anyerror!Output {
        return ctx.call(CycleA, input);
    }
};

test "typed runtime-discovered query dependencies" {
    var scheduler = try Scheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u64, 55), try scheduler.run(Fib, 10));
    try std.testing.expect(try scheduler.run(UnderLimit, .{ .n = 10, .limit = 100 }));
    try std.testing.expect(!try scheduler.run(UnderLimit, .{ .n = 10, .limit = 10 }));
}

test "spawned dependencies can overlap before either is awaited" {
    gate_started.store(0, .release);

    var scheduler = try Scheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u32, 42), try scheduler.run(ParallelSum, {}));
}

test "duplicate dependencies share one in-flight computation and cache result" {
    counted_runs.store(0, .release);

    var scheduler = try Scheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(u32, 20), try scheduler.run(DuplicateDeps, 5));
    try std.testing.expectEqual(@as(u32, 1), counted_runs.load(.acquire));
    try std.testing.expectEqual(@as(u32, 10), try scheduler.run(Counted, 5));
    try std.testing.expectEqual(@as(u32, 1), counted_runs.load(.acquire));
}

test "cycles are reported instead of deadlocking" {
    var scheduler = try Scheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    try std.testing.expectError(error.QueryCycle, scheduler.run(CycleA, 1));
}
