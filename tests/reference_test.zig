const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

test "references custom drops preserve temporal conflicts between captures" {
    const declarations =
        \\struct Captures
        \\    left: Ref(String)
        \\    right: Ref(String)
        \\    trace: Ref(int)
        \\    drop = func(deinit self: Captures)
        \\        const view = self.left.value.view()
        \\        if self.right.value.append("x") -> ()
        \\        self.trace.value = view.byte_length() + 39
        \\func discard(var item: Captures) -> ()
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\fallible calculate() int
        \\    var left: String = "abc"
        \\    var right: String = ""
        \\    var trace = 0
        \\    discard(Captures{left = Ref.from(left), right = Ref.from(right), trace = Ref.from(trace)})
        \\    return trace
    , 42);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\fallible calculate() int
        \\    var buffer: String = "abc"
        \\    var trace = 0
        \\    discard(Captures{left = Ref.from(buffer), right = Ref.from(buffer), trace = Ref.from(trace)})
        \\    return trace
        \\_ = run()
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\fallible calculate() int
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
        \\fallible calculate() int
        \\    var owner: String = "abc"
        \\    const view = owner.view()
        \\    var trace = 0
        \\    discard(Observer{owner = Ref.from(owner), trace = Ref.from(trace)})
        \\    return view.byte_length() + trace + 36
        \\func run() int
        \\    if const result = calculate() -> return result
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
        .{ .clear = "if clear?\n        hook.target = none\n    else\n        hook.target = none", .clear_value = "true", .safe = true },
        .{ .clear = "if clear?\n        hook.target = none\n    else\n        hook.target = none", .clear_value = "false", .safe = true },
        .{ .clear = "if clear? -> hook.target = none", .clear_value = "false", .safe = false },
        .{ .clear = "if clear?\n        _ = hook\n        return view.byte_length() + 39\n    hook.target = none", .clear_value = "true", .safe = false },
        .{ .clear = "loop\n        if not clear? -> break\n        hook.target = none\n        clear = false", .clear_value = "false", .safe = false },
    }) |capture| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\struct Hook
            \\    move = none
            \\    target: Ref(String) | none
            \\    drop = func(deinit self: Hook)
            \\        if const target = self.target as Ref(String)
            \\            if target.value.append("x") -> ()
            \\fallible inspect(ref owner: String, ref clear: bool) int
            \\    const view = owner.view()
            \\    var hook = Hook{target = Ref.from(owner)}
            \\    $clear
            \\    _ = hook
            \\    return view.byte_length() + 39
            \\fallible calculate() int
            \\    var owner: String = "abc"
            \\    var clear = $clear_value
            \\    return inspect?(owner, clear)
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
            \\        if self.target.value.append("x") -> ()
            \\        return Hook{target = self.target}
            \\struct Wrapper
            \\    $member = fieldwise
            \\    value: Hook
            \\func consume(var hook: $container) -> ()
            \\fallible inspect(ref left: String, ref right: String) int
            \\    const view = left.view()
            \\    const hook: $container = $construct
            \\    consume(hook$transfer)
            \\    return view.byte_length() + 39
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 90
        , hook);
        defer std.testing.allocator.free(declarations);
        const unrelated = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\fallible calculate() int
            \\    var left: String = "abc"
            \\    var right: String = ""
            \\    return inspect?(left, right)
        });
        defer std.testing.allocator.free(unrelated);
        try Fixture.expectParity(unrelated, 42);
        const aliased = try std.mem.concat(std.testing.allocator, u8, &.{
            declarations, "\n",
            \\fallible calculate() int
            \\    var buffer: String = "abc"
            \\    return inspect?(buffer, buffer)
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
        \\    if ref item = selected as int -> item += 30
        \\    if const result = owner as int -> return result
        \\    return 90
    , 42);
}

