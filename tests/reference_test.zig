const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "branch joins normalize transferred owners without disturbing shared availability pages" {
    const source = comptime block: {
        @setEvalBranchQuota(100_000);
        var declarations: []const u8 =
            \\struct Trace
            \\    value: int
            \\struct Item
            \\    copy = none
            \\    ref trace: Trace
            \\    value: int
            \\    drop = func(deinit self: Item) -> self.trace.value += 1
            \\func consume(var item: Item) -> return
            \\func probe(mut trace: Trace, flag: bool)
            \\
        ;
        for (0..32) |index| {
            declarations = declarations ++ std.fmt.comptimePrint("    var item{d} = Item{{trace = trace, value = 1}}\n", .{index});
        }
        declarations = declarations ++
            \\    if flag -> consume(item17^)
            \\    if trace.value <> 1 -> panic "join did not end exactly one owner"
            \\
        ;
        for (0..32) |index| {
            if (index == 17) continue;
            declarations = declarations ++ std.fmt.comptimePrint("    _ = item{d}.value\n", .{index});
        }
        break :block declarations ++
            \\func run() int
            \\    var trace = Trace{value = 0}
            \\    probe(trace, true)
            \\    if trace.value <> 32 -> return 90
            \\    trace.value = 0
            \\    probe(trace, false)
            \\    return trace.value + 10
        ;
    };
    try Fixture.expectParity(source, 42);
}

test "large nested calls preserve arguments across temporary storage growth" {
    const source = comptime block: {
        @setEvalBranchQuota(100_000);
        var declarations: []const u8 = "func identity(imm value: int) int -> value\nfunc total(";
        var arguments: []const u8 = "";
        for (0..96) |index| {
            const separator = if (index == 0) "" else ", ";
            declarations = declarations ++ std.fmt.comptimePrint("{s}imm argument{d}: int", .{ separator, index });
            arguments = arguments ++ std.fmt.comptimePrint("{s}identity({d})", .{ separator, index });
        }
        break :block declarations ++ ") int -> argument0 + argument95 - 53\nfunc run() int -> total(" ++ arguments ++ ")";
    };
    try Fixture.expectParity(source, 42);
}

test "forwarded borrow-carrying receivers keep their owned storage alive" {
    try Fixture.expectParity(
        \\struct Holder
        \\    copy = none
        \\    storage: Span(int) | List(int)
        \\
        \\    func view(imm self: Holder) Span(int)
        \\        match self.storage
        \\            Span(int) ->
        \\                const span = self.storage
        \\                return span
        \\            _ -> ()
        \\        match self.storage
        \\            List(int) ->
        \\                ref list = self.storage
        \\                return list.span()
        \\            _ -> ()
        \\        panic "invalid holder"
        \\
        \\    func forward(imm self: Holder) Span(int) -> self.view()
        \\
        \\func make() Holder
        \\    const values: List(int) = [5, 7, 9]
        \\    return Holder{storage = values^}
        \\
        \\func run() int
        \\    const holder = make()
        \\    const span = holder.forward()
        \\    const text = String(7).view()
        \\    match span.get(1)
        \\        first and first is int ->
        \\            match span.get(2)
        \\                second and second is int ->
        \\                    match text.as_bytes().get(0)
        \\                        digit and digit is byte -> return first + second + byte_int(digit) - 29
        \\                        _ -> ()
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "variant member conversions retain borrowed backing and reject its mutation" {
    const declarations =
        \\struct Marker
        \\converter(imm value: Marker) StringView -> "marker"
        \\func view(imm value: ref String | Marker) StringView -> value
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var text = "hello"
        \\    const source: ref String | Marker = text
        \\    const result = view(source)
        \\    const marker: ref String | Marker = Marker{}
        \\    if view(marker) <> "marker" -> return 90
        \\    if result <> "hello" -> return 91
        \\    return 42
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\var text = "hello"
        \\const source: ref String | Marker = text
        \\const result = view(source)
        \\const checked_value_1 = text.append(" world")
        \\if not (checked_value_1 is unit) -> panic "unexpected none"
        \\print(result)
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func escaped() StringView
        \\    var text = "hello"
        \\    const source: ref String | Marker = text
        \\    return view(source)
        \\print(escaped())
    , .borrow_outlives_source);
}

test "references copied optional call arguments remain independent in growing work queues" {
    try Fixture.expectParity(
        \\func must(static T: type, var outcome: T | none) T
        \\    match outcome^
        \\        value and value is T -> return value^
        \\        _ -> ()
        \\    panic "required operation failed"
        \\func calculate() int | none
        \\    var pending: List(int) = [1]
        \\    var head = 0
        \\    var total = 0
        \\    loop
        \\        if head == pending.len() -> break
        \\        const current = must(pending[head])
        \\        head += 1
        \\        total += current
        \\        if current < 4
        \\            const checked_value_1 = pending.append(current * 2)
        \\            if not (checked_value_1 is unit) -> return none
        \\            const checked_value_2 = pending.append(current * 2 + 1)
        \\            if not (checked_value_2 is unit) -> return none
        \\    return total + 14
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references owned optional argument preparation copies only successful payloads" {
    try Fixture.expectParity(
        \\struct Item
        \\    copies: Ref(int)
        \\    value: int
        \\    copy = func(imm self: Item) Item
        \\        self.copies.value += 1
        \\        return Item{copies = self.copies, value = self.value}
        \\func receive(var outcome: Item | none) int
        \\    match outcome^
        \\        item and item is Item -> return item.value
        \\        _ -> ()
        \\    return 0
        \\func run() int
        \\    var copies = 0
        \\    const values = [Item{copies = Ref.from(copies), value = 20}]
        \\    var total = 0
        \\    for index in 0..3 -> total += receive(values.get(index % 2))
        \\    return total + copies
    , 42);
}

test "references optional borrowed results still reject use across loop growth" {
    try Fixture.expectSourceDiagnostic(
        \\func must_ref(static T: type, var outcome: ref T | none) ref T
        \\    match outcome
        \\        T ->
        \\            ref value = outcome
        \\            return value
        \\        _ -> ()
        \\    panic "required element missing"
        \\var values: List(int) = [42]
        \\loop
        \\    ref current = must_ref(values[0])
        \\    const checked_value_1 = values.append(17)
        \\    if not (checked_value_1 is unit) -> panic "unexpected none"
        \\    print(current)
        \\    break
    , .borrow_outlives_source);
}

test "references copied optional view results retain their backing dependencies" {
    try Fixture.expectSourceDiagnostic(
        \\func must(static T: type, var outcome: T | none) T
        \\    match outcome^
        \\        value and value is T -> return value^
        \\        _ -> ()
        \\    panic "required operation failed"
        \\var text = "hello"
        \\var values: List(StringView) = [text.view()]
        \\loop
        \\    const current = must(StringView, values.get(0))
        \\    const checked_value_1 = text.append(" world")
        \\    if not (checked_value_1 is unit) -> panic "unexpected none"
        \\    print(current)
        \\    break
    , .borrow_outlives_source);
}

test "references custom drops preserve temporal conflicts between captures" {
    const declarations =
        \\struct Captures
        \\    left: Ref(String)
        \\    right: Ref(String)
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Captures)
        \\        const view = self.left.value.view()
        \\        if (self.right.value.append("x") is unit) -> ()
        \\        self.trace.value = view.byte_length() + 39
        \\func discard(var item: Captures) -> ()
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    var trace = 0
        \\    discard(Captures{left = Ref.from(left), right = Ref.from(right), trace = Ref.from(trace)})
        \\    return trace
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var buffer: String = "abc"
        \\    var trace = 0
        \\    discard(Captures{left = Ref.from(buffer), right = Ref.from(buffer), trace = Ref.from(trace)})
        \\    return trace
        \\_ = run()
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func calculate() int | none
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    const view = right.view()
        \\    var trace = 0
        \\    discard(Captures{left = Ref.from(left), right = Ref.from(right), trace = Ref.from(trace)})
        \\    return view.byte_length() + 39
        \\_ = run()
    , .borrow_outlives_source);
}

test "references custom drops enforce projected write authority and effects" {
    try Fixture.expectParity(
        \\struct Observer
        \\    owner: Ref(String)
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Observer)
        \\        self.trace.value += self.owner.value.byte_length()
        \\func discard(var observer: Observer) -> ()
        \\func calculate() int | none
        \\    var owner: String = "abc"
        \\    const view = owner.view()
        \\    var trace = 0
        \\    discard(Observer{owner = Ref.from(owner), trace = Ref.from(trace)})
        \\    return view.byte_length() + trace + 36
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Writer
        \\    target: Ref(int)
        \\    drop = func(deinit self: Writer) -> self.target.value += 1
        \\func discard(var writer: Writer) -> ()
        \\const target = 41
        \\discard(Writer{target = Ref.from(target)})
    , .reference_not_writable);
    inline for (.{
        .{ .clear = "hook.target = none", .clear_value = "true", .safe = true },
        .{ .clear = "_ = 0", .clear_value = "true", .safe = false },
        .{ .clear = "if clear\n        hook.target = none\n    else\n        hook.target = none", .clear_value = "true", .safe = true },
        .{ .clear = "if clear\n        hook.target = none\n    else\n        hook.target = none", .clear_value = "false", .safe = true },
        .{ .clear = "if clear -> hook.target = none", .clear_value = "false", .safe = false },
        .{ .clear = "if clear\n        _ = hook\n        return view.byte_length() + 39\n    hook.target = none", .clear_value = "true", .safe = false },
        .{ .clear = "loop\n        if not clear -> break\n        hook.target = none\n        clear = false", .clear_value = "false", .safe = false },
    }) |capture| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Hook
            \\    move = none
            \\    target: Ref(String) | none
            \\    drop = func(deinit self: Hook)
            \\        match self.target
            \\            Ref(String) ->
            \\                const target = self.target
            \\                const checked_value_1 = target.value.append("x")
            \\                if not (checked_value_1 is unit) -> panic "append failed"
            \\            _ -> ()
            \\func inspect(ref owner: String, ref clear: bool) int
            \\    const view = owner.view()
            \\    var hook = Hook{target = Ref.from(owner)}
            \\    $clear
            \\    _ = hook
            \\    return view.byte_length() + 39
            \\func calculate() int
            \\    var owner: String = "abc"
            \\    var clear = $clear_value
            \\    return inspect(owner, clear)
            \\func run() int
            \\    match calculate()
            \\        result -> return result
            \\    return 90
        , .{ .clear = capture.clear, .clear_value = capture.clear_value });
        defer std.testing.allocator.free(source);
        if (capture.safe) {
            try Fixture.expectParity(source, 42);
        } else {
            const executed = try std.mem.concat(std.testing.allocator, u8, &.{ source, "\n_ = run()" });
            defer std.testing.allocator.free(executed);
            try Fixture.expectAnySourceDiagnostic(executed, .borrow_outlives_source);
        }
    }
}

