const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const diagnostics = @import("diagnostics.zig");

const CacheExt = ".qcache";
const Magic: [8]u8 = .{ 'X', '8', '6', 'Q', 'C', 'A', 'C', 'H' };
const SchemaVersion: u32 = 1;
const CompilerAbiVersion: u32 = 1;

pub const CacheOptions = struct {
    cache_dir_override: ?[]const u8 = null,
};

pub const StageSnapshot = struct {
    changed_at: db.Revision,
    has_value: bool,
    diagnostics: []const diagnostics.Diagnostic,
};

pub const CompileStageSnapshot = struct {
    changed_at: db.Revision,
    has_value: bool,
    diagnostics: []const diagnostics.Diagnostic,
    bytes: ?[]const u8,
};

pub const SavePayload = struct {
    source_path: []const u8,
    source_text: []const u8,
    parse: StageSnapshot,
    resolve: StageSnapshot,
    typecheck: StageSnapshot,
    monomorphize: StageSnapshot,
    lower: StageSnapshot,
    compile: CompileStageSnapshot,
};

pub const LoadedStage = struct {
    changed_at: db.Revision,
    has_value: bool,
    diagnostics: std.ArrayList(diagnostics.Diagnostic),
};

pub const LoadedCompile = struct {
    changed_at: db.Revision,
    has_value: bool,
    diagnostics: std.ArrayList(diagnostics.Diagnostic),
    bytes: ?[]const u8,
};

pub const LoadPayload = struct {
    backing: []u8,
    parse: LoadedStage,
    resolve: LoadedStage,
    typecheck: LoadedStage,
    monomorphize: LoadedStage,
    lower: LoadedStage,
    compile: LoadedCompile,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.parse.diagnostics.deinit(gpa);
        self.resolve.diagnostics.deinit(gpa);
        self.typecheck.diagnostics.deinit(gpa);
        self.monomorphize.diagnostics.deinit(gpa);
        self.lower.diagnostics.deinit(gpa);
        self.compile.diagnostics.deinit(gpa);
        gpa.free(self.backing);
    }
};

const LoadError = error{
    InvalidMagic,
    InvalidSchema,
    InvalidCompiler,
    Truncated,
    InvalidData,
} || std.mem.Allocator.Error;

fn splitDirAndName(path: []const u8) struct { dir: []const u8, name: []const u8 } {
    const maybe_dir = std.fs.path.dirname(path);
    return .{
        .dir = maybe_dir orelse ".",
        .name = std.fs.path.basename(path),
    };
}

fn hasCacheExtension(name: []const u8) bool {
    return std.mem.endsWith(u8, name, CacheExt);
}

pub fn sourceHash(source_text: []const u8) u64 {
    return std.hash.Wyhash.hash(0, source_text);
}

pub fn compilerFingerprint() u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(builtin.zig_version_string);
    hasher.update("x86-query-cache");
    var abi_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &abi_bytes, CompilerAbiVersion, .little);
    hasher.update(&abi_bytes);
    return hasher.final();
}

fn cachePathForSource(gpa: std.mem.Allocator, source_path: []const u8, options: CacheOptions) ![]u8 {
    if (options.cache_dir_override) |override_dir| {
        const key_hash = std.hash.Wyhash.hash(0, source_path);
        return std.fmt.allocPrint(gpa, "{s}{c}{x}{s}", .{ override_dir, std.fs.path.sep, key_hash, CacheExt });
    }
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ source_path, CacheExt });
}

fn stageTagByte(stage: diagnostics.Stage) u8 {
    return @intFromEnum(stage);
}

fn stageFromByte(byte: u8) !diagnostics.Stage {
    return switch (byte) {
        stageTagByte(.parse) => .parse,
        stageTagByte(.resolve) => .resolve,
        stageTagByte(.typecheck) => .typecheck,
        stageTagByte(.monomorphize) => .monomorphize,
        stageTagByte(.lower) => .lower,
        stageTagByte(.compile) => .compile,
        else => error.InvalidData,
    };
}

fn appendU8(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u8) !void {
    try buf.append(gpa, value);
}

fn appendU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendU64(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try buf.appendSlice(gpa, &bytes);
}

fn appendBytes(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    try appendU32(buf, gpa, @intCast(bytes.len));
    try buf.appendSlice(gpa, bytes);
}

fn appendDiagnostic(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, diag: diagnostics.Diagnostic) !void {
    try appendU8(buf, gpa, stageTagByte(diag.stage));
    if (diag.span) |span| {
        try appendU8(buf, gpa, 1);
        try appendU64(buf, gpa, @intCast(span.start));
        try appendU64(buf, gpa, @intCast(span.end));
    } else {
        try appendU8(buf, gpa, 0);
    }
    try appendBytes(buf, gpa, diag.message);
}

