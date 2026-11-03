const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "collection sort handles Array List and sliced Span" {
    try Fixture.expectParity(
        \\func descending(imm left: int, imm right: int) bool -> left > right
        \\func run() int
        \\    var values = [5, 1, 4, 2, 3]
        \\    values.sort()
        \\    if values[0] <> 1 or values[4] <> 5 -> return 91
        \\    var middle = values[1..4]
        \\    middle.sort(descending)
        \\    if values[0] <> 1 or values[1] <> 4 or values[2] <> 3 or values[3] <> 2 or values[4] <> 5 -> return 93
        \\    var list: List(int) = [2, 5, 1, 4, 3]
        \\    const capacity = list.capacity()
        \\    list.sort(descending)
        \\    if list.len() <> 5 or list.capacity() <> capacity -> return 95
        \\    if list[0] <> 5 or list[4] <> 1 -> return 96
        \\    return 42
    , 42);
}

test "collection sorted produces a new owned List" {
    try Fixture.expectParity(
        \\func descending(imm left: int, imm right: int) bool -> left > right
        \\func run() int
        \\    const array = [3, 1, 2]
        \\    var ordered = array.sorted()
        \\    if not (ordered is List(int)) -> return 90
        \\    if array[0] <> 3 or ordered[0] <> 1 or ordered[2] <> 3 -> return 91
        \\    const source: List(int) = [3, 1, 2]
        \\    var reversed = source.sorted(descending)
        \\    if not (reversed is List(int)) -> return 92
        \\    if source[0] <> 3 or source[1] <> 1 -> return 93
        \\    if reversed[0] <> 3 or reversed[1] <> 2 or reversed[2] <> 1 -> return 94
        \\    const view = array.span()
        \\    var from_view = view.sorted()
        \\    if not (from_view is List(int)) -> return 95
        \\    if from_view[0] <> 1 or from_view[2] <> 3 -> return 96
        \\    return 42
    , 42);
}

test "collection sorted accepts temporary Array and List values" {
    try Fixture.expectParity(
        \\func make_array() Array(int, 3) -> [3, 1, 2]
        \\func make_list() List(int)
        \\    var values: List(int) = [3, 1, 2]
        \\    return values^
        \\func run() int
        \\    var first = make_array().sorted()
        \\    if not (first is List(int)) -> return 90
        \\    var second = make_list().sorted()
        \\    if not (second is List(int)) -> return 91
        \\    return first[0] + first[1] + first[2] + second[0] + second[1] + second[2] + 30
    , 42);
}

test "collection sorted preserves source loans and copied reference authority" {
    try Fixture.expectParity(
        \\func before(imm left: Ref(int), imm right: Ref(int)) bool -> left.value < right.value
        \\func copy_refs(ref first: int, ref second: int) List(Ref(int)) | none
        \\    const source = [Ref.from(first), Ref.from(second)]
        \\    return source.sorted(before)
        \\func make_refs(ref first: int, ref second: int) Array(Ref(int), 2) -> [Ref.from(first), Ref.from(second)]
        \\func run() int
        \\    var first = 23
        \\    var second = 19
        \\    var references = copy_refs(first, second)
        \\    if not (references is List(Ref(int))) -> return 90
        \\    references[0].value += 1
        \\    if second <> 20 or first <> 23 -> return 91
        \\    var temporary = make_refs(first, second).sorted(before)
        \\    if not (temporary is List(Ref(int))) -> return 94
        \\    temporary[0].value += 1
        \\    if second <> 21 -> return 95
        \\    var source = [3, 1, 2]
        \\    ref original = source[0]
        \\    var ordered = source.sorted()
        \\    if not (ordered is List(int)) -> return 92
        \\    if original <> 3 or source[1] <> 1 -> return 93
        \\    return ordered[0] + second + 20
    , 42);
}

test "collection sorted copies readonly Span and List elements with writable captures" {
    try Fixture.expectParity(
        \\struct Item
        \\    pub key: int
        \\    copies: Ref(int)
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{key = self.key, copies = self.copies}
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func check(mut copies: int) int
        \\    const source = [Item{key = 2, copies = Ref.from(copies)}, Item{key = 1, copies = Ref.from(copies)}]
        \\    const view = source.span()
        \\    var first = view.sorted(before)
        \\    if not (first is List(Item)) -> return 90
        \\    if copies <> 2 or first[0].key <> 1 -> return 91
        \\    const list: List(Item) = [Item{key = 4, copies = Ref.from(copies)}, Item{key = 3, copies = Ref.from(copies)}]
        \\    var second = list.sorted(before)
        \\    if not (second is List(Item)) -> return 92
        \\    if copies <> 4 or second[0].key <> 3 -> return 93
        \\    return 42
        \\func run() int
        \\    var copies = 0
        \\    return check(copies)
    , 42);
}

