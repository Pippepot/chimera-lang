const std = @import("std");
const structures = @import("structures.zig");
const profiling = @import("profiling.zig");

pub const TimingLog = struct {
    const Stage = struct {
        label: []const u8,
        duration: std.Io.Duration,
        work: ?profiling.Snapshot = null,
    };

    started: std.Io.Timestamp,
    previous: std.Io.Timestamp,
    stages: [16]Stage = undefined,
    count: usize = 0,
    program_run: ?std.Io.Duration = null,
    collector: ?*profiling.Collector = null,
    previous_work: profiling.Snapshot = .{},

    pub fn init(started: std.Io.Timestamp) TimingLog {
        return .{ .started = started, .previous = started };
    }

    pub fn enableQueryProfiling(self: *TimingLog, collector: *profiling.Collector) void {
        self.collector = collector;
        self.previous_work = collector.snapshot();
    }

    pub fn mark(self: *TimingLog, io: std.Io, label: []const u8) void {
        std.debug.assert(self.count < self.stages.len);
        const now = std.Io.Clock.awake.now(io);
        const work: ?profiling.Snapshot = if (self.collector) |collector| work: {
            const current = collector.snapshot();
            const delta = current.since(self.previous_work);
            self.previous_work = current;
            break :work delta;
        } else null;
        self.stages[self.count] = .{ .label = label, .duration = self.previous.durationTo(now), .work = work };
        self.count += 1;
        self.previous = now;
    }

    pub fn markProgramRun(self: *TimingLog, io: std.Io) void {
        std.debug.assert(self.program_run == null);
        const now = std.Io.Clock.awake.now(io);
        self.program_run = self.previous.durationTo(now);
        self.previous = now;
    }

    pub fn print(self: *const TimingLog, io: std.Io, writer: *std.Io.Writer) !void {
        const total = self.started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
        const stages = self.stages[0..self.count];
        var label_width: usize = @max("run program".len, work_label_width);
        var compile: i96 = 0;
        var compile_thread: i96 = 0;
        for (stages) |stage| {
            label_width = @max(label_width, displayWidth(stage.label));
            compile += stage.duration.toNanoseconds();
            if (stage.work) |work| compile_thread += threadNanoseconds(work);
        }

        try writer.writeAll("timing");
        try writer.splatByteAll(' ', 2 + label_width - "timing".len);
        try writer.print("  {s:>9}  {s:>9}  {s:>5}\n", .{ "wall ms", "thread ms", "%" });
        for (stages) |stage| {
            const duration = stage.duration.toNanoseconds();
            const thread = if (stage.work) |work| threadNanoseconds(work) else 0;
            try writeTimingRow(writer, label_width, .{
                .label = stage.label,
                .wall = duration,
                .thread = if (thread != 0) thread else null,
                .share = fraction(duration, compile),
                .bar = true,
            });
            const work = stage.work orelse continue;
            var kinds: usize = 0;
            for (work_rows) |row| kinds += @intFromBool(hasWork(work, row));
            if (kinds < 2) continue;
            try writeWorkRows(writer, label_width, work, &work_rows, 1, thread);
            const waiting = workCounter(work, dependency_wait_row);
            if (waiting.runs != 0) try writeTimingRow(writer, label_width, .{
                .label = dependency_wait_row.label,
                .depth = 1,
                .thread = waiting.nanoseconds,
                .runs = .{ .count = waiting.runs, .unit = dependency_wait_row.unit },
            });
        }
        try writeTimingRow(writer, label_width, .{
            .label = "compile",
            .wall = compile,
            .thread = if (compile_thread != 0) compile_thread else null,
        });
        if (self.program_run) |run| try writeTimingRow(writer, label_width, .{ .label = "run program", .wall = run.toNanoseconds() });
        try writeTimingRow(writer, label_width, .{ .label = "total", .wall = total });
    }
};

const WorkUnit = enum { query, parse, phase, function, request };

const WorkRow = struct {
    label: []const u8,
    categories: []const profiling.Category,
    unit: WorkUnit = .query,
    parts: []const WorkRow = &.{},
};

const work_rows = [_]WorkRow{
    .{ .label = "parsing", .categories = &.{.parsing}, .unit = .parse },
    .{ .label = "declarations", .categories = &.{.declarations} },
    .{ .label = "signatures", .categories = &.{ .signatures, .conversion_matching }, .parts = &.{
        .{ .label = "conversion matching", .categories = &.{.conversion_matching} },
    } },
    .{ .label = "body analysis", .categories = &.{ .body_overhead, .body_build, .body_typing, .body_lifetimes, .body_freeze }, .parts = &.{
        .{ .label = "unresolved expressions", .categories = &.{.body_build}, .unit = .phase },
        .{ .label = "typing / SSA", .categories = &.{.body_typing}, .unit = .phase },
        .{ .label = "lifetimes / cleanup", .categories = &.{.body_lifetimes}, .unit = .phase },
        .{ .label = "IR finalization", .categories = &.{.body_freeze}, .unit = .phase },
        .{ .label = "body setup", .categories = &.{.body_overhead} },
    } },
    .{ .label = "type facts", .categories = &.{.type_facts} },
    .{ .label = "comptime", .categories = &.{.comptime_execution} },
    .{ .label = "codegen", .categories = &.{.codegen}, .unit = .function },
    .{ .label = "other queries", .categories = &.{.query_other} },
};

