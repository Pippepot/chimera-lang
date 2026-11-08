const std = @import("std");
const test_sources = @import("test_sources");
const queries = test_sources.queries;
const structures = test_sources.structures;
const testing = std.testing;
const Fixture = test_sources.SourceFixture;

const Tag = std.meta.Tag(structures.FunctionInstruction);

const source =
    \\func identities(a: int) int -> wrapping(0 + a * 1 * -1 / -1 - 0)
    \\func folded() int -> wrapping((2147483647 + 1) / -1 + 7 * 6)
    \\func branch(a: int) int
    \\    if 3 < 4 -> return a
    \\    return 90
    \\func failing(a: int) int -> a / 0
    \\func run() int -> wrapping(identities(2) + branch(40) + folded() - folded())
;

fn optimizedBody(fixture: Fixture, name: []const u8) !*const ?structures.FunctionBodyAnalysis {
    const item = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction(name).?;
    return fixture.db.get(queries.OptimizeFunctionInstance, .{ .item = item });
}

fn count(body: structures.FunctionBodyAnalysis, tags: []const Tag) usize {
    var total: usize = 0;
    for (body.instructions) |instruction| {
        const tag: Tag = switch (instruction) {
            .numeric_binary => |operation| switch (operation.operation) {
                .add => .addi,
                .sub => .subi,
                .mul => .muli,
                .div => .divsi,
                .shl => .shli,
                .shr => .shrsi,
                else => .numeric_binary,
            },
            .numeric_unary => |operation| if (operation.operation == .neg) .negi else .numeric_unary,
            else => std.meta.activeTag(instruction),
        };
        if (std.mem.indexOfScalar(Tag, tags, tag)) |_| total += 1;
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

const checked_steps = block: {
    const line = "    value += 1\n";
    var text: [line.len * 64]u8 = undefined;
    for (0..64) |step| @memcpy(text[step * line.len ..][0..line.len], line);
    break :block text;
};

const guarded_call =
    \\func bounded(index: int) int
    \\    if index < 0 or index >= 9 -> panic "late guard"
    \\    var value = index
++ "\n" ++ checked_steps ++
    \\    return value
;

test "call-boundary ranges require guards on every normal return and recompute" {
    const program = guarded_call ++ "\n" ++
        \\func scan(limit: int) int
        \\    if limit < 0 or limit > 9 -> return 0
        \\    var values: Array(int, 9) = [0, 1, 2, 3, 4, 5, 6, 7, 8]
        \\    var count = 0
        \\    for row in 0..=limit
        \\        if row > 0
        \\            bounded(count)
        \\            count += 1
        \\    var valid = true
        \\    var left = 0
        \\    loop
        \\        if not valid or left >= count - 1 -> break
        \\        var right = left + 1
        \\        loop
        \\            if not valid or right >= count -> break
        \\            if values[left] == values[right] -> valid = false
        \\            right += 1
        \\        left += 1
        \\    return left
        \\func run() int -> scan(9) + scan(0) + scan(1) + 34
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expectEqual(@as(usize, 1), countCalls(body));
    const edited = try std.mem.replaceOwned(u8, testing.allocator, program, "-> panic \"late guard\"", "-> return 0");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    const changed = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expect(countCalls(changed) > 1);
}

test "call-boundary ranges cannot remove an earlier overflow trap" {
    const program = guarded_call ++ "\n" ++
        \\func scan(first: int, limit: int) int
        \\    var index = first
        \\    loop
        \\        if index > limit - 1 -> break
        \\        index += 2
        \\        bounded(limit)
        \\    return 42
        \\func run() int -> scan(7, 8)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program ++ "\nexit(scan(2147483646, 2147483647))");
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    const result = try fixture.runIo("");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "late guard") == null);
}

test "nested collision counters infer guarded array bounds" {
    const program =
        \\func scan(limit: int) int
        \\    if limit < 0 or limit > 8 -> return 0
        \\    var values: Array(int, 8) = [0, 1, 2, 3, 4, 5, 6, 7]
        \\    var valid = true
        \\    var left = 0
        \\    loop
        \\        if not valid or left >= limit - 1 -> break
        \\        var right = left + 1
        \\        loop
        \\            if not valid or right >= limit -> break
        \\            if values[left] == values[right] -> valid = false
        \\            right += 1
        \\        left += 1
        \\    return left
        \\func run() int -> scan(8) + scan(0) + scan(1) + scan(-1) + scan(9) + 35
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expectEqual(@as(usize, 0), countCalls(body));
}

test "nested generation carries successful write bounds into collision scan" {
    const program =
        \\func scan(limit: int) int
        \\    if limit < 0 or limit > 3 -> return 0
        \\    var values = Array(int, 64).filled(0)
        \\    var count = 0
        \\    for first in 0..=limit
        \\        for second in first..=limit
        \\            for third in second..=limit
        \\                for fourth in third..=limit
        \\                    for fifth in fourth..=limit
        \\                        if first <> fifth
        \\                            values[count] = count
        \\                            count += 1
        \\    var valid = true
        \\    var left = 0
        \\    loop
        \\        if not valid or left >= count - 1 -> break
        \\        var right = left + 1
        \\        loop
        \\            if not valid or right >= count -> break
        \\            if values[left] == values[right] -> valid = false
        \\            right += 1
        \\        left += 1
        \\    return left
        \\func run() int -> scan(3) + scan(0) + scan(1) + scan(-1) + scan(4) - 12
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expectEqual(@as(usize, 1), countCalls(body));
    const edited = try std.mem.replaceOwned(u8, testing.allocator, program ++ "\nexit(scan(3))", "count += 1", "count += 3");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    const changed = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expect(countCalls(changed) > 1);
    const result = try fixture.runIo("");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
}

test "invariant loop bounds retain traps and initial flag short circuit" {
    const program =
        \\func scan(limit: int, valid: bool) int
        \\    var index = 0
        \\    loop
        \\        if not valid -> break
        \\        if index >= limit - 1 -> break
        \\        index += 1
        \\    return index
        \\exit(scan(-2147483648, false))
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    const skipped = try fixture.runIo("");
    defer testing.allocator.free(skipped.stdout);
    defer testing.allocator.free(skipped.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, skipped.term);
    const edited = try std.mem.replaceOwned(u8, testing.allocator, program, "false", "true");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    const evaluated = try fixture.runIo("");
    defer testing.allocator.free(evaluated.stdout);
    defer testing.allocator.free(evaluated.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 134 }, evaluated.term);
}

test "conditional bounds cannot prove a wrapping recurrence safe" {
    try Fixture.expectParity(
        \\func scan(first: int, limit: int) int
        \\    if limit > 100 -> return 0
        \\    var index = first
        \\    var guarded = false
        \\    loop
        \\        if guarded
        \\            if index >= limit -> break
        \\            if index < 0 -> return 42
        \\        guarded = true
        \\        index = wrapping(index + 1)
        \\    return 0
        \\func run() int -> scan(2147483647, 10)
    , 42);
}

test "carried boolean exits rotate both stop and valid flags" {
    for ([_]bool{ false, true }) |exit_value| {
        const program = try testing.allocator.print(
            \\func scan(first: int, limit: int, stop: int, initial: bool) int
            \\    var index = first
            \\    var flag = initial
            \\    var total = 0
            \\    loop
            \\        if {s} -> break
            \\        if index >= limit -> break
            \\        total += index
            \\        if index == stop -> flag = {s}
            \\        index += 1
            \\    if flag -> total += 100
            \\    return total + index
            \\func run() int -> scan(0, 6, 3, {s}) + scan(0, 6, 9, {s}) + scan(2, 2, 2, {s}) + scan(1, 4, 2, {s}) - 192
        , .{
            if (exit_value) "flag" else "not flag",
            if (exit_value) "true" else "false",
            if (exit_value) "false" else "true",
            if (exit_value) "false" else "true",
            if (exit_value) "false" else "true",
            if (exit_value) "true" else "false",
        });
        defer testing.allocator.free(program);
        try Fixture.expectParity(program, 42);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const body = (try optimizedBody(fixture, "scan")).*.?;
        try testing.expectEqual(@as(usize, 0), count(body, &.{.select}));
    }
}

test "numbering substitutions converge through branch folding" {
    const program =
        \\func same(value: int) int
        \\    var first = value + 1
        \\    var second = value + 1
        \\    if first == second -> return 42
        \\    return 0
        \\func run() int -> same(7)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "same")).*.?;
    // The shared checked addition must still panic for MAX.
    try testing.expectEqual(@as(usize, 1), count(body, &arithmetic));
    try testing.expectEqual(@as(usize, 0), countPredicates(body));
    try testing.expect(hasConstant(body, 42));
}

test "guarded dynamic loop ranges remove redundant checks for ascending strides" {
    for ([_]i32{ 1, 2, 3 }) |step| for ([_]bool{ false, true }) |inclusive| for ([_]bool{ false, true }) |reversed| {
        const sum: i32 = switch (step) {
            1 => if (inclusive) 28 else 21,
            2 => if (inclusive) 16 else 9,
            3 => if (inclusive) 12 else 5,
            else => unreachable,
        };
        const exit = if (reversed)
            (if (inclusive) "limit < index" else "limit <= index")
        else
            (if (inclusive) "index > limit" else "index >= limit");
        const boundary = std.math.maxInt(i32) - step;
        const program = try testing.allocator.print(
            \\func scan(first: int, limit: int) int
            \\    if {s} -> return 0
            \\    if limit > {d} -> return 0
            \\    var index = first
            \\    var sum = 0
            \\    loop
            \\        if {s} -> break
            \\        if {s} -> return -100
            \\        if {s} -> return -200
            \\        sum += index
            \\        index += {d}
            \\    return sum
            \\func run() int -> wrapping(scan(1, 7) + scan(-1, 7) + scan(8, 7) + scan(9, 7) + {d} + scan({d}, {d}) - {d})
        , .{
            if (reversed) "0 > first" else "first < 0",
            std.math.maxInt(i32) - step + @intFromBool(!inclusive),
            exit,
            if (reversed) "0 > index" else "index < 0",
            exit,
            step,
            42 - sum,
            boundary,
            boundary + @intFromBool(!inclusive),
            boundary,
        });
        defer testing.allocator.free(program);
        try Fixture.expectParity(program, 42);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const body = (try optimizedBody(fixture, "scan")).*.?;
        try testing.expect(!hasConstant(body, -100));
        try testing.expect(!hasConstant(body, -200));
    };
}

