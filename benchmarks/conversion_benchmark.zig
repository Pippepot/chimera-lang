const std = @import("std");
const compiler = @import("compiler");
const queries = compiler.queries;
const structures = compiler.structures;

const sample_count = 9;
const lookup_count = 256;
const Case = struct { name: []const u8, declarations: usize = 0, converters: usize = 0, pairs: usize = 1 };
const cases = [_]Case{
    .{ .name = "small" },
    .{ .name = "declarations-1024", .declarations = 1024 },
    .{ .name = "converters-128", .converters = 128 },
    .{ .name = "converters-512", .converters = 512 },
    .{ .name = "distinct-pairs-128", .pairs = 128 },
};

// Distinct consumers prevent enclosing-query memoization from hiding repeated
// discovery of the same source/target pair.
const Lookup = struct {
    pub const Input = struct { consumer: u32, source: structures.TypeId, target: structures.TypeId };
    pub const Output = usize;

    pub fn run(ctx: anytype, key: Input) !Output {
        const analysis: queries.AnalysisContext(@TypeOf(ctx)) = .{ .ctx = ctx, .file_id = 0 };
        const candidates = try analysis.conversionCandidates(key.source, key.target, null);
        if (candidates.len != 1) return error.UnexpectedConversionCount;
        return candidates.len;
    }
};

fn sourceText(allocator: std.mem.Allocator, case: Case) ![]u8 {
    var source: std.Io.Writer.Allocating = .init(allocator);
    errdefer source.deinit();
    const writer = &source.writer;
    try writer.writeAll("struct Target\n    value: int\n");
    for (0..case.pairs) |index| {
        try writer.print("struct Source{d}\n    value: int\nconverter(value: Source{d}) Target -> Target{{value = value.value}}\n", .{ index, index });
    }
    for (0..case.declarations) |index| try writer.print("static unrelated{d} = 0\n", .{index});
    for (0..case.converters) |index| {
        try writer.print("struct Noise{d}\n    value: int\nconverter(value: Noise{d}) Target -> Target{{value = value.value}}\n", .{ index, index });
    }
    return source.toOwnedSlice();
}

fn typeNamed(db: *compiler.query.Database, scope: structures.ModuleScope, name: []const u8) !structures.TypeId {
    const value_id = (try db.get(queries.ResolveStatic, scope.resolveStatic(name).?)).*.?;
    return (try db.lookupInterned(queries.CompileTimeValues, value_id)).type;
}

const Sample = struct { first: i96, consumers: i96, total: i96 };

fn measure(allocator: std.mem.Allocator, io: std.Io, case: Case, source: []const u8) !Sample {
    const started = std.Io.Clock.awake.now(io);
    const db = try compiler.query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    try compiler.modules.registerSources(db, allocator, source, &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const target = try typeNamed(db, scope, "Target");
    var sources: [128]structures.TypeId = undefined;
    for (sources[0..case.pairs], 0..) |*source_type, index| {
        var name: [32]u8 = undefined;
        source_type.* = try typeNamed(db, scope, try std.fmt.bufPrint(&name, "Source{d}", .{index}));
    }
    const first_started = std.Io.Clock.awake.now(io);
    _ = try db.get(Lookup, .{ .consumer = 0, .source = sources[0], .target = target });
    const consumers_started = std.Io.Clock.awake.now(io);
    for (1..lookup_count + 1) |index| {
        _ = try db.get(Lookup, .{ .consumer = @intCast(index), .source = sources[index % case.pairs], .target = target });
    }
    const ended = std.Io.Clock.awake.now(io);
    return .{
        .first = first_started.durationTo(consumers_started).toNanoseconds(),
        .consumers = consumers_started.durationTo(ended).toNanoseconds(),
        .total = started.durationTo(ended).toNanoseconds(),
    };
}

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("case,stage,median_ns,min_ns,max_ns\n");
    for (cases) |case| {
        const source = try sourceText(init.gpa, case);
        defer init.gpa.free(source);
        _ = try measure(init.gpa, init.io, case, source);
        var samples: [sample_count]Sample = undefined;
        for (&samples) |*sample| sample.* = try measure(init.gpa, init.io, case, source);
        inline for (.{ "first", "consumers", "total" }) |stage| {
            var times: [sample_count]i96 = undefined;
            for (&times, samples) |*time, sample| time.* = @field(sample, stage);
            std.mem.sort(i96, &times, {}, std.sort.asc(i96));
            try writer.print("{s},{s},{d},{d},{d}\n", .{ case.name, stage, times[sample_count / 2], times[0], times[sample_count - 1] });
        }
        try writer.flush();
    }
}
