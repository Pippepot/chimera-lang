const std = @import("std");

/// A self-contained scheduler for typed, memoized queries.
///
/// A query is any struct with exactly one public `Input` type, exactly one
/// public `Output` type, and a compute function:
///
///     pub const MyQuery = struct {
///         pub const Input = u32;
///         pub const Output = u32;
///
///         pub fn compute(ctx: *Context, input: Input) anyerror!Output {
///             _ = ctx;
///             return input + 1;
///         }
///     };
///
/// Queries may optionally define custom input hashing and equality:
///
///     pub fn hash(input: Input) u64
///     pub fn eql(a: Input, b: Input) bool
///
/// Without those functions the scheduler uses `std.hash.autoHash` and
/// `std.meta.eql`, which is a good default for simple structural value types.
/// Prefer custom hash/equality when inputs contain slices, pointers, handles, or
/// padding-sensitive data.
///
/// Ownership expectations:
///
/// * Inputs and outputs are cached by value.
/// * The scheduler only owns the storage for those copied values. It does not
///   deep-copy or deinitialize data reachable through pointers/slices inside
///   them.
/// * If an input contains references, the referenced data must remain valid and
///   stable for as long as the scheduler cache can compare that input.
/// * Outputs should be copyable values, or references/slices to storage owned
///   outside the scheduler.
/// * A handle returned by `Context.schedule` is intended to be waited inside the
///   same query computation. Letting it escape would also let the embedded
///   context pointer escape.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io_runtime: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    work_available: std.Io.Condition = .init,
    stopping: bool = false,
    workers: []Worker,
    cache: CacheMap,
    next_worker: usize = 0,
    steal_cursor: usize = 0,
    visit_token: usize = 1,

    /// Create a scheduler and start a worker pool. Passing 0 creates one worker.
    pub fn init(allocator: std.mem.Allocator, worker_count: usize) !*Scheduler {
        const actual_worker_count = if (worker_count == 0) 1 else worker_count;

        const self = try allocator.create(Scheduler);
        self.* = .{
            .allocator = allocator,
            .io_runtime = std.Io.Threaded.init(allocator, .{}),
            .workers = undefined,
            .cache = CacheMap.init(allocator),
        };

        self.workers = try allocator.alloc(Worker, actual_worker_count);
        var worker_index: usize = 0;
        while (worker_index < self.workers.len) : (worker_index += 1) {
            self.workers[worker_index] = .{
                .index = worker_index,
                .thread = null,
                .queue = .{},
            };
        }

        var spawned: usize = 0;
        errdefer {
            self.stopWorkers(spawned);
            self.cache.deinit();
            self.io_runtime.deinit();
            allocator.free(self.workers);
            allocator.destroy(self);
        }

        while (spawned < self.workers.len) : (spawned += 1) {
            self.workers[spawned].thread = try std.Thread.spawn(.{}, workerMain, .{ self, spawned });
        }

        return self;
    }

    /// Stop workers, join them, and free scheduler-owned cache storage.
    ///
    /// Callers should not call `deinit` concurrently with `get`/`schedule`.
    pub fn deinit(self: *Scheduler) void {
        self.stopWorkers(self.workers.len);

        var values = self.cache.valueIterator();
        while (values.next()) |entry_ptr| {
            self.destroyEntry(entry_ptr.*);
        }
        self.cache.deinit();
        self.io_runtime.deinit();

        const allocator = self.allocator;
        allocator.free(self.workers);
        allocator.destroy(self);
    }

    /// Synchronously compute or fetch a query result.
    pub fn get(self: *Scheduler, comptime Q: type, input: Q.Input) anyerror!Q.Output {
        const handle = try self.schedule(Q, input);
        return handle.wait();
    }

    /// Schedule a root query and return a typed handle. This is useful when a
    /// non-query caller wants to start several independent roots before waiting.
    pub fn schedule(self: *Scheduler, comptime Q: type, input: Q.Input) anyerror!QueryHandle(Q) {
        validateQuery(Q);
        return self.scheduleInternal(Q, input, null);
    }

    fn scheduleInternal(
        self: *Scheduler,
        comptime Q: type,
        input: Q.Input,
        waiter: ?*Context,
    ) anyerror!QueryHandle(Q) {
        const input_copy = input;
        const input_hash = inputHash(Q, input_copy);
        const lookup_key: CacheKey = .{
            .query_name = @typeName(Q),
            .input_hash = input_hash,
            .input_ptr = &input_copy,
            .eql_fn = inputEqlFn(Q),
        };
        const parent = if (waiter) |ctx| ctx.current else null;

        self.lock();
        defer self.unlock();

        if (self.stopping) return error.SchedulerStopped;

        if (self.cache.get(lookup_key)) |existing| {
            try self.addDependencyLocked(parent, existing);
            return .{
                .scheduler = self,
                .entry = existing,
                .waiter = waiter,
            };
        }

        const entry = try self.createEntryLocked(Q, input_copy, input_hash);
        errdefer {
            _ = self.cache.remove(entry.key);
            self.destroyEntry(entry);
        }

        try self.addDependencyLocked(parent, entry);
        self.enqueueLocked(entry);
        self.signalWork();

        return .{
            .scheduler = self,
            .entry = entry,
            .waiter = waiter,
        };
    }

    fn waitFor(self: *Scheduler, comptime Q: type, entry: *Entry, waiter: ?*Context) anyerror!Q.Output {
        const preferred_worker = if (waiter) |ctx| ctx.worker_index else null;

        while (true) {
            self.lock();

            switch (entry.state) {
                .complete => {
                    const output_ptr: *const Q.Output = @ptrCast(@alignCast(entry.output_ptr.?));
                    const output = output_ptr.*;
                    self.unlock();
                    return output;
                },
                .failed => {
                    const err = entry.err orelse error.InternalSchedulerState;
                    self.unlock();
                    return err;
                },
                .queued, .running => {},
            }

            if (self.stopping) {
                self.unlock();
                return error.SchedulerStopped;
            }

            if (self.takeWorkLocked(preferred_worker)) |work| {
                self.unlock();
                self.runEntry(work, preferred_worker);
                continue;
            }

            self.waitWork();
            self.unlock();
        }
    }

    fn createEntryLocked(
        self: *Scheduler,
        comptime Q: type,
        input: Q.Input,
        input_hash: u64,
    ) !*Entry {
        const input_box = try self.allocator.create(Q.Input);
        errdefer self.allocator.destroy(input_box);
        input_box.* = input;

        const key: CacheKey = .{
            .query_name = @typeName(Q),
            .input_hash = input_hash,
            .input_ptr = input_box,
            .eql_fn = inputEqlFn(Q),
        };

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .key = key,
            .input_ptr = input_box,
            .output_ptr = null,
            .err = null,
            .state = .queued,
            .compute_fn = computeFn(Q),
            .destroy_input_fn = destroyValueFn(Q.Input),
            .destroy_output_fn = destroyValueFn(Q.Output),
            .deps_head = null,
            .queue_prev = null,
            .queue_next = null,
            .visit_token = 0,
        };

        try self.cache.put(key, entry);
        return entry;
    }

    fn enqueueLocked(self: *Scheduler, entry: *Entry) void {
        const index = self.next_worker % self.workers.len;
        self.next_worker = (index + 1) % self.workers.len;
        self.workers[index].queue.pushBack(entry);
    }

    fn takeWorkLocked(self: *Scheduler, preferred_worker: ?usize) ?*Entry {
        if (preferred_worker) |index| {
            if (self.workers[index].queue.popBack()) |entry| {
                std.debug.assert(entry.state == .queued);
                entry.state = .running;
                return entry;
            }
        }

        const worker_count = self.workers.len;
        var offset: usize = 0;
        const start = if (preferred_worker) |index| (index + 1) % worker_count else self.steal_cursor % worker_count;
        while (offset < worker_count) : (offset += 1) {
            const index = (start + offset) % worker_count;
            if (preferred_worker != null and index == preferred_worker.?) continue;

            if (self.workers[index].queue.popFront()) |entry| {
                std.debug.assert(entry.state == .queued);
                entry.state = .running;
                self.steal_cursor = (index + 1) % worker_count;
                return entry;
            }
        }

        return null;
    }

    fn runEntry(self: *Scheduler, entry: *Entry, worker_index: ?usize) void {
        const output = entry.compute_fn(self, entry, worker_index) catch |err| {
            self.finishEntryError(entry, err);
            return;
        };
        self.finishEntrySuccess(entry, output);
    }

    fn finishEntrySuccess(self: *Scheduler, entry: *Entry, output: *anyopaque) void {
        self.lock();
        entry.output_ptr = output;
        entry.err = null;
        entry.state = .complete;
        self.broadcastWork();
        self.unlock();
    }

    fn finishEntryError(self: *Scheduler, entry: *Entry, err: anyerror) void {
        self.lock();
        entry.output_ptr = null;
        entry.err = err;
        entry.state = .failed;
        self.broadcastWork();
        self.unlock();
    }

    fn addDependencyLocked(self: *Scheduler, parent: ?*Entry, child: *Entry) anyerror!void {
        const parent_entry = parent orelse return;
        if (parent_entry == child) return error.DependencyCycle;
        if (child.state == .complete or child.state == .failed) return;
        if (self.reachesLocked(child, parent_entry)) return error.DependencyCycle;

        var existing = parent_entry.deps_head;
        while (existing) |node| : (existing = node.next) {
            if (node.entry == child) return;
        }

        const node = try self.allocator.create(DepNode);
        node.* = .{
            .entry = child,
            .next = parent_entry.deps_head,
        };
        parent_entry.deps_head = node;
    }

    fn reachesLocked(self: *Scheduler, start: *Entry, target: *Entry) bool {
        self.visit_token +%= 1;
        if (self.visit_token == 0) self.visit_token +%= 1;
        return reachesVisit(start, target, self.visit_token);
    }

    fn stopWorkers(self: *Scheduler, spawned: usize) void {
        self.lock();
        self.stopping = true;
        self.broadcastWork();
        self.unlock();

        var index: usize = 0;
        while (index < spawned) : (index += 1) {
            if (self.workers[index].thread) |thread| {
                thread.join();
                self.workers[index].thread = null;
            }
        }
    }

    fn io(self: *Scheduler) std.Io {
        return self.io_runtime.io();
    }

    fn lock(self: *Scheduler) void {
        self.mutex.lockUncancelable(self.io());
    }

    fn unlock(self: *Scheduler) void {
        self.mutex.unlock(self.io());
    }

    fn waitWork(self: *Scheduler) void {
        self.work_available.waitUncancelable(self.io(), &self.mutex);
    }

    fn signalWork(self: *Scheduler) void {
        self.work_available.signal(self.io());
    }

    fn broadcastWork(self: *Scheduler) void {
        self.work_available.broadcast(self.io());
    }

    fn destroyEntry(self: *Scheduler, entry: *Entry) void {
        var dep = entry.deps_head;
        while (dep) |node| {
            const next = node.next;
            self.allocator.destroy(node);
            dep = next;
        }

        entry.destroy_input_fn(self.allocator, entry.input_ptr);
        if (entry.output_ptr) |output_ptr| {
            entry.destroy_output_fn(self.allocator, output_ptr);
        }
        self.allocator.destroy(entry);
    }
};

