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
        \\        if const span: Span(int) = self.storage -> return span
        \\        if ref list: List(int) = self.storage -> return list.span()
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
        \\    if const first: int = span.get(1)
        \\        if const second: int = span.get(2)
        \\            if const digit: byte = text.as_bytes().get(0) -> return first + second + byte_int(digit) - 29
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
        \\const _: unit = text.append(" world") else panic "unexpected none"
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
        \\    if const value: T = outcome^ -> return value^
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
        \\            const _: unit = pending.append(current * 2) else return none
        \\            const _: unit = pending.append(current * 2 + 1) else return none
        \\    return total + 14
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
        \\    if const item: Item = outcome^ -> return item.value
        \\    return 0
        \\func run() int
        \\    var copies = 0
        \\    const values = [Item{copies = (if const _selected_result_0: Ref(int) = Ref.from(copies) -> _selected_result_0 else panic "unexpected none"), value = 20}]
        \\    var total = 0
        \\    for index in 0..3 -> total += receive(values.get(index % 2))
        \\    return total + copies
    , 42);
}

test "references optional borrowed results still reject use across loop growth" {
    try Fixture.expectSourceDiagnostic(
        \\func must_ref(static T: type, var outcome: ref T | none) ref T
        \\    if ref value: T = outcome -> return value
        \\    panic "required element missing"
        \\var values: List(int) = [42]
        \\loop
        \\    ref current = must_ref(values[0])
        \\    const _: unit = values.append(17) else panic "unexpected none"
        \\    print(current)
        \\    break
    , .borrow_outlives_source);
}

test "references copied optional view results retain their backing dependencies" {
    try Fixture.expectSourceDiagnostic(
        \\func must(static T: type, var outcome: T | none) T
        \\    if const value: T = outcome^ -> return value^
        \\    panic "required operation failed"
        \\var text = "hello"
        \\var values: List(StringView) = [text.view()]
        \\loop
        \\    const current = must(StringView, values.get(0))
        \\    const _: unit = text.append(" world") else panic "unexpected none"
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
        \\    if const result: int = calculate() -> return result
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
        \\    discard(Observer{owner = (if const _selected_result_0: Ref(String) = Ref.from(owner) -> _selected_result_0 else return none), trace = (if const _selected_result_1: Ref(int) = Ref.from(trace) -> _selected_result_1 else return none)})
        \\    return view.byte_length() + trace + 36
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
            \\        if const target: Ref(String) = self.target
            \\            const _: unit = target.value.append("x") else panic "append failed"
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
            \\    if const result = calculate() -> return result
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
            \\        const _: unit = self.target.value.append("x") else panic "append failed"
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
            \\    if const result: int = calculate() -> return result
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
        \\    if ref item: int = selected -> item += 30
        \\    if const result: int = owner -> return result
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
        \\    const owner: Box(Item) = Box.new(Item{trace = trace, value = 2}) else return none
        \\    return owner.borrow().value + 38
        \\func run() int
        \\    var trace: Array(int, 1) = Array(int, 1).filled(0) else panic "unexpected none"
        \\    if ref target: int = trace.get(0)
        \\        if const value: int = calculate((if const _selected_result_0: Ref(int) = Ref.from(target) -> _selected_result_0 else panic "unexpected none")) -> return value + target
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
        \\    ref third: int = list.get(0) else return none
        \\    ref fourth: int = list.get(1) else return none
        \\    third += 10
        \\    fourth += 9
        \\    return first + second + third + fourth
        \\func run() int
        \\    if const result: int = compute() -> return result
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
        \\    if ref payload: Payload = owner
        \\        update(payload.value)
        \\    if ref result: Payload = owner -> return result.value
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
        \\    if ref item: Payload = select(owner, 0)
        \\        item.value += 30
        \\    if ref absent: Payload = select(owner, 1) -> return 90
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
        \\    if ref selected: int = result -> selected += 25
        \\    else return 90
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
        \\    if ref result: int = carrier -> return result
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
        \\if ref result: int = carrier -> result += 25
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
        \\    if ref result: int = carrier -> return result
        \\    return 90
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
        \\    if ref selected: int = carrier
        \\        selected += 25
        \\        return selected
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
        \\    if const selected: int = capture(owner)
        \\        var copied = selected
        \\        copied += 25
        \\        if owner <> 17 -> return 90
        \\        return copied
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
        \\    if const selected: int | none = carrier
        \\        if const value: int = selected -> return value + 25
        \\        return 42
        \\    return 90
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
        \\    if const selected: Array(int, 3) | int = produce(first)
        \\        if const number: int = selected -> return number
        \\        if ref values: Array(int, 3) = selected
        \\            if const last: int = values.get(2) -> return last + 21
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
        \\    if const selected: (int, int) = pair -> return selected.0 + selected.1
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
        \\    const node = Node{next = none, target = (if const _selected_result_0: Ref(int) = Ref.from(target) -> _selected_result_0 else panic "unexpected none")}
        \\    forward(node)
        \\    return target
    , 42);
}

