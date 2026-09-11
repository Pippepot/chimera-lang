const std = @import("std");

const Revision = u64;

pub const QueryError = error{
    DuplicateInput,
    InputNotFound,
    InputUpdateDuringQuery,
    QueryCycle,
    SchedulerStopped,
    InternalSchedulerState,
    InternIdOverflow,
    InvalidInternId,
};

pub const Options = struct {
    worker_count: usize = 0,
};

const EntryState = enum {
    queued,
    running,
    complete,
    failed,
};

const EntryResult = union(enum) {
    verified,
    success: *anyopaque,
    failure: anyerror,
};

const Computation = struct {
    deps: std.ArrayList(*Entry) = .empty,
    input_deps: std.ArrayList(*InputEntry) = .empty,
    accums: ?*AccumBucket = null,
};

pub const Context = struct {
    db: *Database,
    current: *Entry,
    worker_index: ?usize,

    pub fn input(ctx: *Context, comptime I: type, key: I.Key) anyerror!*const I.Value {
        validateInput(I);
        return ctx.db.getInput(I, key, ctx.current);
    }

    pub fn get(ctx: *Context, comptime Q: type, input_value: Q.Input) anyerror!*const Q.Output {
        const handle = try ctx.spawn(Q, input_value);
        return handle.wait();
    }

    pub fn spawn(ctx: *Context, comptime Q: type, input_value: Q.Input) anyerror!Handle(Q) {
        return ctx.db.scheduleInternal(Q, input_value, ctx);
    }

    pub fn emit(ctx: *Context, comptime A: type, value: A) anyerror!void {
        try ctx.db.emit(ctx.current, A, value);
    }

    pub fn allocator(ctx: *Context) std.mem.Allocator {
        return ctx.db.allocator;
    }

    pub fn intern(ctx: *Context, comptime I: type, value: I.Value) anyerror!I.Id {
        return ctx.db.intern(I, value);
    }

    pub fn lookupInterned(ctx: *Context, comptime I: type, id: I.Id) QueryError!*const I.Value {
        return ctx.db.lookupInterned(I, id);
    }

    pub fn lookupInternedAs(ctx: *Context, comptime I: type, id: I.Id) QueryError!?*const I.Value {
        return ctx.db.lookupInternedAs(I, id);
    }
};

pub fn Handle(comptime Q: type) type {
    return struct {
        db: *Database,
        entry: *Entry,
        waiter: ?*Context,

        pub fn wait(handle: @This()) anyerror!*const Q.Output {
            return handle.db.waitFor(Q, handle.entry, handle.waiter);
        }
    };
}

