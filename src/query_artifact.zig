const std = @import("std");
const codec = @import("query/codec.zig");
const query = @import("query/engine.zig");
const queries = @import("queries.zig");
const disk_cache = @import("query_disk_cache.zig");
const modules = @import("modules.zig");
const structures = @import("structures.zig");

pub const format = "CHIART04";
const max_records = 1_000_000;

pub const ImportResult = struct {
    bodies: usize = 0,
    functions: usize = 0,
};

/// The caller owns the encoded artifact. Unlike a project snapshot, it can be
/// loaded after unrelated files, declarations, and types have been registered.
pub fn encode(db: *query.Database, allocator: std.mem.Allocator) ![]u8 {
    var writer: codec.Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.bytes.appendSlice(allocator, format);
    try db.writeInputs(queries.SourcePath, &writer);
    try db.writePortableInterns(&writer, disk_cache.interners);
    try db.writePortableQueries(queries.AnalyzeFunctionInstance, &writer, disk_cache.persisted_inputs, disk_cache.persisted_query_dependencies);
    try db.writePortableQueries(queries.CompileFunction, &writer, disk_cache.persisted_inputs, disk_cache.persisted_query_dependencies);
    return writer.bytes.toOwnedSlice(allocator);
}

pub fn restore(db: *query.Database, payload: []const u8, registry: *const modules.SourceRegistry) !ImportResult {
    var scratch = std.heap.ArenaAllocator.init(db.allocator);
    defer scratch.deinit();
    var reader: codec.Reader = .{ .allocator = scratch.allocator(), .bytes = payload };
    if (!std.mem.eql(u8, try reader.take(format.len), format)) return error.InvalidCache;
    var identities: Identities = .{ .allocator = db.allocator };
    defer identities.deinit();
    const file_count = try readCount(&reader);
    for (0..file_count) |_| {
        defer _ = scratch.reset(.retain_capacity);
        const original = try reader.read(structures.FileId);
        const path = try reader.read([]const u8);
        defer reader.allocator.free(path);
        const current = registry.fileId(path) orelse if (std.mem.eql(u8, path, registry.entry_path)) @as(?structures.FileId, 0) else null;
        const entry = try identities.files.getOrPut(db.allocator, original);
        if (entry.found_existing) return error.InvalidCache;
        entry.value_ptr.* = current;
    }
    const intern_count = try readCount(&reader);
    try identities.interns.ensureTotalCapacity(db.allocator, intern_count);
    for (0..intern_count) |_| {
        defer _ = scratch.reset(.retain_capacity);
        identities.interns.appendAssumeCapacity(try readIntern(db, &reader, &identities, try reader.read(u8)));
    }
    var compatible = true;
    for (identities.interns.items) |identity| compatible = compatible and identity.compatible;
    const result: ImportResult = .{
        .bodies = try restoreRecords(queries.AnalyzeFunctionInstance, db, &reader, &identities, &scratch, compatible),
        .functions = try restoreRecords(queries.CompileFunction, db, &reader, &identities, &scratch, compatible),
    };
    if (!reader.finished()) return error.InvalidCache;
    return result;
}

pub const Identity = struct {
    id: ?u32,
    compatible: bool,
    interner: usize,
    ready: bool = true,
};

