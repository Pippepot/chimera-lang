const std = @import("std");
const debug = @import("debug.zig");
const db = @import("db.zig");
const queryold = @import("query.zig");
const query = @import("query_new.zig");
const runtime = @import("runtime.zig");

// todo probs move to debug.zig
const DebugFlags = struct {
    ast: bool = false,
    ssa: bool = false,
    timing: bool = false,
    query: bool = false,
    @"asm": bool = false,
};

fn trySetDebugFlag(debugFlags: *DebugFlags, flag: []const u8) bool {
    inline for (@typeInfo(DebugFlags).@"struct".fields) |field| {
        if (std.mem.eql(u8, flag, field.name)) {
            @field(debugFlags, field.name) = true;
            return true;
        }
    }
    return false;
}

fn printUsage(io: std.Io, exe: []const u8) !void {
    var buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("usage: {s} [--debug=ast,ssa,timing,query,asm] [--nocache] <source-file> [program-args...]\n", .{exe});
    try stderr.flush();
}

// fn printTimings(io: std.Io, header: []const u8, stages: []const StageTiming, total: std.Io.Duration) !void {
//     var buf: [2048]u8 = undefined;
//     var w = std.Io.File.stderr().writer(io, &buf);
//     try w.interface.print("; {s}:\n", .{header});
//     for (stages) |s| {
//         try w.interface.print(";   {s}: {d} us\n", .{ s.label, s.duration.toMicroseconds() });
//     }
//     try w.interface.print(";   total: {d} us\n", .{total.toMicroseconds()});
//     try w.interface.flush();
// }

// fn printDiagnostics(io: std.Io, gpa: std.mem.Allocator, path: []const u8, source: []const u8, diags: []const db.Diagnostic) !void {
//     var text = try std.ArrayList(u8).initCapacity(gpa, 512);
//     defer text.deinit(gpa);
//     try db.appendDiagnostics(&text, gpa, path, source, diags);
//     var buf: [4096]u8 = undefined;
//     var w = std.Io.File.stderr().writer(io, &buf);
//     try w.interface.writeAll(text.items);
//     try w.interface.flush();
// }

// fn printStats(io: std.Io, gpa: std.mem.Allocator, stats: query.QueryStats) !void {
//     var text = try std.ArrayList(u8).initCapacity(gpa, 256);
//     defer text.deinit(gpa);
//     try stats.print(&text, gpa);
//     var buf: [2048]u8 = undefined;
//     var w = std.Io.File.stderr().writer(io, &buf);
//     try w.interface.writeAll(text.items);
//     try w.interface.flush();
// }

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var errorBuf: [512]u8 = undefined;
    var errorWriter = std.Io.File.stderr().writer(io, &errorBuf);
    const err = &errorWriter.interface;

    var arg_list = try std.ArrayList([]const u8).initCapacity(gpa, 4);
    defer arg_list.deinit(gpa);

    var args_ok = true;
    var query_cache = true;
    var debugFlags = DebugFlags{};
    var args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--debug=")) {
            var flags = std.mem.splitScalar(u8, arg["--debug=".len..], ',');
            while (flags.next()) |flag| {
                if (!trySetDebugFlag(&debugFlags, flag)) {
                    try debug.printError(err, "unknown debug flag {s}", .{flag});
                    args_ok = false;
                }
            }
        } else if (std.mem.eql(u8, arg, "--nocache")) {
            query_cache = false;
        } else {
            try arg_list.append(gpa, arg);
        }
    }

    if (!args_ok or arg_list.items.len == 0) {
        try printUsage(io, args[0]);
        return;
    }

    // Source -> tokenize -> parse (AST) -> semantic (name resolution & typing) -> ir (SSA) -> optimization -> codegen (x86)
    var qdb = query.QueryDB.init(gpa);
    defer qdb.deInit();

    const src_path = arg_list.items[0];
    const src_text = std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(std.math.maxInt(usize))) catch |e| {
        try debug.printError(err, "failed to read '{s}': {s}", .{ src_path, @errorName(e) });
        return;
    };
    defer gpa.free(src_text);

    try qdb.setSource(src_path, src_text);
    const program_binary = try qdb.compileResult(0);

    var debugBuf: [4096]u8 = undefined;
    var debug_writer = std.Io.File.stdout().writer(io, &debugBuf);

    if (debugFlags.ast) if (try qdb.parsedAst(0)) |ast| debug.dumpAst(ast, &debug_writer.interface);
    if (debugFlags.ssa) if (try qdb.loweredProgram(0)) |ssa| debug.dumpSSA(ssa, &debug_writer.interface);
    if (debugFlags.@"asm") if (program_binary.bytes) |bin| try debug.dumpAssembly(bin, &debug_writer.interface, gpa);
    // if (debugFlags.query) try printStats(io, gpa, qdb.statsSnapshot());

    // if (flags.timing) {
    //     const total = std.Io.Duration{
    //         .nanoseconds = d_src.nanoseconds + d_parse.nanoseconds + d_resolve.nanoseconds + d_type.nanoseconds + d_lower.nanoseconds + d_debug.nanoseconds + d_comp.nanoseconds,
    //     };
    //     try printTimings(io, "compilation timing diagnostics", &.{
    //         .{ .label = "set_source", .duration = d_src },
    //         .{ .label = "parse", .duration = d_parse },
    //         .{ .label = "resolve", .duration = d_resolve },
    //         .{ .label = "typecheck", .duration = d_type },
    //         .{ .label = "lower", .duration = d_lower },
    //         .{ .label = "debug_dump", .duration = d_debug },
    //         .{ .label = "compile_query", .duration = d_comp },
    //     }, total);
    // }

    const has_err = program_binary.diagnostics.len > 0 or program_binary.bytes == null;
    if (has_err) {
        // try printDiagnostics(io, gpa, src_path, src_text, program_binary.diagnostics);
        return;
    }

    runtime.writeProgram(io, program_binary.bytes.?);
    _ = runtime.runProg(io, gpa, arg_list.items);

    // if (flags.timing) {
    //     try printTimings(io, "runtime timing diagnostics", &.{
    //         .{ .label = "write_prog", .duration = d_write },
    //         .{ .label = "run_prog", .duration = d_run },
    //     }, .{ .nanoseconds = d_write.nanoseconds + d_run.nanoseconds });
    // }
}
