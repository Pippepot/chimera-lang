const std = @import("std");
const compiler = @import("compiler");
const query = compiler.query;
const queries = compiler.queries;
const structures = compiler.structures;

const Case = struct {
    name: []const u8,
    source: []const u8,
};

const cases = [_]Case{
    .{ .name = "constant", .source = "static result = 42" },
    .{ .name = "short-expression", .source = "static result = (20 + 1) * 2" },
    .{ .name = "loop-10000", .source =
    \\static result = comptime
    \\  var index = 0
    \\  var total = 0
    \\  loop
    \\    if index == 10000 -> break total
    \\    total += index
    \\    index += 1
    },
    .{ .name = "fibonacci-20", .source =
    \\static fibonacci = func(value: int) int
    \\  if value < 2 -> return value
    \\  return fibonacci(value - 1) + fibonacci(value - 2)
    \\static result = fibonacci(20)
    },
    .{ .name = "unique-recursion-200", .source =
    \\static down = func(value: int) int -> if value == 0 -> 42 else down(value - 1)
    \\static result = down(200)
    },
    .{ .name = "memoized-call", .source =
    \\static increment = func(value: int) int -> value + 1
    \\static result = increment(20) + increment(20)
    },
    .{ .name = "aggregate-call", .source =
    \\struct Pair
    \\  left: int
    \\  right: int
    \\static sum = func(pair: Pair) int -> pair.left + pair.right
    \\static result = sum(Pair{left = 20, right = 22})
    },
    .{ .name = "type-specialization", .source =
    \\struct Box(T: type, N: int)
    \\  value: T
    \\static choose = func(static A: type, static B: type, static C: type) type -> A
    \\static result = choose(Box(int, 42), Box(int, 42), Box(bool, 43))
    },
};

fn elapsed(start: std.Io.Timestamp, io: std.Io) i96 {
    return start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
}

fn printMeasurement(writer: *std.Io.Writer, case_name: []const u8, stage: []const u8, nanoseconds: i96) !void {
    try writer.print("{s},{s},{d}\n", .{ case_name, stage, nanoseconds });
}

fn benchmarkCase(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, case: Case) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try db.addInput(queries.SourceText, 1, case.source);
    try db.addInput(queries.FileModule, 1, try db.intern(queries.ModulePaths, .{ .path = "" }));
    try db.addInput(queries.ModuleMembers, try db.intern(queries.ModulePaths, .{ .path = "" }), &.{1});

    const scope = (try db.get(queries.BuildModuleScope, 1)).*.?;
    const result = scope.resolveStatic("result").?;
    const resolved = (try db.get(queries.ResolveItem, result)).*.?;
    const parsed = (try db.get(queries.ParseFile, 1)).*.?;
    const initializer = parsed.nodes[resolved.declaration].data.node_node.b.unwrap().?;
    const site: structures.CompileTimeSite = .{ .owner = .{ .item = result }, .node = initializer };

    var started = std.Io.Clock.awake.now(io);
    _ = (try db.get(queries.AnalyzeComptimeThunk, site)).*.?;
    try printMeasurement(writer, case.name, "analyze", elapsed(started, io));

    started = std.Io.Clock.awake.now(io);
    _ = (try db.get(queries.ExecuteComptimeThunk, site)).*.?;
    try printMeasurement(writer, case.name, "execute", elapsed(started, io));

    started = std.Io.Clock.awake.now(io);
    _ = (try db.get(queries.ResolveStatic, result)).*.?;
    try printMeasurement(writer, case.name, "publish", elapsed(started, io));

    started = std.Io.Clock.awake.now(io);
    for (0..1000) |_| _ = (try db.get(queries.ResolveStatic, result)).*.?;
    try printMeasurement(writer, case.name, "cached-1000", elapsed(started, io));
}

fn benchmarkIncremental(gpa: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();

    const original =
        \\static increment = func(value: int) int -> value + 1
        \\static unrelated = 0
        \\static result = increment(41)
    ;
    try db.addInput(queries.SourceText, 1, original);
    try db.addInput(queries.FileModule, 1, try db.intern(queries.ModulePaths, .{ .path = "" }));
    try db.addInput(queries.ModuleMembers, try db.intern(queries.ModulePaths, .{ .path = "" }), &.{1});
    const result = (try db.get(queries.BuildModuleScope, 1)).*.?.resolveStatic("result").?;
    _ = (try db.get(queries.ResolveStatic, result)).*.?;

    const edits = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "no-op-edit", .source = original },
        .{ .name = "unrelated-edit", .source =
        \\static increment = func(value: int) int -> value + 1
        \\static unrelated = 1
        \\static result = increment(41)
        },
        .{ .name = "callee-edit", .source =
        \\static increment = func(value: int) int -> value + 2
        \\static unrelated = 1
        \\static result = increment(41)
        },
        .{ .name = "argument-edit", .source =
        \\static increment = func(value: int) int -> value + 2
        \\static unrelated = 1
        \\static result = increment(40)
        },
    };
    for (edits) |edit| {
        const started = std.Io.Clock.awake.now(io);
        try db.setInput(queries.SourceText, 1, edit.source);
        _ = (try db.get(queries.ResolveStatic, result)).*.?;
        try printMeasurement(writer, "incremental", edit.name, elapsed(started, io));
    }
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.writeAll("case,stage,nanoseconds\n");
    for (cases) |case| try benchmarkCase(init.gpa, init.io, writer, case);
    try benchmarkIncremental(init.gpa, init.io, writer);
    try writer.flush();
}