const dependency_wait_row: WorkRow = .{ .label = "dependency wait", .categories = &.{.dependency_wait}, .unit = .request };

const work_label_width = width: {
    var width: usize = dependency_wait_row.label.len + 2;
    for (work_rows) |row| {
        width = @max(width, row.label.len + 2);
        for (row.parts) |part| width = @max(width, part.label.len + 4);
    }
    break :width width;
};

fn workCounter(work: profiling.Snapshot, row: WorkRow) profiling.Counter {
    var counter: profiling.Counter = .{ .runs = work.get(row.categories[0]).runs };
    for (row.categories) |category| counter.nanoseconds += work.get(category).nanoseconds;
    return counter;
}

fn hasWork(work: profiling.Snapshot, row: WorkRow) bool {
    const counter = workCounter(work, row);
    return counter.runs != 0 or counter.nanoseconds != 0;
}

fn threadNanoseconds(work: profiling.Snapshot) i96 {
    var nanoseconds: i96 = 0;
    for (work_rows) |row| nanoseconds += workCounter(work, row).nanoseconds;
    return nanoseconds;
}

fn slowerWork(work: *const profiling.Snapshot, lhs: WorkRow, rhs: WorkRow) bool {
    return workCounter(work.*, lhs).nanoseconds > workCounter(work.*, rhs).nanoseconds;
}

fn writeWorkRows(
    writer: *std.Io.Writer,
    label_width: usize,
    work: profiling.Snapshot,
    rows: []const WorkRow,
    depth: usize,
    stage_thread: i96,
) std.Io.Writer.Error!void {
    var sorted: [work_rows.len]WorkRow = undefined;
    var count: usize = 0;
    for (rows) |row| {
        if (!hasWork(work, row)) continue;
        sorted[count] = row;
        count += 1;
    }
    std.mem.sort(WorkRow, sorted[0..count], &work, slowerWork);
    for (sorted[0..count]) |row| {
        const counter = workCounter(work, row);
        try writeTimingRow(writer, label_width, .{
            .label = row.label,
            .depth = depth,
            .thread = counter.nanoseconds,
            .share = fraction(counter.nanoseconds, stage_thread),
            .runs = .{ .count = counter.runs, .unit = row.unit },
        });
        try writeWorkRows(writer, label_width, work, row.parts, depth + 1, stage_thread);
    }
}

const TimingRow = struct {
    label: []const u8,
    depth: usize = 0,
    wall: ?i96 = null,
    thread: ?i96 = null,
    share: ?f64 = null,
    bar: bool = false,
    runs: ?struct { count: usize, unit: WorkUnit } = null,
};

fn writeTimingRow(writer: *std.Io.Writer, label_width: usize, row: TimingRow) std.Io.Writer.Error!void {
    var buffer: [256]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buffer);
    const indent = 2 * row.depth;
    try line.splatByteAll(' ', 2 + indent);
    try writePadded(&line, row.label, label_width - indent, .left);
    try writeMilliseconds(&line, row.wall);
    try writeMilliseconds(&line, row.thread);
    if (row.share) |share| try line.print("  {d:>5.1}", .{share * 100}) else try line.splatByteAll(' ', 7);
    if (row.bar) try writeShareBar(&line, row.share.?);
    if (row.runs) |runs| if (runs.count != 0) {
        const average = @as(f64, @floatFromInt(row.thread.?)) / 1_000.0 / @as(f64, @floatFromInt(runs.count));
        try line.print("  {d:>6} × {d:>6.1} µs/{s}", .{ runs.count, average, @tagName(runs.unit) });
    };
    try writer.writeAll(std.mem.trimEnd(u8, line.buffered(), " "));
    try writer.writeByte('\n');
}

fn writeMilliseconds(writer: *std.Io.Writer, nanoseconds: ?i96) std.Io.Writer.Error!void {
    const value = nanoseconds orelse return writer.splatByteAll(' ', 11);
    try writer.print("  {d:>9.3}", .{@as(f64, @floatFromInt(value)) / 1_000_000.0});
}

fn expectTimingRow(text: []const u8, expected: []const []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    next_line: while (lines.next()) |line| {
        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        for (expected) |token| {
            if (!std.mem.eql(u8, tokens.next() orelse continue :next_line, token)) continue :next_line;
        }
        if (tokens.next() == null) return;
    }
    std.debug.print("missing timing row starting {s}\n{s}", .{ expected[0], text });
    return error.TestExpectedEqual;
}