test "callable widening preserves reference result contracts" {
    for ([_][]const u8{
        \\func source(ref value: int) int -> value
        \\func accept(callback: fallible(ref int) ref int) -> ()
        \\accept(source)
        ,
        \\func source(ref value: int) ref int -> value
        \\func accept(callback: fallible(ref int) int) -> ()
        \\accept(source)
        ,
    }) |source| try Fixture.expectSourceDiagnostic(source, .call_argument_type_mismatch);
    try Fixture.expectParity(
        \\func identity(ref value: int) ref int -> value
        \\func run() int
        \\    var source = 42
        \\    const callback: fallible(ref int) ref int = identity
        \\    if ref result = callback(source) -> return result
        \\    return 1
    , 42);
}

test "references readonly borrows preserve owner cleanup authority" {
    try Fixture.expectParity(
        \\struct Item
        \\    move = none
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\fallible calculate(var trace: Ref(int)) int
        \\    const owner = Box.new?(Item{trace = trace, value = 2})
        \\    return owner.borrow().value + 38
        \\func run() int
        \\    var trace = Array(int, 1).filled(0)
        \\    if ref target = trace.get(0)
        \\        if const value = calculate(Ref.from(target)) -> return value + target
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
        \\fallible compute() int
        \\    var array = [1, 2]
        \\    ref first = array[0]
        \\    ref second = array[1]
        \\    first += 9
        \\    second += 8
        \\    var list: List(int) = [1, 2]
        \\    ref third = list.get?(0)
        \\    ref fourth = list.get?(1)
        \\    third += 10
        \\    fourth += 9
        \\    return first + second + third + fourth
        \\func run() int
        \\    if const result = compute() -> return result
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
        \\    if ref payload = owner as Payload
        \\        update(payload.value)
        \\    if ref result = owner as Payload -> return result.value
        \\    return 90
    , 42);
}

test "references borrowed fallible results bind conditionally without copying" {
    try Fixture.expectParity(
        \\struct Payload
        \\    pub value: int
        \\fallible select(ref owner: Payload, index: int) ref Payload
        \\    index == 0
        \\    return owner
        \\func run() int
        \\    var owner = Payload{value = 12}
        \\    if ref item = select(owner, 0)
        \\        item.value += 30
        \\    if ref absent = select(owner, 1) -> return 90
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
        \\    if ref selected = result as int -> selected += 25
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
        \\    if ref result = carrier as int -> return result
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
        \\if ref result = carrier as int -> result += 25
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
        \\    if ref result = carrier as int -> return result
        \\    return 90
    , 42);
}