pub const Database = struct {
    allocator: std.mem.Allocator,
    revision: Revision = 0,
    io_runtime: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    work_available: std.Io.Condition = .init,
    stopping: bool = false,
    workers: []Worker,
    entries: EntryMap,
    inputs: InputMap,
    interns: InternMap,
    interned_values: std.ArrayList(InternEntry),
    next_worker: usize = 0,
    steal_cursor: usize = 0,
    visit_token: usize = 1,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Database {
        const requested_workers = if (options.worker_count == 0)
            std.Thread.getCpuCount() catch 1
        else
            options.worker_count;
        const worker_count = @max(requested_workers, 1);

        const db = try allocator.create(Database);
        errdefer allocator.destroy(db);
        db.* = .{
            .allocator = allocator,
            .io_runtime = std.Io.Threaded.init(allocator, .{}),
            .workers = undefined,
            .entries = EntryMap.init(allocator),
            .inputs = InputMap.init(allocator),
            .interns = InternMap.init(allocator),
            .interned_values = .empty,
        };
        errdefer {
            db.entries.deinit();
            db.inputs.deinit();
            db.interns.deinit();
            db.interned_values.deinit(allocator);
            db.io_runtime.deinit();
        }

        db.workers = try allocator.alloc(Worker, worker_count);
        errdefer allocator.free(db.workers);
        for (db.workers) |*worker| {
            worker.* = .{
                .thread = null,
                .queue = .{},
            };
        }

        var spawned: usize = 0;
        errdefer db.stopWorkers(spawned);

        while (spawned < db.workers.len) : (spawned += 1) {
            db.workers[spawned].thread = try std.Thread.spawn(.{}, workerMain, .{ db, spawned });
        }

        return db;
    }

    pub fn deinit(db: *Database) void {
        db.stopWorkers(db.workers.len);
        db.destroyEntries();
        db.destroyInputs();
        db.destroyInternedValues();
        db.entries.deinit();
        db.inputs.deinit();
        db.interns.deinit();
        db.interned_values.deinit(db.allocator);
        db.io_runtime.deinit();

        const allocator = db.allocator;
        allocator.free(db.workers);
        allocator.destroy(db);
    }

    pub fn addInput(db: *Database, comptime I: type, key: I.Key, value: I.Value) anyerror!void {
        validateInput(I);

        const key_copy = key;
        const key_hash = inputKeyHash(I, key_copy);
        const lookup_key = inputCacheKey(I, &key_copy, key_hash);

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;
        if (!db.isIdleLocked()) return error.InputUpdateDuringQuery;
        if (db.inputs.contains(lookup_key)) return error.DuplicateInput;

        const key_box = try db.allocator.create(I.Key);
        errdefer db.allocator.destroy(key_box);
        key_box.* = key_copy;

        const value_box = try db.allocator.create(I.Value);
        errdefer db.allocator.destroy(value_box);
        value_box.* = try cloneInputValue(I, db.allocator, value);
        errdefer deinitInputValue(I, db.allocator, value_box);

        const cache_key = inputCacheKey(I, key_box, key_hash);

        const entry = try db.allocator.create(InputEntry);
        errdefer db.allocator.destroy(entry);
        entry.* = .{
            .key_ptr = @ptrCast(key_box),
            .value_ptr = @ptrCast(value_box),
            .changed_at = db.revision,
            .destroy_key_fn = destroyInputKeyFn(I),
            .destroy_value_fn = destroyInputValueFn(I),
        };

        try db.inputs.put(cache_key, entry);
    }

    pub fn setInput(db: *Database, comptime I: type, key: I.Key, value: I.Value) anyerror!void {
        validateInput(I);

        const key_copy = key;
        const lookup_key = inputCacheKey(I, &key_copy, inputKeyHash(I, key_copy));

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;
        if (!db.isIdleLocked()) return error.InputUpdateDuringQuery;

        const input_entry = db.inputs.get(lookup_key) orelse return error.InputNotFound;
        const old_value: *I.Value = @ptrCast(@alignCast(input_entry.value_ptr));
        if (inputValueEql(I, old_value.*, value)) return;

        const replacement = try cloneInputValue(I, db.allocator, value);
        deinitInputValue(I, db.allocator, old_value);
        old_value.* = replacement;
        db.revision += 1;
        input_entry.changed_at = db.revision;
    }

    pub fn get(db: *Database, comptime Q: type, input_value: Q.Input) anyerror!*const Q.Output {
        const handle = try db.spawn(Q, input_value);
        return handle.wait();
    }

    pub fn spawn(db: *Database, comptime Q: type, input_value: Q.Input) anyerror!Handle(Q) {
        return db.scheduleInternal(Q, input_value, null);
    }

    pub fn intern(db: *Database, comptime I: type, value: I.Value) anyerror!I.Id {
        validateInterner(I);
        const value_hash = I.hash(value);
        const lookup_key = internCacheKey(I, &value, value_hash);

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;
        if (db.interns.get(lookup_key)) |index| return internId(I, index);
        if (db.interned_values.items.len > std.math.maxInt(@typeInfo(I.Id).@"enum".tag_type)) return error.InternIdOverflow;

        try db.interns.ensureUnusedCapacity(1);
        try db.interned_values.ensureUnusedCapacity(db.allocator, 1);

        const value_box = try db.allocator.create(I.Value);
        errdefer db.allocator.destroy(value_box);
        value_box.* = try I.clone(db.allocator, value);
        errdefer I.deinit(db.allocator, value_box);

        const index: u32 = @intCast(db.interned_values.items.len);
        db.interned_values.appendAssumeCapacity(.{
            .type_name = @typeName(I),
            .value_ptr = @ptrCast(value_box),
            .destroy_value_fn = destroyInternedValueFn(I),
        });
        db.interns.putAssumeCapacityNoClobber(internCacheKey(I, value_box, value_hash), index);
        return internId(I, index);
    }

    pub fn lookupInterned(db: *Database, comptime I: type, id: I.Id) QueryError!*const I.Value {
        return (try db.lookupInternedAs(I, id)) orelse error.InvalidInternId;
    }

    /// Returns null when the global ID is valid but belongs to another
    /// interner. An out-of-range ID still returns InvalidInternId.
    pub fn lookupInternedAs(db: *Database, comptime I: type, id: I.Id) QueryError!?*const I.Value {
        validateInterner(I);
        const index: usize = @intFromEnum(id);

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;
        if (index >= db.interned_values.items.len) return error.InvalidInternId;
        const entry = db.interned_values.items[index];
        if (!std.mem.eql(u8, entry.type_name, @typeName(I))) return null;
        return @ptrCast(@alignCast(entry.value_ptr));
    }

    pub fn directAccumulatorValues(db: *Database, comptime Q: type, input_value: Q.Input, comptime A: type) anyerror![]const A {
        const entry = try db.completedEntry(Q, input_value);
        return directAccumulatorValuesEntry(entry, A);
    }

    pub fn transitiveAccumulatorValues(
        db: *Database,
        comptime Q: type,
        input_value: Q.Input,
        comptime A: type,
        gpa: std.mem.Allocator,
    ) anyerror![]A {
        const entry = try db.completedEntry(Q, input_value);

        var out: std.ArrayList(A) = .empty;
        errdefer {
            for (out.items) |*item| deinitTypedValue(A, gpa, item);
            out.deinit(gpa);
        }

        var seen = std.AutoHashMap(*Entry, void).init(gpa);
        defer seen.deinit();

        try db.appendAccumulatorValuesRecursive(entry, A, &out, &seen, gpa);
        return out.toOwnedSlice(gpa);
    }

    fn completedEntry(db: *Database, comptime Q: type, input_value: Q.Input) anyerror!*Entry {
        const handle = try db.spawn(Q, input_value);
        _ = try handle.wait();
        return handle.entry;
    }

    fn scheduleInternal(db: *Database, comptime Q: type, input_value: Q.Input, waiter: ?*Context) anyerror!Handle(Q) {
        validateQuery(Q);

        const input_copy = input_value;
        const input_hash = queryInputHash(Q, input_copy);
        const lookup_key = queryCacheKey(Q, &input_copy, input_hash);
        const parent = if (waiter) |ctx| ctx.current else null;

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;

        if (db.entries.get(lookup_key)) |existing| {
            db.enqueueForCurrentRevisionLocked(existing);
            try db.addDependencyLocked(parent, existing);
            return .{
                .db = db,
                .entry = existing,
                .waiter = waiter,
            };
        }

        const entry = try db.insertEntryLocked(Q, input_copy, input_hash);
        errdefer {
            _ = db.entries.remove(lookup_key);
            db.destroyEntry(entry);
        }

        try db.addDependencyLocked(parent, entry);
        db.enqueueLocked(entry);
        db.signalWork();

        return .{
            .db = db,
            .entry = entry,
            .waiter = waiter,
        };
    }

    fn getInput(db: *Database, comptime I: type, key: I.Key, parent: *Entry) anyerror!*const I.Value {
        const key_copy = key;
        const lookup_key = inputCacheKey(I, &key_copy, inputKeyHash(I, key_copy));

        db.lock();
        defer db.unlock();

        const entry = db.inputs.get(lookup_key) orelse return error.InputNotFound;
        try db.addInputDependencyLocked(parent, entry);
        const value: *const I.Value = @ptrCast(@alignCast(entry.value_ptr));
        return value;
    }

    fn insertEntryLocked(db: *Database, comptime Q: type, input_value: Q.Input, input_hash: u64) !*Entry {
        const input_box = try db.allocator.create(Q.Input);
        errdefer db.allocator.destroy(input_box);
        input_box.* = input_value;
        errdefer deinitTypedValue(Q.Input, db.allocator, input_box);

        const key = queryCacheKey(Q, input_box, input_hash);

        const entry = try db.allocator.create(Entry);
        errdefer db.allocator.destroy(entry);

        entry.* = .{
            .input_ptr = @ptrCast(input_box),
            .output_ptr = null,
            .err = null,
            .state = .queued,
            .verified_at = db.revision,
            .changed_at = db.revision,
            .compute_fn = computeFn(Q),
            .destroy_input_fn = destroyBoxFn(Q.Input),
            .destroy_output_fn = destroyBoxFn(Q.Output),
            .output_eql_fn = outputEqlFn(Q),
            .deps = .empty,
            .input_deps = .empty,
            .accums = null,
            .computation = null,
            .queue_prev = null,
            .queue_next = null,
            .visit_token = 0,
        };

        try db.entries.put(key, entry);
        return entry;
    }

    fn waitFor(db: *Database, comptime Q: type, entry: *Entry, waiter: ?*Context) anyerror!*const Q.Output {
        try db.waitForEntry(entry, if (waiter) |ctx| ctx.worker_index else null);
        // Output payloads are boxed, so an absent value such as a failed
        // parse's `?Ast = null` still has a non-null box pointer here.
        return @ptrCast(@alignCast(entry.output_ptr.?));
    }

    fn waitForEntry(db: *Database, entry: *Entry, preferred_worker: ?usize) anyerror!void {
        while (true) {
            db.lock();

            switch (entry.state) {
                .complete => {
                    std.debug.assert(entry.verified_at == db.revision);
                    db.unlock();
                    return;
                },
                .failed => {
                    const err = entry.err orelse error.InternalSchedulerState;
                    db.unlock();
                    return err;
                },
                .queued, .running => {},
            }

            if (db.stopping) {
                db.unlock();
                return error.SchedulerStopped;
            }

            if (db.takeEntryLocked(entry)) |work| {
                db.unlock();
                db.runEntry(work, preferred_worker);
                continue;
            }

            db.waitWork();
            db.unlock();
        }
    }

    fn runEntry(db: *Database, entry: *Entry, worker_index: ?usize) void {
        if (entry.output_ptr != null and entry.verified_at != db.revision) {
            const changed = db.dependenciesChanged(entry, worker_index) catch |err| {
                db.finishEntry(entry, .{ .failure = err });
                return;
            };
            if (!changed) {
                db.finishEntry(entry, .verified);
                return;
            }
        }

        db.lock();
        std.debug.assert(entry.computation == null);
        entry.computation = .{};
        db.unlock();

        const output = entry.compute_fn(db, entry, worker_index) catch |err| {
            db.finishEntry(entry, .{ .failure = err });
            return;
        };
        db.finishEntry(entry, .{ .success = output });
    }

    fn finishEntry(db: *Database, entry: *Entry, result: EntryResult) void {
        db.lock();
        switch (result) {
            .verified => entry.verified_at = db.revision,
            .success => |output| {
                db.commitComputationLocked(entry, output);
            },
            .failure => |err| {
                // Infrastructure failure: discard the fresh computation but
                // keep the last completed memo. A later demand revalidates the
                // recorded dependencies and can restore `.complete` without
                // rerunning `Q.run`, so transient failures stay retryable.
                if (entry.computation) |*computation| db.deinitComputation(computation);
                entry.computation = null;
                entry.err = err;
                entry.state = .failed;
            },
        }
        if (result != .failure) {
            entry.err = null;
            entry.state = .complete;
        }
        db.broadcastWork();
        db.unlock();
    }

    fn dependenciesChanged(db: *Database, entry: *Entry, worker_index: ?usize) anyerror!bool {
        const verified_at = entry.verified_at;
        for (entry.input_deps.items) |input| {
            if (input.changed_at > verified_at) return true;
        }
        for (entry.deps.items) |dep| {
            try db.verifyDependency(entry, dep, worker_index);
            if (dep.changed_at > verified_at) return true;
        }
        return false;
    }

    fn verifyDependency(db: *Database, entry: *Entry, dep: *Entry, worker_index: ?usize) anyerror!void {
        {
            db.lock();
            defer db.unlock();
            std.debug.assert(entry.verification_dependency == null);
            if (db.reachesLocked(dep, entry)) return error.QueryCycle;
            // Only the dependency currently being verified is an active wait.
            // Other old edges may disappear when this entry recomputes.
            entry.verification_dependency = dep;
            db.enqueueForCurrentRevisionLocked(dep);
        }
        defer {
            db.lock();
            entry.verification_dependency = null;
            db.unlock();
        }
        try db.waitForEntry(dep, worker_index);
    }

    fn enqueueForCurrentRevisionLocked(db: *Database, entry: *Entry) void {
        const needs_work = entry.state == .failed or
            (entry.state == .complete and entry.verified_at != db.revision);
        if (!needs_work) return;
        entry.err = null;
        entry.state = .queued;
        db.enqueueLocked(entry);
        db.signalWork();
    }

    fn commitComputationLocked(db: *Database, entry: *Entry, output: *anyopaque) void {
        const computation = if (entry.computation) |*fresh| fresh else unreachable;
        const observable_equal = entry.output_ptr != null and
            entry.output_eql_fn(entry.output_ptr.?, output) and
            accumBucketsEql(entry.accums, computation.accums);

        if (observable_equal) {
            entry.destroy_output_fn(db.allocator, output);
            db.destroyAccumBuckets(computation.accums);
        } else {
            db.deinitEntryObservable(entry);
            entry.output_ptr = output;
            entry.accums = computation.accums;
            entry.changed_at = db.revision;
        }
        computation.accums = null;

        entry.deps.deinit(db.allocator);
        entry.input_deps.deinit(db.allocator);
        entry.deps = computation.deps;
        entry.input_deps = computation.input_deps;
        computation.deps = .empty;
        computation.input_deps = .empty;
        entry.computation = null;
        entry.verified_at = db.revision;
    }

    fn enqueueLocked(db: *Database, entry: *Entry) void {
        const index = db.next_worker % db.workers.len;
        db.next_worker = (index + 1) % db.workers.len;
        db.workers[index].queue.pushBack(entry);
    }

    fn takeWorkLocked(db: *Database, preferred_worker: ?usize) ?*Entry {
        if (preferred_worker) |index| {
            if (db.workers[index].queue.popBack()) |entry| {
                std.debug.assert(entry.state == .queued);
                entry.state = .running;
                return entry;
            }
        }

        const worker_count = db.workers.len;
        const start = if (preferred_worker) |index| (index + 1) % worker_count else db.steal_cursor % worker_count;
        var offset: usize = 0;
        while (offset < worker_count) : (offset += 1) {
            const index = (start + offset) % worker_count;
            if (preferred_worker != null and index == preferred_worker.?) continue;
            if (db.workers[index].queue.popFront()) |entry| {
                std.debug.assert(entry.state == .queued);
                entry.state = .running;
                db.steal_cursor = (index + 1) % worker_count;
                return entry;
            }
        }

        return null;
    }

    fn takeEntryLocked(db: *Database, entry: *Entry) ?*Entry {
        if (entry.state != .queued) return null;

        for (db.workers) |*worker| {
            var queued = worker.queue.head;
            while (queued) |candidate| : (queued = candidate.queue_next) {
                if (candidate != entry) continue;
                worker.queue.remove(entry);
                entry.state = .running;
                return entry;
            }
        }

        unreachable;
    }

    fn addDependencyLocked(db: *Database, parent: ?*Entry, child: *Entry) anyerror!void {
        const parent_entry = parent orelse return;
        if (parent_entry == child) return error.QueryCycle;
        if (db.reachesLocked(child, parent_entry)) return error.QueryCycle;

        const deps = &parent_entry.computation.?.deps;
        for (deps.items) |dep| {
            if (dep == child) return;
        }
        try deps.append(db.allocator, child);
    }

    fn addInputDependencyLocked(db: *Database, parent: *Entry, input: *InputEntry) !void {
        const input_deps = &parent.computation.?.input_deps;
        for (input_deps.items) |dep| {
            if (dep == input) return;
        }
        try input_deps.append(db.allocator, input);
    }

    fn isIdleLocked(db: *Database) bool {
        var iter = db.entries.valueIterator();
        while (iter.next()) |entry_ptr| {
            switch (entry_ptr.*.state) {
                .queued, .running => return false,
                .complete, .failed => {},
            }
        }
        return true;
    }

    fn reachesLocked(db: *Database, start: *Entry, target: *Entry) bool {
        db.visit_token = @max(1, db.visit_token +% 1);
        return reachesVisit(db, start, target, db.visit_token);
    }

    fn emit(db: *Database, entry: *Entry, comptime A: type, value: A) !void {
        comptime validateObservableType(A, @typeName(A) ++ " accumulator");
        const computation = &entry.computation.?;
        if (accumulatorList(computation.accums, A)) |list| {
            try appendClonedAccumValue(A, list, db.allocator, value);
            return;
        }

        const list = try db.allocator.create(std.ArrayList(A));
        list.* = .empty;
        errdefer {
            list.deinit(db.allocator);
            db.allocator.destroy(list);
        }

        const new_bucket = try db.allocator.create(AccumBucket);
        errdefer db.allocator.destroy(new_bucket);

        new_bucket.* = .{
            .type_name = @typeName(A),
            .values_ptr = @ptrCast(list),
            .eql_fn = accumListEqlFn(A),
            .destroy_fn = destroyAccumListFn(A),
            .next = computation.accums,
        };

        try appendClonedAccumValue(A, list, db.allocator, value);
        computation.accums = new_bucket;
    }

    fn appendAccumulatorValuesRecursive(
        db: *Database,
        entry: *Entry,
        comptime A: type,
        out: *std.ArrayList(A),
        seen: *std.AutoHashMap(*Entry, void),
        gpa: std.mem.Allocator,
    ) !void {
        if ((try seen.getOrPut(entry)).found_existing) return;

        const direct = directAccumulatorValuesEntry(entry, A);
        for (direct) |item| {
            try appendClonedAccumValue(A, out, gpa, item);
        }

        for (entry.deps.items) |dep| {
            try db.appendAccumulatorValuesRecursive(dep, A, out, seen, gpa);
        }
    }

    fn destroyEntries(db: *Database) void {
        var iter = db.entries.valueIterator();
        while (iter.next()) |entry_ptr| {
            db.destroyEntry(entry_ptr.*);
        }
    }

    fn destroyInputs(db: *Database) void {
        var iter = db.inputs.valueIterator();
        while (iter.next()) |entry_ptr| {
            db.destroyInput(entry_ptr.*);
        }
    }

    fn destroyInternedValues(db: *Database) void {
        for (db.interned_values.items) |entry| entry.destroy_value_fn(db.allocator, entry.value_ptr);
    }

    fn destroyEntry(db: *Database, entry: *Entry) void {
        entry.destroy_input_fn(db.allocator, entry.input_ptr);
        if (entry.computation) |*computation| db.deinitComputation(computation);
        db.deinitEntryObservable(entry);
        entry.deps.deinit(db.allocator);
        entry.input_deps.deinit(db.allocator);
        db.allocator.destroy(entry);
    }

    fn deinitEntryObservable(db: *Database, entry: *Entry) void {
        if (entry.output_ptr) |output_ptr| {
            entry.destroy_output_fn(db.allocator, output_ptr);
            entry.output_ptr = null;
        }

        db.destroyAccumBuckets(entry.accums);
        entry.accums = null;
    }

    fn deinitComputation(db: *Database, computation: *Computation) void {
        computation.deps.deinit(db.allocator);
        computation.input_deps.deinit(db.allocator);
        db.destroyAccumBuckets(computation.accums);
        computation.* = .{};
    }

    fn destroyAccumBuckets(db: *Database, first: ?*AccumBucket) void {
        var bucket = first;
        while (bucket) |current| {
            const next = current.next;
            current.destroy_fn(db.allocator, current.values_ptr);
            db.allocator.destroy(current);
            bucket = next;
        }
    }

    fn destroyInput(db: *Database, entry: *InputEntry) void {
        entry.destroy_key_fn(db.allocator, entry.key_ptr);
        entry.destroy_value_fn(db.allocator, entry.value_ptr);
        db.allocator.destroy(entry);
    }

    fn stopWorkers(db: *Database, spawned: usize) void {
        db.lock();
        db.stopping = true;
        db.broadcastWork();
        db.unlock();

        var index: usize = 0;
        while (index < spawned) : (index += 1) {
            if (db.workers[index].thread) |thread| {
                thread.join();
                db.workers[index].thread = null;
            }
        }
    }

    fn io(db: *Database) std.Io {
        return db.io_runtime.io();
    }

    fn lock(db: *Database) void {
        db.mutex.lockUncancelable(db.io());
    }

    fn unlock(db: *Database) void {
        db.mutex.unlock(db.io());
    }

    fn waitWork(db: *Database) void {
        db.work_available.waitUncancelable(db.io(), &db.mutex);
    }

    fn signalWork(db: *Database) void {
        db.work_available.signal(db.io());
    }

    fn broadcastWork(db: *Database) void {
        db.work_available.broadcast(db.io());
    }
};