test "timing table sorts stage work and keeps waiting and the program run out of compile shares" {
    var analysis: profiling.Snapshot = .{};
    analysis.counters[@backingInt(profiling.Category.body_overhead)] = .{ .nanoseconds = 1_000_000, .runs = 2 };
    analysis.counters[@backingInt(profiling.Category.body_typing)] = .{ .nanoseconds = 4_000_000, .runs = 2 };
    analysis.counters[@backingInt(profiling.Category.codegen)] = .{ .nanoseconds = 3_000_000, .runs = 4 };
    analysis.counters[@backingInt(profiling.Category.query_other)] = .{ .nanoseconds = 2_000_000, .runs = 1 };
    analysis.counters[@backingInt(profiling.Category.dependency_wait)] = .{ .nanoseconds = 9_000_000, .runs = 7 };
    var linking: profiling.Snapshot = .{};
    linking.counters[@backingInt(profiling.Category.parsing)] = .{ .nanoseconds = 50_000, .runs = 1 };

    var timings: TimingLog = .init(std.Io.Clock.awake.now(std.testing.io));
    timings.stages[0] = .{ .label = "load source", .duration = .fromNanoseconds(1_000_000), .work = .{} };
    timings.stages[1] = .{ .label = "analyze", .duration = .fromNanoseconds(8_000_000), .work = analysis };
    timings.stages[2] = .{ .label = "link", .duration = .fromNanoseconds(100_000), .work = linking };
    timings.count = 3;
    timings.program_run = .fromNanoseconds(50_000_000);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try timings.print(std.testing.io, &output.writer);
    const text = output.writer.buffered();

    try expectTimingRow(text, &.{ "timing", "wall", "ms", "thread", "ms", "%" });
    try expectTimingRow(text, &.{ "load", "source", "1.000", "11.0", "██▋" });
    try expectTimingRow(text, &.{ "analyze", "8.000", "10.000", "87.9", "█████████████████████▏" });
    try expectTimingRow(text, &.{ "body", "analysis", "5.000", "50.0", "2", "×", "2500.0", "µs/query" });
    try expectTimingRow(text, &.{ "typing", "/", "SSA", "4.000", "40.0", "2", "×", "2000.0", "µs/phase" });
    try expectTimingRow(text, &.{ "body", "setup", "1.000", "10.0", "2", "×", "500.0", "µs/query" });
    try expectTimingRow(text, &.{ "codegen", "3.000", "30.0", "4", "×", "750.0", "µs/function" });
    try expectTimingRow(text, &.{ "other", "queries", "2.000", "20.0", "1", "×", "2000.0", "µs/query" });
    try expectTimingRow(text, &.{ "dependency", "wait", "9.000", "7", "×", "1285.7", "µs/request" });
    try expectTimingRow(text, &.{ "link", "0.100", "0.050", "1.1", "▎" });
    try expectTimingRow(text, &.{ "compile", "9.100", "10.050" });
    try expectTimingRow(text, &.{ "run", "program", "50.000" });

    const order = [_][]const u8{ "body analysis", "typing / SSA", "body setup", "codegen", "other queries", "dependency wait", "link", "compile", "run program", "total" };
    var previous: usize = 0;
    for (order) |label| {
        const index = std.mem.indexOfPos(u8, text, previous, label) orelse return error.TestExpectedEqual;
        previous = index + label.len;
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "parsing") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "signatures") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, " \n") == null);
}

pub const MemoryTracker = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    allocations: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *MemoryTracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    pub fn print(self: *const MemoryTracker, writer: *std.Io.Writer) !void {
        var buffers: [4][32]u8 = undefined;
        const rows = [_]struct { label: []const u8, value: []const u8 }{
            .{ .label = "peak live", .value = try formatByteSize(&buffers[0], self.peak.load(.monotonic)) },
            .{ .label = "total allocated", .value = try formatByteSize(&buffers[1], self.total.load(.monotonic)) },
            .{ .label = "still live", .value = try formatByteSize(&buffers[2], self.live.load(.monotonic)) },
            .{ .label = "allocations", .value = try std.fmt.bufPrint(&buffers[3], "{d}", .{self.allocations.load(.monotonic)}) },
        };
        var label_width: usize = 0;
        var value_width: usize = 0;
        for (rows) |row| label_width = @max(label_width, row.label.len);
        // Byte sizes align with each other; the allocation count does not widen them.
        for (rows[0..3]) |row| value_width = @max(value_width, displayWidth(row.value));

        try writer.writeAll("memory\n");
        for (rows) |row| {
            try writer.writeAll("  ");
            try writePadded(writer, row.label, label_width, .left);
            try writer.writeAll("  ");
            try writePadded(writer, row.value, value_width, .right);
            try writer.writeByte('\n');
        }
    }

    fn grow(self: *MemoryTracker, bytes: usize) void {
        _ = self.total.fetchAdd(bytes, .monotonic);
        const live = self.live.fetchAdd(bytes, .monotonic) + bytes;
        _ = self.peak.fetchMax(live, .monotonic);
    }

    fn shrink(self: *MemoryTracker, bytes: usize) void {
        _ = self.live.fetchSub(bytes, .monotonic);
    }

    fn resized(self: *MemoryTracker, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) self.grow(new_len - old_len) else self.shrink(old_len - new_len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        self.grow(len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resized(memory.len, new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MemoryTracker = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.shrink(memory.len);
    }
};

const share_bar_width = 24;
const partial_share_blocks = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

fn formatByteSize(buffer: []u8, bytes: usize) ![]const u8 {
    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes});
    var scaled: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
    var unit: usize = 0;
    while (scaled >= 1024.0 and unit + 1 < units.len) : (unit += 1) scaled /= 1024.0;
    return std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ scaled, units[unit] });
}