test "references readonly recursive owners cannot upgrade owned views" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Node
        \\    next: Box(Node) | none
        \\    view: Span(int) | none
        \\func selected(ref node: Node) Span(int)
        \\    if ref next: Box(Node) = node.next -> return selected(next.borrow())
        \\    if const view: Span(int) = node.view -> return view
        \\    panic
        \\func forward(imm node: Node) Span(int) -> selected(node)
        \\func calculate() unit | none
        \\    var values = [41]
        \\    var leaf: Box(Node) = Box.new(Node{next = none, view = values.span()}) else return none
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
        \\    if ref next: Box(Node) = node.next -> return selected(next.borrow())
        \\    return node.target
        \\func forward(imm node: Node) Ref(int) -> selected(node)
        \\func calculate() int | none
        \\    var target = 41
        \\    var leaf: Box(Node) = Box.new(Node{next = none, target = (if const _selected_result_0: Ref(int) = Ref.from(target) -> _selected_result_0 else panic "unexpected none")}) else return none
        \\    const root = Node{next = leaf^, target = (if const _selected_result_1: Ref(int) = Ref.from(target) -> _selected_result_1 else return none)}
        \\    const handle = forward(root)
        \\    handle.value += 1
        \\    return target
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "references recursive parameter outputs retain replacement authority and lifetime" {
    const source =
        \\struct Node
        \\    next: Box(Node) | none
        \\    target: Ref(int)
        \\func replace(ref node: Node, ref source: int)
        \\    if ref next: Box(Node) = node.next -> replace(next.borrow(), source)
        \\    else
        \\        node.target = (if const _selected_result_0: Ref(int) = Ref.from(source) -> _selected_result_0 else panic "unexpected none")
        \\func selected(ref node: Node) Ref(int)
        \\    if ref next: Box(Node) = node.next -> return selected(next.borrow())
        \\    return node.target
        \\func calculate() int | none
        \\    var original = 0
        \\    var replacement = 41
        \\    var leaf: Box(Node) = Box.new(Node{next = none, target = (if const _selected_result_1: Ref(int) = Ref.from(original) -> _selected_result_1 else panic "unexpected none")}) else return none
        \\    var root = Node{next = leaf^, target = (if const _selected_result_2: Ref(int) = Ref.from(original) -> _selected_result_2 else return none)}
        \\    replace(root, replacement)
        \\    const handle = selected(root)
        \\    handle.value += 1
        \\    return replacement
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
        \\        if ref left_item: A = left_result
        \\            const right_result = self.right.next()
        \\            if ref right_item: B = right_result
        \\                var pair: (ref A, ref B) = (left_item, right_item)
        \\                return pair^
        \\        return End{}
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func run() int
        \\    var left = Left{value = 12}
        \\    const right = Right{value = 7}
        \\    var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\    const result = zipped.next()
        \\    if ref pair: (ref Left, ref Right) = result
        \\        pair.0.value += 30
        \\        if pair.1.value <> 7 -> return 90
        \\        if zipped.next() is End -> return left.value
        \\    return 91
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\var left = Left{value = 12}
        \\const right = Right{value = 7}
        \\var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\const result = zipped.next()
        \\if ref pair: (ref Left, ref Right) = result -> pair.1.value += 1
    , .reference_not_writable);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func first(ref left: Left) ref Left
        \\    const right = Right{value = 7}
        \\    var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\    const result = zipped.next()
        \\    if const pair: (ref Left, ref Right) = result -> return pair.0
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
        \\    if const pair: (ref Left, ref Right) = result
        \\        if pair.0.value <> 7 -> return 90
        \\        pair.1.value += 30
        \\        return right.value
        \\    return 91
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\const left = Left{value = 7}
        \\var right = Right{value = 12}
        \\var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\const result = zipped.next()
        \\if const pair: (ref Left, ref Right) = result -> pair.0.value += 1
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
        \\    var owner = Tracked{value = 17, effects = (if const _selected_result_0: Ref(int) = Ref.from(effects) -> _selected_result_0 else panic "unexpected none")}
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
        \\if const copied: Item = capture(owner) -> exit(copied.value)
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
        \\    if ref item: int | bool = choose(number, flag, true) -> return 1
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
        \\    if ref item: int | bool = carrier -> item = 42
        \\    if const item: int = owner -> return item
        \\    return 90
    , 42);
}