test "references ownership hooks export temporal writes at their call sites" {
    inline for (.{
        .{ .member = "copy", .mode = "imm", .transfer = "", .container = "Hook", .construct = "Hook{target = Ref.from(right)}" },
        .{ .member = "move", .mode = "deinit", .transfer = "^", .container = "Hook", .construct = "Hook{target = Ref.from(right)}" },
        .{ .member = "copy", .mode = "imm", .transfer = "", .container = "Wrapper", .construct = "Wrapper{value = Hook{target = Ref.from(right)}}" },
        .{ .member = "move", .mode = "deinit", .transfer = "^", .container = "Wrapper", .construct = "Wrapper{value = Hook{target = Ref.from(right)}}" },
        .{ .member = "copy", .mode = "imm", .transfer = "", .container = "(Hook, int)", .construct = "(Hook{target = Ref.from(right)}, 0)" },
        .{ .member = "move", .mode = "deinit", .transfer = "^", .container = "(Hook, int)", .construct = "(Hook{target = Ref.from(right)}, 0)" },
        .{ .member = "copy", .mode = "imm", .transfer = "", .container = "Array(Hook, 1)", .construct = "[Hook{target = Ref.from(right)}]" },
        .{ .member = "move", .mode = "deinit", .transfer = "^", .container = "Array(Hook, 1)", .construct = "[Hook{target = Ref.from(right)}]" },
        .{ .member = "copy", .mode = "imm", .transfer = "", .container = "Hook | none", .construct = "Hook{target = Ref.from(right)}" },
        .{ .member = "move", .mode = "deinit", .transfer = "^", .container = "Hook | none", .construct = "Hook{target = Ref.from(right)}" },
    }) |hook| {
        const declarations = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Hook
            \\    target: Ref(String)
            \\    $member = func($mode self: Hook) Hook
            \\        if not (self.target.value.append("x") is unit) -> panic "append failed"
            \\        return Hook{target = self.target}
            \\struct Wrapper
            \\    $member = fieldwise
            \\    value: Hook
            \\func consume(var hook: $container) -> ()
            \\func inspect(ref left: String, ref right: String) int
            \\    const view = left.view()
            \\    const hook: $container = $construct
            \\    consume(hook$transfer)
            \\    return view.byte_length() + 39
            \\func run() int
            \\    const result = calculate()
            \\    if result is int -> return result
            \\    return 90
        , hook);
        defer std.testing.allocator.free(declarations);
        const unrelated = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\func calculate() int | none
            \\    var left: String = "abc"
            \\    var right: String = ""
            \\    return inspect(left, right)
        });
        defer std.testing.allocator.free(unrelated);
        try Fixture.expectParity(unrelated, 42);
        const aliased = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\func calculate() int | none
            \\    var buffer: String = "abc"
            \\    return inspect(buffer, buffer)
            \\_ = run()
        });
        defer std.testing.allocator.free(aliased);
        try Fixture.expectAnySourceDiagnostic(aliased, .borrow_outlives_source);
    }
}

test "reference result mode borrows the complete variant" {
    try Fixture.expectParity(
        \\func select(ref owner: int | none) ref (int | none) -> owner
        \\func run() int
        \\    var owner: int | none = 12
        \\    ref selected = select(owner)
        \\    match selected
        \\        int ->
        \\            ref item = selected
        \\            item += 30
        \\        _ -> ()
        \\    match owner
        \\        int ->
        \\            const result = owner
        \\            return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "callable widening preserves reference result contracts" {
    for ([_][]const u8{
        \\func source(ref value: int) int -> value
        \\func accept(callback: func(ref int) ref int) -> ()
        \\accept(source)
        ,
        \\func source(ref value: int) ref int -> value
        \\func accept(callback: func(ref int) int) -> ()
        \\accept(source)
        ,
    }) |source| try Fixture.expectSourceDiagnostic(source, .call_argument_type_mismatch);
    try Fixture.expectParity(
        \\func identity(ref value: int) ref int -> value
        \\func run() int
        \\    var source = 19
        \\    const callback: func(ref int) ref int = identity
        \\    ref result = callback(source)
        \\    result += 23
        \\    return source
    , 42);
}

test "references readonly borrows preserve owner cleanup authority" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\func calculate(var trace: Ref(int)) int | none
        \\    const owner = Box.new(Item{trace = trace, value = 2})
        \\    if not (owner is Box(Item)) -> return none
        \\    return owner.borrow().value + 38
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if not (trace is Array(int, 1)) -> panic "unexpected none"
        \\    match trace.get(0)
        \\        ref _matched_target and _matched_target is int ->
        \\            ref target = _matched_target
        \\            match calculate(Ref.from(target))
        \\                value and value is int -> return value + target
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references preserve binding permissions after whole-local assignment" {
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    owner = 20
        \\    ref item = owner
        \\    item += 22
        \\    return owner
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func update(owner: int)
        \\    var copy = owner
        \\    copy = 20
        \\    ref item = owner
        \\    item = copy
        \\update(12)
    , .reference_not_writable);
}

test "references local aliases preserve address across loops and copies read the current value" {
    try Fixture.expectParity(
        \\func identity(ref value: int) ref int -> value
        \\func run() int
        \\    var owner = 12
        \\    ref item = identity(owner)
        \\    const snapshot = item
        \\    var count = 0
        \\    loop
        \\        if count == 3 -> break
        \\        item += 10
        \\        count += 1
        \\    if snapshot <> 12 -> return 90
        \\    return owner
    , 42);
}

test "references callable values preserve borrowed parameter and result contracts" {
    try Fixture.expectParity(
        \\func identity(ref value: int) ref int -> value
        \\func run() int
        \\    const select: func(ref int) ref int = identity
        \\    var owner = 12
        \\    ref item = select(owner)
        \\    item += 30
        \\    return owner
    , 42);
}

test "references generic handles own only their reference field" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\struct Handle(T: type)
        \\    copy = trivial
        \\    pub ref value: T
        \\    pub func from(ref item: T) Handle(T) -> Handle(T){value = item}
        \\func run() int
        \\    var owner = 11
        \\    var first = Handle.from(owner)
        \\    var second = first
        \\    second.value += 10
        \\    var explicit = Ref.from(first.value)
        \\    explicit.value *= 2
        \\    return owner
    , 42);
}

test "references array and list lookups preserve earlier element borrows" {
    try Fixture.expectParity(
        \\func compute() int | none
        \\    var array = [1, 2]
        \\    ref first = array[0]
        \\    ref second = array[1]
        \\    first += 9
        \\    second += 8
        \\    var list: List(int) = [1, 2]
        \\    const checked_value_1 = list.get(0)
        \\    if not (checked_value_1 is int) -> return none
        \\    ref third = checked_value_1
        \\    const checked_value_2 = list.get(1)
        \\    if not (checked_value_2 is int) -> return none
        \\    ref fourth = checked_value_2
        \\    third += 10
        \\    fourth += 9
        \\    return first + second + third + fourth
        \\func run() int
        \\    match compute()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references conditional payload borrows and mutable calls preserve ownership" {
    try Fixture.expectParity(
        \\struct Payload
        \\    pub value: int
        \\func update(mut value: int) -> value += 30
        \\func run() int
        \\    var owner: Payload | none = Payload{value = 12}
        \\    match owner
        \\        Payload ->
        \\            ref payload = owner
        \\            update(payload.value)
        \\        _ -> ()
        \\    match owner
        \\        Payload ->
        \\            ref result = owner
        \\            return result.value
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references borrowed func results bind conditionally without copying" {
    try Fixture.expectParity(
        \\struct Payload
        \\    pub value: int
        \\func select(ref owner: Payload, index: int) ref Payload | none
        \\    if not (index == 0) -> return none
        \\    return owner
        \\func run() int
        \\    var owner = Payload{value = 12}
        \\    match select(owner, 0)
        \\        ref _matched_item and _matched_item is Payload ->
        \\            ref item = _matched_item
        \\            item.value += 30
        \\        _ -> ()
        \\    match select(owner, 1)
        \\        ref _matched_absent and _matched_absent is Payload ->
        \\            ref absent = _matched_absent
        \\            return 90
        \\        _ -> ()
        \\    return owner.value
    , 42);
}

test "references variant alternatives capture existing places" {
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: int) ref int | End -> value
        \\func run() int
        \\    var owner = 17
        \\    const result = capture(owner)
        \\    match result
        \\        int ->
        \\            ref selected = result
        \\            selected += 25
        \\        _ -> return 90
        \\    return owner
    , 42);
}

test "references variant captures retain independent referent lifetime" {
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: int) ref int | End -> value
        \\func selected(ref value: int) ref int
        \\    const carrier = capture(value)
        \\    match carrier
        \\        int ->
        \\            ref result = carrier
        \\            return result
        \\        _ -> ()
        \\    return value
        \\func run() int
        \\    var owner = 17
        \\    ref result = selected(owner)
        \\    result += 25
        \\    return owner
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\struct End
        \\    copy = trivial
        \\func invalid() ref int | End
        \\    var local = 42
        \\    return local
        \\_ = invalid()
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: int) ref int | End -> value
        \\const owner = 17
        \\const carrier = capture(owner)
        \\match carrier
        \\    int ->
        \\        ref result = carrier
        \\        result += 25
        \\    _ -> ()
    , .reference_not_writable);
}

test "references variant construction rejects ambiguous storage selection" {
    try Fixture.expectAnySourceDiagnostic(
        \\func invalid(ref value: int) int | ref int -> value
        \\var owner = 42
        \\_ = invalid(owner)
    , .ambiguous_variant_member);
    try Fixture.expectParity(
        \\func owned() int | ref int -> 42
        \\func run() int
        \\    const carrier = owned()
        \\    match carrier
        \\        int ->
        \\            ref result = carrier
        \\            return result
    , 42);
}

test "references variant logical matching aliases either storage kind" {
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: int) ref int | End -> value
        \\func choose(ref value: int, borrowed: bool) int | ref int | End
        \\    if borrowed -> return capture(value)
        \\    return 17
        \\func update(ref value: int, borrowed: bool) int
        \\    var carrier = choose(value, borrowed)
        \\    match carrier
        \\        int ->
        \\            ref selected = carrier
        \\            selected += 25
        \\            return selected
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    var owner = 17
        \\    if update(owner, true) <> 42 -> return 91
        \\    if update(owner, false) <> 42 -> return 92
        \\    return owner
    , 42);
}