fn fraction(part: i96, whole: i96) f64 {
    if (whole <= 0) return 0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
}

fn writeShareBar(writer: *std.Io.Writer, share: f64) std.Io.Writer.Error!void {
    const eighths: usize = @intFromFloat(@round(std.math.clamp(share, 0, 1) * share_bar_width * partial_share_blocks.len));
    try writer.writeAll("  ");
    try writer.splatBytesAll("█", eighths / partial_share_blocks.len);
    try writer.writeAll(partial_share_blocks[eighths % partial_share_blocks.len]);
}

fn writePadded(writer: *std.Io.Writer, text: []const u8, width: usize, alignment: enum { left, right }) !void {
    const padding = width -| displayWidth(text);
    if (alignment == .right) try writer.splatByteAll(' ', padding);
    try writer.writeAll(text);
    if (alignment == .left) try writer.splatByteAll(' ', padding);
}

// Multi-byte units such as 'µs' occupy fewer columns than bytes.
fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

const LineInfo = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

fn lineInfoForOffset(source: []const u8, offset: usize) LineInfo {
    const prefix = source[0..@min(offset, source.len)];
    const line_start = if (std.mem.findScalarLast(u8, prefix, '\n')) |newline| newline + 1 else 0;
    return .{
        .line = std.mem.countScalar(u8, prefix, '\n') + 1,
        .column = prefix.len - line_start + 1,
        .line_start = line_start,
        .line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len,
    };
}

/// Empty spans and spans outside the line still get one caret.
fn highlightLen(span: structures.SourceSpan, line_start: usize, line_end: usize) usize {
    return @max(1, @min(span.end, line_end) -| @max(span.start, line_start));
}

fn writeType(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId) !void {
    try writer.writeByte('`');
    try writeTypeInner(types, writer, type_id);
    try writer.writeByte('`');
}

pub fn writeTypeInner(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId) anyerror!void {
    if (type_id.isPrimitive()) return writer.writeAll(@tagName(type_id));
    if (try types.arrayType(type_id)) |array| {
        try writer.writeAll("Array(");
        try writeTypeInner(types, writer, array.element_type);
        return writer.print(", {d})", .{array.length});
    }
    if (try types.borrowElement(type_id)) |element| {
        try writeReferenceType(types, writer, element);
        return;
    }
    if (try types.tupleMembers(type_id)) |members| {
        try writer.writeByte('(');
        for (members, 0..) |member, index| {
            if (index != 0) try writer.writeAll(", ");
            if (member.kind == .reference)
                try writeReferenceType(types, writer, member.type_id)
            else
                try writeTypeInner(types, writer, member.type_id);
        }
        return writer.writeByte(')');
    }
    if (try types.structName(type_id)) |name| {
        if (try types.structIdentity(type_id)) |identity| {
            if (identity == .generated and identity.generated.owner.specialization != null) {
                try writeFunctionName(types, writer, identity.generated.owner);
                if (std.mem.eql(u8, name, "anonymous struct")) try writer.writeAll("::{anonymous struct}");
                return;
            }
        }
        return writer.writeAll(name);
    }
    if (try types.callable(type_id)) |callable| {
        try writer.writeAll(if (callable.is_fallible) "fallible(" else "func(");
        for (callable.parameters, 0..) |parameter, index| {
            if (index != 0) try writer.writeAll(", ");
            if (parameter.mode != .imm) try writer.print("{s} ", .{@tagName(parameter.mode)});
            try writeTypeInner(types, writer, parameter.type_id);
        }
        try writer.writeAll(") ");
        if (callable.result_mode == .reference) return writeReferenceType(types, writer, callable.return_type);
        return writeTypeInner(types, writer, callable.return_type);
    }

    const members = (try types.variantMembers(type_id)) orelse unreachable;
    for (members, 0..) |member, index| {
        if (index != 0) try writer.writeAll(" | ");
        try writeGroupedType(types, writer, member, try types.callable(member) != null);
    }
}

fn writeGroupedType(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId, grouped: bool) anyerror!void {
    if (grouped) try writer.writeByte('(');
    try writeTypeInner(types, writer, type_id);
    if (grouped) try writer.writeByte(')');
}

/// Shared source-style callable identity, including inherited and own static arguments.
pub fn writeFunctionName(types: anytype, writer: *std.Io.Writer, instance: structures.InstanceId) anyerror!void {
    const arguments: []const structures.CompileTimeValueId = if (instance.specialization) |tuple| try types.staticArguments(tuple) else &.{};
    try writeFunctionParts(types, writer, instance.item, arguments);
}