test "references variant logical matching aliases either storage kind" {
    try Fixture.expectParity(
        \\struct End
        \\    copy = trivial
        \\func capture(ref value: int) ref int | End -> value
        \\func choose(ref value: int, borrowed: bool) int | ref int | End
        \\    if borrowed? -> return capture(value)
        \\    return 17
        \\func update(ref value: int, borrowed: bool) int
        \\    var carrier = choose(value, borrowed)
        \\    if ref selected = carrier as int
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
        \\    if const selected = capture(owner) as int
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
        \\    if present? -> return value
        \\    return none
        \\func inspect(ref owner: int, present: bool) int
        \\    const carrier = capture(owner, present)
        \\    if const selected = carrier as (int | none)
        \\        if const value = selected as int -> return value + 25
        \\        return 42
        \\    return 90
        \\func run() int
        \\    var owner = 17
        \\    if inspect(owner, true) <> 42 -> return 91
        \\    return inspect(owner, false)
    , 42);
    try Fixture.expectParity(
        \\func produce(first: bool) none | Array(int, 3) | int
        \\    if first? -> return [10, 11, 21]
        \\    return 42
        \\func inspect(first: bool) int
        \\    if const selected = produce(first) as (Array(int, 3) | int)
        \\        if const number = selected as int -> return number
        \\        if ref values = selected as Array(int, 3)
        \\            if const last = values.get(2) -> return last + 21
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
        \\    if const selected = pair as (int, int) -> return selected.0 + selected.1
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

test "references readonly recursive owners cannot upgrade owned views" {
    try Fixture.expectAnySourceDiagnostic(
        \\struct Node
        \\    next: Box(Node) | none
        \\    view: Span(int) | none
        \\func selected(ref node: Node) Span(int)
        \\    if ref next = node.next as Box(Node) -> return selected(next.borrow())
        \\    if const view = node.view as Span(int) -> return view
        \\    panic
        \\func forward(imm node: Node) Span(int) -> selected(node)
        \\fallible calculate()
        \\    var values = [41]
        \\    var leaf = Box.new?(Node{next = none, view = values.span()})
        \\    const root = Node{next = leaf^, view = none}
        \\    var view = forward(root)
        \\    view[0] = 42
        \\if calculate() -> ()
    , .reference_not_writable);
}

test "references readonly recursive owners return writable captured handles" {
    try Fixture.expectParity(
        \\struct Node
        \\    next: Box(Node) | none
        \\    target: Ref(int)
        \\func selected(ref node: Node) Ref(int)
        \\    if ref next = node.next as Box(Node) -> return selected(next.borrow())
        \\    return node.target
        \\func forward(imm node: Node) Ref(int) -> selected(node)
        \\fallible calculate() int
        \\    var target = 41
        \\    var leaf = Box.new?(Node{next = none, target = Ref.from(target)})
        \\    const root = Node{next = leaf^, target = Ref.from(target)}
        \\    const handle = forward(root)
        \\    handle.value += 1
        \\    return target
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "references recursive parameter outputs retain replacement authority and lifetime" {
    const source =
        \\struct Node
        \\    next: Box(Node) | none
        \\    target: Ref(int)
        \\func replace(ref node: Node, ref source: int)
        \\    if ref next = node.next as Box(Node) -> replace(next.borrow(), source)
        \\    else
        \\        node.target = Ref.from(source)
        \\func selected(ref node: Node) Ref(int)
        \\    if ref next = node.next as Box(Node) -> return selected(next.borrow())
        \\    return node.target
        \\fallible calculate() int
        \\    var original = 0
        \\    var replacement = 41
        \\    var leaf = Box.new?(Node{next = none, target = Ref.from(original)})
        \\    var root = Node{next = leaf^, target = Ref.from(original)}
        \\    replace(root, replacement)
        \\    const handle = selected(root)
        \\    handle.value += 1
        \\    return replacement
        \\func run() int
        \\    if const result = calculate() -> return result
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
        \\        if not self.ready? -> return End{}
        \\        self.ready = false
        \\        return self.source.value
        \\struct Zip(L: type, R: type, A: type, B: type)
        \\    left: L
        \\    right: R
        \\    func next(mut self: Zip(L, R, A, B)) (ref A, ref B) | End
        \\        const left_result = self.left.next()
        \\        if ref left_item = left_result as A
        \\            const right_result = self.right.next()
        \\            if ref right_item = right_result as B
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
        \\    if ref pair = result as (ref Left, ref Right)
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
        \\if ref pair = result as (ref Left, ref Right) -> pair.1.value += 1
    , .reference_not_writable);
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func first(ref left: Left) ref Left
        \\    const right = Right{value = 7}
        \\    var zipped = Zip(Cursor(Left), Cursor(Right), Left, Right){left = Cursor(Left){source = Ref.from(left), ready = true}, right = Cursor(Right){source = Ref.from(right), ready = true}}
        \\    const result = zipped.next()
        \\    if const pair = result as (ref Left, ref Right) -> return pair.0
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
        \\    if const pair = result as (ref Left, ref Right)
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
        \\if const pair = result as (ref Left, ref Right) -> pair.0.value += 1
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
        \\if const copied = capture(owner) as Item -> exit(copied.value)
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
        \\    if ref item = choose(number, flag, true) as int | bool -> return 1
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
        \\    if ref item = carrier as int | bool -> item = 42
        \\    if const item = owner as int -> return item
        \\    return 90
    , 42);
}

test "references logical payload borrows do not retain temporary carriers" {
    const declarations =
        \\func capture(ref owner: int) ref int | End -> owner
    ;
    try Fixture.expectParity(declarations ++ "\n" ++
        \\func selected(ref owner: int) ref int
        \\    if ref item = capture(owner) as int -> return item
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
        \\    if ref item = carrier as int
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
        \\if ref item = capture(owner) as int -> item += 30
    , .reference_not_writable);
    try Fixture.expectAnySourceDiagnostic(declarations ++ "\n" ++
        \\func invalid() ref int
        \\    var owner = 12
        \\    if ref item = capture(owner) as int -> return item
        \\    exit(90)
        \\_ = invalid()
    , .borrow_outlives_source);
    try Fixture.expectAnySourceDiagnostic(
        \\var carrier: int | End = 12
        \\if ref item = carrier as int
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
        \\    const first = Ref.from(owner)
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
        \\fallible invalid()
        \\    var owner = 12
        \\    var values = [1]
        \\    const original = Mixed{target = Ref.from(owner), view = values.span()}
        \\    var copied = original
        \\    ref item = copied.view.get?(0)
        \\    item = 42
        \\if invalid() -> unit
    , .reference_not_writable);
}

test "references const aggregate copies preserve array and variant captures" {
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    const original = [Ref.from(owner)]
        \\    var copied = original
        \\    if ref handle = copied.get(0) -> handle.value += 30
        \\    return owner
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    var owner = 12
        \\    const original: Ref(int) | none = Ref.from(owner)
        \\    var copied = original
        \\    if ref handle = copied as Ref(int) -> handle.value += 30
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
        \\if ref item = handle.value as int -> item += 1
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\const source: int | none = 42
        \\const readonly = Ref.from(source)
        \\var handle = readonly
        \\if ref item = handle.value as int -> item += 1
    , .reference_not_writable);
    try Fixture.expectParity(
        \\func run() int
        \\    var source: int | none = 41
        \\    const handle = Ref.from(source)
        \\    if ref item = handle.value as int -> item += 1
        \\    if ref item = source as int -> return item
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
        \\fallible invalid()
        \\    var owner = [12]
        \\    var view = owner.span().as_imm()
        \\    ref item = view[0]
        \\    item = 42
        \\if invalid() -> unit
    , .reference_not_writable);
}

test "references returning a referent does not capture an intermediate handle owner" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\func referent(ref handle: Ref(int)) ref int -> handle.value
        \\func capture(ref owner: int) Ref(int)
        \\    var temporary = Ref.from(owner)
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
        \\    update(handle)
        \\    return source
    , 42);
}