/// Context handed to a running query. Dependencies are discovered dynamically by
/// calling `schedule` or `get`.
pub const Context = struct {
    scheduler: *Scheduler,
    current: *Entry,
    worker_index: ?usize,

    /// Schedule a dependency now and receive a typed handle to its eventual
    /// result. Schedule several dependencies first to make parallel execution
    /// possible, then wait on the returned handles.
    pub fn schedule(self: *Context, comptime Q: type, input: Q.Input) anyerror!QueryHandle(Q) {
        validateQuery(Q);
        return self.scheduler.scheduleInternal(Q, input, self);
    }

    /// Convenience operation for schedule-and-immediately-wait.
    pub fn get(self: *Context, comptime Q: type, input: Q.Input) anyerror!Q.Output {
        const handle = try self.schedule(Q, input);
        return handle.wait();
    }
};

pub fn QueryHandle(comptime Q: type) type {
    validateQuery(Q);

    return struct {
        scheduler: *Scheduler,
        entry: *Entry,
        waiter: ?*Context,

        pub fn wait(self: @This()) anyerror!Q.Output {
            return self.scheduler.waitFor(Q, self.entry, self.waiter);
        }
    };
}

const CacheMap = std.HashMap(CacheKey, *Entry, CacheKeyContext, 80);