fn writeFunctionParts(types: anytype, writer: *std.Io.Writer, item: structures.ItemId, arguments: []const structures.CompileTimeValueId) anyerror!void {
    const location = try types.itemLocation(item);
    if (location.kind == .top_level_entry) return writer.writeAll("<entry>");
    var inherited: usize = 0;
    if (location.owner) |owner| {
        // An invalid declaration may have no shape; keep its supplied arguments
        // visible on the innermost name without trying to specialize it again.
        if (try types.staticParameterCounts(item)) |counts| inherited = @min(counts.inherited, arguments.len);
        try writeFunctionParts(types, writer, owner, arguments[0..inherited]);
        try writer.writeByte('.');
    }
    try writer.writeAll(location.name.text());
    if (location.name == .operation) try writer.print("/{d}", .{location.name.operation.operandCount()});
    if (arguments.len > inherited) {
        try writer.writeByte('(');
        try writeStaticArguments(types, writer, arguments[inherited..]);
        try writer.writeByte(')');
    }
}

fn writeStaticArguments(types: anytype, writer: *std.Io.Writer, arguments: []const structures.CompileTimeValueId) anyerror!void {
    for (arguments, 0..) |argument, index| {
        if (index != 0) try writer.writeAll(", ");
        try writeStaticValue(types, writer, argument);
    }
}

fn writeStaticValue(types: anytype, writer: *std.Io.Writer, id: structures.CompileTimeValueId) anyerror!void {
    switch (try types.staticValue(id)) {
        .type => |type_id| try writeTypeInner(types, writer, type_id),
        .runtime => |runtime| try writeStaticRuntime(types, writer, runtime),
    }
}

fn writeStaticRuntime(types: anytype, writer: *std.Io.Writer, runtime: structures.CompileTimeValue.Runtime) anyerror!void {
    switch (runtime.value) {
        inline .int, .int_literal, .byte => |value| try writer.print("{d}", .{value}),
        .bool => |value| try writer.writeAll(if (value) "true" else "false"),
        .unit => try writer.writeAll("()"),
        .none => try writer.writeAll("none"),
        .string_literal => |value| try writer.print("\"{f}\"", .{std.zig.fmtString(try types.byteString(value))}),
        .storage_cursor => |cursor| try writeStaticCursor(types, writer, cursor),
        .function_ref => |reference| try writeFunctionName(types, writer, reference.instance()),
        .structure => |tuple| try writeStaticAggregate(types, writer, runtime.type_id, try types.staticArguments(tuple)),
        .variant => |variant| {
            try writeStaticValue(types, writer, variant.payload);
            try writer.writeAll(" as ");
            try writeTypeInner(types, writer, variant.member_type);
        },
    }
}

fn writeStaticCursor(types: anytype, writer: *std.Io.Writer, cursor: structures.StaticStorageCursor) anyerror!void {
    try writer.writeAll("cursor(");
    if (cursor.data) |data|
        try writer.print("\"{f}\"", .{std.zig.fmtString(try types.byteString(data))})
    else
        try writer.writeAll("none");
    try writer.print(", {d})", .{cursor.offset});
}

fn writeStaticAggregate(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId, values: []const structures.CompileTimeValueId) anyerror!void {
    const brackets: ?*const [2]u8 = if (try types.arrayType(type_id) != null) "[]" else if (try types.tupleMembers(type_id) != null) "()" else null;
    if (brackets) |pair| {
        try writer.writeByte(pair[0]);
        try writeStaticArguments(types, writer, values);
        return writer.writeByte(pair[1]);
    }
    try writeTypeInner(types, writer, type_id);
    try writer.writeByte('{');
    const definition = (try types.structDefinition(type_id)) orelse return error.Unavailable;
    std.debug.assert(values.len == definition.fields.len);
    for (definition.fields, values, 0..) |field, value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{s} = ", .{field.name});
        try writeStaticValue(types, writer, value);
    }
    try writer.writeByte('}');
}

fn writeReferenceType(types: anytype, writer: *std.Io.Writer, type_id: structures.TypeId) anyerror!void {
    try writer.writeAll("ref ");
    try writeGroupedType(types, writer, type_id, try types.variantMembers(type_id) != null or try types.callable(type_id) != null);
}

fn writeTypedMessage(types: anytype, writer: *std.Io.Writer, prefix: []const u8, type_id: structures.TypeId, suffix: []const u8) !void {
    try writer.writeAll(prefix);
    try writeType(types, writer, type_id);
    try writer.writeAll(suffix);
}

fn writeTypePair(types: anytype, writer: *std.Io.Writer, prefix: []const u8, first: structures.TypeId, separator: []const u8, second: structures.TypeId) !void {
    try writeTypedMessage(types, writer, prefix, first, separator);
    try writeType(types, writer, second);
}

fn writeMismatch(types: anytype, writer: *std.Io.Writer, comptime prefix: []const u8, mismatch: structures.Diagnostic.TypeMismatch) !void {
    try writeTypePair(types, writer, prefix ++ "expected ", mismatch.expected, ", found ", mismatch.found);
}