test "loop proofs follow checked shifted starts and lower safe recurrences" {
    const program =
        \\func shifted(first: int, limit: int) int
        \\    if limit > 100 -> return 0
        \\    var index = first + 1
        \\    var total = 0
        \\    loop
        \\        if index >= limit -> break
        \\        if first < 0 -> return -100
        \\        if index < 1 -> return -200
        \\        total += index
        \\        index += 1
        \\    return total
        \\func run() int -> shifted(0, 7) + shifted(1, 6) + shifted(9, 9) + shifted(-2, 6) + 107
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "shifted")).*.?;
    try testing.expectEqual(@as(usize, 3), countPredicates(body));
    var checked: usize = 0;
    var wrapping: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .addi) wrapping += 1;
        if (instruction != .numeric_binary) continue;
        if (instruction.numeric_binary.overflow == .checked) checked += 1;
        if (instruction.numeric_binary.overflow == .wrapping) wrapping += 1;
    }
    try testing.expectEqual(@as(usize, 2), checked);
    try testing.expectEqual(@as(usize, 1), wrapping);
}

test "carried collision exits preserve an overflowing final increment" {
    const fixture = try Fixture.init(
        \\func scan(first: int, limit: int)
        \\    var index = first
        \\    var valid = true
        \\    loop
        \\        if not valid -> break
        \\        if index > limit -> break
        \\        if index == limit -> valid = false
        \\        index += 1
        \\scan(2147483647, 2147483647)
    );
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    const result = try fixture.runIo("");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
}

test "guarded dynamic loop ranges remove redundant checks for descending strides" {
    for ([_]i32{ 1, 2, 3 }) |step| for ([_]bool{ false, true }) |inclusive| for ([_]bool{ false, true }) |reversed| {
        const sum: i32 = switch (step) {
            1 => if (inclusive) 28 else 27,
            2 => if (inclusive) 16 else 15,
            3 => if (inclusive) 12 else 11,
            else => unreachable,
        };
        const exit = if (reversed)
            (if (inclusive) "limit > index" else "limit >= index")
        else
            (if (inclusive) "index < limit" else "index <= limit");
        const program = try testing.allocator.print(
            \\func scan(first: int, limit: int) int
            \\    if {s} -> return 0
            \\    if limit < 0 -> return 0
            \\    var index = first
            \\    var sum = 0
            \\    loop
            \\        if {s} -> break
            \\        if index < 0 -> return -100
            \\        if {s} -> return -200
            \\        if {s} -> return -300
            \\        sum += index
            \\        index -= {d}
            \\    return sum
            \\func run() int -> scan(7, 1) + scan(13, 1) + scan(0, 1) + scan(7, -1) + {d}
        , .{
            if (reversed) "12 < first" else "first > 12",
            exit,
            if (reversed) "12 < index" else "index > 12",
            exit,
            step,
            42 - sum,
        });
        defer testing.allocator.free(program);
        try Fixture.expectParity(program, 42);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const body = (try optimizedBody(fixture, "scan")).*.?;
        try testing.expectEqual(@as(usize, 3), countPredicates(body));
    };
}

test "loop ranges retain checks across wrapping and non-dominating guards" {
    const program =
        \\func ascending() int
        \\    var index = 2147483646
        \\    var visited = 0
        \\    loop
        \\        if index >= 2147483647 -> break
        \\        if index < 0 -> return 21
        \\        if visited == 2 -> return -100
        \\        visited += 1
        \\        index = wrapping(index + 2)
        \\    return -200
        \\func descending() int
        \\    var index = -2147483647
        \\    var visited = 0
        \\    loop
        \\        if index <= -2147483648 -> break
        \\        if index > 0 -> return 21
        \\        if visited == 2 -> return -100
        \\        visited += 1
        \\        index = wrapping(index - 2)
        \\    return -200
        \\func partial(first: int, limit: int, guarded: bool) int
        \\    if guarded
        \\        if first < 0 -> return 0
        \\    var index = first
        \\    loop
        \\        if index >= limit -> break
        \\        if index < 0 -> return 21
        \\        index += 1
        \\    return 0
        \\func run() int -> ascending() + descending() + partial(-1, 1, false) - 21
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "ascending", "descending", "partial" }, [_]usize{ 3, 3, 4 }) |name, expected| {
        const body = (try optimizedBody(fixture, name)).*.?;
        try testing.expectEqual(expected, countPredicates(body));
    }
}

test "dead loop removal preserves potentially nonterminating nested iterations" {
    const fixture = try Fixture.init(
        \\func spin(start: int, waiting: bool) int
        \\    var index = start
        \\    loop
        \\        if index == 0 -> break
        \\        loop
        \\            if not waiting -> break
        \\        index -= 1
        \\    return 42
    );
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "spin")).*.?;
    try testing.expect(countPredicates(body) != 0);
}

test "loop rewrites compose and recompute range proofs after source edits" {
    const program =
        \\func scan(first: int, limit: int) int
        \\    if first < 0 -> return 0
        \\    if limit > 100 -> return 0
        \\    var index = first
        \\    var sum = 0
        \\    loop
        \\        if index >= limit -> break
        \\        var discarded = index
        \\        loop
        \\            if discarded == 0 -> break
        \\            discarded = wrapping(discarded - 1)
        \\        if index < 0 -> return -100
        \\        if index >= limit -> return -200
        \\        sum += index
        \\        index += 3
        \\    return sum
        \\func run() int -> scan(1, 8) + scan(9, 8) + 30
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
    const original = try optimizedBody(fixture, "scan");
    try testing.expectEqual(@as(usize, 3), countPredicates(original.*.?));

    const edited = try std.mem.replaceOwned(u8, testing.allocator, program ++ "\nexit(run())", "limit > 100", "limit > 2147483647");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(0, 42);
    const recomputed = try optimizedBody(fixture, "scan");
    try testing.expect(original != recomputed);
    try testing.expectEqual(@as(usize, 3), countPredicates(recomputed.*.?));
}

test "carried exit rotation preserves empty and final range iterations" {
    const program =
        \\func calculate(first: int, limit: int) int
        \\    var sum = 0
        \\    for value in first..limit
        \\        sum += value
        \\    return sum
        \\func run() int -> calculate(2, 6) * 3 + calculate(3, 3) + calculate(7, 3)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{.select}));
}

test "threaded range exits resolve aliases introduced by block merging" {
    try Fixture.expectParity(
        \\func drain(first: int, limit: int) int
        \\    for _ in (first..limit).reversed() -> ()
        \\    return 7
        \\func run() int
        \\    const first = drain(0, 2)
        \\    const second = drain(3, 3)
        \\    const third = drain(5, 2)
        \\    var values = List(int).new(2)
        \\    if not (values is List(int)) -> return 90
        \\    if not (values.append(10) is unit) -> return 91
        \\    if not (values.append(11) is unit) -> return 92
        \\    return first + second + third + values[0] + values[1]
    , 42);
}

test "terminal range counters prove guarded array bounds and withdraw edited guards" {
    for ([_][]const u8{ "first..=limit", "(first..=limit).reversed()" }) |range| {
        const program = try test_sources.renderTemplate(testing.allocator,
            \\func scan(first: int, limit: int) int
            \\    if first < 0 or limit >= 8 -> return 0
            \\    var values: Array(int, 8) = [0, 1, 2, 3, 4, 5, 6, 7]
            \\    var sum = 0
            \\    for index in $range
            \\        sum += values[index]
            \\    return sum
            \\func run() int -> scan(1, 4) + scan(3, 3) + scan(9, 2) + scan(0, -1) + 29
        , .{ .range = range });
        defer testing.allocator.free(program);
        try Fixture.expectParity(program, 42);
        const checked = try testing.allocator.print("{s}\nexit(scan(0, 8))", .{program});
        defer testing.allocator.free(checked);
        const fixture = try Fixture.init(checked);
        defer fixture.deinit();
        try fixture.expectExit(0, 0);
        const before = (try optimizedBody(fixture, "scan")).*.?;
        try testing.expectEqual(@as(usize, 0), countCalls(before));
        const edited = try std.mem.replaceOwned(u8, testing.allocator, checked, "limit >= 8", "limit > 8");
        defer testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        const after = (try optimizedBody(fixture, "scan")).*.?;
        try testing.expect(countCalls(after) != 0);
        try fixture.expectExit(0, 134);
    }
}

test "range engine proves counters carried beside a terminal range counter" {
    const program =
        \\func tally(limit: int) int
        \\    if limit < 2 or limit == 2147483647 -> return 0
        \\    var found = 0
        \\    for number in 2..(limit + 1)
        \\        if number % 2 == 0 -> found += 1
        \\    return found
        \\func run() int -> tally(10) + tally(1) + 37
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "tally")).*.?;
    // The remainder test became a mask, leaving no unproven checked operation.
    try testing.expectEqual(@as(usize, 0), countChecked(body));
    try testing.expectEqual(@as(usize, 1), count(body, &.{.select}));
}

test "range engine keeps carried overflow reachable" {
    const fixture = try Fixture.init(
        \\func tally(start: int) int
        \\    var found = start
        \\    for number in 2..=20
        \\        found += 1
        \\    return found
        \\exit(tally(2147483640))
    );
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "tally")).*.?;
    try testing.expect(countChecked(body) != 0);
    try fixture.expectExit(0, 134);
}

test "carried exit rotation preserves a conditional backedge and its separate return" {
    const program =
        \\func scan(first: int, limit: int, empty: bool) int
        \\    var value = first
        \\    var finished = empty
        \\    var count = 0
        \\    loop
        \\        if finished -> break
        \\        if value == limit -> finished = true else value += 1
        \\        count += 1
        \\        if value < 0 -> return 9
        \\    return count + 10 * value
        \\func run() int -> scan(0, 2, false) + scan(2, 2, false) + scan(-1, -1, false) + scan(3, 1, true) - 41
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{.select}));
}

test "terminal counter proofs preserve unconditional final overflow" {
    const fixture = try Fixture.init(
        \\func scan(first: int, limit: int) int
        \\    var index = first
        \\    loop
        \\        const next = index + 1
        \\        if index == limit -> break
        \\        index = next
        \\    return 42
        \\exit(scan(2147483647, 2147483647))
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 134);
}

test "carried exit rotation preserves observable cursor and finished state" {
    try Fixture.expectParity(
        \\func walk(limit: int) int
        \\    var index = 0
        \\    var sum = 0
        \\    var finished = limit <= 0
        \\    loop
        \\        if finished -> break
        \\        sum += index
        \\        if index + 1 == limit -> finished = true else index += 1
        \\    return sum + index * 10 + if finished -> 1 else 0
        \\func run() int -> walk(4) + walk(0) + walk(-1) + 3
    , 42);
}

