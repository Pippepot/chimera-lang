const std = @import("std");
const compiler = @import("compiler");
const sampling = @import("history_sampling.zig");
const queries = compiler.queries;
const bundle = @embedFile("standard_bundle");

const Shape = enum { independent, serial, serial_selected, forwarding, cleanup, callable };

comptime {
    if (compiler.optimize_mode != @import("builtin").mode)
        @compileError("benchmark driver and compiler must use the same optimization mode");
}

fn helper(allocator: std.mem.Allocator, shape: Shape, depth: usize, inverted: bool) ![]const u8 {
    if (shape == .cleanup) return std.fmt.allocPrint(
        allocator,
        "pub struct Install\n" ++
            "    pub target: Ref(Ref(int))\n    pub source: Ref(int)\n    pub fallback: Ref(int)\n" ++
            "    drop = func(deinit self: Install) -> self.target.value = self.{s}\n",
        .{if (inverted) "fallback" else "source"},
    );
    if (shape == .callable) return std.fmt.allocPrint(
        allocator,
        "pub func identity(ref source: int) ref int -> source\n" ++
            "pub func alternate(ref source: int) ref int -> source\n" ++
            "pub func factory() func(ref int) ref int -> {s}\n",
        .{if (inverted) "alternate" else "identity"},
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print(
        "pub func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none\n" ++
            "    if not selected -> return {s}\n" ++
            "    slot = Ref.from(source)\n    return {s}\n",
        .{ if (inverted) "()" else "none", if (inverted) "none" else "()" },
    );
    for (0..depth) |index| {
        const previous = if (index == 0) "replace" else try std.fmt.allocPrint(allocator, "forward_{d}", .{index - 1});
        defer if (index != 0) allocator.free(previous);
        try output.writer.print("pub func forward_{d}(mut slot: Ref(int), ref source: int, selected: bool) unit | none -> {s}(slot, source, selected)\n", .{ index, previous });
    }
    try output.writer.print("pub func forward(mut slot: Ref(int), ref source: int, selected: bool) unit | none -> forward_{d}(slot, source, selected)\n", .{depth - 1});
    return output.toOwnedSlice();
}

fn entry(allocator: std.mem.Allocator, shape: Shape, size: usize) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    switch (shape) {
        .cleanup => try output.writer.writeAll("import mutation.{Install}\n"),
        .callable => try output.writer.writeAll("import mutation.{factory}\n"),
        else => try output.writer.writeAll("import mutation.{forward}\n"),
    }
    try output.writer.writeAll(
        "func run(selected: bool) int\n" ++
            "    var original = 40\n    var source = 40\n",
    );
    const calls = if (shape == .forwarding) 1 else size;
    if (shape != .independent and shape != .cleanup and shape != .callable)
        try output.writer.writeAll("    var slot = Ref.from(original)\n");
    for (0..calls) |index| {
        if (shape == .cleanup) {
            try output.writer.print(
                "    var slot_{d} = Ref.from(original)\n" ++
                    "    var install_{d} = Install{{target = Ref.from(slot_{d}), source = Ref.from(source), fallback = Ref.from(original)}}\n" ++
                    "    _ = install_{d}\n",
                .{ index, index, index, index },
            );
            continue;
        }
        if (shape == .callable) {
            try output.writer.print("    const callback_{d} = factory()\n    _ = callback_{d}(source)\n", .{ index, index });
            continue;
        }
        const slot = if (shape == .independent) try std.fmt.allocPrint(allocator, "slot_{d}", .{index}) else "slot";
        defer if (shape == .independent) allocator.free(slot);
        if (shape == .independent) try output.writer.print("    var {s} = Ref.from(original)\n", .{slot});
        try output.writer.print("    const result_{d} = forward({s}, source, selected)\n", .{ index, slot });
        if (shape == .independent) try output.writer.print("    if result_{d} is unit -> {s}.value += 0\n", .{ index, slot });
    }
    if (shape == .serial_selected) {
        for (0..calls) |index| try output.writer.print("    if result_{d} is unit -> slot.value += 0\n", .{index});
    }
    if (shape == .callable) {
        try output.writer.writeAll("    return source + 2\n");
    } else {
        const last = if (shape == .independent or shape == .cleanup) try std.fmt.allocPrint(allocator, "slot_{d}", .{calls - 1}) else "slot";
        defer if (shape == .independent or shape == .cleanup) allocator.free(last);
        try output.writer.print("    return {s}.value + 2\n", .{last});
    }
    try output.writer.writeAll(
        "var answer = 0\nfor iteration in 0..100000\n" ++
            "    answer = run(iteration % 2 == 0)\nexit(answer)\n",
    );
    return output.toOwnedSlice();
}

fn executable(db: *compiler.query.Database, allocator: std.mem.Allocator) ![]const u8 {
    if ((try db.get(queries.BuildExecutable, 0)).*) |built| return built.bytes;
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, compiler.structures.Diagnostic, allocator);
    defer allocator.free(diagnostics);
    for (diagnostics) |diagnostic| std.debug.print("{any}\n", .{diagnostic});
    return error.CompilationFailed;
}

fn run(init: std.process.Init) !void {
    var child = try std.process.spawn(init.io, .{ .argv = &.{"./provenance-program"} });
    switch (try child.wait(init.io)) {
        .exited => |status| if (status != 42) return error.IncorrectProgramResult,
        else => return error.ProgramDidNotExitNormally,
    }
}

fn writeProgram(init: std.process.Init, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(init.io, "provenance-program", .{ .permissions = .executable_file });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, bytes);
}