test "collection sorting cannot upgrade readonly captures" {
    try Fixture.expectAnySourceDiagnostic(
        \\func before(imm left: Ref(int), imm right: Ref(int)) bool -> left.value < right.value
        \\func invalid()
        \\    const readonly = 19
        \\    var writable = 23
        \\    var source = [Ref.from(readonly), Ref.from(writable)]
        \\    var ordered = source.sorted(before)
        \\    if not (ordered is List(Ref(int))) -> return
        \\    ordered[0].value += 1
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Item
        \\    pub key: int
        \\    copies: Ref(int)
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{key = self.key, copies = self.copies}
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func invalid()
        \\    const readonly = 0
        \\    const source = [Item{key = 2, copies = Ref.from(readonly)}, Item{key = 1, copies = Ref.from(readonly)}]
        \\    _ = source.sorted(before)
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(
        \\func invalid()
        \\    var values = [3, 1, 2]
        \\    const readonly = values.span()
        \\    var copy = readonly
        \\    _ = copy.sort()
        \\invalid()
    , .reference_not_writable);
}

test "collection sort rejects loans into relocated owners" {
    try Fixture.expectAnySourceDiagnostic(
        \\func before(imm left: List(int), imm right: List(int)) bool -> left.len() < right.len()
        \\func invalid()
        \\    var values: Array(List(int), 2) = [[19], [23, 40]]
        \\    ref first = values[0][0]
        \\    _ = values.sort(before)
        \\    print(first)
        \\invalid()
    , .borrow_outlives_source);
}

test "collection sort rejects custom moves that alias its backing" {
    const declarations =
        \\struct Item
        \\    pub key: int
        \\    pub target: Ref(int)
        \\    move = func(deinit self: Item) Item
        \\        self.target.value += 1
        \\        return Item{key = self.key, target = self.target}
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
    ;
    for ([_][]const u8{
        \\    var values = [Item{key = 19, target = Ref.from(external)}, Item{key = 23, target = Ref.from(external)}]
        ,
        \\    var values = [Item{key = (index * 17) % 64, target = Ref.from(external)} static for index in 0..64]
        ,
    }) |values| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\{s}
            \\func invalid()
            \\    var external = 0
            \\{s}
            \\    values[0].target = Ref.from(values[1].key)
            \\    _ = values.sort(before)
            \\invalid()
        , .{ declarations, values });
        defer std.testing.allocator.free(source);
        try Fixture.expectAnySourceDiagnostic(source, .borrow_outlives_source);
    }
}

test "collection sort preserves references into stable backing without custom moves" {
    try Fixture.expectParity(
        \\struct Item
        \\    pub key: int
        \\    pub target: Ref(int)
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func run() int
        \\    var external = 0
        \\    var small = [Item{key = 2, target = Ref.from(external)}, Item{key = 1, target = Ref.from(external)}]
        \\    small[0].target = Ref.from(small[1].key)
        \\    small.sort(before)
        \\    small[1].target.value += 40
        \\    if small[1].key <> 42 -> return 91
        \\    var large = [Item{key = (index * 17) % 64, target = Ref.from(external)} static for index in 0..64]
        \\    large[0].target = Ref.from(large[1].key)
        \\    large.sort(before)
        \\    if large[0].key <> 0 or large[1].key <> 1 -> return 93
        \\    large[0].target.value += 41
        \\    return large[1].key
    , 42);
}

test "collection sort transfers explicit drop obligations" {
    try Fixture.expectParity(
        \\struct Token
        \\    drop = explicit
        \\    pub value: int
        \\func before(imm left: Token, imm right: Token) bool -> left.value < right.value
        \\func dispose(deinit token: Token) int -> token.value
        \\func run() int
        \\    var values = [Token{value = 23}, Token{value = 19}]
        \\    values.sort(before)
        \\    const [first, second] = values^
        \\    if first.value <> 19
        \\        _ = dispose(first^) + dispose(second^)
        \\        return 91
        \\    return dispose(first^) + dispose(second^)
    , 42);
}