fn appendStage(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, snapshot: StageSnapshot) !void {
    try appendU64(buf, gpa, snapshot.changed_at);
    try appendU8(buf, gpa, if (snapshot.has_value) 1 else 0);
    try appendU32(buf, gpa, @intCast(snapshot.diagnostics.len));
    for (snapshot.diagnostics) |diag| {
        try appendDiagnostic(buf, gpa, diag);
    }
}

fn appendCompileStage(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, snapshot: CompileStageSnapshot) !void {
    try appendStage(buf, gpa, .{
        .changed_at = snapshot.changed_at,
        .has_value = snapshot.has_value,
        .diagnostics = snapshot.diagnostics,
    });
    if (snapshot.bytes) |bytes| {
        try appendU8(buf, gpa, 1);
        try appendBytes(buf, gpa, bytes);
    } else {
        try appendU8(buf, gpa, 0);
    }
}

fn serialize(gpa: std.mem.Allocator, payload: SavePayload) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(gpa, 4096);
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, &Magic);
    try appendU32(&buf, gpa, SchemaVersion);
    try appendU64(&buf, gpa, compilerFingerprint());
    try appendU64(&buf, gpa, sourceHash(payload.source_text));
    try appendBytes(&buf, gpa, payload.source_path);

    try appendStage(&buf, gpa, payload.parse);
    try appendStage(&buf, gpa, payload.resolve);
    try appendStage(&buf, gpa, payload.typecheck);
    try appendStage(&buf, gpa, payload.monomorphize);
    try appendStage(&buf, gpa, payload.lower);
    try appendCompileStage(&buf, gpa, payload.compile);

    return buf.toOwnedSlice(gpa);
}

