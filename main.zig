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
    memory: bool = false,
};

const RunInput = struct {
    source_path: []const u8,
    source: []const u8,
    program_args: []const []const u8,
    debug_flags: DebugFlags,
    started: std.Io.Timestamp,
};

const RunOutcome = union(enum) {
    program_exit: u8,
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
        "usage: {s} [--debug=ast,ssa,asm,timing,memory] <source-file> [program-args...]\n",
        .{executable_name},
    );
}

fn buildWithStageTimings(db: *query.Database, io: std.Io, timings: *diagnostics.TimingLog) !void {
    _ = try db.get(queries.ParseFile, file_id);
    timings.mark(io, "parse");
    const index = try db.get(queries.IndexItems, file_id);
    timings.mark(io, "discover items");
    if (index.*) |items| {
        for (items.ids()) |item_id| _ = try db.get(queries.ResolveItem, item_id);
        timings.mark(io, "resolve items");
        for (items.ids()) |item_id| _ = try db.get(queries.FunctionShape, item_id);
        timings.mark(io, "function shapes");
        for (items.ids()) |item_id| _ = try db.get(queries.FunctionSignature, item_id);
        timings.mark(io, "signatures");
        for (items.ids()) |item_id| _ = try db.get(queries.AnalyzeFunctionBody, item_id);
    }
    timings.mark(io, "analyze bodies");
    _ = try db.get(queries.CollectReachableInstances, file_id);
    timings.mark(io, "compile functions");
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
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    timings.mark(io, "database init");
    try db.addInput(queries.SourceText, file_id, input.source);
    timings.mark(io, "add source");

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

    if (input.debug_flags.ast) {
        if ((try db.get(queries.ParseFile, file_id)).*) |parsed| {
            try debug.renderAst(gpa, &parsed, input.source, output);
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
        const type_interner: queries.TypeInterner(*query.Database) = .{ .ctx = db };
        try diagnostics.renderDiagnostics(type_interner, errors, input.source_path, input.source, emitted);
        if (input.debug_flags.timing) try timings.print(io, errors);
        try errors.flush();
        return .rejected;
    }
    std.debug.assert(emitted.len == 0);
    const executable = executable_result.*.?;

    if (input.debug_flags.ssa) try debug.renderReachableSsa(db, file_id, output);
    if (input.debug_flags.@"asm") try debug.renderAssembly(executable, gpa, output);
    try output.flush();
    timings.mark(io, "debug output");

    try runtime.writeProgram(io, executable.bytes);
    timings.mark(io, "write program");
    const exit_code = try runtime.runProg(io, gpa, input.program_args);
    timings.mark(io, "run program");

    if (input.debug_flags.timing) {
        try timings.print(io, errors);
        try errors.flush();
    }
    return .{ .program_exit = exit_code };
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

    var positional: std.ArrayList([]const u8) = .empty;
    var debug_flags: DebugFlags = .{};
    var valid_arguments = true;

    const args = try init.minimal.args.toSlice(arena);
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
            try positional.append(arena, arg);
        }
    }

    if (!valid_arguments or positional.items.len == 0) {
        try printUsage(errors, args[0]);
        try errors.flush();
        std.process.exit(1);
    }

    // Tracking allocates nothing but adds per-allocation bookkeeping.
    var tracker: diagnostics.MemoryTracker = .{ .backing = init.gpa };
    const gpa = if (debug_flags.memory) tracker.allocator() else init.gpa;

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
        std.process.exit(1);
    };
    defer gpa.free(source);

    const outcome = compileAndRun(io, gpa, .{
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
    if (debug_flags.memory) {
        try tracker.print(errors);
        try errors.flush();
    }
    switch (outcome) {
        .program_exit => |code| {
            try output.print("exit code: {d}\n", .{code});
            try output.flush();
        },
        .compiler_exit => |code| std.process.exit(code),
        .rejected => {
            // Rejected source is an expected user error: exit quietly so the
            // caller sees status 1 without the runtime's error trace.
            std.process.exit(1);
        },
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

    try std.testing.expectEqual(RunOutcome{ .program_exit = 42 }, exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "AST\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "SSA\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "ASM\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.writer.buffered(), "db 0x") == null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "timing\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "database init") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "analyze bodies") != null);
    try std.testing.expect(std.mem.indexOf(u8, errors.writer.buffered(), "compile functions") != null);
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
        \\static fail = func() int -> 42 / 0
        \\static middle = func() int -> fail()
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
