const std = @import("std");
const artifact = @import("query_artifact.zig");
const codec = @import("query/codec.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const disk_cache = @import("query_disk_cache.zig");
const modules = @import("modules.zig");
const structures = @import("structures.zig");
const value_operations = @import("value.zig");
const standard_library = @import("standard_library");

const format = "CHISTD02";
const Files = [standard_library.paths.len]structures.FileId;

const Table = struct {
    index: []const u8 = &.{},
    data: []const u8 = &.{},
};

/// Build a seekable bundle from validated portable query records. Dependency
/// values become a closed-source fact and a per-record set of variant ABIs.
pub fn encode(db: *query.Database, allocator: std.mem.Allocator) ![]u8 {
    const portable = try artifact.encode(db, allocator);
    defer allocator.free(portable);
    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    var reader: codec.Reader = .{ .allocator = scratch.allocator(), .bytes = portable };
    std.debug.assert(std.mem.eql(u8, try reader.take(artifact.format.len), artifact.format));
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.bytes.appendSlice(allocator, format);
    const files_start = reader.offset;
    const file_count = try reader.read(u64);
    for (0..file_count) |_| {
        _ = try reader.read(structures.FileId);
        _ = try reader.read([]const u8);
    }
    try writer.bytes.appendSlice(allocator, portable[files_start..reader.offset]);
    const intern_count = try reader.read(u64);
    var index: codec.Writer = .{ .allocator = allocator };
    defer index.deinit();
    var data: codec.Writer = .{ .allocator = allocator };
    defer data.deinit();
    for (0..intern_count) |_| {
        defer _ = scratch.reset(.retain_capacity);
        const kind = try reader.read(u8);
        const start = reader.offset;
        var found = false;
        inline for (disk_cache.interners, 0..) |I, interner_index| {
            if (kind == interner_index) {
                // Decode only to find the end of this producer-owned value.
                _ = try reader.read(I.Value);
                found = true;
                break;
            }
        }
        std.debug.assert(found);
        try index.write(u8, kind);
        try index.write(u64, @intCast(data.bytes.items.len));
        try index.write(u64, @intCast(reader.offset - start));
        try data.bytes.appendSlice(allocator, portable[start..reader.offset]);
    }
    try writeTable(&writer, intern_count, &index, &data);
    inline for (Loader.query_types) |Q| try encodeRecords(Q, db, &reader, &writer, &scratch);
    std.debug.assert(reader.finished());
    return writer.bytes.toOwnedSlice(allocator);
}

fn encodeRecords(comptime Q: type, db: *query.Database, reader: *codec.Reader, writer: *codec.Writer, scratch: *std.heap.ArenaAllocator) !void {
    const count = try reader.read(u64);
    const Row = struct { digest: [32]u8, offset: u64, length: u64 };
    const rows = try writer.allocator.alloc(Row, @intCast(count));
    defer writer.allocator.free(rows);
    var index: codec.Writer = .{ .allocator = writer.allocator };
    defer index.deinit();
    var data: codec.Writer = .{ .allocator = writer.allocator };
    defer data.deinit();
    for (rows) |*row| {
        defer _ = scratch.reset(.retain_capacity);
        const key = try reader.read(Q.Input);
        const length: usize = @intCast(try reader.read(u64));
        var record: codec.Reader = .{ .allocator = reader.allocator, .bytes = try reader.take(length) };
        const output = try record.read(Q.Output);
        var variants: Variants = .{ .db = db, .allocator = reader.allocator };
        try variants.collect(Q.Input, key);
        try variants.collect(Q.Output, output);
        try variants.dependencies(true, disk_cache.persisted_inputs, &record);
        try variants.dependencies(false, disk_cache.persisted_query_dependencies, &record);
        std.debug.assert(record.finished());
        const start = data.bytes.items.len;
        try data.write(Q.Input, key);
        try data.write([]const structures.InternedTypeId, variants.types.keys());
        try data.write(Q.Output, output);
        row.* = .{
            .digest = try logicalDigest(db, reader.allocator, Q.Input, key),
            .offset = @intCast(start),
            .length = @intCast(data.bytes.items.len - start),
        };
    }
    std.mem.sort(Row, rows, {}, struct {
        fn lessThan(_: void, left: Row, right: Row) bool {
            return std.mem.order(u8, &left.digest, &right.digest) == .lt;
        }
    }.lessThan);
    for (rows) |row| try index.write(Row, row);
    try writeTable(writer, count, &index, &data);
}

fn writeTable(writer: *codec.Writer, count: u64, index: *const codec.Writer, data: *const codec.Writer) !void {
    try writer.write(u64, count);
    try writer.write(u64, @intCast(data.bytes.items.len));
    try writer.bytes.appendSlice(writer.allocator, index.bytes.items);
    try writer.bytes.appendSlice(writer.allocator, data.bytes.items);
}

const Variants = struct {
    db: *query.Database,
    allocator: std.mem.Allocator,
    seen: std.AutoHashMapUnmanaged(u32, void) = .empty,
    types: std.AutoArrayHashMapUnmanaged(structures.InternedTypeId, void) = .empty,

    fn collect(self: *Variants, comptime T: type, value: T) anyerror!void {
        inline for (disk_cache.interners) |I| {
            if (T == I.Id) {
                if ((try self.seen.getOrPut(self.allocator, @backingInt(value))).found_existing) return;
                const interned = try self.db.lookupInterned(I, value);
                if (I == queries.Types and interned.* == .variant) try self.types.put(self.allocator, value, {});
                return self.collect(I.Value, interned.*);
            }
        }
        if (T == structures.TypeId) {
            if (value.interned()) |id| try self.collect(structures.InternedTypeId, id);
            return;
        }
        switch (@typeInfo(T)) {
            .optional => |info| if (value) |present| try self.collect(info.child, present),
            .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (!attrs.@"comptime") try self.collect(Field, @field(value, name));
            },
            .@"union" => switch (value) {
                inline else => |payload| try self.collect(@TypeOf(payload), payload),
            },
            .array => |info| for (value) |element| try self.collect(info.child, element),
            .pointer => |info| if (info.child != u8) {
                for (value) |element| try self.collect(info.child, element);
            },
            else => {},
        }
    }

    fn dependencies(self: *Variants, comptime inputs: bool, comptime candidates: anytype, reader: *codec.Reader) !void {
        const count = try reader.read(u64);
        for (0..count) |_| {
            const kind = try reader.read(u8);
            var found = false;
            inline for (candidates, 0..) |Owner, index| {
                if (kind == index) {
                    const Key = if (inputs) Owner.Key else Owner.Input;
                    const Value = if (inputs) ?Owner.Value else Owner.Output;
                    try self.collect(Key, try reader.read(Key));
                    try self.collect(Value, try reader.read(Value));
                    found = true;
                    break;
                }
            }
            std.debug.assert(found);
        }
    }
};