test "references variant owning matches copy reference referents" {
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: int) ref int | End -> value
        \\func run() int
        \\    var owner = 17
        \\    match capture(owner)
        \\        selected and selected is int ->
        \\            var copied = selected
        \\            copied += 25
        \\            if owner <> 17 -> return 90
        \\            return copied
        \\        _ -> ()
        \\    return 91
    , 42);
}

test "references variant union matches copy logical reference payloads" {
    try Fixture.expectParity(
        \\func capture(ref value: int, present: bool) ref int | none
        \\    if present -> return value
        \\    return none
        \\func inspect(ref owner: int, present: bool) int
        \\    const carrier: ref int | none = capture(owner, present)
        \\    match carrier
        \\        int | none ->
        \\            const selected = carrier
        \\            match selected
        \\                int ->
        \\                    const value = selected
        \\                    return value + 25
        \\                _ -> ()
        \\            return 42
        \\func run() int
        \\    var owner = 17
        \\    if inspect(owner, true) <> 42 -> return 91
        \\    return inspect(owner, false)
    , 42);
    try Fixture.expectParity(
        \\func produce(first: bool) none | Array(int, 3) | int
        \\    if first -> return [10, 11, 21]
        \\    return 42
        \\func inspect(first: bool) int
        \\    match produce(first)
        \\        selected and selected is Array(int, 3) | int ->
        \\            match selected
        \\                int ->
        \\                    const number = selected
        \\                    return number
        \\                _ -> ()
        \\            match selected
        \\                Array(int, 3) ->
        \\                    ref values = selected
        \\                    match values.get(2)
        \\                        last and last is int -> return last + 21
        \\                        _ -> ()
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
        \\func run() int
        \\    if inspect(true) <> 42 -> return 91
        \\    return inspect(false)
    , 42);
}

test "references typed tuples preserve member storage and authority" {
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 17
        \\    const other = 5
        \\    const pair: (ref int, int) = (owner, other)
        \\    pair.0 += 25
        \\    return owner
    , 42);
}

test "references contextual tuple construction permits unrelated reference alternatives" {
    try Fixture.expectParity(
        \\func run() int
        \\    const pair: (int, int) | ref bool = (19, 23)
        \\    match pair
        \\        (int, int) ->
        \\            const selected = pair
        \\            return selected.0 + selected.1
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references readonly recursive owners preserve captured authority when forwarded" {
    try Fixture.expectParity(
        \\struct Node
        \\    next: Box(Node) | none
        \\    target: Ref(int)
        \\func update(ref node: Node) -> node.target.value += 1
        \\func forward(imm node: Node) -> update(node)
        \\func run() int
        \\    var target = 41
        \\    const node = Node{next = none, target = Ref.from(target)}
        \\    forward(node)
        \\    return target
    , 42);
}

test "references retain nested readonly authority through looped forwarding and edits" {
    const declarations =
        \\struct Holder
        \\    target: Ref(int)
        \\func update(imm handle: Ref(Holder))
        \\    var current = handle
        \\    var remaining = 2
        \\    loop
        \\        if remaining == 0 -> break
        \\        current.value.target.value += 1
        \\        current = handle
        \\        remaining -= 1
        \\func run() int
        \\    var target = 40
        \\    var owner = Holder{target = Ref.from(target)}
        \\    const handle = Ref.from(owner)
        \\    update(handle)
        \\    return target
    ;
    try Fixture.expectParity(declarations, 42);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{declarations});
    defer std.testing.allocator.free(source);
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const readonly_owner = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var owner =", "const owner =");
    defer std.testing.allocator.free(readonly_owner);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, readonly_owner);
    try fixture.expectDiagnostic(0, .reference_not_writable);

    const readonly_target = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var target = 40", "const target = 40");
    defer std.testing.allocator.free(readonly_target);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, readonly_target);
    try fixture.expectDiagnostic(0, .reference_not_writable);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "references readonly recursive owners cannot upgrade owned views" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Node
        \\    next: Box(Node) | none
        \\    view: Span(int) | none
        \\func selected(ref node: Node) Span(int)
        \\    match node.next
        \\        Box(Node) ->
        \\            ref next = node.next
        \\            return selected(next.borrow())
        \\        _ -> ()
        \\    match node.view
        \\        Span(int) ->
        \\            const view = node.view
        \\            return view
        \\        _ -> ()
        \\    panic
        \\func forward(imm node: Node) Span(int) -> selected(node)
        \\func calculate() unit | none
        \\    var values = [41]
        \\    var leaf = Box.new(Node{next = none, view = values.span()})
        \\    if not (leaf is Box(Node)) -> return none
        \\    const root = Node{next = leaf^, view = none}
        \\    var view = forward(root)
        \\    view[0] = 42
        \\    return ()
        \\if (calculate() is unit) -> ()
    , .reference_not_writable);
}

test "references readonly recursive owners return writable captured handles" {
    try Fixture.expectParity(
        \\struct Node
        \\    next: Box(Node) | none
        \\    target: Ref(int)
        \\func selected(ref node: Node) Ref(int)
        \\    match node.next
        \\        Box(Node) ->
        \\            ref next = node.next
        \\            return selected(next.borrow())
        \\        _ -> ()
        \\    return node.target
        \\func forward(imm node: Node) Ref(int) -> selected(node)
        \\func calculate() int | none
        \\    var target = 41
        \\    var leaf = Box.new(Node{next = none, target = Ref.from(target)})
        \\    if not (leaf is Box(Node)) -> return none
        \\    const root = Node{next = leaf^, target = Ref.from(target)}
        \\    const handle = forward(root)
        \\    handle.value += 1
        \\    return target
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references recursive parameter outputs retain replacement authority and lifetime" {
    const source =
        \\struct Node
        \\    next: Box(Node) | none
        \\    target: Ref(int)
        \\func replace(ref node: Node, ref source: int)
        \\    match node.next
        \\        Box(Node) ->
        \\            ref next = node.next
        \\            replace(next.borrow(), source)
        \\        _ ->
        \\            node.target = Ref.from(source)
        \\func selected(ref node: Node) Ref(int)
        \\    match node.next
        \\        Box(Node) ->
        \\            ref next = node.next
        \\            return selected(next.borrow())
        \\        _ -> ()
        \\    return node.target
        \\func calculate() int | none
        \\    var original = 0
        \\    var replacement = 41
        \\    var leaf = Box.new(Node{next = none, target = Ref.from(original)})
        \\    if not (leaf is Box(Node)) -> return none
        \\    var root = Node{next = leaf^, target = Ref.from(original)}
        \\    replace(root, replacement)
        \\    const handle = selected(root)
        \\    handle.value += 1
        \\    return replacement
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    ;
    try Fixture.expectParity(source, 42);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source ++ "\nexit(run())", "var replacement", "const replacement");
    defer std.testing.allocator.free(readonly);
    try Fixture.expectAnySourceDiagnostic(readonly, .reference_not_writable);
    const expired = try std.mem.replaceOwned(u8, std.testing.allocator, source ++ "\nexit(run())", "replace(root, replacement)",
        \\if 1 == 1
        \\        var temporary = 41
        \\        replace(root, temporary)
    );
    defer std.testing.allocator.free(expired);
    try Fixture.expectAnySourceDiagnostic(expired, .borrow_outlives_source);
}

test "references generic borrowed zip preserves independent tuple captures" {
    const declarations =
        \\struct End
        \\    copy = trivial
        \\struct Left
        \\    copy = none
        \\    pub value: int
        \\struct Right
        \\    copy = none
        \\    pub value: int
        \\struct Cursor(T: type)
        \\    source: Ref(T)
        \\    ready: bool
        \\    func next(mut self: Cursor(T)) ref T | End
        \\        if not self.ready -> return End{}
        \\        self.ready = false
        \\        return self.source.value
        \\struct Zip(L: type, R: type, A: type, B: type)
        \\    left: L
        \\    right: R
        \\    func next(mut self: Zip(L, R, A, B)) (ref A, ref B) | End
        \\        const left_result = self.left.next()
        \\        match left_result
        \\            A ->
        \\                ref left_item = left_result
        \\                const right_result = self.right.next()
        \\                match right_result
        \\                    B ->
        \\                        ref right_item = right_result
        \\                        var pair: (ref A, ref B) = (left_item, right_item)
        \\                        return pair^
        \\                    _ -> ()
        \\            _ -> ()
        \\        return End{}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var left = Left{value = 12}
        \\    const right = Right{value = 7}
        \\    var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\    const result = zipped.next()
        \\    match result
        \\        (Left, Right) ->
        \\            ref pair = result
        \\            pair.0.value += 30
        \\            if pair.1.value <> 7 -> return 90
        \\            if zipped.next() is End -> return left.value
        \\        _ -> ()
        \\    return 91
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\var left = Left{value = 12}
        \\const right = Right{value = 7}
        \\var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\const result = zipped.next()
        \\match result
        \\    (Left, Right) ->
        \\        ref pair = result
        \\        pair.1.value += 1
        \\    _ -> ()
    , .reference_not_writable);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func first(ref left: Left) ref Left
        \\    const right = Right{value = 7}
        \\    var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\    const result = zipped.next()
        \\    match result
        \\        (Left, Right) ->
        \\            const pair = result
        \\            return pair.0
        \\        _ -> ()
        \\    exit(90)
        \\func run() int
        \\    var left = Left{value = 12}
        \\    ref selected = first(left)
        \\    selected.value += 30
        \\    return left.value
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const left = Left{value = 7}
        \\    var right = Right{value = 12}
        \\    var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\    const result = zipped.next()
        \\    match result
        \\        (Left, Right) ->
        \\            const pair = result
        \\            if pair.0.value <> 7 -> return 90
        \\            pair.1.value += 30
        \\            return right.value
        \\        _ -> ()
        \\    return 91
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\const left = Left{value = 7}
        \\var right = Right{value = 12}
        \\var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\const result = zipped.next()
        \\match result
        \\    (Left, Right) ->
        \\        const pair = result
        \\        pair.0.value += 1
        \\    _ -> ()
    , .reference_not_writable);
}

