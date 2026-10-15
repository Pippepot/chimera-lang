const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;

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

test "references readonly source cannot acquire writable access through a mutable handle" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\const source = 12
        \\var handle = Ref.from(source)
        \\handle.value = 42
    , .reference_not_writable);
}

test "references copying a readonly handle keeps readonly authority" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\var source = 12
        \\const first = Ref.from(source)
        \\var second = first
        \\second.value = 42
    , .reference_not_writable);
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
        \\var source = 12
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
        \\var source = 12
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
        \\    const view = values.view?(0, 2)
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
        \\    var slice = complete.slice?(0, 1)
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
        \\    copy = func(imm self: Install) Install
        \\        self.target.value = self.source
        \\        return Install{target = self.target, source = self.source}
        \\func selected(ref initial: int) Ref(int)
        \\    var result = Ref.from(initial)
        \\    var local = 42
        \\    const source = Install{target = Ref.from(result), source = Ref.from(local)}
        \\    const copied = source
        \\    _ = copied
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
