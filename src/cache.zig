const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const magic = "CHICACHE";
const format_version: u64 = 1;
const header_len = magic.len + 32 + 8 + 32;
const max_artifact_size = 512 * 1024 * 1024;

pub const Key = [32]u8;

/// Zig's SHA-1 ELF build ID identifies the linked image without reading it
/// from disk on every cache lookup. Direct `zig test` binaries may lack one.
fn buildIdDigest() ?Key {
    const phdrs = std.posix.getSelfPhdrs();
    const base = for (phdrs) |phdr| {
        if (phdr.type == .PHDR) break @intFromPtr(phdrs.ptr) - phdr.vaddr;
    } else return null;
    for (phdrs) |phdr| {
        if (phdr.type != .NOTE) continue;
        const size = std.math.cast(usize, phdr.filesz) orelse continue;
        const address = std.math.add(usize, base, @as(usize, @intCast(phdr.vaddr))) catch continue;
        const bytes: []const u8 = @as([*]const u8, @ptrFromInt(address))[0..size];
        var offset: usize = 0;
        while (offset <= bytes.len and bytes.len - offset >= 12) {
            const name_size = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            const desc_size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
            const note_type = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
            const name_start = offset + 12;
            const name_end = std.math.add(usize, name_start, name_size) catch break;
            const desc_start = std.mem.alignForward(usize, name_end, 4);
            const desc_end = std.math.add(usize, desc_start, desc_size) catch break;
            if (desc_end > bytes.len) break;
            if (note_type == std.elf.NT_GNU_BUILD_ID and
                std.mem.eql(u8, bytes[name_start..name_end], "GNU\x00") and desc_size == 20)
            {
                var hasher = Sha256.init(.{});
                hasher.update("chi compiler build ID");
                hasher.update(bytes[desc_start..desc_end]);
                var result: Key = undefined;
                hasher.final(&result);
                return result;
            }
            offset = std.mem.alignForward(usize, desc_end, 4);
        }
    }
    return null;
}

fn addLength(hasher: *Sha256, value: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hasher.update(&bytes);
}

fn addBytes(hasher: *Sha256, bytes: []const u8) void {
    addLength(hasher, bytes.len);
    hasher.update(bytes);
}

/// Tie cache entries to the linked compiler image, including any newly added
/// source modules that a maintained list could miss.
pub fn compilerDigest(io: std.Io) !Key {
    if (buildIdDigest()) |digest| return digest;
    // /proc/self/exe refers to this process's original inode even if another
    // process replaces the binary on disk while this run is active.
    const compiler = try std.Io.Dir.cwd().openFile(io, "/proc/self/exe", .{});
    defer compiler.close(io);
    var compiler_hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = compiler.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        compiler_hasher.update(buffer[0..n]);
    }
    var compiler_digest: Key = undefined;
    compiler_hasher.final(&compiler_digest);
    return compiler_digest;
}

/// The executable result depends on all source and module inputs. Hash the
/// complete contents: timestamps and file sizes alone can accept stale code.
pub fn key(compiler_digest: Key, source_path: []const u8, source: []const u8, files: anytype, module_paths: []const []const u8) Key {
    var hasher = Sha256.init(.{});
    addLength(&hasher, format_version);
    addBytes(&hasher, &compiler_digest);
    addBytes(&hasher, source_path);
    addBytes(&hasher, source);
    addLength(&hasher, files.len);
    for (files) |file| {
        addBytes(&hasher, file.path);
        addBytes(&hasher, file.module_path);
        addBytes(&hasher, file.source);
    }
    addLength(&hasher, module_paths.len);
    for (module_paths) |path| addBytes(&hasher, path);
    var result: Key = undefined;
    hasher.final(&result);
    return result;
}

/// A query snapshot survives source edits while file IDs retain their path
/// mapping. Added, removed, or reordered files use a different snapshot.
pub fn querySnapshotKey(compiler_digest: Key, source_path: []const u8, files: anytype) Key {
    var hasher = Sha256.init(.{});
    addBytes(&hasher, "query snapshot v4");
    addBytes(&hasher, &compiler_digest);
    addBytes(&hasher, source_path);
    addLength(&hasher, files.len);
    for (files) |file| {
        addBytes(&hasher, file.path);
        addBytes(&hasher, file.module_path);
    }
    var result: Key = undefined;
    hasher.final(&result);
    return result;
}

