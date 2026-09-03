const std = @import("std");
const debug = @import("debug.zig");
const diagnostics = @import("diagnostics.zig");
const query = @import("query_new.zig");
const queries = @import("query_structures.zig");
const runtime = @import("runtime.zig");
const structures = @import("structures.zig");

const file_id: structures.FileId = 0;

const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    @"asm": bool = false,
    timing: bool = false,
};

const RunInput = struct {
    source_path: []const u8,
    source: []const u8,
    program_args: []const []const u8,
    debug_flags: DebugFlags,
    started: std.Io.Timestamp,
};

const StageTiming = struct {
    label: []const u8,
    duration: std.Io.Duration,
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
        "usage: {s} [--debug=ast,ssa,asm,timing] <source-file> [program-args...]\n",
        .{executable_name},
    );
}

fn printTimings(
    writer: *std.Io.Writer,
    stages: []const StageTiming,
    total: std.Io.Duration,
) !void {
    try writer.writeAll("timing\n");
    for (stages) |stage| {
        try writer.print("  {s}: {d} us\n", .{ stage.label, stage.duration.toMicroseconds() });
    }
    try writer.print("  total: {d} us\n", .{total.toMicroseconds()});
}

fn freeDiagnostics(gpa: std.mem.Allocator, values: []structures.Diagnostic) void {
    for (values) |*diagnostic| diagnostic.deinit(gpa);
    gpa.free(values);
}

fn compileAndRun(
    io: std.Io,
    gpa: std.mem.Allocator,
    input: RunInput,
    output: *std.Io.Writer,
    errors: *std.Io.Writer,
) !?u8 {
    const database_started = std.Io.Clock.awake.now(io);
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    const database_initialized = std.Io.Clock.awake.now(io);
    try db.addInput(queries.SourceText, file_id, input.source);
    const source_added = std.Io.Clock.awake.now(io);

    const executable_result = try db.get(queries.BuildExecutable, file_id);
    const executable_built = std.Io.Clock.awake.now(io);
    const emitted = try db.transitiveAccumulatorValues(
        queries.BuildExecutable,
        file_id,
        structures.Diagnostic,
        gpa,
    );
    defer freeDiagnostics(gpa, emitted);
    const diagnostics_collected = std.Io.Clock.awake.now(io);

    const debug_started = diagnostics_collected;
    if (input.debug_flags.ast) {
        if ((try db.get(queries.ParseFile, file_id)).*) |parsed| {
            try debug.renderAst(gpa, &parsed, input.source, output);
        }
    }
    if (executable_result.* == null) {
        std.debug.assert(emitted.len != 0);
        try output.flush();
        const debug_finished = std.Io.Clock.awake.now(io);
        try diagnostics.renderDiagnostics(errors, input.source_path, input.source, emitted);
        if (input.debug_flags.timing) {
            const finished = std.Io.Clock.awake.now(io);
            try printTimings(errors, &.{
                .{ .label = "load source", .duration = input.started.durationTo(database_started) },
                .{ .label = "database init", .duration = database_started.durationTo(database_initialized) },
                .{ .label = "add source", .duration = database_initialized.durationTo(source_added) },
                .{ .label = "build executable", .duration = source_added.durationTo(executable_built) },
                .{ .label = "collect diagnostics", .duration = executable_built.durationTo(diagnostics_collected) },
                .{ .label = "debug output", .duration = debug_started.durationTo(debug_finished) },
            }, input.started.durationTo(finished));
        }
        try errors.flush();
        return null;
    }
    std.debug.assert(emitted.len == 0);
    const executable = executable_result.*.?;

    if (input.debug_flags.ssa) try debug.renderReachableSsa(db, file_id, output);
    if (input.debug_flags.@"asm") try debug.renderAssembly(executable, gpa, output);
    try output.flush();
    const debug_finished = std.Io.Clock.awake.now(io);

    try runtime.writeProgram(io, executable.bytes);
    const write_finished = std.Io.Clock.awake.now(io);
    const exit_code = try runtime.runProg(io, gpa, input.program_args);
    const run_finished = std.Io.Clock.awake.now(io);

    if (input.debug_flags.timing) {
        try printTimings(errors, &.{
            .{ .label = "load source", .duration = input.started.durationTo(database_started) },
            .{ .label = "database init", .duration = database_started.durationTo(database_initialized) },
            .{ .label = "add source", .duration = database_initialized.durationTo(source_added) },
            .{ .label = "build executable", .duration = source_added.durationTo(executable_built) },
            .{ .label = "collect diagnostics", .duration = executable_built.durationTo(diagnostics_collected) },
            .{ .label = "debug output", .duration = debug_started.durationTo(debug_finished) },
            .{ .label = "write program", .duration = debug_finished.durationTo(write_finished) },
            .{ .label = "run program", .duration = write_finished.durationTo(run_finished) },
        }, input.started.durationTo(run_finished));
        try errors.flush();
    }
    return exit_code;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const output = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const errors = &stderr_writer.interface;

    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);
    var debug_flags: DebugFlags = .{};
    var valid_arguments = true;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug=")) {
            var names = std.mem.splitScalar(u8, arg["--debug=".len..], ',');
            while (names.next()) |name| {
                if (!trySetDebugFlag(&debug_flags, name)) {
                    try printError(errors, "unknown debug flag '{s}'", .{name});
                    valid_arguments = false;
                }
            }
        } else {
            try positional.append(gpa, arg);
        }
    }

    if (!valid_arguments or positional.items.len == 0) {
        try printUsage(errors, args[0]);
        try errors.flush();
        return;
    }

    const started = std.Io.Clock.awake.now(io);
    const source_path = positional.items[0];
    const source = std.Io.Dir.cwd().readFileAlloc(
        io,
        source_path,
        gpa,
        .limited(std.math.maxInt(usize)),
    ) catch |read_error| {
        try printError(errors, "failed to read '{s}': {s}", .{ source_path, @errorName(read_error) });
        try errors.flush();
        return;
    };
    defer gpa.free(source);

    const exit_code = compileAndRun(io, gpa, .{
        .source_path = source_path,
        .source = source,
        .program_args = positional.items[1..],
        .debug_flags = debug_flags,
        .started = started,
    }, output, errors) catch |run_error| {
        try printError(errors, "compiler execution failed: {s}", .{@errorName(run_error)});
        try errors.flush();
        return run_error;
    };
    if (exit_code) |code| {
        try output.print("exit code: {d}\n", .{code});
        try output.flush();
    } else {
        // Rejected source is an expected user error: exit quietly so the
        // caller sees status 1 without the runtime's error trace.
        std.process.exit(1);
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

    try std.testing.expectEqual(@as(?u8, 42), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "AST\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "SSA\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "ASM\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "db 0x") == null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "timing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "database init:") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "build executable:") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "collect diagnostics:") != null);
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

    try std.testing.expectEqual(@as(?u8, null), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "AST\n") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errors.writer.buffered(),
        "broken.chi:1:1: call argument count does not match function signature",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "timing\n") != null);
}

test "CLI core rejects duplicate top-level function names without running" {
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

    try std.testing.expectEqual(@as(?u8, null), exit_code);
    try std.testing.expectEqual(@as(usize, 0), output.writer.buffered().len);
    try std.testing.expect(std.mem.indexOf(
        u8,
        errors.writer.buffered(),
        "duplicates.chi:2:8: duplicate top-level function name",
    ) != null);
}