fn fingerprint(name: []const u8, phase: []const u8, sample: usize, inverted: bool, bytes: []const u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    std.debug.print("image,{s},{s},{s},{d},{s}\n", .{ name, phase, if (inverted) "inverted" else "normal", sample, hex });
}

fn measure(init: std.process.Init, writer: *std.Io.Writer, shape: Shape, size: usize, profile: bool) !void {
    const source = try entry(init.gpa, shape, size);
    defer init.gpa.free(source);
    const depth = if (shape == .forwarding) size else 4;
    const normal = try helper(init.gpa, shape, depth, false);
    defer init.gpa.free(normal);
    const inverted = try helper(init.gpa, shape, depth, true);
    defer init.gpa.free(inverted);
    const name = try std.fmt.allocPrint(init.arena.allocator(), "{s}-{d}", .{ @tagName(shape), size });
    var cold: sampling.Sampling = .{ .limit = sampling.compilation_maximum_samples };
    var edit: sampling.Sampling = .{ .limit = sampling.compilation_maximum_samples };
    var runtime: sampling.Sampling = .{};
    var database: ?*compiler.query.Database = null;
    defer if (database) |db| db.deinit();
    var registry: compiler.modules.SourceRegistry = .{};
    defer registry.deinit(init.gpa);
    defer std.Io.Dir.cwd().deleteFile(init.io, "provenance-program") catch {};
    var warmup = true;
    var changed = false;
    var collector: compiler.profiling.Collector = .{ .io = init.io };
    while (warmup or !cold.complete() or !edit.complete()) {
        if (warmup or !cold.complete()) {
            if (database) |db| db.deinit();
            database = null;
            registry.deinit(init.gpa);
            registry = .{};
            const started = std.Io.Clock.awake.now(init.io);
            const db = try compiler.query.Database.init(init.gpa, .{ .worker_count = 0, .profile = if (profile) &collector else null });
            database = db;
            try registry.update(db, init.gpa, source, &.{.{ .path = "mutation.chi", .source = normal, .module_path = "mutation" }}, &.{});
            _ = try compiler.standard_bundle.install(db, bundle);
            const bytes = try executable(db, init.gpa);
            const ended = std.Io.Clock.awake.now(init.io);
            if (!warmup) {
                try cold.add(started.durationTo(ended).toNanoseconds(), bytes.len);
                fingerprint(name, "cold", cold.count - 1, false, bytes);
            }
            try writeProgram(init, bytes);
            try run(init);
            if (profile) {
                const snapshot = collector.snapshot();
                inline for (@typeInfo(compiler.profiling.Category).@"enum".field_names) |category| {
                    const counter = snapshot.get(@field(compiler.profiling.Category, category));
                    if (counter.runs != 0) std.debug.print("{s}: {d:.3} ms, {d} runs\n", .{ category, @as(f64, @floatFromInt(counter.nanoseconds)) / 1e6, counter.runs });
                }
                return;
            }
            changed = false;
        }
        if (warmup or !edit.complete()) {
            const db = database.?;
            changed = !changed;
            const started = std.Io.Clock.awake.now(init.io);
            try db.setInput(queries.SourceText, registry.fileId("mutation.chi").?, if (changed) inverted else normal);
            const bytes = try executable(db, init.gpa);
            const ended = std.Io.Clock.awake.now(init.io);
            if (!warmup) {
                try edit.add(started.durationTo(ended).toNanoseconds(), bytes.len);
                fingerprint(name, "contract-edit", edit.count - 1, changed, bytes);
            }
            try writeProgram(init, bytes);
            try run(init);
        }
        warmup = false;
    }
    const db = database.?;
    if (changed) try db.setInput(queries.SourceText, registry.fileId("mutation.chi").?, normal);
    const runtime_bytes = try executable(db, init.gpa);
    try writeProgram(init, runtime_bytes);
    fingerprint(name, "runtime", 0, false, runtime_bytes);
    try run(init);
    while (!runtime.complete()) {
        const started = std.Io.Clock.awake.now(init.io);
        try run(init);
        const ended = std.Io.Clock.awake.now(init.io);
        try runtime.add(started.durationTo(ended).toNanoseconds(), runtime_bytes.len);
    }
    try cold.write(writer, name, "normal", "cold");
    try edit.write(writer, name, "normal", "contract-edit");
    try runtime.write(writer, name, "normal", "runtime");
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var shape: ?Shape = null;
    var size: ?usize = null;
    var profile = false;
    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--profile")) {
            profile = true;
        } else if (std.mem.startsWith(u8, argument, "--shape=")) {
            shape = std.meta.stringToEnum(Shape, argument["--shape=".len..]) orelse return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, argument, "--size=")) {
            size = try std.fmt.parseInt(usize, argument["--size=".len..], 10);
        } else return error.InvalidArgument;
    }
    if (size) |count| if (count == 0 or count > 512) return error.InvalidArgument;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    try output.interface.writeAll("case,lane,phase,sample,nanoseconds,executable_bytes,sample_count,stable\n");
    for ([_]Shape{ .independent, .serial, .serial_selected, .forwarding, .cleanup, .callable }) |selected| {
        if (shape == null and (selected == .cleanup or selected == .callable)) continue;
        if (shape != null and shape.? != selected) continue;
        for ([_]usize{ 8, 32, 128 }) |count| {
            if (size != null and size.? != count) continue;
            try measure(init, &output.interface, selected, count, profile);
        }
        if (size) |count| if (count != 8 and count != 32 and count != 128) try measure(init, &output.interface, selected, count, profile);
    }
    try output.interface.flush();
}
