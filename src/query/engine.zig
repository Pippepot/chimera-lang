const std = @import("std");
const disk_codec = @import("codec.zig");
const value_operations = @import("../value.zig");
const profiling = @import("../profiling.zig");

const Revision = u64;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const PersistedInputRef = *InputEntry;
pub const PersistedQueryRef = *Entry;

pub const QueryError = error{
    DuplicateInput,
    InputNotFound,
    InputUpdateDuringQuery,
    QueryCycle,
    SchedulerStopped,
    InternIdOverflow,
    InvalidInternId,
};

pub const Options = struct {
    worker_count: ?usize = null,
    profile: ?*profiling.Collector = null,
};

const EntryState = enum {
    queued,
    running,
    complete,
    failed,
};

const EntryResult = union(enum) {
    verified,
    success: QueryOutput,
    failure: anyerror,
};

const QueryOutput = struct {
    pointer: *anyopaque,
    storage: union(enum) {
        heap,
        arena: std.heap.ArenaAllocator,
        inline_value,
    } = .heap,

    fn deinit(output: *QueryOutput, allocator: std.mem.Allocator, destroy: DestroyOutputFn) void {
        switch (output.storage) {
            .heap => destroy(allocator, output.pointer, true),
            .arena => |*arena| {
                destroy(arena.allocator(), output.pointer, true);
                arena.deinit();
            },
            .inline_value => destroy(allocator, output.pointer, false),
        }
    }
};

/// Work a caller is about to wait for stays unpublished: any thread that needs
/// it can still claim it, but no worker wakes up to race for a task the caller
/// is about to run itself.
const Publish = enum { deferred, immediate };

const Computation = struct {
    deps: DependencyMap = .empty,
    input_deps: std.ArrayList(*InputEntry) = .empty,
    accums: ?*AccumBucket = null,
};

const QueryStorage = struct {
    const sizes = .{ 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576 };
    const general_class_count = 6;
    const large_sizes = .{ 4194304, 16777216, 67108864, 268435456 };

    backing: std.mem.Allocator,
    pool_arena: std.heap.ArenaAllocator.State = .{},
    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    free_lists: [sizes.len]std.SinglyLinkedList = @splat(.{}),
    large_free_lists: [large_sizes.len]std.SinglyLinkedList = @splat(.{}),

    fn allocator(storage: *QueryStorage) std.mem.Allocator {
        return storage.classAllocator(general_class_count);
    }

    fn arenaAllocator(storage: *QueryStorage) std.mem.Allocator {
        return storage.classAllocator(sizes.len);
    }

    fn classAllocator(storage: *QueryStorage, comptime class_count: usize) std.mem.Allocator {
        const Classes = struct {
            fn alloc(pointer: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
                const owner: *QueryStorage = @ptrCast(@alignCast(pointer));
                return owner.allocClass(class_count, length, alignment, return_address);
            }

            fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
                const owner: *QueryStorage = @ptrCast(@alignCast(pointer));
                owner.freeClass(class_count, memory, alignment, return_address);
            }
        };
        return .{ .ptr = storage, .vtable = &.{
            .alloc = Classes.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = Classes.free,
        } };
    }

    fn deinit(storage: *QueryStorage) void {
        storage.releaseLarge();
        var arena = storage.pool_arena.promote(storage.backing);
        arena.deinit();
    }

    fn releaseLarge(storage: *QueryStorage) void {
        storage.mutex.lockUncancelable(storage.io);
        defer storage.mutex.unlock(storage.io);
        inline for (large_sizes, 0..) |size, index| {
            while (storage.large_free_lists[index].popFirst()) |node| {
                const memory: [*]u8 = @ptrCast(node);
                storage.backing.rawFree(memory[0..size], .@"16", @returnAddress());
            }
        }
    }

    fn allocClass(storage: *QueryStorage, comptime class_count: usize, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        if (alignment.toByteUnits() <= 16) {
            storage.mutex.lockUncancelable(storage.io);
            defer storage.mutex.unlock(storage.io);
            inline for (sizes, 0..) |size, index| {
                if (index < class_count and length <= size) {
                    if (storage.free_lists[index].popFirst()) |node| return @ptrCast(node);
                    var arena = storage.pool_arena.promote(storage.backing);
                    defer storage.pool_arena = arena.state;
                    const memory = arena.allocator().alignedAlloc(u8, .@"16", size) catch return null;
                    return memory.ptr;
                }
            }
            inline for (large_sizes, 0..) |size, index| {
                if (length > sizes[sizes.len - 1] and length <= size) {
                    if (storage.large_free_lists[index].popFirst()) |node| return @ptrCast(node);
                    return storage.backing.rawAlloc(size, .@"16", return_address);
                }
            }
        }
        return storage.backing.rawAlloc(length, alignment, return_address);
    }

    fn freeClass(storage: *QueryStorage, comptime class_count: usize, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        if (alignment.toByteUnits() <= 16) {
            storage.mutex.lockUncancelable(storage.io);
            defer storage.mutex.unlock(storage.io);
            inline for (sizes, 0..) |size, index| {
                if (index < class_count and memory.len <= size) {
                    storage.free_lists[index].prepend(@ptrCast(@alignCast(memory.ptr)));
                    return;
                }
            }
            inline for (large_sizes, 0..) |size, index| {
                if (memory.len > sizes[sizes.len - 1] and memory.len <= size) {
                    storage.large_free_lists[index].prepend(@ptrCast(@alignCast(memory.ptr)));
                    return;
                }
            }
        }
        storage.backing.rawFree(memory, alignment, return_address);
    }
};