const ErasedKey = struct {
    type_name: []const u8,
    hash: u64,
    value_ptr: *const anyopaque,
    eql_fn: *const fn (*const anyopaque, *const anyopaque) bool,
};

const ErasedKeyContext = struct {
    pub fn hash(_: ErasedKeyContext, key: ErasedKey) u64 {
        var hasher = std.hash.Wyhash.init(0x7175_6572_79);
        hasher.update(key.type_name);
        std.hash.autoHash(&hasher, key.hash);
        return hasher.final();
    }

    pub fn eql(_: ErasedKeyContext, a: ErasedKey, b: ErasedKey) bool {
        if (a.hash != b.hash) return false;
        if (!std.mem.eql(u8, a.type_name, b.type_name)) return false;
        return a.eql_fn(a.value_ptr, b.value_ptr);
    }
};

const EntryMap = std.HashMap(ErasedKey, *Entry, ErasedKeyContext, 80);
const InputMap = std.HashMap(ErasedKey, *InputEntry, ErasedKeyContext, 80);
const InternMap = std.HashMap(ErasedKey, u32, ErasedKeyContext, 80);
const ComputeFn = *const fn (*Database, *Entry, ?usize) anyerror!*anyopaque;
const DestroyOpaqueFn = *const fn (std.mem.Allocator, *anyopaque) void;
const EqlOpaqueFn = *const fn (*const anyopaque, *const anyopaque) bool;