test "references tuples own cleanup only for owned members" {
    try Fixture.expectParity(
        \\struct Tracked
        \\    value: int
        \\    effects: Ref(int)
        \\    copy = func(imm self: Tracked) Tracked
        \\        self.effects.value += 1
        \\        return Tracked{value = self.value, effects = self.effects}
        \\    drop = func(deinit self: Tracked) -> self.effects.value += 10
        \\func exercise(ref owner: Tracked)
        \\    const pair: (ref Tracked, Tracked) = (owner, owner)
        \\    const copied = pair
        \\    _ = copied.0.value
        \\    _ = copied.1.value
        \\func run() int
        \\    var effects = 0
        \\    var owner = Tracked{value = 17, effects = Ref.from(effects)}
        \\    exercise(owner)
        \\    const result = effects + 20
        \\    _ = owner.value
        \\    return result
    , 42);
    try Fixture.expectAnySourceDiagnostic(
        \\struct Item
        \\    copy = none
        \\    value: int
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: Item) ref Item | End -> value
        \\var owner = Item{value = 42}
        \\const result = capture(owner)
        \\match result
        \\    Item ->
        \\        const copied = result
        \\        exit(copied.value)
        \\    _ -> ()
    , .type_not_copyable);
}

test "references separate union alternatives do not become a whole union borrow" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct End
        \\    copy = trivial
        \\func choose(ref number: int, ref flag: bool, first: bool) ref int | ref bool | End
        \\    if first -> return number
        \\    return flag
        \\func run() int
        \\    var number = 42
        \\    var flag = false
        \\    match choose(number, flag, true)
        \\        ref _matched_item and _matched_item is int | bool ->
        \\            ref item = _matched_item
        \\            return 1
        \\        _ -> ()
        \\    return 0
        \\_ = run()
    , .reference_projection_requires_member);
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref owner: int | bool) ref (int | bool) | End -> owner
        \\func run() int
        \\    var owner: int | bool = true
        \\    const carrier = capture(owner)
        \\    match carrier
        \\        int | bool ->
        \\            ref item = carrier
        \\            item = 42
        \\        _ -> ()
        \\    match owner
        \\        int ->
        \\            const item = owner
        \\            return item
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references logical payload borrows do not retain temporary carriers" {
    const declarations =
        \\func capture(ref owner: int) ref int | End -> owner
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func selected(ref owner: int) ref int
        \\    match capture(owner)
        \\        ref _matched_item and _matched_item is int ->
        \\            ref item = _matched_item
        \\            return item
        \\        _ -> ()
        \\    exit(90)
        \\func run() int
        \\    var owner = 12
        \\    ref item = selected(owner)
        \\    item += 30
        \\    return owner
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func selected(ref owner: int) ref int
        \\    var carrier: ref int | End = owner
        \\    match carrier
        \\        int ->
        \\            ref item = carrier
        \\            carrier = End{}
        \\            return item
        \\        _ -> ()
        \\    exit(90)
        \\func run() int
        \\    var owner = 12
        \\    ref item = selected(owner)
        \\    item += 30
        \\    return owner
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\const owner = 12
        \\match capture(owner)
        \\    ref _matched_item and _matched_item is int ->
        \\        ref item = _matched_item
        \\        item += 30
        \\    _ -> ()
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() ref int
        \\    var owner = 12
        \\    match capture(owner)
        \\        ref _matched_item and _matched_item is int ->
        \\            ref item = _matched_item
        \\            return item
        \\        _ -> ()
        \\    exit(90)
        \\_ = invalid()
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(
        \\var carrier: int | End = 12
        \\match carrier
        \\    int ->
        \\        ref item = carrier
        \\        carrier = End{}
        \\        exit(item)
        \\    _ -> ()
    , .borrow_outlives_source);
}

test "references tuples keep readonly captures through copies" {
    try Fixture.expectAnySourceDiagnostic(
        \\const owner = 17
        \\const pair: (ref int, int) = (owner, 5)
        \\var copied = pair
        \\copied.0 += 25
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(
        \\var owner = 17
        \\const pair: (ref int, int) = (owner, 5)
        \\pair.1 += 25
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(
        \\func invalid() (ref int, int)
        \\    var local = 42
        \\    return (local, 7)
        \\_ = invalid()
    , .borrow_outlives_source);
}

test "references const carriers preserve captured referent authority" {
    try Fixture.expectParity(
        \\func update(ref handle: Ref(int)) -> handle.value += 10
        \\func forward(ref handle: Ref(int)) Ref(int) -> handle
        \\func run() int
        \\    var owner = 12
        \\    const first = Ref.from(owner)
        \\    if not (first is Ref(int)) -> panic "unexpected none"
        \\    first.value += 10
        \\    const second = first
        \\    update(second)
        \\    const third = forward(second)
        \\    third.value += 10
        \\    return owner
    , 42);
}

test "references const aggregate copies preserve independent reference and storage permissions" {
    try Fixture.expectParity(
        \\struct Mixed
        \\    copy = trivial
        \\    pub target: Ref(int)
        \\    pub view: Span(int)
        \\func run() int
        \\    var owner = 12
        \\    var values = [1]
        \\    const original = Mixed{target = Ref.from(owner), view = values.span()}
        \\    var copied = original
        \\    copied.target.value += 30
        \\    return owner
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Mixed
        \\    copy = trivial
        \\    pub target: Ref(int)
        \\    pub view: Span(int)
        \\func invalid() unit | none
        \\    var owner = 12
        \\    var values = [1]
        \\    const original = Mixed{target = Ref.from(owner), view = values.span()}
        \\    var copied = original
        \\    const checked_value_1 = copied.view.get(0)
        \\    if not (checked_value_1 is int) -> return none
        \\    ref item = checked_value_1
        \\    item = 42
        \\    return ()
        \\if (invalid() is unit) -> unit
    , .reference_not_writable);
}

test "references const aggregate copies preserve array and variant captures" {
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    const original = [Ref.from(owner)]
        \\    var copied = original
        \\    match copied.get(0)
        \\        ref _matched_handle and _matched_handle is Ref(int) ->
        \\            ref handle = _matched_handle
        \\            handle.value += 30
        \\        _ -> ()
        \\    return owner
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    const original: Ref(int) | none = Ref.from(owner)
        \\    var copied = original
        \\    match copied
        \\        Ref(int) ->
        \\            ref handle = copied
        \\            handle.value += 30
        \\        _ -> ()
        \\    return owner
    , 42);
}

test "references readonly source cannot acquire writable access through a mutable handle" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\const source = 12
        \\var handle = Ref.from(source)
        \\handle.value = 42
    , .reference_not_writable);
}

test "references copying a handle captured from a readonly source keeps readonly authority" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\const source = 12
        \\const first = Ref.from(source)
        \\var second = first
        \\second.value = 42
    , .reference_not_writable);
}

test "references readonly handle fields preserve permission in conditional borrows" {
    try Fixture.expectSourceDiagnostic(
        \\const source: int | none = 42
        \\const handle = Ref.from(source)
        \\match handle.value
        \\    int ->
        \\        ref item = handle.value
        \\        item += 1
        \\    _ -> ()
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\const source: int | none = 42
        \\const readonly = Ref.from(source)
        \\var handle = readonly
        \\match handle.value
        \\    int ->
        \\        ref item = handle.value
        \\        item += 1
        \\    _ -> ()
    , .reference_not_writable);
    try Fixture.expectParity(
        \\func run() int
        \\    var source: int | none = 41
        \\    const handle = Ref.from(source)
        \\    if not (handle is Ref(int | none)) -> panic "unexpected none"
        \\    match handle.value
        \\        int ->
        \\            ref item = handle.value
        \\            item += 1
        \\        _ -> ()
        \\    match source
        \\        int ->
        \\            ref item = source
        \\            return item
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references local storage cannot escape as a borrowed result or reference field" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() ref int
        \\    var local = 42
        \\    return local
        \\const result = invalid()
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func invalid() Ref(int)
        \\    var local = 42
        \\    return Ref.from(local)
        \\const result = invalid()
    , .borrow_outlives_source);
}

test "references an owned result cannot be captured as a reference" {
    try Fixture.expectSourceDiagnostic(
        \\func fresh() int -> 42
        \\ref invalid = fresh()
    , .borrow_requires_place);
}

test "references annotations preserve the original place for noncopyable values" {
    try Fixture.expectParity(
        \\struct Payload
        \\    copy = none
        \\    pub value: int
        \\func run() int
        \\    var owner = Payload{value = 12}
        \\    ref item: Payload = owner
        \\    item.value += 30
        \\    return owner.value
    , 42);
}

test "references mutable parameters return the original caller storage" {
    try Fixture.expectParity(
        \\func select(mut value: int) ref int
        \\    value += 10
        \\    return value
        \\func run() int
        \\    var owner = 12
        \\    ref item = select(owner)
        \\    item += 20
        \\    return owner
    , 42);
}

test "references ownership cannot be transferred from a local alias or reference field" {
    try Fixture.expectSourceDiagnostic(
        \\var owner = 42
        \\ref alias = owner
        \\const moved = alias^
    , .ownership_transfer_requires_owned_place);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\var owner = 42
        \\var handle = Ref.from(owner)
        \\const moved = handle.value^
    , .ownership_transfer_requires_owned_place);
}

test "references readonly attenuation through a helper is preserved at its call site" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func readonly(ref value: int) Ref(int)
        \\    const captured = Ref.from(value)
        \\    return captured
        \\const source = 12
        \\var result = readonly(source)
        \\result.value = 42
    , .reference_not_writable);
}

test "references readonly spans cannot grant writable element access" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() unit | none
        \\    var owner = [12]
        \\    var view = owner.span().as_imm()
        \\    ref item = view[0]
        \\    item = 42
        \\    return ()
        \\if (invalid() is unit) -> unit
    , .reference_not_writable);
}

test "references returning a referent does not capture an intermediate handle owner" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func referent(ref handle: Ref(int)) ref int -> handle.value
        \\func capture(ref owner: int) Ref(int)
        \\    var temporary = Ref.from(owner)
        \\    if not (temporary is Ref(int)) -> panic "unexpected none"
        \\    return Ref.from(referent(temporary))
        \\func run() int
        \\    var owner = 12
        \\    var result = capture(owner)
        \\    result.value += 30
        \\    return owner
    , 42);
}

test "references returned origin excludes unrelated reference arguments" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func first(ref left: int, ref right: int) ref int -> left
        \\func capture(ref source: int) Ref(int)
        \\    var unrelated = 90
        \\    return Ref.from(first(source, unrelated))
        \\func run() int
        \\    var source = 12
        \\    var result = capture(source)
        \\    result.value += 30
        \\    return source
    , 42);
}

