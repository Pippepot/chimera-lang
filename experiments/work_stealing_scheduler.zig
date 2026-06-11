const std = @import("std");

/// A self-contained multithreaded scheduler with dependency-aware jobs and
/// mutex-protected work-stealing deques.
///
/// Jobs are ordinary structs with:
///   - `pub const Result = T`
///   - zero or more fields of type `Scheduler.Dep(U)`
///   - `pub fn execute(self: *const @This()) T`
///
/// Dependency fields are filled by the scheduler before `execute` is called.
pub const Scheduler = struct {
    pub const Options = struct {
        threads: usize = 0,
    };

    pub fn Dep(comptime T: type) type {
        return struct {
            pub const scheduler_dependency_type = T;

            future: *Future(T),
            ready: bool = false,
            value: T = undefined,

            pub fn from(future: *Future(T)) @This() {
                return .{ .future = future };
            }

            pub fn get(self: *const @This()) T {
                std.debug.assert(self.ready);
                return self.value;
            }
        };
    }

    pub fn Future(comptime T: type) type {
        return struct {
            io: std.Io,
            header: FutureHeader = .{},
            result: T = undefined,

            pub fn dep(self: *@This()) Dep(T) {
                return Dep(T).from(self);
            }

            pub fn done(self: *@This()) bool {
                self.header.mutex.lockUncancelable(self.io);
                defer self.header.mutex.unlock(self.io);
                return self.header.completed;
            }

            pub fn wait(self: *@This()) T {
                self.header.mutex.lockUncancelable(self.io);
                while (!self.header.completed) {
                    self.header.cond.waitUncancelable(self.io, &self.header.mutex);
                }
                const value = self.result;
                self.header.mutex.unlock(self.io);
                return value;
            }
        };
    }

    allocator: std.mem.Allocator,
    io: std.Io,
    workers: []Worker,

    state_mutex: std.Io.Mutex = .init,
    state_cond: std.Io.Condition = .init,
    unfinished: usize = 0,
    available: usize = 0,
    next_queue: usize = 0,
    stopping: bool = false,

    all_mutex: std.Io.Mutex = .init,
    all_tasks: ?*TaskHeader = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Scheduler {
        const requested_threads = if (options.threads == 0)
            std.Thread.getCpuCount() catch 1
        else
            options.threads;
        const thread_count = @max(requested_threads, 1);

        const scheduler = try allocator.create(Scheduler);
        scheduler.* = .{
            .allocator = allocator,
            .io = io,
            .workers = try allocator.alloc(Worker, thread_count),
        };

        for (scheduler.workers) |*worker| {
            worker.* = .{};
        }

        var started: usize = 0;
        errdefer {
            scheduler.stopWorkers();
            scheduler.joinStarted(started);
            allocator.free(scheduler.workers);
            allocator.destroy(scheduler);
        }

        while (started < scheduler.workers.len) : (started += 1) {
            scheduler.workers[started].thread = try std.Thread.spawn(.{}, workerMain, .{ scheduler, started });
        }

        return scheduler;
    }

    /// Waits until every job submitted so far has completed.
    pub fn finish(self: *Scheduler) void {
        self.state_mutex.lockUncancelable(self.io);
        while (self.unfinished != 0) {
            self.state_cond.waitUncancelable(self.io, &self.state_mutex);
        }
        self.state_mutex.unlock(self.io);
    }

    pub fn deinit(self: *Scheduler) void {
        self.stopWorkers();
        self.joinStarted(self.workers.len);
        self.destroyTasks();

        const allocator = self.allocator;
        allocator.free(self.workers);
        allocator.destroy(self);
    }

    pub fn spawn(self: *Scheduler, job: anytype) !*Future(jobResult(@TypeOf(job))) {
        const Job = @TypeOf(job);
        const Box = TaskBox(Job);
        const dep_count = dependencyCount(Job);

        const waiters = try self.allocator.alloc(Waiter, dep_count);
        errdefer self.allocator.free(waiters);

        const box = try self.allocator.create(Box);
        errdefer self.allocator.destroy(box);

        box.* = .{
            .header = .{
                .scheduler = self,
                .vtable = vtableFor(Job),
                .remaining_dependencies = dep_count,
                .waiters = waiters,
            },
            .job = job,
            .future = .{ .io = self.io },
        };

        self.rememberTask(&box.header);

        self.state_mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.state_mutex.unlock(self.io);
            return error.SchedulerStopped;
        }
        self.unfinished += 1;
        self.state_mutex.unlock(self.io);

        self.bindDependencies(Job, &box.header, &box.job);
        if (dep_count == 0) {
            self.enqueue(&box.header);
        }

        return &box.future;
    }

    fn bindDependencies(self: *Scheduler, comptime Job: type, task: *TaskHeader, job: *Job) void {
        var waiter_index: usize = 0;

        inline for (std.meta.fields(Job)) |field| {
            if (comptime isDependency(field.type)) {
                const T = field.type.scheduler_dependency_type;
                const dep = &@field(job, field.name);
                self.bindDependency(T, task, dep, &task.waiters[waiter_index]);
                waiter_index += 1;
            }
        }
    }

    fn bindDependency(
        self: *Scheduler,
        comptime T: type,
        task: *TaskHeader,
        dep: *Dep(T),
        waiter: *Waiter,
    ) void {
        waiter.* = .{
            .task = task,
            .target = dep,
            .fill = fillDependency(T),
            .next = null,
        };

        const future = dep.future;
        future.header.mutex.lockUncancelable(self.io);
        if (future.header.completed) {
            const value = future.result;
            future.header.mutex.unlock(self.io);
            dep.value = value;
            dep.ready = true;
            self.dependencyBecameReady(task);
            return;
        }

        waiter.next = future.header.waiters;
        future.header.waiters = waiter;
        future.header.mutex.unlock(self.io);
    }

    fn dependencyBecameReady(self: *Scheduler, task: *TaskHeader) void {
        task.mutex.lockUncancelable(self.io);
        std.debug.assert(task.remaining_dependencies > 0);
        task.remaining_dependencies -= 1;
        const ready = task.remaining_dependencies == 0;
        task.mutex.unlock(self.io);

        if (ready) {
            self.enqueue(task);
        }
    }

    fn enqueue(self: *Scheduler, task: *TaskHeader) void {
        self.state_mutex.lockUncancelable(self.io);
        const index = self.next_queue % self.workers.len;
        self.next_queue += 1;
        self.state_mutex.unlock(self.io);

        self.workers[index].queue.pushFront(self.io, task);

        self.state_mutex.lockUncancelable(self.io);
        self.available += 1;
        self.state_cond.signal(self.io);
        self.state_mutex.unlock(self.io);
    }

    fn completeFuture(self: *Scheduler, comptime T: type, future: *Future(T), result: T) void {
        future.header.mutex.lockUncancelable(self.io);
        future.result = result;
        future.header.completed = true;
        const waiters = future.header.waiters;
        future.header.waiters = null;
        future.header.cond.broadcast(self.io);
        future.header.mutex.unlock(self.io);

        var current = waiters;
        while (current) |waiter| {
            const next = waiter.next;
            waiter.fill(waiter.target, &future.result);
            self.dependencyBecameReady(waiter.task);
            current = next;
        }

        self.state_mutex.lockUncancelable(self.io);
        std.debug.assert(self.unfinished > 0);
        self.unfinished -= 1;
        if (self.unfinished == 0) {
            self.state_cond.broadcast(self.io);
        }
        self.state_mutex.unlock(self.io);
    }

    fn takeTask(self: *Scheduler, worker_index: usize) ?*TaskHeader {
        if (self.workers[worker_index].queue.popFront(self.io)) |task| {
            self.markTaskTaken();
            return task;
        }

        var offset: usize = 1;
        while (offset < self.workers.len) : (offset += 1) {
            const victim_index = (worker_index + offset) % self.workers.len;
            if (self.workers[victim_index].queue.popBack(self.io)) |task| {
                self.markTaskTaken();
                return task;
            }
        }

        return null;
    }

    fn markTaskTaken(self: *Scheduler) void {
        self.state_mutex.lockUncancelable(self.io);
        std.debug.assert(self.available > 0);
        self.available -= 1;
        self.state_mutex.unlock(self.io);
    }

    fn stopWorkers(self: *Scheduler) void {
        self.state_mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.state_cond.broadcast(self.io);
        self.state_mutex.unlock(self.io);
    }

    fn joinStarted(self: *Scheduler, count: usize) void {
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (self.workers[index].thread) |thread| {
                thread.join();
                self.workers[index].thread = null;
            }
        }
    }

    fn rememberTask(self: *Scheduler, task: *TaskHeader) void {
        self.all_mutex.lockUncancelable(self.io);
        task.all_next = self.all_tasks;
        self.all_tasks = task;
        self.all_mutex.unlock(self.io);
    }

    fn destroyTasks(self: *Scheduler) void {
        var task = self.all_tasks;
        while (task) |current| {
            const next = current.all_next;
            current.vtable.destroy(current);
            task = next;
        }
        self.all_tasks = null;
    }
};