test "collection sorted rejects elements requiring explicit drop" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Token
        \\    copy = trivial
        \\    drop = explicit
        \\    pub value: int
        \\func before(imm left: Token, imm right: Token) bool -> left.value < right.value
        \\func dispose(deinit token: Token) int -> token.value
        \\func invalid()
        \\    var values = [Token{value = 23}, Token{value = 19}]
        \\    _ = values.sorted(before)
        \\    const [first, second] = values^
        \\    _ = dispose(first^) + dispose(second^)
        \\invalid()
    , .list_requires_automatic_drop);
}

test "collection sort is stable for noncopyable elements" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    pub sequence: int
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func run() int
        \\    var values = [Item{key = 2, sequence = 0}, Item{key = 1, sequence = 1}, Item{key = 2, sequence = 2}, Item{key = 1, sequence = 3}]
        \\    values.sort(before)
        \\    if values[0].sequence <> 1 or values[1].sequence <> 3 -> return 91
        \\    if values[2].sequence <> 0 or values[3].sequence <> 2 -> return 92
        \\    return 42
    , 42);
}

test "collection sorted requires copyable elements" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\var values = [Item{key = 1}]
        \\_ = values.sorted(before)
    , .where_condition_failed);
}

test "collection sorted copies custom-move elements before ordering" {
    try Fixture.expectParity(
        \\struct Item
        \\    pub key: int
        \\    copies: Ref(int)
        \\    moves: Ref(int)
        \\    drops: Ref(int)
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{key = 10 - self.key, copies = self.copies, moves = self.moves, drops = self.drops}
        \\    move = func(deinit self: Item) Item
        \\        self.moves.value += 1
        \\        return Item{key = self.key, copies = self.copies, moves = self.moves, drops = self.drops}
        \\    drop = func(deinit self: Item) -> self.drops.value += 1
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func check(mut copies: int, mut moves: int, mut drops: int) int
        \\    const source = [Item{key = 1, copies = Ref.from(copies), moves = Ref.from(moves), drops = Ref.from(drops)}, Item{key = 3, copies = Ref.from(copies), moves = Ref.from(moves), drops = Ref.from(drops)}, Item{key = 2, copies = Ref.from(copies), moves = Ref.from(moves), drops = Ref.from(drops)}]
        \\    copies = 0
        \\    moves = 0
        \\    drops = 0
        \\    var ordered = source.sorted(before)
        \\    if not (ordered is List(Item)) -> return 90
        \\    if source[0].key <> 1 or source[1].key <> 3 or source[2].key <> 2 -> return 91
        \\    if ordered[0].key <> 7 or ordered[1].key <> 8 or ordered[2].key <> 9 -> return 92
        \\    if copies <> 3 -> return 93
        \\    if moves == 0 -> return 96
        \\    if drops <> 0 -> return 97
        \\    _ = source
        \\    _ = ordered
        \\    return 42
        \\func run() int
        \\    var copies = 0
        \\    var moves = 0
        \\    var drops = 0
        \\    const outcome = check(copies, moves, drops)
        \\    if outcome <> 42 -> return outcome
        \\    if drops <> 6 -> return 95
        \\    return 42
    , 42);
}

test "collection sort permits writable comparator captures" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    comparisons: Ref(int)
        \\func before(imm left: Item, imm right: Item) bool
        \\    left.comparisons.value += 1
        \\    return left.key < right.key
        \\func check(mut comparisons: int) int
        \\    var values = [Item{key = 3, comparisons = Ref.from(comparisons)}, Item{key = 1, comparisons = Ref.from(comparisons)}, Item{key = 2, comparisons = Ref.from(comparisons)}]
        \\    values.sort(before)
        \\    if values[0].key <> 1 or values[2].key <> 3 -> return 91
        \\    if comparisons == 0 -> return 92
        \\    return 42
        \\func run() int
        \\    var comparisons = 0
        \\    return check(comparisons)
    , 42);
}

test "reference-bearing List construction keeps captured authority" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    comparisons: Ref(int)
        \\func check(mut comparisons: int) int
        \\    var values = List(Item).new(64)
        \\    if not (values is List(Item)) -> return 90
        \\    var index = 0
        \\    loop
        \\        if index == 64 -> break
        \\        if not (values.append(Item{key = index, comparisons = Ref.from(comparisons)}) is unit) -> return 91
        \\        index += 1
        \\    values[0].comparisons.value += 1
        \\    return comparisons + 41
        \\func run() int
        \\    var comparisons = 0
        \\    return check(comparisons)
    , 42);
}

