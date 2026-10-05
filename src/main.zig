const std = @import("std");
const cache = @import("cache.zig");
const debug = @import("debug.zig");
const diagnostics = @import("diagnostics.zig");
const modules = @import("modules.zig");
const query = @import("query/engine.zig");
const query_disk_cache = @import("query_disk_cache.zig");
const queries = @import("queries.zig");
const runtime = @import("runtime.zig");
const structures = @import("structures.zig");

const file_id: structures.FileId = 0;

const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    @"asm": bool = false,
    timing: bool = false,
    memory: bool = false,
};

const RunInput = struct {
    source_path: []const u8,
    source: []const u8,
    source_files: []const modules.SourceFile = &.{},
    module_paths: []const []const u8 = &.{},
    program_args: []const []const u8,
    debug_flags: DebugFlags,
    started: std.Io.Timestamp,
    cache_directory: ?[]const u8 = null,
    worker_count: usize = 0,
};

const RunOutcome = union(enum) {
    program: std.process.Child.Term,
    compiler_exit: u8,
    rejected,
};

fn trySetDebugFlag(flags: *DebugFlags, name: []const u8) bool {
    inline for (@typeInfo(DebugFlags).@"struct".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            @field(flags, field.name) = true;
            return true;
        }
    }
    return false;
}

fn printError(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) !void {
    try writer.writeAll("\x1b[31merror:\x1b[0m ");
    try writer.print(format, args);
    try writer.writeByte('\n');
}

fn printUsage(writer: *std.Io.Writer, executable_name: []const u8) !void {
    try writer.print(
        "usage: {s} [--debug=ast,ssa,asm,timing,memory] [--workers=N] [--disk-cache] <source-file> [program-args...]\n" ++
            "       {s} [-h|--help]\n",
        .{ executable_name, executable_name },
    );
}

const CommandLine = struct {
    debug_flags: DebugFlags,
    worker_count: usize,
    disk_cache_enabled: bool,
    positional: []const []const u8,
};

const ParsedCommandLine = union(enum) {
    help,
    run: CommandLine,
};

fn parseCommandLine(args: []const []const u8, errors: *std.Io.Writer) !?ParsedCommandLine {
    var flags: DebugFlags = .{};
    var worker_count: usize = 0;
    var disk_cache_enabled = false;
    var valid = true;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "-h") or std.mem.eql(u8, args[index], "--help")) {
            if (!valid) return null;
            return .help;
        } else if (std.mem.startsWith(u8, args[index], "--debug=")) {
            var names = std.mem.splitScalar(u8, args[index]["--debug=".len..], ',');
            while (names.next()) |name| {
                if (trySetDebugFlag(&flags, name)) continue;
                try printError(errors, "unknown debug flag '{s}'", .{name});
                valid = false;
            }
        } else if (std.mem.startsWith(u8, args[index], "--workers=")) {
            worker_count = std.fmt.parseUnsigned(usize, args[index]["--workers=".len..], 10) catch 0;
            if (worker_count == 0 or worker_count > 64) {
                try printError(errors, "worker count must be between 1 and 64", .{});
                valid = false;
            }
        } else if (std.mem.eql(u8, args[index], "--disk-cache")) {
            disk_cache_enabled = true;
        } else {
            break;
        }
    }
    if (!valid or index == args.len) return null;
    return .{ .run = .{ .debug_flags = flags, .worker_count = worker_count, .disk_cache_enabled = disk_cache_enabled, .positional = args[index..] } };
}

fn buildWithStageTimings(db: *query.Database, io: std.Io, timings: *diagnostics.TimingLog) !void {
    _ = try db.get(queries.ParseFile, file_id);
    timings.mark(io, "parse");
    // Debug timing follows the same demand roots as an ordinary build.
    _ = try db.get(queries.IndexItems, file_id);
    timings.mark(io, "discover items");
    const root = try db.intern(queries.ModulePaths, .{ .path = "" });
    const modules_valid = (try db.get(queries.ValidateModuleGraph, root)).*;
    timings.mark(io, "validate modules");
    if (!modules_valid) return;
    if ((try db.get(queries.SelectEntry, file_id)).*) |entry|
        _ = try db.get(queries.AnalyzeFunctionInstance, .{ .item = entry });
    timings.mark(io, "analyze entry");
    _ = try db.get(queries.CollectReachableInstances, file_id);
    timings.mark(io, "compile reachable functions (includes callee analysis)");
}