test "references logical payload borrows do not retain temporary carriers" {
    const declarations =
        \\func capture(ref owner: int) ref int | End -> owner
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func selected(ref owner: int) ref int
        \\    if ref item: int = capture(owner) -> return item
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
        \\    if ref item: int = carrier
        \\        carrier = End{}
        \\        return item
        \\    exit(90)
        \\func run() int
        \\    var owner = 12
        \\    ref item = selected(owner)
        \\    item += 30
        \\    return owner
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\const owner = 12
        \\if ref item: int = capture(owner) -> item += 30
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() ref int
        \\    var owner = 12
        \\    if ref item: int = capture(owner) -> return item
        \\    exit(90)
        \\_ = invalid()
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(
        \\var carrier: int | End = 12
        \\if ref item: int = carrier
        \\    carrier = End{}
        \\    exit(item)
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
        \\    const first: Ref(int) = Ref.from(owner) else panic "unexpected none"
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
        \\    const original = Mixed{target = (if const _selected_result_0: Ref(int) = Ref.from(owner) -> _selected_result_0 else panic "unexpected none"), view = values.span()}
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
        \\    ref item: int = copied.view.get(0) else return none
        \\    item = 42
        \\    return ()
        \\if (invalid() is unit) -> unit
    , .reference_not_writable);
}

test "references const aggregate copies preserve array and variant captures" {
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    const original = [(if const _selected_result_0: Ref(int) = Ref.from(owner) -> _selected_result_0 else panic "unexpected none")]
        \\    var copied = original
        \\    if ref handle: Ref(int) = copied.get(0) -> handle.value += 30
        \\    return owner
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    const original: Ref(int) | none = Ref.from(owner)
        \\    var copied = original
        \\    if ref handle: Ref(int) = copied -> handle.value += 30
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
        \\if ref item: int = handle.value -> item += 1
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\const source: int | none = 42
        \\const readonly = Ref.from(source)
        \\var handle = readonly
        \\if ref item: int = handle.value -> item += 1
    , .reference_not_writable);
    try Fixture.expectParity(
        \\func run() int
        \\    var source: int | none = 41
        \\    const handle: Ref(int | none) = Ref.from(source) else panic "unexpected none"
        \\    if ref item: int = handle.value -> item += 1
        \\    if ref item: int = source -> return item
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
        \\    var temporary: Ref(int) = Ref.from(owner) else panic "unexpected none"
        \\    return (if const _selected_result_0: Ref(int) = Ref.from(referent(temporary)) -> _selected_result_0 else panic "unexpected none")
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
        \\    return (if const _selected_result_0: Ref(int) = Ref.from(first(source, unrelated)) -> _selected_result_0 else panic "unexpected none")
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
        \\    var handle: Ref(int) = Ref.from(source) else panic "unexpected none"
        \\    update(handle)
        \\    return source
    , 42);
}

test "references containers of handles expose the handle slot and copy only its contents" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func capture(ref source: int) Ref(int) | none
        \\    var handles = [(if const _selected_result_0: Ref(int) = Ref.from(source) -> _selected_result_0 else return none)]
        \\    ref slot = handles[0]
        \\    slot.value += 10
        \\    return handles[0]
        \\func calculate() int | none
        \\    var source = 12
        \\    var copied: Ref(int) = capture(source) else return none
        \\    copied.value += 20
        \\    return source
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "references variant payload aliases cannot survive a changed active tag" {
    try Fixture.expectSourceDiagnostic(
        \\struct Payload
        \\    pub value: int
        \\var owner: Payload | none = Payload{value = 42}
        \\if ref payload: Payload = owner
        \\    owner = none
        \\    exit(payload.value)
    , .borrow_outlives_source);
}

test "references list element aliases cannot survive reallocation" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() unit | none
        \\    var owner: List(int) = [42]
        \\    ref item = owner[0]
        \\    const _: unit = owner.reserve(128) else return none
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
        \\    var a: Ref(int) = Ref.from(left) else panic "unexpected none"
        \\    var b: Ref(int) = Ref.from(right) else panic "unexpected none"
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
        \\    discard(Item{trace = (if const _selected_result_0: Ref(int) = Ref.from(source) -> _selected_result_0 else panic "unexpected none")})
        \\    return source
    , 42);
}