const Entry = struct {
    input_ptr: *anyopaque,
    output_ptr: ?*anyopaque,
    err: ?anyerror,
    state: EntryState,
    verified_at: Revision,
    changed_at: Revision,
    compute_fn: ComputeFn,
    destroy_input_fn: DestroyOpaqueFn,
    destroy_output_fn: DestroyOpaqueFn,
    output_eql_fn: EqlOpaqueFn,
    deps: std.ArrayList(*Entry),
    input_deps: std.ArrayList(*InputEntry),
    accums: ?*AccumBucket,
    computation: ?Computation,
    verification_dependency: ?*Entry = null,
    queue_prev: ?*Entry,
    queue_next: ?*Entry,
    visit_token: usize,
};

const InputEntry = struct {
    key_ptr: *anyopaque,
    value_ptr: *anyopaque,
    changed_at: Revision,
    destroy_key_fn: DestroyOpaqueFn,
    destroy_value_fn: DestroyOpaqueFn,
};

const InternEntry = struct {
    type_name: []const u8,
    value_ptr: *anyopaque,
    destroy_value_fn: DestroyOpaqueFn,
};

const AccumBucket = struct {
    type_name: []const u8,
    values_ptr: *anyopaque,
    eql_fn: EqlOpaqueFn,
    destroy_fn: DestroyOpaqueFn,
    next: ?*AccumBucket,
};