test "unchanged nested aggregates leave loops while changing fields retain their values" {
    const program =
        \\pub struct Pair
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\struct Nested
        \\    copy = trivial
        \\    pub pair: Pair
        \\    pub extra: int
        \\func rebuild(value: Nested) Nested
        \\    return Nested{pair = Pair{first = value.pair.first, second = value.pair.second}, extra = value.extra}
        \\func steady(value: Nested, limit: int) int
        \\    var saved = value
        \\    var index = 0
        \\    var sum = 0
        \\    loop
        \\        if index >= limit -> break
        \\        saved = rebuild(saved)
        \\        sum += saved.pair.first
        \\        index += 1
        \\    return sum + saved.pair.second + saved.extra
        \\func changing(value: Pair, limit: int) int
        \\    var saved = value
        \\    var index = 0
        \\    loop
        \\        if index >= limit -> break
        \\        saved = Pair{first = saved.second, second = saved.first + 1}
        \\        index += 1
        \\    return saved.first + saved.second
        \\func run() int
        \\    const pair = Pair{first = 3, second = 5}
        \\    const nested = Nested{pair = pair, extra = 4}
        \\    return steady(nested, 5) + changing(pair, 2) + steady(nested, 0) - 1
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const rebuilt = (try optimizedBody(fixture, "rebuild")).*.?;
    try testing.expectEqual(@as(usize, 0), count(rebuilt, &.{.aggregate}));
    const steady = (try optimizedBody(fixture, "steady")).*.?;
    for (steady.blocks, 0..) |block, index| {
        if (index == @backingInt(steady.entry)) continue;
        for (steady.block_arguments[block.argument_start..block.argument_end]) |argument|
            try testing.expect(argument.type_id.isPrimitive());
    }
}

test "scalar replacement copies split slots without aliasing their fields" {
    const program =
        \\struct Pair
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\func calculate(limit: int) int
        \\    var source = Pair{first = 1, second = 2}
        \\    var saved = Pair{first = 0, second = 0}
        \\    var index = 0
        \\    loop
        \\        if index == limit -> break
        \\        saved = source
        \\        source.first += 1
        \\        source.second += 2
        \\        index += 1
        \\    return saved.first * 10 + saved.second
        \\func run() int -> calculate(4) + calculate(0) - 6
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .aggregate, .field_access, .local_storage }));
}

test "ordinary user cursor construction and polling simplify across loop joins" {
    const program =
        \\struct Cursor
        \\    position: int
        \\    last: int
        \\    descending: bool
        \\    func next(mut self: Cursor) int | End
        \\        if self.position == self.last -> return End{}
        \\        const result = self.position
        \\        if self.descending -> self.position -= 1
        \\        else self.position += 1
        \\        return result
        \\struct Source
        \\    first: int
        \\    last: int
        \\    func iter(self: Source) Cursor
        \\        return Cursor{position = self.first, last = self.last, descending = false}
        \\func sum(first: int, last: int) int
        \\    var result = 0
        \\    for item in Source{first = first, last = last} -> result += item
        \\    return result
        \\func run() int -> sum(2, 10) - sum(2, 2) - 2
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "sum")).*.?;
    try testing.expectEqual(@as(usize, 0), countCalls(body));
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .aggregate, .subi, .variant_coerce, .variant_extract, .variant_tag, .select }));
}

test "bounds proofs ignore the untested first iteration of a bottom-tested counter" {
    try Fixture.expectParity(
        \\struct Cursor
        \\    value: int
        \\    last: int
        \\    step: int
        \\    finished: bool
        \\    func next(mut self: Cursor) int | End
        \\        if self.finished -> return End{}
        \\        const value = self.value
        \\        if value == self.last -> self.finished = true
        \\        else self.value = wrapping(value + self.step)
        \\        return value
        \\struct Positive
        \\    source: Cursor
        \\    func next(mut self: Positive) int | End
        \\        loop
        \\            const result = self.source.next()
        \\            match result^
        \\                item and item is int -> if item > 0 -> return item^
        \\                _ -> return End{}
        \\func run() int
        \\    var positive = Positive{source = Cursor{value = 1, last = 2, step = 1, finished = false}}
        \\    var total = 0
        \\    loop
        \\        const result = positive.next()
        \\        match result
        \\            int -> total += result
        \\            _ -> break
        \\    return total * 14
    , 42);
}

test "standard zip and enumerate over range and span cursors inline" {
    const program =
        \\import std.algorithms.{zip, enumerate}
        \\import std.memory.{SpanIterator}
        \\import std.range.{RangeIterator}
        \\func zipped() int
        \\    var left: Array(int, 3) = [10, 11, 12]
        \\    var right: Array(int, 3) = [1, 2, 3]
        \\    var sum = 0
        \\    for pair in zip(SpanIterator(int), SpanIterator(int), int, int, true, true, left.iter(), right.iter()) -> sum += pair.0 + pair.1
        \\    return sum
        \\func numbered() int
        \\    var values: Array(int, 3) = [10, 11, 12]
        \\    var sum = 0
        \\    for pair in enumerate(SpanIterator(int), int, true, values.iter()) -> sum += pair.0 * pair.1
        \\    return sum
        \\func ranged() int
        \\    var values: Array(int, 3) = [10, 11, 12]
        \\    var sum = 0
        \\    for pair in zip(RangeIterator, SpanIterator(int), int, int, false, true, (0..3).iter(), values.iter()) -> sum += pair.0 + pair.1
        \\    for pair in enumerate(RangeIterator, int, false, (5..8).iter()) -> sum += pair.0 * pair.1
        \\    return sum
        \\func run() int -> zipped() + numbered() + ranged() - 88
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    for ([_][]const u8{ "zipped", "numbered", "ranged" }) |name| {
        try testing.expectEqual(@as(usize, 0), countReturningCalls((try optimizedBody(fixture, name)).*.?));
    }
}

test "composed standard adapters inline their cursor state" {
    const program =
        \\import std.algorithms.{map, filter, enumerate, zip, Map, Filter, Enumerate}
        \\import std.memory.{SpanIterator}
        \\import std.range.{RangeIterator}
        \\func triple_impl(value: int) int -> value * 3 + 1
        \\func odd_impl(value: int) bool -> value % 2 == 1
        \\static triple: func(int) int = triple_impl
        \\static odd: func(int) bool = odd_impl
        \\func total(ref values: Array(int, 4)) int
        \\    const mapped = map(SpanIterator(int), int, int, values.iter(), triple)
        \\    const selected = filter(Map(SpanIterator(int), int, int, func(imm int) int), int, false, mapped^, odd)
        \\    const numbered = enumerate(Filter(Map(SpanIterator(int), int, int, func(imm int) int), int, false, func(imm int) bool), int, false, selected^)
        \\    var sum = 0
        \\    for pair in zip(Enumerate(Filter(Map(SpanIterator(int), int, int, func(imm int) int), int, false, func(imm int) bool), int, false), RangeIterator, (int, int), int, false, false, numbered^, (5..8).iter()) -> sum += pair.0.0 + pair.0.1 + pair.1
        \\    return sum
        \\func run() int
        \\    var values: Array(int, 4) = [1, 2, 3, 4]
        \\    return total(values) + 10
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try testing.expectEqual(@as(usize, 0), countReturningCalls((try optimizedBody(fixture, "run")).*.?));
}

test "deep standard adapter chains inline at every depth" {
    const program =
        \\import std.algorithms.{map, filter, enumerate, zip, Map, Filter, Enumerate, Zip}
        \\import std.range.{RangeIterator}
        \\func triple_impl(value: int) int -> value % 100 + 1
        \\func sum2_impl(pair: (int, int)) int -> pair.0 + pair.1
        \\func odd_impl(value: int) bool -> value % 3 <> 0
        \\static triple: func(int) int = triple_impl
        \\static sum2: func((int, int)) int = sum2_impl
        \\static odd: func(int) bool = odd_impl
        \\func total(limit: int) int
        \\    const e0 = enumerate(RangeIterator, int, false, (0..limit).iter())
        \\    const t0 = map(Enumerate(RangeIterator, int, false), (int, int), int, e0^, sum2)
        \\    const s1 = filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, t0^, odd)
        \\    const z2 = zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false, s1^, (2..limit).iter())
        \\    const t2 = map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, z2^, sum2)
        \\    const s3 = map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, t2^, triple)
        \\    const e4 = enumerate(Map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, func(imm int) int), int, false, s3^)
        \\    const t4 = map(Enumerate(Map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, func(imm int) int), int, false), (int, int), int, e4^, sum2)
        \\    const s5 = filter(Map(Enumerate(Map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, func(imm int) int), int, false), (int, int), int, func(imm (int, int)) int), int, false, t4^, odd)
        \\    const z6 = zip(Filter(Map(Enumerate(Map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, func(imm int) int), int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false, s5^, (6..limit).iter())
        \\    const t6 = map(Zip(Filter(Map(Enumerate(Map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, func(imm int) int), int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, z6^, sum2)
        \\    const s7 = map(Map(Zip(Filter(Map(Enumerate(Map(Map(Zip(Filter(Map(Enumerate(RangeIterator, int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, func(imm int) int), int, false), (int, int), int, func(imm (int, int)) int), int, false, func(imm int) bool), RangeIterator, int, int, false, false), (int, int), int, func(imm (int, int)) int), int, int, t6^, triple)
        \\    var sum = 0
        \\    for value in s7^ -> sum += value % 1000
        \\    return sum
        \\func run() int -> total(64) % 251
    ;
    try Fixture.expectParity(program, 25);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try testing.expectEqual(@as(usize, 0), countReturningCalls((try optimizedBody(fixture, "total")).*.?));
}

test "constant incoming predicates bypass only exits independent of join parameters" {
    try Fixture.expectParity(
        \\func pick(flag: bool, number: int) int | none
        \\    if flag -> return number
        \\    return none
        \\func calculate(flag: bool, number: int) int
        \\    const value = pick(flag, number)
        \\    match value
        \\        int ->
        \\            const integer = value
        \\            return integer
        \\        _ -> ()
        \\    return 11
        \\func run() int -> calculate(true, 31) + calculate(false, 90)
    , 42);
}

test "joins retain known variant alternatives and constant aggregate fields" {
    const program =
        \\struct Value
        \\    copy = trivial
        \\    pub number: int
        \\    pub subtract: bool
        \\func choose(flag: bool, number: int) Value | none
        \\    if flag -> return Value{number = number, subtract = false}
        \\    return Value{number = number + 1, subtract = false}
        \\func calculate(flag: bool, number: int) int
        \\    const value = choose(flag, number)
        \\    if not (value is Value) -> return 90
        \\    if value.subtract -> return value.number - 10
        \\    return value.number + 10
        \\func constant(number: int) int
        \\    const value = choose(true, number)
        \\    if not (value is Value) -> return 90
        \\    return value.number
        \\func run() int -> calculate(true, 10) + calculate(false, 11) + constant(0)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .variant_tag, .subi }));
}

test "aggregate reconstruction keeps snapshots separate from later mutations" {
    try Fixture.expectParity(
        \\struct Pair
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\func change(mut value: Pair) -> value.first += 10
        \\func run() int
        \\    var value = Pair{first = 3, second = 7}
        \\    const saved = Pair{first = value.first, second = value.second}
        \\    change(value)
        \\    return saved.first * 10 + value.first - saved.second + 6
    , 42);
}

test "scalar variant joins preserve distinct tags and inactive payloads" {
    const program =
        \\func pick(mode: int, number: int) int | bool | none
        \\    if mode == 0 -> return number
        \\    if mode == 1 -> return true
        \\    return none
        \\func calculate(mode: int, number: int) int
        \\    const value = pick(mode, number)
        \\    match value
        \\        int ->
        \\            const integer = value
        \\            return integer
        \\        _ -> ()
        \\    match value
        \\        bool ->
        \\            const flag = value
        \\            if flag -> return 22
        \\            return 90
        \\        _ -> ()
        \\    return 0
        \\func run() int -> calculate(0, 20) + calculate(1, 99) + calculate(2, 99)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .variant_tag, .variant_extract }));
}

test "scalar variant joins batch independent and dependent consumers" {
    const program =
        \\func pick(mode: int, number: int) int | bool | none
        \\    if mode == 0 -> return number
        \\    if mode == 1 -> return true
        \\    return none
        \\func calculate(mode: int, number: int) int
        \\    const first = pick(mode, number)
        \\    const second = pick(2 - mode, number + 1)
        \\    var result = 0
        \\    match first
        \\        int ->
        \\            const integer = first
        \\            result += integer
        \\        _ -> ()
        \\    match first
        \\        bool ->
        \\            const flag = first
        \\            if flag -> result += 10
        \\        _ -> ()
        \\    match second
        \\        int ->
        \\            const integer = second
        \\            result += integer
        \\        _ -> ()
        \\    match second
        \\        bool ->
        \\            const flag = second
        \\            if flag -> result += 10
        \\        _ -> ()
        \\    const third = pick(mode, result)
        \\    match third
        \\        int ->
        \\            const integer = third
        \\            return integer
        \\        _ -> ()
        \\    return result
        \\func run() int -> calculate(0, 10) + calculate(1, 99) + calculate(2, 11)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .variant_tag, .variant_extract }));
}