const Reader = struct {
    data: []const u8,
    idx: usize = 0,

    fn readU8(self: *@This()) LoadError!u8 {
        if (self.idx + 1 > self.data.len) return error.Truncated;
        const value = self.data[self.idx];
        self.idx += 1;
        return value;
    }

    fn readU32(self: *@This()) LoadError!u32 {
        const bytes = try self.readSlice(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readU64(self: *@This()) LoadError!u64 {
        const bytes = try self.readSlice(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn readSlice(self: *@This(), len: usize) LoadError![]const u8 {
        if (self.idx + len > self.data.len) return error.Truncated;
        const out = self.data[self.idx .. self.idx + len];
        self.idx += len;
        return out;
    }

    fn readBytes(self: *@This()) LoadError![]const u8 {
        const len = try self.readU32();
        return self.readSlice(len);
    }
};

fn readDiagnosticsList(r: *Reader, gpa: std.mem.Allocator) LoadError!std.ArrayList(diagnostics.Diagnostic) {
    const count = try r.readU32();
    var list = try std.ArrayList(diagnostics.Diagnostic).initCapacity(gpa, count);
    errdefer list.deinit(gpa);

    var idx: u32 = 0;
    while (idx < count) : (idx += 1) {
        const stage = try stageFromByte(try r.readU8());
        const has_span = try r.readU8();
        var span: ?@import("ast.zig").Span = null;
        if (has_span == 1) {
            const start = try r.readU64();
            const end = try r.readU64();
            span = .{ .start = @intCast(start), .end = @intCast(end) };
        } else if (has_span != 0) {
            return error.InvalidData;
        }
        const msg = try r.readBytes();
        try list.append(gpa, .{
            .stage = stage,
            .span = span,
            .message = msg,
        });
    }

    return list;
}

fn readStage(r: *Reader, gpa: std.mem.Allocator) LoadError!LoadedStage {
    const changed = try r.readU64();
    const has_value_byte = try r.readU8();
    if (has_value_byte != 0 and has_value_byte != 1) return error.InvalidData;

    return .{
        .changed_at = changed,
        .has_value = has_value_byte == 1,
        .diagnostics = try readDiagnosticsList(r, gpa),
    };
}

fn readCompileStage(r: *Reader, gpa: std.mem.Allocator) LoadError!LoadedCompile {
    var stage = try readStage(r, gpa);
    errdefer stage.diagnostics.deinit(gpa);

    const has_bytes = try r.readU8();
    if (has_bytes != 0 and has_bytes != 1) return error.InvalidData;

    return .{
        .changed_at = stage.changed_at,
        .has_value = stage.has_value,
        .diagnostics = stage.diagnostics,
        .bytes = if (has_bytes == 1) try r.readBytes() else null,
    };
}

fn deserialize(gpa: std.mem.Allocator, file_data: []u8, expected_source_hash: u64) LoadError!?LoadPayload {
    var r = Reader{ .data = file_data };

    const magic = try r.readSlice(Magic.len);
    if (!std.mem.eql(u8, magic, &Magic)) return error.InvalidMagic;

    const schema = try r.readU32();
    if (schema != SchemaVersion) return error.InvalidSchema;

    const compiler = try r.readU64();
    if (compiler != compilerFingerprint()) return error.InvalidCompiler;

    const cached_source_hash = try r.readU64();
    if (cached_source_hash != expected_source_hash) return null;

    _ = try r.readBytes(); // stored source path; currently informational only

    var parse_stage = try readStage(&r, gpa);
    errdefer parse_stage.diagnostics.deinit(gpa);
    var resolve_stage = try readStage(&r, gpa);
    errdefer resolve_stage.diagnostics.deinit(gpa);
    var type_stage = try readStage(&r, gpa);
    errdefer type_stage.diagnostics.deinit(gpa);
    var mono_stage = try readStage(&r, gpa);
    errdefer mono_stage.diagnostics.deinit(gpa);
    var lower_stage = try readStage(&r, gpa);
    errdefer lower_stage.diagnostics.deinit(gpa);
    var compile_stage = try readCompileStage(&r, gpa);
    errdefer compile_stage.diagnostics.deinit(gpa);

    if (r.idx != r.data.len) return error.InvalidData;

    return .{
        .backing = file_data,
        .parse = parse_stage,
        .resolve = resolve_stage,
        .typecheck = type_stage,
        .monomorphize = mono_stage,
        .lower = lower_stage,
        .compile = compile_stage,
    };
}

fn writeAtomically(io: std.Io, gpa: std.mem.Allocator, cache_path: []const u8, bytes: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp", .{cache_path});
    defer gpa.free(tmp_path);

    cwd.writeFile(io, .{ .sub_path = tmp_path, .data = bytes }) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };

    cwd.rename(tmp_path, cwd, cache_path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
}

fn ensureOverrideDir(io: std.Io, options: CacheOptions) !void {
    if (options.cache_dir_override) |override_dir| {
        try std.Io.Dir.cwd().createDirPath(io, override_dir);
    }
}

pub fn save(io: std.Io, gpa: std.mem.Allocator, options: CacheOptions, payload: SavePayload) !void {
    try ensureOverrideDir(io, options);
    const cache_path = try cachePathForSource(gpa, payload.source_path, options);
    defer gpa.free(cache_path);

    const bytes = try serialize(gpa, payload);
    defer gpa.free(bytes);

    try writeAtomically(io, gpa, cache_path, bytes);
}

pub fn load(io: std.Io, gpa: std.mem.Allocator, options: CacheOptions, source_path: []const u8, source_text: []const u8) !?LoadPayload {
    const cache_path = try cachePathForSource(gpa, source_path, options);
    defer gpa.free(cache_path);

    const data = std.Io.Dir.cwd().readFileAlloc(io, cache_path, gpa, .limited(std.math.maxInt(usize))) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const expected_hash = sourceHash(source_text);
    return deserialize(gpa, data, expected_hash) catch {
        gpa.free(data);
        return null;
    };
}

fn sweepCacheDir(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterateAssumeFirstIteration();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!hasCacheExtension(entry.name)) continue;

        const cache_data = dir.readFileAlloc(io, entry.name, gpa, .limited(std.math.maxInt(usize))) catch continue;
        defer gpa.free(cache_data);

        var r = Reader{ .data = cache_data };
        _ = r.readSlice(Magic.len) catch continue;
        const schema = r.readU32() catch continue;
        if (schema != SchemaVersion) continue;
        _ = r.readU64() catch continue;
        _ = r.readU64() catch continue;
        const source_path_bytes = r.readBytes() catch continue;

        const source_exists = blk: {
            std.Io.Dir.cwd().access(io, source_path_bytes, .{}) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        };

        if (!source_exists) {
            dir.deleteFile(io, entry.name) catch {};
        }
    }
}

pub fn sweepStaleCaches(io: std.Io, gpa: std.mem.Allocator, options: CacheOptions, source_path: []const u8) !void {
    if (options.cache_dir_override) |override_dir| {
        try sweepCacheDir(io, gpa, override_dir);
        return;
    }

    const parts = splitDirAndName(source_path);
    try sweepCacheDir(io, gpa, parts.dir);
}