test "references helper writes respect the captured referent permission" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func update(mut handle: Ref(int)) -> handle.value += 30
        \\const source = 12
        \\var handle = Ref.from(source)
        \\update(handle)
    , .reference_not_writable);
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func update(mut handle: Ref(int)) -> handle.value += 30
        \\func run() int
        \\    var source = 12
        \\    var handle = Ref.from(source)
        \\    if not (handle is Ref(int)) -> panic "unexpected none"
        \\    update(handle)
        \\    return source
    , 42);
}

test "references containers of handles expose the handle slot and copy only its contents" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func capture(ref source: int) Ref(int) | none
        \\    var handles = [Ref.from(source)]
        \\    ref slot = handles[0]
        \\    slot.value += 10
        \\    return handles[0]
        \\func calculate() int | none
        \\    var source = 12
        \\    var copied = capture(source)
        \\    if not (copied is Ref(int)) -> return none
        \\    copied.value += 20
        \\    return source
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references variant payload aliases cannot survive a changed active tag" {
    try Fixture.expectSourceDiagnostic(
        \\struct Payload
        \\    pub value: int
        \\var owner: Payload | none = Payload{value = 42}
        \\match owner
        \\    Payload ->
        \\        ref payload = owner
        \\        owner = none
        \\        exit(payload.value)
        \\    _ -> ()
    , .borrow_outlives_source);
}

test "references list element aliases cannot survive reallocation" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() unit | none
        \\    var owner: List(int) = [42]
        \\    ref item = owner[0]
        \\    const checked_value_1 = owner.reserve(128)
        \\    if not (checked_value_1 is unit) -> return none
        \\    exit(item)
        \\    return ()
        \\if (invalid() is unit) -> unit
    , .borrow_outlives_source);
}

test "references recursive components recompute after dependency edits" {
    const first =
        \\pub func first(ref left: int, ref right: int, count: int) ref int
        \\    if count == 0 -> return left
        \\    return second(left, right, count - 1)
        \\
    ;
    const direct = first ++
        \\pub func second(ref left: int, ref right: int, count: int) ref int -> left
    ;
    const recursive = first ++
        \\pub func second(ref left: int, ref right: int, count: int) ref int -> first(right, left, count)
    ;
    const fixture = try Fixture.initFiles(
        \\import library.{first}
        \\var left = 12
        \\const right = 30
        \\ref selected = first(left, right, 1)
        \\selected += 30
        \\exit(left)
    , &.{.{ .path = "library/functions.chi", .module_path = "library", .source = direct }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, recursive);
    try fixture.expectDiagnostic(0, .reference_not_writable);
    try fixture.db.setInput(test_sources.queries.SourceText, 1, direct);
    try fixture.expectExit(0, 42);
}

test "references recursive forwarding infers writes through every participating argument" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func first(mut left: Ref(int), mut right: Ref(int), count: int)
        \\    if count == 0
        \\        left.value += 1
        \\        return
        \\    second(right, left, count - 1)
        \\func second(mut left: Ref(int), mut right: Ref(int), count: int)
        \\    first(left, right, count)
        \\var writable = 41
        \\const readonly = 0
        \\var left = Ref.from(writable)
        \\var right = Ref.from(readonly)
        \\first(left, right, 1)
    , .reference_not_writable);
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func first(mut left: Ref(int), mut right: Ref(int), count: int)
        \\    if count == 0
        \\        left.value += 1
        \\        return
        \\    second(right, left, count - 1)
        \\func second(mut left: Ref(int), mut right: Ref(int), count: int)
        \\    first(left, right, count)
        \\func run() int
        \\    var left = 20
        \\    var right = 21
        \\    var a = Ref.from(left)
        \\    if not (a is Ref(int)) -> panic "unexpected none"
        \\    var b = Ref.from(right)
        \\    if not (b is Ref(int)) -> panic "unexpected none"
        \\    first(a, b, 1)
        \\    return left + right
    , 42);
}

test "references recursive borrowed returns preserve the referent and readonly attenuation" {
    try Fixture.expectParity(
        \\func select(ref source: int, count: int) ref int
        \\    if count == 0 -> return source
        \\    return select(source, count - 1)
        \\func run() int
        \\    var source = 12
        \\    ref result = select(source, 5)
        \\    result += 30
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func select(ref source: int, count: int) Ref(int)
        \\    if count == 0
        \\        const result = Ref.from(source)
        \\        return result
        \\    return select(source, count - 1)
        \\const source = 12
        \\var result = select(source, 5)
        \\result.value = 42
    , .reference_not_writable);
}

test "references owned handles keep captured permission during argument preparation and cleanup" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\struct Item
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Item) -> self.trace.value += 42
        \\func discard(var item: Item) -> unit
        \\func run() int
        \\    var source = 0
        \\    discard(Item{trace = Ref.from(source)})
        \\    return source
    , 42);
}

test "references owned handles survive borrowed variant conversion through an immutable argument" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func choose(imm handle: Ref(int)) Ref(int) | none -> handle
        \\func run() int
        \\    const source = [42]
        \\    match source.get(0)
        \\        ref _matched_element and _matched_element is int ->
        \\            ref element = _matched_element
        \\            match choose(Ref.from(element))
        \\                handle and handle is Ref(int) -> return handle.value
        \\                _ -> ()
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references list views keep allocation storage through copied descriptor frames" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values: List(int) = [19, 23]
        \\    const view = values.slice(0..2)
        \\    if not (view is Span(int)) -> return none
        \\    return view[0] + view[1]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references parametric parameters infer direct writes without a call site modifier" {
    try Fixture.expectParity(
        \\func increment(ref value: int) -> value += 1
        \\func run() int
        \\    var source = 41
        \\    increment(source)
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func increment(ref value: int) -> value += 1
        \\const source = 41
        \\increment(source)
    , .reference_not_writable);
}

test "references read-only helpers do not invalidate another live element reference" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func inspect(var handle: Ref(int)) int -> handle.value
        \\func calculate() int | none
        \\    var owner: List(int) = [12]
        \\    const checked_value_1 = owner.get(0)
        \\    if not (checked_value_1 is int) -> return none
        \\    ref element = checked_value_1
        \\    const observed = inspect(Ref.from(element))
        \\    element += 18
        \\    return observed + element
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references helper replacement invalidates allocated descendants but preserves the owner slot" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(ref owner: Box(int), var replacement: Box(int)) -> owner = replacement^
        \\func invalid() unit | none
        \\    var owner = Box.new(12)
        \\    if not (owner is Box(int)) -> return none
        \\    ref old = owner.borrow()
        \\    replace(owner, ((match Box.new(42)
        \\        _selected_result_0 and _selected_result_0 is Box(int) -> _selected_result_0^
        \\        _ -> return none)))
        \\    print("replaced")
        \\    old += 1
        \\    return ()
        \\if (invalid() is unit) -> unit
    , .borrow_outlives_source);
}

test "references unknown function values cannot upgrade a returned readonly capture" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func readonly(ref source: int) Ref(int)
        \\    const result = Ref.from(source)
        \\    return result
        \\func apply(handler: func(ref int) Ref(int), mut source: int) Ref(int) -> handler(source)
        \\var source = 12
        \\var result = apply(readonly, source)
        \\result.value = 42
    , .reference_not_writable);
}

test "references replacing a handle slot retains the newly borrowed referent" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func calculate() int | none
        \\    var first = 12
        \\    var second = 42
        \\    var handles = [Ref.from(first)]
        \\    ref slot = handles[0]
        \\    slot = Ref.from(second)
        \\    return slot.value
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func invalid() int | none
        \\    const original = 42
        \\    var handles = [Ref.from(original)]
        \\    if 1 == 1
        \\        const temporary = 12
        \\        ref slot = handles[0]
        \\        slot = Ref.from(temporary)
        \\    return handles[0].value
        \\if (invalid() is int) -> unit
    , .borrow_outlives_source);
}

test "references recursive reference fields infer a finite return contract" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\pub struct Node
        \\    pub next: Ref(Node) | none
        \\    pub value: int
        \\func select(ref node: Node, depth: int) ref Node
        \\    if depth == 0 -> return node
        \\    match node.next
        \\        Ref(Node) ->
        \\            ref next = node.next
        \\            return select(next.value, depth - 1)
        \\        _ -> ()
        \\    return node
        \\func run() int
        \\    var first = Node{next = none, value = 12}
        \\    var second = Node{next = Ref.from(first), value = 30}
        \\    ref found = select(second, 1)
        \\    return found.value + 30
    , 42);
}

test "references byte and zero-sized parameters retain caller addresses" {
    try Fixture.expectParity(
        \\func byte_identity(ref value: byte) ref byte -> value
        \\func unit_identity(ref value: unit) ref unit -> value
        \\func run() int
        \\    var source: byte = 12
        \\    ref selected = byte_identity(source)
        \\    selected = 42
        \\    var empty = unit
        \\    ref zero = unit_identity(empty)
        \\    zero = unit
        \\    return byte_int(source)
    , 42);
}

test "references immutable scalar arguments snapshot a borrowed value before later owner transfer" {
    try Fixture.expectParity(
        \\import std.memory.{Allocation}
        \\func discard(deinit owner: Allocation(int)) int
        \\    owner.unsafe_destroy(0)
        \\    owner^.deallocate()
        \\    return 0
        \\func observe(first: int, second: int) int -> first + second
        \\func calculate() int | none
        \\    var owner = Allocation(int).allocate(1)
        \\    if not (owner is Allocation(int)) -> return none
        \\    if (owner.unsafe_initialize(0, 42) is unit) -> unit
        \\    else
        \\        owner^.deallocate()
        \\        return none
        \\    return observe(owner.unsafe_borrow(0), discard(owner^))
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references span capabilities survive copies calls fields and joins" {
    try Fixture.expectParity(
        \\func retain(ref view: Span(int)) Span(int) -> view
        \\func calculate() int | none
        \\    var owner = [12]
        \\    var view = owner.span()
        \\    const callback: func(ref Span(int)) Span(int) = retain
        \\    var copied = callback(view)
        \\    ref item = copied[0]
        \\    item += 30
        \\    return owner[0]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
    for ([_][]const u8{
        "const readonly = owner.span()\n    var selected = readonly",
        "var readonly = owner.span().as_imm()\n    var selected = retain(readonly)",
        "var writable = owner.span()\n    var readonly = writable.as_imm()\n    var selected = if choice == 0 -> writable else readonly",
        "var readonly = owner.span().as_imm()\n    var wrapped = Wrapped{view = readonly}\n    var selected = wrapped.view",
        "var selected = owner.span()\n    var readonly = selected.as_imm()\n    var index = 0\n    loop\n        if index == choice -> break\n        selected = readonly\n        index += 1",
    }) |setup| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Wrapped
            \\    pub view: Span(int)
            \\func retain(ref view: Span(int)) Span(int) -> view
            \\func invalid(choice: int)
            \\    var owner = [12]
            \\    $setup
            \\    ref item = selected[0]
            \\    item = 42
            \\invalid(1)
        , .{ .setup = setup });
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .reference_not_writable);
    }
    try Fixture.expectSourceDiagnostic(
        \\func retain(ref view: Span(int)) Span(int) -> view
        \\func invalid(callback: func(ref Span(int)) Span(int)) unit | none
        \\    var owner = [12]
        \\    var view = owner.span()
        \\    var selected = callback(view)
        \\    ref item = selected[0]
        \\    item = 42
        \\    return ()
        \\if (invalid(retain) is unit) -> unit
    , .reference_not_writable);
}