test "unused aggregate snapshots preserve variant payloads" {
    const program =
        \\struct Unused
        \\    pub value: int | bool | none
        \\func calculate(mode: int, number: int) int
        \\    var value: int | bool | none = none
        \\    if mode == 0 -> value = number
        \\    if mode == 1 -> value = true
        \\    const unused = Unused{value = value}
        \\    _ = unused
        \\    match value
        \\        int -> return value
        \\        bool ->
        \\            if value -> return 22
        \\            return 90
        \\        none -> return 0
        \\func run() int -> calculate(0, 20) + calculate(1, 99) + calculate(2, 99)
    ;
    try Fixture.expectParity(program, 42);
}

test "value numbering eliminates repeated expressions" {
    const program =
        \\func repeated(a: int, b: int) int -> (a + b) * (a + b)
        \\exit(repeated(3, 4))
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 49);
    const body = (try optimizedBody(fixture, "repeated")).*.?;
    try testing.expectEqual(@as(usize, 1), count(body, &.{.addi}));
}

test "value numbering respects branch dominance and shares aggregates" {
    const program =
        \\struct Pair
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\func separate(flag: bool, a: int, b: int) int
        \\    if flag -> return (a + b) * (a + b)
        \\    return (a + b) * (a + b) * 2
        \\func dominated(flag: bool, a: int, b: int) int
        \\    const sum = a + b
        \\    if flag -> return sum * (a + b)
        \\    return sum * (a + b) * 2
        \\func alternatives(branch: int, a: int, b: int) int
        \\    if branch == 0 -> return (a + b) * (a + b)
        \\    if branch == 1 -> return (a + b) * (a + b) * 2
        \\    if branch == 2 -> return (a + b) * (a + b) * 3
        \\    return (a + b) * (a + b) * 4
        \\func aggregate(flag: bool, a: int, b: int) Pair
        \\    const first = Pair{first = a, second = b}
        \\    const second = Pair{first = a, second = b}
        \\    if flag -> return first
        \\    return second
        \\func run() int
        \\    if separate(true, 2, 3) <> 25 -> return 90
        \\    if separate(false, 2, 3) <> 50 -> return 91
        \\    if dominated(true, 2, 3) <> 25 -> return 92
        \\    if dominated(false, 2, 3) <> 50 -> return 93
        \\    if alternatives(0, 2, 3) <> 25 -> return 94
        \\    if alternatives(1, 2, 3) <> 50 -> return 95
        \\    if alternatives(2, 2, 3) <> 75 -> return 96
        \\    if alternatives(3, 2, 3) <> 100 -> return 97
        \\    return aggregate(false, 30, 12).first + aggregate(true, 30, 12).second
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const separate = (try optimizedBody(fixture, "separate")).*.?;
    try testing.expectEqual(@as(usize, 2), count(separate, &.{.addi}));
    const dominated = (try optimizedBody(fixture, "dominated")).*.?;
    try testing.expectEqual(@as(usize, 1), count(dominated, &.{.addi}));
    const alternatives = (try optimizedBody(fixture, "alternatives")).*.?;
    try testing.expectEqual(@as(usize, 4), count(alternatives, &.{.addi}));
    const aggregate = (try optimizedBody(fixture, "aggregate")).*.?;
    try testing.expectEqual(@as(usize, 1), count(aggregate, &.{.aggregate}));
}

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
        \\func scale(a: int, b: int) int -> wrapping(a * 0 + b * -1 + b / -1 + -(-a))
        \\func run() int
        \\    const minimum = -2147483647 - 1
        \\    if scale(minimum, minimum) <> wrapping(0 - minimum - minimum + minimum) -> return 90
        \\    if scale(5, -1) <> 7 -> return 91
        \\    if wrapping(minimum * -1) <> minimum -> return 92
        \\    if wrapping(minimum / -1 * 1 + 0) <> minimum -> return 93
        \\    if 1 > 2 -> return 94
        \\    return 42
    , 42);
}

test "inlined element reads snapshot the value before later writes to the same slot" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values: List(int) = [10, 11, 21]
        \\    const removed = values.remove(1)
        \\    if not (removed is int) -> return none
        \\    return values[0] + removed + values[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 99
    , 42);
}

test "cursor address copies preserve pointee snapshots mutation and incremental edits" {
    const program =
        \\func calculate(mut view: Span(int), index: int) int
        \\    const saved = view[index]
        \\    view[index] += 1
        \\    return saved * 2 + view[index]
        \\func run() int
        \\    var values: Array(int, 2) = [10, 20]
        \\    var view = values.span()
        \\    return calculate(view, 0) + 11
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program ++ "\nexit(run())");
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    for (body.instructions) |instruction| {
        if (instruction != .value_copy or instruction.value_copy.destination != null) continue;
        const operand = @backingInt(instruction.value_copy.source);
        if (operand < body.block_arguments.len) continue;
        const producer = body.instructions[operand - body.block_arguments.len];
        try testing.expect(producer != .cursor_element);
        try testing.expect(producer != .cursor_offset);
        try testing.expect(producer != .storage_cursor);
    }
    try fixture.expectExit(0, 42);
    const edited = try std.mem.replaceOwned(u8, testing.allocator, program ++ "\nexit(run())", "view[index] += 1", "view[index] += 2");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(0, 43);
}

test "cursor snapshots retain their backing across descriptor replacement" {
    try Fixture.expectParity(
        \\func run() int
        \\    var first: Array(int, 2) = [10, 11]
        \\    var second: Array(int, 2) = [20, 21]
        \\    var view = first.span()
        \\    const saved = view
        \\    var total = 0
        \\    for index in 0..2
        \\        total += saved[index]
        \\        view = second.span()
        \\    return total + view[0] + 1
    , 42);
}

test "invariant boolean loop versions preserve calls empty loops and both polarities" {
    const program =
        \\func step(mut total: int, amount: int) -> total += amount
        \\func calculate(enabled: bool, limit: int) int
        \\    var total = 0
        \\    for index in 0..limit
        \\        if enabled -> step(total, index)
        \\        else step(total, 2)
        \\    return total
        \\func opposite(enabled: bool, limit: int) int
        \\    var total = 0
        \\    for index in 0..limit
        \\        if not enabled -> total += index
        \\        else total += 2
        \\    return total
        \\func run() int
        \\    return calculate(true, 5) + calculate(false, 5) + opposite(false, 5) + opposite(true, 5) + calculate(false, 0) + opposite(true, -1) + 2
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
}

test "dynamic relational guards preserve later overflow and skipped effects" {
    const program =
        \\func scan(first: int, limit: int) int
        \\    if first < 0 or first > limit or limit > 8 -> return 0
        \\    var values: Array(int, 8) = [1, 2, 3, 4, 5, 6, 7, 8]
        \\    var total = 0
        \\    for index in first..limit
        \\        if index < first -> panic "impossible lower bound"
        \\        if index >= limit -> panic "impossible upper bound"
        \\        total += values[index]
        \\    return total
        \\func run() int -> scan(0, 8) + scan(3, 3) + scan(-1, 4) + 6
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(
        \\func scan(first: int, limit: int) int
        \\    var index = first
        \\    var total = 0
        \\    loop
        \\        total += 1
        \\        index += 1
        \\        if index >= limit -> break
        \\    return total
        \\exit(scan(2147483647, 2147483647))
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 134);
}

test "aggregate joins split independent fields without changing snapshots" {
    const program =
        \\struct Pair
        \\    copy = trivial
        \\    pub number: int
        \\    pub enabled: bool
        \\func choose(flag: bool, number: int) Pair
        \\    if flag -> return Pair{number = number, enabled = true}
        \\    return Pair{number = number + 1, enabled = false}
        \\func calculate(flag: bool, number: int) int
        \\    const selected = choose(flag, number)
        \\    var total = selected.number
        \\    if selected.enabled -> total += 1
        \\    return total
        \\func run() int -> calculate(true, 20) + calculate(false, 20)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .aggregate, .field_access }));
}

test "disjoint private field writes preserve reads while whole writes invalidate them" {
    const program =
        \\struct Pair
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\func inspect(ref pair: Pair) int -> pair.first
        \\func replace(mut pair: Pair) -> pair = Pair{first = pair.first + 1, second = 0}
        \\func stable(limit: int) int
        \\    var pair = Pair{first = 10, second = 1}
        \\    const observed = inspect(pair)
        \\    var total = 0
        \\    for index in 0..limit
        \\        total += pair.first
        \\        pair.second += 1
        \\    return total + pair.second + observed - 2
        \\func changing() int
        \\    var pair = Pair{first = 10, second = 1}
        \\    var total = 0
        \\    for index in 0..2
        \\        total += pair.first
        \\        replace(pair)
        \\    return total + pair.first
        \\func run() int -> stable(3) + changing() - 33
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program ++ "\nexit(run())");
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
}