fn writeToken(writer: *std.Io.Writer, tag: structures.Token.Tag) !void {
    if (structures.Token.spelling(tag)) |text| return writer.print("`{s}`", .{text});
    switch (tag) {
        .invalid => try writer.writeAll("an invalid token"),
        .eof => try writer.writeAll("end of file"),
        .indent => try writer.writeAll("an indented block"),
        .dedent => try writer.writeAll("the end of the block"),
        .identifier => try writer.writeAll("an identifier"),
        .number_literal => try writer.writeAll("a number"),
        .char_literal => try writer.writeAll("a character literal"),
        .string_literal => try writer.writeAll("a string literal"),
        else => try writer.writeAll(@tagName(tag)),
    }
}

fn writeTokenMessage(writer: *std.Io.Writer, prefix: []const u8, tag: structures.Token.Tag, suffix: []const u8) !void {
    try writer.writeAll(prefix);
    try writeToken(writer, tag);
    try writer.writeAll(suffix);
}

fn writeSourceLabel(writer: *std.Io.Writer, label: []const u8, source: []const u8, span: ?structures.SourceSpan) !void {
    try writer.writeAll(label);
    const text = spanText(source, span orelse return);
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '\n') != null) return;
    try writer.print(": `{s}`", .{text});
}

fn spanText(source: []const u8, span: structures.SourceSpan) []const u8 {
    const start = @min(span.start, source.len);
    return source[start..@min(@max(span.end, start), source.len)];
}