const Worker = struct {
    thread: ?std.Thread,
    queue: WorkQueue,
};

const WorkQueue = struct {
    head: ?*Entry = null,
    tail: ?*Entry = null,

    fn pushBack(queue: *WorkQueue, entry: *Entry) void {
        std.debug.assert(entry.queue_prev == null);
        std.debug.assert(entry.queue_next == null);

        entry.queue_prev = queue.tail;
        entry.queue_next = null;

        if (queue.tail) |tail| {
            tail.queue_next = entry;
        } else {
            queue.head = entry;
        }

        queue.tail = entry;
    }

    fn popBack(queue: *WorkQueue) ?*Entry {
        const entry = queue.tail orelse return null;
        queue.remove(entry);
        return entry;
    }

    fn popFront(queue: *WorkQueue) ?*Entry {
        const entry = queue.head orelse return null;
        queue.remove(entry);
        return entry;
    }

    fn remove(queue: *WorkQueue, entry: *Entry) void {
        if (entry.queue_prev) |prev| {
            prev.queue_next = entry.queue_next;
        } else {
            queue.head = entry.queue_next;
        }

        if (entry.queue_next) |next| {
            next.queue_prev = entry.queue_prev;
        } else {
            queue.tail = entry.queue_prev;
        }

        entry.queue_prev = null;
        entry.queue_next = null;
    }
};