test "integer algebra shares width-correct identities across overflow modes" {
    for ([_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize" }) |kind| {
        for ([_][]const u8{ "", "wrapping", "saturating" }) |mode| {
            const program = try test_sources.renderTemplate(testing.allocator,
                \\func identity(value: $T) $T -> $mode(((value & ~$T(0)) | 0) * 1 + 0)
                \\func repeated(value: $T) $T -> (value & value) | (value | value)
                \\func zero(value: $T) $T -> $mode((value - value) | (value ^ value) | (value & 0) | (value % 1))
                \\func ones(value: $T) $T -> value | ~$T(0)
                \\func run() int
                \\    if identity(42) <> 42 or repeated(42) <> 42 -> return 90
                \\    if zero(~$T(0)) <> 0 or ones(0) <> ~$T(0) -> return 91
                \\    if identity(~$T(0)) <> ~$T(0) or repeated(~$T(0)) <> ~$T(0) -> return 92
                \\    return 42
            , .{ .T = kind, .mode = mode });
            defer testing.allocator.free(program);
            try Fixture.expectParity(program, 42);
            const fixture = try Fixture.init(program);
            defer fixture.deinit();
            for ([_][]const u8{ "identity", "repeated", "zero", "ones" }) |name| {
                errdefer std.debug.print("integer algebra: {s} {s} {s}\n", .{ kind, mode, name });
                const body = (try optimizedBody(fixture, name)).*.?;
                try testing.expectEqual(@as(usize, 0), count(body, &.{ .numeric_binary, .addi, .subi, .muli, .divsi }));
            }
        }
    }
}

test "integer identity copies preserve snapshots and distinct writable storage" {
    try Fixture.expectParity(
        \\func overwrite(ref value: i16, replacement: i16)
        \\    value = replacement
        \\func snapshot(ref original: i16) int
        \\    var saved = original + 0
        \\    overwrite(original, 7)
        \\    if saved <> 42 -> return 90
        \\    overwrite(saved, 19)
        \\    if original <> 7 or saved <> 19 -> return 91
        \\    return 42
        \\func run() int
        \\    var value: i16 = 42
        \\    return snapshot(value)
    , 42);
}

test "signed negative-one rewrites preserve checked wrapping and saturated results" {
    for ([_][]const u8{ "i8", "i16", "i32", "i64", "isize" }) |kind| {
        const program = try test_sources.renderTemplate(testing.allocator,
            \\func multiply(value: $T) $T -> value * -1
            \\func divide(value: $T) $T -> value / -1
            \\func wrapped(value: $T) $T -> wrapping(value / -1)
            \\func saturated(value: $T) $T -> saturating(value * -1)
            \\func run() int
            \\    const minimum = $T(1) << ($T($width) - 1)
            \\    if multiply(7) <> -7 or divide(-7) <> 7 -> return 90
            \\    if wrapped(minimum) <> minimum -> return 91
            \\    if saturated(minimum) <> (minimum ^ ~$T(0)) -> return 92
            \\    return 42
        , .{ .T = kind, .width = if (std.mem.eql(u8, kind, "i8")) "8" else if (std.mem.eql(u8, kind, "i16")) "16" else if (std.mem.eql(u8, kind, "i32")) "32" else "64" });
        defer testing.allocator.free(program);
        try Fixture.expectParity(program, 42);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        for ([_][]const u8{ "multiply", "divide", "wrapped", "saturated" }) |name| {
            const body = (try optimizedBody(fixture, name)).*.?;
            try testing.expectEqual(@as(usize, 0), count(body, &.{ .muli, .divsi }));
            try testing.expectEqual(@as(usize, 1), count(body, &.{.negi}));
        }
    }
}

test "algebraic results retain traps and recompute after operator edits" {
    for ([_][]const u8{
        "func fail(value: i8)\n    value * -1\nfail(-128)",
        "func fail(value: i64)\n    value / -1\nfail(-9223372036854775808)",
        "func fail(value: u8)\n    (value + 1) & 0\nfail(255)",
        "func fail(value: u64)\n    (value / 0) | ~u64(0)\nfail(42)",
        "func fail(value: i16)\n    (value << 16) % 1\nfail(42)",
    }) |program| {
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const result = try fixture.runIo("");
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
        try testing.expect(std.mem.startsWith(u8, result.stderr, "panic: invalid numeric operation\n"));
        try testing.expect(std.mem.indexOf(u8, result.stderr, "at fail ") != null);
    }

    const program = "func changed(value: u64) u64 -> value ^ value\nexit(wrap(i32, changed(42)))";
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 0);
    const original = try optimizedBody(fixture, "changed");
    try testing.expectEqual(@as(usize, 0), count(original.*.?, &.{.numeric_binary}));
    try fixture.db.setInput(queries.SourceText, 0, "func changed(value: u64) u64 -> value | value\nexit(wrap(i32, changed(42)))");
    try fixture.expectExit(0, 42);
    try testing.expect(original != try optimizedBody(fixture, "changed"));
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
    \\func change(ref value: int, times: int) unit
    \\    if times == 0 -> value += 1 else change(value, times - 1)
    \\func positive(value: int) int | none
    \\    if value < 0 -> return none
    \\    return value
    \\func sum(limit: int) int
    \\    var total = 0
    \\    var index = 0
    \\    var odd = false
    \\    loop
    \\        if index == limit -> break
    \\        index += 1
    \\        if odd -> odd = false else odd = true
    \\        if odd -> continue
    \\        total += index
    \\    return total
    \\func merge(flag: bool, var start: int) int
    \\    var value = start
    \\    if flag
    \\        value = value * 2
    \\        start = 1
    \\    else
    \\        value = value + 3
    \\    return value + start
    \\func borrowed(start: int) int
    \\    var value = start
    \\    change(value, 1)
    \\    return value
    \\func reopened(start: int) int
    \\    var value = start
    \\    if 1 + 1 == 3 -> change(value, 0)
    \\    return value * 2
    \\func checked(start: int) int | none
    \\    var value = start
    \\    var attempts = 0
    \\    loop
    \\        attempts += 1
    \\        match positive(value)
    \\            accepted and accepted is int -> return accepted + attempts
    \\            _ -> ()
    \\        value += 5
    \\func run() int
    \\    if sum(10) <> 30 -> return 90
    \\    if merge(true, 4) <> 9 -> return 91
    \\    if merge(false, 4) <> 11 -> return 92
    \\    if borrowed(6) <> 7 -> return 93
    \\    if reopened(21) <> 42 -> return 95
    \\    match checked(-12)
    \\        value and value is int -> if value == 7 -> return 42
    \\        _ -> ()
    \\    return 94
;

test "promotion turns non-escaping scalar locals into SSA values" {
    try Fixture.expectParity(promotion_source, 42);
    const program = try testing.allocator.print("{s}\nexit(run())", .{promotion_source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "sum", "merge", "checked", "reopened" }) |name| {
        const body = (try optimizedBody(fixture, name)).*.?;
        errdefer std.debug.print("promotion failed for {s}\n", .{name});
        try testing.expectEqual(@as(usize, 0), countLocalStorage(body, .int) + countLocalStorage(body, .bool));
        try testing.expectEqual(@as(usize, 0), count(body, &.{.value_copy}));
    }
    const borrowed = (try optimizedBody(fixture, "borrowed")).*.?;
    try testing.expectEqual(@as(usize, 1), countLocalStorage(borrowed, .int));
}

test "promotion batches loop carried slots across bitset words" {
    var program: std.Io.Writer.Allocating = .init(testing.allocator);
    defer program.deinit();
    try program.writer.writeAll("func many(limit: int) int\n");
    for (0..65) |index| try program.writer.print("    var value{d} = {d}\n", .{ index, index });
    try program.writer.writeAll("    var index = 0\n    loop\n        if index == limit -> break\n");
    for (0..65) |index| try program.writer.print("        value{d} += 1\n", .{index});
    try program.writer.writeAll("        index += 1\n    return ");
    for (0..65) |index| try program.writer.print("{s}value{d}", .{ if (index == 0) "" else " + ", index });
    try program.writer.writeAll("\nfunc run() int -> many(2) - 2168\n");
    try Fixture.expectParity(program.written(), 42);
    const fixture = try Fixture.init(program.written());
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "many")).*.?;
    try testing.expectEqual(@as(usize, 0), countLocalStorage(body, .int));
    try testing.expectEqual(@as(usize, 0), count(body, &.{.value_copy}));
}

fn countChecked(body: structures.FunctionBodyAnalysis) usize {
    var total: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .numeric_binary and instruction.numeric_binary.overflow == .checked) total += 1;
    }
    return total;
}

fn countCalls(body: structures.FunctionBodyAnalysis) usize {
    return count(body, &.{.call});
}

fn countPredicates(body: structures.FunctionBodyAnalysis) usize {
    var total: usize = 0;
    for (body.blocks) |block| total += @intFromBool(block.terminator == .predicate_branch);
    return total;
}

// Keep the bulk-loop shape explicit rather than depending on List.filled's implementation.
const pipeline_source =
    \\import std.memory.{Allocation}
    \\struct Pair
    \\    copy = trivial
    \\    pub first: int
    \\    pub second: int
    \\func swap(pair: Pair) Pair -> Pair{first = pair.second, second = pair.first}
    \\func total(pair: Pair) int -> pair.first + pair.second
    \\func countdown(n: int) int
    \\    if n == 0 -> return 0
    \\    return countdown(n - 1) + 1
    \\func half(n: int) int | none
    \\    if n < 0 -> return none
    \\    return n / 2
    \\func larger(a: int, b: int) int
    \\    if a > b -> return a
    \\    return b
    \\func scan(n: int) int | none
    \\    var values = Allocation(int).allocate(n)
    \\    if not (values is Allocation(int)) -> return none
    \\    var index = 0
    \\    loop
    \\        if index == n -> break
    \\        values.unsafe_initialize(index, 3)
    \\        index += 1
    \\    index = 0
    \\    var sum = 0
    \\    loop
    \\        if index >= n -> break
    \\        sum += values.unsafe_take(index)
    \\        index += 1
    \\    values.deallocate()
    \\    return sum
    \\func spin(n: int) int
    \\    var index = n
    \\    loop
    \\        if index == 0 -> break
    \\        index -= 1
    \\    return 5
    \\func run() int
    \\    const pair = swap(Pair{first = 30, second = 12})
    \\    var sum = 0
    \\    var index = 0
    \\    loop
    \\        if index == 10 -> break
    \\        sum += larger(index, 3)
    \\        index += 1
    \\    match scan(4)
    \\        scanned and scanned is int ->
    \\            match half(total(pair))
    \\                halved and halved is int -> return halved + countdown(3) + sum + scanned - 45 + spin(9) - 5
    \\                _ -> ()
    \\        _ -> ()
    \\    return 90
;