fn compileAndRun(
    io: std.Io,
    gpa: std.mem.Allocator,
    input: RunInput,
    output: *std.Io.Writer,
    errors: *std.Io.Writer,
) !RunOutcome {
    var timings: diagnostics.TimingLog = .init(input.started);
    timings.mark(io, "load source");
    const use_cache = input.cache_directory != null and !input.debug_flags.ast and
        !input.debug_flags.ssa and !input.debug_flags.@"asm";
    const compiler_digest = if (use_cache) cache.compilerDigest(io) catch null else null;
    const cache_key = if (compiler_digest) |digest|
        cache.key(digest, input.source_path, input.source, input.source_files, input.module_paths)
    else
        null;
    if (cache_key) |digest| {
        if (try cache.load(io, gpa, input.cache_directory.?, digest)) |bytes| {
            defer gpa.free(bytes);
            timings.mark(io, "cache hit");
            return runExecutable(io, gpa, input, bytes, &timings, errors);
        }
    }
    const worker_count = if (input.worker_count == 0)
        @min(2, std.Thread.getCpuCount() catch 1)
    else
        input.worker_count;
    const snapshot_key = if (compiler_digest) |digest|
        cache.querySnapshotKey(digest, input.source_path, input.source_files)
    else
        null;
    const snapshot = if (snapshot_key) |digest|
        try cache.load(io, gpa, input.cache_directory.?, digest)
    else
        null;
    defer if (snapshot) |bytes| gpa.free(bytes);

    const database_options: query.Options = .{
        .worker_count = worker_count,
    };
    var db = try query.Database.init(gpa, database_options);
    defer db.deinit();
    timings.mark(io, "database init");
    var source_registry: modules.SourceRegistry = .{};
    defer source_registry.deinit(gpa);
    var restored_offset: ?usize = null;
    if (snapshot) |bytes| {
        restored_offset = query_disk_cache.restoreInterns(db, gpa, bytes) catch |err| switch (err) {
            error.InvalidCache, error.InvalidInternId => invalid: {
                const fresh = try query.Database.init(gpa, database_options);
                db.deinit();
                db = fresh;
                break :invalid null;
            },
            else => return err,
        };
    }
    timings.mark(io, "restore identities");
    try source_registry.update(db, gpa, input.source, input.source_files, input.module_paths);
    timings.mark(io, "add source");
    if (restored_offset) |offset| {
        _ = query_disk_cache.restoreQueries(db, snapshot.?, offset) catch |err| switch (err) {
            error.InvalidCache, error.InvalidInternId => {
                const fresh = try query.Database.init(gpa, database_options);
                source_registry.deinit(gpa);
                source_registry = .{};
                db.deinit();
                db = fresh;
                try source_registry.update(db, gpa, input.source, input.source_files, input.module_paths);
            },
            else => return err,
        };
    }
    timings.mark(io, "restore queries");

    if (input.debug_flags.timing) try buildWithStageTimings(db, io, &timings);
    const executable_result = try db.get(queries.BuildExecutable, file_id);
    timings.mark(io, "link executable");
    const emitted = try db.transitiveAccumulatorValues(
        queries.BuildExecutable,
        file_id,
        structures.Diagnostic,
        gpa,
    );
    defer gpa.free(emitted);
    const compiler_controls = try db.transitiveAccumulatorValues(
        queries.BuildExecutable,
        file_id,
        structures.CompilerControl,
        gpa,
    );
    defer gpa.free(compiler_controls);
    timings.mark(io, "collect diagnostics");

    var render_sources: std.ArrayList(diagnostics.DiagnosticSource) = .empty;
    defer {
        for (render_sources.items, 0..) |source, index| {
            if (index != 0 and index <= input.source_files.len) gpa.free(source.path);
        }
        render_sources.deinit(gpa);
    }
    try render_sources.append(gpa, .{ .file_id = file_id, .path = input.source_path, .source = input.source });
    for (input.source_files, 0..) |file, index| {
        const path = try std.fs.path.join(gpa, &.{ std.fs.path.dirname(input.source_path) orelse ".", file.path });
        errdefer gpa.free(path);
        try render_sources.append(gpa, .{ .file_id = @intCast(index + 1), .path = path, .source = file.source });
    }
    for (modules.standard_sources) |source| {
        try render_sources.append(gpa, .{
            .file_id = source_registry.fileId(source.registry_path).?,
            .path = source.display_path,
            .source = source.source,
        });
    }
    if (input.debug_flags.ast) {
        for (render_sources.items) |source| {
            if ((try db.get(queries.ParseFile, source.file_id)).*) |parsed| {
                try output.print("source {s}\n", .{source.path});
                try debug.renderAst(gpa, &parsed, source.source, output);
            }
        }
    }
    if (executable_result.* == null) {
        if (compiler_controls.len != 0) {
            const status = switch (compiler_controls[0]) {
                .exit => |value| value,
            };
            return .{ .compiler_exit = @truncate(@as(u32, @bitCast(status))) };
        }
        std.debug.assert(emitted.len != 0);
        try output.flush();
        timings.mark(io, "debug output");
        const type_interner: queries.TypeFacts(*query.Database) = .{ .ctx = db };
        try diagnostics.renderDiagnostics(type_interner, errors, render_sources.items, emitted);
        if (input.debug_flags.timing) try timings.print(io, errors);
        try errors.flush();
        return .rejected;
    }
    std.debug.assert(emitted.len == 0);
    const executable = executable_result.*.?;

    if (input.debug_flags.ssa) try debug.renderReachableSsa(db, file_id, render_sources.items, output);
    if (input.debug_flags.@"asm") try debug.renderAssembly(db, file_id, render_sources.items, executable, gpa, output);
    try output.flush();
    timings.mark(io, "debug output");

    // A cache write failure cannot invalidate a completed compilation.
    if (snapshot_key) |digest| query_disk_cache.save(io, gpa, input.cache_directory.?, digest, db) catch {};
    timings.mark(io, "save queries");
    if (cache_key) |digest| cache.save(io, gpa, input.cache_directory.?, digest, executable.bytes) catch {};

    return runExecutable(io, gpa, input, executable.bytes, &timings, errors);
}

