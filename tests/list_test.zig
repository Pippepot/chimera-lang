const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

const owned_item =
    \\struct Item
    \\    copy = none
    \\    value: int
    \\func consume(deinit item: Item) int -> item.value
;

const traced_item =
    \\struct Item
    \\    copy = none
    \\    trace: Ref(int)
    \\    value: int
    \\    drop = func(deinit self: Item) -> self.trace.value += self.value
;

test "List slot replacement destroys the previous item with its captured references" {
    try expectCalculation(traced_item ++ "\n" ++
        \\func calculate() int | none
        \\    var trace = 0
        \\    var values: List(Item) = [Item{trace = Ref.from(trace), value = 20}]
        \\    if 1 == 1
        \\        var temporary = 0
        \\        values[0] = Item{trace = Ref.from(temporary), value = 7}
        \\        values[0] = Item{trace = Ref.from(trace), value = 22}
        \\        if temporary <> 7 -> return 90
        \\    for item in values^ -> ()
        \\    return trace
    , 42);
}

test "List slot replacement preserves readonly authority when dropping the old item" {
    try Fixture.expectSourceDiagnostic(traced_item ++ "\n" ++
        \\func invalid() unit | none
        \\    const original = 0
        \\    var replacement = 0
        \\    var values: List(Item) = [Item{trace = Ref.from(original), value = 1}]
        \\    values[0] = Item{trace = Ref.from(replacement), value = 1}
        \\    return ()
        \\if (invalid() is unit) -> ()
    , .reference_not_writable);
}

test "List consuming early exits release backing allocations repeatedly" {
    const fixture = try Fixture.init(
        \\func calculate() int | none
        \\    var iteration = 0
        \\    loop
        \\        if iteration == 384 -> break
        \\        const values = List(Array(int, 2048)).from([Array(int, 2048).filled(0), Array(int, 2048).filled(0)])
        \\        if not (values is List(Array(int, 2048))) -> return none
        \\        for item in values^ -> break
        \\        iteration += 1
        \\    return 42
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
        \\exit(run())
    );
    defer fixture.deinit();
    const executable = try fixture.executable(0);
    try test_sources.runtime.writeProgram(std.testing.io, executable.bytes);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
    var child = std.process.spawn(std.testing.io, .{ .argv = &.{ "prlimit", "--as=1048576", "--", "./prog" } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, try child.wait(std.testing.io));
}

test "List removal and consuming traversal transfer nested array storage" {
    try expectCalculation(
        \\func calculate() int | none
        \\    var values: List(Array(int, 2)) = [[9, 10], [20, 22]]
        \\    const removed = values.remove(1)
        \\    if not (removed is Array(int, 2)) -> return none
        \\    var total = removed[0] + removed[1]
        \\    for item in values^ -> total += item[0] - item[1] + 1
        \\    return total
    , 42);
}

test "slot selectors remap captured local indices across deferred initialization" {
    try expectCalculation(
        \\func select(ref values: Array(Ref(int), 2), index: int) Ref(int) | none
        \\    const picked = index + 0
        \\    const owner = Box.new(values[picked])
        \\    if not (owner is Box(Ref(int))) -> return none
        \\    return owner.take()
        \\func calculate() int | none
        \\    var source = 42
        \\    var result: Ref(int) | none = none
        \\    if 1 == 1
        \\        var temporary = 7
        \\        var values = [Ref.from(source), Ref.from(temporary)]
        \\        result = ((match select(values, 0)
        \\            _selected_result_0 and _selected_result_0 is Ref(int) -> _selected_result_0
        \\            _ -> return none))
        \\    match result
        \\        Ref(int) ->
        \\            ref item = result
        \\            return item.value
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "recursive List mutations widen changing index selectors to finite contracts" {
    try expectCalculation(
        \\func replace(mut values: List(Ref(int)), index: int, ref source: int, remaining: int) unit | none
        \\    values[index] = Ref.from(source)
        \\    if remaining > 0 -> ((match replace(values, index + 1, source, remaining - 1)
        \\        _selected_result_0 and _selected_result_0 is unit -> _selected_result_0
        \\        _ -> return none))
        \\    return ()
        \\func calculate() int | none
        \\    var source = 14
        \\    var values: List(Ref(int)) = [Ref.from(source), Ref.from(source), Ref.from(source)]
        \\    const checked_value_1 = replace(values, 0, source, 2)
        \\    if not (checked_value_1 is unit) -> return none
        \\    return values[0].value + values[1].value + values[2].value
    , 42);
}

test "List failed growth destroys its prepared item and preserves initialized elements" {
    const source = traced_item ++ "\n" ++
        \\func calculate() int | none
        \\    var trace = 0
        \\    var values: List(Item) = [Item{trace = Ref.from(trace), value = 1}]
        \\    if (values.append(Item{trace = Ref.from(trace), value = 2}) is unit) -> return 90
        \\    if values.len() <> 1 -> return 91
        \\    if trace == 3 -> return 42
        \\    return 92
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 93
    ;
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
        const program = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try Fixture.init(program);
        defer fixture.deinit();
        const allocation_file = (try fixture.db.input(test_sources.queries.StandardFile, @backingInt(@import("standard_library").File.memory_allocation))).*;
        const original = (try fixture.db.input(test_sources.queries.SourceText, allocation_file)).*;
        try std.testing.expect(std.mem.indexOf(u8, original, "allocate(T, minimum_capacity)") != null);
        const failed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "allocate(T, minimum_capacity)", "allocate(T, -1)");
        defer std.testing.allocator.free(failed);
        try fixture.db.setInput(test_sources.queries.SourceText, allocation_file, failed);
        try fixture.expectExit(0, 42);
    }
}

test "List consuming traversal cleans items on continue return and failure" {
    const declarations = traced_item ++ "\n" ++
        \\func walk(mut trace: int) unit | none
        \\    const values: List(Item) = [Item{trace = Ref.from(trace), value = 1}, Item{trace = Ref.from(trace), value = 1}, Item{trace = Ref.from(trace), value = 1}]
    ;
    for ([_][]const u8{ "continue", "return unit", "return none" }) |body| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}\n    for item in values^ -> {s}\n    return unit\nfunc run() int\n    var trace = 0\n    const outcome = walk(trace)\n    if (outcome is none) <> {s} -> return 91\n    if trace == 3 -> return 42\n    return 90",
            .{ declarations, body, if (std.mem.eql(u8, body, "return none")) "true" else "false" },
        );
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "List consuming bindings preserve ownership without copying" {
    for ([_][]const u8{ "", "const", "var" }) |mode| {
        const source = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}\nfunc run() int\n    const values: List(Item) = [Item{{value = 20}}, Item{{value = 22}}]\n    var total = 0\n    for {s} item in values^ -> total += consume(item^)\n    return total",
            .{ owned_item, mode },
        );
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
    try Fixture.expectParity(
        \\func run() int
        \\    const values: List(int) = [20, 20]
        \\    var total = 0
        \\    for ref item in values^
        \\        item += 1
        \\        total += item
        \\    return total
    , 42);
}