test "rotated List filled loops become fills and preserve initialized lengths" {
    for ([_]struct { element_type: []const u8, value: []const u8 }{
        .{ .element_type = "int", .value = "7" },
        .{ .element_type = "bool", .value = "true" },
        .{ .element_type = "byte", .value = "255" },
    }) |element| {
        const program = try test_sources.renderTemplate(testing.allocator,
            \\func calculate(length: int) int
            \\    const value: $element_type = $value
            \\    var values = List($element_type).filled(value, length)
            \\    if not (values is List($element_type)) -> return 0
            \\    if length == 0 -> return values.len()
            \\    if values[0] <> value or values[length - 1] <> value -> return 90
            \\    return values.len() + 14
            \\func run() int -> calculate(-1) + calculate(0) + calculate(1) + calculate(13)
        , element);
        defer testing.allocator.free(program);
        try Fixture.expectParity(program, 42);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const body = (try optimizedBody(fixture, "calculate")).*.?;
        try testing.expectEqual(@as(usize, 1), count(body, &.{.fill}));
    }
}

test "terminal fills preserve nonzero starts and independent carried counts" {
    const program =
        \\import std.memory.{Allocation}
        \\func calculate(first: int, last: int, initial: int) int
        \\    if first < 0 or last > 8 or first > last -> return 0
        \\    var values = Allocation(int).allocate(last + 1)
        \\    if not (values is Allocation(int)) -> return 90
        \\    var initialized = initial
        \\    var index = first
        \\    var finished = false
        \\    loop
        \\        if finished -> break
        \\        values.unsafe_initialize(index, 3)
        \\        initialized = wrapping(initialized + 1)
        \\        if index == last -> finished = true else index = wrapping(index + 1)
        \\    var result = wrapping(initialized + index)
        \\    for position in first..=last
        \\        result = wrapping(result + values.unsafe_take(position))
        \\    values.deallocate()
        \\    return result
        \\func run() int
        \\    if calculate(2, 4, 2147483646) <> -2147483634 -> return 90
        \\    return calculate(2, 4, 5) + calculate(1, 1, 0) + calculate(0, 2, 2)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 1), count(body, &.{.fill}));
}

test "terminal fill overflow guard retains the signed maximum fallback" {
    const program =
        \\import std.memory.{Allocation}
        \\func fillMaximum(bound: int) int
        \\    var values = Allocation(int).allocate(4)
        \\    if not (values is Allocation(int)) -> return 90
        \\    var initialized = 0
        \\    var index = 0
        \\    var finished = false
        \\    loop
        \\        if finished -> break
        \\        values.unsafe_initialize(index, 7)
        \\        initialized = wrapping(initialized + 1)
        \\        if index == bound -> finished = true else index = wrapping(index + 1)
        \\    values.deallocate()
        \\    return initialized
        \\func run() int -> fillMaximum(3) + 38
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const guarded_body = (try optimizedBody(fixture, "fillMaximum")).*.?;
    try testing.expectEqual(@as(usize, 1), count(guarded_body, &.{.fill}));
    try testing.expect(hasConstant(guarded_body, std.math.maxInt(i32)));

    // 2^31 elements do not fit a signed fill count. Compile this boundary
    // without executing its unsafe writes beyond the small allocation.
    const maximum = try std.mem.replaceOwned(u8, testing.allocator, program, "index == bound", "index == 2147483647");
    defer testing.allocator.free(maximum);
    try fixture.db.setInput(queries.SourceText, 0, maximum);
    const body = (try optimizedBody(fixture, "fillMaximum")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{.fill}));
    try testing.expectEqual(@as(usize, 1), count(body, &.{.allocation_element}));

    // Starting at one fits exactly INT_MAX elements, so this adjacent case
    // must become a fill even though the terminal index is still INT_MAX.
    const edited = try std.mem.replaceOwned(u8, testing.allocator, maximum, "var index = 0", "var index = 1");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    const fitting = (try optimizedBody(fixture, "fillMaximum")).*.?;
    try testing.expectEqual(@as(usize, 1), count(fitting, &.{.fill}));
    try fixture.db.setInput(queries.SourceText, 0, maximum);
    const restored = (try optimizedBody(fixture, "fillMaximum")).*.?;
    try testing.expectEqual(@as(usize, 0), count(restored, &.{.fill}));
}

test "terminal fills retain carried increment panics" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation}
        \\func calculate(initial: int) int
        \\    var values = Allocation(int).allocate(2)
        \\    if not (values is Allocation(int)) -> return 90
        \\    var initialized = initial
        \\    for index in 0..2
        \\        values.unsafe_initialize(index, 7)
        \\        initialized += 1
        \\    values.deallocate()
        \\    return initialized
        \\exit(calculate(2147483647))
    );
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{.fill}));
    try testing.expect(countChecked(body) != 0);
    try fixture.expectExit(0, 134);
}

test "bulk loop fallbacks converge across simplification within bounded memory" {
    const program =
        \\func calculate(count: int) int | none
        \\    var values = List(int).filled(7, count)
        \\    if not (values is List(int)) -> return none
        \\    if not (values.reserve(count + 2) is unit) -> return none
        \\    if count == 0 -> return 0
        \\    return values[0] + values[count - 1] + values.capacity()
        \\func run() int
        \\    if not (calculate(-1) is none) -> return 90
        \\    const empty = calculate(0)
        \\    if not (empty is int) -> return 91
        \\    if empty <> 0 -> return 92
        \\    match calculate(2)
        \\        result and result is int -> return result + 24
        \\        _ -> return 93
        \\exit(run())
    ;
    // A regression must report OutOfMemory without exhausting the machine.
    const memory = try testing.allocator.alloc(u8, 64 * 1024 * 1024);
    defer testing.allocator.free(memory);
    var bounded: std.heap.FixedBufferAllocator = .init(memory);
    const allocator = bounded.allocator();
    const fixture: Fixture = .{ .db = try test_sources.query.Database.init(allocator, .{ .worker_count = 0 }) };
    defer fixture.deinit();
    try test_sources.modules.registerSources(fixture.db, allocator, program, &.{}, &.{});
    try fixture.expectExit(0, 42);
}

test "inlining exposes callee bodies to scalar replacement selects and loop idioms" {
    try Fixture.expectParity(pipeline_source, 42);
    const program = try testing.allocator.print("{s}\nexit(run())", .{pipeline_source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 256);
    try fixture.expectExit(0, 42);

    const run = (try optimizedBody(fixture, "run")).*.?;
    try testing.expectEqual(@as(usize, 1), try countCallsTo(run, "countdown", fixture));
    for ([_][]const u8{ "swap", "total", "half", "larger", "scan", "spin" }) |name| {
        errdefer std.debug.print("Expected inlined callee: {s}\n", .{name});
        try testing.expectEqual(@as(usize, 0), try countCallsTo(run, name, fixture));
    }
    try testing.expect(run.inline_frames.len != 0);
    try testing.expect(count(run, &.{.select}) != 0);
    try testing.expectEqual(@as(usize, 1), count(run, &.{.fill}));
    try testing.expectEqual(@as(usize, 0), countLocalStorage(run, .int) + countLocalStorage(run, .bool));
    const pair_item = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveStatic("Pair").?;
    const pair_value = (try fixture.db.get(queries.ResolveStatic, pair_item)).*.?;
    const pair_type = (try fixture.db.lookupInterned(queries.CompileTimeValues, pair_value)).type;
    try testing.expectEqual(@as(usize, 0), countLocalStorage(run, pair_type));
    const types: queries.TypeFacts(*test_sources.query.Database) = .{ .ctx = fixture.db };
    for (run.instructions) |instruction| if (instruction == .local_storage) {
        try testing.expect((try types.variantMembers(instruction.local_storage)) != null);
    };

    const scan = (try optimizedBody(fixture, "scan")).*.?;
    try testing.expectEqual(@as(usize, 1), count(scan, &.{.fill}));
    for (scan.blocks) |block| if (block.terminator == .predicate_branch) {
        const predicate = block.terminator.predicate_branch;
        if (predicate.operation == .lti) {
            const bound = @backingInt(predicate.operands.rhs);
            try testing.expect(bound >= scan.block_arguments.len);
            try testing.expectEqualDeep(structures.FunctionInstruction{ .const_int = 0 }, scan.instructions[bound - scan.block_arguments.len]);
        }
    };

    const spin = (try optimizedBody(fixture, "spin")).*.?;
    // An arbitrary negative start eventually overflows its checked decrement.
    try testing.expectEqual(@as(usize, 1), countPredicates(spin));
}

/// Calls that can return; panic paths end in never-returning calls.
fn countReturningCalls(body: structures.FunctionBodyAnalysis) usize {
    var total: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .call and instruction.call.return_type != .never) total += 1;
    }
    return total;
}

fn countCallsTo(body: structures.FunctionBodyAnalysis, name: []const u8, fixture: Fixture) !usize {
    const item = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction(name).?;
    var total: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .call and instruction.call.target == .direct and instruction.call.target.direct.item == item) total += 1;
    }
    return total;
}

test "scalar replacement preserves nested storage and cross-local snapshots" {
    try Fixture.expectParity(
        \\pub struct Pair
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\struct Nested
        \\    copy = trivial
        \\    pub pair: Pair
        \\    pub extra: int
        \\func run() int
        \\    var left = Nested{pair = Pair{first = 10, second = 20}, extra = 3}
        \\    var right = left
        \\    left.pair.first = 30
        \\    right.extra = 2
        \\    var saved = right
        \\    right = left
        \\    var copied = left
        \\    copied = right
        \\    right.extra = 100
        \\    saved.pair.second = 28
        \\    return saved.pair.first + saved.pair.second + saved.extra + copied.extra - 1
    , 42);
}

test "scalar replacement splits deeply nested structs through whole copies and field updates" {
    const program =
        \\pub struct Leaf
        \\    copy = trivial
        \\    pub a: int
        \\    pub b: int
        \\pub struct Mid
        \\    copy = trivial
        \\    pub leaf: Leaf
        \\    pub weight: int
        \\struct Top
        \\    copy = trivial
        \\    pub mid: Mid
        \\    pub tail: Leaf
        \\    pub id: int
        \\func calculate(seed: int) int
        \\    var top = Top{mid = Mid{leaf = Leaf{a = seed, b = 2}, weight = 3}, tail = Leaf{a = 4, b = 5}, id = 6}
        \\    var saved = top
        \\    top.mid.leaf.a = 10
        \\    top.tail = top.mid.leaf
        \\    var moved = top.mid
        \\    moved.leaf.b = 7
        \\    top.mid = moved
        \\    saved.tail.a += top.mid.leaf.b
        \\    return saved.mid.leaf.a + saved.tail.a + top.tail.b + top.mid.leaf.a + top.mid.weight + saved.id + top.id + moved.weight
        \\func run() int -> calculate(1)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .aggregate, .field_access, .local_storage, .storage_projection }));
}