test "references owned handles survive borrowed variant conversion through an immutable argument" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func choose(imm handle: Ref(int)) Ref(int) | none -> handle
        \\func run() int
        \\    const source = [42]
        \\    if ref element: int = source.get(0)
        \\        if const handle: Ref(int) = choose((if const _selected_result_0: Ref(int) = Ref.from(element) -> _selected_result_0 else panic "unexpected none")) -> return handle.value
        \\    return 90
    , 42);
}

test "references list views keep allocation storage through copied descriptor frames" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var values: List(int) = [19, 23]
        \\    const view: Span(int) = values.slice(0..2) else return none
        \\    return view[0] + view[1]
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
        \\    ref element: int = owner.get(0) else return none
        \\    const observed = inspect((if const _selected_result_0: Ref(int) = Ref.from(element) -> _selected_result_0 else return none))
        \\    element += 18
        \\    return observed + element
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "references helper replacement invalidates allocated descendants but preserves the owner slot" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(ref owner: Box(int), var replacement: Box(int)) -> owner = replacement^
        \\func invalid() unit | none
        \\    var owner: Box(int) = Box.new(12) else return none
        \\    ref old = owner.borrow()
        \\    replace(owner, (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none))
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
        \\    var handles = [(if const _selected_result_0: Ref(int) = Ref.from(first) -> _selected_result_0 else return none)]
        \\    ref slot = handles[0]
        \\    slot = (if const _selected_result_1: Ref(int) = Ref.from(second) -> _selected_result_1 else return none)
        \\    return slot.value
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
        \\    if ref next: Ref(Node) = node.next -> return select(next.value, depth - 1)
        \\    return node
        \\func run() int
        \\    var first = Node{next = none, value = 12}
        \\    var second = Node{next = (if const _selected_result_0: Ref(Node) = Ref.from(first) -> _selected_result_0 else panic "unexpected none"), value = 30}
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
        \\    var owner: Allocation(int) = Allocation(int).allocate(1) else return none
        \\    if (owner.unsafe_initialize(0, 42) is unit) -> unit
        \\    else
        \\        owner^.deallocate()
        \\        return none
        \\    return observe(owner.unsafe_borrow(0), discard(owner^))
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
        \\    if const result: int = calculate() -> return result
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
        \\    var slice: Span(int) = complete.slice(0..1) else return none
        \\    ref item = slice[0]
        \\    item += 30
        \\    return source[0]
        \\func run() int
        \\    if const result: int = calculate() -> return result
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
        \\    return (if const _selected_result_0: Ref(int) = Ref.from(item) -> _selected_result_0 else panic "unexpected none")
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
        \\    if ref next: Box(Node) = node.next -> return last(next.borrow())
        \\    return node.value
        \\func calculate() int | none
        \\    var leaf: Box(Node) = Box.new(Node{next = none, value = 12}) else return none
        \\    var root = Node{next = leaf^, value = 0}
        \\    ref result = last(root)
        \\    result += 30
        \\    return result
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "references a parameter payload cannot survive replacing its variant tag" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid(ref source: int | none) int
        \\    if ref item: int = source
        \\        source = none
        \\        return item
        \\    return 90
        \\var source: int | none = 42
        \\exit(invalid(source))
    , .borrow_outlives_source);
}

test "references parameter replacement retains the new referent" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func replace(ref slot: Ref(int), ref source: int) -> slot = (if const _selected_result_0: Ref(int) = Ref.from(source) -> _selected_result_0 else panic "unexpected none")
        \\func run() int
        \\    var first = 10
        \\    var second = 40
        \\    var slot: Ref(int) = Ref.from(first) else panic "unexpected none"
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
        \\func install(var target: Ref(Ref(int)), ref source: int) -> target.value = (if const _selected_result_0: Ref(int) = Ref.from(source) -> _selected_result_0 else panic "unexpected none")
        \\func run() int
        \\    var original = 1
        \\    var replacement = 42
        \\    var slot: Ref(int) = Ref.from(original) else panic "unexpected none"
        \\    install((if const _selected_result_1: Ref(Ref(int)) = Ref.from(slot) -> _selected_result_1 else panic "unexpected none"), replacement)
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
        \\    owner = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\    slot = Ref.from(owner.borrow())
        \\    return ()
        \\func replace(mut owner: Box(int)) unit | none
        \\    var replacement: Box(int) = Box.new(17) else return none
        \\    owner = replacement^
        \\    return unit
        \\func invalid() int | none
        \\    var source = 1
        \\    var slot = Ref.from(source)
        \\    var owner: Box(int) = Box.new(10) else return none
        \\    const _: unit = install(slot, owner) else return none
        \\    const _: unit = replace(owner) else return none
        \\    return slot.value
        \\if const result: int = invalid() -> exit(result)
    , .borrow_outlives_source);
}