fn runExecutable(io: std.Io, gpa: std.mem.Allocator, input: RunInput, bytes: []const u8, timings: *diagnostics.TimingLog, errors: *std.Io.Writer) !RunOutcome {
    var prepared = try runtime.prepareProgram(io, gpa, bytes);
    defer prepared.deinit(io);
    timings.mark(io, "write program");
    const exit_code = try prepared.run(io, input.program_args);
    timings.mark(io, "run program");

    if (input.debug_flags.timing) {
        try timings.print(io, errors);
        try errors.flush();
    }
    return .{ .program = exit_code };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const output = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const errors = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    const parsed = (try parseCommandLine(args[1..], errors)) orelse {
        try printUsage(errors, args[0]);
        try errors.flush();
        std.process.exit(1);
    };
    const command_line = switch (parsed) {
        .help => {
            try printUsage(output, args[0]);
            try output.flush();
            return;
        },
        .run => |command_line| command_line,
    };
    const debug_flags = command_line.debug_flags;

    // Tracking allocates nothing but adds per-allocation bookkeeping.
    var tracker: diagnostics.MemoryTracker = .{ .backing = init.gpa };
    const gpa = if (debug_flags.memory) tracker.allocator() else init.gpa;

    const started = std.Io.Clock.awake.now(io);
    const source_path = command_line.positional[0];
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        source_path,
        gpa,
        .limited(std.math.maxInt(usize)),
    ) catch |read_error| {
        try printError(errors, "failed to read '{s}': {s}", .{ source_path, @errorName(read_error) });
        try errors.flush();
        std.process.exit(1);
    };
    defer gpa.free(source);

    const entry_dir_path = std.fs.path.dirname(source_path) orelse ".";
    const entry_name = std.fs.path.basename(source_path);
    var entry_dir = std.Io.Dir.cwd().openDir(io, entry_dir_path, .{ .iterate = true }) catch |dir_error| {
        try printError(errors, "failed to open '{s}': {s}", .{ entry_dir_path, @errorName(dir_error) });
        try errors.flush();
        std.process.exit(1);
    };
    defer entry_dir.close(io);
    const catalog = modules.collectModuleFiles(arena, io, entry_dir, entry_name) catch |walk_error| {
        try printError(errors, "failed to list '{s}': {s}", .{ entry_dir_path, @errorName(walk_error) });
        try errors.flush();
        std.process.exit(1);
    };
    const source_files = modules.readSources(io, arena, entry_dir, catalog.files) catch |read_error| {
        try printError(errors, "failed to read sources under '{s}': {s}", .{ entry_dir_path, @errorName(read_error) });
        try errors.flush();
        std.process.exit(1);
    };
    const cache_directory = if (command_line.disk_cache_enabled)
        try std.fs.path.join(arena, &.{ entry_dir_path, ".chi-cache" })
    else
        null;

    const outcome = compileAndRun(io, gpa, .{
        .source_path = source_path,
        .source = source,
        .source_files = source_files,
        .module_paths = catalog.modules,
        .program_args = command_line.positional[1..],
        .debug_flags = debug_flags,
        .started = started,
        .cache_directory = cache_directory,
        .worker_count = command_line.worker_count,
    }, output, errors) catch |run_error| {
        try printError(errors, "compiler execution failed: {s}", .{@errorName(run_error)});
        try errors.flush();
        return run_error;
    };
    if (debug_flags.memory) {
        try tracker.print(errors);
        try errors.flush();
    }
    switch (outcome) {
        .program => |termination| if (!try reportProgramTermination(output, errors, termination)) std.process.exit(1),
        .compiler_exit => |code| std.process.exit(code),
        .rejected => {
            // Rejected source is an expected user error: exit quietly so the
            // caller sees status 1 without the runtime's error trace.
            std.process.exit(1);
        },
    }
}

