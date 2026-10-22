const std = @import("std");
const compiler = @import("compiler");
const queries = compiler.queries;
const standard_bundle = @embedFile("standard_bundle");

comptime {
    if (compiler.optimize_mode != @import("builtin").mode)
        @compileError("benchmark driver and compiler must use the same optimization mode");
}

const sample_count = 21;
const Case = struct { name: []const u8, source: []const u8 };
const cases = [_]Case{
    .{ .name = "exit", .source = "exit(42)" },
    .{ .name = "math", .source = "import std.math\nexit(std.math.clamp(50, 0, 42))" },
    .{ .name = "scalar-print", .source = "const i = 42\nprint(i)" },
    .{ .name = "collections-text-range", .source =
    \\import std.math
    \\var values: List(int) = [20, 22]
    \\const text = String(values)
    \\print(text)
    \\print(std.math.clamp(values[0] + values[1], 0, 42))
    \\for value in 0..3 -> print(value)
    },
};

const Sample = struct { compile: i96, lifecycle: i96, setup: i96 };

// Source and bundled modes use the same compiler and fixtures. Each sample has
// a fresh database and no disk cache; only loading the std bundle differs.
// Profiling runs separately so instrumentation does not affect the timings.
fn measure(allocator: std.mem.Allocator, io: std.Io, case: Case, bundled: bool, profile: ?*compiler.profiling.Collector) !Sample {
    const started = std.Io.Clock.awake.now(io);
    var compiled: std.Io.Timestamp = undefined;
    var setup_ns: i96 = 0;
    {
        const db = try compiler.query.Database.init(allocator, .{ .worker_count = 0, .profile = profile });
        defer db.deinit();
        var registry: compiler.modules.SourceRegistry = .{};
        defer registry.deinit(allocator);
        try registry.update(db, allocator, case.source, &.{}, &.{});
        var loader: ?*compiler.standard_bundle.Loader = null;
        if (bundled) {
            const loading = std.Io.Clock.awake.now(io);
            loader = try compiler.standard_bundle.install(db, standard_bundle);
            setup_ns = loading.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        }
        if ((try db.get(queries.BuildExecutable, 0)).* == null) {
            const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, compiler.structures.Diagnostic, allocator);
            defer allocator.free(diagnostics);
            for (diagnostics) |diagnostic| std.debug.print("{any}\n", .{diagnostic});
            return error.CompilationFailed;
        }
        compiled = std.Io.Clock.awake.now(io);
        if (loader) |installed| if (installed.stats().functions == 0) return error.BundleNotReused;
    }
    return .{
        .compile = started.durationTo(compiled).toNanoseconds(),
        .lifecycle = started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(),
        .setup = setup_ns,
    };
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("case,mode,stage,samples,median_ns,min_ns,max_ns,body_typing_runs,codegen_runs\n");
    for (cases) |case| {
        var profiles: [2]compiler.profiling.Snapshot = undefined;
        for (&profiles, 0..) |*profile, mode| {
            var collector: compiler.profiling.Collector = .{ .io = init.io };
            _ = try measure(init.gpa, init.io, case, mode == 1, &collector);
            profile.* = collector.snapshot();
        }
        var samples: [2][sample_count]Sample = undefined;
        for (0..sample_count) |index| {
            // Reverse order on alternate pairs to reduce ordering bias.
            for (0..2) |offset| {
                const mode = (index + offset) % 2;
                samples[mode][index] = try measure(init.gpa, init.io, case, mode == 1, null);
            }
        }
        for (samples, profiles, 0..) |mode_samples, profile, mode| {
            inline for (.{ "compile", "lifecycle", "setup" }) |stage| {
                var times: [sample_count]i96 = undefined;
                for (&times, mode_samples) |*time, sample| time.* = @field(sample, stage);
                std.mem.sort(i96, &times, {}, std.sort.asc(i96));
                try writer.print("{s},{s},{s},{d},{d},{d},{d},{d},{d}\n", .{
                    case.name,                  if (mode == 0) "source" else "lazy", stage,                   sample_count,
                    times[sample_count / 2],    times[0],                            times[sample_count - 1], profile.get(.body_typing).runs,
                    profile.get(.codegen).runs,
                });
            }
        }
        try writer.flush();
    }
}