pub const Identities = struct {
    allocator: std.mem.Allocator,
    files: std.AutoHashMapUnmanaged(structures.FileId, ?structures.FileId) = .empty,
    interns: std.ArrayList(Identity) = .empty,
    available: bool = true,
    compatible: bool = true,
    intern_limit: usize = std.math.maxInt(usize),
    resolver: ?struct {
        context: *anyopaque,
        resolve: *const fn (*anyopaque, *Identities, usize) anyerror!Identity,
    } = null,

    pub fn deinit(self: *Identities) void {
        self.files.deinit(self.allocator);
        self.interns.deinit(self.allocator);
    }

    pub fn reset(self: *Identities) void {
        self.available = true;
        self.compatible = true;
    }

    fn file(self: *Identities, original: structures.FileId) !structures.FileId {
        const mapped = self.files.get(original) orelse return error.InvalidCache;
        if (mapped) |id| return id;
        self.available = false;
        return 0;
    }

    fn intern(self: *Identities, comptime T: type, original: T) !T {
        const index = @backingInt(original);
        if (index >= self.interns.items.len or index >= self.intern_limit) return error.InvalidCache;
        if (!self.interns.items[index].ready) {
            const resolver = self.resolver orelse return error.InvalidCache;
            self.interns.items[index] = try resolver.resolve(resolver.context, self, index);
        }
        const identity = self.interns.items[index];
        inline for (disk_cache.interners, 0..) |I, interner| {
            if (T == I.Id and identity.interner != interner) return error.InvalidCache;
        }
        self.compatible = self.compatible and identity.compatible;
        if (identity.id) |id| return @fromBackingInt(@intCast(id));
        self.available = false;
        return @fromBackingInt(0);
    }

    /// Only decoded owned values are mutated. Numeric source offsets, SSA
    /// indices, variant tags, and relocation indices retain their own domains.
    pub fn translate(self: *Identities, comptime T: type, value: *T) anyerror!void {
        if (T == u8) return;
        inline for (disk_cache.interners) |I| {
            if (T == I.Id) {
                value.* = try self.intern(T, value.*);
                return;
            }
        }
        if (T == structures.TypeId) {
            if (value.interned()) |original| {
                value.* = .fromInterned(try self.intern(structures.InternedTypeId, original));
            } else if (!value.isPrimitive()) return error.InvalidCache;
            return;
        }
        if (T == structures.ItemLoc) {
            if (value.origin == .entry) value.origin.entry = try self.file(value.origin.entry);
        }
        if (T == structures.ResolvedItem) value.file_id = try self.file(value.file_id);
        if (T == structures.Name and value.* == .converter) value.converter.file_id = try self.file(value.converter.file_id);
        switch (@typeInfo(T)) {
            .optional => |info| if (value.*) |*present| try self.translate(info.child, present),
            .@"struct" => |info| inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
                if (!attrs.@"comptime") {
                    try self.translate(Field, &@field(value, name));
                }
            },
            .@"union" => switch (value.*) {
                inline else => |*payload| try self.translate(@TypeOf(payload.*), payload),
            },
            .array => |info| for (value) |*element| try self.translate(info.child, element),
            .pointer => |info| {
                if (info.child != u8) for (@constCast(value.*)) |*element| try self.translate(info.child, element);
            },
            else => {},
        }
        if (T == structures.ModuleItemIndex) {
            std.mem.sort(structures.ModuleItemIndex.Entry, @constCast(value.entries), {}, struct {
                fn lessThan(_: void, left: structures.ModuleItemIndex.Entry, right: structures.ModuleItemIndex.Entry) bool {
                    return @backingInt(left.item) < @backingInt(right.item);
                }
            }.lessThan);
        }
        if (T == structures.ModuleScope) {
            std.mem.sort(structures.ModuleScope.Entry, @constCast(value.entries), {}, struct {
                fn lessThan(_: void, a: structures.ModuleScope.Entry, b: structures.ModuleScope.Entry) bool {
                    return structures.Name.order(a.name, b.name) == .lt;
                }
            }.lessThan);
        }
    }

    fn key(self: *Identities, comptime Owner: type, value: anytype) !void {
        if (Owner == queries.SourceText or Owner == queries.SourcePath or Owner == queries.FileModule or Owner == queries.BuildModuleScope) {
            value.* = try self.file(value.*);
        } else try self.translate(@TypeOf(value.*), value);
    }

    fn inputValue(self: *Identities, comptime I: type, value: *?I.Value) !void {
        if (value.*) |*present| {
            if (I == queries.ModuleMembers) {
                for (@constCast(present.*)) |*file_id| file_id.* = try self.file(file_id.*);
                std.mem.sort(structures.FileId, @constCast(present.*), {}, std.sort.asc(structures.FileId));
            } else if (I == queries.StandardFile) {
                present.* = try self.file(present.*);
            } else {
                try self.translate(I.Value, present);
                if (I == queries.ModuleCatalog) std.mem.sort(structures.ModuleId, @constCast(present.*), {}, struct {
                    fn lessThan(_: void, a: structures.ModuleId, b: structures.ModuleId) bool {
                        return @backingInt(a) < @backingInt(b);
                    }
                }.lessThan);
            }
        }
    }
};