const Worker = struct {
    queue: WorkDeque = .{},
    thread: ?std.Thread = null,
};

const WorkDeque = struct {
    mutex: std.Io.Mutex = .init,
    head: ?*TaskHeader = null,
    tail: ?*TaskHeader = null,

    fn pushFront(self: *WorkDeque, io: std.Io, task: *TaskHeader) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        task.queue_prev = null;
        task.queue_next = self.head;
        if (self.head) |old_head| {
            old_head.queue_prev = task;
        } else {
            self.tail = task;
        }
        self.head = task;
    }

    fn popFront(self: *WorkDeque, io: std.Io) ?*TaskHeader {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const task = self.head orelse return null;
        self.head = task.queue_next;
        if (self.head) |new_head| {
            new_head.queue_prev = null;
        } else {
            self.tail = null;
        }
        task.queue_next = null;
        task.queue_prev = null;
        return task;
    }

    fn popBack(self: *WorkDeque, io: std.Io) ?*TaskHeader {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const task = self.tail orelse return null;
        self.tail = task.queue_prev;
        if (self.tail) |new_tail| {
            new_tail.queue_next = null;
        } else {
            self.head = null;
        }
        task.queue_next = null;
        task.queue_prev = null;
        return task;
    }
};

const FutureHeader = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    completed: bool = false,
    waiters: ?*Waiter = null,
};