test "scalar replacement keeps a nested slot whose address escapes while splitting its siblings" {
    try Fixture.expectParity(
        \\pub struct Leaf
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\struct Wrap
        \\    copy = trivial
        \\    pub leaf: Leaf
        \\    pub other: Leaf
        \\    pub count: int
        \\func bump(mut leaf: Leaf) -> leaf.first += 1
        \\func calculate(limit: int) int
        \\    var wrap = Wrap{leaf = Leaf{first = 1, second = 2}, other = Leaf{first = 5, second = 6}, count = 0}
        \\    var snapshot = wrap
        \\    var index = 0
        \\    loop
        \\        if index == limit -> break
        \\        bump(wrap.leaf)
        \\        wrap.leaf.second += wrap.leaf.first
        \\        wrap.other.first += wrap.leaf.second
        \\        wrap.count += 1
        \\        index += 1
        \\    snapshot.count = wrap.count
        \\    snapshot.other = wrap.other
        \\    return wrap.leaf.first * 10 + wrap.leaf.second + snapshot.leaf.first + snapshot.leaf.second + snapshot.count + snapshot.other.first - wrap.other.first
        \\func run() int -> calculate(3) + calculate(0) - 30
    , 42);
}

test "inlined callers recompute with their callees and keep recursive callees out of line" {
    const program = try testing.allocator.print("{s}\nexit(run())", .{pipeline_source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = try optimizedBody(fixture, "run");
    try testing.expectEqual(@as(usize, 1), try countCallsTo(run.*.?, "countdown", fixture));

    const recursive = try std.mem.replaceOwned(u8, testing.allocator, program, "return countdown(n - 1) + 1", "return countdown(n - 1) + 2");
    defer testing.allocator.free(recursive);
    try fixture.db.setInput(queries.SourceText, 0, recursive);
    try fixture.expectExit(0, 45);
    try testing.expectEqual(run, try optimizedBody(fixture, "run"));

    const edited = try std.mem.replaceOwned(u8, testing.allocator, recursive, "if a > b -> return a", "if a >= b -> return a");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(0, 45);
    try testing.expect(run != try optimizedBody(fixture, "run"));
}

test "parallel callee optimization keeps fresh leaf edits to one typed body" {
    const entry =
        \\import stable
        \\import leaf
        \\func left() int -> stable.value()
        \\func right() int -> leaf.value()
        \\exit(left() + right())
    ;
    for ([_]usize{ 0, 4 }) |workers| {
        var collector: test_sources.profiling.Collector = .{ .io = testing.io };
        const db = try test_sources.query.Database.init(testing.allocator, .{ .worker_count = workers, .profile = &collector });
        const fixture: Fixture = .{ .db = db };
        defer fixture.deinit();
        var registry: test_sources.modules.SourceRegistry = .{};
        defer registry.deinit(testing.allocator);
        try registry.update(db, testing.allocator, entry, &.{
            .{ .path = "stable.chi", .module_path = "stable", .source = "pub func value() int -> 40\n" },
            .{ .path = "leaf.chi", .module_path = "leaf", .source = "pub func value() int -> 2\n" },
        }, &.{});
        try fixture.expectExit(0, 42);
        const scope = (try db.get(queries.BuildModuleScope, registry.fileId("stable.chi").?)).*.?;
        const stable: structures.InstanceId = .{ .item = scope.resolveFunction("value").? };
        const stable_body = try db.get(queries.OptimizeFunctionInstance, stable);
        for (3..6) |value| {
            const replacement = try testing.allocator.print("pub func value() int -> {d}\n", .{value});
            defer testing.allocator.free(replacement);
            const before = collector.snapshot();
            try db.setInput(queries.SourceText, registry.fileId("leaf.chi").?, replacement);
            try fixture.expectExit(0, @intCast(40 + value));
            const work = collector.snapshot().since(before);
            try testing.expectEqual(@as(usize, 1), work.get(.body_build).runs);
            try testing.expectEqual(@as(usize, 1), work.get(.body_typing).runs);
            try testing.expectEqual(stable_body, try db.get(queries.OptimizeFunctionInstance, stable));
        }
        // Removing a call must also remove its dependency and diagnostics.
        try db.setInput(queries.SourceText, 0, "import stable\nimport leaf\nexit(stable.value())\n");
        try fixture.expectExit(0, 40);
        const without_leaf = try db.get(queries.BuildExecutable, 0);
        try db.setInput(queries.SourceText, registry.fileId("leaf.chi").?, "pub func value() int -> true\n");
        const before = collector.snapshot();
        try fixture.expectExit(0, 40);
        try testing.expectEqual(without_leaf, try db.get(queries.BuildExecutable, 0));
        try testing.expectEqual(@as(usize, 0), collector.snapshot().since(before).get(.body_typing).runs);
    }
}

test "static callable arguments specialize direct member and overload calls and recompute" {
    const program =
        \\func bump(value: int) int -> value + 2
        \\func other(value: int) int -> value + 3
        \\func apply(static callback: func(int) int, value: int) int -> callback(value)
        \\func dynamic(callback: func(int) int, value: int, marker: unit) int -> callback(value)
        \\overload invoke(apply, dynamic)
        \\struct Operation(callback: func(int) int)
        \\    pub func call(imm self: Operation(callback), value: int) int -> callback(value)
        \\struct Dispatcher
        \\    pub func call(imm self: Dispatcher, static callback: func(int) int, value: int) int -> callback(value)
        \\func direct(value: int) int -> apply(bump, value)
        \\func member(value: int) int -> Dispatcher{}.call(bump, value)
        \\func overloaded(value: int) int -> invoke(bump, value)
        \\func wrapped(value: int) int -> Operation(bump){}.call(value)
        \\func run() int -> direct(40) + member(40) + overloaded(40) + wrapped(40) - 126
        \\exit(run())
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "direct", "member", "overloaded", "wrapped" }) |name|
        try testing.expectEqual(@as(usize, 0), countCalls((try optimizedBody(fixture, name)).*.?));
    const dynamic = (try optimizedBody(fixture, "dynamic")).*.?;
    for (dynamic.instructions) |instruction| {
        if (instruction == .call) try testing.expect(instruction.call.target == .indirect);
    }
    const edited = try std.mem.replaceOwned(u8, testing.allocator, program, "apply(bump, value)", "apply(other, value)");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(0, 43);
    const changed_body = try std.mem.replaceOwned(u8, testing.allocator, edited, "value + 3", "value + 4");
    defer testing.allocator.free(changed_body);
    try fixture.db.setInput(queries.SourceText, 0, changed_body);
    try fixture.expectExit(0, 44);
}

test "known indirect calls promote after forwarding and preserve incremental callees" {
    const program =
        \\func bump(value: int) int -> value + 2
        \\func forward(callback: func(int) int) func(int) int -> callback
        \\func unknown(callback: func(int) int, value: int) int -> callback(value)
        \\func recursive(value: int) int
        \\    if value <= 0 -> return 0
        \\    const callback = recursive
        \\    return callback(value - 1) + 1
        \\func run() int -> forward(bump)(40)
        \\exit(run())
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try optimizedBody(fixture, "run")).*.?;
    try testing.expectEqual(@as(usize, 0), countCalls(run));
    const unknown = (try optimizedBody(fixture, "unknown")).*.?;
    try testing.expectEqual(@as(usize, 1), countCalls(unknown));
    for (unknown.instructions) |instruction| {
        if (instruction == .call) try testing.expect(instruction.call.target == .indirect);
    }
    const recursive = (try optimizedBody(fixture, "recursive")).*.?;
    try testing.expectEqual(@as(usize, 1), try countCallsTo(recursive, "recursive", fixture));

    const edited = try std.mem.replaceOwned(u8, testing.allocator, program, "value + 2", "value + 3");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectExit(0, 43);
    try testing.expectEqual(@as(usize, 0), countCalls((try optimizedBody(fixture, "run")).*.?));
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 43);
    try testing.expectEqual(@as(usize, 2), countCalls((try optimizedBody(fixture, "run")).*.?));
}

test "known indirect calls recover immutable fields and common joins but retain different targets" {
    const program =
        \\struct Callbacks
        \\    callback: func(int) int
        \\func bump(value: int) int -> value + 2
        \\func other(value: int) int -> value + 5
        \\func forward(callback: func(int) int) func(int) int -> callback
        \\func field(value: int) int
        \\    const callbacks = Callbacks{callback = forward(bump)}
        \\    return callbacks.callback(value)
        \\func common(flag: bool, value: int) int
        \\    var callback = forward(bump)
        \\    if flag -> callback = forward(bump)
        \\    return callback(value)
        \\func different(flag: bool, value: int) int
        \\    var callback = forward(bump)
        \\    if flag -> callback = forward(other)
        \\    return callback(value)
        \\func run() int -> field(39) + common(false, 39) + common(true, 39) + different(false, 39) + different(true, 39) - 166
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    for ([_][]const u8{ "field", "common" }) |name| {
        const body = (try optimizedBody(fixture, name)).*.?;
        try testing.expectEqual(@as(usize, 0), countCalls(body));
    }
    const different = (try optimizedBody(fixture, "different")).*.?;
    try testing.expectEqual(@as(usize, 1), countCalls(different));
    for (different.instructions) |instruction| {
        if (instruction == .call) try testing.expect(instruction.call.target == .indirect);
    }
}

test "known indirect calls through forwarding keep mutual recursion out of line" {
    const program =
        \\func forward(callback: func(int) int) func(int) int -> callback
        \\func left(value: int) int
        \\    if value <= 0 -> return 0
        \\    return forward(right)(value - 1) + 1
        \\func right(value: int) int
        \\    if value <= 0 -> return 0
        \\    return forward(left)(value - 1) + 1
        \\func run() int -> left(4) + 38
        \\exit(run())
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try testing.expect(countCalls((try optimizedBody(fixture, "left")).*.?) != 0);
    try testing.expect(countCalls((try optimizedBody(fixture, "right")).*.?) != 0);
}

test "a zero inline limit keeps calls out of line" {
    const program = try testing.allocator.print("{s}\nexit(run())", .{pipeline_source});
    defer testing.allocator.free(program);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
    const run = (try optimizedBody(fixture, "run")).*.?;
    try testing.expectEqual(@as(usize, 0), run.inline_frames.len);
    try testing.expect(countCalls(run) >= 6);
}