test "references slicing a writable span preserves captured permission" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var source = [12, 0]
        \\    var complete = source.span()
        \\    var slice = complete.slice(0..1)
        \\    if not (slice is Span(int)) -> return none
        \\    ref item = slice[0]
        \\    item += 30
        \\    return source[0]
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references assignments to returned places evaluate their receiver once" {
    try Fixture.expectParity(
        \\func select(ref item: int, mut calls: int) ref int
        \\    calls += 1
        \\    return item
        \\func handle(ref item: int, mut calls: int) Ref(int)
        \\    calls += 1
        \\    return Ref.from(item)
        \\func run() int
        \\    var source = 10
        \\    var calls = 0
        \\    select(source, calls) += 10
        \\    handle(source, calls).value += 20
        \\    return source + calls
    , 42);
}

test "references recursive allocated owners infer a finite borrowed-result contract" {
    try Fixture.expectParity(
        \\pub struct Node
        \\    pub next: Box(Node) | none
        \\    pub value: int
        \\func last(ref node: Node) ref int
        \\    match node.next
        \\        Box(Node) ->
        \\            ref next = node.next
        \\            return last(next.borrow())
        \\        _ -> ()
        \\    return node.value
        \\func calculate() int | none
        \\    var leaf = Box.new(Node{next = none, value = 12})
        \\    if not (leaf is Box(Node)) -> return none
        \\    var root = Node{next = leaf^, value = 0}
        \\    ref result = last(root)
        \\    result += 30
        \\    return result
        \\func run() int
        \\    match calculate()
        \\        result and result is int -> return result
        \\        _ -> ()
        \\    return 90
    , 42);
}

test "references a parameter payload cannot survive replacing its variant tag" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid(ref source: int | none) int
        \\    match source
        \\        int ->
        \\            ref item = source
        \\            source = none
        \\            return item
        \\        _ -> ()
        \\    return 90
        \\var source: int | none = 42
        \\exit(invalid(source))
    , .borrow_outlives_source);
}

test "references parameter replacement retains the new referent" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func replace(ref slot: Ref(int), ref source: int) -> slot = Ref.from(source)
        \\func run() int
        \\    var first = 10
        \\    var second = 40
        \\    var slot = Ref.from(first)
        \\    if not (slot is Ref(int)) -> panic "unexpected none"
        \\    replace(slot, second)
        \\    slot.value += 2
        \\    return second
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func replace(ref slot: Ref(int), ref source: int) -> slot = Ref.from(source)
        \\func invalid() int
        \\    var first = 10
        \\    var slot = Ref.from(first)
        \\    if true
        \\        var temporary = 42
        \\        replace(slot, temporary)
        \\    return slot.value
        \\exit(invalid())
    , .borrow_outlives_source);
}

test "references bare returns retain the correct output authority and lifetime" {
    for ([_][]const u8{ "", "()" }) |returned| {
        const declarations = try test_sources.renderTemplate(std.testing.allocator,
            \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
            \\    if not selected -> return none
            \\    slot = Ref.from(source)
            \\    return $returned
        , .{ .returned = returned });
        defer std.testing.allocator.free(declarations);
        const valid = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\func run() int
            \\    const original = 1
            \\    var source = 41
            \\    var slot = Ref.from(original)
            \\    const result = replace(slot, source, true)
            \\    if result is unit -> slot.value += 1
            \\    return source
        });
        defer std.testing.allocator.free(valid);
        try Fixture.expectParity(valid, 42);
        const readonly = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\func invalid() unit
            \\    var original = 1
            \\    const source = 41
            \\    var slot = Ref.from(original)
            \\    const result = replace(slot, source, true)
            \\    if result is unit -> slot.value = 42
            \\invalid()
        });
        defer std.testing.allocator.free(readonly);
        try Fixture.expectSourceDiagnostic(readonly, .reference_not_writable);
        const expired = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\func invalid() int
            \\    var original = 1
            \\    var slot = Ref.from(original)
            \\    if true
            \\        var temporary = 42
            \\        const result = replace(slot, temporary, true)
            \\        if not (result is unit) -> return 90
            \\    return slot.value
            \\exit(invalid())
        });
        defer std.testing.allocator.free(expired);
        try Fixture.expectSourceDiagnostic(expired, .borrow_outlives_source);
    }
}

test "references result correlated replacement selects the installed referent" {
    try Fixture.expectParity(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, true)
        \\    if not (result is unit) -> return 90
        \\    slot.value += 2
        \\    return source
    , 42);
}

test "references result correlated saved forwarding and loop joins" {
    try Fixture.expectParity(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func forward(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    const result = replace(slot, source, selected)
        \\    return result
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = forward(slot, source, true)
        \\    const saved = result
        \\    const success = saved is unit
        \\    var count = 0
        \\    loop
        \\        if count == 2 -> break
        \\        count += 1
        \\    if not success -> return 90
        \\    slot.value += count
        \\    return source
    , 42);
}

test "references result correlated narrowing cannot restore overwritten outputs" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, true)
        \\    slot = Ref.from(original)
        \\    if not (result is unit) -> return 90
        \\    slot.value += 2
        \\    return source
        \\exit(invalid())
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var result = replace(slot, source, false)
        \\    result = ()
        \\    if not (result is unit) -> return 90
        \\    slot.value += 2
        \\    return source
        \\exit(invalid())
    , .reference_not_writable);
}

test "references result correlated failure retains previous capture" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, false)
        \\    if result is unit -> return 90
        \\    slot.value += 2
        \\    return source
        \\exit(invalid())
    , .reference_not_writable);
}

test "references result correlated match and indirect output writes" {
    try Fixture.expectParity(
        \\func install(var target: Ref(Ref(int)), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    target.value = Ref.from(source)
        \\    return ()
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    match install(Ref.from(slot), source, true)
        \\        unit -> slot.value += 2
        \\        none -> return 90
        \\    return source
    , 42);
    const invalid =
        \\func install(var target: Ref(Ref(int)), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    target.value = Ref.from(source)
        \\    return ()
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = install(Ref.from(slot), source, false)
        \\    if result is unit -> return 90
        \\    slot.value += 2
        \\    return source
        \\exit(invalid())
    ;
    for ([_]u32{ 0, 1, 2 }) |worker_count| {
        const db = try test_sources.query.Database.init(std.testing.allocator, .{ .worker_count = worker_count });
        defer db.deinit();
        try test_sources.modules.registerSources(db, std.testing.allocator, invalid, &.{}, &.{});
        const fixture: Fixture = .{ .db = db };
        fixture.expectDiagnostic(0, .reference_not_writable) catch |err| {
            std.debug.print("Indirect output authority failed with {d} workers\n", .{worker_count});
            return err;
        };
    }
}

test "references result correlated selected captures still expire" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func invalid() int
        \\    var original = 1
        \\    var slot = Ref.from(original)
        \\    if 1 == 1
        \\        var temporary = 42
        \\        const result = replace(slot, temporary, true)
        \\        if not (result is unit) -> return 90
        \\    return slot.value
        \\exit(invalid())
    , .borrow_outlives_source);
}

test "references result correlated branch forwarding and multiple outputs" {
    try Fixture.expectParity(
        \\func replace(mut left: Ref(int), mut right: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    left = Ref.from(source)
        \\    right = Ref.from(source)
        \\    return ()
        \\func forward(mut left: Ref(int), mut right: Ref(int), ref source: int, flag: bool) unit | none
        \\    return if flag -> replace(left, right, source, true) else replace(left, right, source, false)
        \\func run() int
        \\    const original = 1
        \\    var source = 39
        \\    var left = Ref.from(original)
        \\    var right = Ref.from(original)
        \\    const result = forward(left, right, source, true)
        \\    if not (result is unit) -> return 90
        \\    left.value += 1
        \\    right.value += 2
        \\    return source
    , 42);
}

test "references result correlated loop calls preserve earlier iteration captures" {
    const declarations =
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func invoke(ref source: int) int
        \\    var original = 1
        \\    var slot = Ref.from(original)
        \\    var count = 0
        \\    loop
        \\        const result = replace(slot, source, count == 0)
        \\        if not (result is unit) -> slot.value += 2
        \\        count += 1
        \\        if count == 2 -> break
        \\    return original
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var source = 40
        \\    _ = invoke(source)
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\const source = 40
        \\_ = invoke(source)
    , .reference_not_writable);
}

test "references result correlated loop overwrite cannot forge a call result" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var result = replace(slot, source, false)
        \\    var count = 0
        \\    loop
        \\        if result is unit -> slot.value += 2
        \\        result = ()
        \\        count += 1
        \\        if count == 2 -> break
        \\    return source
        \\exit(invalid())
    , .reference_not_writable);
}

test "references result correlated mutable saved results survive unchanged loop joins" {
    try Fixture.expectParity(
        \\func replace(mut slot: Ref(int), ref source: int, selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot = Ref.from(source)
        \\    return ()
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var result = replace(slot, source, true)
        \\    var count = 0
        \\    loop
        \\        count += 1
        \\        if count == 2 -> break
        \\    if not (result is unit) -> return 90
        \\    slot.value += 2
        \\    return source
        \\exit(run())
    , 42);
}

test "references result correlated equal return alternatives still merge dependencies" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(mut slot: Ref(int), ref source: int, flag: bool) unit | none
        \\    if flag
        \\        slot = Ref.from(source)
        \\        return ()
        \\    return ()
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, false)
        \\    if not (result is unit) -> return 90
        \\    slot.value += 2
        \\    return source
        \\exit(invalid())
    , .reference_not_writable);
}