fn workerMain(db: *Database, worker_index: usize) void {
    while (true) {
        db.lock();
        while (true) {
            if (db.stopping) {
                db.unlock();
                return;
            }

            if (db.takeWorkLocked(worker_index)) |entry| {
                db.unlock();
                db.runEntry(entry, worker_index);
                break;
            }

            db.waitWork();
        }
    }
}

fn reachesVisit(db: *Database, entry: *Entry, target: *Entry, token: usize) bool {
    if (entry == target) return true;
    if (entry.visit_token == token) return false;
    entry.visit_token = token;

    if (entry.verification_dependency) |dep| {
        if (reachesVisit(db, dep, target, token)) return true;
    }

    const deps = if (entry.computation) |*computation|
        computation.deps.items
    else if (entry.verified_at == db.revision)
        entry.deps.items
    else
        &.{};
    for (deps) |dep| {
        if (reachesVisit(db, dep, target, token)) return true;
    }

    return false;
}

fn directAccumulatorValuesEntry(entry: *Entry, comptime A: type) []const A {
    const list = accumulatorList(entry.accums, A) orelse return &.{};
    return list.items;
}

fn accumulatorList(first: ?*AccumBucket, comptime A: type) ?*std.ArrayList(A) {
    var bucket = first;
    while (bucket) |current| : (bucket = current.next) {
        if (std.mem.eql(u8, current.type_name, @typeName(A))) {
            return @ptrCast(@alignCast(current.values_ptr));
        }
    }
    return null;
}

fn validateQuery(comptime Q: type) void {
    comptime {
        if (!@hasDecl(Q, "Input")) @compileError(@typeName(Q) ++ " must define pub const Input");
        if (!@hasDecl(Q, "Output")) @compileError(@typeName(Q) ++ " must define pub const Output");
        if (!@hasDecl(Q, "run")) @compileError(@typeName(Q) ++ " must define pub fn run(ctx, input: Input) anyerror!Output");
        if (typeContainsPointer(Q.Input)) @compileError(@typeName(Q) ++ ".Input contains pointers; query keys must be small stable identities");
        if (!@hasDecl(Q, "eqlOutput")) validateObservableType(Q.Output, @typeName(Q) ++ ".Output");
    }
}

fn validateObservableType(comptime T: type, comptime label: []const u8) void {
    if (typeHasEql(T)) return;
    if (@typeInfo(T) == .optional) {
        validateObservableType(@typeInfo(T).optional.child, label);
        return;
    }
    if (typeContainsPointer(T)) @compileError(label ++ " contains pointers and must define value equality");
}

fn typeHasEql(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "eql"),
        else => false,
    };
}