fn reportProgramTermination(output: *std.Io.Writer, errors: *std.Io.Writer, termination: std.process.Child.Term) !bool {
    switch (termination) {
        .exited => |code| {
            try output.print("exit code: {d}\n", .{code});
            try output.flush();
            return true;
        },
        .signal => |signal| try printError(errors, "generated program terminated by signal {d}", .{@intFromEnum(signal)}),
        .stopped => |signal| try printError(errors, "generated program stopped by signal {d}", .{@intFromEnum(signal)}),
        .unknown => |status| try printError(errors, "generated program terminated with unknown status {d}", .{status}),
    }
    try errors.flush();
    return false;
}

test "CLI reports a generated program signal separately from compiler failure" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expect(!try reportProgramTermination(&output.writer, &errors.writer, .{ .signal = .TERM }));
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "generated program terminated by signal 15") != null);
    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
}

test "CLI options stop at the source path and preserve program arguments" {
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const args = [_][]const u8{ "--debug=ast,memory", "main.chi", "--debug=child", "--help", "-h", "argument" };
    const parsed = (try parseCommandLine(&args, &errors.writer)).?.run;
    try std.testing.expect(parsed.debug_flags.ast);
    try std.testing.expect(parsed.debug_flags.memory);
    try std.testing.expectEqualSlices([]const u8, args[1..], parsed.positional);
    try std.testing.expectEqual(@as(usize, 0), errors.writer.buffered().len);
    try std.testing.expect(!parsed.disk_cache_enabled);
    try std.testing.expect(try parseCommandLine(&.{"--debug=ssa"}, &errors.writer) == null);
    try std.testing.expect(try parseCommandLine(&.{ "--debug=unknown", "main.chi" }, &errors.writer) == null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "unknown debug flag 'unknown'") != null);
    const workers = (try parseCommandLine(&.{ "--workers=4", "main.chi" }, &errors.writer)).?.run;
    try std.testing.expectEqual(@as(usize, 4), workers.worker_count);
    try std.testing.expect(try parseCommandLine(&.{ "--workers=0", "main.chi" }, &errors.writer) == null);
    const disk_cached = (try parseCommandLine(&.{ "--disk-cache", "--workers=2", "main.chi", "--disk-cache" }, &errors.writer)).?.run;
    try std.testing.expect(disk_cached.disk_cache_enabled);
    try std.testing.expectEqualSlices([]const u8, &.{ "main.chi", "--disk-cache" }, disk_cached.positional);
}

test "CLI help accepts both spellings without a source path" {
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    try std.testing.expect((try parseCommandLine(&.{"-h"}, &errors.writer)).? == .help);
    try std.testing.expect((try parseCommandLine(&.{"--help"}, &errors.writer)).? == .help);
    try std.testing.expect((try parseCommandLine(&.{ "--workers=2", "--help" }, &errors.writer)).? == .help);
    try std.testing.expectEqual(@as(usize, 0), errors.writer.buffered().len);
    try std.testing.expect(try parseCommandLine(&.{ "--debug=unknown", "--help" }, &errors.writer) == null);
}