const RecyclingAllocator = struct {
    const min_block_log2 = 4;
    const block_alignment: std.mem.Alignment = .fromByteUnits(1 << min_block_log2);
    const FreeBlock = struct { next: ?*FreeBlock };

    backing: std.mem.Allocator,
    free_blocks: [@bitSizeOf(usize) - min_block_log2]?*FreeBlock = @splat(null),

    fn allocator(recycler: *RecyclingAllocator) std.mem.Allocator {
        return .{ .ptr = recycler, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn recyclable(memory_length: usize, alignment: std.mem.Alignment) bool {
        return memory_length >= block_alignment.toByteUnits() and alignment.order(block_alignment) != .gt;
    }

    fn alloc(pointer: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const recycler: *RecyclingAllocator = @ptrCast(@alignCast(pointer));
        if (!recyclable(length, alignment)) return recycler.backing.rawAlloc(length, alignment, return_address);
        const class = std.math.log2_int_ceil(usize, length) - min_block_log2;
        if (recycler.free_blocks[class]) |block| {
            recycler.free_blocks[class] = block.next;
            return @ptrCast(block);
        }
        return recycler.backing.rawAlloc(length, block_alignment, return_address);
    }

    fn resize(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const recycler: *RecyclingAllocator = @ptrCast(@alignCast(pointer));
        return recycler.backing.rawResize(memory, alignment, new_length, return_address);
    }

    fn remap(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        return if (resize(pointer, memory, alignment, new_length, return_address)) memory.ptr else null;
    }

    fn free(pointer: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const recycler: *RecyclingAllocator = @ptrCast(@alignCast(pointer));
        if (!recyclable(memory.len, alignment) or !block_alignment.check(@intFromPtr(memory.ptr))) {
            return recycler.backing.rawFree(memory, alignment, return_address);
        }
        if (std.debug.runtime_safety) @memset(memory, undefined);
        const class = std.math.log2_int(usize, memory.len) - min_block_log2;
        const block: *FreeBlock = @ptrCast(@alignCast(memory.ptr));
        block.* = .{ .next = recycler.free_blocks[class] };
        recycler.free_blocks[class] = block;
    }
};

test "recycling allocator reuses released blocks that fit later requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recycler: RecyclingAllocator = .{ .backing = arena.allocator() };
    const allocator = recycler.allocator();
    const first = try allocator.alloc(u8, 40);
    const live = try allocator.alloc(u8, 40);
    @memset(live, 0x5a);
    allocator.free(first);
    const larger = try allocator.alloc(u8, 33);
    try std.testing.expect(larger.ptr != first.ptr);
    const reused = try allocator.alloc(u64, 4);
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    for (live) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
}

test "query storage reuses allocation classes without overlapping live storage" {
    var storage: QueryStorage = .{ .backing = std.testing.allocator, .io = std.testing.io };
    defer storage.deinit();
    const allocator = storage.arenaAllocator();
    inline for (QueryStorage.sizes) |size| {
        const memory = try allocator.alloc(u8, size / 2);
        defer allocator.free(memory);
        @memset(memory, 0xa5);
        const freed = try allocator.alloc(u8, size);
        try std.testing.expect(memory.ptr != freed.ptr);
        allocator.free(freed);
        const reused = try allocator.alloc(u8, size - 1);
        defer allocator.free(reused);
        try std.testing.expectEqual(freed.ptr, reused.ptr);
        try std.testing.expect(@intFromPtr(reused.ptr) % 16 == 0);
        @memset(reused, 0x5a);
        for (memory) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
    }
    const general = storage.allocator();
    const retained = storage.free_lists[QueryStorage.general_class_count].first;
    general.free(try general.alloc(u8, QueryStorage.sizes[QueryStorage.general_class_count - 1] + 1));
    try std.testing.expectEqual(retained, storage.free_lists[QueryStorage.general_class_count].first);

    const large = try allocator.alloc(u8, QueryStorage.sizes[QueryStorage.sizes.len - 1] + 1);
    allocator.free(large);
    const reused_large = try general.alloc(u8, QueryStorage.large_sizes[0]);
    try std.testing.expectEqual(large.ptr, reused_large.ptr);
    general.free(reused_large);
    storage.releaseLarge();
    try std.testing.expectEqual(null, storage.large_free_lists[0].first);
}

pub const Context = struct {
    db: *Database,
    current: *Entry,
    worker_index: ?usize,
    local_allocator: ?std.mem.Allocator = null,

    pub fn input(ctx: *Context, comptime I: type, key: I.Key) anyerror!*const I.Value {
        validateInput(I);
        const equal = if (@hasDecl(I, "eqlKey")) I.eqlKey else std.meta.eql;
        for (ctx.current.computation.?.input_deps.items) |dependency| {
            if (dependency.type_identity != comptime typeIdentity(I)) continue;
            const stored_key: *const I.Key = @ptrCast(@alignCast(dependency.key_ptr));
            if (!equal(key, stored_key.*)) continue;
            return @ptrCast(@alignCast(dependency.value_ptr orelse return error.InputNotFound));
        }
        return ctx.db.getInput(I, key, ctx.current);
    }

    pub fn get(ctx: *Context, comptime Q: type, input_value: Q.Input) anyerror!*const Q.Output {
        const input_copy = input_value;
        const key = cacheKey(Q, &input_copy, keyHash(Q, "hash", input_copy), "eql");
        if (ctx.current.computation.?.deps.get(key)) |output| return @ptrCast(@alignCast(output));
        const handle = try ctx.db.scheduleWithKey(Q, input_value, key, ctx, .deferred);
        const output = try handle.wait();
        ctx.current.computation.?.deps.entries.items[handle.dependency_index.?].output = @ptrCast(output);
        return output;
    }

    pub fn spawn(ctx: *Context, comptime Q: type, input_value: Q.Input) anyerror!Handle(Q) {
        return ctx.db.scheduleInternal(Q, input_value, ctx, .immediate);
    }

    pub fn emit(ctx: *Context, comptime A: type, value: A) anyerror!void {
        try ctx.db.emit(ctx.current, A, value);
    }

    pub fn allocator(ctx: *Context) std.mem.Allocator {
        return ctx.local_allocator orelse ctx.db.allocator;
    }

    pub fn withAllocator(ctx: *Context, local_allocator: std.mem.Allocator) Context {
        var local = ctx.*;
        local.local_allocator = local_allocator;
        return local;
    }

    pub fn hasParallelWorkers(ctx: *Context) bool {
        return ctx.db.workers.len > 1;
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
        dependency_index: ?usize,
        settled: bool,

        pub fn wait(handle: @This()) anyerror!*const Q.Output {
            if (handle.settled) return @ptrCast(@alignCast(handle.entry.output.?.pointer));
            return handle.db.waitFor(Q, handle.entry, handle.waiter);
        }
    };
}

pub const Database = struct {
    allocator: std.mem.Allocator,
    profile: ?*profiling.Collector,
    revision: Revision = 0,
    io_runtime: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    work_available: std.Io.Condition = .init,
    stopping: bool = false,
    pending_queries: usize = 0,
    workers: []Worker,
    entries: EntryMap,
    entry_pool: std.heap.MemoryPool(Entry) = .empty,
    query_storage: QueryStorage,
    scratch_arenas: std.ArrayList(std.heap.ArenaAllocator.State) = .empty,
    inputs: InputMap,
    intern_mutex: std.Io.Mutex = .init,
    intern_slots: std.atomic.Value(*InternSlots),
    interned_values: InternValues,
    published_interns: std.atomic.Value(u64) = .init(0),
    next_worker: usize = 0,
    steal_cursor: usize = 0,
    visit_token: usize = 1,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Database {
        const worker_count = options.worker_count orelse std.Thread.getCpuCount() catch 1;

        const db = try allocator.create(Database);
        errdefer allocator.destroy(db);
        db.* = .{
            .allocator = allocator,
            .profile = options.profile,
            .io_runtime = std.Io.Threaded.init(allocator, .{}),
            .query_storage = .{ .backing = allocator },
            .workers = undefined,
            .entries = undefined,
            .inputs = undefined,
            .intern_slots = undefined,
            .interned_values = .empty,
        };
        db.query_storage.io = db.io();
        db.entries = .init(db.query_storage.allocator());
        db.inputs = .init(db.query_storage.allocator());
        errdefer db.query_storage.deinit();
        errdefer {
            db.entries.deinit();
            db.inputs.deinit();
            db.interned_values.deinit(db.query_storage.allocator());
            db.io_runtime.deinit();
        }
        db.intern_slots = .init(try InternSlots.create(db.query_storage.allocator(), null, 64));
        errdefer db.destroyInternSlots();

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
        for (db.workers) |*worker| db.destroyScratchArenas(&worker.scratch_arenas);
        db.destroyScratchArenas(&db.scratch_arenas);
        db.destroyInputs();
        db.destroyInternedValues();
        db.entries.deinit();
        db.inputs.deinit();
        db.destroyInternSlots();
        db.interned_values.deinit(db.query_storage.allocator());
        db.query_storage.deinit();
        db.io_runtime.deinit();

        const allocator = db.allocator;
        allocator.free(db.workers);
        allocator.destroy(db);
    }

    pub fn addInput(db: *Database, comptime I: type, key: I.Key, value: I.Value) anyerror!void {
        validateInput(I);

        const key_copy = key;
        const key_hash = keyHash(I, "hashKey", key_copy);
        const lookup_key = cacheKey(I, &key_copy, key_hash, "eqlKey");

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;
        if (db.pending_queries != 0) return error.InputUpdateDuringQuery;
        const existing = db.inputs.get(lookup_key);
        if (existing) |entry| if (entry.value_ptr != null) return error.DuplicateInput;

        const value_box = try db.query_storage.allocator().create(I.Value);
        errdefer db.query_storage.allocator().destroy(value_box);
        value_box.* = try cloneInputValue(I, db.query_storage.allocator(), value);
        errdefer deinitInputValue(I, db.query_storage.allocator(), value_box);

        const entry = existing orelse try db.insertInputLocked(I, key_copy, key_hash);
        // A missing read is observable too. Filling its entry invalidates
        // queries that previously handled InputNotFound.
        if (existing != null) {
            db.revision += 1;
            entry.changed_at = db.revision;
        }
        entry.value_ptr = @ptrCast(value_box);
    }

    fn insertInputLocked(db: *Database, comptime I: type, key: I.Key, key_hash: u64) !*InputEntry {
        const key_box = try db.query_storage.allocator().create(I.Key);
        errdefer db.query_storage.allocator().destroy(key_box);
        key_box.* = key;
        const entry = try db.query_storage.allocator().create(InputEntry);
        errdefer db.query_storage.allocator().destroy(entry);
        entry.* = .{
            .key_ptr = @ptrCast(key_box),
            .value_ptr = null,
            .changed_at = db.revision,
            .type_identity = comptime typeIdentity(I),
            .destroy_key_fn = comptime destroyBoxFn(I.Key, null),
            .destroy_value_fn = comptime destroyInputValueFn(I),
            .write_key_fn = comptime writeValueFn(I.Key),
            .fingerprint_fn = comptime fingerprintInputFn(I),
        };
        try db.inputs.put(cacheKey(I, key_box, key_hash, "eqlKey"), entry);
        return entry;
    }

    pub fn setInput(db: *Database, comptime I: type, key: I.Key, value: I.Value) anyerror!void {
        validateInput(I);

        const key_copy = key;
        const lookup_key = cacheKey(I, &key_copy, keyHash(I, "hashKey", key_copy), "eqlKey");

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;
        if (db.pending_queries != 0) return error.InputUpdateDuringQuery;

        const input_entry = db.inputs.get(lookup_key) orelse return error.InputNotFound;
        const old_value: *I.Value = @ptrCast(@alignCast(input_entry.value_ptr orelse return error.InputNotFound));
        if (inputValueEql(I, old_value.*, value)) return;

        const replacement = try cloneInputValue(I, db.query_storage.allocator(), value);
        deinitInputValue(I, db.query_storage.allocator(), old_value);
        old_value.* = replacement;
        db.revision += 1;
        input_entry.changed_at = db.revision;
    }

    pub fn input(db: *Database, comptime I: type, key: I.Key) anyerror!*const I.Value {
        validateInput(I);
        return db.getInput(I, key, null);
    }

    pub fn get(db: *Database, comptime Q: type, input_value: Q.Input) anyerror!*const Q.Output {
        const handle = try db.scheduleInternal(Q, input_value, null, .deferred);
        return handle.wait();
    }

    pub fn spawn(db: *Database, comptime Q: type, input_value: Q.Input) anyerror!Handle(Q) {
        return db.scheduleInternal(Q, input_value, null, .immediate);
    }

    pub fn intern(db: *Database, comptime I: type, value: I.Value) anyerror!I.Id {
        validateInterner(I);
        const value_hash = I.hash(value);
        if (db.published_interns.load(.acquire) == stopped_interns) return error.SchedulerStopped;
        if (db.findIntern(I, db.intern_slots.load(.acquire), &value, value_hash)) |index| return internId(I, index);

        db.intern_mutex.lockUncancelable(db.io());
        defer db.intern_mutex.unlock(db.io());

        if (db.published_interns.load(.monotonic) == stopped_interns) return error.SchedulerStopped;
        const slots = db.intern_slots.load(.monotonic);
        if (db.findIntern(I, slots, &value, value_hash)) |index| return internId(I, index);
        if (db.interned_values.len > std.math.maxInt(@typeInfo(I.Id).@"enum".tag_type)) return error.InternIdOverflow;
        if (db.interned_values.len == std.math.maxInt(u32)) return error.InternIdOverflow;

        const current = if ((db.interned_values.len + 1) * 2 > slots.slots.len) try db.growInternSlots(slots) else slots;
        try db.interned_values.ensureUnusedCapacity(db.query_storage.allocator(), 1);

        const value_box = try db.query_storage.allocator().create(I.Value);
        errdefer db.query_storage.allocator().destroy(value_box);
        value_box.* = try I.clone(db.query_storage.allocator(), value);
        errdefer I.deinit(db.query_storage.allocator(), value_box);

        const index: u32 = @intCast(db.interned_values.len);
        db.interned_values.appendAssumeCapacity(.{
            .type_identity = comptime typeIdentity(I),
            .hash = value_hash,
            .value_ptr = @ptrCast(value_box),
            .destroy_value_fn = comptime destroyBoxFn(I.Value, I.deinit),
            .write_value_fn = comptime writeValueFn(I.Value),
        });
        current.insert(index, value_hash);
        db.published_interns.store(@intCast(db.interned_values.len), .release);
        return internId(I, index);
    }

    fn findIntern(db: *Database, comptime I: type, table: *const InternSlots, value: *const I.Value, hash: u64) ?u32 {
        const mask = table.slots.len - 1;
        var slot: usize = @as(usize, @truncate(hash)) & mask;
        while (true) : (slot = (slot + 1) & mask) {
            const stored = table.slots[slot].load(.acquire);
            if (stored == 0) return null;
            const entry = db.interned_values.at(stored - 1);
            if (entry.hash != hash or entry.type_identity != comptime typeIdentity(I)) continue;
            const interned: *const I.Value = @ptrCast(@alignCast(entry.value_ptr));
            if (I.eql(interned.*, value.*)) return stored - 1;
        }
    }

    fn growInternSlots(db: *Database, table: *InternSlots) !*InternSlots {
        const grown = try InternSlots.create(db.query_storage.allocator(), table, table.slots.len * 2);
        for (0..db.interned_values.len) |index| grown.insert(@intCast(index), db.interned_values.at(index).hash);
        db.intern_slots.store(grown, .release);
        return grown;
    }

    fn destroyInternSlots(db: *Database) void {
        var table: ?*InternSlots = db.intern_slots.raw;
        while (table) |current| {
            table = current.previous;
            db.query_storage.allocator().free(current.slots);
            db.query_storage.allocator().destroy(current);
        }
    }

    pub fn writeInternedValues(db: *Database, writer: *disk_codec.Writer) !void {
        db.intern_mutex.lockUncancelable(db.io());
        defer db.intern_mutex.unlock(db.io());
        try writer.write(u64, @intCast(db.interned_values.len));
        for (0..db.interned_values.len) |index| {
            const entry = db.interned_values.at(index).*;
            try writer.write([]const u8, entry.type_identity.name);
            try entry.write_value_fn(writer, entry.value_ptr);
        }
    }

    pub fn matchPersistedInput(db: *Database, comptime I: type, key: I.Key, digest: [32]u8) !?PersistedInputRef {
        validateInput(I);
        const key_copy = key;
        const key_hash = keyHash(I, "hashKey", key_copy);
        const lookup_key = cacheKey(I, &key_copy, key_hash, "eqlKey");
        db.lock();
        defer db.unlock();
        if (db.pending_queries != 0) return error.InputUpdateDuringQuery;
        const entry = db.inputs.get(lookup_key) orelse try db.insertInputLocked(I, key_copy, key_hash);
        const actual = try inputFingerprint(I, db.allocator, entry.value_ptr);
        return if (std.mem.eql(u8, &actual, &digest)) entry else null;
    }

    pub fn matchPersistedQuery(db: *Database, comptime Q: type, input_value: Q.Input, digest: [32]u8) !?PersistedQueryRef {
        const handle = try db.scheduleInternal(Q, input_value, null, .deferred);
        _ = handle.wait() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        const entry = handle.entry;
        var clean: std.AutoHashMap(*Entry, bool) = .init(db.allocator);
        defer clean.deinit();
        if (!(try db.persistedSubtreeClean(entry, &clean))) return null;
        const actual = try entry.fingerprint_output_fn.?(db.allocator, entry.output.?.pointer);
        return if (std.mem.eql(u8, &actual, &digest)) entry else null;
    }

    pub fn importCompletedQuery(db: *Database, comptime Q: type, input_value: Q.Input, output_value: Q.Output, inputs: []const PersistedInputRef, queries: []const PersistedQueryRef) !void {
        validateQuery(Q);
        const input_copy = input_value;
        const input_hash = keyHash(Q, "hash", input_copy);
        db.lock();
        defer db.unlock();
        if (db.pending_queries != 0) return error.InputUpdateDuringQuery;
        if (db.entries.get(cacheKey(Q, &input_copy, input_hash, "eql"))) |existing| {
            if (!settledLocked(db, existing) or existing.accums_in_subtree) return error.InvalidCache;
            const current = existing.output orelse return error.InvalidCache;
            if (!existing.output_eql_fn(current.pointer, @ptrCast(&output_value))) return error.InvalidCache;
            var redundant = output_value;
            deinitTypedValue(Q.Output, db.allocator, &redundant);
            return;
        }
        const entry = try db.insertEntryLocked(Q, input_copy, input_hash);
        errdefer {
            _ = db.entries.remove(cacheKey(Q, &input_copy, input_hash, "eql"));
            db.destroyEntry(entry);
        }
        try entry.input_deps.appendSlice(db.query_storage.allocator(), inputs);
        for (queries) |dependency| try entry.deps.put(db.query_storage.allocator(), dependency, null);
        const output_box = try db.allocator.create(Q.Output);
        output_box.* = output_value;
        entry.output = .{ .pointer = @ptrCast(output_box) };
        entry.state = .complete;
    }

    /// Persist only successful, diagnostic-free subgraphs. Query boundaries
    /// retain equal-result invalidation, while the remaining edges terminate
    /// at the exact inputs observed by the computation.
    pub fn writeCompletedQueries(db: *Database, comptime Q: type, writer: *disk_codec.Writer) !void {
        validateQuery(Q);
        comptime if (@typeInfo(Q.Output) != .optional) @compileError("persisted query output must be optional");
        db.lock();
        defer db.unlock();
        if (db.pending_queries != 0) return error.InputUpdateDuringQuery;

        const Record = struct { entry: *Entry, inputs: []*InputEntry, queries: []*Entry };
        var records: std.ArrayList(Record) = .empty;
        defer {
            for (records.items) |record| {
                db.allocator.free(record.inputs);
                db.allocator.free(record.queries);
            }
            records.deinit(db.allocator);
        }
        var clean: std.AutoHashMap(*Entry, bool) = .init(db.allocator);
        defer clean.deinit();
        var entries = db.entries.iterator();
        while (entries.next()) |slot| {
            if (slot.key_ptr.type_identity != comptime typeIdentity(Q)) continue;
            const entry = slot.value_ptr.*;
            if (entry.state != .complete or entry.verified_at != db.revision) continue;
            const output: *const Q.Output = @ptrCast(@alignCast((entry.output orelse continue).pointer));
            if (output.* == null) continue;
            var seen_entries = std.AutoHashMap(*Entry, void).init(db.allocator);
            defer seen_entries.deinit();
            var seen_inputs = std.AutoHashMap(*InputEntry, void).init(db.allocator);
            defer seen_inputs.deinit();
            var inputs: std.ArrayList(*InputEntry) = .empty;
            defer inputs.deinit(db.allocator);
            var query_deps: std.ArrayList(*Entry) = .empty;
            defer query_deps.deinit(db.allocator);
            if (!(try db.persistedSubtreeClean(entry, &clean))) continue;
            try db.collectPersistedDependencies(entry, &seen_entries, &seen_inputs, &inputs, &query_deps);
            const owned_inputs = try inputs.toOwnedSlice(db.allocator);
            errdefer db.allocator.free(owned_inputs);
            const owned_queries = try query_deps.toOwnedSlice(db.allocator);
            errdefer db.allocator.free(owned_queries);
            try records.append(db.allocator, .{ .entry = entry, .inputs = owned_inputs, .queries = owned_queries });
        }
        try writer.write(u64, @intCast(records.items.len));
        for (records.items) |record| {
            const query_input: *const Q.Input = @ptrCast(@alignCast(record.entry.input_ptr));
            const output: *const Q.Output = @ptrCast(@alignCast(record.entry.output.?.pointer));
            try writer.write(Q.Input, query_input.*);
            try writer.write(Q.Output, output.*);
            try writer.write(u64, @intCast(record.inputs.len));
            for (record.inputs) |dep| {
                try writer.write([]const u8, dep.type_identity.name);
                try dep.write_key_fn(writer, dep.key_ptr);
                const digest = try dep.fingerprint_fn(db.allocator, dep.value_ptr);
                try writer.bytes.appendSlice(writer.allocator, &digest);
            }
            try writer.write(u64, @intCast(record.queries.len));
            for (record.queries) |dep| {
                try writer.write([]const u8, dep.type_identity.name);
                try dep.write_input_fn(writer, dep.input_ptr);
                const digest = try dep.fingerprint_output_fn.?(db.allocator, dep.output.?.pointer);
                try writer.bytes.appendSlice(writer.allocator, &digest);
            }
        }
    }

    fn persistedSubtreeClean(db: *Database, entry: *Entry, clean: *std.AutoHashMap(*Entry, bool)) !bool {
        if (clean.get(entry)) |result| return result;
        var result = entry.state == .complete and entry.verified_at == db.revision and !entry.accums_in_subtree;
        if (result) {
            for (entry.deps.entries.items) |dependency| {
                const dep = dependency.entry;
                if (!(try db.persistedSubtreeClean(dep, clean))) {
                    result = false;
                    break;
                }
            }
        }
        try clean.put(entry, result);
        return result;
    }

    fn collectPersistedDependencies(db: *Database, entry: *Entry, seen_entries: *std.AutoHashMap(*Entry, void), seen_inputs: *std.AutoHashMap(*InputEntry, void), inputs: *std.ArrayList(*InputEntry), query_deps: *std.ArrayList(*Entry)) !void {
        if ((try seen_entries.getOrPut(entry)).found_existing) return;
        for (entry.input_deps.items) |input_entry| {
            if (!(try seen_inputs.getOrPut(input_entry)).found_existing) try inputs.append(db.allocator, input_entry);
        }
        for (entry.deps.entries.items) |dependency| {
            const dep = dependency.entry;
            if (dep.fingerprint_output_fn != null) {
                if (!(try seen_entries.getOrPut(dep)).found_existing)
                    try query_deps.append(db.allocator, dep);
            } else {
                try db.collectPersistedDependencies(dep, seen_entries, seen_inputs, inputs, query_deps);
            }
        }
    }

    pub fn lookupInterned(db: *Database, comptime I: type, id: I.Id) QueryError!*const I.Value {
        return (try db.lookupInternedAs(I, id)) orelse error.InvalidInternId;
    }

    /// Returns null when the global ID is valid but belongs to another
    /// interner. An out-of-range ID still returns InvalidInternId.
    pub fn lookupInternedAs(db: *Database, comptime I: type, id: I.Id) QueryError!?*const I.Value {
        validateInterner(I);
        const index: usize = @backingInt(id);
        const published = db.published_interns.load(.acquire);
        if (published == stopped_interns) return error.SchedulerStopped;
        if (index >= published) return error.InvalidInternId;
        const entry = db.interned_values.at(index);
        if (entry.type_identity != comptime typeIdentity(I)) return null;
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
        const handle = try db.scheduleInternal(Q, input_value, null, .deferred);
        _ = try handle.wait();
        return handle.entry;
    }

    fn scheduleInternal(db: *Database, comptime Q: type, input_value: Q.Input, waiter: ?*Context, publish: Publish) anyerror!Handle(Q) {
        const input_copy = input_value;
        const input_hash = keyHash(Q, "hash", input_copy);
        const lookup_key = cacheKey(Q, &input_copy, input_hash, "eql");
        return db.scheduleWithKey(Q, input_value, lookup_key, waiter, publish);
    }

    fn scheduleWithKey(db: *Database, comptime Q: type, input_value: Q.Input, lookup_key: ErasedKey, waiter: ?*Context, publish: Publish) anyerror!Handle(Q) {
        validateQuery(Q);
        const parent = if (waiter) |ctx| ctx.current else null;

        db.lock();
        defer db.unlock();

        if (db.stopping) return error.SchedulerStopped;

        if (db.entries.get(lookup_key)) |existing| {
            const dependency_index = try db.addDependencyLocked(parent, existing);
            db.enqueueForCurrentRevisionLocked(existing, publish);
            return .{
                .db = db,
                .entry = existing,
                .waiter = waiter,
                .dependency_index = dependency_index,
                .settled = settledLocked(db, existing),
            };
        }

        const entry = try db.insertEntryLocked(Q, input_value, lookup_key.hash ^ typeHash(Q));
        errdefer {
            _ = db.entries.remove(lookup_key);
            db.destroyEntry(entry);
        }

        const dependency_index = try db.addDependencyLocked(parent, entry);
        db.enqueueLocked(entry, publish);

        return .{
            .db = db,
            .entry = entry,
            .waiter = waiter,
            .dependency_index = dependency_index,
            .settled = false,
        };
    }

    fn getInput(db: *Database, comptime I: type, key: I.Key, parent: ?*Entry) anyerror!*const I.Value {
        const key_copy = key;
        const key_hash = keyHash(I, "hashKey", key_copy);
        const lookup_key = cacheKey(I, &key_copy, key_hash, "eqlKey");

        db.lock();
        defer db.unlock();

        const entry = db.inputs.get(lookup_key) orelse try db.insertInputLocked(I, key_copy, key_hash);
        if (parent) |query_entry| try db.addInputDependencyLocked(query_entry, entry);
        const value: *const I.Value = @ptrCast(@alignCast(entry.value_ptr orelse return error.InputNotFound));
        return value;
    }

    fn insertEntryLocked(db: *Database, comptime Q: type, input_value: Q.Input, input_hash: u64) !*Entry {
        const entry = try db.entry_pool.create(db.query_storage.allocator());
        errdefer db.entry_pool.destroy(entry);
        const inline_input = @sizeOf(Q.Input) <= 32 and @alignOf(Q.Input) <= 16;
        const input_box: *Q.Input = if (inline_input)
            @ptrCast(@alignCast(&entry.input_storage))
        else
            try db.query_storage.allocator().create(Q.Input);
        errdefer if (!inline_input) db.query_storage.allocator().destroy(input_box);

        entry.* = .{
            .input_ptr = @ptrCast(input_box),
            .output = null,
            .type_identity = comptime typeIdentity(Q),
            .key_hash = input_hash ^ typeHash(Q),
            .err = null,
            .state = .queued,
            .verified_at = db.revision,
            .changed_at = db.revision,
            .compute_fn = comptime computeFn(Q),
            .destroy_input_fn = comptime if (inline_input) deinitInlineBoxFn(Q.Input) else destroyBoxFn(Q.Input, deinitBoxValue),
            .destroy_output_fn = comptime destroyOutputFn(Q.Output),
            .output_eql_fn = comptime outputEqlFn(Q),
            .write_input_fn = comptime writeValueFn(Q.Input),
            .fingerprint_output_fn = comptime if (@hasDecl(Q, "disk_boundary") and Q.disk_boundary) fingerprintQueryOutputFn(Q) else null,
            .deps = .empty,
            .input_deps = .empty,
            .accums = null,
            .accums_in_subtree = false,
            .computation = null,
            .queue_owner = null,
            .queue_prev = null,
            .queue_next = null,
            .visit_token = 0,
        };
        input_box.* = input_value;

        try db.entries.put(cacheKey(Q, input_box, input_hash, "eql"), entry);
        return entry;
    }

    fn waitFor(db: *Database, comptime Q: type, entry: *Entry, waiter: ?*Context) anyerror!*const Q.Output {
        try db.waitForEntry(entry, if (waiter) |ctx| ctx.worker_index else null);
        // Output payloads are boxed, so an absent value such as a failed
        // parse's `?Ast = null` still has a non-null box pointer here.
        return @ptrCast(@alignCast(entry.output.?.pointer));
    }

    fn waitForEntry(db: *Database, entry: *Entry, preferred_worker: ?usize) anyerror!void {
        var waiting: profiling.Scope = .{};
        waiting.beginCurrent(.dependency_wait);
        defer waiting.end();
        while (true) {
            db.lock();

            switch (entry.state) {
                .complete => {
                    std.debug.assert(entry.verified_at == db.revision);
                    db.unlock();
                    return;
                },
                .failed => {
                    const err = entry.err orelse unreachable;
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

            std.debug.assert(db.workers.len != 0);
            const finished = entry.finished.raw;
            _ = entry.waiters.fetchAdd(1, .monotonic);
            db.unlock();
            db.io().futexWaitUncancelable(u32, &entry.finished.raw, finished);
            _ = entry.waiters.fetchSub(1, .monotonic);
        }
    }

    fn runEntry(db: *Database, entry: *Entry, worker_index: ?usize) void {
        if (entry.output != null and entry.verified_at != db.revision) {
            if (!db.dependenciesChanged(entry, worker_index)) {
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
            .verified => {
                entry.verified_at = db.revision;
                updateAccumsInSubtreeLocked(entry);
            },
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
                entry.last_failed_at = db.revision;
            },
        }
        if (result != .failure) {
            entry.err = null;
            entry.state = .complete;
        }
        std.debug.assert(db.pending_queries != 0);
        db.pending_queries -= 1;
        if (db.pending_queries == 0) db.query_storage.releaseLarge();
        _ = entry.finished.fetchAdd(1, .release);
        const waiting = entry.waiters.load(.monotonic) != 0;
        db.unlock();
        if (waiting) db.io().futexWake(u32, &entry.finished.raw, std.math.maxInt(u32));
    }

    fn dependenciesChanged(db: *Database, entry: *Entry, worker_index: ?usize) bool {
        const verified_at = entry.verified_at;
        for (entry.input_deps.items) |input_entry| {
            if (input_entry.changed_at > verified_at) return true;
        }
        for (entry.deps.entries.items) |dependency| {
            const dep = dependency.entry;
            // Let Q.run handle dependency errors again, just as on first demand.
            db.verifyDependency(entry, dep, worker_index) catch return true;
            // A recovered child can equal its old memo while the parent still
            // holds a fallback computed during that child's failure.
            if (dep.last_failed_at) |failed_at| if (failed_at >= verified_at) return true;
            if (dep.changed_at > verified_at) return true;
        }
        return false;
    }

    fn verifyDependency(db: *Database, entry: *Entry, dep: *Entry, worker_index: ?usize) anyerror!void {
        {
            db.lock();
            defer db.unlock();
            std.debug.assert(entry.verification_dependency == null);
            if (!settledLocked(db, dep) and db.reachesLocked(dep, entry)) return error.QueryCycle;
            // Only the dependency currently being verified is an active wait.
            // Other old edges may disappear when this entry recomputes.
            entry.verification_dependency = dep;
            db.enqueueForCurrentRevisionLocked(dep, .deferred);
        }
        defer {
            db.lock();
            entry.verification_dependency = null;
            db.unlock();
        }
        try db.waitForEntry(dep, worker_index);
    }

    fn enqueueForCurrentRevisionLocked(db: *Database, entry: *Entry, publish: Publish) void {
        const needs_work = entry.state == .failed or
            (entry.state == .complete and entry.verified_at != db.revision);
        if (!needs_work) return;
        entry.err = null;
        entry.state = .queued;
        db.enqueueLocked(entry, publish);
    }

    fn commitComputationLocked(db: *Database, entry: *Entry, result: QueryOutput) void {
        var fresh = result;
        const computation = if (entry.computation) |*pending| pending else unreachable;
        const observable_equal = entry.output != null and
            entry.output_eql_fn(entry.output.?.pointer, fresh.pointer) and
            accumBucketsEql(entry.accums, computation.accums);

        if (observable_equal) {
            fresh.deinit(db.allocator, entry.destroy_output_fn);
            db.destroyAccumBuckets(computation.accums);
        } else {
            db.deinitEntryObservable(entry);
            entry.output = fresh;
            entry.accums = computation.accums;
            entry.changed_at = db.revision;
        }
        computation.accums = null;

        entry.deps.deinit(db.query_storage.allocator());
        entry.input_deps.deinit(db.query_storage.allocator());
        entry.deps = computation.deps;
        entry.input_deps = computation.input_deps;
        computation.deps = .empty;
        computation.input_deps = .empty;
        entry.computation = null;
        entry.verified_at = db.revision;
        updateAccumsInSubtreeLocked(entry);
    }

    fn updateAccumsInSubtreeLocked(entry: *Entry) void {
        entry.accums_in_subtree = entry.accums != null;
        for (entry.deps.entries.items) |dependency| {
            const dep = dependency.entry;
            if (dep.state == .complete and dep.accums_in_subtree) {
                entry.accums_in_subtree = true;
                break;
            }
        }
    }

    fn enqueueLocked(db: *Database, entry: *Entry, publish: Publish) void {
        db.pending_queries += 1;
        if (publish == .deferred or db.workers.len == 0) return;
        const index = db.next_worker % db.workers.len;
        db.next_worker = (index + 1) % db.workers.len;
        entry.queue_owner = index;
        db.workers[index].queue.pushBack(entry);
        db.signalWork();
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
        if (entry.queue_owner) |index| db.workers[index].queue.remove(entry);
        entry.state = .running;
        return entry;
    }

    fn addDependencyLocked(db: *Database, parent: ?*Entry, child: *Entry) anyerror!?usize {
        const parent_entry = parent orelse return null;
        if (parent_entry == child) return error.QueryCycle;

        const computation = &parent_entry.computation.?;
        const existing = try computation.deps.getOrPut(db.query_storage.allocator(), child);
        if (existing.found_existing) return existing.index;
        existing.value_ptr.* = null;
        errdefer computation.deps.rollback(child);

        if (!settledLocked(db, child) and db.reachesLocked(child, parent_entry)) return error.QueryCycle;
        return existing.index;
    }

    // Everything reachable from an entry completed in this revision is itself
    // complete, so such a subgraph cannot reach a still-running entry.
    fn settledLocked(db: *Database, entry: *Entry) bool {
        return entry.state == .complete and entry.verified_at == db.revision;
    }

    fn addInputDependencyLocked(db: *Database, parent: *Entry, input_entry: *InputEntry) !void {
        const input_deps = &parent.computation.?.input_deps;
        for (input_deps.items) |dep| {
            if (dep == input_entry) return;
        }
        try input_deps.append(db.query_storage.allocator(), input_entry);
    }

    fn reachesLocked(db: *Database, start: *Entry, target: *Entry) bool {
        std.debug.assert(!settledLocked(db, target));
        db.visit_token = @max(1, db.visit_token +% 1);
        return reachesVisit(db, start, target, db.visit_token);
    }

    fn emit(db: *Database, entry: *Entry, comptime A: type, value: A) !void {
        comptime validateObservableType(A, @typeName(A) ++ " accumulator");
        const computation = &entry.computation.?;
        if (accumulatorList(computation.accums, A)) |list| {
            try appendClonedAccumValue(A, list, db.query_storage.allocator(), value);
            return;
        }

        const list = try db.query_storage.allocator().create(std.ArrayList(A));
        list.* = .empty;
        errdefer {
            list.deinit(db.query_storage.allocator());
            db.query_storage.allocator().destroy(list);
        }

        const new_bucket = try db.query_storage.allocator().create(AccumBucket);
        errdefer db.query_storage.allocator().destroy(new_bucket);

        new_bucket.* = .{
            .type_name = @typeName(A),
            .values_ptr = @ptrCast(list),
            .eql_fn = accumListEqlFn(A),
            .destroy_fn = destroyAccumListFn(A),
            .next = computation.accums,
        };

        try appendClonedAccumValue(A, list, db.query_storage.allocator(), value);
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
        if (entry.state != .complete or !entry.accums_in_subtree) return;
        if ((try seen.getOrPut(entry)).found_existing) return;

        const direct = directAccumulatorValuesEntry(entry, A);
        for (direct) |item| {
            try appendClonedAccumValue(A, out, gpa, item);
        }

        for (entry.deps.entries.items) |dependency| {
            try db.appendAccumulatorValuesRecursive(dependency.entry, A, out, seen, gpa);
        }
    }

    fn destroyEntries(db: *Database) void {
        var iter = db.entries.valueIterator();
        while (iter.next()) |entry_ptr| {
            db.destroyEntry(entry_ptr.*);
        }
        db.entry_pool.deinit(db.query_storage.allocator());
    }

    fn destroyInputs(db: *Database) void {
        var iter = db.inputs.valueIterator();
        while (iter.next()) |entry_ptr| {
            db.destroyInput(entry_ptr.*);
        }
    }

    fn destroyInternedValues(db: *Database) void {
        for (0..db.interned_values.len) |index| {
            const entry = db.interned_values.at(index).*;
            entry.destroy_value_fn(db.query_storage.allocator(), entry.value_ptr);
        }
    }

    fn destroyEntry(db: *Database, entry: *Entry) void {
        entry.destroy_input_fn(db.query_storage.allocator(), entry.input_ptr);
        if (entry.computation) |*computation| db.deinitComputation(computation);
        db.deinitEntryObservable(entry);
        entry.deps.deinit(db.query_storage.allocator());
        entry.input_deps.deinit(db.query_storage.allocator());
        db.entry_pool.destroy(entry);
    }

    fn deinitEntryObservable(db: *Database, entry: *Entry) void {
        if (entry.output) |*output| {
            output.deinit(db.allocator, entry.destroy_output_fn);
            entry.output = null;
        }

        db.destroyAccumBuckets(entry.accums);
        entry.accums = null;
    }

    fn deinitComputation(db: *Database, computation: *Computation) void {
        computation.deps.deinit(db.query_storage.allocator());
        computation.input_deps.deinit(db.query_storage.allocator());
        db.destroyAccumBuckets(computation.accums);
        computation.* = .{};
    }

    fn destroyAccumBuckets(db: *Database, first: ?*AccumBucket) void {
        var bucket = first;
        while (bucket) |current| {
            const next = current.next;
            current.destroy_fn(db.query_storage.allocator(), current.values_ptr);
            db.query_storage.allocator().destroy(current);
            bucket = next;
        }
    }

    fn destroyInput(db: *Database, entry: *InputEntry) void {
        entry.destroy_key_fn(db.query_storage.allocator(), entry.key_ptr);
        if (entry.value_ptr) |value| entry.destroy_value_fn(db.query_storage.allocator(), value);
        db.query_storage.allocator().destroy(entry);
    }

    fn stopWorkers(db: *Database, spawned: usize) void {
        db.lock();
        db.stopping = true;
        db.intern_mutex.lockUncancelable(db.io());
        db.published_interns.store(stopped_interns, .release);
        db.intern_mutex.unlock(db.io());
        db.work_available.broadcast(db.io());
        db.unlock();

        var index: usize = 0;
        while (index < spawned) : (index += 1) {
            if (db.workers[index].thread) |thread| {
                thread.join();
                db.workers[index].thread = null;
            }
        }
    }

    fn acquireScratchArena(db: *Database, worker_index: ?usize) std.heap.ArenaAllocator {
        const allocator = db.query_storage.arenaAllocator();
        const index = worker_index orelse {
            db.lock();
            defer db.unlock();
            return if (db.scratch_arenas.pop()) |state| state.promote(allocator) else .init(allocator);
        };
        std.debug.assert(db.workers[index].thread_id == std.Thread.getCurrentId());
        return if (db.workers[index].scratch_arenas.pop()) |state| state.promote(allocator) else .init(allocator);
    }

    fn releaseScratchArena(db: *Database, worker_index: ?usize, arena: *std.heap.ArenaAllocator) void {
        if (!arena.reset(.{ .retain_with_limit = 128 * 1024 })) {
            arena.deinit();
            return;
        }
        if (arena.queryCapacity() == 0) return;
        const retained = if (worker_index) |index|
            db.workers[index].scratch_arenas.append(db.query_storage.allocator(), arena.state)
        else retained: {
            db.lock();
            defer db.unlock();
            break :retained db.scratch_arenas.append(db.query_storage.allocator(), arena.state);
        };
        retained catch {
            arena.deinit();
            return;
        };
        arena.* = .init(db.query_storage.arenaAllocator());
    }

    fn destroyScratchArenas(db: *Database, arenas: *std.ArrayList(std.heap.ArenaAllocator.State)) void {
        for (arenas.items) |state| state.promote(db.query_storage.arenaAllocator()).deinit();
        arenas.deinit(db.query_storage.allocator());
    }

    fn io(db: *Database) std.Io {
        return db.io_runtime.io();
    }

    fn lock(db: *Database) void {
        for (0..lock_spin_attempts) |_| {
            if (db.mutex.state.load(.monotonic) == .unlocked and db.mutex.tryLock()) return;
            std.atomic.spinLoopHint();
        }
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
};

const TypeIdentity = struct { name: []const u8 };

const ErasedKey = struct {
    type_identity: *const TypeIdentity,
    hash: u64,
    value_ptr: *const anyopaque,
    eql_fn: *const fn (*const anyopaque, *const anyopaque) bool,
};

const ErasedKeyContext = struct {
    pub fn hash(_: ErasedKeyContext, key: ErasedKey) u64 {
        return key.hash;
    }

    pub fn eql(_: ErasedKeyContext, a: ErasedKey, b: ErasedKey) bool {
        if (a.hash != b.hash) return false;
        if (a.type_identity != b.type_identity) return false;
        return a.eql_fn(a.value_ptr, b.value_ptr);
    }
};

const EntryMap = std.HashMap(ErasedKey, *Entry, ErasedKeyContext, 80);
const InputMap = std.HashMap(ErasedKey, *InputEntry, ErasedKeyContext, 80);
const ComputeFn = *const fn (*Database, *Entry, ?usize) anyerror!QueryOutput;
const DestroyOpaqueFn = *const fn (std.mem.Allocator, *anyopaque) void;
const DestroyOutputFn = *const fn (std.mem.Allocator, *anyopaque, bool) void;
const EqlOpaqueFn = *const fn (*const anyopaque, *const anyopaque) bool;
const WriteOpaqueFn = *const fn (*disk_codec.Writer, *const anyopaque) anyerror!void;
const FingerprintFn = *const fn (std.mem.Allocator, ?*anyopaque) anyerror![32]u8;
const FingerprintQueryFn = *const fn (std.mem.Allocator, *const anyopaque) anyerror![32]u8;

const DependencyMap = struct {
    const Dependency = struct {
        entry: *Entry,
        output: ?*const anyopaque = null,
    };

    entries: std.ArrayList(Dependency) = .empty,
    buckets: []u32 = &.{},

    const empty: DependencyMap = .{};

    fn get(deps: *const DependencyMap, key: ErasedKey) ?*const anyopaque {
        if (deps.buckets.len != 0) {
            const mask = deps.buckets.len - 1;
            var bucket: usize = @as(usize, @truncate(key.hash)) & mask;
            while (deps.buckets[bucket] != 0) : (bucket = (bucket + 1) & mask) {
                const dependency = deps.entries.items[deps.buckets[bucket] - 1];
                if (matches(key, dependency.entry)) return dependency.output;
            }
            return null;
        }
        for (deps.entries.items) |dependency| {
            if (matches(key, dependency.entry)) return dependency.output;
        }
        return null;
    }

    fn getOrPut(deps: *DependencyMap, allocator: std.mem.Allocator, entry: *Entry) !struct {
        found_existing: bool,
        index: usize,
        value_ptr: *?*const anyopaque,
    } {
        if (deps.buckets.len != 0) {
            const mask = deps.buckets.len - 1;
            var bucket: usize = @as(usize, @truncate(entry.key_hash)) & mask;
            while (deps.buckets[bucket] != 0) : (bucket = (bucket + 1) & mask) {
                const position = deps.buckets[bucket] - 1;
                if (deps.entries.items[position].entry == entry) return .{
                    .found_existing = true,
                    .index = position,
                    .value_ptr = &deps.entries.items[position].output,
                };
            }
        } else {
            for (deps.entries.items, 0..) |dependency, position| {
                if (dependency.entry == entry) return .{
                    .found_existing = true,
                    .index = position,
                    .value_ptr = &deps.entries.items[position].output,
                };
            }
        }
        if (deps.entries.items.len == std.math.maxInt(u32)) return error.OutOfMemory;
        if (deps.buckets.len != 0 or deps.entries.items.len >= 16) try deps.ensureIndexCapacity(allocator);
        try deps.entries.ensureUnusedCapacity(allocator, 1);
        const position = deps.entries.items.len;
        if (deps.buckets.len != 0) insertIndex(deps.buckets, position, entry.key_hash);
        deps.entries.appendAssumeCapacity(.{ .entry = entry });
        return .{ .found_existing = false, .index = position, .value_ptr = &deps.entries.items[position].output };
    }

    fn put(deps: *DependencyMap, allocator: std.mem.Allocator, entry: *Entry, output: ?*const anyopaque) !void {
        const result = try deps.getOrPut(allocator, entry);
        result.value_ptr.* = output;
    }

    fn ensureIndexCapacity(deps: *DependencyMap, allocator: std.mem.Allocator) !void {
        if (deps.buckets.len >= (deps.entries.items.len + 1) * 2) return;
        const buckets = try allocator.alloc(u32, @max(64, deps.buckets.len * 2));
        @memset(buckets, 0);
        for (deps.entries.items, 0..) |dependency, position| insertIndex(buckets, position, dependency.entry.key_hash);
        allocator.free(deps.buckets);
        deps.buckets = buckets;
    }

    fn insertIndex(buckets: []u32, position: usize, hash: u64) void {
        const mask = buckets.len - 1;
        var bucket: usize = @as(usize, @truncate(hash)) & mask;
        while (buckets[bucket] != 0) bucket = (bucket + 1) & mask;
        buckets[bucket] = @intCast(position + 1);
    }

    inline fn matches(key: ErasedKey, entry: *Entry) bool {
        return key.hash == entry.key_hash and key.type_identity == entry.type_identity and
            key.eql_fn(key.value_ptr, entry.input_ptr);
    }

    fn rollback(deps: *DependencyMap, entry: *Entry) void {
        std.debug.assert(deps.entries.items[deps.entries.items.len - 1].entry == entry);
        if (deps.buckets.len != 0) {
            const mask = deps.buckets.len - 1;
            var bucket: usize = @as(usize, @truncate(entry.key_hash)) & mask;
            while (deps.buckets[bucket] != deps.entries.items.len) {
                std.debug.assert(deps.buckets[bucket] != 0);
                bucket = (bucket + 1) & mask;
            }
            deps.buckets[bucket] = 0;
        }
        _ = deps.entries.pop();
    }

    fn deinit(deps: *DependencyMap, allocator: std.mem.Allocator) void {
        deps.entries.deinit(allocator);
        allocator.free(deps.buckets);
    }
};

const Entry = struct {
    input_storage: [32]u8 align(16) = undefined,
    output_slots: [2][32]u8 align(16) = undefined,
    input_ptr: *anyopaque,
    output: ?QueryOutput,
    type_identity: *const TypeIdentity,
    key_hash: u64,
    err: ?anyerror,
    state: EntryState,
    verified_at: Revision,
    changed_at: Revision,
    last_failed_at: ?Revision = null,
    compute_fn: ComputeFn,
    destroy_input_fn: DestroyOpaqueFn,
    destroy_output_fn: DestroyOutputFn,
    output_eql_fn: EqlOpaqueFn,
    write_input_fn: WriteOpaqueFn,
    fingerprint_output_fn: ?FingerprintQueryFn,
    deps: DependencyMap,
    input_deps: std.ArrayList(*InputEntry),
    accums: ?*AccumBucket,
    // Set at commit so accumulator collection can skip clean subtrees.
    accums_in_subtree: bool,
    computation: ?Computation,
    verification_dependency: ?*Entry = null,
    finished: std.atomic.Value(u32) = .init(0),
    waiters: std.atomic.Value(u32) = .init(0),
    queue_owner: ?usize,
    queue_prev: ?*Entry,
    queue_next: ?*Entry,
    visit_token: usize,
};

const InputEntry = struct {
    key_ptr: *anyopaque,
    value_ptr: ?*anyopaque,
    changed_at: Revision,
    type_identity: *const TypeIdentity,
    destroy_key_fn: DestroyOpaqueFn,
    destroy_value_fn: DestroyOpaqueFn,
    write_key_fn: WriteOpaqueFn,
    fingerprint_fn: FingerprintFn,
};

const stopped_interns = std.math.maxInt(u64);
const lock_spin_attempts = 128;

const InternSlots = struct {
    previous: ?*InternSlots,
    slots: []std.atomic.Value(u32),

    fn create(allocator: std.mem.Allocator, previous: ?*InternSlots, count: usize) !*InternSlots {
        const table = try allocator.create(InternSlots);
        errdefer allocator.destroy(table);
        const slots = try allocator.alloc(std.atomic.Value(u32), count);
        @memset(slots, .init(0));
        table.* = .{ .previous = previous, .slots = slots };
        return table;
    }

    fn insert(table: *InternSlots, index: u32, hash: u64) void {
        const mask = table.slots.len - 1;
        var slot: usize = @as(usize, @truncate(hash)) & mask;
        while (table.slots[slot].raw != 0) slot = (slot + 1) & mask;
        table.slots[slot].store(index + 1, .release);
    }
};

const InternEntry = struct {
    type_identity: *const TypeIdentity,
    hash: u64,
    value_ptr: *anyopaque,
    destroy_value_fn: DestroyOpaqueFn,
    write_value_fn: WriteOpaqueFn,
};

const InternValues = struct {
    chunks: [27]?[*]InternEntry = @splat(null),
    len: usize = 0,

    const empty: InternValues = .{};

    fn chunkIndex(index: usize) usize {
        return std.math.log2_int(usize, index + 64) - 6;
    }

    fn at(values: *const InternValues, index: usize) *InternEntry {
        const chunk = chunkIndex(index);
        const capacity = @as(usize, 64) << @intCast(chunk);
        return &values.chunks[chunk].?[index + 64 - capacity];
    }

    fn ensureUnusedCapacity(values: *InternValues, allocator: std.mem.Allocator, additional: usize) !void {
        std.debug.assert(additional == 1);
        const chunk = chunkIndex(values.len);
        if (values.chunks[chunk] != null) return;
        const capacity = @as(usize, 64) << @intCast(chunk);
        values.chunks[chunk] = (try allocator.alloc(InternEntry, capacity)).ptr;
    }

    fn appendAssumeCapacity(values: *InternValues, entry: InternEntry) void {
        values.at(values.len).* = entry;
        values.len += 1;
    }

    fn deinit(values: *InternValues, allocator: std.mem.Allocator) void {
        for (values.chunks, 0..) |maybe_chunk, index| {
            if (maybe_chunk) |chunk| allocator.free(chunk[0 .. @as(usize, 64) << @intCast(index)]);
        }
        values.* = .empty;
    }
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
    thread_id: std.Thread.Id = undefined,
    queue: WorkQueue,
    scratch_arenas: std.ArrayList(std.heap.ArenaAllocator.State) = .empty,
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
        entry.queue_owner = null;
    }
};

fn workerMain(db: *Database, worker_index: usize) void {
    db.workers[worker_index].thread_id = std.Thread.getCurrentId();
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
    if (Database.settledLocked(db, entry)) return false;
    if (entry.visit_token == token) return false;
    entry.visit_token = token;

    if (entry.verification_dependency) |dep| {
        if (reachesVisit(db, dep, target, token)) return true;
    }

    const deps = if (entry.computation) |*computation|
        computation.deps.entries.items
    else if (entry.verified_at == db.revision)
        entry.deps.entries.items
    else
        &.{};
    for (deps) |dependency| {
        if (reachesVisit(db, dependency.entry, target, token)) return true;
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
    if (typeHasDecl(T, "eql")) return;
    if (@typeInfo(T) == .optional) {
        validateObservableType(@typeInfo(T).optional.child, label);
        return;
    }
    if (typeContainsPointer(T)) @compileError(label ++ " contains pointers and must define value equality");
}

fn typeHasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

fn typeContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |info| typeContainsPointer(info.child),
        .array => |info| typeContainsPointer(info.child),
        .error_union => |info| typeContainsPointer(info.payload),
        .@"struct" => |info| fieldsContainPointer(info.field_types),
        .@"union" => |info| fieldsContainPointer(info.field_types),
        else => false,
    };
}

fn fieldsContainPointer(comptime field_types: []const type) bool {
    for (field_types) |FieldType| {
        if (typeContainsPointer(FieldType)) return true;
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

inline fn cacheKey(comptime Owner: type, value_ptr: anytype, hash: u64, comptime equality: []const u8) ErasedKey {
    const Value = @typeInfo(@TypeOf(value_ptr)).pointer.child;
    return .{
        .type_identity = comptime typeIdentity(Owner),
        .hash = hash ^ typeHash(Owner),
        .value_ptr = value_ptr,
        .eql_fn = comptime erasedEqlFn(Value, if (@hasDecl(Owner, equality)) @field(Owner, equality) else std.meta.eql),
    };
}

fn typeIdentity(comptime Owner: type) *const TypeIdentity {
    return &struct {
        const value: TypeIdentity = .{ .name = @typeName(Owner) };
    }.value;
}

fn erasedEqlFn(comptime T: type, comptime equal: anytype) EqlOpaqueFn {
    return struct {
        fn eql(a_opaque: *const anyopaque, b_opaque: *const anyopaque) bool {
            const a: *const T = @ptrCast(@alignCast(a_opaque));
            const b: *const T = @ptrCast(@alignCast(b_opaque));
            return equal(a.*, b.*);
        }
    }.eql;
}

fn internId(comptime I: type, index: u32) I.Id {
    return @fromBackingInt(@intCast(index));
}

fn writeValueFn(comptime T: type) WriteOpaqueFn {
    return struct {
        fn write(writer: *disk_codec.Writer, ptr: *const anyopaque) anyerror!void {
            const value: *const T = @ptrCast(@alignCast(ptr));
            try writer.write(T, value.*);
        }
    }.write;
}

fn fingerprintQueryOutputFn(comptime Q: type) FingerprintQueryFn {
    return struct {
        fn fingerprint(allocator: std.mem.Allocator, ptr: *const anyopaque) anyerror![32]u8 {
            const output: *const Q.Output = @ptrCast(@alignCast(ptr));
            var writer: disk_codec.Writer = .{ .allocator = allocator };
            defer writer.deinit();
            try writer.write(Q.Output, output.*);
            var digest: [32]u8 = undefined;
            Sha256.hash(writer.bytes.items, &digest, .{});
            return digest;
        }
    }.fingerprint;
}

fn inputFingerprint(comptime I: type, allocator: std.mem.Allocator, value_ptr: ?*anyopaque) ![32]u8 {
    var writer: disk_codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.write(bool, value_ptr != null);
    if (value_ptr) |ptr| {
        const value: *const I.Value = @ptrCast(@alignCast(ptr));
        try writer.write(I.Value, value.*);
    }
    var digest: [32]u8 = undefined;
    Sha256.hash(writer.bytes.items, &digest, .{});
    return digest;
}

fn fingerprintInputFn(comptime I: type) FingerprintFn {
    return struct {
        fn fingerprint(allocator: std.mem.Allocator, value_ptr: ?*anyopaque) anyerror![32]u8 {
            return inputFingerprint(I, allocator, value_ptr);
        }
    }.fingerprint;
}

fn keyHash(comptime Owner: type, comptime hash: []const u8, value: anytype) u64 {
    if (@hasDecl(Owner, hash)) return @field(Owner, hash)(value);
    if (comptime typeHasDecl(@TypeOf(value), "hash")) return value.hash();
    switch (@typeInfo(@TypeOf(value))) {
        .int => |integer| {
            if (integer.bits <= 64) {
                const Unsigned = @Int(.unsigned, integer.bits);
                return std.hash.int(@as(u64, @as(Unsigned, @bitCast(value))) ^ typeHash(Owner));
            }
        },
        .@"enum" => return keyHash(Owner, hash, @backingInt(value)),
        else => {},
    }
    var hasher = std.hash.Wyhash.init(typeHash(Owner));
    std.hash.autoHash(&hasher, value);
    return hasher.final();
}

inline fn typeHash(comptime T: type) u64 {
    return comptime std.hash.Wyhash.hash(0, @typeName(T));
}

fn canCompactOutput(comptime T: type, comptime ancestors: anytype) bool {
    @setEvalBranchQuota(100_000);
    for (ancestors) |Ancestor| if (T == Ancestor) return true;
    const nested = ancestors ++ .{T};
    switch (@typeInfo(T)) {
        .pointer => |pointer| return pointer.size == .slice and canCompactOutput(pointer.child, nested),
        inline .array, .optional => |info| return canCompactOutput(info.child, nested),
        inline .@"struct", .@"union" => |info| {
            for (info.field_types) |Field| if (!canCompactOutput(Field, nested)) return false;
            return true;
        },
        .@"fn", .@"opaque", .error_union => return false,
        else => return true,
    }
}

fn computeFn(comptime Q: type) ComputeFn {
    return struct {
        fn compute(db: *Database, entry: *Entry, worker_index: ?usize) anyerror!QueryOutput {
            var computation: profiling.Scope = .{};
            computation.begin(db.profile, comptime profiling.queryCategory(Q));
            defer computation.end();
            const input_value: *const Q.Input = @ptrCast(@alignCast(entry.input_ptr));
            var scratch = db.acquireScratchArena(worker_index);
            defer db.releaseScratchArena(worker_index, &scratch);
            var recycler: RecyclingAllocator = .{ .backing = scratch.allocator() };
            var ctx: Context = .{
                .db = db,
                .current = entry,
                .worker_index = worker_index,
                .local_allocator = recycler.allocator(),
            };

            var output_value = try Q.run(&ctx, input_value.*);
            var output_transferred = false;
            defer if (!output_transferred) deinitTypedValue(Q.Output, scratch.allocator(), &output_value);

            // Spawned dependencies belong to this computation even when their
            // handles are discarded. Q.run decides which errors to propagate;
            // settling dependencies must not override errors it handled.
            for (entry.computation.?.deps.entries.items) |dependency| {
                if (dependency.output == null) db.waitForEntry(dependency.entry, worker_index) catch {};
            }

            if (comptime !typeContainsPointer(Q.Output) and @sizeOf(Q.Output) <= 32 and @alignOf(Q.Output) <= 16) {
                const first_slot: *anyopaque = @ptrCast(&entry.output_slots[0]);
                const slot: usize = if (entry.output != null and entry.output.?.pointer == first_slot) 1 else 0;
                const output_box: *Q.Output = @ptrCast(@alignCast(&entry.output_slots[slot]));
                output_box.* = output_value;
                output_transferred = true;
                return .{ .pointer = @ptrCast(output_box), .storage = .inline_value };
            }

            if (comptime !canCompactOutput(Q.Output, .{})) {
                const output_box = try scratch.allocator().create(Q.Output);
                output_box.* = output_value;
                output_transferred = true;
                const arena = scratch;
                scratch = .init(db.query_storage.arenaAllocator());
                return .{ .pointer = @ptrCast(output_box), .storage = .{ .arena = arena } };
            } else {
                var arena = std.heap.ArenaAllocator.init(db.query_storage.arenaAllocator());
                errdefer arena.deinit();
                const output_box = try arena.allocator().create(Q.Output);
                output_box.* = try value_operations.Owned(Q.Output).clone(arena.allocator(), output_value);
                output_transferred = true;
                return .{ .pointer = @ptrCast(output_box), .storage = .{ .arena = arena } };
            }
        }
    }.compute;
}

fn outputEqlFn(comptime Q: type) EqlOpaqueFn {
    return erasedEqlFn(Q.Output, if (@hasDecl(Q, "eqlOutput")) Q.eqlOutput else valueEql);
}

fn valueEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (comptime typeHasDecl(T, "eql")) return T.eql(a, b);
    if (comptime @typeInfo(T) == .optional) {
        if (a == null or b == null) return a == null and b == null;
        return valueEql(a.?, b.?);
    }
    return std.meta.eql(a, b);
}

fn accumListEqlFn(comptime A: type) EqlOpaqueFn {
    return erasedEqlFn(std.ArrayList(A), struct {
        fn eql(a: std.ArrayList(A), b: std.ArrayList(A)) bool {
            if (a.items.len != b.items.len) return false;
            for (a.items, b.items) |left, right| if (!valueEql(left, right)) return false;
            return true;
        }
    }.eql);
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

fn destroyInputValueFn(comptime I: type) DestroyOpaqueFn {
    return destroyBoxFn(I.Value, struct {
        fn deinit(gpa: std.mem.Allocator, value: *I.Value) void {
            deinitInputValue(I, gpa, value);
        }
    }.deinit);
}

fn destroyOutputFn(comptime T: type) DestroyOutputFn {
    return struct {
        fn destroy(allocator: std.mem.Allocator, ptr: *anyopaque, boxed: bool) void {
            const value: *T = @ptrCast(@alignCast(ptr));
            deinitTypedValue(T, allocator, value);
            if (boxed) allocator.destroy(value);
        }
    }.destroy;
}

fn deinitInlineBoxFn(comptime T: type) DestroyOpaqueFn {
    return struct {
        fn deinit(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const value: *T = @ptrCast(@alignCast(ptr));
            deinitTypedValue(T, allocator, value);
        }
    }.deinit;
}

fn destroyBoxFn(comptime T: type, comptime cleanup: anytype) DestroyOpaqueFn {
    return struct {
        fn destroy(gpa: std.mem.Allocator, ptr: *anyopaque) void {
            const typed: *T = @ptrCast(@alignCast(ptr));
            if (comptime @TypeOf(cleanup) != @TypeOf(null)) cleanup(gpa, typed);
            gpa.destroy(typed);
        }
    }.destroy;
}

fn deinitBoxValue(gpa: std.mem.Allocator, value: anytype) void {
    deinitTypedValue(@typeInfo(@TypeOf(value)).pointer.child, gpa, value);
}

fn destroyAccumListFn(comptime A: type) DestroyOpaqueFn {
    return destroyBoxFn(std.ArrayList(A), struct {
        fn deinit(gpa: std.mem.Allocator, list: *std.ArrayList(A)) void {
            for (list.items) |*item| deinitTypedValue(A, gpa, item);
            list.deinit(gpa);
        }
    }.deinit);
}

fn cloneAccumValue(comptime A: type, gpa: std.mem.Allocator, value: A) !A {
    if (comptime typeHasDecl(A, "clone")) return A.clone(gpa, value);
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