/// The database owns the loader after installation. The bytes must outlive it.
/// Installation indexes byte ranges; function outputs and identities decode only
/// when a matching query runs. Workers share remapping under the loader mutex.
pub fn install(db: *query.Database, bytes: []const u8) !*Loader {
    const loader = try db.allocator.create(Loader);
    loader.* = .{ .db = db, .identities = .{ .allocator = db.allocator } };
    errdefer loader.deinit();
    var reader: codec.Reader = .{ .allocator = db.allocator, .bytes = bytes };
    if (!std.mem.eql(u8, try reader.take(format.len), format)) return error.InvalidCache;
    const file_count = try readCount(&reader);
    for (0..file_count) |_| {
        const file = try reader.read(structures.FileId);
        const path = try readBytes(&reader);
        var standard_index: ?usize = null;
        for (modules.standard_sources, 0..) |source, index| {
            if (std.mem.eql(u8, source.registry_path, path)) standard_index = index;
        }
        try loader.files.put(db.allocator, file, standard_index);
    }
    loader.interns = try readTable(&reader, 17);
    try loader.identities.interns.resize(db.allocator, loader.interns.index.len / 17);
    loader.resetIdentities();
    loader.bodies = try readTable(&reader, 48);
    loader.functions = try readTable(&reader, 48);
    if (!reader.finished()) return error.InvalidCache;
    try db.installMemoProvider(Loader, loader);
    return loader;
}