test "CLI reuses a complete disk cache entry and invalidates changed source" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_directory = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cache_directory);

    for ([_]struct { source: []const u8, expected: u8, hit: bool, corrupt_before: bool = false }{
        .{ .source = "exit(17)", .expected = 17, .hit = false },
        .{ .source = "exit(17)", .expected = 17, .hit = true },
        .{ .source = "exit(17)", .expected = 17, .hit = false, .corrupt_before = true },
        .{ .source = "exit(18)", .expected = 18, .hit = false },
    }) |case| {
        if (case.corrupt_before) {
            const digest = cache.key(try cache.compilerDigest(io), "test.chi", case.source, &[_]modules.SourceFile{}, &.{});
            const name = std.fmt.bytesToHex(digest, .lower);
            try tmp.dir.writeFile(io, .{ .sub_path = &name, .data = "damaged" });
        }
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer errors.deinit();
        const result = try compileAndRun(io, std.testing.allocator, .{
            .source_path = "test.chi",
            .source = case.source,
            .program_args = &.{},
            .debug_flags = .{ .timing = true },
            .started = std.Io.Clock.awake.now(io),
            .cache_directory = cache_directory,
            .worker_count = 2,
        }, &output.writer, &errors.writer);
        try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = case.expected } }, result);
        try std.testing.expectEqual(case.hit, std.mem.indexOf(u8, errors.writer.buffered(), "cache hit") != null);
    }

    var uncached_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer uncached_output.deinit();
    var uncached_errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer uncached_errors.deinit();
    const uncached_result = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "test.chi",
        .source = "exit(18)",
        .program_args = &.{},
        .debug_flags = .{ .timing = true },
        .started = std.Io.Clock.awake.now(io),
        .worker_count = 2,
    }, &uncached_output.writer, &uncached_errors.writer);
    try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = 18 } }, uncached_result);
    try std.testing.expect(std.mem.indexOf(u8, uncached_errors.writer.buffered(), "cache hit") == null);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const rejected = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "test.chi",
        .source = "exit(",
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
        .cache_directory = cache_directory,
        .worker_count = 2,
    }, &output.writer, &errors.writer);
    try std.testing.expectEqual(RunOutcome.rejected, rejected);
    try std.testing.expect(errors.writer.buffered().len != 0);

    const snapshot_key = cache.querySnapshotKey(try cache.compilerDigest(io), "test.chi", &[_]modules.SourceFile{});
    const snapshot = (try cache.load(io, std.testing.allocator, cache_directory, snapshot_key)).?;
    defer std.testing.allocator.free(snapshot);
    snapshot[0] ^= 1;
    try cache.save(io, std.testing.allocator, cache_directory, snapshot_key, snapshot);
    var recovered_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer recovered_output.deinit();
    var recovered_errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer recovered_errors.deinit();
    const recovered = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "test.chi",
        .source = "exit(19)",
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
        .cache_directory = cache_directory,
        .worker_count = 2,
    }, &recovered_output.writer, &recovered_errors.writer);
    try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = 19 } }, recovered);
    try std.testing.expectEqual(@as(usize, 0), recovered_errors.writer.buffered().len);
}

test "one and four workers produce identical multi-file artifacts" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    const source_files = [_]modules.SourceFile{
        .{ .path = "a.chi", .module_path = "", .source = "static a = func() int -> return 10" },
        .{ .path = "b.chi", .module_path = "", .source = "static b = func() int -> return 11" },
    };
    var first_artifact: ?[]u8 = null;
    defer if (first_artifact) |bytes| std.testing.allocator.free(bytes);
    for ([_]usize{ 1, 4 }) |workers| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer errors.deinit();
        const result = try compileAndRun(io, std.testing.allocator, .{
            .source_path = "main.chi",
            .source = "exit(a() + b())",
            .source_files = &source_files,
            .program_args = &.{},
            .debug_flags = .{},
            .started = std.Io.Clock.awake.now(io),
            .worker_count = workers,
        }, &output.writer, &errors.writer);
        try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = 21 } }, result);
        try std.testing.expectEqual(@as(usize, 0), errors.writer.buffered().len);
        const artifact = try std.Io.Dir.cwd().readFileAlloc(io, "prog", std.testing.allocator, .limited(1024 * 1024));
        if (first_artifact) |first| {
            defer std.testing.allocator.free(artifact);
            try std.testing.expectEqualSlices(u8, first, artifact);
        } else {
            first_artifact = artifact;
        }
    }
}