test "references result correlated three alternatives retain unselected captures" {
    const declarations =
        \\func replace(mut slot: Ref(int), ref source: int, choice: int) unit | none | bool
        \\    if choice == 0 -> return none
        \\    if choice == 1 -> return true
        \\    slot = Ref.from(source)
        \\    return ()
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func calculate(choice: int) int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const first = replace(slot, source, choice)
        \\    const second = replace(slot, source, choice)
        \\    if not (first is unit) -> return 90
        \\    if not (second is unit) -> return 91
        \\    slot.value += 2
        \\    return source
        \\func run() int -> calculate(2)
        \\exit(run())
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid(choice: int) int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const first = replace(slot, source, choice)
        \\    const second = replace(slot, source, choice)
        \\    if not (first is bool) -> return 90
        \\    if not (second is bool) -> return 91
        \\    slot.value += 2
        \\    return source
        \\exit(invalid(1))
    , .reference_not_writable);
}

test "references result correlated cleared referents release selected captures" {
    const declarations =
        \\func clear(slot: Ref(Ref(int) | none), selected: bool) unit | none
        \\    if not selected -> return none
        \\    slot.value = none
        \\    return ()
        \\func forward(slot: Ref(Ref(int) | none), selected: bool) unit | none -> clear(slot, selected)
        \\func checked(slot: Ref(int) | none) int
        \\    if slot is none -> return 42
        \\    return 90
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var slot: Ref(int) | none = none
        \\    if 1 == 1
        \\        var temporary = 40
        \\        slot = Ref.from(temporary)
        \\        const result = forward(Ref(Ref(int) | none).from(slot), true)
        \\        if not (result is unit) -> return 91
        \\    return checked(slot)
        \\exit(run())
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() int
        \\    var slot: Ref(int) | none = none
        \\    if 1 == 1
        \\        var temporary = 40
        \\        slot = Ref.from(temporary)
        \\        const result = forward(Ref(Ref(int) | none).from(slot), false)
        \\        if not (result is none) -> return 91
        \\    return checked(slot)
        \\exit(invalid())
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() int
        \\    var slot: Ref(int) | none = none
        \\    if 1 == 1
        \\        var temporary = 40
        \\        slot = Ref.from(temporary)
        \\        _ = forward(Ref(Ref(int) | none).from(slot), true)
        \\    return checked(slot)
        \\exit(invalid())
    , .borrow_outlives_source);
}

test "references result correlated borrowed variant results retain dependencies" {
    const declarations =
        \\func replace(mut slot: Ref(int), ref source: int, present: bool) ref int | none
        \\    if not present -> return none
        \\    slot = Ref.from(source)
        \\    return source
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, true)
        \\    if not (result is int) -> return 90
        \\    slot.value += 2
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, false)
        \\    if result is none -> slot.value += 2
        \\    return source
        \\exit(invalid())
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() int
        \\    var original = 1
        \\    const source = 40
        \\    var slot = Ref.from(original)
        \\    const result = replace(slot, source, true)
        \\    if result is int -> slot.value += 2
        \\    return original
        \\exit(invalid())
    , .reference_not_writable);
}

test "references opaque immutable handles require captured write authority" {
    try Fixture.expectSourceDiagnostic(
        \\func write(handle: Ref(int)) unit -> handle.value = 42
        \\func invoke(handler: func(Ref(int)) unit, handle: Ref(int)) unit -> handler(handle)
        \\const source = 1
        \\invoke(write, Ref.from(source))
    , .reference_not_writable);
    try Fixture.expectParity(
        \\func write(handle: Ref(int)) unit -> handle.value = 42
        \\func invoke(handler: func(Ref(int)) unit, handle: Ref(int)) unit -> handler(handle)
        \\func run() int
        \\    var source = 1
        \\    const handle = Ref.from(source)
        \\    invoke(write, handle)
        \\    return source
    , 42);
}

test "references opaque immutable spans preserve readonly parameter access" {
    try Fixture.expectSourceDiagnostic(
        \\func write(view: Span(int)) unit
        \\    ref item = view[0]
        \\    item = 42
        \\func invoke(handler: func(Span(int)) unit, view: Span(int)) unit -> handler(view)
        \\const values = [1]
        \\invoke(write, values.span())
    , .reference_not_writable);
    try Fixture.expectParity(
        \\func read(view: Span(int)) int -> view[0]
        \\func invoke(handler: func(Span(int)) int, view: Span(int)) int -> handler(view)
        \\func run() int
        \\    const values = [42]
        \\    const view = values.span()
        \\    return invoke(read, view)
    , 42);
}

test "references opaque immutable handles invalidate content views" {
    try Fixture.expectSourceDiagnostic(
        \\func append(handle: Ref(String)) unit
        \\    if not (handle.value.append("x") is unit) -> panic "append failed"
        \\func invoke(handler: func(Ref(String)) unit, handle: Ref(String)) unit -> handler(handle)
        \\func invalid() int
        \\    var source: String = "abc"
        \\    const view = source.view()
        \\    invoke(append, Ref.from(source))
        \\    return view.byte_length()
        \\exit(invalid())
    , .borrow_outlives_source);
}

test "references known callable projections and returns preserve contracts" {
    try Fixture.expectParity(
        \\func identity(ref source: int) ref int -> source
        \\struct Callback
        \\    target: func(ref int) ref int
        \\func run() int
        \\    const source = 42
        \\    const callback = Callback{target = identity}
        \\    ref selected = callback.target(source)
        \\    return selected
    , 42);
    try Fixture.expectParity(
        \\func identity(ref source: int) ref int -> source
        \\func forward(callback: func(ref int) ref int) func(ref int) ref int -> callback
        \\func run() int
        \\    const source = 42
        \\    const callback = forward(identity)
        \\    ref selected = callback(source)
        \\    return selected
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func identity(ref source: int) ref int -> source
        \\func write(ref source: int) ref int
        \\    source = 42
        \\    return source
        \\struct Callback
        \\    target: func(ref int) ref int
        \\const source = 1
        \\var callback = Callback{target = identity}
        \\callback.target = write
        \\_ = callback.target(source)
    , .reference_not_writable);
}

test "references callable recovery follows long forwarding and immutable copy chains" {
    for ([_]bool{ false, true }) |aggregate| {
        var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer source.deinit();
        try source.writer.writeAll("func identity(ref source: int) ref int -> source\n");
        try source.writer.writeAll("func forward(callback: func(ref int) ref int) func(ref int) ref int -> callback\n");
        try source.writer.writeAll("struct Callback\n    copy = fieldwise\n    target: func(ref int) ref int\nfunc run() int\n    const source = 42\n");
        if (aggregate) {
            try source.writer.writeAll("    const callback_0 = Callback{target = identity}\n");
            for (1..81) |index| try source.writer.print("    const callback_{d} = callback_{d}\n", .{ index, index - 1 });
            try source.writer.writeAll("    return callback_80.target(source)\n");
        } else {
            try source.writer.writeAll("    const callback_0 = identity\n");
            for (1..81) |index| try source.writer.print("    const callback_{d} = forward(callback_{d})\n", .{ index, index - 1 });
            try source.writer.writeAll("    return callback_80(source)\n");
        }
        try Fixture.expectParity(source.written(), 42);
    }
}

test "references returned mutable callbacks remain conservative" {
    const declarations =
        \\func identity(ref source: int) ref int -> source
        \\func write(ref source: int) ref int
        \\    source = 42
        \\    return source
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func factory() func(ref int) ref int -> identity
        \\func run() int
        \\    const source = 42
        \\    const callback = factory()
        \\    return callback(source)
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func redirect(var callback: func(ref int) ref int) func(ref int) ref int
        \\    callback = write
        \\    return callback
        \\const source = 1
        \\const callback = redirect(identity)
        \\_ = callback(source)
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func select(which: bool) func(ref int) ref int
        \\    if which -> return write
        \\    return identity
        \\const source = 1
        \\const callback = select(false)
        \\_ = callback(source)
    , .reference_not_writable);
}

test "references automatic drop publishes installed reference authority" {
    try Fixture.expectParity(
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\func run() int
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    _ = install
        \\    slot.value += 1
        \\    return source
    , 42);
}

test "references automatic drop preserves installed reference lifetime" {
    try Fixture.expectSourceDiagnostic(
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\func invalid() int
        \\    var original = 1
        \\    var slot = Ref.from(original)
        \\    if true
        \\        var temporary = 42
        \\        const install = Install{target = Ref.from(slot), source = Ref.from(temporary)}
        \\        _ = install
        \\    return slot.value
        \\exit(invalid())
    , .borrow_outlives_source);
}

test "references automatic drop follows captured slot replacements" {
    const declarations =
        \\struct FollowSlot
        \\    target: Ref(Ref(int))
        \\    source: Ref(Ref(int))
        \\    drop = func(deinit self: FollowSlot) -> self.target.value = self.source.value
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var later = 41
        \\    var source = Ref.from(original)
        \\    var slot = Ref.from(original)
        \\    const install = FollowSlot{target = Ref.from(slot), source = Ref.from(source)}
        \\    _ = install
        \\    source = Ref.from(later)
        \\    _ = install
        \\    slot.value += 1
        \\    return later
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit
        \\    var original = 1
        \\    const later = 41
        \\    var source = Ref.from(original)
        \\    var slot = Ref.from(original)
        \\    const install = FollowSlot{target = Ref.from(slot), source = Ref.from(source)}
        \\    _ = install
        \\    source = Ref.from(later)
        \\    _ = install
        \\    slot.value = 42
        \\invalid()
    , .reference_not_writable);
}

test "references unused automatic drop exports parameter writes" {
    const declarations =
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\func install(mut target: Ref(int), imm source: Ref(int)) unit
        \\    const hook = Install{target = Ref.from(target), source = source}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    install(slot, Ref.from(source))
        \\    slot.value += 1
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit
        \\    var original = 1
        \\    const source = 41
        \\    var slot = Ref.from(original)
        \\    install(slot, Ref.from(source))
        \\    slot.value = 42
        \\invalid()
    , .reference_not_writable);
}

