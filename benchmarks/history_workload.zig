const std = @import("std");

pub const File = struct { path: []const u8, source: []const u8, module_path: []const u8 };

pub const Workload = struct {
    arena: std.heap.ArenaAllocator,
    entry: []const u8,
    files: []const File,
    edited_leaf: []const u8,
    lines: usize,
    units: usize,

    pub fn deinit(self: *Workload) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const support =
    \\pub struct Pair
    \\    pub left: int
    \\    pub right: int
    \\    pub func sum(imm self: Pair) int -> self.left + self.right
    \\pub converter(imm value: Pair) int -> value.sum()
    \\pub struct Cell(T: type)
    \\    pub value: T
    \\pub struct Token
    \\    copy = none
    \\    pub value: int
    \\pub func consume(deinit token: Token) int -> token.value
    \\pub func identity(static T: type, value: T) T -> value
    \\pub func integer(value: int) int -> value
    \\pub func boolean(value: bool) int
    \\    if value -> return 1
    \\    return 0
    \\pub overload choose(integer, boolean)
    \\pub func bump(mut value: int) -> value += 1
    \\pub func checked(value: int) int | none
    \\    if not (value >= 0) -> return none
    \\    return value
;

const unit_body =
    \\    var total = seed + 1
    \\    const pair = Pair{left = total, right = 3}
    \\    total = pair.sum()
    \\    const cell = Cell(int){value = total}
    \\    total = identity(cell.value)
    \\    const (left, right) = (total, 2)
    \\    total = left + right
    \\    var array: Array(int, 3) = [seed, 2, 3]
    \\    var values: List(int) = [array[0], array[1], array[2]]
    \\    values[0] += 1
    \\    ref first = values[0]
    \\    first += 1
    \\    var view = values[0..2]
    \\    for item in view
    \\        total += item
    \\    var index = 0
    \\    loop
    \\        if index == 3 -> break
    \\        total += index
    \\        index += 1
    \\    for number in 0..3
    \\        total += number
    \\    if seed >= 0 and total > 0
    \\        total += 2
    \\    else
    \\        return 0
    \\    const variant: int | none = total
    \\    total = match variant
    \\        value: int -> value
    \\        none -> 0
    \\    if const accepted: int = checked(total)
    \\        total = accepted
    \\    else
    \\        return 0
    \\    if checked(-1) is int -> return 0
    \\    total += choose(seed)
    \\    total += choose(true)
    \\    bump(total)
    \\    const text = String(values)
    \\    if text <> "[3, 2, 3]" -> return 0
    \\    const folded = comptime -> 2 + 3
    \\    total += folded
    \\    const callback: func(int) int = integer
    \\    total = callback(total)
    \\    total = int(Pair{left = total, right = 0})
    \\    var token = Token{value = total}
    \\    total = consume(token^)
    \\    if total <> 28 -> return 0
    \\    return 1
;

pub fn generate(allocator: std.mem.Allocator, target_lines: usize) !Workload {
    if (target_lines < 256) return error.WorkloadTooSmall;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const module_count: usize = @min(128, @max(1, target_lines / 4096));
    const support_source = support ++ "\n";
    const body = unit_body ++ "\n";
    const fixed_lines = std.mem.count(u8, support_source, "\n") + 1 + module_count * 9 + 4;
    const unit_lines = std.mem.count(u8, body, "\n") + 2;
    const units_per_module = (target_lines - fixed_lines) / (module_count * unit_lines);
    if (units_per_module == 0) return error.WorkloadTooSmall;
    const padding = target_lines - fixed_lines - module_count * units_per_module * unit_lines;
    const files = try owned.alloc(File, module_count + 2);
    files[0] = .{ .path = "support.chi", .module_path = "support", .source = support_source };
    var entry: std.Io.Writer.Allocating = .init(owned);
    try entry.writer.writeAll("import leaf\n");
    for (0..module_count) |module_index| {
        const module_path = try std.fmt.allocPrint(owned, "part{d}", .{module_index});
        try entry.writer.print("import {s}\n", .{module_path});
        var source: std.Io.Writer.Allocating = .init(owned);
        try source.writer.writeAll("import support.{Pair, Cell, Token, identity, integer, choose, bump, checked, consume}\n");
        for (0..units_per_module) |unit_index| {
            try source.writer.print("func exercise_{d}(seed: int) int\n", .{unit_index});
            try source.writer.writeAll(body);
        }
        try source.writer.writeAll("pub func run(seed: int) int\n    var total = 0\n");
        for (0..units_per_module) |unit_index|
            try source.writer.print("    total += exercise_{d}(seed)\n", .{unit_index});
        try source.writer.writeAll("    return total\n");
        files[module_index + 1] = .{
            .path = try std.fmt.allocPrint(owned, "{s}.chi", .{module_path}),
            .module_path = module_path,
            .source = try source.toOwnedSlice(),
        };
    }
    try entry.writer.writeAll("var padding = 0\n");
    for (0..module_count) |module_index| {
        try entry.writer.print("if const actual: int = part{d}.run(1)\n", .{module_index});
        try entry.writer.print("    if actual <> {d} -> exit(1)\n", .{units_per_module});
        try entry.writer.writeAll("else\n    exit(1)\n");
    }
    for (0..padding) |_| try entry.writer.writeAll("padding += 1\n");
    try entry.writer.print("if padding <> {d} -> exit(1)\n", .{padding});
    try entry.writer.writeAll("exit(leaf.value() + 1)\n");
    files[files.len - 1] = .{ .path = "leaf.chi", .module_path = "leaf", .source = "pub func value() int -> 41\n" };
    const entry_source = try entry.toOwnedSlice();
    var lines = std.mem.count(u8, entry_source, "\n");
    for (files) |file| lines += std.mem.count(u8, file.source, "\n");
    std.debug.assert(lines == target_lines);
    return .{
        .arena = arena,
        .entry = entry_source,
        .files = files,
        .edited_leaf = "pub func value() int -> 42\n",
        .lines = lines,
        .units = module_count * units_per_module,
    };
}

test "mixed workloads contain exactly the requested nonblank code lines" {
    for ([_]usize{ 1000, 10_000, 1_000_000 }) |target| {
        var workload = try generate(std.testing.allocator, target);
        defer workload.deinit();
        try std.testing.expectEqual(target, workload.lines);
        var calls: usize = 0;
        for (workload.files) |file| {
            try std.testing.expect(std.mem.indexOf(u8, file.source, "\n\n") == null);
            calls += std.mem.count(u8, file.source, "total += exercise_");
        }
        try std.testing.expectEqual(workload.units, calls);
        try std.testing.expectEqualStrings("leaf", workload.files[workload.files.len - 1].module_path);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, workload.edited_leaf, "\n"));
    }
}