test "CLI core renders debug output and runs the compiled program" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    const exit_code = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "test.chi",
        .source =
        \\static status = func(value: int) int -> return value * 2
        \\const a = status(21)
        \\exit(a)
        ,
        .program_args = &.{},
        .debug_flags = .{ .ast = true, .ssa = true, .@"asm" = true, .timing = true },
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);

    try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = 42 } }, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "AST\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "SSA\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "ASM\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "db 0x") == null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "timing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "database init") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "validate modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "analyze entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "compile reachable functions (includes callee analysis)") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "analyze bodies") == null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "compile functions") == null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "link executable") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "collect diagnostics") != null);
}

test "CLI core renders source diagnostics without running" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    const exit_code = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "broken.chi",
        .source = "exit()",
        .program_args = &.{},
        .debug_flags = .{ .ast = true, .timing = true },
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);

    try std.testing.expectEqual(RunOutcome.rejected, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "AST\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errors.writer.buffered(),
        "broken.chi:1:1: expected 1 call argument, found 0",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "timing\n") != null);
}

test "CLI core renders compile-time call traces from the failure outward" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    const exit_code = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "trace.chi",
        .source =
        \\static fail_value = func() int -> 42 / 0
        \\static middle = func() int -> fail_value()
        \\static bad = middle()
        \\exit(bad)
        ,
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);

    try std.testing.expectEqual(RunOutcome.rejected, exit_code);
    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    const rendered = errors.writer.buffered();
    const failure = std.mem.indexOf(u8, rendered, "division by zero during compile-time execution").?;
    const inner_call = std.mem.indexOf(u8, rendered, "trace.chi:2:").?;
    const outer_call = std.mem.indexOf(u8, rendered, "trace.chi:3:").?;
    try std.testing.expect(failure < inner_call);
    try std.testing.expect(inner_call < outer_call);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, rendered, "called at compile time from here"));
}

test "CLI rejects unsupported compile-time borrowing and allocation with diagnostics" {
    const io = std.testing.io;
    for ([_][]const u8{
        \\func compute() int
        \\  const number = 42
        \\  borrow item = number
        \\  return item
        \\static answer = compute()
        \\exit(answer)
        ,
        \\fallible compute() int
        \\  const owner = Box.new?(42)
        \\  return owner.borrow()[]
        \\static answer = compute?()
        \\exit(answer)
        ,
    }) |source| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer errors.deinit();
        const result = try compileAndRun(io, std.testing.allocator, .{
            .source_path = "unsupported.chi",
            .source = source,
            .program_args = &.{},
            .debug_flags = .{},
            .started = std.Io.Clock.awake.now(io),
        }, &output.writer, &errors.writer);
        try std.testing.expectEqual(RunOutcome.rejected, result);
        try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "operation is not supported during compile-time execution") != null);
        try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "unsupported.chi:") != null);
    }
}

test "CLI core handles compile-time exit without producing an artifact" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    const exit_code = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "comptime-exit.chi",
        .source =
        \\static stopped = exit(42)
        \\exit(stopped)
        ,
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);

    try std.testing.expectEqual(RunOutcome{ .compiler_exit = 42 }, exit_code);
    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), errors.writer.buffered().len);
}

test "CLI core rejects duplicate top-level names without running" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    const exit_code = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "duplicates.chi",
        .source =
        \\static duplicate = func() int -> return 1
        \\static duplicate = func() int -> return 2
        \\exit(0)
        ,
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);

    try std.testing.expectEqual(RunOutcome.rejected, exit_code);
    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errors.writer.buffered(),
        "duplicates.chi:2:8: top-level name is already declared: `duplicate`",
    ) != null);
}

test "source files load without changing the entry program" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();

    const exit_code = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "test.chi",
        .source =
        \\static status = func(value: int) int -> return value * 2
        \\const a = status(21)
        \\exit(a)
        ,
        .source_files = &.{
            .{ .path = "physics/body.chi", .source = "exit(0)", .module_path = "physics" },
        },
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);

    try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = 42 } }, exit_code);
}