const CacheKey = struct {
    query_name: []const u8,
    input_hash: u64,
    input_ptr: *const anyopaque,
    eql_fn: *const fn (*const anyopaque, *const anyopaque) bool,
};

const CacheKeyContext = struct {
    pub fn hash(_: CacheKeyContext, key: CacheKey) u64 {
        var hasher = std.hash.Wyhash.init(0x5eed_5eed_5eed_5eed);
        hasher.update(key.query_name);
        std.hash.autoHash(&hasher, key.input_hash);
        return hasher.final();
    }

    pub fn eql(_: CacheKeyContext, a: CacheKey, b: CacheKey) bool {
        if (a.input_hash != b.input_hash) return false;
        if (!std.mem.eql(u8, a.query_name, b.query_name)) return false;
        return a.eql_fn(a.input_ptr, b.input_ptr);
    }
};

const EntryState = enum {
    queued,
    running,
    complete,
    failed,
};

const ComputeFn = *const fn (*Scheduler, *Entry, ?usize) anyerror!*anyopaque;
const DestroyValueFn = *const fn (std.mem.Allocator, *anyopaque) void;

const Entry = struct {
    key: CacheKey,
    input_ptr: *anyopaque,
    output_ptr: ?*anyopaque,
    err: ?anyerror,
    state: EntryState,
    compute_fn: ComputeFn,
    destroy_input_fn: DestroyValueFn,
    destroy_output_fn: DestroyValueFn,
    deps_head: ?*DepNode,
    queue_prev: ?*Entry,
    queue_next: ?*Entry,
    visit_token: usize,
};