test "driftsort stably merges natural runs and unsorted regions" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    pub sequence: int
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func run() int
        \\    var values = List(Item).new(256)
        \\    if not (values is List(Item)) -> return 90
        \\    var index = 0
        \\    loop
        \\        if index == 256 -> break
        \\        var key = (index * 37) % 127
        \\        if index < 80 -> key = index * 2
        \\        else if index < 160 -> key = 280 - index
        \\        if not (values.append(Item{key = key, sequence = index}) is unit) -> return 91
        \\        index += 1
        \\    values.sort(before)
        \\    index = 1
        \\    loop
        \\        if index == values.len() -> break
        \\        if values[index - 1].key > values[index].key -> return 93
        \\        if values[index - 1].key == values[index].key and values[index - 1].sequence >= values[index].sequence -> return 94
        \\        index += 1
        \\    return 42
    , 42);
}

test "driftsort adapts to ordered inputs and repeated keys" {
    const source =
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    pub sequence: int
        \\    comparisons: Ref(int)
        \\func before(imm left: Item, imm right: Item) bool
        \\    left.comparisons.value += 1
        \\    return left.key < right.key
        \\func check(pattern: int, mut comparisons: int) int
        \\    var values = List(Item).new(256)
        \\    if not (values is List(Item)) -> return 90
        \\    var index = 0
        \\    loop
        \\        if index == 256 -> break
        \\        var key = index
        \\        if pattern == 1 -> key = 255 - index
        \\        if pattern == 2 -> key = (index * 37 + 7) % 3
        \\        if not (values.append(Item{key = key, sequence = index, comparisons = Ref.from(comparisons)}) is unit) -> return 91
        \\        index += 1
        \\    comparisons = 0
        \\    values.sort(before)
        \\    if pattern < 2 and comparisons > 260 -> return 93
        \\    if pattern == 2 and comparisons > 2048 -> return 94
        \\    index = 1
        \\    loop
        \\        if index == values.len() -> break
        \\        if values[index - 1].key > values[index].key -> return 95
        \\        if values[index - 1].key == values[index].key and values[index - 1].sequence >= values[index].sequence -> return 96
        \\        index += 1
        \\    return 42
        \\func run() int
        \\    var comparisons = 0
        \\    if check(0, comparisons) <> 42 -> return 97
        \\    if check(1, comparisons) <> 42 -> return 98
        \\    if check(2, comparisons) <> 42 -> return 99
        \\    return 42
    ;
    try Fixture.expectParity(source, 42);
}

test "driftsort preserves each value across lengths and distributions" {
    try Fixture.expectParity(
        \\func run() int
        \\    for length in [0, 1, 2, 19, 20, 21, 63, 64, 65, 127, 128]
        \\        var values = List(int).new(length)
        \\        if not (values is List(int)) -> return 90
        \\        var counts = Array(int, 17).filled(0)
        \\        var index = 0
        \\        loop
        \\            if index == length -> break
        \\            const item = (index * 73 + length * 19) % 17
        \\            counts[item] += 1
        \\            if not (values.append(item) is unit) -> return 91
        \\            index += 1
        \\        values.sort()
        \\        index = 0
        \\        loop
        \\            if index == length -> break
        \\            if index > 0 and values[index - 1] > values[index] -> return 93
        \\            counts[values[index]] -= 1
        \\            index += 1
        \\        for count in counts
        \\            if count <> 0 -> return 94
        \\    return 42
    , 42);
}

test "driftsort run scheduling handles integer boundaries" {
    try Fixture.expectFilesParity(
        \\import std.memory.{test_drift_threshold, test_drift_depth, test_drift_power}
        \\func run() int
        \\    if test_drift_threshold(21) <> 11 -> return 90
        \\    if test_drift_threshold(4096) <> 64 -> return 91
        \\    if test_drift_threshold(4097) <> 64 -> return 92
        \\    if test_drift_threshold(2147483647) <> 49151 -> return 93
        \\    if test_drift_depth(1) <> 0 or test_drift_depth(2147483647) <> 60 -> return 94
        \\    if test_drift_power(2147483647, 0, 1, 2) <> 31 -> return 95
        \\    if test_drift_power(2147483647, 0, 1, 2147483647) <> 1 -> return 96
        \\    return 42
    , &.{.{
        .path = "drift_test.chi",
        .module_path = "std.memory",
        .source =
        \\pub func test_drift_threshold(length: int) int -> drift_run_threshold(length)
        \\pub func test_drift_depth(length: int) int -> drift_depth(length)
        \\pub func test_drift_power(length: int, first: int, middle: int, limit: int) int -> drift_node_power(length, first, middle, limit)
        ,
    }}, 42);
}