test "List consuming Ref handles retain their external referents after cursor cleanup" {
    try expectCalculation(
        \\func calculate() int | none
        \\    var source = 20
        \\    const values: List(Ref(int)) = [Ref.from(source)]
        \\    var saved: Ref(int) | none = none
        \\    for item in values^ -> saved = item
        \\    match saved
        \\        Ref(int) ->
        \\            ref item = saved
        \\            item.value += 22
        \\        _ -> ()
        \\    return source
    , 42);
}

test "List consuming traversal rejects an escaping alias into the current item" {
    try Fixture.expectSourceDiagnostic(
        \\const values: List(int) = [42]
        \\var saved: Ref(int) | none = none
        \\for ref item in values^ -> saved = Ref.from(item)
        \\match saved
        \\    Ref(int) ->
        \\        ref item = saved
        \\        print(item.value)
        \\    _ -> ()
    , .borrow_outlives_source);
}

test "List consuming traversal preserves readonly captured backing" {
    try Fixture.expectSourceDiagnostic(
        \\func readonly(imm values: Array(int, 1)) Span(int) -> values.span()
        \\func invalid() unit | none
        \\    var original = [20]
        \\    const values: List(Span(int)) = [readonly(original)]
        \\    for var item in values^ -> item[0] = 42
        \\    return ()
        \\if (invalid() is unit) -> ()
    , .reference_not_writable);
}

test "List consuming traversal preserves mixed reference and owned alternatives" {
    try Fixture.expectParity(
        \\func run() int
        \\    var original = 20
        \\    const reference: ref int | none = original
        \\    const values = [if i == 0 -> reference else none for i in 0..2]
        \\    var total = 22
        \\    for item in values^
        \\        match item
        \\            int ->
        \\                ref selected = item
        \\                total += selected
        \\            _ -> ()
        \\    return total
    , 42);
}