pub const Loader = struct {
    pub const query_types = .{ queries.AnalyzeFunctionInstance, queries.CompileFunction };
    db: *query.Database,
    mutex: std.Io.Mutex = .init,
    files: std.AutoHashMapUnmanaged(structures.FileId, ?usize) = .empty,
    interns: Table = .{},
    identities: artifact.Identities,
    current_files: ?Files = null,
    bodies: Table = .{},
    functions: Table = .{},
    loaded: artifact.ImportResult = .{},

    pub fn deinit(self: *Loader) void {
        const allocator = self.db.allocator;
        self.files.deinit(allocator);
        self.identities.deinit();
        allocator.destroy(self);
    }

    pub fn stats(self: *Loader) artifact.ImportResult {
        self.mutex.lockUncancelable(self.db.io());
        defer self.mutex.unlock(self.db.io());
        return self.loaded;
    }

    fn resetIdentities(self: *Loader) void {
        @memset(self.identities.interns.items, .{ .id = null, .compatible = true, .interner = 0, .ready = false });
    }

    pub fn load(self: *Loader, comptime Q: type, ctx: *query.Context, key: Q.Input) anyerror!?Q.Output {
        const location = try ctx.lookupInterned(queries.ItemLocations, key.item);
        if (location.origin != .module) return null;
        const module = try ctx.lookupInterned(queries.ModulePaths, location.origin.module);
        if (!std.mem.eql(u8, module.path, "std") and !std.mem.startsWith(u8, module.path, "std.")) return null;
        const digest = try logicalDigest(ctx.db, ctx.allocator(), Q.Input, key);
        const records = if (Q == queries.AnalyzeFunctionInstance) self.bodies else self.functions;
        const record = (try findRecord(records, digest)) orelse return null;
        // Validate before taking the loader lock: this is an ordinary query
        // dependency and can itself need work on another worker.
        const files = (try ctx.get(queries.StandardLibraryUnchanged, {})).* orelse return null;
        self.mutex.lockUncancelable(self.db.io());
        defer self.mutex.unlock(self.db.io());
        if (self.current_files == null or !std.mem.eql(structures.FileId, &self.current_files.?, &files)) {
            self.resetIdentities();
            var paths = self.files.iterator();
            while (paths.next()) |entry| {
                const file: ?structures.FileId = if (entry.value_ptr.*) |index| files[index] else null;
                try self.identities.files.put(self.db.allocator, entry.key_ptr.*, file);
            }
            self.current_files = files;
        }
        var demand: Demand = .{ .loader = self, .allocator = ctx.allocator() };
        self.identities.resolver = .{ .context = &demand, .resolve = Demand.resolve };
        defer self.identities.resolver = null;
        self.identities.reset();
        var reader: codec.Reader = .{ .allocator = ctx.allocator(), .bytes = record };
        var translated = try reader.read(Q.Input);
        try self.identities.translate(Q.Input, &translated);
        if (!self.identities.available or !self.identities.compatible) return null;
        if (!value_operations.equal(Q.Input, translated, key)) return error.InvalidCache;
        const variants = try reader.read([]const structures.InternedTypeId);
        for (@constCast(variants)) |*variant| try self.identities.translate(structures.InternedTypeId, variant);
        if (!self.identities.available or !self.identities.compatible) return null;
        var output = try reader.read(Q.Output);
        try self.identities.translate(Q.Output, &output);
        if (!reader.finished() or output == null) return error.InvalidCache;
        if (!self.identities.available or !self.identities.compatible) return null;
        if (Q == queries.AnalyzeFunctionInstance) self.loaded.bodies += 1 else self.loaded.functions += 1;
        return output;
    }
};

const Demand = struct {
    loader: *Loader,
    allocator: std.mem.Allocator,

    fn resolve(pointer: *anyopaque, identities: *artifact.Identities, index: usize) anyerror!artifact.Identity {
        const self: *Demand = @ptrCast(@alignCast(pointer));
        var slot: codec.Reader = .{ .allocator = self.allocator, .bytes = self.loader.interns.index[index * 17 ..][0..17] };
        const kind = try slot.read(u8);
        var reader: codec.Reader = .{ .allocator = self.allocator, .bytes = try tableValue(self.loader.interns, &slot) };
        const limit = identities.intern_limit;
        identities.intern_limit = index;
        defer identities.intern_limit = limit;
        const identity = try artifact.readIntern(self.loader.db, &reader, identities, kind);
        if (!reader.finished()) return error.InvalidCache;
        return identity;
    }
};