test "driftsort stable fallback sorts a forced depth-limited region" {
    const source =
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    pub sequence: int
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func run() int
        \\    var values = List(Item).new(96)
        \\    if not (values is List(Item)) -> return 90
        \\    for index in 0..96
        \\        if not (values.append(Item{key = (index * 37 + 7) % 7, sequence = index}) is unit) -> return 91
        \\    values.sort(before)
        \\    for index in 1..96
        \\        if values[index - 1].key > values[index].key -> return 93
        \\        if values[index - 1].key == values[index].key and values[index - 1].sequence >= values[index].sequence -> return 94
        \\    return 42
    ;
    const standard_library = @import("standard_library");
    const original = standard_library.source("memory/sort.chi");
    const call = "drift_quicksort(T, source, order, scratch, 0, length, drift_depth(length), before)";
    try std.testing.expect(std.mem.indexOf(u8, original, call) != null);
    const forced = try std.mem.replaceOwned(u8, std.testing.allocator, original, call, "drift_quicksort(T, source, order, scratch, 0, length, 0, before)");
    defer std.testing.allocator.free(forced);
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
        const program = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const file = (try fixture.db.input(test_sources.queries.StandardFile, @backingInt(standard_library.File.memory_sort))).*;
        try fixture.db.setInput(test_sources.queries.SourceText, file, forced);
        try fixture.expectExit(0, 42);
    }
}

test "driftsort terminates and preserves elements with inconsistent comparisons" {
    try Fixture.expectParity(
        \\func inconsistent(imm left: int, imm right: int) bool -> (left + right) % 2 == 0
        \\func run() int
        \\    var values = Array(int, 80).filled(0)
        \\    var counts = Array(int, 80).filled(0)
        \\    for index in 0..80 -> values[index] = index
        \\    values.sort(inconsistent)
        \\    for item in values
        \\        if item < 0 or item >= 80 -> return 91
        \\        counts[item] += 1
        \\    for count in counts
        \\        if count <> 1 -> return 92
        \\    return 42
    , 42);
}

test "driftsort moves owners and retains their references and drop duties" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub key: int
        \\    pub target: Ref(int)
        \\    moves: Ref(int)
        \\    drops: Ref(int)
        \\    move = func(deinit self: Item) Item
        \\        self.moves.value += 1
        \\        return Item{key = self.key, target = self.target, moves = self.moves, drops = self.drops}
        \\    drop = func(deinit self: Item) -> self.drops.value += 1
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func reorder(mut target: int, mut moves: int, mut drops: int) int
        \\    var values = [Item{key = (index * 17) % 64, target = Ref.from(target), moves = Ref.from(moves), drops = Ref.from(drops)} static for index in 0..64]
        \\    moves = 0
        \\    values.sort(before)
        \\    if moves == 0 or drops <> 0 -> return 93
        \\    var index = 0
        \\    loop
        \\        if index == 64 -> break
        \\        if values[index].key <> index -> return 94
        \\        values[index].target.value += 1
        \\        index += 1
        \\    return 42
        \\func run() int
        \\    var target = 0
        \\    var moves = 0
        \\    var drops = 0
        \\    if reorder(target, moves, drops) <> 42 -> return 95
        \\    if target <> 64 or drops <> 64 -> return 96
        \\    return 42
    , 42);
}

