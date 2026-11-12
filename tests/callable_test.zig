const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;
const standard_library = @import("standard_library");
const queries = test_sources.queries;
const structures = test_sources.structures;

fn refusingFixture(source: []const u8) !Fixture {
    const fixture = try Fixture.init(source);
    errdefer fixture.deinit();
    const file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.callables))).*;
    const original = (try fixture.db.input(queries.SourceText, file)).*;
    const renamed = try std.mem.replaceOwned(u8, std.testing.allocator, original, "func reserve_environment(", "func reserve_initial_environment(");
    defer std.testing.allocator.free(renamed);
    const infallible_call = "EnvironmentReservation(Environment) -> reserve_environment(Environment)";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, renamed, infallible_call));
    const initial = try std.mem.replaceOwned(u8, std.testing.allocator, renamed, infallible_call, "EnvironmentReservation(Environment) -> reserve_initial_environment(Environment)");
    defer std.testing.allocator.free(initial);
    const refusing = try std.testing.allocator.print(
        "{s}\nfunc reserve_environment(static Environment: type) EnvironmentReservation(Environment) | AllocationError -> AllocationError.refused\n",
        .{initial},
    );
    defer std.testing.allocator.free(refusing);
    try fixture.db.setInput(queries.SourceText, file, refusing);
    return fixture;
}

fn expectRefusingParity(source: []const u8, status: u8) !void {
    for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }, 0..) |entry, index| {
        const program = try std.testing.allocator.print("{s}\n{s}", .{ source, entry });
        defer std.testing.allocator.free(program);
        const fixture = try refusingFixture(program);
        defer fixture.deinit();
        if (index == 0) {
            try fixture.expectExit(0, status);
        } else if ((try fixture.db.get(queries.BuildExecutable, 0)).* == null) {
            const controls = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.CompilerControl, std.testing.allocator);
            defer std.testing.allocator.free(controls);
            if (controls.len != 1) try fixture.printDiagnostics(0);
            try std.testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = status }}, controls);
        } else {
            try fixture.expectExit(0, status);
        }
    }
}

test "callable environments survive conditional and loop argument evaluation" {
    try Fixture.expectParity(
        \\struct Capture
        \\    copy = fieldwise
        \\    ref drops: int
        \\    value: int
        \\    drop = func(deinit self: Capture)
        \\        self.drops += 1
        \\struct Holder
        \\    callback: func(int) int
        \\func evaluate(ref drops: int, flag: bool) int
        \\    const capture = Capture{drops = drops, value = 2}
        \\    const concrete = (value: int) => value + capture.value
        \\    const stored: func(int) int = concrete
        \\    const holder = Holder{callback = concrete}
        \\    var index = 0
        \\    const first = concrete(loop
        \\        index += 1
        \\        if index < 2 -> continue
        \\        break 12
        \\    )
        \\    const second = stored(if flag -> 12 else 12)
        \\    const third = holder.callback(loop
        \\        index += 1
        \\        if index < 4 -> continue
        \\        break 12
        \\    )
        \\    return first + second + third
        \\func run() int
        \\    var drops = 0
        \\    const first = evaluate(drops, true)
        \\    if drops <> 4 -> return 1
        \\    const second = evaluate(drops, false)
        \\    if drops <> 8 -> return 2
        \\    return first + second - 42
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func make(offset: int) func(int) int -> (value) => value + offset
        \\func replace(mut callback: func(int) int) int
        \\    callback = make(9)
        \\    return 40
        \\func run() int
        \\    var callback = make(2)
        \\    return callback(replace(callback))
        \\exit(run())
    , .borrow_outlives_source);
}