const Waiter = struct {
    task: *TaskHeader,
    target: *anyopaque,
    fill: *const fn (*anyopaque, *const anyopaque) void,
    next: ?*Waiter,
};

const TaskHeader = struct {
    scheduler: *Scheduler,
    vtable: *const TaskVTable,
    mutex: std.Io.Mutex = .init,
    remaining_dependencies: usize = 0,
    waiters: []Waiter = &.{},
    queue_prev: ?*TaskHeader = null,
    queue_next: ?*TaskHeader = null,
    all_next: ?*TaskHeader = null,
};

const TaskVTable = struct {
    run: *const fn (*TaskHeader) void,
    destroy: *const fn (*TaskHeader) void,
};

fn TaskBox(comptime Job: type) type {
    return struct {
        header: TaskHeader,
        job: Job,
        future: Scheduler.Future(jobResult(Job)),
    };
}

fn workerMain(scheduler: *Scheduler, worker_index: usize) void {
    while (true) {
        if (scheduler.takeTask(worker_index)) |task| {
            task.vtable.run(task);
            continue;
        }

        scheduler.state_mutex.lockUncancelable(scheduler.io);
        while (scheduler.available == 0 and !scheduler.stopping) {
            scheduler.state_cond.waitUncancelable(scheduler.io, &scheduler.state_mutex);
        }
        const stopping = scheduler.stopping;
        scheduler.state_mutex.unlock(scheduler.io);

        if (stopping) {
            return;
        }
    }
}

fn vtableFor(comptime Job: type) *const TaskVTable {
    return &struct {
        const table = TaskVTable{
            .run = runTask(Job),
            .destroy = destroyTask(Job),
        };
    }.table;
}

fn runTask(comptime Job: type) *const fn (*TaskHeader) void {
    return struct {
        fn run(header: *TaskHeader) void {
            const Box = TaskBox(Job);
            const box: *Box = @fieldParentPtr("header", header);
            const Result = jobResult(Job);

            if (Result == void) {
                box.job.execute();
                header.scheduler.completeFuture(void, &box.future, {});
            } else {
                const result: Result = box.job.execute();
                header.scheduler.completeFuture(Result, &box.future, result);
            }
        }
    }.run;
}