test "List consuming traversal cannot erase an owned End alternative" {
    for ([_][]const u8{ "End", "int | End" }) |element| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "const values: List({s}) = [End{{}}]\nfor item in values^ -> ()", .{element});
        defer std.testing.allocator.free(source);
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        try fixture.expectLibraryDiagnostic(.list_iteration_item_conflicts_with_end);
    }
}

test "List removal cannot leave a live borrowed iterator over ended slots" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() unit | none
        \\    var values: List(int) = [20, 22]
        \\    for item in values
        \\        print(item)
        \\        const checked_value_1 = values.remove(0)
        \\        if not (checked_value_1 is int) -> return none
        \\    return ()
        \\if (invalid() is unit) -> ()
    , .borrow_outlives_source);
}

test "List borrowed iteration allows replacement in stable initialized slots" {
    try expectCalculation(
        \\func calculate() int | none
        \\    var values: List(int) = [20, 20]
        \\    for ref item in values -> item += 1
        \\    return values[0] + values[1]
    , 42);
}

test "List transfer through field and conditional sources selects consuming traversal" {
    try Fixture.expectParity(owned_item ++ "\n" ++
        \\struct Holder
        \\    values: List(Item)
        \\func run() int
        \\    var holder = Holder{values = [Item{value = 20}]}
        \\    var other: List(Item) = [Item{value = 90}]
        \\    var total = 0
        \\    for item in (if true -> holder.values^ else other^) -> total += consume(item^)
        \\    const more: List(Item) = [Item{value = 22}]
        \\    for item in more^ -> total += consume(item^)
        \\    return total
    , 42);
}

test "List reference append and relocation retain independent captured authority" {
    try expectCalculation(
        \\func calculate() int | none
        \\    var first = 10
        \\    var second = 20
        \\    var values = List(Ref(int)).new(0)
        \\    if not (values is List(Ref(int))) -> return none
        \\    const checked_value_2 = values.append(Ref.from(first))
        \\    if not (checked_value_2 is unit) -> return none
        \\    const checked_value_3 = values.append(Ref.from(second))
        \\    if not (checked_value_3 is unit) -> return none
        \\    const checked_value_4 = values.reserve(8)
        \\    if not (checked_value_4 is unit) -> return none
        \\    values[0].value += 1
        \\    values[1].value += 1
        \\    return first + second + values.len() + values.capacity()
    , 42);
}

test "List removal returns captured references independently of the old allocation" {
    try expectCalculation(
        \\func extract(ref source: int) Ref(int) | none
        \\    var values: List(Ref(int)) = [Ref.from(source)]
        \\    return ((match values.remove(0)
        \\        _selected_result_0 and _selected_result_0 is Ref(int) -> _selected_result_0
        \\        _ -> return none))
        \\func calculate() int | none
        \\    var source = 20
        \\    var result = extract(source)
        \\    if not (result is Ref(int)) -> return none
        \\    result.value += 22
        \\    return source
    , 42);
}

test "List conditional removal conservatively retains possible captures" {
    try Fixture.expectSourceDiagnostic(
        \\func calculate() int | none
        \\    var source = 21
        \\    var values: List(Ref(int)) = [Ref.from(source), Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        values[0] = Ref.from(temporary)
        \\        const removed = values.remove(0)
        \\        if not (removed is Ref(int)) -> return none
        \\        if removed.value <> 7 -> return 90
        \\    return values[0].value * 2
        \\_ = calculate()
    , .borrow_outlives_source);
}

test "List failed removal preserves the stored capture" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() unit | none
        \\    var source = 21
        \\    var values: List(Ref(int)) = [Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        values[0] = Ref.from(temporary)
        \\        if (values.remove(1) is Ref(int)) -> return ()
        \\    print(values[0].value)
        \\    return ()
        \\if (invalid() is unit) -> ()
    , .borrow_outlives_source);
}

