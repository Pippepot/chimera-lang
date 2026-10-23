const std = @import("std");
const test_sources = @import("test_sources");
const queries = test_sources.queries;
const structures = test_sources.structures;
const testing = std.testing;
const Fixture = test_sources.SourceFixture;

const Tag = std.meta.Tag(structures.FunctionInstruction);

const source =
    \\func identities(a: int) int -> 0 + a * 1 * -1 / -1 - 0
    \\func folded() int -> (2147483647 + 1) / -1 + 7 * 6
    \\func branch(a: int) int
    \\    if 3 < 4 -> return a
    \\    return 90
    \\func failing(a: int) int -> a / 0
    \\func run() int -> identities(2) + branch(40) + folded() - folded()
;

fn optimizedBody(fixture: Fixture, name: []const u8) !*const ?structures.FunctionBodyAnalysis {
    const item = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction(name).?;
    return fixture.db.get(queries.OptimizeFunctionInstance, .{ .item = item });
}

fn count(body: structures.FunctionBodyAnalysis, tags: []const Tag) usize {
    var total: usize = 0;
    for (body.instructions) |instruction| {
        if (std.mem.indexOfScalar(Tag, tags, std.meta.activeTag(instruction))) |_| total += 1;
    }
    return total;
}

fn hasConstant(body: structures.FunctionBodyAnalysis, value: i32) bool {
    for (body.instructions) |instruction| {
        if (instruction == .const_int and instruction.const_int == value) return true;
    }
    return false;
}

const arithmetic = [_]Tag{ .addi, .subi, .muli, .divsi, .negi };

test "optimizer folds integer constants identities and constant branches" {
    const program = try testing.allocator.print("{s}\nexit(run())", .{source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const identities = (try optimizedBody(fixture, "identities")).*.?;
    try testing.expectEqual(@as(usize, 0), count(identities, &arithmetic));

    const folded = (try optimizedBody(fixture, "folded")).*.?;
    try testing.expectEqual(@as(usize, 0), count(folded, &arithmetic));
    try testing.expect(hasConstant(folded, std.math.minInt(i32) + 42));

    const branch = (try optimizedBody(fixture, "branch")).*.?;
    for (branch.blocks) |block| try testing.expect(block.terminator != .predicate_branch);
    try testing.expect(!hasConstant(branch, 90));

    const failing = (try optimizedBody(fixture, "failing")).*.?;
    try testing.expectEqual(@as(usize, 1), count(failing, &.{.divsi}));
}

test "optimized native code agrees with unoptimized compile-time execution" {
    try Fixture.expectParity(source, 42);
    try Fixture.expectParity(
        \\func scale(a: int, b: int) int -> a * 0 + b * -1 + b / -1 + -(-a)
        \\func run() int
        \\    const minimum = -2147483647 - 1
        \\    if scale(minimum, minimum) <> 0 - minimum - minimum + minimum -> return 90
        \\    if scale(5, -1) <> 7 -> return 91
        \\    if minimum * -1 <> minimum -> return 92
        \\    if minimum / -1 * 1 + 0 <> minimum -> return 93
        \\    if 1 > 2 -> return 94
        \\    return 42
    , 42);
}

test "optimized bodies recompute only when their typed body changes" {
    const program = try testing.allocator.print("{s}\nexit(run())", .{source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const identities = try optimizedBody(fixture, "identities");
    const branch = try optimizedBody(fixture, "branch");

    const edited = try std.mem.replaceOwned(u8, testing.allocator, program, "return 90", "return 91");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(0, 42);
    try testing.expectEqual(identities, try optimizedBody(fixture, "identities"));
    try testing.expectEqual(branch, try optimizedBody(fixture, "branch"));

    const changed = try std.mem.replaceOwned(u8, testing.allocator, edited, "a * 1 * -1 / -1", "a * 2 * -1 / -1");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(0, 44);
    const recomputed = try optimizedBody(fixture, "identities");
    try testing.expect(identities != recomputed);
    try testing.expectEqual(@as(usize, 1), count(recomputed.*.?, &.{.muli}));
}

fn countLocalStorage(body: structures.FunctionBodyAnalysis, type_id: structures.TypeId) usize {
    var total: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .local_storage and instruction.local_storage == type_id) total += 1;
    }
    return total;
}

const promotion_source =
    \\func change(ref value: int) unit -> value += 1
    \\fallible positive(value: int) int
    \\    if value < 0 -> fail
    \\    return value
    \\func sum(limit: int) int
    \\    var total = 0
    \\    var index = 0
    \\    var odd = false
    \\    loop
    \\        if index == limit -> break
    \\        index += 1
    \\        if odd? -> odd = false else odd = true
    \\        if odd? -> continue
    \\        total += index
    \\    return total
    \\func merge(flag: bool, var start: int) int
    \\    var value = start
    \\    if flag?
    \\        value = value * 2
    \\        start = 1
    \\    else
    \\        value = value + 3
    \\    return value + start
    \\func borrowed(start: int) int
    \\    var value = start
    \\    change(value)
    \\    return value
    \\fallible checked(start: int) int
    \\    var value = start
    \\    var attempts = 0
    \\    loop
    \\        attempts += 1
    \\        if const accepted = positive(value) -> return accepted + attempts
    \\        value += 5
    \\func run() int
    \\    if sum(10) <> 30 -> return 90
    \\    if merge(true, 4) <> 9 -> return 91
    \\    if merge(false, 4) <> 11 -> return 92
    \\    if borrowed(6) <> 7 -> return 93
    \\    if const value = checked(-12) -> if value == 7 -> return 42
    \\    return 94
;

test "promotion turns non-escaping scalar locals into SSA values" {
    try Fixture.expectParity(promotion_source, 42);
    const program = try testing.allocator.print("{s}\nexit(run())", .{promotion_source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "sum", "merge", "checked" }) |name| {
        const body = (try optimizedBody(fixture, name)).*.?;
        try testing.expectEqual(@as(usize, 0), countLocalStorage(body, .int) + countLocalStorage(body, .bool));
        try testing.expectEqual(@as(usize, 0), count(body, &.{.value_copy}));
    }
    const borrowed = (try optimizedBody(fixture, "borrowed")).*.?;
    try testing.expectEqual(@as(usize, 1), countLocalStorage(borrowed, .int));
}