const DepNode = struct {
    entry: *Entry,
    next: ?*DepNode,
};

const Worker = struct {
    index: usize,
    thread: ?std.Thread,
    queue: WorkQueue,
};

const WorkQueue = struct {
    head: ?*Entry = null,
    tail: ?*Entry = null,
    len: usize = 0,

    fn pushBack(self: *WorkQueue, entry: *Entry) void {
        std.debug.assert(entry.queue_prev == null);
        std.debug.assert(entry.queue_next == null);

        entry.queue_prev = self.tail;
        entry.queue_next = null;

        if (self.tail) |tail| {
            tail.queue_next = entry;
        } else {
            self.head = entry;
        }

        self.tail = entry;
        self.len += 1;
    }

    fn popBack(self: *WorkQueue) ?*Entry {
        const entry = self.tail orelse return null;
        self.tail = entry.queue_prev;
        if (self.tail) |tail| {
            tail.queue_next = null;
        } else {
            self.head = null;
        }
        entry.queue_prev = null;
        entry.queue_next = null;
        self.len -= 1;
        return entry;
    }

    fn popFront(self: *WorkQueue) ?*Entry {
        const entry = self.head orelse return null;
        self.head = entry.queue_next;
        if (self.head) |head| {
            head.queue_prev = null;
        } else {
            self.tail = null;
        }
        entry.queue_prev = null;
        entry.queue_next = null;
        self.len -= 1;
        return entry;
    }
};

fn workerMain(scheduler: *Scheduler, worker_index: usize) void {
    while (true) {
        scheduler.lock();
        while (true) {
            if (scheduler.stopping) {
                scheduler.unlock();
                return;
            }

            if (scheduler.takeWorkLocked(worker_index)) |entry| {
                scheduler.unlock();
                scheduler.runEntry(entry, worker_index);
                break;
            }

            scheduler.waitWork();
        }
    }
}

fn reachesVisit(entry: *Entry, target: *Entry, token: usize) bool {
    if (entry == target) return true;
    if (entry.state == .complete or entry.state == .failed) return false;
    if (entry.visit_token == token) return false;
    entry.visit_token = token;

    var dep = entry.deps_head;
    while (dep) |node| : (dep = node.next) {
        if (reachesVisit(node.entry, target, token)) return true;
    }

    return false;
}

fn validateQuery(comptime Q: type) void {
    comptime {
        if (!@hasDecl(Q, "Input")) @compileError(@typeName(Q) ++ " must define pub const Input");
        if (!@hasDecl(Q, "Output")) @compileError(@typeName(Q) ++ " must define pub const Output");
        if (!@hasDecl(Q, "compute")) @compileError(@typeName(Q) ++ " must define pub fn compute(ctx: *Context, input: Input) anyerror!Output");
    }
}