test "joined nonowning callable cleanup does not invalidate referenced provider storage" {
    const selections = [_][]const u8{
        "const selected = if view.byte_length() == 3 -> first else second",
        "var selected = first\n    if view.byte_length() == 3 -> selected = second",
        "const selected = forward(if view.byte_length() == 3 -> first else second)",
        "const selected = pick(view.byte_length() == 3, first, second)",
        "const holder = Holder{callback = if view.byte_length() == 3 -> first else second}\n    const selected = holder.callback",
        "const holder = if view.byte_length() == 3 -> Holder{callback = first} else Holder{callback = second}\n    const selected = holder.callback",
        "const selected = wrap(view.byte_length() == 3, first, second).callback",
        "const selected = clone(pick(view.byte_length() == 3, first, second))?\n    const copied = selected\n    const moved = copied^",
    };
    for (selections) |selection| {
        const source = try std.testing.allocator.print(
            \\import std.callables.{{clone}}
            \\import std.memory.{{AllocationError}}
            \\struct Provider
            \\    copy = none
            \\    ref owner: String
            \\    func read(imm self: Provider) int -> self.owner.byte_length()
            \\struct Holder
            \\    callback: func() int
            \\func forward(callback: func() int) func() int -> callback
            \\func pick(flag: bool, first: func() int, second: func() int) func() int
            \\    return if flag -> first else second
            \\func wrap(flag: bool, first: func() int, second: func() int) Holder
            \\    return Holder{{callback = if flag -> first else second}}
            \\func evaluate() int | AllocationError
            \\    var owner: String = "abc"
            \\    const view = owner.view()
            \\    const provider = Provider{{owner = owner}}
            \\    const other = Provider{{owner = owner}}
            \\    const first: func() int = provider.read
            \\    const second: func() int = other.read
            \\    {s}
            \\    return view.byte_length() + 39
            \\func run() int
            \\    const result = evaluate()
            \\    if result is AllocationError -> return 1
            \\    return result
        , .{selection});
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
    try Fixture.expectSourceDiagnostic(
        \\struct Provider
        \\    ref owner: String
        \\    func grow(imm self: Provider)
        \\        if not (self.owner.append("x") is unit) -> return
        \\func run() int
        \\    var owner: String = "abc"
        \\    const view = owner.view()
        \\    const first_provider = Provider{owner = owner}
        \\    const second_provider = Provider{owner = owner}
        \\    const first: func() unit = first_provider.grow
        \\    const second: func() unit = second_provider.grow
        \\    const selected = if view.byte_length() == 3 -> first else second
        \\    selected()
        \\    return view.byte_length() + 39
        \\exit(run())
    , .borrow_outlives_source);
}

test "nonowning callable facts do not suppress owning cleanup after opaque replacement" {
    try Fixture.expectParity(
        \\struct Provider
        \\    value: int
        \\    func read(imm self: Provider) int -> self.value
        \\struct Capture
        \\    copy = fieldwise
        \\    ref drops: int
        \\    value: int
        \\    drop = func(deinit self: Capture)
        \\        self.drops += 1
        \\func replace(mut callback: func() int, ref drops: int)
        \\    const capture = Capture{drops = drops, value = 42}
        \\    callback = () => capture.value
        \\func evaluate(ref drops: int) int
        \\    const provider = Provider{value = 1}
        \\    var callback: func() int = provider.read
        \\    replace(callback, drops)
        \\    return callback()
        \\func run() int
        \\    var drops = 0
        \\    const result = evaluate(drops)
        \\    if drops <> 2 -> return 1
        \\    return result
    , 42);
    const nonowning_initializer = "var callback: func() int = provider.read";
    const replacements = [_]struct { mode: []const u8, argument: []const u8, result: []const u8, initializer: []const u8, drops: u32 }{
        .{ .mode = "mut", .argument = "callback", .result = "callback", .initializer = nonowning_initializer, .drops = 3 },
        .{ .mode = "deinit", .argument = "callback^", .result = "callback^", .initializer = nonowning_initializer, .drops = 2 },
        .{
            .mode = "deinit",
            .argument = "callback^",
            .result = "callback^",
            .initializer = "const old = Capture{drops = drops, value = 1}\n    var callback: func() int = () => old.value",
            .drops = 4,
        },
    };
    for (replacements) |replacement| {
        const source = try std.testing.allocator.print(
            \\struct Provider
            \\    value: int
            \\    func read(imm self: Provider) int -> self.value
            \\struct Capture
            \\    copy = fieldwise
            \\    ref drops: int
            \\    value: int
            \\    drop = func(deinit self: Capture)
            \\        self.drops += 1
            \\func replace({s} callback: func() int, ref drops: int) func() int
            \\    const capture = Capture{{drops = drops, value = 42}}
            \\    callback = () => capture.value
            \\    return {s}
            \\func evaluate(ref drops: int) int
            \\    const provider = Provider{{value = 1}}
            \\    {s}
            \\    const changed = replace({s}, drops)
            \\    return changed()
            \\func run() int
            \\    var drops = 0
            \\    const result = evaluate(drops)
            \\    if drops <> {d} -> return 1
            \\    return result
        , .{ replacement.mode, replacement.result, replacement.initializer, replacement.argument, replacement.drops });
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
    try Fixture.expectParity(
        \\struct Provider
        \\    value: int
        \\    func read(imm self: Provider) int -> self.value
        \\struct Holder
        \\    callback: func() int
        \\struct Capture
        \\    copy = fieldwise
        \\    ref drops: int
        \\    value: int
        \\    drop = func(deinit self: Capture)
        \\        self.drops += 1
        \\func replace(mut callback: func() int, ref drops: int)
        \\    const capture = Capture{drops = drops, value = 42}
        \\    callback = () => capture.value
        \\func wrap(callback: func() int, ref drops: int) Holder
        \\    var holder = Holder{callback = callback}
        \\    replace(holder.callback, drops)
        \\    return holder^
        \\func evaluate(ref drops: int) int
        \\    const provider = Provider{value = 1}
        \\    const changed = wrap(provider.read, drops)
        \\    return changed.callback()
        \\func run() int
        \\    var drops = 0
        \\    const result = evaluate(drops)
        \\    if drops <> 2 -> return 1
        \\    return result
    , 42);
}

test "opaque owning callable copy and cleanup retain captured referent writes" {
    try Fixture.expectSourceDiagnostic(
        \\struct Capture
        \\    ref owner: String
        \\    value: int
        \\    copy = func(imm self: Capture) Capture
        \\        if not (self.owner.append("x") is unit) -> panic("append failed")
        \\        return Capture{owner = self.owner, value = self.value}
        \\func forward(callback: func() int) func() int -> callback
        \\func run() int
        \\    var owner: String = "abc"
        \\    const capture = Capture{owner = owner, value = 42}
        \\    const first: func() int = () => capture.value
        \\    const second: func() int = () => capture.value + 1
        \\    const view = owner.view()
        \\    const copied = forward(if view.byte_length() > 0 -> first else second)
        \\    return view.byte_length()
        \\exit(run())
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\struct Capture
        \\    copy = fieldwise
        \\    ref owner: String
        \\    value: int
        \\    drop = func(deinit self: Capture)
        \\        if not (self.owner.append("x") is unit) -> panic("append failed")
        \\func discard(deinit callback: func() int)
        \\    return
        \\func run() int
        \\    var owner: String = "abc"
        \\    const capture = Capture{owner = owner, value = 42}
        \\    const callback: func() int = () => capture.value
        \\    const view = owner.view()
        \\    discard(callback^)
        \\    return view.byte_length()
        \\exit(run())
    , .borrow_outlives_source);
}

test "fallible callable refusal does not force initializers or copy captures" {
    try expectRefusingParity(
        \\import std.callables.{erase, clone}
        \\import std.memory.{AllocationError}
        \\struct Capture
        \\    ref copies: int
        \\    value: int
        \\    copy = func(imm self: Capture) Capture
        \\        self.copies += 1
        \\        return Capture{copies = self.copies, value = self.value}
        \\func run() int
        \\    var copies = 0
        \\    const capture = Capture{copies = copies, value = 40}
        \\    const rejected = erase(func() int, () => capture.value)
        \\    if not (rejected is AllocationError) -> return 1
        \\    if copies <> 0 -> return 2
        \\    const concrete = () => capture.value
        \\    const existing = erase(func() int, concrete^)
        \\    if not (existing is AllocationError) -> return 3
        \\    if copies <> 1 -> return 4
        \\    const callback: func() int = () => capture.value
        \\    const copied = clone(callback)
        \\    if not (copied is AllocationError) -> return 5
        \\    if copies <> 2 -> return 6
        \\    return callback() + copies
    , 42);
}

test "nonowning callable erase clone and transfer never reserve environments" {
    try expectRefusingParity(
        \\import std.callables.{erase, clone}
        \\import std.memory.{AllocationError}
        \\struct Provider
        \\    copy = none
        \\    value: int
        \\    func read(imm self: Provider) int -> self.value
        \\func named() int -> 10
        \\func run() int
        \\    var provider = Provider{value = 20}
        \\    const first = erase(func() int, provider.read)
        \\    if first is AllocationError -> return 1
        \\    const second = clone(first)
        \\    if second is AllocationError -> return 2
        \\    const ordinary = second
        \\    const moved = first^
        \\    const thin = erase(func() int, named)
        \\    if thin is AllocationError -> return 3
        \\    const empty = erase(func() int, () => 12)
        \\    if empty is AllocationError -> return 4
        \\    return ordinary() + moved() + thin() + empty() - 20
    , 42);
}

test "infallible callable copies panic on reservation refusal" {
    const source =
        \\const value = 42
        \\const first: func() int = () => value
        \\const second = first
        \\exit(second())
    ;
    const fixture = try refusingFixture(source);
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Callable environment allocation failed") != null);
}

test "fallible erase rejects already erased initializers in favor of clone" {
    try Fixture.expectAnySourceDiagnostic(
        \\import std.callables.{erase}
        \\const value = 42
        \\const callback: func() int = () => value
        \\const result = erase(func() int, callback)
        \\exit(0)
    , .callable_erasure_requires_concrete);
}

test "partial aggregate construction destroys completed callable environments" {
    try Fixture.expectParity(
        \\struct Capture
        \\    copy = fieldwise
        \\    ref drops: int
        \\    drop = func(deinit self: Capture) -> self.drops += 1
        \\struct Container
        \\    callback: func() int
        \\    later: int
        \\func partial(mut drops: int, stop: bool) int
        \\    const capture = Capture{drops = drops}
        \\    const result = Container{callback = () => capture.drops, later = if stop -> return 40 else 0}
        \\    return result.callback()
        \\func run() int
        \\    var drops = 0
        \\    const result = partial(drops, true)
        \\    return result + drops
    , 42);
}

test "owning callable collections retain writable captures without mutating owner storage" {
    try Fixture.expectParity(
        \\import std.memory.{List}
        \\func run() int
        \\    var value = 1
        \\    ref live = value
        \\    var callbacks = List(func() int).new(0)
        \\    if not (callbacks is List(func() int)) -> return 1
        \\    if not (callbacks.append(() => live += 20) is unit) -> return 2
        \\    if not (callbacks.append(() => live += 21) is unit) -> return 3
        \\    for ref callback in callbacks -> callback()
        \\    return value
    , 42);
}

test "owning erased callables run capture copy and destruction hooks exactly once" {
    try Fixture.expectParity(
        \\struct Capture
        \\    ref copies: int
        \\    ref drops: int
        \\    value: int
        \\    copy = func(imm self: Capture) Capture
        \\        self.copies += 1
        \\        return Capture{copies = self.copies, drops = self.drops, value = self.value + 1}
        \\    drop = func(deinit self: Capture) -> self.drops += self.value
        \\func exercise(mut copies: int, mut drops: int) int
        \\    const capture = Capture{copies = copies, drops = drops, value = 0}
        \\    const first: func() int = () => capture.value
        \\    const copied = first
        \\    const moved = first^
        \\    return copied() + moved()
        \\func run() int
        \\    var copies = 0
        \\    var drops = 0
        \\    const value = exercise(copies, drops)
        \\    return value + copies + drops + 34
    , 42);
}

test "owning erased callables construct and clone immovable environments" {
    try Fixture.expectParity(
        \\struct Pinned
        \\    move = none
        \\    copy = func(imm self: Pinned) Pinned -> Pinned{value = self.value}
        \\    value: int
        \\func run() int
        \\    const pinned = Pinned{value = 40}
        \\    const concrete = (value: int) => value + pinned.value
        \\    const stored: func(int) int = concrete
        \\    const copied = stored
        \\    const moved = stored^
        \\    return copied(1) + moved(1) - 40
    , 42);
}

test "nested owning callable copies preserve capture hooks and handle transfers skip moves" {
    try Fixture.expectParity(
        \\struct Capture
        \\    ref copies: int
        \\    ref moves: int
        \\    ref drops: int
        \\    value: int
        \\    copy = func(imm self: Capture) Capture
        \\        self.copies += 1
        \\        return Capture{copies = self.copies, moves = self.moves, drops = self.drops, value = self.value}
        \\    move = func(deinit self: Capture) Capture
        \\        self.moves += 1
        \\        return Capture{copies = self.copies, moves = self.moves, drops = self.drops, value = self.value}
        \\    drop = func(deinit self: Capture) -> self.drops += 1
        \\func exercise(mut copies: int, mut moves: int, mut drops: int) int
        \\    const capture = Capture{copies = copies, moves = moves, drops = drops, value = 20}
        \\    const inner: func() int = () => capture.value
        \\    const outer: func() int = () => inner()
        \\    const copied = outer
        \\    const moved = outer^
        \\    return copied() + moved()
        \\func run() int
        \\    var copies = 0
        \\    var moves = 0
        \\    var drops = 0
        \\    const result = exercise(copies, moves, drops)
        \\    if copies <> 3 or moves <> 0 or drops <> 4 -> return 90
        \\    return result + 2
    , 42);
}

test "owning erased callables survive fields arrays joins and collection growth" {
    try Fixture.expectParity(
        \\import std.memory.{List}
        \\struct Service
        \\    copy = fieldwise
        \\    callback: func(int) int
        \\func choose(flag: bool, offset: int) func(int) int
        \\    if flag -> return (value) => value + offset
        \\    return (value) => value * offset
        \\func run() int
        \\    const service = Service{callback = choose(true, 2)}
        \\    const copied = service
        \\    var callbacks = List(func(int) int).new(0)
        \\    if not (callbacks is List(func(int) int)) -> return 1
        \\    for offset in 1..3
        \\        if not (callbacks.append((value: int) => value + offset) is unit) -> return 2
        \\    if not (callbacks.append(choose(false, 2)) is unit) -> return 3
        \\    var total = 0
        \\    for ref callback in callbacks -> total += callback(10)
        \\    const array: Array(func(int) int, 2) = [copied.callback, choose(false, 1)]
        \\    return total + array[0](1) + array[1](1) - 5
    , 42);
}

test "owning erased callables preserve returned environment and captured references" {
    try Fixture.expectParity(
        \\func owned(value: int) func() ref int -> () => value
        \\func captured(ref value: int) func() ref int -> () => value
        \\func borrow_captured(ref value: int) ref int
        \\    const callback = captured(value)
        \\    return callback()
        \\func run() int
        \\    var callback = owned(20)
        \\    ref first = callback()
        \\    var value = 21
        \\    ref second = borrow_captured(value)
        \\    value += 1
        \\    return first + second
    , 42);
    try Fixture.expectParity(
        \\func make(value: int) func() ref int -> () => value
        \\func run() int
        \\    var original = make(21)
        \\    const copied = original
        \\    ref kept = copied()
        \\    original = make(9)
        \\    return kept + original() + 12
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func make(value: int) func() ref int -> () => value
        \\func run() int
        \\    var callback = make(42)
        \\    ref borrowed = callback()
        \\    callback = make(9)
        \\    return borrowed
        \\exit(run())
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\func bad() func() ref int
        \\    var value = 42
        \\    ref borrowed = value
        \\    return () => borrowed
        \\const callback = bad()
        \\exit(callback())
    , .borrow_outlives_source);
}

test "owning erased callables return copy and transfer captured environments" {
    try Fixture.expectParity(
        \\func make(offset: int) func(int) int -> (value) => value + offset
        \\func run() int
        \\    const first = make(2)
        \\    const copied = first
        \\    const moved = first^
        \\    return copied(20) + moved(18)
    , 42);
}

test "owning erased callables construct snapshots and preserve reference captures" {
    try Fixture.expectParity(
        \\func run() int
        \\    var offset = 5
        \\    const snapshot: func(int) int = (value) => value + offset
        \\    ref live = offset
        \\    const current: func(int) int = (value) => value + live
        \\    const copied = current
        \\    offset = 10
        \\    return snapshot(1) + copied(1) + 25
    , 42);
}

test "owning erased callables expose fallible deferred erasure and cloning" {
    try Fixture.expectParity(
        \\import std.callables.{erase, clone}
        \\import std.memory.{AllocationError}
        \\func run() int
        \\    const offset = 2
        \\    const first = erase(func(int) int, (value) => value + offset)
        \\    if first is AllocationError -> return 1
        \\    const copied = clone(first)
        \\    if copied is AllocationError -> return 2
        \\    return first(18) + copied(20)
    , 42);
}

test "implicit and fallible erasure reserve before moving concrete captures once" {
    const forms = [_][]const u8{
        "const stored: func() int = concrete^",
        "const stored = erase(func() int, concrete^)\n        if stored is AllocationError -> return 91",
        "const holder = Holder{callback = concrete}\n        const stored = moved_field(holder^)",
        "const stored = moved(concrete^) ",
        "const stored: (func() int) | none = concrete^\n        if stored is none -> return 92",
    };
    for (forms) |formation| {
        const source = try std.testing.allocator.print(
            \\import std.memory.{{Allocator, AllocationLayout, RawBlock, AllocationError, root_allocator}}
            \\import std.callables.{{erase}}
            \\struct Tracker
            \\    upstream: Allocator
            \\    ref events: int
            \\    pub func allocate(imm self: Tracker, layout: AllocationLayout) RawBlock | AllocationError
            \\        self.events = self.events * 10 + 1
            \\        return self.upstream.allocate(layout)
            \\    pub func deallocate(imm self: Tracker, deinit block: RawBlock)
            \\        self.upstream.deallocate(block^)
            \\struct Capture
            \\    copy = fieldwise
            \\    ref events: int
            \\    value: int
            \\    move = func(deinit self: Capture) Capture
            \\        self.events = self.events * 10 + 2
            \\        return Capture{{events = self.events, value = self.value + 1}}
            \\struct Holder(F: type)
            \\    move = fieldwise
            \\    callback: F
            \\func moved(static F: type, deinit callback: F) func() int -> callback^
            \\func moved_field(static F: type, deinit holder: Holder(F)) func() int -> holder.callback^
            \\func run() int
            \\    var events = 0
            \\    var tracker = Tracker{{upstream = root_allocator(), events = events}}
            \\    const capture = Capture{{events = events, value = 41}}
            \\    const concrete = () => capture.value
            \\    with context.allocator = Allocator.from(Tracker, tracker)
            \\        {s}
            \\        if stored() <> 42 -> return 90
            \\    if events <> 12 -> return 93
            \\    return 42
        , .{formation});
        defer std.testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "joined borrows keep every selectable owner alive until the join is used" {
    try Fixture.expectParity(
        \\func run() int
        \\    const factor = 3
        \\    const add: func(int) int = (value: int) => value + factor
        \\    const multiply: func(int) int = (value: int) => value * factor
        \\    const chosen = if factor > 10 -> add else multiply
        \\    return chosen(1) + (if factor > 10 -> add else multiply)(5)
    , 18);
    try Fixture.expectParity(
        \\struct Tracker
        \\    copy = fieldwise
        \\    ref drops: int
        \\    id: int
        \\    drop = func(deinit self: Tracker)
        \\        self.drops += 1
        \\func run() int
        \\    var drops = 0
        \\    const first = Tracker{drops = drops, id = 4}
        \\    const second = Tracker{drops = drops, id = 5}
        \\    const chosen = if drops == 0 -> first else second
        \\    return chosen.id
    , 4);
}
