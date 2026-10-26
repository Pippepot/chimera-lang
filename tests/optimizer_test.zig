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
        \\    if const integer: int = value -> return integer
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
        \\    const value: Value = choose(flag, number) else return 90
        \\    if value.subtract -> return value.number - 10
        \\    return value.number + 10
        \\func constant(number: int) int
        \\    const value: Value = choose(true, number) else return 90
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
        \\    if const integer: int = value -> return integer
        \\    if const flag: bool = value
        \\        if flag -> return 22
        \\        return 90
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
        \\    if const integer: int = first -> result += integer
        \\    if const flag: bool = first
        \\        if flag -> result += 10
        \\    if const integer: int = second -> result += integer
        \\    if const flag: bool = second
        \\        if flag -> result += 10
        \\    const third = pick(mode, result)
        \\    if const integer: int = third -> return integer
        \\    return result
        \\func run() int -> calculate(0, 10) + calculate(1, 99) + calculate(2, 11)
    ;
    try Fixture.expectParity(program, 42);
    const fixture = try Fixture.init(program);
    defer fixture.deinit();
    const body = (try optimizedBody(fixture, "calculate")).*.?;
    try testing.expectEqual(@as(usize, 0), count(body, &.{ .variant_tag, .variant_extract }));
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
    \\        if const accepted: int = positive(value) -> return accepted + attempts
    \\        value += 5
    \\func run() int
    \\    if sum(10) <> 30 -> return 90
    \\    if merge(true, 4) <> 9 -> return 91
    \\    if merge(false, 4) <> 11 -> return 92
    \\    if borrowed(6) <> 7 -> return 93
    \\    if reopened(21) <> 42 -> return 95
    \\    if const value: int = checked(-12) -> if value == 7 -> return 42
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
    \\    var values: List(int) = List(int).filled(3, n) else return none
    \\    var index = 0
    \\    var sum = 0
    \\    loop
    \\        if index >= values.len() -> break
    \\        const value: int = values.get(index) else return none
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
    \\    if const scanned: int = scan(4)
    \\        if const halved: int = half(total(pair)) -> return halved + countdown(3) + sum + scanned - 45 + spin(9) - 5
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
    try testing.expectEqual(@as(usize, 0), countPredicates(spin));
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
