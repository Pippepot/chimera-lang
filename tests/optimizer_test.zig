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
        try testing.expectEqual(@as(usize, 3), countPredicates(body));
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
    try testing.expectEqual(@as(usize, 5), countPredicates(recomputed.*.?));
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

fn countCalls(body: structures.FunctionBodyAnalysis) usize {
    return count(body, &.{.call});
}

fn countPredicates(body: structures.FunctionBodyAnalysis) usize {
    var total: usize = 0;
    for (body.blocks) |block| total += @intFromBool(block.terminator == .predicate_branch);
    return total;
}

const pipeline_source =
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
    \\    var values = List(int).filled(3, n)
    \\    if not (values is List(int)) -> return none
    \\    var index = 0
    \\    var sum = 0
    \\    loop
    \\        if index >= values.len() -> break
    \\        const value = values.get(index)
    \\        if not (value is int) -> return none
    \\        sum += value
    \\        index += 1
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
        try testing.expectEqual(@as(usize, 1), count(body, &.{.shrsi}));
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
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .divsi, .negi }));
    try testing.expectEqual(@as(usize, 3), count(body, &.{.shrsi}));
}