test "references containers of handles expose the handle slot and copy only its contents" {
    try Fixture.expectParity(
        \\import std.memory.{Ref}
        \\fallible capture(ref source: int) Ref(int)
        \\    var handles = [Ref.from(source)]
        \\    ref slot = handles[0]
        \\    slot.value += 10
        \\    return handles[0]
        \\fallible calculate() int
        \\    var source = 12
        \\    var copied = capture?(source)
        \\    copied.value += 20
        \\    return source
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "references variant payload aliases cannot survive a changed active tag" {
    try Fixture.expectSourceDiagnostic(
        \\struct Payload
        \\    pub value: int
        \\var owner: Payload | none = Payload{value = 42}
        \\if ref payload = owner as Payload
        \\    owner = none
        \\    exit(payload.value)
    , .borrow_outlives_source);
}

test "references list element aliases cannot survive reallocation" {
    try Fixture.expectSourceDiagnostic(
        \\fallible invalid()
        \\    var owner: List(int) = [42]
        \\    ref item = owner[0]
        \\    owner.reserve?(128)
        \\    exit(item)
        \\if invalid() -> unit
    , .borrow_outlives_source);
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
        \\    var b = Ref.from(right)
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
        \\    if ref element = source.get(0)
        \\        if const handle = choose(Ref.from(element)) as Ref(int) -> return handle.value
        \\    return 90
    , 42);
}

test "references list views keep allocation storage through copied descriptor frames" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var values: List(int) = [19, 23]
        \\    const view = values.slice?(0..2)
        \\    return view[0] + view[1]
        \\func run() int
        \\    if const result = calculate() -> return result
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
        \\fallible calculate() int
        \\    var owner: List(int) = [12]
        \\    ref element = owner.get?(0)
        \\    const observed = inspect(Ref.from(element))
        \\    element += 18
        \\    return observed + element
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "references helper replacement invalidates allocated descendants but preserves the owner slot" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(ref owner: Box(int), var replacement: Box(int)) -> owner = replacement^
        \\fallible invalid()
        \\    var owner = Box.new?(12)
        \\    ref old = owner.borrow()
        \\    replace(owner, Box.new?(42))
        \\    print("replaced")
        \\    old += 1
        \\if invalid() -> unit
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
        \\fallible calculate() int
        \\    var first = 12
        \\    var second = 42
        \\    var handles = [Ref.from(first)]
        \\    ref slot = handles[0]
        \\    slot = Ref.from(second)
        \\    return slot.value
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\fallible invalid() int
        \\    const original = 42
        \\    var handles = [Ref.from(original)]
        \\    if 1 == 1
        \\        const temporary = 12
        \\        ref slot = handles[0]
        \\        slot = Ref.from(temporary)
        \\    return handles[0].value
        \\if invalid() -> unit
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
        \\    if ref next = node.next as Ref(Node) -> return select(next.value, depth - 1)
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
        \\fallible calculate() int
        \\    var owner = Allocation(int).allocate?(1)
        \\    if owner.unsafe_initialize(0, 42) -> unit
        \\    else
        \\        owner^.deallocate()
        \\        fail
        \\    return observe(owner.unsafe_borrow(0), discard(owner^))
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "references span capabilities survive copies calls fields and joins" {
    try Fixture.expectParity(
        \\func retain(ref view: Span(int)) Span(int) -> view
        \\fallible calculate() int
        \\    var owner = [12]
        \\    var view = owner.span()
        \\    const callback: func(ref Span(int)) Span(int) = retain
        \\    var copied = callback(view)
        \\    ref item = copied[0]
        \\    item += 30
        \\    return owner[0]
        \\func run() int
        \\    if const result = calculate() -> return result
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
            \\fallible invalid(choice: int)
            \\    var owner = [12]
            \\    $setup
            \\    ref item = selected[0]
            \\    item = 42
            \\if invalid(1) -> unit
        , .{ .setup = setup });
        defer std.testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .reference_not_writable);
    }
    try Fixture.expectSourceDiagnostic(
        \\func retain(ref view: Span(int)) Span(int) -> view
        \\fallible invalid(callback: func(ref Span(int)) Span(int))
        \\    var owner = [12]
        \\    var view = owner.span()
        \\    var selected = callback(view)
        \\    ref item = selected[0]
        \\    item = 42
        \\if invalid(retain) -> unit
    , .reference_not_writable);
}