fn writeKindMessage(types: anytype, writer: *std.Io.Writer, source: []const u8, span: ?structures.SourceSpan, kind: structures.Diagnostic.Kind) !void {
    switch (kind) {
        .expected_token => |payload| {
            try writeTokenMessage(writer, "expected ", payload.expected, ", found ");
            try writeToken(writer, payload.found);
        },
        .invalid_expression => |tag| try writeTokenMessage(writer, "expected an expression, found ", tag, ""),
        .unsupported_syntax => |tag| try writeTokenMessage(writer, "", tag, " syntax is not implemented yet"),
        .match_not_exhaustive => |type_id| {
            try writer.writeAll("match is not exhaustive; uncovered values remain in ");
            try writeType(types, writer, type_id);
        },
        .match_pattern_incompatible => |mismatch| {
            try writer.writeAll("match pattern is incompatible with the subject: ");
            try writeTypePair(types, writer, "expected ", mismatch.expected, ", found ", mismatch.found);
        },
        .match_literal_ambiguous => |type_id| {
            try writer.writeAll("literal pattern has more than one matching type in ");
            try writeType(types, writer, type_id);
        },
        .compile_time_panic => |message| {
            try writer.writeAll("panic during compile-time execution");
            const bytes = try types.byteString(message);
            if (bytes.len != 0) try writer.print(": {s}", .{bytes});
        },
        .no_matching_overload => |expected| if (expected) |type_id|
            try writeTypedMessage(types, writer, "no overload matches the required function type ", type_id, "")
        else
            try writer.writeAll("no overload matches the argument types and count"),
        .unknown_struct_property => {
            try writeSourceLabel(writer, "unknown struct ownership property", source, span);
            try writer.writeAll("; expected `move`, `copy`, or `drop`");
        },
        .invalid_struct_property_value => |property| {
            try writeSourceLabel(writer, "invalid ownership setting", source, span);
            switch (property) {
                .move, .copy => try writer.writeAll("; expected `trivial`, `fieldwise`, `none`, or a hook function"),
                .drop => try writer.writeAll("; expected `trivial`, `fieldwise`, `explicit`, or a hook function"),
            }
        },
        .struct_ownership_hook_signature_mismatch => |mismatch| try writeMismatch(types, writer, "struct ownership hook signature mismatch: ", mismatch),
        .struct_ownership_property_incompatible_with_fields => |reason| switch (reason) {
            .trivial_move => try writer.writeAll("`move = trivial` requires every field to be trivially movable"),
            .fieldwise_move => try writer.writeAll("`move = fieldwise` requires every field to be movable"),
            .custom_move => try writer.writeAll("a custom move hook requires every field to be movable"),
            .trivial_copy => try writer.writeAll("`copy = trivial` requires every field to be trivially copyable"),
            .fieldwise_copy => try writer.writeAll("`copy = fieldwise` requires every field to be copyable"),
            .trivial_drop => try writer.writeAll("`drop = trivial` requires every field to have trivial drop behavior"),
        },
        .static_initializer_type_mismatch => |mismatch| try writeMismatch(types, writer, "static initializer type mismatch: ", mismatch),
        .generic_struct_requires_specialization => {
            try writer.writeAll("struct must be specialized before initialization");
            if (span) |focus| try writer.print("; write `{s}(...){{...}}`", .{spanText(source, focus)});
        },
        .missing_operation => |missing| {
            try writeType(types, writer, missing.receiver);
            try writer.print(" does not define operation `{s}`", .{missing.operation.spelling()});
        },
        .compile_time_only_type => |type_id| try writeTypedMessage(types, writer, "compile-time-only type ", type_id, " cannot be materialized during runtime execution"),
        .ambiguous_conversion => |mismatch| try writeTypePair(types, writer, "multiple conversions apply from ", mismatch.found, " to ", mismatch.expected),
        .ambiguous_variant_member => |mismatch| try writeTypePair(types, writer, "both owned and reference alternatives accept ", mismatch.found, " in ", mismatch.expected),
        .destructure_length_mismatch => |counts| try writer.print("binding expects {d} elements, found {d}", .{ counts.expected, counts.found }),
        .tuple_member_count_mismatch => |counts| try writer.print("tuple expects {d} members, found {d}", .{ counts.expected, counts.found }),
        .type_not_movable => |type_id| try writeTypedMessage(types, writer, "cannot transfer value of immovable type ", type_id, ""),
        .relocation_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "a completed value of type ", type_id, " cannot move directly into another destination; construct it there, giving the result a known type if needed"),
        .type_not_copyable => |details| {
            try writeTypedMessage(types, writer, "cannot implicitly copy value of non-copyable type ", details.type_id, "");
            if (details.is_movable) try writer.writeAll("; use `^` to transfer ownership");
        },
        .list_requires_automatic_drop => |type_id| try writeTypedMessage(types, writer, "List requires an automatically droppable element type; found ", type_id, ""),
        .list_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "List requires a directly movable element type for relocation; found ", type_id, ""),
        .list_iteration_item_conflicts_with_end => |type_id| try writeTypedMessage(types, writer, "List consuming iteration cannot distinguish an owned End element from exhaustion; element type is ", type_id, ""),
        .borrow_write_requires_automatic_drop => |type_id| try writeTypedMessage(types, writer, "write requires an automatically droppable pointee type; found ", type_id, ""),
        .borrow_write_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "write requires a directly movable pointee type; found ", type_id, ""),
        .box_requires_automatic_drop => |type_id| try writeTypedMessage(types, writer, "Box requires an automatically droppable element type; found ", type_id, ""),
        .box_extraction_requires_direct_move => |type_id| try writeTypedMessage(types, writer, "cannot extract a non-directly-movable value from Box; found ", type_id, ""),
        .value_requires_explicit_drop => |type_id| try writeTypedMessage(types, writer, "", type_id, " must be transferred with `^` or passed to a `deinit` parameter before this scope ends"),
        .struct_initializer_not_struct => |found| try writeTypedMessage(types, writer, "only a struct type can be initialized with `{...}`; found ", found, ""),
        .missing_struct_initializer_field => |details| {
            const definition = (try types.structDefinition(details.type_id)) orelse unreachable;
            try writer.print("struct initializer is missing required field `{s}`", .{definition.fields[details.field_index].name});
        },
        .struct_initializer_field_type_mismatch => |mismatch| try writeMismatch(types, writer, "struct field initializer type mismatch: ", mismatch),
        .field_access_not_struct => |found| try writeTypedMessage(types, writer, "field access requires a struct value, found ", found, ""),
        .private_struct_field => |type_id| try writeTypedMessage(types, writer, "cannot name a private field of ", type_id, " outside its defining module"),
        .assignment_type_mismatch => |mismatch| try writeMismatch(types, writer, "assignment type mismatch: ", mismatch),
        .query_operand_not_bool => |found| try writeTypedMessage(types, writer, "query `?` requires bool, found ", found, ""),
        .variant_inspection_operand_not_variant => |found| try writeTypedMessage(types, writer, "variant inspection requires a variant value, found ", found, ""),
        .iterator_result_requires_end => |mismatch| try writeTypePair(types, writer, "next must return an item variant with owned ", mismatch.expected, ", found ", mismatch.found),
        .local_type_mismatch => |mismatch| try writeMismatch(types, writer, "initializer type mismatch: ", mismatch),
        .comparison_operand_not_int => |found| try writeTypedMessage(types, writer, "comparison requires `int`, found ", found, ""),
        .equality_operand_not_supported => |found| try writeTypedMessage(types, writer, "equality is not supported for ", found, ""),
        .equality_operand_type_mismatch => |mismatch| try writeMismatch(types, writer, "equality operand type mismatch: ", mismatch),
        .missing_return_value => |expected| try writeTypedMessage(types, writer, "function must return ", expected, " on every reachable path"),
        .return_type_mismatch => |mismatch| try writeMismatch(types, writer, "return type mismatch: ", mismatch),
        .call_argument_count_mismatch => |count| try writer.print("expected {d} call argument{s}, found {d}", .{
            count.expected,
            if (count.expected == 1) "" else "s",
            count.found,
        }),
        .call_argument_type_mismatch => |mismatch| try writeMismatch(types, writer, "argument type mismatch: ", mismatch),
        inline else => |_, tag| {
            const message = comptime structures.Diagnostic.message(tag);
            if (message.source_label)
                try writeSourceLabel(writer, message.text, source, span)
            else
                try writer.writeAll(message.text);
        },
    }
}

pub const DiagnosticSource = struct {
    file_id: structures.FileId,
    path: []const u8,
    source: []const u8,
};

fn sourceFor(sources: []const DiagnosticSource, file_id: structures.FileId) DiagnosticSource {
    for (sources) |candidate| if (candidate.file_id == file_id) return candidate;
    unreachable; // Every diagnostic must have a registered source.
}