fn typeContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |info| typeContainsPointer(info.child),
        .array => |info| typeContainsPointer(info.child),
        .error_union => |info| typeContainsPointer(info.payload),
        .@"struct" => |info| fieldsContainPointer(info.fields),
        .@"union" => |info| fieldsContainPointer(info.fields),
        else => false,
    };
}

fn fieldsContainPointer(comptime fields: anytype) bool {
    for (fields) |field| {
        if (typeContainsPointer(field.type)) return true;
    }
    return false;
}

fn validateInput(comptime I: type) void {
    comptime {
        if (!@hasDecl(I, "Key")) @compileError(@typeName(I) ++ " must define pub const Key");
        if (!@hasDecl(I, "Value")) @compileError(@typeName(I) ++ " must define pub const Value");
        if (typeContainsPointer(I.Key)) @compileError(@typeName(I) ++ ".Key contains pointers; input keys must be small stable identities");
        if (typeContainsPointer(I.Value)) {
            if (!@hasDecl(I, "cloneValue")) @compileError(@typeName(I) ++ " must define cloneValue for its pointer-containing Value");
            if (!@hasDecl(I, "eqlValue")) @compileError(@typeName(I) ++ " must define eqlValue for its pointer-containing Value");
            if (!@hasDecl(I, "deinitValue")) @compileError(@typeName(I) ++ " must define deinitValue for its pointer-containing Value");
        }
    }
}

fn validateInterner(comptime I: type) void {
    comptime {
        if (!@hasDecl(I, "Value")) @compileError(@typeName(I) ++ " must define pub const Value");
        if (!@hasDecl(I, "Id")) @compileError(@typeName(I) ++ " must define pub const Id");
        if (@typeInfo(I.Id) != .@"enum") @compileError(@typeName(I) ++ ".Id must be an enum");
        const tag = @typeInfo(I.Id).@"enum".tag_type;
        const tag_info = @typeInfo(tag).int;
        if (tag_info.signedness != .unsigned or tag_info.bits > 32) @compileError(@typeName(I) ++ ".Id must use an unsigned tag no wider than u32");
        if (!@hasDecl(I, "hash")) @compileError(@typeName(I) ++ " must define hash");
        if (!@hasDecl(I, "eql")) @compileError(@typeName(I) ++ " must define eql");
        if (!@hasDecl(I, "clone")) @compileError(@typeName(I) ++ " must define clone");
        if (!@hasDecl(I, "deinit")) @compileError(@typeName(I) ++ " must define deinit");
    }
}

fn internCacheKey(comptime I: type, value_ptr: *const I.Value, value_hash: u64) ErasedKey {
    return .{
        .type_name = @typeName(I),
        .hash = value_hash,
        .value_ptr = value_ptr,
        .eql_fn = struct {
            fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
                const a: *const I.Value = @ptrCast(@alignCast(a_opaque));
                const b: *const I.Value = @ptrCast(@alignCast(b_opaque));
                return I.eql(a.*, b.*);
            }
        }.eql,
    };
}

fn internId(comptime I: type, index: u32) I.Id {
    return @enumFromInt(@as(@typeInfo(I.Id).@"enum".tag_type, @intCast(index)));
}

fn destroyInternedValueFn(comptime I: type) DestroyOpaqueFn {
    return struct {
        fn destroy(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const value: *I.Value = @ptrCast(@alignCast(ptr));
            I.deinit(gpa, value);
            gpa.destroy(value);
        }
    }.destroy;
}

fn queryCacheKey(comptime Q: type, input_ptr: *const Q.Input, input_hash: u64) ErasedKey {
    return .{
        .type_name = @typeName(Q),
        .hash = input_hash,
        .value_ptr = input_ptr,
        .eql_fn = queryInputEqlFn(Q),
    };
}

fn inputCacheKey(comptime I: type, key_ptr: *const I.Key, key_hash: u64) ErasedKey {
    return .{
        .type_name = @typeName(I),
        .hash = key_hash,
        .value_ptr = key_ptr,
        .eql_fn = inputKeyEqlFn(I),
    };
}

fn queryInputHash(comptime Q: type, input_value: Q.Input) u64 {
    if (@hasDecl(Q, "hash")) return Q.hash(input_value);

    var hasher = std.hash.Wyhash.init(typeHash(Q));
    std.hash.autoHash(&hasher, input_value);
    return hasher.final();
}

fn queryInputEqlFn(comptime Q: type) *const fn (*const anyopaque, *const anyopaque) bool {
    return struct {
        fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
            const a: *const Q.Input = @ptrCast(@alignCast(a_opaque));
            const b: *const Q.Input = @ptrCast(@alignCast(b_opaque));
            if (@hasDecl(Q, "eql")) return Q.eql(a.*, b.*);
            return std.meta.eql(a.*, b.*);
        }
    }.eql;
}

fn inputKeyHash(comptime I: type, key: I.Key) u64 {
    if (@hasDecl(I, "hashKey")) return I.hashKey(key);

    var hasher = std.hash.Wyhash.init(typeHash(I));
    std.hash.autoHash(&hasher, key);
    return hasher.final();
}

fn inputKeyEqlFn(comptime I: type) *const fn (*const anyopaque, *const anyopaque) bool {
    return struct {
        fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
            const a: *const I.Key = @ptrCast(@alignCast(a_opaque));
            const b: *const I.Key = @ptrCast(@alignCast(b_opaque));
            if (@hasDecl(I, "eqlKey")) return I.eqlKey(a.*, b.*);
            return std.meta.eql(a.*, b.*);
        }
    }.eql;
}

