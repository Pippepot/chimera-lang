const std = @import("std");
const debug = @import("debug.zig");
const diagnostics = @import("diagnostics.zig");
const query = @import("query.zig");
const runtime = @import("runtime.zig");

fn printUsage(io: std.Io, exe_name: []const u8) !void {
    var wbuf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.print("usage: {s} [--debug=ast,ssa,timing,query] <source-file> [program-args...]\n", .{exe_name});
    try w.interface.flush();
}

fn readSourceFile(io: std.Io, gpa: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, source_path, gpa, .limited(std.math.maxInt(usize)));
}

const StageTiming = struct {
    label: []const u8,
    duration: std.Io.Duration,
};

fn printStageTimings(io: std.Io, stages: []const StageTiming, total: std.Io.Duration) !void {
    var wbuf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.writeAll("; timing diagnostics:\n");
    for (stages) |stage| {
        try w.interface.print(";   {s}: {d} us\n", .{ stage.label, stage.duration.toMicroseconds() });
    }
    try w.interface.print(";   total: {d} us\n", .{total.toMicroseconds()});
    try w.interface.flush();
}

fn printQueryStats(io: std.Io, gpa: std.mem.Allocator, stats: query.QueryStats) !void {
    var text = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer text.deinit(gpa);
    try runtime.appendQueryDiagnostics(&text, gpa, stats);
    var wbuf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.writeAll(text.items);
    try w.interface.flush();
}

fn printCompileDiagnostics(
    io: std.Io,
    gpa: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    diags: []const diagnostics.Diagnostic,
) !void {
    var text = try std.ArrayList(u8).initCapacity(gpa, 512);
    defer text.deinit(gpa);
    try diagnostics.appendDiagnostics(&text, gpa, source_path, source, diags);

    var wbuf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.writeAll(text.items);
    try w.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const flags = debug.parseDebugFlags(init.minimal.args);
    const total_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;

    var cli_args_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer cli_args_list.deinit(gpa);

    var iter = std.process.Args.Iterator.init(init.minimal.args);
    defer iter.deinit();
    const exe_name = iter.next() orelse "main";
    while (iter.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--debug=")) try cli_args_list.append(gpa, arg);
    }

    const cli_args = cli_args_list.items;
    if (cli_args.len == 0) {
        try printUsage(io, exe_name);
        std.process.exit(1);
    }

    const source_path = cli_args[0];
    const prog_args = cli_args[1..];
    const source_id: query.SourceId = 0;

    var qdb = query.QueryDb.init(gpa);
    defer qdb.deinit();

    const set_source_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    const source_text = readSourceFile(io, gpa, source_path) catch |err| {
        var wbuf: [512]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &wbuf);
        w.interface.print("error: failed to read source file '{s}': {s}\n", .{ source_path, @errorName(err) }) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    };
    defer gpa.free(source_text);
    try qdb.setSource(source_id, source_text);
    const set_source_duration = if (set_source_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const parse_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    const root = try qdb.parsedAst(source_id);
    const parse_duration = if (parse_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const type_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    _ = try qdb.typedAst(source_id);
    const type_duration = if (type_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const lower_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    const ir = try qdb.loweredProgram(source_id);
    const lower_duration = if (lower_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const debug_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    try debug.dumpDebugInfo(io, flags, root, ir, gpa);
    const debug_duration = if (debug_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const compile_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    const compile_result = try qdb.compileResult(source_id);
    const compile_duration = if (compile_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    if (compile_result.diagnostics.len > 0 or compile_result.bytes == null) {
        try printCompileDiagnostics(io, gpa, source_path, source_text, compile_result.diagnostics);
        if (flags.query) {
            try printQueryStats(io, gpa, qdb.statsSnapshot());
        }
        std.process.exit(1);
    }

    if (flags.query) {
        try printQueryStats(io, gpa, qdb.statsSnapshot());
    }

    const write_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    runtime.writeProgram(io, compile_result.bytes.?);
    const write_duration = if (write_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const run_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    _ = runtime.runProg(io, gpa, prog_args);
    const run_duration = if (run_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    if (flags.timing) {
        const total_duration = total_start.?.untilNow(io, .awake);
        try printStageTimings(io, &.{
            .{ .label = "set_source", .duration = set_source_duration },
            .{ .label = "parse", .duration = parse_duration },
            .{ .label = "typecheck", .duration = type_duration },
            .{ .label = "lower", .duration = lower_duration },
            .{ .label = "debug_dump", .duration = debug_duration },
            .{ .label = "compile_query", .duration = compile_duration },
            .{ .label = "write_prog", .duration = write_duration },
            .{ .label = "run_prog", .duration = run_duration },
        }, total_duration);
    }
}