pub fn renderDiagnostic(
    types: anytype,
    writer: *std.Io.Writer,
    sources: []const DiagnosticSource,
    diagnostic: structures.Diagnostic,
) !void {
    const file = sourceFor(sources, diagnostic.file_id);
    const is_note = std.meta.activeTag(diagnostic.kind) == .compile_time_call_trace;
    const label = if (is_note) "\x1b[36mnote:\x1b[0m" else "\x1b[31merror:\x1b[0m";
    const info: ?LineInfo = if (diagnostic.span) |span| lineInfoForOffset(file.source, span.start) else null;
    try writer.print("{s} {s}:", .{ label, file.path });
    if (info) |line| try writer.print("{d}:{d}:", .{ line.line, line.column });
    try writer.writeByte(' ');
    try writeKindMessage(types, writer, file.source, diagnostic.span, diagnostic.kind);
    try writer.writeByte('\n');
    if (info) |line| {
        try writer.print("{s}\n", .{file.source[line.line_start..line.line_end]});
        try writer.splatByteAll(' ', line.column - 1);
        try writer.writeByte('^');
        try writer.splatByteAll('~', highlightLen(diagnostic.span.?, line.line_start, line.line_end) - 1);
        try writer.writeByte('\n');
    }
    try writeFunctionContext(types, writer, diagnostic.instance);
}

fn writeFunctionContext(types: anytype, writer: *std.Io.Writer, instance: ?structures.InstanceId) !void {
    const function = instance orelse return;
    if ((try types.itemLocation(function.item)).kind != .function) return;
    try writer.writeAll("  in ");
    try writeFunctionName(types, writer, function);
    try writer.writeByte('\n');
}

pub fn renderDiagnostics(
    types: anytype,
    writer: *std.Io.Writer,
    sources: []const DiagnosticSource,
    diagnostics: []const structures.Diagnostic,
) !void {
    for (diagnostics) |diagnostic| {
        if (std.meta.activeTag(diagnostic.kind) == .compile_time_call_trace) continue;
        try renderDiagnostic(types, writer, sources, diagnostic);
    }
    // Call traces render from the failure outward.
    var traces = std.mem.reverseIterator(diagnostics);
    while (traces.next()) |diagnostic| {
        if (std.meta.activeTag(diagnostic.kind) != .compile_time_call_trace) continue;
        try renderDiagnostic(types, writer, sources, diagnostic);
    }
}

test "diagnostic types display array elements lengths and nested variants" {
    const query = @import("query/engine.zig");
    const queries = @import("queries.zig");
    const allocator = std.testing.allocator;
    const db = try query.Database.init(allocator, .{ .worker_count = 1 });
    defer db.deinit();
    const element: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .variant = .{ .members = &.{ .int, .none } } }));
    const row: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .array = .{ .element_type = element, .length = 2 } }));
    const matrix: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .array = .{ .element_type = row, .length = 0 } }));
    const callable: structures.TypeId = .fromInterned(try db.intern(queries.Types, .{ .callable = .{
        .parameters = &.{.{ .mode = .imm, .type_id = .int }},
        .return_type = .int,
        .is_fallible = false,
    } }));
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeType(types, &output.writer, matrix);
    try std.testing.expectEqualStrings("`Array(Array(int | none, 2), 0)`", output.writer.buffered());
    const cases = [_]struct { kind: structures.Diagnostic.Kind, message: []const u8 }{
        .{ .kind = .{ .missing_operation = .{ .receiver = .bool, .operation = .@"+" } }, .message = "`bool` does not define operation `+`" },
        .{ .kind = .{ .unsupported_syntax = .keyword_for }, .message = "`for` syntax is not implemented yet" },
        .{ .kind = .{ .compile_time_only_type = matrix }, .message = "compile-time-only type `Array(Array(int | none, 2), 0)` cannot be materialized during runtime execution" },
        .{ .kind = .{ .return_type_mismatch = .{ .expected = matrix, .found = .int } }, .message = "return type mismatch: expected `Array(Array(int | none, 2), 0)`, found `int`" },
        .{ .kind = .{ .type_not_copyable = .{ .type_id = matrix, .is_movable = true } }, .message = "cannot implicitly copy value of non-copyable type `Array(Array(int | none, 2), 0)`; use `^` to transfer ownership" },
        .{ .kind = .{ .type_not_copyable = .{ .type_id = matrix, .is_movable = false } }, .message = "cannot implicitly copy value of non-copyable type `Array(Array(int | none, 2), 0)`" },
        .{ .kind = .overload_requires_callable_context, .message = "an overload reference requires a function-type annotation" },
        .{ .kind = .{ .no_matching_overload = null }, .message = "no overload matches the argument types and count" },
        .{ .kind = .{ .no_matching_overload = callable }, .message = "no overload matches the required function type `func(int) int`" },
        .{ .kind = .ambiguous_overload, .message = "multiple overloads match; name an implementation explicitly" },
    };
    for (cases) |case| {
        output.clearRetainingCapacity();
        try writeKindMessage(types, &output.writer, "", null, case.kind);
        try std.testing.expectEqualStrings(case.message, output.writer.buffered());
    }
}
