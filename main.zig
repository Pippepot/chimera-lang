const std = @import("std");
const debug = @import("debug.zig");
const codegen = @import("codegen.zig");
const query = @import("query.zig");

pub const IfNode = struct {
    cond: *const AstNode,
    then_: *const AstNode,
    else_: ?*const AstNode,
};

pub const ConstNode = struct {
    name: []const u8,
    value: *const AstNode,
    body: *const AstNode,
};

pub const AstNode = union(enum) {
    int: i32,
    float: f32,
    var_ref: []const u8,
    seq: *const [2]AstNode,
    const_: *const ConstNode,
    print: *const AstNode,
    add: *const [2]AstNode,
    sub: *const [2]AstNode,
    mul: *const [2]AstNode,
    div: *const [2]AstNode,
    arg: u32,
    lt: *const [2]AstNode,
    gt: *const [2]AstNode,
    le: *const [2]AstNode,
    ge: *const [2]AstNode,
    eq: *const [2]AstNode,
    ne: *const [2]AstNode,
    if_: *const IfNode,
};

fn printUsage(io: std.Io) !void {
    var wbuf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.writeAll("usage: zig run main.zig -- [--debug=ast,ssa,timing,query] <source-file> [program-args...]\n");
    try w.interface.flush();
}

fn waitForExitCode(io: std.Io, child: *std.process.Child) u8 {
    switch (child.wait(io) catch std.process.exit(1)) {
        .exited => |code| return code,
        else => std.process.exit(1),
    }
}

fn isDebugFlag(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "--debug=");
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

pub fn appendQueryDiagnostics(out: *std.ArrayList(u8), gpa: std.mem.Allocator, stats: query.QueryStats) !void {
    try out.appendSlice(gpa, "; query diagnostics:\n");
    try out.print(gpa, ";   revision: {d}\n", .{stats.revision});
    try out.print(gpa, ";   source_sets: {d}\n", .{stats.source_sets});
    try out.print(gpa, ";   source_unchanged: {d}\n", .{stats.source_unchanged});
    try out.print(gpa, ";   parse: hits={d} recomputes={d}\n", .{ stats.parse_hits, stats.parse_recomputes });
    try out.print(gpa, ";   type: hits={d} recomputes={d}\n", .{ stats.type_hits, stats.type_recomputes });
    try out.print(gpa, ";   lower: hits={d} recomputes={d}\n", .{ stats.lower_hits, stats.lower_recomputes });
    try out.print(gpa, ";   compile: hits={d} recomputes={d}\n", .{ stats.compile_hits, stats.compile_recomputes });
    try out.print(gpa, ";   dependencies: checks={d} invalidations={d}\n", .{ stats.dependency_checks, stats.dependency_invalidations });
}

fn printQueryStats(io: std.Io, gpa: std.mem.Allocator, stats: query.QueryStats) !void {
    var text = try std.ArrayList(u8).initCapacity(gpa, 256);
    defer text.deinit(gpa);
    try appendQueryDiagnostics(&text, gpa, stats);

    var wbuf: [2048]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.writeAll(text.items);
    try w.interface.flush();
}

pub fn writeProgram(io: std.Io, prog_bytes: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(io, .{
        .sub_path = "prog",
        .data = prog_bytes,
        .flags = .{ .permissions = .executable_file },
    }) catch std.process.exit(1);
}

pub fn runProg(io: std.Io, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    var argv = std.ArrayList([]const u8).initCapacity(gpa, 1 + args.len) catch std.process.exit(1);
    defer argv.deinit(gpa);

    argv.appendAssumeCapacity("./prog");
    for (args) |arg| argv.appendAssumeCapacity(arg);

    var child = std.process.spawn(io, .{ .argv = argv.items, .stderr = .inherit }) catch std.process.exit(1);
    return waitForExitCode(io, &child);
}

pub fn eval(io: std.Io, node: *const AstNode, gpa: std.mem.Allocator, args: []const []const u8) u8 {
    const prog_bytes = codegen.compile(node, gpa) catch std.process.exit(1);
    defer gpa.free(prog_bytes);

    writeProgram(io, prog_bytes);
    return runProg(io, gpa, args);
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
    _ = iter.next();
    while (iter.next()) |arg| {
        if (!isDebugFlag(arg)) try cli_args_list.append(gpa, arg);
    }

    const cli_args = cli_args_list.items;
    if (cli_args.len == 0) {
        try printUsage(io);
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
    const prog_bytes = try qdb.compileBytes(source_id);
    const compile_duration = if (compile_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    if (flags.query) {
        try printQueryStats(io, gpa, qdb.statsSnapshot());
    }

    const write_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    writeProgram(io, prog_bytes);
    const write_duration = if (write_start) |ts| ts.untilNow(io, .awake) else std.Io.Duration.zero;

    const run_start = if (flags.timing) std.Io.Clock.awake.now(io) else null;
    _ = runProg(io, gpa, prog_args);
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