fn logicalDigest(db: *query.Database, allocator: std.mem.Allocator, comptime T: type, value: T) ![32]u8 {
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writeLogical(db, T, value, &writer);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(writer.bytes.items, &digest, .{});
    return digest;
}

fn writeLogical(db: *query.Database, comptime T: type, value: T, writer: *codec.Writer) anyerror!void {
    inline for (disk_cache.interners, 0..) |I, index| {
        if (T == I.Id) {
            try writer.write(u8, @intCast(index));
            return writeLogical(db, I.Value, (try db.lookupInterned(I, value)).*, writer);
        }
    }
    if (T == structures.TypeId) {
        try writer.write(bool, value.interned() != null);
        if (value.interned()) |id| return writeLogical(db, structures.InternedTypeId, id, writer);
        return writer.write(u32, @backingInt(value));
    }
    if (T == structures.ItemLoc) {
        try writer.write(bool, value.origin == .module);
        if (value.origin == .module) {
            try writeLogical(db, structures.ModuleId, value.origin.module, writer);
        } else try writer.write([]const u8, (try db.input(queries.SourcePath, value.origin.entry)).*);
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, Field| {
            if (comptime !std.mem.eql(u8, name, "origin")) try writeLogical(db, Field, @field(value, name), writer);
        }
        return;
    }
    if (T == structures.Name and value == .converter) {
        try writer.write(std.meta.Tag(T), std.meta.activeTag(value));
        try writer.write([]const u8, (try db.input(queries.SourcePath, value.converter.file_id)).*);
        return writer.write(u32, value.converter.ordinal);
    }
    switch (@typeInfo(T)) {
        .optional => |info| {
            try writer.write(bool, value != null);
            if (value) |present| try writeLogical(db, info.child, present, writer);
        },
        .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
            if (!attrs.@"comptime") try writeLogical(db, Field, @field(value, name), writer);
        },
        .@"union" => {
            try writer.write(std.meta.Tag(T), std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| try writeLogical(db, @TypeOf(payload), payload, writer),
            }
        },
        .array => |info| for (value) |element| try writeLogical(db, info.child, element, writer),
        .pointer => |info| {
            if (info.child == u8) return writer.write(T, value);
            try writer.write(u64, @intCast(value.len));
            for (value) |element| try writeLogical(db, info.child, element, writer);
        },
        else => try writer.write(T, value),
    }
}

fn readBytes(reader: *codec.Reader) ![]const u8 {
    const length = std.math.cast(usize, try reader.read(u64)) orelse return error.InvalidCache;
    return reader.take(length);
}

fn readCount(reader: *codec.Reader) !usize {
    const count = try reader.read(u64);
    if (count > 1_000_000 or count > reader.bytes.len - reader.offset) return error.InvalidCache;
    return @intCast(count);
}

fn readTable(reader: *codec.Reader, stride: usize) !Table {
    const count = try readCount(reader);
    const length = std.math.cast(usize, try reader.read(u64)) orelse return error.InvalidCache;
    return .{ .index = try reader.take(count * stride), .data = try reader.take(length) };
}

fn tableValue(table: Table, slot: *codec.Reader) ![]const u8 {
    const offset = std.math.cast(usize, try slot.read(u64)) orelse return error.InvalidCache;
    const length = std.math.cast(usize, try slot.read(u64)) orelse return error.InvalidCache;
    var reader: codec.Reader = .{ .allocator = slot.allocator, .bytes = table.data, .offset = offset };
    return reader.take(length);
}

fn findRecord(table: Table, digest: [32]u8) !?[]const u8 {
    var start: usize = 0;
    var end = table.index.len / 48;
    while (start < end) {
        const index = start + (end - start) / 2;
        const row = table.index[index * 48 ..][0..48];
        switch (std.mem.order(u8, &digest, row[0..32])) {
            .eq => {
                var slot: codec.Reader = .{ .allocator = undefined, .bytes = row[32..] };
                return try tableValue(table, &slot);
            },
            .lt => end = index,
            .gt => start = index + 1,
        }
    }
    return null;
}