test "List writes before ordinary failure replace the caller capture" {
    try expectCalculation(
        \\func replace(ref slot: Ref(int), ref source: int) unit | none
        \\    slot = Ref.from(source)
        \\    return none
        \\    return ()
        \\func calculate() int | none
        \\    var source = 42
        \\    var values: List(Ref(int)) = [Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        values[0] = Ref.from(temporary)
        \\        const checked_value_1 = values.get(0)
        \\        if not (checked_value_1 is Ref(int)) -> return none
        \\        ref slot = checked_value_1
        \\        if (replace(slot, source) is unit) -> return 90
        \\    return values[0].value
    , 42);
}

test "List conditional replacement conservatively retains possible captures" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut values: List(Ref(int)), index: int, ref source: int) unit | none
        \\    const checked_value_1 = values.get(index)
        \\    if not (checked_value_1 is Ref(int)) -> return none
        \\    ref slot = checked_value_1
        \\    slot = Ref.from(source)
        \\    return ()
        \\func calculate() int | none
        \\    var source = 42
        \\    var values: List(Ref(int)) = [Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        const checked_value_2 = replace(values, 0, temporary)
        \\        if not (checked_value_2 is unit) -> return none
        \\        const checked_value_3 = replace(values, 0, source)
        \\        if not (checked_value_3 is unit) -> return none
        \\    return values[0].value
        \\_ = calculate()
    , .borrow_outlives_source);
}

test "indexed reference outputs remap selectors through forwarded handles" {
    const declarations =
        \\func replace(var handle: Ref(Array(Ref(int), 2)), index: int, ref source: int) unit | none
        \\    const checked_value_1 = handle.value.get(index)
        \\    if not (checked_value_1 is Ref(int)) -> return none
        \\    ref slot = checked_value_1
        \\    slot = Ref.from(source)
        \\    return ()
        \\func forward(ref values: Array(Ref(int), 2), index: int, ref source: int) unit | none
        \\    const checked_value_2 = replace(Ref.from(values), index + 1, source)
        \\    if not (checked_value_2 is unit) -> return none
        \\    return ()
    ;
    try expectCalculation(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var source = 21
        \\    var values = [Ref.from(source), Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        forward(values, -1, temporary)
        \\        forward(values, -1, source)
        \\    return values[0].value + values[1].value
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit | none
        \\    var source = 21
        \\    var values = [Ref.from(source), Ref.from(source)]
        \\    if 1 == 1
        \\        var temporary = 7
        \\        forward(values, -1, temporary)
        \\    print(values[0].value)
        \\    return ()
        \\if (invalid() is unit) -> ()
    , .borrow_outlives_source);
}

test "List removal preserves order and bounds failures preserve contents" {
    try expectCalculation(
        \\func calculate() int | none
        \\    var values: List(int) = [10, 11, 21]
        \\    if (values.remove(-1) is int) -> return 90
        \\    if (values.remove(3) is int) -> return 91
        \\    const removed = values.remove(1)
        \\    if not (removed is int) -> return none
        \\    if values.len() <> 2 -> return 92
        \\    return values[0] + removed + values[1]
    , 42);
}

test "List filled copies one value into every slot" {
    try expectCalculation(
        \\struct Item
        \\    value: int
        \\    copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func calculate() int | none
        \\    if (List(int).filled(0, -1) is List(int)) -> return 90
        \\    const empty = List(int).filled(0, 0)
        \\    if not (empty is List(int)) -> return none
        \\    if empty.len() <> 0 -> return 91
        \\    const source = Item{value = 13}
        \\    const values = List(Item).filled(source, 2)
        \\    if not (values is List(Item)) -> return none
        \\    if values.len() <> 2 -> return 92
        \\    if values.capacity() <> 2 -> return 93
        \\    return values[0].value + values[1].value + source.value + 1
    , 42);
}

test "List consuming traversal cleans current and remaining items on early break" {
    try Fixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value = self.trace.value * 10 + self.value
        \\func run() int
        \\    var trace = 0
        \\    const values: List(Item) = [Item{trace = Ref.from(trace), value = 1}, Item{trace = Ref.from(trace), value = 2}, Item{trace = Ref.from(trace), value = 3}]
        \\    for item in values^ -> break
        \\    if trace == 321 -> return 42
        \\    return 90
    , 42);
}

test "List transfer is consumed even when the traversal is empty" {
    try Fixture.expectSourceDiagnostic(
        \\var values: List(int) = []
        \\for item in values^ -> ()
        \\print(values.len())
    , .use_after_transfer);
}

test "transferred Span keeps borrowed delivery and captured authority" {
    try expectCalculation(
        \\func calculate() int | none
        \\    var values = [20, 20]
        \\    var view = values.span()
        \\    for ref item in view^ -> item += 1
        \\    return values[0] + values[1]
    , 42);
}

fn expectCalculation(comptime source: []const u8, status: u8) !void {
    try Fixture.expectParity(source ++ "\n" ++
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 99
    , status);
}