fn entryPath(gpa: std.mem.Allocator, directory: []const u8, digest: Key) ![]u8 {
    const name = std.fmt.bytesToHex(digest, .lower);
    return std.fs.path.join(gpa, &.{ directory, &name });
}

/// A malformed, truncated, or stale entry is a miss. The caller owns the bytes.
pub fn load(io: std.Io, gpa: std.mem.Allocator, directory: []const u8, digest: Key) !?[]u8 {
    const path = try entryPath(gpa, directory, digest);
    defer gpa.free(path);
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(header_len + max_artifact_size)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer gpa.free(contents);
    if (contents.len < header_len or !std.mem.eql(u8, contents[0..magic.len], magic)) return null;
    if (!std.mem.eql(u8, contents[magic.len..][0..32], &digest)) return null;
    const size = std.mem.readInt(u64, contents[magic.len + 32 ..][0..8], .little);
    if (size > max_artifact_size or contents.len - header_len != size) return null;
    const payload = contents[header_len..];
    var actual_hash: [32]u8 = undefined;
    Sha256.hash(payload, &actual_hash, .{});
    if (!std.mem.eql(u8, contents[magic.len + 40 ..][0..32], &actual_hash)) return null;
    return try gpa.dupe(u8, payload);
}

/// Each writer publishes a complete immutable entry with an atomic replace.
/// Concurrent writers for the same key publish the same validated result.
pub fn save(io: std.Io, gpa: std.mem.Allocator, directory: []const u8, digest: Key, payload: []const u8) !void {
    if (payload.len > max_artifact_size) return;
    const path = try entryPath(gpa, directory, digest);
    defer gpa.free(path);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, @intCast(payload.len), .little);
    var payload_hash: [32]u8 = undefined;
    Sha256.hash(payload, &payload_hash, .{});
    try atomic.file.writeStreamingAll(io, magic);
    try atomic.file.writeStreamingAll(io, &digest);
    try atomic.file.writeStreamingAll(io, &size);
    try atomic.file.writeStreamingAll(io, &payload_hash);
    try atomic.file.writeStreamingAll(io, payload);
    try atomic.replace(io);
}

test "disk cache validates source identity and complete artifact contents" {
    const testing = std.testing;
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(directory);

    const compiler_digest = try compilerDigest(io);
    const SourceFile = struct { path: []const u8, module_path: []const u8, source: []const u8 };
    const files = [_]SourceFile{.{ .path = "lib.chi", .module_path = "", .source = "static value = 1" }};
    const digest = key(compiler_digest, "main.chi", "exit(value)", &files, &.{""});
    const changed_file = [_]SourceFile{.{ .path = "lib.chi", .module_path = "", .source = "static value = 2" }};
    try testing.expect(!std.mem.eql(u8, &digest, &key(compiler_digest, "main.chi", "exit(value)", &changed_file, &.{""})));
    try testing.expect(!std.mem.eql(u8, &digest, &key(compiler_digest, "main.chi", "exit(1)", &files, &.{""})));
    try testing.expect(!std.mem.eql(u8, &digest, &key(compiler_digest, "main.chi", "exit(value)", &[_]SourceFile{}, &.{""})));
    try testing.expect(!std.mem.eql(u8, &digest, &key(compiler_digest, "main.chi", "exit(value)", &files, &.{ "", "unused" })));
    try testing.expect((try load(io, gpa, directory, digest)) == null);

    try save(io, gpa, directory, digest, "valid executable");
    const loaded = (try load(io, gpa, directory, digest)).?;
    defer gpa.free(loaded);
    try testing.expectEqualStrings("valid executable", loaded);

    const path = try entryPath(gpa, directory, digest);
    defer gpa.free(path);
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "truncated");
    }
    try testing.expect((try load(io, gpa, directory, digest)) == null);
    try save(io, gpa, directory, digest, "restored executable");
    const restored = (try load(io, gpa, directory, digest)).?;
    defer gpa.free(restored);
    try testing.expectEqualStrings("restored executable", restored);

    const damaged = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(damaged);
    damaged[header_len] ^= 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = damaged });
    try testing.expect((try load(io, gpa, directory, digest)) == null);
}