test "diagnostics render with their own file paths" {
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    const physics_source = "exit()";
    const entry_source = "exit(0)";
    try modules.registerSources(db, std.testing.allocator, entry_source, &.{
        .{ .path = "physics/body.chi", .source = physics_source, .module_path = "physics" },
    }, &.{ "", "physics" });
    const physics_entry = (try db.get(queries.SelectEntry, 1)).*.?;
    try std.testing.expect((try db.get(queries.AnalyzeFunctionInstance, .{ .item = physics_entry })).* == null);
    const held = try db.transitiveAccumulatorValues(queries.AnalyzeFunctionInstance, .{ .item = physics_entry }, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(held);
    try std.testing.expectEqual(@as(usize, 1), held.len);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const type_interner: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    try diagnostics.renderDiagnostics(type_interner, &output.writer, &.{
        .{ .file_id = 0, .path = "main.chi", .source = entry_source },
        .{ .file_id = 1, .path = "physics/body.chi", .source = physics_source },
    }, held);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.writer.buffered(),
        "physics/body.chi:1:1: expected 1 call argument, found 0",
    ) != null);
}

test "ownership diagnostics describe field transfers" {
    const db = try query.Database.init(std.testing.allocator, .{ .worker_count = 1 });
    defer db.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const type_interner: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    try diagnostics.renderDiagnostics(type_interner, &output.writer, &.{
        .{ .file_id = 0, .path = "ownership.chi", .source = "" },
    }, &.{
        .{ .file_id = 0, .span = null, .kind = .ownership_transfer_requires_place },
        .{ .file_id = 0, .span = null, .kind = .partial_field_transfer_not_supported },
        .{ .file_id = 0, .span = null, .kind = .explicit_drop_field_cannot_be_implicitly_ended },
        .{ .file_id = 0, .span = null, .kind = .{ .box_extraction_requires_direct_move = .int } },
    });

    const rendered = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "`^` can only transfer a local binding or one of its fields") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cannot transfer or join these fields independently under the current ownership rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "transfer or dispose of it on every path") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cannot extract a non-directly-movable value from Box; found `int`") != null);
}

test "CLI debug labels sources across modules and timing preserves unused code" {
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const outcome = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "/project/main.chi",
        .source = "import lib\nfunc unused() -> exit(comptime -> exit(99))\nexit(lib.answer())",
        .source_files = &.{.{ .path = "lib/a.chi", .module_path = "lib", .source = "pub func answer() int -> return 42\nexit(comptime -> exit(98))" }},
        .program_args = &.{},
        .debug_flags = .{ .ast = true, .ssa = true, .@"asm" = true, .timing = true },
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);
    try std.testing.expectEqual(RunOutcome{ .program = .{ .exited = 42 } }, outcome);
    const rendered = output.writer.buffered();
    for ([_][]const u8{ "source /project/main.chi", "source /project/lib/a.chi", "SSA\n", "ASM\n", ":: lib.answer" }) |expected|
        try std.testing.expect(std.mem.indexOf(u8, rendered, expected) != null);
    const ssa = rendered[std.mem.indexOf(u8, rendered, "SSA\n").?..];
    try std.testing.expect(std.mem.indexOf(u8, ssa, "unused") == null);
}

test "CLI qualified access diagnostics identify the defining dependency file" {
    const io = std.testing.io;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const outcome = try compileAndRun(io, std.testing.allocator, .{
        .source_path = "/project/main.chi",
        .source = "import api\nexit(api.answer())",
        .source_files = &.{
            .{ .path = "lib/a.chi", .module_path = "lib", .source = "static secret = 42" },
            .{ .path = "api/a.chi", .module_path = "api", .source = "import lib\npub func answer() int -> return lib.secret" },
        },
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(io),
    }, &output.writer, &errors.writer);
    try std.testing.expectEqual(RunOutcome.rejected, outcome);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "/project/api/a.chi:2:") != null);
}

test "missing field diagnostics use the struct definition's source file" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer errors.deinit();
    const outcome = try compileAndRun(std.testing.io, std.testing.allocator, .{
        .source_path = "/project/main.chi",
        .source = "import lib\nconst s = lib.S{}",
        .source_files = &.{.{ .path = "lib/s.chi", .module_path = "lib", .source = "pub struct S\n  pub required: int" }},
        .program_args = &.{},
        .debug_flags = .{},
        .started = std.Io.Clock.awake.now(std.testing.io),
    }, &output.writer, &errors.writer);
    try std.testing.expectEqual(RunOutcome.rejected, outcome);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "missing required field `required`") != null);
}