test "collection sorting panics when either scratch allocation fails" {
    const source =
        \\func run() int
        \\    var values = Array(int, 64).filled(0)
        \\    for index in 0..64 -> values[index] = (index * 17) % 64
        \\    $operation
        \\    return 42
    ;
    const standard_library = @import("standard_library");
    const original = standard_library.source("memory/sort.chi");
    for ([_]struct { original: []const u8, failed: []const u8 }{
        .{ .original = "var order = List(int).filled(0, length)", .failed = "var order = List(int).filled(0, -1)" },
        .{ .original = "var scratch = List(int).filled(0, length)", .failed = "var scratch = List(int).filled(0, -1)" },
    }) |allocation| {
        try std.testing.expect(std.mem.indexOf(u8, original, allocation.original) != null);
        const failed = try std.mem.replaceOwned(u8, std.testing.allocator, original, allocation.original, allocation.failed);
        defer std.testing.allocator.free(failed);
        for ([_][]const u8{ "values.sort()", "_ = values.sorted()" }) |operation| {
            const declarations = try test_sources.renderTemplate(std.testing.allocator, source, .{ .operation = operation });
            defer std.testing.allocator.free(declarations);
            for ([_]bool{ false, true }) |comptime_call| {
                const program = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit({s}run())", .{ declarations, if (comptime_call) "comptime -> " else "" });
                defer std.testing.allocator.free(program);
                const fixture = try Fixture.init(program);
                defer fixture.deinit();
                const file = (try fixture.db.input(test_sources.queries.StandardFile, @backingInt(standard_library.File.memory_sort))).*;
                try fixture.db.setInput(test_sources.queries.SourceText, file, failed);
                if (comptime_call) {
                    try fixture.expectDiagnostic(null, .compile_time_panic);
                } else {
                    const result = try fixture.runIo("");
                    defer std.testing.allocator.free(result.stdout);
                    defer std.testing.allocator.free(result.stderr);
                    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
                    try std.testing.expect(std.mem.startsWith(u8, result.stderr, "panic: sort scratch allocation failed\n"));
                }
            }
        }
    }
}

test "collection sort fast paths do not need scratch allocations" {
    const source =
        \\func run() int
        \\    var empty = Array(int, 0).filled(0)
        \\    empty.sort()
        \\    var singleton = [42]
        \\    singleton.sort()
        \\    var small = [20 - index static for index in 0..20]
        \\    small.sort()
        \\    var ascending = [index static for index in 0..64]
        \\    ascending.sort()
        \\    var descending = [63 - index static for index in 0..64]
        \\    descending.sort()
        \\    for index in 0..20
        \\        if small[index] <> index + 1 -> return 90
        \\    for index in 0..64
        \\        if ascending[index] <> index or descending[index] <> index -> return 91
        \\    return singleton[0]
    ;
    const standard_library = @import("standard_library");
    const original = standard_library.source("memory/sort.chi");
    const failed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "List(int).filled(0, length)", "List(int).filled(0, -1)");
    defer std.testing.allocator.free(failed);
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
        const program = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const file = (try fixture.db.input(test_sources.queries.StandardFile, @backingInt(standard_library.File.memory_sort))).*;
        try fixture.db.setInput(test_sources.queries.SourceText, file, failed);
        try fixture.expectExit(0, 42);
    }
}

test "collection sorted result allocation failure leaves elements uncopied" {
    const source =
        \\struct Item
        \\    pub key: int
        \\    copies: Ref(int)
        \\    drops: Ref(int)
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{key = self.key, copies = self.copies, drops = self.drops}
        \\    drop = func(deinit self: Item) -> self.drops.value += 1
        \\func before(imm left: Item, imm right: Item) bool -> left.key < right.key
        \\func check(mut copies: int, mut drops: int) int
        \\    var source = [Item{key = (index * 17) % 32, copies = Ref.from(copies), drops = Ref.from(drops)} static for index in 0..32]
        \\    copies = 0
        \\    drops = 0
        \\    const result = source.sorted(before)
        \\    if not (result is none) -> return 90
        \\    if copies <> 0 or drops <> 0 -> return 91
        \\    for index in 0..32
        \\        if source[index].key <> (index * 17) % 32 -> return 92
        \\    _ = source
        \\    return 42
        \\func run() int
        \\    var copies = 0
        \\    var drops = 0
        \\    if check(copies, drops) <> 42 -> return 93
        \\    if drops <> 32 -> return 94
        \\    return 42
    ;
    const standard_library = @import("standard_library");
    const original = standard_library.source("memory/sort.chi");
    const allocation = "var result = List(T).new(source.len())";
    try std.testing.expect(std.mem.indexOf(u8, original, allocation) != null);
    const failed = try std.mem.replaceOwned(u8, std.testing.allocator, original, allocation, "var result = List(T).new(-1)");
    defer std.testing.allocator.free(failed);
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
        const program = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const file = (try fixture.db.input(test_sources.queries.StandardFile, @backingInt(standard_library.File.memory_sort))).*;
        try fixture.db.setInput(test_sources.queries.SourceText, file, failed);
        try fixture.expectExit(0, 42);
    }
}
