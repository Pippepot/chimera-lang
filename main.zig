const std = @import("std");
const debug = @import("debug.zig");
const db = @import("db.zig");
const query = @import("query.zig");
const runtime = @import("runtime.zig");
const disasm = @import("disasm.zig");

fn usage(io: std.Io, exe: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print("usage: {s} [--debug=ast,ssa,timing,query,asm] [--nocache] <source-file> [program-args...]\n", .{exe});
    try w.interface.flush();
}

fn printTimings(io: std.Io, header: []const u8, stages: []const StageTiming, total: std.Io.Duration) !void {
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print("; {s}:\n", .{header});
    for (stages) |s| {
        try w.interface.print(";   {s}: {d} us\n", .{ s.label, s.duration.toMicroseconds() });
    }
    try w.interface.print(";   total: {d} us\n", .{total.toMicroseconds()});
    try w.interface.flush();
}

fn printDiags(io: std.Io, gpa: std.mem.Allocator, path: []const u8, source: []const u8, diags: []const db.Diagnostic) !void {
    var text = try std.ArrayList(u8).initCapacity(gpa, 512);
    defer text.deinit(gpa);
    try db.appendDiagnostics(&text, gpa, path, source, diags);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(text.items);
    try w.interface.flush();
}

fn printStats(io: std.Io, gpa: std.mem.Allocator, stats: query.QueryStats) !void {
    var text = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer text.deinit(gpa);
    try stats.print(&text, gpa);
    var buf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.writeAll(text.items);
    try w.interface.flush();
}

const StageTiming = struct {
    label: []const u8,
    duration: std.Io.Duration,
};

const Timing = struct {
    start: ?std.Io.Timestamp,

    fn begin(io: std.Io, enabled: bool) Timing {
        return .{ .start = if (enabled) std.Io.Clock.awake.now(io) else null };
    }

    fn end(self: Timing, io: std.Io) std.Io.Duration {
        return if (self.start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const flags = debug.parseDebugFlags(init.minimal.args);
    var cache = true;

    var arg_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer arg_list.deinit(gpa);

    var iter = std.process.Args.Iterator.init(init.minimal.args);
    defer iter.deinit();
    const exe = iter.next() orelse "main";
    while (iter.next()) |a| {
        if (std.mem.startsWith(u8, a, "--debug=")) continue;
        if (std.mem.eql(u8, a, "--nocache")) {
            cache = false;
            continue;
        }
        try arg_list.append(gpa, a);
    }

    const args = arg_list.items;
    if (args.len == 0) {
        try usage(io, exe);
        return error.MissingSourceFile;
    }

    const src_path = args[0];
    const prog_args = args[1..];

    var qdb = query.QueryDb.initWithOptions(gpa, .{
        .persistent_cache_enabled = cache,
        .io = io,
    });
    defer qdb.deinit();

    const t_src = Timing.begin(io, flags.timing);
    const src_text = std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(std.math.maxInt(usize))) catch |err| {
        var buf: [512]u8 = undefined;
        var w = std.Io.File.stderr().writer(io, &buf);
        w.interface.print("\x1b[31merror:\x1b[0m failed to read '{s}': {s}\n", .{ src_path, @errorName(err) }) catch {};
        w.interface.flush() catch {};
        return error.SourceReadError;
    };
    defer gpa.free(src_text);
    try qdb.setSourceFile(0, src_path, src_text);
    const d_src = t_src.end(io);

    var d_parse = std.Io.Duration.zero;
    var d_resolve = std.Io.Duration.zero;
    var d_type = std.Io.Duration.zero;
    var d_lower = std.Io.Duration.zero;
    var d_debug = std.Io.Duration.zero;

    if (flags.timing or flags.ast or flags.ssa) {
        const t = Timing.begin(io, flags.timing);
        const mod = try qdb.parsedAst(0);
        d_parse = t.end(io);

        const t2 = Timing.begin(io, flags.timing);
        _ = try qdb.resolvedAst(0);
        d_resolve = t2.end(io);

        const t3 = Timing.begin(io, flags.timing);
        _ = try qdb.typedAst(0);
        d_type = t3.end(io);

        const t4 = Timing.begin(io, flags.timing);
        const ir = try qdb.loweredProgram(0);
        d_lower = t4.end(io);

        const t5 = Timing.begin(io, flags.timing);
        try debug.dumpDebugInfo(io, flags, mod, ir, null, gpa);
        d_debug = t5.end(io);
    }

    const t_comp = Timing.begin(io, flags.timing);
    const result = try qdb.compileResult(0);
    const d_comp = t_comp.end(io);

    if (flags.x86 and result.bytes != null) {
        const len = std.mem.readInt(u32, result.bytes.?[120..124], .little);
        const asm_text = try disasm.disassemble(result.bytes.?[0x1000..][0..@intCast(len)], gpa);
        defer gpa.free(asm_text);
        try debug.dumpDebugInfo(io, flags, null, null, asm_text, gpa);
    }

    if (flags.timing) {
        const total = std.Io.Duration{
            .nanoseconds = d_src.nanoseconds + d_parse.nanoseconds + d_resolve.nanoseconds + d_type.nanoseconds + d_lower.nanoseconds + d_debug.nanoseconds + d_comp.nanoseconds,
        };
        try printTimings(io, "compilation timing diagnostics", &.{
            .{ .label = "set_source", .duration = d_src },
            .{ .label = "parse", .duration = d_parse },
            .{ .label = "resolve", .duration = d_resolve },
            .{ .label = "typecheck", .duration = d_type },
            .{ .label = "lower", .duration = d_lower },
            .{ .label = "debug_dump", .duration = d_debug },
            .{ .label = "compile_query", .duration = d_comp },
        }, total);
    }

    const has_err = result.diagnostics.len > 0 or result.bytes == null;
    if (has_err or flags.query) {
        if (has_err) try printDiags(io, gpa, src_path, src_text, result.diagnostics);
        if (flags.query) try printStats(io, gpa, qdb.statsSnapshot());
        if (has_err) return;
    }

    const t_write = Timing.begin(io, flags.timing);
    runtime.writeProgram(io, result.bytes.?);
    const d_write = t_write.end(io);

    const t_run = Timing.begin(io, flags.timing);
    _ = runtime.runProg(io, gpa, prog_args);
    const d_run = t_run.end(io);

    if (flags.timing) {
        try printTimings(io, "runtime timing diagnostics", &.{
            .{ .label = "write_prog", .duration = d_write },
            .{ .label = "run_prog", .duration = d_run },
        }, .{ .nanoseconds = d_write.nanoseconds + d_run.nanoseconds });
    }
}