fn destroyTask(comptime Job: type) *const fn (*TaskHeader) void {
    return struct {
        fn destroy(header: *TaskHeader) void {
            const Box = TaskBox(Job);
            const box: *Box = @fieldParentPtr("header", header);
            const scheduler = header.scheduler;
            scheduler.allocator.free(header.waiters);
            scheduler.allocator.destroy(box);
        }
    }.destroy;
}

fn fillDependency(comptime T: type) *const fn (*anyopaque, *const anyopaque) void {
    return struct {
        fn fill(target: *anyopaque, value_ptr: *const anyopaque) void {
            const dep: *Scheduler.Dep(T) = @ptrCast(@alignCast(target));
            const value: *const T = @ptrCast(@alignCast(value_ptr));
            dep.value = value.*;
            dep.ready = true;
        }
    }.fill;
}

fn jobResult(comptime Job: type) type {
    if (!@hasDecl(Job, "Result")) {
        @compileError("scheduler jobs must declare `pub const Result = T`");
    }
    if (!@hasDecl(Job, "execute")) {
        @compileError("scheduler jobs must define `execute`");
    }
    return Job.Result;
}

fn isDependency(comptime FieldType: type) bool {
    return switch (@typeInfo(FieldType)) {
        .@"struct" => @hasDecl(FieldType, "scheduler_dependency_type"),
        else => false,
    };
}

fn dependencyCount(comptime Job: type) usize {
    comptime var count: usize = 0;
    inline for (std.meta.fields(Job)) |field| {
        if (comptime isDependency(field.type)) {
            count += 1;
        }
    }
    return count;
}

test "jobs execute after dependency fields are filled" {
    const Value = struct {
        pub const Result = i32;

        value: i32,

        pub fn execute(self: *const @This()) i32 {
            return self.value;
        }
    };

    const Add = struct {
        pub const Result = i32;

        left: Scheduler.Dep(i32),
        right: Scheduler.Dep(i32),

        pub fn execute(self: *const @This()) i32 {
            std.debug.assert(self.left.ready);
            std.debug.assert(self.right.ready);
            return self.left.value + self.right.value;
        }
    };

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();

    const scheduler = try Scheduler.init(std.heap.page_allocator, threaded_io.io(), .{ .threads = 4 });
    defer scheduler.deinit();

    const a = try scheduler.spawn(Value{ .value = 21 });
    const b = try scheduler.spawn(Value{ .value = 19 });
    const sum = try scheduler.spawn(Add{ .left = a.dep(), .right = b.dep() });

    scheduler.finish();
    try std.testing.expectEqual(@as(i32, 40), sum.wait());
}

test "dependencies can form a small computation graph" {
    const Value = struct {
        pub const Result = i64;

        value: i64,

        pub fn execute(self: *const @This()) i64 {
            return self.value;
        }
    };

    const Multiply = struct {
        pub const Result = i64;

        a: Scheduler.Dep(i64),
        b: Scheduler.Dep(i64),

        pub fn execute(self: *const @This()) i64 {
            return self.a.get() * self.b.get();
        }
    };

    const Add = struct {
        pub const Result = i64;

        a: Scheduler.Dep(i64),
        b: Scheduler.Dep(i64),

        pub fn execute(self: *const @This()) i64 {
            return self.a.get() + self.b.get();
        }
    };

    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();

    const scheduler = try Scheduler.init(std.heap.page_allocator, threaded_io.io(), .{ .threads = 4 });
    defer scheduler.deinit();

    const two = try scheduler.spawn(Value{ .value = 2 });
    const three = try scheduler.spawn(Value{ .value = 3 });
    const five = try scheduler.spawn(Value{ .value = 5 });
    const six = try scheduler.spawn(Multiply{ .a = two.dep(), .b = three.dep() });
    const eleven = try scheduler.spawn(Add{ .a = six.dep(), .b = five.dep() });

    scheduler.finish();
    try std.testing.expectEqual(@as(i64, 11), eleven.wait());
}
