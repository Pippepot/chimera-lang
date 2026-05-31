// Chimera — Source → Query → Machine Code Compiler
const std = @import("std");
const debug = @import("debug.zig");
const diagnostics = @import("diagnostics.zig");
const query = @import("query.zig");
const runtime = @import("runtime.zig");
const disasm = @import("disasm.zig");

fn printUsage(io: std.Io, exe_name: []const u8) !void {
    var wbuf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.print("usage: {s} [--debug=ast,ssa,timing,query,asm] [--no-query-cache] <source-file> [program-args...]\n", .{exe_name});
    try w.interface.flush();
}

fn readSourceFile(io: std.Io, gpa: std.mem.Allocator, source_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, source_path, gpa, .limited(std.math.maxInt(usize)));
}

const StageTiming = struct {
    label: []const u8,
    duration: std.Io.Duration,
};

fn printStageTimings(io: std.Io, header: []const u8, stages: []const StageTiming, total: std.Io.Duration) !void {
    var wbuf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.print("; {s}:\n", .{header});
    for (stages) |stage| {
        try w.interface.print(";   {s}: {d} us\n", .{ stage.label, stage.duration.toMicroseconds() });
    }
    try w.interface.print(";   total: {d} us\n", .{total.toMicroseconds()});
    try w.interface.flush();
}

fn printQueryStats(io: std.Io, gpa: std.mem.Allocator, stats: query.QueryStats) !void {
    var text = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer text.deinit(gpa);
    try query.appendQueryDiagnostics(&text, gpa, stats);
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
    var persistent_cache_enabled = true;

    var cli_args_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer cli_args_list.deinit(gpa);

    var iter = std.process.Args.Iterator.init(init.minimal.args);
    defer iter.deinit();
    const exe_name = iter.next() orelse "main";
    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug=")) continue;
        if (std.mem.eql(u8, arg, "--no-query-cache")) {
            persistent_cache_enabled = false;
            continue;
        }
        try cli_args_list.append(gpa, arg);
    }

    const cli_args = cli_args_list.items;
    if (cli_args.len == 0) {
        try printUsage(io, exe_name);
        std.process.exit(1);
    }

    const source_path = cli_args[0];
    const prog_args = cli_args[1..];
    const source_id: query.SourceId = 0;

    var qdb = query.QueryDb.initWithOptions(gpa, .{
        .persistent_cache_enabled = persistent_cache_enabled,
        .io = io,
    });
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
    try qdb.setSourceFile(source_id, source_path, source_text);
    const set_source_duration = if (set_source_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const need_stage_debug = flags.ast or flags.ssa;
    const need_stage_pipeline = flags.timing or need_stage_debug;

    var parse_duration = std.Io.Duration.zero;
    var resolve_duration = std.Io.Duration.zero;
    var astgen_duration = std.Io.Duration.zero;
    var type_duration = std.Io.Duration.zero;
    var lower_duration = std.Io.Duration.zero;
    var debug_duration = std.Io.Duration.zero;
    if (need_stage_pipeline) {
        const parse_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
        const module_or_null = try qdb.parsedAst(source_id);
        parse_duration = if (parse_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

        const resolve_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
        _ = try qdb.resolvedAst(source_id);
        resolve_duration = if (resolve_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

        const astgen_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
        _ = try qdb.astgenIr(source_id);
        astgen_duration = if (astgen_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

        const type_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
        _ = try qdb.typedAst(source_id);
        type_duration = if (type_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

        const lower_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
        const ir = try qdb.loweredProgram(source_id);
        lower_duration = if (lower_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

        const debug_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
        try debug.dumpDebugInfo(io, flags, module_or_null, ir, null, gpa);
        debug_duration = if (debug_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;
    }

    const compile_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    const compile_result = try qdb.compileResult(source_id);
    const compile_duration = if (compile_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    if (flags.x86 and compile_result.bytes != null) {
        const program_code_len = std.mem.readInt(u32, compile_result.bytes.?[120..124], .little);
        const raw_code = compile_result.bytes.?[0x1000..];
        const asm_text = try disasm.disassemble(raw_code[0..@intCast(program_code_len)], gpa);
        defer gpa.free(asm_text);
        try debug.dumpDebugInfo(io, flags, null, null, asm_text, gpa);
    }

    if (flags.timing) {
        const compile_total = std.Io.Duration{
            .nanoseconds = set_source_duration.nanoseconds + parse_duration.nanoseconds + resolve_duration.nanoseconds + astgen_duration.nanoseconds + type_duration.nanoseconds + lower_duration.nanoseconds + debug_duration.nanoseconds + compile_duration.nanoseconds,
        };
        try printStageTimings(io, "compilation timing diagnostics", &.{
            .{ .label = "set_source", .duration = set_source_duration },
            .{ .label = "parse", .duration = parse_duration },
            .{ .label = "resolve", .duration = resolve_duration },
            .{ .label = "astgen", .duration = astgen_duration },
            .{ .label = "typecheck", .duration = type_duration },
            .{ .label = "lower", .duration = lower_duration },
            .{ .label = "debug_dump", .duration = debug_duration },
            .{ .label = "compile_query", .duration = compile_duration },
        }, compile_total);
    }

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
        const run_total = std.Io.Duration{
            .nanoseconds = write_duration.nanoseconds + run_duration.nanoseconds,
        };
        try printStageTimings(io, "runtime timing diagnostics", &.{
            .{ .label = "write_prog", .duration = write_duration },
            .{ .label = "run_prog", .duration = run_duration },
        }, run_total);
    }
}