fn inputHash(comptime Q: type, input: Q.Input) u64 {
    if (@hasDecl(Q, "hash")) return Q.hash(input);

    var hasher = std.hash.Wyhash.init(0x7175_6572_79);
    std.hash.autoHash(&hasher, input);
    return hasher.final();
}

fn inputEqlFn(comptime Q: type) *const fn (*const anyopaque, *const anyopaque) bool {
    return struct {
        fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
            const a: *const Q.Input = @ptrCast(@alignCast(a_opaque));
            const b: *const Q.Input = @ptrCast(@alignCast(b_opaque));

            if (@hasDecl(Q, "eql")) return Q.eql(a.*, b.*);
            return std.meta.eql(a.*, b.*);
        }
    }.eql;
}

fn computeFn(comptime Q: type) ComputeFn {
    return struct {
        fn compute(scheduler: *Scheduler, entry: *Entry, worker_index: ?usize) anyerror!*anyopaque {
            const input: *const Q.Input = @ptrCast(@alignCast(entry.input_ptr));
            var ctx: Context = .{
                .scheduler = scheduler,
                .current = entry,
                .worker_index = worker_index,
            };

            const output = try Q.compute(&ctx, input.*);
            const output_box = try scheduler.allocator.create(Q.Output);
            output_box.* = output;
            return output_box;
        }
    }.compute;
}

fn destroyValueFn(comptime T: type) DestroyValueFn {
    return struct {
        fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const typed: *T = @ptrCast(@alignCast(ptr));
            allocator.destroy(typed);
        }
    }.destroy;
}

const SquareQuery = struct {
    pub const Input = i32;
    pub const Output = i32;

    pub fn compute(ctx: *Context, input: Input) anyerror!Output {
        _ = ctx;
        return input * input;
    }
};

const Pair = struct {
    a: i32,
    b: i32,
};

const SumSquaresQuery = struct {
    pub const Input = Pair;
    pub const Output = i32;

    pub fn compute(ctx: *Context, input: Input) anyerror!Output {
        const a = try ctx.schedule(SquareQuery, input.a);
        const b = try ctx.schedule(SquareQuery, input.b);
        return (try a.wait()) + (try b.wait());
    }
};

const CycleA = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn compute(ctx: *Context, input: Input) anyerror!Output {
        return ctx.get(CycleB, input);
    }
};

const CycleB = struct {
    pub const Input = u32;
    pub const Output = u32;

    pub fn compute(ctx: *Context, input: Input) anyerror!Output {
        return ctx.get(CycleA, input);
    }
};

const BytesInput = struct {
    bytes: []const u8,
    marker: usize,
};

const BytesQuery = struct {
    pub const Input = BytesInput;
    pub const Output = usize;

    pub fn hash(input: Input) u64 {
        return std.hash.Wyhash.hash(0, input.bytes);
    }

    pub fn eql(a: Input, b: Input) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }

    pub fn compute(ctx: *Context, input: Input) anyerror!Output {
        _ = ctx;
        return input.marker;
    }
};

test "dependencies can be scheduled before waiting" {
    const scheduler = try Scheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    try std.testing.expectEqual(@as(i32, 25), try scheduler.get(SumSquaresQuery, .{ .a = 3, .b = 4 }));
}

test "custom input equality controls memoization" {
    const scheduler = try Scheduler.init(std.testing.allocator, 2);
    defer scheduler.deinit();

    const first = try scheduler.get(BytesQuery, .{ .bytes = "same", .marker = 10 });
    const second_bytes = [_]u8{ 's', 'a', 'm', 'e' };
    const second = try scheduler.get(BytesQuery, .{ .bytes = second_bytes[0..], .marker = 99 });

    try std.testing.expectEqual(@as(usize, 10), first);
    try std.testing.expectEqual(@as(usize, 10), second);
}

test "dependency cycles return an error" {
    const scheduler = try Scheduler.init(std.testing.allocator, 2);
    defer scheduler.deinit();

    try std.testing.expectError(error.DependencyCycle, scheduler.get(CycleA, 1));
}
