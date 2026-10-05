const std = @import("std");
const compiler = @import("compiler");
const query = compiler.query;
const queries = compiler.queries;
const structures = compiler.structures;

var benchmark_io: std.Io = undefined;

const Measurement = struct {
    nanoseconds: i96,
    body: compiler.typing.BodyMeasurements,
};

const Measure = struct {
    pub const Input = bool;
    pub const Output = Measurement;

    pub fn run(ctx: anytype, collect_measurements: Input) !Output {
        const scope = (try ctx.get(queries.BuildModuleScope, 1)).* orelse return error.InvalidFixture;
        const item = scope.resolveFunction("probe") orelse return error.InvalidFixture;
        const signature = (try ctx.get(queries.FunctionSignature, item)).* orelse return error.InvalidFixture;
        const resolved = (try ctx.get(queries.ResolveItem, item)).* orelse return error.InvalidFixture;
        const parsed = (try ctx.get(queries.ParseFile, 1)).* orelse return error.InvalidFixture;
        const source = (try ctx.input(queries.SourceText, 1)).*;
        const instance: structures.InstanceId = .{ .item = item };
        const analysis: queries.AnalysisContext(@TypeOf(ctx)) = .{
            .ctx = ctx,
            .file_id = 1,
            .instance = instance,
        };
        var unresolved = switch (try compiler.semantic.buildUnresolvedBody(
            &parsed,
            source,
            resolved.declaration,
            .function,
            signature.parameters,
            analysis,
            ctx.allocator(),
        )) {
            .success => |body| body,
            .unsupported => return error.InvalidFixture,
        };
        defer unresolved.deinit(ctx.allocator());
        var measurements: compiler.typing.BodyMeasurements = .{};
        const started = std.Io.Clock.awake.now(benchmark_io);
        var body = (try compiler.typing.resolveAndTypeBody(
            ctx,
            instance,
            1,
            signature.parameters,
            signature.return_type,
            signature.is_fallible,
            .{ .measurements = if (collect_measurements) &measurements else null },
            analysis,
            unresolved,
        )) orelse return error.InvalidFixture;
        const nanoseconds = started.durationTo(std.Io.Clock.awake.now(benchmark_io)).toNanoseconds();
        defer body.deinit(ctx.allocator());
        return .{ .nanoseconds = nanoseconds, .body = measurements };
    }
};

fn appendLine(source: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime format: []const u8, arguments: anytype) !void {
    const line = try std.fmt.allocPrint(allocator, format, arguments);
    defer allocator.free(line);
    try source.appendSlice(allocator, line);
}

fn benchmark(init: std.process.Init, writer: *std.Io.Writer, count: u32, owning: bool) !void {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(init.gpa);
    if (owning) try source.appendSlice(init.gpa, "struct Item\n  value: int\n  drop = func(deinit self: Item) -> return\n");
    try source.appendSlice(init.gpa, "static probe = func(flag: int) int\n  var total = 0\n");
    for (0..count) |index| {
        if (owning) {
            try appendLine(&source, init.gpa, "  var v{d} = Item{{value = flag + {d}}}\n", .{ index, index });
        } else {
            try appendLine(&source, init.gpa, "  var v{d} = flag + {d}\n", .{ index, index });
        }
    }
    for (0..count) |index| try appendLine(&source, init.gpa, "  if flag < {d} -> v{d}{s} += 1\n", .{ index, index, if (owning) ".value" else "" });
    for (0..count) |index| try appendLine(&source, init.gpa, "  total += v{d}{s}\n", .{ index, if (owning) ".value" else "" });
    try source.appendSlice(init.gpa, "  return total\n");

    var times: [5]i96 = undefined;
    var measured: compiler.typing.BodyMeasurements = undefined;
    for (0..(times.len + 1)) |sample_index| {
        const db = try query.Database.init(init.gpa, .{ .worker_count = 1 });
        defer db.deinit();
        const module = try db.intern(queries.ModulePaths, .{ .path = "" });
        try db.addInput(queries.SourceText, 1, source.items);
        try db.addInput(queries.FileModule, 1, module);
        try db.addInput(queries.ModuleMembers, module, &.{1});
        const collect_measurements = sample_index == times.len;
        const result = (try db.get(Measure, collect_measurements)).*;
        if (collect_measurements) {
            measured = result.body;
        } else times[sample_index] = result.nanoseconds;
    }
    std.mem.sort(i96, &times, {}, std.sort.asc(i96));
    try writer.print("{s},{d},{d},{d},{d},{d},{d},{d}\n", .{
        if (owning) "owning" else "scalar",
        count,
        times[2],
        measured.snapshots,
        measured.snapshot_bytes,
        measured.blocks,
        measured.generations,
        measured.lifetime_table_bytes,
    });
}

pub fn main(init: std.process.Init) !void {
    benchmark_io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const writer = &stdout.interface;
    try writer.writeAll("kind,branches,typing_ns,snapshots,snapshot_bytes,blocks,generations,lifetime_bytes\n");
    for ([_]bool{ false, true }) |owning| {
        for ([_]u32{ 8, 32, 128, 256, 512 }) |count| try benchmark(init, writer, count, owning);
    }
    try writer.flush();
}