fn typeHash(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

fn computeFn(comptime Q: type) ComputeFn {
    return struct {
        fn compute(db: *Database, entry: *Entry, worker_index: ?usize) anyerror!*anyopaque {
            const input_value: *const Q.Input = @ptrCast(@alignCast(entry.input_ptr));
            var ctx: Context = .{
                .db = db,
                .current = entry,
                .worker_index = worker_index,
            };

            var output_value = try Q.run(&ctx, input_value.*);
            errdefer deinitTypedValue(Q.Output, db.allocator, &output_value);

            const output_box = try db.allocator.create(Q.Output);
            output_box.* = output_value;
            return @ptrCast(output_box);
        }
    }.compute;
}

fn outputEqlFn(comptime Q: type) EqlOpaqueFn {
    return struct {
        fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
            const a: *const Q.Output = @ptrCast(@alignCast(a_opaque));
            const b: *const Q.Output = @ptrCast(@alignCast(b_opaque));
            if (@hasDecl(Q, "eqlOutput")) return Q.eqlOutput(a.*, b.*);
            return valueEql(Q.Output, a.*, b.*);
        }
    }.eql;
}

fn valueEql(comptime T: type, a: T, b: T) bool {
    if (comptime typeHasEql(T)) return T.eql(a, b);
    if (comptime @typeInfo(T) == .optional) {
        if (a == null or b == null) return a == null and b == null;
        return valueEql(@typeInfo(T).optional.child, a.?, b.?);
    }
    return std.meta.eql(a, b);
}

fn accumListEqlFn(comptime A: type) EqlOpaqueFn {
    return struct {
        fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
            const a: *const std.ArrayList(A) = @ptrCast(@alignCast(a_opaque));
            const b: *const std.ArrayList(A) = @ptrCast(@alignCast(b_opaque));
            if (a.items.len != b.items.len) return false;
            for (a.items, b.items) |left, right| {
                if (!valueEql(A, left, right)) return false;
            }
            return true;
        }
    }.eql;
}

fn accumBucketsEql(a_first: ?*AccumBucket, b_first: ?*AccumBucket) bool {
    var a_count: usize = 0;
    var a_bucket = a_first;
    while (a_bucket) |a| : (a_bucket = a.next) {
        a_count += 1;
        var matching = b_first;
        while (matching) |b| : (matching = b.next) {
            if (std.mem.eql(u8, a.type_name, b.type_name)) break;
        }
        const b = matching orelse return false;
        if (!a.eql_fn(a.values_ptr, b.values_ptr)) return false;
    }

    var b_count: usize = 0;
    var b_bucket = b_first;
    while (b_bucket) |b| : (b_bucket = b.next) b_count += 1;
    return a_count == b_count;
}

fn cloneInputValue(comptime I: type, gpa: std.mem.Allocator, value: I.Value) !I.Value {
    if (@hasDecl(I, "cloneValue")) return I.cloneValue(gpa, value);
    return value;
}

fn inputValueEql(comptime I: type, a: I.Value, b: I.Value) bool {
    if (@hasDecl(I, "eqlValue")) return I.eqlValue(a, b);
    return std.meta.eql(a, b);
}

fn deinitInputValue(comptime I: type, gpa: std.mem.Allocator, value: *I.Value) void {
    if (@hasDecl(I, "deinitValue")) {
        I.deinitValue(gpa, value);
    } else {
        deinitTypedValue(I.Value, gpa, value);
    }
}

fn destroyInputKeyFn(comptime I: type) DestroyOpaqueFn {
    return struct {
        fn destroy(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const key: *I.Key = @ptrCast(@alignCast(ptr));
            gpa.destroy(key);
        }
    }.destroy;
}

fn destroyInputValueFn(comptime I: type) DestroyOpaqueFn {
    return struct {
        fn destroy(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const value: *I.Value = @ptrCast(@alignCast(ptr));
            deinitInputValue(I, gpa, value);
            gpa.destroy(value);
        }
    }.destroy;
}

fn destroyBoxFn(comptime T: type) DestroyOpaqueFn {
    return struct {
        fn destroy(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const typed: *T = @ptrCast(@alignCast(ptr));
            deinitTypedValue(T, gpa, typed);
            gpa.destroy(typed);
        }
    }.destroy;
}

fn destroyAccumListFn(comptime A: type) DestroyOpaqueFn {
    return struct {
        fn destroy(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const list: *std.ArrayList(A) = @ptrCast(@alignCast(ptr));
            for (list.items) |*item| deinitTypedValue(A, gpa, item);
            list.deinit(gpa);
            gpa.destroy(list);
        }
    }.destroy;
}

fn cloneAccumValue(comptime A: type, gpa: std.mem.Allocator, value: A) !A {
    if (@hasDecl(A, "clone")) return A.clone(gpa, value);
    return value;
}

fn appendClonedAccumValue(comptime A: type, list: *std.ArrayList(A), gpa: std.mem.Allocator, value: A) !void {
    var cloned = try cloneAccumValue(A, gpa, value);
    errdefer deinitTypedValue(A, gpa, &cloned);
    try list.append(gpa, cloned);
}

fn deinitTypedValue(comptime T: type, gpa: std.mem.Allocator, value: *T) void {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (value.*) |*child| {
                deinitTypedValue(optional.child, gpa, child);
            }
        },
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            if (@hasDecl(T, "deinit")) value.deinit(gpa);
        },
        else => {},
    }
}
