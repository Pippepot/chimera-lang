const std = @import("std");
const compiler = @import("compiler");
const workload_generator = @import("history_workload.zig");
const sampling = @import("history_sampling.zig");
const queries = compiler.queries;
const has_standard_bundle = @hasDecl(compiler, "standard_bundle");
const standard_bundle = if (has_standard_bundle) @embedFile("standard_bundle") else "";

comptime {
    if (compiler.optimize_mode != @import("builtin").mode)
        @compileError("benchmark driver and compiler must use the same optimization mode");
}

const compilation_case = "core-1000000";
const runtime_case = "sieve-88000000";
const runtime_limit = 88_000_000;

fn executable(db: *compiler.query.Database, allocator: std.mem.Allocator) ![]const u8 {
    if ((try db.get(queries.BuildExecutable, 0)).*) |built| return built.bytes;
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, compiler.structures.Diagnostic, allocator);
    defer allocator.free(diagnostics);
    for (diagnostics) |diagnostic| std.debug.print("{any}\n", .{diagnostic});
    return error.CompilationFailed;
}

fn writeProgram(init: std.process.Init, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(init.io, "history-program", .{ .permissions = .executable_file });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, bytes);
}

fn runProgram(init: std.process.Init, expected: u8) !void {
    var child = try std.process.spawn(init.io, .{ .argv = &.{"./history-program"} });
    switch (try child.wait(init.io)) {
        .exited => |code| if (code != expected) return error.IncorrectProgramResult,
        else => return error.ProgramDidNotExitNormally,
    }
}

fn validate(init: std.process.Init, bytes: []const u8, expected: u8) !void {
    defer std.Io.Dir.cwd().deleteFile(init.io, "history-program") catch {};
    try writeProgram(init, bytes);
    try runProgram(init, expected);
}

fn runRuntimeProgram(init: std.process.Init, program: []const u8, limit: u32) !std.process.RunResult {
    var input: [4]u8 = undefined;
    std.mem.writeInt(u32, &input, limit, .little);
    var child = try std.process.spawn(init.io, .{ .argv = &.{program}, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe });
    defer child.kill(init.io);
    try child.stdin.?.writeStreamingAll(init.io, &input);
    child.stdin.?.close(init.io);
    child.stdin = null;
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(init.gpa, init.io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(64, .none)) |_| {} else |err| {
        switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }
    try reader.checkAnyError();
    const term = try child.wait(init.io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer init.gpa.free(stdout);
    return .{ .term = term, .stdout = stdout, .stderr = try reader.toOwnedSlice(1) };
}

fn validateRuntimeOutput(allocator: std.mem.Allocator, result: std.process.RunResult, expected: []const u8) !void {
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.IncorrectProgramResult,
        else => return error.ProgramDidNotExitNormally,
    }
    if (!std.mem.eql(u8, result.stdout, expected)) return error.IncorrectProgramResult;
    if (result.stderr.len != 0) return error.UnexpectedProgramOutput;
}