test "references slicing a writable span preserves captured permission" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var source = [12, 0]
        \\    var complete = source.span()
        \\    var slice = complete.slice?(0..1)
        \\    ref item = slice[0]
        \\    item += 30
        \\    return source[0]
        \\func run() int
        \\    if const result = calculate() -> return result
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
        \\    if ref next = node.next as Box(Node) -> return last(next.borrow())
        \\    return node.value
        \\fallible calculate() int
        \\    var leaf = Box.new?(Node{next = none, value = 12})
        \\    var root = Node{next = leaf^, value = 0}
        \\    ref result = last(root)
        \\    result += 30
        \\    return result
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "references a parameter payload cannot survive replacing its variant tag" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid(ref source: int | none) int
        \\    if ref item = source as int
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
        \\func replace(ref slot: Ref(int), ref source: int) -> slot = Ref.from(source)
        \\func run() int
        \\    var first = 10
        \\    var second = 40
        \\    var slot = Ref.from(first)
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
        \\func install(var target: Ref(Ref(int)), ref source: int) -> target.value = Ref.from(source)
        \\func run() int
        \\    var original = 1
        \\    var replacement = 42
        \\    var slot = Ref.from(original)
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
        \\    if selected?
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
        \\fallible install(mut slot: Ref(int), mut owner: Box(int))
        \\    owner = Box.new?(42)
        \\    slot = Ref.from(owner.borrow())
        \\fallible replace(mut owner: Box(int)) -> owner = Box.new?(17)
        \\fallible invalid() int
        \\    var source = 1
        \\    var slot = Ref.from(source)
        \\    var owner = Box.new?(10)
        \\    install?(slot, owner)
        \\    replace?(owner)
        \\    return slot.value
        \\if const result = invalid() -> exit(result)
    , .borrow_outlives_source);
}