test "inlining reuses pruned growth capacity without multiplying the caller budget" {
    const batch_calls = block: {
        const line = "    sum += choose(true, value)\n";
        var text: [line.len * 48]u8 = undefined;
        for (0..48) |index| @memcpy(text[index * line.len ..][0..line.len], line);
        break :block text;
    };
    const growing_calls = block: {
        const line = "    sum = choose(flag, sum)\n";
        var text: [line.len * 48]u8 = undefined;
        for (0..48) |index| @memcpy(text[index * line.len ..][0..line.len], line);
        break :block text;
    };
    const program =
        \\func choose(flag: bool, value: int) int
        \\    if flag -> return value
        \\    var result = value
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    result += 1
        \\    return result
        \\func batch(value: int) int
        \\    var sum = 0
    ++ "\n" ++ batch_calls ++
        \\    return sum
        \\func growing(flag: bool, value: int) int
        \\    var sum = value
    ++ "\n" ++ growing_calls ++
        \\    return sum
        \\func run() int -> batch(1) + growing(false, 0) + growing(true, 3) - 777
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const batch = (try optimizedBody(fixture, "batch")).*.?;
    try testing.expectEqual(@as(usize, 0), try countCallsTo(batch, "choose", fixture));
    const growing = (try optimizedBody(fixture, "growing")).*.?;
    try testing.expect(try countCallsTo(growing, "choose", fixture) != 0);
}

test "power of two division rewrites to signed shifts and preserves truncation" {
    for ([_]i32{ 2, -2, 4, -4, 8, -8, 1024, -1024, 1073741824, -1073741824, -2147483648 }) |divisor| {
        const program = try testing.allocator.print(
            \\func divide(value: int) int -> value / {d}
            \\func check(value: int, divisor: int) int
            \\    if divide(value) <> value / divisor -> return 1
            \\    return 0
            \\func run() int
            \\    var failures = 0
            \\    var value = -40
            \\    loop
            \\        if value > 40 -> break
            \\        failures += check(value, {d})
            \\        value += 1
            \\    failures += check(-2147483648, {d})
            \\    failures += check(-2147483647, {d})
            \\    failures += check(2147483647, {d})
            \\    return 42 + failures
            \\exit(run())
        , .{ divisor, divisor, divisor, divisor, divisor });
        defer testing.allocator.free(program);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        try fixture.db.addInput(test_sources.queries.InlineLimit, {}, 0);
        try fixture.expectExit(0, 42);
        const body = (try optimizedBody(fixture, "divide")).*.?;
        try testing.expectEqual(@as(usize, 0), count(body, &.{.divsi}));
        // One shift extracts the sign for the truncation bias and one divides.
        try testing.expectEqual(@as(usize, 2), count(body, &.{.shrsi}));
    }
}

test "division rewriting and source shifts recompute after count and divisor edits" {
    const program =
        \\func divide(value: int) int -> value / 8
        \\func shifted(value: int) int -> value >> 1
        \\exit(divide(336) + shifted(0))
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.db.addInput(test_sources.queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
    const original = try optimizedBody(fixture, "divide");
    try testing.expectEqual(@as(usize, 0), count(original.*.?, &.{.divsi}));
    const changed = try std.mem.replaceOwned(u8, testing.allocator, program, "/ 8", "/ 3");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(0, 112);
    const recomputed = try optimizedBody(fixture, "divide");
    try testing.expect(original != recomputed);
    try testing.expectEqual(@as(usize, 1), count(recomputed.*.?, &.{.divsi}));
    const invalid = try std.mem.replaceOwned(u8, testing.allocator, changed, ">> 1", ">> 32");
    defer testing.allocator.free(invalid);
    const comptime_source = try std.mem.replaceOwned(u8, testing.allocator, invalid, "exit(divide(336) + shifted(0))", "exit(comptime -> shifted(0))");
    defer testing.allocator.free(comptime_source);
    try fixture.db.setInput(queries.SourceText, 0, comptime_source);
    try fixture.expectDiagnostic(0, .compile_time_invalid_shift_count);
    try fixture.db.setInput(queries.SourceText, 0, program);
    try fixture.expectExit(0, 42);
}

test "invalid shifts are retained when unused and inside potentially skipped loops" {
    const program =
        \\func ignored(count: int) int
        \\    const value = 0 << count
        \\    return 42
        \\func maybe(count: int, iterations: int) int
        \\    var index = 0
        \\    loop
        \\        if index >= iterations -> break
        \\        const value = 1 >> count
        \\        index += 1
        \\    return 42
        \\exit(maybe(32, 0))
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    try fixture.db.addInput(test_sources.queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
    const ignored = (try optimizedBody(fixture, "ignored")).*.?;
    const maybe = (try optimizedBody(fixture, "maybe")).*.?;
    try testing.expectEqual(@as(usize, 1), count(ignored, &.{.shli}));
    try testing.expectEqual(@as(usize, 1), count(maybe, &.{.shrsi}));
}

test "scalar expansion preserves repeated rewrites and aliases of newly emitted values" {
    var program: std.ArrayList(u8) = .empty;
    defer program.deinit(testing.allocator);
    try program.appendSlice(testing.allocator, "func expanded(value: int) int\n    var total = 0\n");
    for (0..64) |_| try program.appendSlice(testing.allocator, "    total += (value / -8) * -1\n");
    try program.appendSlice(testing.allocator,
        \\    if value < 0 -> return total + (value / -4) * -1
        \\    return total + (value / -2) * -1
        \\func run() int
        \\    if expanded(-9) <> -66 -> return 90
        \\    if expanded(9) <> 68 -> return 91
        \\    return 42
        \\exit(run())
    );
    const fixture = try Fixture.init(program.items);
    defer fixture.deinit();
    try fixture.db.addInput(queries.InlineLimit, {}, 0);
    try fixture.expectExit(0, 42);
    const body = (try optimizedBody(fixture, "expanded")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{.divsi}));
    // Only the unit-scale truncation bias of the division by two negates; the
    // other negations of divisors and products cancel.
    try testing.expectEqual(@as(usize, 1), count(body, &.{.negi}));
    // One shared sign word plus one quotient shift for each divisor.
    try testing.expectEqual(@as(usize, 4), count(body, &.{.shrsi}));
}

fn onCycle(body: structures.FunctionBodyAnalysis, start: usize) bool {
    var visited: [64]bool = @splat(false);
    var pending: [64]usize = undefined;
    var size: usize = 1;
    pending[0] = start;
    var first = true;
    while (size != 0) {
        size -= 1;
        const block = pending[size];
        if (!first) {
            if (block == start) return true;
            if (visited[block]) continue;
            visited[block] = true;
        }
        first = false;
        var terminator = body.blocks[block].terminator;
        for (terminator.branches()) |maybe_branch| if (maybe_branch) |branch| {
            pending[size] = @backingInt(branch.target);
            size += 1;
        };
    }
    return false;
}

test "scalar element writes leave parameter object reads loop invariant" {
    const fixture = try Fixture.init(
        \\struct Header
        \\    pub scale: int
        \\    pub flag: bool
        \\func fill(mut header: Header, mut values: List(int)) int
        \\    var total = 0
        \\    for index in 0..values.len()
        \\        values[index] = header.scale
        \\        total += 1
        \\    return total
        \\func run() int
        \\    var header = Header{scale = 2, flag = true}
        \\    var values = List(int).filled(1, 40)
        \\    if not (values is List(int)) -> return 90
        \\    return fill(header, values) + values[39]
        \\exit(run())
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const body = (try optimizedBody(fixture, "fill")).*.?;
    var header_reads: usize = 0;
    for (body.blocks, 0..) |block, index| {
        for (body.instructions[block.instruction_start..block.instruction_end]) |instruction| {
            if (instruction != .field_access or instruction.field_access.field_index != 0) continue;
            if (body.valueType(instruction.field_access.operand) != body.block_arguments[0].type_id) continue;
            header_reads += 1;
            try testing.expect(!onCycle(body, index));
        }
    }
    try testing.expect(header_reads != 0);
}

fn countRemainders(body: structures.FunctionBodyAnalysis) usize {
    var total: usize = 0;
    for (body.instructions) |instruction| {
        if (instruction == .numeric_binary and instruction.numeric_binary.operation == .rem) total += 1;
    }
    return total;
}

test "zero tests of power of two remainders use masks and recompute after edits" {
    const program =
        \\func even(value: int) bool -> value % 2 == 0
        \\func aligned(value: i64) bool -> value % 64 <> 0
        \\func other(value: int) bool -> value % 7 == 0
        \\func kept(value: int) int
        \\    const remainder = value % 8
        \\    if remainder == 0 -> return remainder + 1
        \\    return remainder
        \\func run() int
        \\    var total = kept(-13) + kept(16)
        \\    if even(-40) and not even(7) and aligned(65) and other(14) -> total += 26
        \\    return total
        \\exit(run())
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    // kept(-13) = -5, kept(16) = 1
    try fixture.expectExit(0, 22);
    const original = try optimizedBody(fixture, "even");
    try testing.expectEqual(@as(usize, 0), countRemainders(original.*.?));
    try testing.expectEqual(@as(usize, 1), count(original.*.?, &.{.numeric_binary}));
    try testing.expectEqual(@as(usize, 0), countRemainders((try optimizedBody(fixture, "aligned")).*.?));
    try testing.expectEqual(@as(usize, 1), countRemainders((try optimizedBody(fixture, "other")).*.?));
    try testing.expectEqual(@as(usize, 1), countRemainders((try optimizedBody(fixture, "kept")).*.?));
    const changed = try std.mem.replaceOwned(u8, testing.allocator, program, "% 2 == 0", "% 3 == 0");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    // even(-40) is now false: -40 % 3 is not zero.
    try fixture.expectExit(0, 252);
    try testing.expect(original != try optimizedBody(fixture, "even"));
    try testing.expectEqual(@as(usize, 1), countRemainders((try optimizedBody(fixture, "even")).*.?));
}

test "iteration carriers thread through their tag test and leave no variants in loops" {
    const program =
        \\func total(values: Array(int, 8)) int
        \\    var sum = 0
        \\    for value in values
        \\        sum += value
        \\    return sum
        \\func listed(values: List(int)) int
        \\    var sum = 0
        \\    for value in values
        \\        if value == 4 -> continue
        \\        if value > 100 -> break
        \\        sum += value
        \\    return sum
        \\func viewed(mut values: Array(int, 8)) int
        \\    var sum = 0
        \\    for ref value in values
        \\        value += 1
        \\        sum += value
        \\    return sum
        \\func run() int
        \\    var array: Array(int, 8) = [1, 2, 3, 4, 5, 6, 7, 8]
        \\    var list = List(int).from(9, [1, 2, 3, 4, 5, 6, 200, 7, 8])
        \\    if not (list is List(int)) -> return 90
        \\    return total(array) + listed(list) + viewed(array) - 55
        \\exit(run())
    ;
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    // total = 36, listed = 1+2+3+5+6 = 17, viewed = 2+3+...+9 = 44
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "total", "listed", "viewed" }) |name| {
        const body = (try optimizedBody(fixture, name)).*.?;
        try testing.expectEqual(@as(usize, 0), count(body, &.{ .variant_tag, .variant_coerce, .variant_extract }));
    }
}