fn measureCompilation(init: std.process.Init, writer: *std.Io.Writer, lines: usize, samples: ?usize, workers: usize) !void {
    var workload = try workload_generator.generate(init.gpa, lines);
    defer workload.deinit();
    const allocator = init.arena.allocator();
    const files = try allocator.alloc(compiler.modules.SourceFile, workload.files.len);
    for (workload.files, files) |source, *file|
        file.* = .{ .path = source.path, .source = source.source, .module_path = source.module_path };
    const name = if (lines == 1_000_000) compilation_case else try std.fmt.allocPrint(allocator, "probe-core-{d}", .{lines});
    const lane = if (workers == 0) "normal" else try std.fmt.allocPrint(allocator, "workers-{d}", .{workers});
    std.debug.print("history: {s}: {d} code lines, {d} modules, {d} mixed-feature units, {d} workers\n", .{
        name, workload.lines, workload.files.len, workload.units, workers,
    });
    var cold: sampling.Sampling = .{ .fixed_count = samples, .limit = sampling.compilation_maximum_samples };
    var edit: sampling.Sampling = .{ .fixed_count = samples, .limit = sampling.compilation_maximum_samples };
    var database: ?*compiler.query.Database = null;
    defer if (database) |db| db.deinit();
    var registry: compiler.modules.SourceRegistry = .{};
    defer registry.deinit(init.gpa);
    var leaf_value: u8 = 41;
    var warmup = true;
    while (true) {
        if (warmup or !cold.complete()) {
            if (database) |db| db.deinit();
            database = null;
            registry.deinit(init.gpa);
            registry = .{};
            const started = std.Io.Clock.awake.now(init.io);
            const db = try compiler.query.Database.init(init.gpa, .{ .worker_count = workers });
            database = db;
            try registry.update(db, init.gpa, workload.entry, files, &.{});
            if (has_standard_bundle) _ = try compiler.standard_bundle.install(db, standard_bundle);
            const bytes = try executable(db, init.gpa);
            const ended = std.Io.Clock.awake.now(init.io);
            if (!warmup) try cold.add(started.durationTo(ended).toNanoseconds(), bytes.len);
            try validate(init, bytes, 42);
            leaf_value = 41;
        }
        if (warmup or !edit.complete()) {
            const db = database.?;
            leaf_value += 1;
            const source = try std.fmt.allocPrint(init.gpa, "pub func value() int -> {d}\n", .{leaf_value});
            defer init.gpa.free(source);
            const started = std.Io.Clock.awake.now(init.io);
            try db.setInput(queries.SourceText, registry.fileId(files[files.len - 1].path).?, source);
            const bytes = try executable(db, init.gpa);
            const ended = std.Io.Clock.awake.now(init.io);
            if (!warmup) try edit.add(started.durationTo(ended).toNanoseconds(), bytes.len);
            try validate(init, bytes, leaf_value + 1);
        }
        warmup = false;
        if (cold.complete() and edit.complete()) break;
    }
    try cold.write(writer, name, lane, "cold");
    try edit.write(writer, name, lane, "leaf-edit");
    try writer.flush();
}

fn measureRuntime(init: std.process.Init, writer: *std.Io.Writer, skip_c: bool, samples: ?usize) !void {
    const source =
        \\import std.io.{stdin, read_bytes}
        \\func run() unit | none
        \\  var input: List(byte) = []
        \\  loop
        \\    if input.len() == 4 -> break
        \\    const received: int = read_bytes(stdin, input, 4 - input.len()) else return none
        \\    if not (received > 0) -> return none
        \\  const limit = byte_int(input[0]) + 256 * byte_int(input[1]) + 65536 * byte_int(input[2]) + 16777216 * byte_int(input[3])
        \\  if not (limit >= 2) -> return none
        \\  var composite: List(int) = List(int).filled(0, limit + 1) else return none
        \\  var factor = 2
        \\  loop
        \\    if factor * factor > limit -> break
        \\    if composite[factor] == 0
        \\      var multiple = factor * factor
        \\      loop
        \\        if multiple > limit -> break
        \\        composite[multiple] = 1
        \\        multiple += factor
        \\    factor += 1
        \\  var count = 0
        \\  for number in 2..(limit + 1)
        \\    if composite[number] == 0 -> count += 1
        \\  print(count)
        \\  return ()
        \\if (run() is unit) -> exit(0)
        \\exit(1)
    ;
    const db = try compiler.query.Database.init(init.gpa, .{ .worker_count = 0 });
    defer db.deinit();
    var registry: compiler.modules.SourceRegistry = .{};
    defer registry.deinit(init.gpa);
    try registry.update(db, init.gpa, source, &.{}, &.{});
    if (has_standard_bundle) _ = try compiler.standard_bundle.install(db, standard_bundle);
    const bytes = try executable(db, init.gpa);
    defer std.Io.Dir.cwd().deleteFile(init.io, "history-program") catch {};
    try writeProgram(init, bytes);
    try measureRuntimeProgram(init, writer, "normal", "./history-program", bytes.len, samples);
    if (skip_c) return;
    defer std.Io.Dir.cwd().deleteFile(init.io, "history-c-program") catch {};
    for ([_][]const u8{ "-O0", "-O3" }) |optimization| {
        var child = try std.process.spawn(init.io, .{ .argv = &.{ "cc", "-std=c11", optimization, "benchmarks/history_runtime.c", "-o", "history-c-program" } });
        switch (try child.wait(init.io)) {
            .exited => |code| if (code != 0) return error.CCompilationFailed,
            else => return error.CCompilationFailed,
        }
        const file = try std.Io.Dir.cwd().openFile(init.io, "history-c-program", .{});
        const size = (try file.stat(init.io)).size;
        file.close(init.io);
        const lane = try std.fmt.allocPrint(init.arena.allocator(), "c{s}", .{optimization});
        try measureRuntimeProgram(init, writer, lane, "./history-c-program", size, samples);
    }
}