pub fn readIntern(db: *query.Database, reader: *codec.Reader, identities: *Identities, kind: u8) !Identity {
    const available = identities.available;
    const compatible = identities.compatible;
    defer {
        identities.available = available;
        identities.compatible = compatible;
    }
    inline for (disk_cache.interners, 0..) |I, interner| {
        if (kind == interner) {
            var value = try reader.read(I.Value);
            defer codec.freeValue(I.Value, reader.allocator, &value);
            identities.reset();
            try identities.translate(I.Value, &value);
            if (I == queries.Types and value == .variant) {
                const members = @constCast(value.variant.members);
                if (members.len < 2) return error.InvalidCache;
                for (members[1..], members[0 .. members.len - 1]) |member, previous| {
                    if (@backingInt(previous) >= @backingInt(member)) identities.compatible = false;
                }
                std.mem.sort(structures.TypeId, members, {}, struct {
                    fn lessThan(_: void, a: structures.TypeId, b: structures.TypeId) bool {
                        return @backingInt(a) < @backingInt(b);
                    }
                }.lessThan);
            }
            const id: ?u32 = if (identities.available) @intCast(@backingInt(try disk_cache.importIntern(I, db, value))) else null;
            return .{ .id = id, .compatible = identities.compatible, .interner = interner };
        }
    }
    return error.InvalidCache;
}

fn restoreRecords(comptime Q: type, db: *query.Database, stream: *codec.Reader, identities: *Identities, scratch: *std.heap.ArenaAllocator, compatible: bool) !usize {
    const count = try readCount(stream);
    var imported: usize = 0;
    for (0..count) |_| {
        defer _ = scratch.reset(.retain_capacity);
        var key = try stream.read(Q.Input);
        const length = std.math.cast(usize, try stream.read(u64)) orelse return error.InvalidCache;
        var record: codec.Reader = .{ .allocator = stream.allocator, .bytes = try stream.take(length) };
        // Native code and typed tag tables retain the producer's variant ABI.
        // This also covers snapshots of results originally loaded from std.
        if (!compatible) continue;
        const reader = &record;
        var output = try reader.read(Q.Output);
        defer codec.freeValue(Q.Output, reader.allocator, &output);
        identities.reset();
        try identities.translate(Q.Input, &key);
        try identities.translate(Q.Output, &output);
        if (output == null) return error.InvalidCache;
        var valid = identities.available and identities.compatible;
        if (valid) valid = try disk_cache.validateIds(Q.Input, db, key) and try disk_cache.validateIds(Q.Output, db, output);
        var inputs: std.ArrayList(query.PersistedInputRef) = .empty;
        defer inputs.deinit(reader.allocator);
        var dependencies: std.ArrayList(query.PersistedQueryRef) = .empty;
        defer dependencies.deinit(reader.allocator);
        try restoreDependencies(query.PersistedInputRef, disk_cache.persisted_inputs, db, reader, identities, &valid, &inputs);
        try restoreDependencies(query.PersistedQueryRef, disk_cache.persisted_query_dependencies, db, reader, identities, &valid, &dependencies);
        if (!reader.finished()) return error.InvalidCache;
        if (!valid) continue;
        if (!try disk_cache.validOutput(Q, db, output)) return error.InvalidCache;
        try db.importQueryCopy(Q, key, output, inputs.items, dependencies.items);
        imported += 1;
    }
    return imported;
}

fn restoreDependencies(comptime Ref: type, comptime candidates: anytype, db: *query.Database, reader: *codec.Reader, identities: *Identities, valid: *bool, matched: *std.ArrayList(Ref)) !void {
    const count = try readCount(reader);
    for (0..count) |_| {
        const kind = try reader.read(u8);
        var found = false;
        inline for (candidates, 0..) |Owner, index| {
            if (kind == index) {
                found = true;
                const is_input = Ref == query.PersistedInputRef;
                const Key = if (is_input) Owner.Key else Owner.Input;
                const Value = if (is_input) ?Owner.Value else Owner.Output;
                var key = try reader.read(Key);
                var expected = try reader.read(Value);
                defer codec.freeValue(Value, reader.allocator, &expected);
                identities.reset();
                try identities.key(Owner, &key);
                if (is_input) {
                    try identities.inputValue(Owner, &expected);
                } else if (Owner == queries.StandardLibraryUnchanged) {
                    if (expected) |*files| for (files) |*file| {
                        file.* = try identities.file(file.*);
                    };
                } else try identities.translate(Value, &expected);
                valid.* = valid.* and identities.available and identities.compatible;
                if (valid.*) {
                    const digest = try query.fingerprint(Value, reader.allocator, expected);
                    const dependency = if (is_input) try db.matchPersistedInput(Owner, key, digest) else try db.matchPersistedQuery(Owner, key, digest);
                    if (dependency) |entry| {
                        try matched.append(reader.allocator, entry);
                    } else {
                        valid.* = false;
                    }
                }
                break;
            }
        }
        if (!found) return error.InvalidCache;
    }
}

fn readCount(reader: *codec.Reader) !usize {
    const count = try reader.read(u64);
    if (count > max_records or count > reader.bytes.len - reader.offset) return error.InvalidCache;
    return @intCast(count);
}