test "references automatic drop follows capture and branch chronology" {
    const declarations =
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\struct Wrapper
        \\    install: Install
        \\struct Pair
        \\    first: Install
        \\    second: Install
        \\struct Slots
        \\    first: Ref(int)
        \\    second: Ref(int)
    ;
    const sources = [_][]const u8{
        \\func run() int
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    ref captured = slot.value
        \\    const saved = slot
        \\    _ = install
        \\    slot.value += 1
        \\    return source + captured + saved.value - 2
        ,
        \\func select(which: bool) int
        \\    const original = 42
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    if which
        \\        ref captured = slot.value
        \\        _ = install
        \\        return captured
        \\    else
        \\        return slot.value + 1
        \\func run() int -> select(true) + select(false) - 42
        ,
        \\func run() int
        \\    const original = 1
        \\    var first_source = 40
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const first = Install{target = Ref.from(slot), source = Ref.from(first_source)}
        \\    _ = first
        \\    const second = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    _ = second
        \\    slot.value += 1
        \\    return source
        ,
        \\func run() int
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const wrapper = Wrapper{install = Install{target = Ref.from(slot), source = Ref.from(source)}}
        \\    _ = wrapper
        \\    slot.value += 1
        \\    return source
        ,
    };
    inline for (sources) |source| try Fixture.expectParity(declarations ++ "\n" ++ source, 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    const installed = 2
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(installed)}
        \\    _ = install
        \\    slot = Ref.from(source)
        \\    slot.value += 1
        \\    return source
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    loop
        \\        const install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\        _ = install
        \\        break
        \\    slot.value += 1
        \\    return source
    , 42);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var first = 20
        \\    var second = 20
        \\    var slots = Slots{first = Ref.from(original), second = Ref.from(original)}
        \\    const pair = Pair{
        \\        first = Install{target = Ref.from(slots.first), source = Ref.from(first)},
        \\        second = Install{target = Ref.from(slots.second), source = Ref.from(second)},
        \\    }
        \\    _ = pair
        \\    slots.first.value += 1
        \\    slots.second.value += 1
        \\    return first + second
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit
        \\    var original = 1
        \\    var installed = 2
        \\    const readonly = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(installed)}
        \\    _ = install
        \\    slot = Ref.from(readonly)
        \\    slot.value = 42
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid(var repeat: bool) unit
        \\    var original = 1
        \\    const readonly = 41
        \\    var slot = Ref.from(original)
        \\    loop
        \\        if not repeat -> break
        \\        const install = Install{target = Ref.from(slot), source = Ref.from(readonly)}
        \\        _ = install
        \\        repeat = false
        \\    slot.value = 42
        \\invalid(true)
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid(which: bool) unit
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    if which
        \\        ref captured = slot.value
        \\        _ = install
        \\        captured = 42
        \\    else
        \\        _ = slot.value
        \\invalid(true)
    , .reference_not_writable);
}

test "references automatic drop follows aggregate cleanup order" {
    const declarations =
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\struct Pair
        \\    left: Install
        \\    right: Install
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var pair = Pair{left = Install{target = Ref.from(slot), source = Ref.from(source)}, right = Install{target = Ref.from(slot), source = Ref.from(original)}}
        \\    _ = pair
        \\    slot.value = 42
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var pair = Pair{left = Install{target = Ref.from(slot), source = Ref.from(original)}, right = Install{target = Ref.from(slot), source = Ref.from(source)}}
        \\    _ = pair
        \\    slot.value = 42
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var pair = Pair{left = Install{target = Ref.from(slot), source = Ref.from(original)}, right = Install{target = Ref.from(slot), source = Ref.from(source)}}
        \\    var moved = pair.left^
        \\    _ = pair.right.source
        \\    slot.value = 42
        \\    _ = moved
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var pair = Pair{left = Install{target = Ref.from(slot), source = Ref.from(source)}, right = Install{target = Ref.from(slot), source = Ref.from(original)}}
        \\    var moved = pair.left^
        \\    _ = pair.right.source
        \\    slot.value = 42
        \\    _ = moved
        \\invalid()
    , .reference_not_writable);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var installs = [Install{target = Ref.from(slot), source = Ref.from(source)}, Install{target = Ref.from(slot), source = Ref.from(original)}]
        \\    _ = installs
        \\    slot.value = 42
        \\    return source
    , 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() unit
        \\    const original = 1
        \\    var source = 40
        \\    var slot = Ref.from(original)
        \\    var installs = [Install{target = Ref.from(slot), source = Ref.from(original)}, Install{target = Ref.from(slot), source = Ref.from(source)}]
        \\    _ = installs
        \\    slot.value = 42
        \\invalid()
    , .reference_not_writable);
}

test "references automatic drop contents cross shared diamonds and preserve branch writes" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll(
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\func inspect(chosen: bool) int
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    const install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    _ = install
        \\    var count = 0
        \\
    );
    for (0..18) |_| try source.writer.writeAll("    if chosen\n        count += 1\n    else\n        count += 2\n");
    try source.writer.writeAll(
        \\    slot.value += 1
        \\    if count == 18 or count == 36 -> return source
        \\    return 90
        \\func run() int
        \\    if inspect(true) <> 42 -> return 91
        \\    return inspect(false)
    );
    try Fixture.expectParity(source.written(), 42);
}

test "references automatic drop guarded carrier preserves untouched origins" {
    try Fixture.expectSourceDiagnostic(
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    drop = func(deinit self: Install) -> self.target.value = self.source
        \\func invalid(which: bool) unit
        \\    const original = 1
        \\    var source = 41
        \\    var slot = Ref.from(original)
        \\    var install: Install | none = none
        \\    if which -> install = Install{target = Ref.from(slot), source = Ref.from(source)}
        \\    _ = install
        \\    slot.value = 42
        \\invalid(false)
    , .reference_not_writable);
}

test "references fieldwise copying copies addresses of noncopyable referents" {
    try Fixture.expectParity(
        \\pub struct Payload
        \\    copy = none
        \\    pub value: int
        \\struct Token
        \\    copy = func(imm self: Token) Token -> Token{}
        \\struct Holder
        \\    copy = fieldwise
        \\    pub ref item: Payload
        \\    token: Token
        \\func run() int
        \\    var source = Payload{value = 42}
        \\    var holder = Holder{item = source, token = Token{}}
        \\    const copied = holder
        \\    return copied.item.value
    , 42);
}

test "references ownership hook writes retain newly installed loans" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Install
        \\    target: Ref(Ref(int))
        \\    source: Ref(int)
        \\    move = func(deinit self: Install) Install
        \\        self.target.value = self.source
        \\        return Install{target = self.target, source = self.source}
        \\func selected(ref initial: int) Ref(int)
        \\    var result = Ref.from(initial)
        \\    var local = 42
        \\    const source = Install{target = Ref.from(result), source = Ref.from(local)}
        \\    const moved = source^
        \\    _ = moved
        \\    return result
        \\var initial = 17
        \\exit(selected(initial).value)
    , .borrow_outlives_source);
}

test "references handle parameter writes retain new loans and reject expired referents" {
    try Fixture.expectParity(
        \\func install(var target: Ref(Ref(int)), ref source: int) -> target.value = Ref.from(source)
        \\func run() int
        \\    var original = 1
        \\    var replacement = 42
        \\    var slot = Ref.from(original)
        \\    if not (slot is Ref(int)) -> panic "unexpected none"
        \\    install(Ref.from(slot), replacement)
        \\    return slot.value
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func install(var target: Ref(Ref(int)), ref source: int) -> target.value = Ref.from(source)
        \\func invalid() int
        \\    var original = 1
        \\    var slot = Ref.from(original)
        \\    if 1 == 1
        \\        var temporary = 42
        \\        install(Ref.from(slot), temporary)
        \\    return slot.value
        \\exit(invalid())
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\func install(var target: Ref(Ref(int)))
        \\    var temporary = 42
        \\    target.value = Ref.from(temporary)
        \\var original = 1
        \\var slot = Ref.from(original)
        \\install(Ref.from(slot))
    , .borrow_outlives_source);
    try Fixture.expectSourceDiagnostic(
        \\func choose(var target: Ref(Ref(int)), ref first: int, ref second: int, selected: bool)
        \\    if selected
        \\        target.value = Ref.from(first)
        \\    else
        \\        target.value = Ref.from(second)
        \\func invalid() int
        \\    var original = 1
        \\    var slot = Ref.from(original)
        \\    if 1 == 1
        \\        var temporary = 42
        \\        choose(Ref.from(slot), temporary, original, true)
        \\    return slot.value
        \\exit(invalid())
    , .borrow_outlives_source);
}

test "references unknown callbacks require writable authority for possible writes" {
    try Fixture.expectSourceDiagnostic(
        \\func write(ref value: int) -> value = 42
        \\func invoke(handler: func(ref int) unit, ref value: int) -> handler(value)
        \\const source = 1
        \\invoke(write, source)
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\func write(var handle: Ref(int)) -> handle.value = 42
        \\func invoke(handler: func(var Ref(int)) unit, var handle: Ref(int)) -> handler(handle^)
        \\const source = 1
        \\invoke(write, Ref.from(source))
    , .reference_not_writable);
}

test "references fieldwise destruction leaves the referent owned by its source" {
    try Fixture.expectParity(
        \\pub struct Resource
        \\    ref trace: int
        \\    pub value: int
        \\    drop = func(deinit self: Resource) -> self.trace += 40
        \\struct Token
        \\    ref trace: int
        \\    drop = func(deinit self: Token) -> self.trace += 1
        \\struct Holder
        \\    pub ref source: Resource
        \\    token: Token
        \\func exercise(ref trace: int) int
        \\    var source = Resource{trace = trace, value = 1}
        \\    if 1 == 1
        \\        var holder = Holder{source = source, token = Token{trace = trace}}
        \\        if holder.source.value <> 1 -> exit(90)
        \\    if trace <> 1 -> exit(91)
        \\    return source.value
        \\func run() int
        \\    var trace = 0
        \\    const result = exercise(trace)
        \\    return trace + result
    , 42);
}

test "references stored by a replacing call expire after the next replacement" {
    try Fixture.expectSourceDiagnostic(
        \\func install(mut slot: Ref(int), mut owner: Box(int)) unit | none
        \\    owner = ((match Box.new(42)
        \\        _selected_result_0 and _selected_result_0 is Box(int) -> _selected_result_0^
        \\        _ -> return none))
        \\    slot = Ref.from(owner.borrow())
        \\    return ()
        \\func replace(mut owner: Box(int)) unit | none
        \\    var replacement = Box.new(17)
        \\    if not (replacement is Box(int)) -> return none
        \\    owner = replacement^
        \\    return unit
        \\func invalid() int | none
        \\    var source = 1
        \\    var slot = Ref.from(source)
        \\    var owner = Box.new(10)
        \\    if not (owner is Box(int)) -> return none
        \\    const checked_value_3 = install(slot, owner)
        \\    if not (checked_value_3 is unit) -> return none
        \\    const checked_value_4 = replace(owner)
        \\    if not (checked_value_4 is unit) -> return none
        \\    return slot.value
        \\match invalid()
        \\    result and result is int -> exit(result)
        \\    _ -> ()
    , .borrow_outlives_source);
}