fn measureRuntimeProgram(init: std.process.Init, writer: *std.Io.Writer, lane: []const u8, program: []const u8, size: usize, samples: ?usize) !void {
    std.debug.print("history: {s} (runtime, {s})\n", .{ runtime_case, lane });
    const probes = [_]struct { limit: u32, expected: []const u8 }{
        .{ .limit = 2, .expected = "1\n" },
        .{ .limit = 10, .expected = "4\n" },
        .{ .limit = 100, .expected = "25\n" },
        .{ .limit = 1000, .expected = "168\n" },
    };
    for (probes) |probe| {
        const result = try runRuntimeProgram(init, program, probe.limit);
        try validateRuntimeOutput(init.gpa, result, probe.expected);
    }
    var measured: sampling.Sampling = .{ .fixed_count = samples };
    for (0..sampling.maximum_samples + 1) |sample| {
        const started = std.Io.Clock.awake.now(init.io);
        const result = try runRuntimeProgram(init, program, runtime_limit);
        const ended = std.Io.Clock.awake.now(init.io);
        try validateRuntimeOutput(init.gpa, result, "5107832\n");
        if (sample == 0) continue;
        try measured.add(started.durationTo(ended).toNanoseconds(), size);
        if (measured.complete()) break;
    }
    try measured.write(writer, runtime_case, lane, "runtime");
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var skip_c = false;
    var selected: ?[]const u8 = null;
    var lines: usize = 1_000_000;
    var samples: ?usize = null;
    var workers: usize = 0;
    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--skip-c")) {
            skip_c = true;
        } else if (std.mem.startsWith(u8, argument, "--case=")) {
            selected = argument["--case=".len..];
        } else if (std.mem.startsWith(u8, argument, "--lines=")) {
            lines = try std.fmt.parseInt(usize, argument["--lines=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--samples=")) {
            samples = try std.fmt.parseInt(usize, argument["--samples=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--workers=")) {
            workers = try std.fmt.parseInt(usize, argument["--workers=".len..], 10);
        } else return error.InvalidArgument;
    }
    if (samples) |count| if (count == 0 or count > sampling.maximum_samples) return error.InvalidArgument;
    if (workers > 64) return error.InvalidArgument;
    if (selected) |name| {
        if (!std.mem.eql(u8, name, compilation_case) and
            !std.mem.eql(u8, name, runtime_case)) return error.InvalidArgument;
    }
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("case,lane,phase,sample,nanoseconds,executable_bytes,sample_count,stable\n");
    if (selected == null or std.mem.eql(u8, selected.?, compilation_case))
        try measureCompilation(init, writer, lines, samples, workers);
    if (selected == null or std.mem.eql(u8, selected.?, runtime_case))
        try measureRuntime(init, writer, skip_c, samples);
    try writer.flush();
}
