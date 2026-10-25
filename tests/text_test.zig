const std = @import("std");
const test_sources = @import("test_sources");
const SourceFixture = test_sources.SourceFixture;

test "scalar string converters format decimal limits booleans and empty values in both engines" {
    try SourceFixture.expectParity(
        \\func run() int
        \\    if String(0) <> "0" -> return 90
        \\    if String(1) <> "1" -> return 91
        \\    if String(-10) <> "-10" -> return 92
        \\    if String(2147483647) <> "2147483647" -> return 93
        \\    if String(-2147483648) <> "-2147483648" -> return 94
        \\    const byte_value: byte = 255
        \\    if String(byte_value) <> "255" -> return 95
        \\    if String(true) <> "true" or String(false) <> "false" -> return 96
        \\    if String(()) <> "()" or String(none) <> "none" -> return 97
        \\    const view: StringView = "hé\0"
        \\    if String(view) <> "hé\0" -> return 98
        \\    if const text = String(42)
        \\        if text <> "42" -> return 99
        \\    else
        \\        return 100
        \\    return 42
    , 42);
}

test "collection string converters recursively borrow strings and custom move only elements" {
    try SourceFixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub value: int
        \\pub converter(imm value: Item) String -> String(value.value)
        \\func inspect() int | none
        \\    var values = [Item{value = -2}, Item{value = 42}]
        \\    if String(values) <> "[-2, 42]" -> return 90
        \\    if String(values.span()) <> "[-2, 42]" -> return 91
        \\    if String((if const _selected_result_0: Span(Item) = values.slice(1..) -> _selected_result_0 else return none)) <> "[42]" -> return 92
        \\    const nested = [[1, 2], [3, 4]]
        \\    if String(nested) <> "[[1, 2], [3, 4]]" -> return 93
        \\    if String([1, 2]) <> "[1, 2]" -> return 103
        \\    const converted: String = [[1], [2]]
        \\    if converted <> "[[1], [2]]" -> return 104
        \\    const words = ["hello", "world"]
        \\    if String(words) <> "[hello, world]" -> return 94
        \\    if words[0] <> "hello" -> return 95
        \\    const list: List(Item) = [Item{value = 1}, Item{value = 2}]
        \\    if String(list) <> "[1, 2]" -> return 96
        \\    if list[1].value <> 2 -> return 97
        \\    const empty: Array(int, 0) = []
        \\    if String(empty) <> "[]" -> return 98
        \\    const bytes: Array(byte, 3) = [0, 128, 255]
        \\    if String(BytesView.from_array(3, bytes)) <> "[0, 128, 255]" -> return 99
        \\    if String((if const _selected_result_1: Ref(Item) = Ref.from(values[1]) -> _selected_result_1 else return none)) <> "Ref(42)" -> return 100
        \\    const boxed: Box(Item) = Box(Item).new(Item{value = 42}) else return none
        \\    if String(boxed) <> "Box(42)" -> return 101
        \\    return values[0].value + 44
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 102
    , 42);
}

test "string conversion borrows immovable elements and drops each owner once" {
    try SourceFixture.expectParity(
        \\struct Item
        \\    move = none
        \\    copy = none
        \\    pub value: int
        \\    pub drops: Ref(int)
        \\    drop = func(deinit self: Item) -> self.drops.value += self.value
        \\pub converter(imm value: Item) String -> String(value.value)
        \\func render(ref drops: int) String
        \\    const values = [Item{value = 19, drops = (if const _selected_result_0: Ref(int) = Ref.from(drops) -> _selected_result_0 else panic "unexpected none")}, Item{value = 23, drops = (if const _selected_result_1: Ref(int) = Ref.from(drops) -> _selected_result_1 else panic "unexpected none")}]
        \\    const text = String(values)
        \\    if drops <> 0 -> panic "formatting consumed an element"
        \\    if values.len() <> 2 -> panic "formatting changed the source"
        \\    return text^
        \\func run() int
        \\    var drops = 0
        \\    const text = render(drops)
        \\    if text <> "[19, 23]" -> return 90
        \\    return drops
    , 42);
}

test "string conversion preserves owner cleanup on explicit mismatch" {
    try SourceFixture.expectParity(
        \\struct Item
        \\    copy = none
        \\    pub drops: Ref(int)
        \\    drop = func(deinit self: Item) -> self.drops.value += 1
        \\pub converter(imm value: Item) String -> "item"
        \\func stop() Item | none -> return none
        \\func late(ref count: int) Item
        \\    count += 10
        \\    return Item{drops = (if const _selected_result_0: Ref(int) = Ref.from(count) -> _selected_result_0 else panic "unexpected none")}
        \\func render(ref drops: int, ref calls: int) String | none
        \\    const prefix = [Item{drops = Ref.from(drops)}]
        \\    const text = String(prefix)
        \\    const _: Item = stop() else return none
        \\    late(calls)
        \\    return text^
        \\func run() int
        \\    var counters = [0, 0]
        \\    if ref drops: int = counters.get(0)
        \\        if ref calls: int = counters.get(1)
        \\            if const text: String = render(drops, calls) -> return 90
        \\            return drops + calls + 41
        \\    return 91
    , 42);
}

test "range string converters preserve independently omitted bounds and inclusivity" {
    try SourceFixture.expectParity(
        \\func run() int
        \\    if String(-2..4) <> "-2..4" -> return 90
        \\    if String(1..=3) <> "1..=3" -> return 91
        \\    if String(..3) <> "..3" -> return 92
        \\    if String(2..) <> "2.." -> return 93
        \\    if String(..) <> ".." -> return 94
        \\    return 42
    , 42);
}

test "runtime optional range bounds share slicing and formatting consumers" {
    try SourceFixture.expectParity(
        \\import std.range.{Range}
        \\func select(include_first: bool, include_limit: bool) Range
        \\    const first: int | none = if include_first -> 1 else none
        \\    const limit: int | none = if include_limit -> 3 else none
        \\    return first..limit
        \\func calculate() int | none
        \\    var values = [10, 20, 30, 40]
        \\    const list: List(int) = [10, 20, 30, 40]
        \\    var span = values.span()
        \\    const text: StringView = "abcd"
        \\    const bytes: BytesView = "abcd"
        \\    const ranges = [select(true, true), select(false, true), select(true, false), select(false, false)]
        \\    var length = 0
        \\    for bounds in ranges
        \\        const array_slice: Span(int) = values.slice(bounds) else return none
        \\        const list_slice: Span(int) = list.slice(bounds) else return none
        \\        const span_slice: Span(int) = span.slice(bounds) else return none
        \\        const text_slice: StringView = text.slice(bounds) else return none
        \\        const bytes_slice: BytesView = bytes.slice(bounds) else return none
        \\        const size = array_slice.len()
        \\        if not (size == list_slice.len()) -> return none
        \\        if not (size == span_slice.len()) -> return none
        \\        if not (size == text_slice.byte_length()) -> return none
        \\        if not (size == bytes_slice.byte_length()) -> return none
        \\        length += size
        \\    if not (String(ranges[0]) == "1..3") -> return none
        \\    if not (String(ranges[1]) == "..3") -> return none
        \\    if not (String(ranges[2]) == "1..") -> return none
        \\    if not (String(ranges[3]) == "..") -> return none
        \\    return length + 30
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "text equality compares exact UTF-8 bytes including empty strings and NUL" {
    try SourceFixture.expectParity(
        \\func run() int
        \\    const view: StringView = "hé\0"
        \\    const identical: StringView = "hé\0"
        \\    if view <> identical -> return 90
        \\    if view == "hé" -> return 91
        \\    if view == "hè\0" -> return 92
        \\    if "" <> "" -> return 93
        \\    if "é" == "e\u{301}" -> return 94
        \\    const equal = bool(StringView.==(view, identical))
        \\    const different = StringView.<>
        \\    if equal and different(view, "hè\0") -> return 42
        \\    return 95
    , 42);
}

test "owned String equality survives growth cloning and literal conversion" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    var text = "hé"
        \\    const _: unit = text.append("\0") else return none
        \\    const duplicate: String = text.clone() else return none
        \\    const view: StringView = "hé\0"
        \\    if view <> text -> return 89
        \\    if text <> duplicate -> return 90
        \\    if text == "hé" -> return 91
        \\    const equal = String.==
        \\    if equal(text, "hé\0") -> return 42
        \\    return 92
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 93
    , 42);
}

test "independent structs with literal views permit alternating mutable calls and loops" {
    try SourceFixture.expectParity(
        \\struct Named
        \\    pub name: StringView
        \\    pub health: int
        \\func hit(imm attacker: Named, mut defender: Named)
        \\    defender.health -= attacker.health
        \\func run() int
        \\    var knight = Named{name = "knight", health = 4}
        \\    var dragon = Named{name = "dragon", health = 10}
        \\    hit(knight, dragon)
        \\    hit(dragon, knight)
        \\    var count = 0
        \\    loop
        \\        if count == 2 -> break
        \\        hit(knight, dragon)
        \\        hit(dragon, knight)
        \\        count += 1
        \\    if knight.name <> "knight" or dragon.name <> "dragon" -> return 90
        \\    return knight.health + dragon.health + 52
    , 42);
}

test "mutable view outputs still depend on compatible inline owner storage" {
    const source =
        \\struct Owner
        \\    pub bytes: Array(byte, 1)
        \\struct View
        \\    pub text: StringView
        \\func attach(imm source: Owner, mut target: View) unit | none
        \\    target.text = (if const text: StringView = BytesView.from_array(1, source.bytes).validate_utf8() -> text else return none)
        \\    return ()
        \\func conflict(mut source: Owner, imm view: View) -> return
        \\func inspect() int | none
        \\    var owner = Owner{bytes = [65]}
        \\    var view = View{text = "literal"}
        \\    const _: unit = attach(owner, view) else return none
        \\    conflict(owner, view)
        \\    return view.text.byte_length()
        \\if const result: int = inspect() -> exit(result)
        \\exit(90)
    ;
    try SourceFixture.expectSourceDiagnostic(source, .overlapping_mutable_arguments);
}

test "loop alias checks reject an owner reached through a later backedge" {
    try SourceFixture.expectSourceDiagnostic(
        \\import std.memory.{Ref}
        \\func conflict(mut owner: int, imm reference: Ref(int)) -> return
        \\func run() int
        \\    var first = 19
        \\    var second = 23
        \\    var reference = Ref.from(first)
        \\    var count = 0
        \\    loop
        \\        if count == 2 -> break
        \\        conflict(second, reference)
        \\        reference = Ref.from(second)
        \\        count += 1
        \\    return first + second
        \\exit(run())
    , .overlapping_mutable_arguments);
}

test "call borrow precision recomputes when source storage types change" {
    const source =
        \\struct Named
        \\    pub name: StringView
        \\    pub health: int
        \\func hit(imm attacker: Named, mut defender: Named)
        \\    defender.health -= attacker.health
        \\func run() int
        \\    var knight = Named{name = "knight", health = 4}
        \\    var dragon = Named{name = "dragon", health = 10}
        \\    hit(knight, dragon)
        \\    hit(dragon, knight)
        \\    return knight.health + 44
        \\exit(run())
    ;
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const fields = try std.mem.replaceOwned(u8, std.testing.allocator, source, "pub health: int", "pub health: int\n    pub bytes: Array(byte, 1)");
    defer std.testing.allocator.free(fields);
    const first = try std.mem.replaceOwned(u8, std.testing.allocator, fields, "health = 4}", "health = 4, bytes = [65]}");
    defer std.testing.allocator.free(first);
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, first, "health = 10}", "health = 10, bytes = [66]}");
    defer std.testing.allocator.free(changed);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, changed);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(test_sources.queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "UTF-8 literals default to String and preserve byte counts in both engines" {
    try SourceFixture.expectParity(
        \\static greeting = "é\u{1f600}\0"
        \\func run() int
        \\    const text = "é\u{1f600}\0"
        \\    return text.byte_length() + greeting.byte_length()
    , 14);
}

test "literal views slice on UTF-8 boundaries and widen bytes explicitly" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    const text: StringView = "aé\0"
        \\    const suffix: StringView = text.slice(1..3) else return none
        \\    const bytes = suffix.as_bytes()
        \\    const first: byte = bytes.get(0) else return none
        \\    if text.slice(2..3) is StringView -> return 90
        \\    if text.slice(-1..0) is StringView -> return 91
        \\    return byte_int(first) - 153
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 92
    , 42);
}

test "reference casts project variant payloads without copying" {
    try SourceFixture.expectParity(
        \\import std.memory
        \\pub struct Payload
        \\    pub number: int
        \\func run() int
        \\    var value: Payload | none = Payload{number = 19}
        \\    if ref payload: Payload = value -> payload.number = 42
        \\    if ref payload: Payload = value -> return payload.number
        \\    return 90
    , 42);
}

test "borrowed variant payloads can be replaced by a different member shape" {
    try SourceFixture.expectParity(
        \\import std.memory
        \\struct Small
        \\    copy = trivial
        \\    pub number: int
        \\struct Large
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\func run() int
        \\    var value: Small | Large = Small{number = 1}
        \\    if ref payload: Small = value -> payload.number = 42
        \\    const replacement: Small | Large = Large{first = 19, second = 23}
        \\    value = replacement
        \\    if ref payload: Large = value -> return payload.first + payload.second
        \\    return 90
    , 42);
}

test "strings detach literal storage grow clone and clean both owners" {
    try SourceFixture.expectParity(
        \\func calculate() int | none
        \\    var text = "hé"
        \\    const _: unit = text.reserve(0) else return none
        \\    const _: unit = text.append("llo") else return none
        \\    var duplicate: String = text.clone() else return none
        \\    const _: unit = duplicate.append("!") else return none
        \\    const bytes = text.as_bytes()
        \\    if const first: byte = bytes.get(0)
        \\        return text.byte_length() + duplicate.byte_length() + byte_int(first) - 75
        \\    return 90
        \\func run() int
        \\    if const answer: int = calculate() -> return answer
        \\    return 91
    , 42);
}

test "malformed demanded literals have source diagnostics" {
    try SourceFixture.expectSourceDiagnostic("const text = \"\\q\"", .invalid_string_escape);
    try SourceFixture.expectSourceDiagnostic("const text = \"\\u{d800}\"", .invalid_string_escape);
    try SourceFixture.expectSourceDiagnostic("const text = \"\\xC0\\x80\"", .invalid_string_utf8);
    const source = "const text = \"ok\\u{e9}\\xFF\"";
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .invalid_string_utf8);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(test_sources.queries.BuildExecutable, 0, test_sources.structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "\\xFF").?, diagnostics[0].span.?.start);
}

test "literal escapes and empty array views preserve exact bytes in both engines" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    const bytes: BytesView = "\"\\\n\r\t\0"
        \\    const array: Array(byte, 0) = []
        \\    const empty = BytesView.from_array(0, array)
        \\    const text: StringView = empty.validate_utf8() else return none
        \\    if (empty.get(0) is byte) -> return 90
        \\    return byte_int((if const _selected_result_0: byte = bytes.get(0) -> _selected_result_0 else return none)) + bytes.byte_length() + text.byte_length() + 2
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 91
    , 42);
}

test "string literals materialize as StaticString for every runtime target" {
    try SourceFixture.expectParity(
        \\static constant: String = "lmnop"
        \\func size(imm text: StaticString) int -> text.byte_length()
        \\func run() int
        \\    const first: StringView = "ab"
        \\    const second: StringView = "cde"
        \\    const bytes: BytesView = "fghi"
        \\    const owned = "jk"
        \\    const literal: StaticString = "qrstuv"
        \\    const choice: StaticString | none = "w"
        \\    if const present: StaticString = choice
        \\        return first.byte_length() + second.byte_length() + bytes.byte_length() + owned.byte_length() + constant.byte_length() + size(literal) + size(present) + 19
        \\    return 90
    , 42);
}

test "distinct string literals share converter instances" {
    const fixture = try SourceFixture.init(
        \\const first: StringView = "first"
        \\const second: StringView = "second"
        \\const owned = "third"
        \\exit(first.byte_length() + second.byte_length() + owned.byte_length())
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 16);
    const reachable = (try fixture.db.get(test_sources.queries.CollectReachableInstances, 0)).*.?;
    for (reachable.instances) |instance| {
        const tuple = instance.specialization orelse continue;
        for ((try fixture.db.lookupInterned(test_sources.queries.CompileTimeValueTuples, tuple)).values) |value_id| {
            const value = try fixture.db.lookupInterned(test_sources.queries.CompileTimeValues, value_id);
            try std.testing.expect(value.* != .runtime or value.runtime.type_id != .string_literal);
        }
    }
}

test "user literal converters receive canonical string literal values" {
    try SourceFixture.expectParity(
        \\struct Label
        \\    pub size: int
        \\pub converter(static value: string_literal) Label
        \\    const text: StringView = value
        \\    return Label{size = text.byte_length()}
        \\func run() int
        \\    const label: Label = "hello"
        \\    return label.size + 37
    , 42);
}

test "literal conversion widens into a variant containing text" {
    try SourceFixture.expectParity(
        \\func text() StringView | none -> "hello"
        \\func run() int
        \\    const value: StringView | none = text()
        \\    if const view: StringView = value -> return view.byte_length() + 37
        \\    return 90
    , 42);
}

fn expectIo(source: []const u8, input: []const u8, output: []const u8, errors: []const u8, status: u8) !void {
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    const result = try fixture.runIo(input);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = status }, result.term);
    try std.testing.expectEqualSlices(u8, output, result.stdout);
    try std.testing.expectEqualSlices(u8, errors, result.stderr);
}

test "print accepts scalar collection and custom string converters and evaluates once" {
    try expectIo(
        \\struct Item
        \\    copy = none
        \\    pub count: Ref(int)
        \\pub converter(imm value: Item) String
        \\    value.count.value += 1
        \\    return "item"
        \\func make(count: Ref(int)) Item
        \\    count.value += 10
        \\    return Item{count = count}
        \\func output()
        \\    var count = 0
        \\    print(-2147483648)
        \\    print(true)
        \\    print(false)
        \\    print(())
        \\    print(none)
        \\    print([[1, 2], [3, 4]])
        \\    print(["hello", "world"])
        \\    print(make((if const _selected_result_0: Ref(int) = Ref.from(count) -> _selected_result_0 else panic "unexpected none")))
        \\    print(count)
        \\    const write_integer: func(imm int) unit = print
        \\    write_integer(42)
        \\output()
        \\exit(42)
    , "", "-2147483648\ntrue\nfalse\n()\nnone\n[[1, 2], [3, 4]]\n[hello, world]\nitem\n11\n42\n", "", 42);
}

test "print requires a usable string converter including collection elements" {
    for ([_][]const u8{ "Missing{}", "[Missing{}]", "[10, Missing{}]" }) |expression| {
        const source = try std.testing.allocator.print("struct Missing\nprint({s})", .{expression});
        defer std.testing.allocator.free(source);
        try SourceFixture.expectAnySourceDiagnostic(source, .local_type_mismatch);
    }
}

test "variant string conversion formats heterogeneous collections without copying strings" {
    try SourceFixture.expectParity(
        \\func length(static T: type, imm value: T) int -> String(value).byte_length()
        \\func run() int
        \\    const values = [10, "Hello", [1, 2, 3]]
        \\    if String(values) <> "[10, Hello, [1, 2, 3]]" -> return 90
        \\    if String(values.span()) <> "[10, Hello, [1, 2, 3]]" -> return 91
        \\    const list: List(int | String) = [42, "hello"]
        \\    if String(list) <> "[42, hello]" -> return 92
        \\    var number = 42
        \\    const reference: ref int | bool = number
        \\    const boolean: ref int | bool = true
        \\    if String(reference) <> "42" or String(boolean) <> "true" -> return 93
        \\    return length(values) + length(list) + 9
    , 42);
    try expectIo(
        \\const arr = [10, "Hello", [1, 2, 3]]
        \\print(arr)
        \\const i = 10
        \\print(i)
    , "", "[10, Hello, [1, 2, 3]]\n10\n", "", 0);
}

test "text output writes exact UTF-8 NUL and newline bytes to standard streams" {
    try expectIo(
        \\import std.io.{write_text, stdout, stderr}
        \\func output() unit | none
        \\    print("é\0")
        \\    const _: unit = write_text(stderr, "oops") else return none
        \\    const _: unit = write_text(stdout, "") else return none
        \\    return unit
        \\if const _: unit = output() -> exit(42)
        \\exit(90)
    , "", "é\x00\n", "oops", 42);
}

test "byte input initializes only the returned prefix and reports EOF" {
    try expectIo(
        \\import std.memory.{List}
        \\import std.io.{read_bytes, write_all, stdin, stdout}
        \\func echo() int | none
        \\    var buffer: List(byte) = List(byte).new(0) else return none
        \\    const count: int = read_bytes(stdin, buffer, 100) else return none
        \\    const bytes: BytesView = buffer.bytes() else return none
        \\    const _: unit = write_all(stdout, bytes) else return none
        \\    if (bytes.get(count) is byte) -> return 90
        \\    const eof: int = read_bytes(stdin, buffer, 1) else return none
        \\    const empty: int = read_bytes(stdin, buffer, 0) else return none
        \\    return count + eof + empty + 36
        \\if const result: int = echo() -> exit(result)
        \\exit(91)
    , "a\x00\xffé!", "a\x00\xffé!", "", 42);
}

test "reached compile-time IO is rejected while untaken IO remains pure" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func run() int
        \\    print("hello")
        \\    return 1
        \\    return 2
        \\exit(comptime -> run())
    , .compile_time_unsupported_operation);
    try SourceFixture.expectParity(
        \\func run() int
        \\    if false
        \\        if (print("hello") is unit) -> return 1
        \\    return 42
    , 42);
}

test "byte array views validate full UTF-8 and execute through transient interpreter borrows" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    const bytes: Array(byte, 4) = [240, 159, 152, 128]
        \\    const view = BytesView.from_array(4, bytes)
        \\    const text: StringView = view.validate_utf8() else return none
        \\    const empty: StringView = text.slice(4..4) else return none
        \\    return text.byte_length() + empty.byte_length() + 38
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
    const invalid = [_][]const u8{ "[128]", "[192, 128]", "[224, 128, 128]", "[237, 160, 128]", "[240, 128, 128, 128]", "[244, 144, 128, 128]", "[245, 128, 128, 128]", "[226, 130]" };
    const counts = [_][]const u8{ "1", "2", "3", "3", "4", "4", "4", "2" };
    for (invalid, counts) |bytes, count| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\func run() int
            \\    const bytes: Array(byte, $count) = $bytes
            \\    const view = BytesView.from_array($count, bytes)
            \\    if const _: StringView = view.validate_utf8() -> return 90
            \\    return 42
        , .{ .bytes = bytes, .count = count });
        defer std.testing.allocator.free(source);
        try SourceFixture.expectParity(source, 42);
    }
}

test "views reject escape from local owners and use after owner growth" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func bad() BytesView
        \\    const bytes: Array(byte, 1) = [42]
        \\    return BytesView.from_array(1, bytes)
        \\const view = bad()
    , .borrow_outlives_source);
    try SourceFixture.expectSourceDiagnostic(
        \\func run() int | none
        \\    var text = "hello"
        \\    const view = text.view()
        \\    const _: unit = text.append("!") else return none
        \\    return view.byte_length()
        \\if const answer: int = run() -> exit(answer)
    , .borrow_outlives_source);
    try SourceFixture.expectSourceDiagnostic(
        \\import std.memory
        \\pub struct Payload
        \\    pub number: int
        \\var value: Payload | none = Payload{number = 1}
        \\if ref payload: Payload = value
        \\    value = none
        \\    exit(payload.number)
    , .borrow_outlives_source);
}

test "byte views borrow readonly elements and copy owned bytes in both engines" {
    try SourceFixture.expectParity(
        \\func first(imm bytes: BytesView) ref byte | none -> bytes.get(0)
        \\func inspect() int | none
        \\    var bytes: Array(byte, 2) = [20, 22]
        \\    var view = BytesView.from_array(2, bytes)
        \\    ref element: byte = first(view) else return none
        \\    const copied = view[1]
        \\    ref temporary: byte = BytesView.from_array(2, bytes).get(1) else return none
        \\    return byte_int(element) + byte_int(copied) + byte_int(temporary) - 22
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 90
    , 42);
    try SourceFixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\    var bytes: Array(byte, 1) = [42]
        \\    var view = BytesView.from_array(1, bytes)
        \\    var handle = Ref.from(view[0])
        \\    handle.value = 0
        \\    return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
    try SourceFixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\    var bytes: Array(byte, 1) = [42]
        \\    var view = BytesView.from_array(1, bytes)
        \\    ref element = view[0]
        \\    bytes[0] = 0
        \\    exit(byte_int(element))
        \\    return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .borrow_outlives_source);
}

test "generic spans borrow arrays and preserve empty slicing in both engines" {
    try SourceFixture.expectParity(
        \\import std.memory.{Span, Ref}
        \\func inspect() int | none
        \\    const numbers: Array(int, 3) = [17, 23, 2]
        \\    const view = Span(int).from_array(3, numbers)
        \\    const tail: Span(int) = view.slice(1..3) else return none
        \\    const empty: Span(int) = tail.slice(2..2) else return none
        \\    if (empty.get(0) is int) -> return none
        \\    ref first: int = view.get(0) else return none
        \\    ref second: int = tail.get(0) else return none
        \\    ref third: int = tail.get(1) else return none
        \\    return first + second + third + empty.len() + Span(int).empty().len()
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "range slicing preserves reusable empty reversed and inclusive bounds" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    var values = [7, 17, 23, 11]
        \\    var view = values.span()
        \\    const bounds = 1..3
        \\    const selected: Span(int) = view.slice(bounds) else return none
        \\    const inclusive: Span(int) = view.slice(1..=2) else return none
        \\    const empty: Span(int) = view.slice(2..2) else return none
        \\    const endpoint: Span(int) = view.slice(4..4) else return none
        \\    if (view.slice(2..1) is Span(int)) -> return 91
        \\    if (view.slice(4..=4) is Span(int)) -> return 92
        \\    if inclusive.len() <> 2 -> return 93
        \\    if (view.slice(2..=1) is Span(int)) -> return 94
        \\    var count = 0
        \\    for index in bounds -> count += 1
        \\    return selected[0] + selected[1] + count + empty.len() + endpoint.len()
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 90
    , 42);
}

test "end relative collection indexing and slicing preserve native and comptime behavior" {
    try SourceFixture.expectParity(
        \\func distance(ref calls: int) int
        \\    calls += 1
        \\    return 1
        \\func inspect() int | none
        \\    var values = [10, 20, 30, 40]
        \\    var calls = 0
        \\    values[^distance(calls)] += 2
        \\    if not (calls == 1) -> return none
        \\    if not (values[^1] == 42) -> return none
        \\    if not ((if const _selected_result_0: int = values.get(^4) -> _selected_result_0 else return none) == 10) -> return none
        \\    var span = values.span()
        \\    span[^2] = 31
        \\    if not ((if const _selected_result_1: int = span.get(^2) -> _selected_result_1 else return none) == 31) -> return none
        \\    const prefix = ..^1
        \\    const suffix = ^2..
        \\    const selected = values[suffix]
        \\    if not (selected.len() == 2 and selected[^1] == 42) -> return none
        \\    if not (values[prefix].len() == 3) -> return none
        \\    if not (values[1..=^1].len() == 3) -> return none
        \\    var list: List(int) = [17, 20]
        \\    const _: unit = list.reserve(8) else return none
        \\    list[^1] += 3
        \\    if not ((if const _selected_result_2: int = list.get(^1) -> _selected_result_2 else return none) == 23) -> return none
        \\    if not (list[prefix].len() == 1) -> return none
        \\    if not (list[suffix].len() == 2) -> return none
        \\    const bytes: BytesView = "abcd"
        \\    if not (byte_int(bytes[^1]) == 100) -> return none
        \\    if not (byte_int((if const _selected_result_3: byte = bytes.get(^4) -> _selected_result_3 else return none)) == 97) -> return none
        \\    if not (bytes[prefix].byte_length() == 3) -> return none
        \\    const text: StringView = "aéz"
        \\    if text[..^1] <> "aé" -> return none
        \\    if text[^3..^1] <> "é" -> return none
        \\    if text[..=^1] <> text -> return none
        \\    if const _: StringView = text.slice(^2..) -> return 90
        \\    if const _: StringView = text.slice(..^2) -> return 91
        \\    return 42
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 92
    , 42);
}

test "end relative collection bounds reject invalid distances and accept end boundaries" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    var values = [10, 20, 30]
        \\    var list: List(int) = [10, 20, 30]
        \\    const _: unit = list.reserve(8) else return none
        \\    var span = values.span()
        \\    const bytes: BytesView = "abc"
        \\    for distance in [-2147483648, -1, 0, 4, 2147483647]
        \\        if const _: int = values.get(^distance) -> return 90
        \\        if const _: int = list.get(^distance) -> return 91
        \\        if const _: int = span.get(^distance) -> return 92
        \\        if const _: byte = bytes.get(^distance) -> return 93
        \\    if ref target: int = list.get(^4)
        \\        target = 0
        \\        return 94
        \\    if not (list[^1] == 30) -> return none
        \\    const whole = values[..^0]
        \\    const empty = values[^0..]
        \\    if not (whole.len() == 3 and empty.len() == 0) -> return none
        \\    if const _: Span(int) = values.slice(..=^0) -> return 95
        \\    if const _: Span(int) = values.slice(^4..) -> return 96
        \\    if const _: Span(int) = values.slice(..^4) -> return 97
        \\    var absent: Array(int, 0) = []
        \\    if not (absent[^0..^0].len() == 0) -> return none
        \\    if const _: int = absent.get(^0) -> return 98
        \\    if const _: int = absent.get(^1) -> return 99
        \\    if const _: Span(int) = absent.slice(..=^0) -> return 100
        \\    return 42
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 101
    , 42);
}

test "end relative slicing matches independent absolute endpoint combinations" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    const values = [2, 4, 6, 8, 10]
        \\    var accepted = 0
        \\    var included = 0
        \\    for absolute_first in [true, false]
        \\        for absolute_limit in [true, false]
        \\            for first in -1..=6
        \\                for limit in -1..=6
        \\                    const start_bound = if absolute_first -> first else ^first
        \\                    const limit_bound = if absolute_limit -> limit else ^limit
        \\                    const start = if absolute_first -> first else 5 - first
        \\                    const end = if absolute_limit -> limit else 5 - limit
        \\                    if const selected: Span(int) = values.slice(start_bound..limit_bound)
        \\                        if not (start >= 0 and start <= end and end <= 5) -> return none
        \\                        if not (selected.len() == end - start) -> return none
        \\                        var offset = 0
        \\                        for value in selected
        \\                            if not (value == (start + offset + 1) * 2) -> return none
        \\                            offset += 1
        \\                        accepted += 1
        \\                    else
        \\                        if start >= 0 and start <= end and end <= 5 -> return none
        \\                    if const selected: Span(int) = values.slice(start_bound..=limit_bound)
        \\                        if not (start >= 0 and start <= end and end < 5) -> return none
        \\                        if not (selected.len() == end - start + 1) -> return none
        \\                        included += 1
        \\                    else
        \\                        if start >= 0 and start <= end and end < 5 -> return none
        \\    if not (accepted == 84 and included == 60) -> return none
        \\    return 42
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 90
    , 42);
}

test "end relative access preserves borrow permissions and invalidation" {
    const source =
        \\func last(ref values: Array(int, 3)) ref int | none -> values[^1]
        \\func inspect() int | none
        \\    var values = [7, 11, 40]
        \\    ref item: int = last(values) else return none
        \\    item += 2
        \\    return values[^1]
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 90
    ;
    try SourceFixture.expectParity(source, 42);
    const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var values", "const values");
    defer std.testing.allocator.free(readonly);
    const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{readonly});
    defer std.testing.allocator.free(rejected);
    try SourceFixture.expectSourceDiagnostic(rejected, .reference_not_writable);
    try SourceFixture.expectSourceDiagnostic(
        \\func inspect() int | none
        \\    var values: List(int) = [40]
        \\    ref item = values[^1]
        \\    const _: unit = values.append(2) else return none
        \\    return item
        \\if const result: int = inspect() -> exit(result)
    , .borrow_outlives_source);
}

test "range slicing resolves independently omitted bounds against initialized extents" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    var values = [7, 17, 23, 11]
        \\    const all = ..
        \\    const prefix = ..3
        \\    const suffix = 2..
        \\    const whole: Span(int) = values.slice(all) else return none
        \\    const head: Span(int) = values.slice(prefix) else return none
        \\    const tail: Span(int) = values.slice(suffix) else return none
        \\    const inclusive: Span(int) = values.slice(..=2) else return none
        \\    const explicit_head: Span(int) = values.slice(none..3) else return none
        \\    const explicit_tail: Span(int) = values.slice(2..none) else return none
        \\    if whole.len() <> 4 or head.len() <> 3 or tail.len() <> 2 -> return 91
        \\    if inclusive.len() <> 3 or explicit_head.len() <> 3 or explicit_tail.len() <> 2 -> return 92
        \\    if (values.slice(5..) is Span(int)) -> return 93
        \\    if (values.slice(..5) is Span(int)) -> return 94
        \\    var empty: Array(int, 0) = []
        \\    const absent: Span(int) = empty.slice(all) else return none
        \\    if (absent.get(0) is int) -> return 95
        \\    var list: List(int) = [17, 23]
        \\    const _: unit = list.reserve(8) else return none
        \\    if (list.slice(..3) is Span(int)) -> return 96
        \\    var selected: Span(int) = list.slice(all) else return none
        \\    selected[0] += 2
        \\    return selected[0] + selected[1] + absent.len()
        \\func run() int
        \\    if const result: int = inspect() -> return result
        \\    return 90
    , 42);
}

test "range slicing preserves collection permissions and rejects sequence operands" {
    const declarations = [_][]const u8{ "var values = [40]", "var values: List(int) = [40]" };
    for (declarations) |declaration| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\func inspect() int
            \\    $declaration
            \\    var selected: Span(int) = values.slice(..) else return 90
            \\    selected[0] += 2
            \\    return values[0]
            \\func run() int
            \\    if const result = inspect() -> return result
            \\    return 90
        , .{ .declaration = declaration });
        defer std.testing.allocator.free(source);
        try SourceFixture.expectParity(source, 42);
        const readonly = try std.mem.replaceOwned(u8, std.testing.allocator, source, "var values", "const values");
        defer std.testing.allocator.free(readonly);
        const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{readonly});
        defer std.testing.allocator.free(rejected);
        try SourceFixture.expectSourceDiagnostic(rejected, .reference_not_writable);
    }
    const sequences = [_][]const u8{ "(0..1).reversed()", "(if const selected: RangeSequence = (0..1).step_by(1) -> selected else panic \"unexpected none\")" };
    for (sequences) |sequence| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\import std.range.{RangeSequence}
            \\func inspect() int
            \\    var values = [42]
            \\    const selected = values.slice($sequence)
            \\    return selected[0]
            \\if const result = inspect() -> exit(result)
        , .{ .sequence = sequence });
        defer std.testing.allocator.free(source);
        try SourceFixture.expectSourceDiagnostic(source, .call_argument_type_mismatch);
    }
}

test "span slicing matches an independent endpoint boundary matrix" {
    try SourceFixture.expectParity(
        \\func run() int
        \\    const values = [2, 4, 6, 8, 10]
        \\    const source = values.span()
        \\    var accepted = 0
        \\    var accepted_inclusive = 0
        \\    for start in 0..=6
        \\        for limit in 0..=6
        \\            if const selected: Span(int) = source.slice(start..limit)
        \\                if start > limit or limit > 5 -> return 90
        \\                if selected.len() <> limit - start -> return 91
        \\                var actual = 0
        \\                for value in selected -> actual += value
        \\                var expected = 0
        \\                for position in start..limit -> expected += (position + 1) * 2
        \\                if actual <> expected -> return 92
        \\                accepted += 1
        \\            else
        \\                if start <= limit and limit <= 5 -> return 93
        \\            if const included: Span(int) = source.slice(start..=limit)
        \\                if start > limit or limit >= 5 -> return 95
        \\                if included.len() <> limit - start + 1 -> return 96
        \\                var actual = 0
        \\                for value in included -> actual += value
        \\                var expected = 0
        \\                for position in start..=limit -> expected += (position + 1) * 2
        \\                if actual <> expected -> return 97
        \\                accepted_inclusive += 1
        \\            else
        \\                if start <= limit and limit < 5 -> return 98
        \\    if accepted <> 21 -> return 94
        \\    if accepted_inclusive <> 15 -> return 99
        \\    return 42
    , 42);
}

test "span slicing rejects extreme bounds before offset arithmetic" {
    try SourceFixture.expectParity(
        \\func run() int
        \\    const values = [17, 23, 2]
        \\    const source = values.span()
        \\    if (source.slice(-2147483648..0) is Span(int)) -> return 90
        \\    if (source.slice(-1..0) is Span(int)) -> return 91
        \\    if (source.slice(0..-2147483648) is Span(int)) -> return 92
        \\    if (source.slice(0..-1) is Span(int)) -> return 93
        \\    if (source.slice(2147483647..0) is Span(int)) -> return 94
        \\    if (source.slice(0..2147483647) is Span(int)) -> return 95
        \\    if (source.slice(1..=2147483647) is Span(int)) -> return 96
        \\    if (source.slice(2147483647..=2147483647) is Span(int)) -> return 97
        \\    if (source.slice(-2147483648..2147483647) is Span(int)) -> return 98
        \\    if const endpoint: Span(int) = source.slice(3..3)
        \\        if (endpoint.get(0) is int) -> return 99
        \\        return 42 + endpoint.len()
        \\    return 100
    , 42);
}

test "span slicing validates empty zero sized extents without exposing an element" {
    try SourceFixture.expectParity(
        \\struct Empty
        \\    copy = trivial
        \\func run() int
        \\    var absent: Array(Empty, 0) = []
        \\    var empty = absent.span()
        \\    if (empty.slice(0..1) is Span(Empty)) -> return 90
        \\    if (empty.slice(1..1) is Span(Empty)) -> return 91
        \\    if const selected: Span(Empty) = empty.slice(0..0)
        \\        if (selected.get(0) is Empty) -> return 92
        \\        if (selected.get(-1) is Empty) -> return 93
        \\    else
        \\        return 94
        \\    var values: Array(Empty, 3) = [Empty{}, Empty{}, Empty{}]
        \\    var source = values.span()
        \\    if const tail: Span(Empty) = source.slice(^0..)
        \\        if tail.len() <> 0 -> return 99
        \\    else
        \\        return 100
        \\    if const complete: Span(Empty) = source.slice(^3..^0)
        \\        if complete.len() <> 3 -> return 101
        \\    else
        \\        return 102
        \\    if (source.get(^0) is Empty) -> return 97
        \\    if not (source.get(^1) is Empty) -> return 98
        \\    if const endpoint: Span(Empty) = source.slice(3..3)
        \\        if (endpoint.get(0) is Empty) -> return 95
        \\        return 42 + endpoint.len()
        \\    return 96
    , 42);
}

test "span slicing returns nested views with backing authority rather than carrier lifetime" {
    const source =
        \\func tail(ref values: Array(int, 4)) Span(int) | none
        \\    var all = values.span()
        \\    var selected: Span(int) = all.slice(1..4) else return none
        \\    return selected.slice(1..2)
        \\func inspect() int | none
        \\    var values = [7, 11, 40, 13]
        \\    var view: Span(int) = tail(values) else return none
        \\    view[0] += 2
        \\    return values[2]
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    ;
    try SourceFixture.expectParity(source, 42);
    const readonly_cases = [_]struct { original: []const u8, replacement: []const u8 }{
        .{ .original = "var values = [7, 11, 40, 13]", .replacement = "const values = [7, 11, 40, 13]" },
        .{ .original = "var selected: Span(int)", .replacement = "const selected: Span(int)" },
        .{ .original = "var view: Span(int) = tail(values) else return none", .replacement = "var view: Span(int) = (if const found: Span(int) = tail(values) -> found.as_imm() else return none)" },
    };
    for (readonly_cases) |case| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, case.original, case.replacement);
        defer std.testing.allocator.free(changed);
        const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{changed});
        defer std.testing.allocator.free(rejected);
        try SourceFixture.expectSourceDiagnostic(rejected, .reference_not_writable);
    }
    try SourceFixture.expectSourceDiagnostic(
        \\func escape() Span(int) | none
        \\    var values = [7, 11, 40, 13]
        \\    var all = values.span()
        \\    var selected: Span(int) = all.slice(1..4) else return none
        \\    return selected.slice(1..2)
        \\func inspect() int | none
        \\    const view: Span(int) = escape() else return none
        \\    return view[0]
        \\if const answer: int = inspect() -> exit(answer)
    , .borrow_outlives_source);
}

test "span slicing separates owned field access from captured reference authority" {
    const source =
        \\struct Views
        \\    pub owned: Span(int)
        \\    pub ref captured: Span(int)
        \\    pub func owned_tail(ref self: Views) Span(int) | none -> self.owned.slice(0..1)
        \\    pub func captured_tail(ref self: Views) Span(int) | none -> self.captured.slice(0..1)
        \\func inspect() int | none
        \\    var first = [7]
        \\    var second = [40]
        \\    var owned = first.span()
        \\    var captured = second.span()
        \\    const carrier = Views{owned = owned, captured = captured}
        \\    var selected: Span(int) = carrier.captured_tail() else return none
        \\    selected[0] += 2
        \\    return second[0]
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    ;
    try SourceFixture.expectParity(source, 42);
    const readonly_cases = [_]struct { original: []const u8, replacement: []const u8 }{
        .{ .original = "carrier.captured_tail()", .replacement = "carrier.owned_tail()" },
        .{ .original = "var captured = second.span()", .replacement = "var captured = second.span().as_imm()" },
    };
    for (readonly_cases) |case| {
        const changed = try std.mem.replaceOwned(u8, std.testing.allocator, source, case.original, case.replacement);
        defer std.testing.allocator.free(changed);
        const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\nexit(run())", .{changed});
        defer std.testing.allocator.free(rejected);
        try SourceFixture.expectSourceDiagnostic(rejected, .reference_not_writable);
    }
}

test "generic spans retain writable access and attenuate in both engines" {
    try SourceFixture.expectParity(
        \\import std.memory.{Span, Ref}
        \\func inspect() int | none
        \\    var numbers: Array(int, 2) = [17, 23]
        \\    var writable = Span(int).from_array(2, numbers)
        \\    writable[0] = 18
        \\    ref element: int = writable.get(0) else return none
        \\    element = 19
        \\    const readonly = writable.as_imm()
        \\    return readonly[0] + readonly[1]
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "attenuated empty spans publish readonly cursors in both engines" {
    try SourceFixture.expectParity(
        \\static empty = Span(int).empty().as_imm()
        \\func run() int
        \\    const source = empty
        \\    if const endpoint: Span(int) = source.slice(0..0) -> return endpoint.len() + 42
        \\    return 90
    , 42);
}

test "aggregate call results cannot assume correspondence with input fields" {
    const cases = [_]struct { result_type: []const u8, construct: []const u8, select: []const u8 }{
        .{ .result_type = "Pair", .construct = "Pair{first = value.second, second = value.first}", .select = "reordered" },
        .{ .result_type = "Array(Pair, 1)", .construct = "[Pair{first = value.second, second = value.first}]", .select = "reordered[0]" },
        .{ .result_type = "Box(Pair)", .construct = "(if const _selected_result_0: Box(Pair) = Box(Pair).new(Pair{first = value.second, second = value.first}) -> _selected_result_0^ else panic \"unexpected none\")", .select = "Ref.from(reordered.borrow()).value" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            errdefer std.debug.print("aggregate result: {s}, entry: {s}\n", .{ case.result_type, entry });
            const source = try test_sources.renderTemplate(std.testing.allocator,
                \\pub struct Pair
                \\    copy = trivial
                \\    pub first: Ref(byte)
                \\    pub second: Ref(byte)
                \\func swap(var value: Pair) $result_type -> $construct
                \\func inspect() int
                \\    var first_bytes: Array(byte, 1) = [65]
                \\    var second_bytes: Array(byte, 1) = [66]
                \\    ref first: byte = first_bytes.get(0) else panic "missing first byte"
                \\    ref second: byte = second_bytes.get(0) else panic "missing second byte"
                \\    var reordered = swap(Pair{first = Ref.from(first), second = Ref.from(second)})
                \\    var selected = $select
                \\    const text: StringView = BytesView.from_array(1, second_bytes).validate_utf8() else panic "invalid text"
                \\    selected.first.value = 255
                \\    return byte_int(text.as_bytes()[0])
                \\func run() int
                \\    if const answer = inspect() -> return answer
                \\    return 90
                \\$entry
            , .{ .result_type = case.result_type, .construct = case.construct, .select = case.select, .entry = entry });
            defer std.testing.allocator.free(source);
            try SourceFixture.expectSourceDiagnostic(source, .borrow_outlives_source);
        }
    }
}

test "returned readonly ranges depend on contents throughout aggregate shapes" {
    const cases = [_]struct { result_type: []const u8, construct: []const u8, select: []const u8 }{
        .{ .result_type = "StringView", .construct = "text", .select = "returned" },
        .{ .result_type = "Wrapped", .construct = "Wrapped{view = text}", .select = "returned.view" },
        .{ .result_type = "Array(StringView, 1)", .construct = "[text]", .select = "returned[0]" },
        .{ .result_type = "Box(StringView)", .construct = "(if const _selected_result_0: Box(StringView) = Box(StringView).new(text) -> _selected_result_0^ else panic \"unexpected none\")", .select = "Ref.from(returned.borrow()).value" },
        .{ .result_type = "List(StringView)", .construct = "[text]", .select = "returned[0]" },
        .{ .result_type = "StringView | none", .construct = "text", .select = "if const view: StringView = returned -> view else panic \"missing text\"" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            const source = try test_sources.renderTemplate(std.testing.allocator,
                \\struct Wrapped
                \\    pub view: StringView
                \\func validate(imm view: Span(byte)) $result_type
                \\    const text: StringView = BytesView.from_span(view.as_imm()).validate_utf8() else panic "invalid text"
                \\    return $construct
                \\func inspect() int
                \\    var bytes: Array(byte, 1) = [65]
                \\    var writable = bytes.span()
                \\    const returned = validate(writable)
                \\    const text = $select
                \\    writable[0] = 255
                \\    return byte_int(text.as_bytes()[0])
                \\func run() int
                \\    if const answer = inspect() -> return answer
                \\    return 90
                \\$entry
            , .{ .result_type = case.result_type, .construct = case.construct, .select = case.select, .entry = entry });
            defer std.testing.allocator.free(source);
            try SourceFixture.expectSourceDiagnostic(source, .borrow_outlives_source);
        }
    }
}

test "returned aggregates preserve writable handle storage dependencies" {
    try SourceFixture.expectParity(
        \\struct Views
        \\    pub writable: Span(byte)
        \\    pub readonly: StringView
        \\func views(ref source: Span(byte)) Views | none
        \\    return Views{writable = source, readonly = (if const _selected_result_0: StringView = BytesView.from_span(source.as_imm()).validate_utf8() -> _selected_result_0 else return none)}
        \\func inspect() int | none
        \\    var bytes: Array(byte, 1) = [65]
        \\    var input = bytes.span()
        \\    var wrapped: Views = views(input) else return none
        \\    var writable = wrapped.writable
        \\    writable[0] = 41
        \\    writable[0] = 42
        \\    return byte_int(writable[0])
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "ownership hook results preserve readonly content dependencies" {
    const cases = [_]struct { operation: []const u8, mode: []const u8, transfer: []const u8 }{
        .{ .operation = "copy", .mode = "imm", .transfer = "" },
        .{ .operation = "move", .mode = "deinit", .transfer = "^" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            const source = try test_sources.renderTemplate(std.testing.allocator,
                \\struct Views
                \\    pub writable: Span(byte)
                \\    pub readonly: StringView
                \\    $operation = func($mode self: Views) Views
                \\        if const text: StringView = BytesView.from_span(self.writable.as_imm()).validate_utf8()
                \\            return Views{writable = self.writable, readonly = text}
                \\        exit(90)
                \\func inspect() int
                \\    var first: Array(byte, 1) = [65]
                \\    var second: Array(byte, 1) = [66]
                \\    var writable = second.span()
                \\    const text: StringView = BytesView.from_array(1, first).validate_utf8() else panic "invalid text"
                \\    const original = Views{writable = writable, readonly = text}
                \\    const changed = original$transfer
                \\    writable[0] = 255
                \\    return byte_int(changed.readonly.as_bytes()[0])
                \\func run() int
                \\    if const answer = inspect() -> return answer
                \\    return 90
                \\$entry
            , .{ .operation = case.operation, .mode = case.mode, .transfer = case.transfer, .entry = entry });
            defer std.testing.allocator.free(source);
            try SourceFixture.expectSourceDiagnostic(source, .borrow_outlives_source);
        }
    }
}

test "mutable outputs preserve readonly dependencies through owned and referenced storage" {
    const cases = [_]struct { setup: []const u8, place: []const u8, select: []const u8 }{
        .{ .setup = "var view = View{text = original}", .place = "view", .select = "view.text" },
        .{ .setup = "var wrapped = Wrapped{view = View{text = original}}", .place = "wrapped.view", .select = "wrapped.view.text" },
        .{ .setup = "var wrapped = Wrapped{view = View{text = original}}\n    var alias = Ref.from(wrapped.view)", .place = "alias.value", .select = "wrapped.view.text" },
        .{ .setup = "var boxed: Box(View) = Box(View).new(View{text = original}) else panic \"unexpected allocation refusal\"\n    var alias = Ref.from(boxed.borrow())", .place = "alias.value", .select = "boxed.borrow().text" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\import std.memory
            \\pub struct View
            \\    pub text: StringView
            \\struct Wrapped
            \\    pub view: View
            \\func refresh(mut value: View, imm source: Span(byte))
            \\    const text: StringView = BytesView.from_span(source.as_imm()).validate_utf8() else panic "invalid text"
            \\    value.text = text
            \\func inspect() int
            \\    var first: Array(byte, 1) = [65]
            \\    var second: Array(byte, 1) = [66]
            \\    var writable = second.span()
            \\    const original: StringView = BytesView.from_array(1, first).validate_utf8() else panic "invalid text"
            \\    $setup
            \\    refresh($place, writable)
            \\    return byte_int($select.as_bytes()[0]) - 24
            \\func run() int
            \\    if const answer = inspect() -> return answer
            \\    return 90
        , .{ .setup = case.setup, .place = case.place, .select = case.select });
        defer std.testing.allocator.free(source);
        try SourceFixture.expectParity(source, 42);
        const conflicting_write = try std.mem.replaceOwned(u8, std.testing.allocator, source, "    return byte_int(", "    writable[0] = 255\n    return byte_int(");
        defer std.testing.allocator.free(conflicting_write);
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ conflicting_write, entry });
            defer std.testing.allocator.free(rejected);
            try SourceFixture.expectSourceDiagnostic(rejected, .borrow_outlives_source);
        }
    }
}

test "mutable outputs preserve writable handle storage dependencies" {
    try SourceFixture.expectParity(
        \\struct Views
        \\    pub writable: Span(byte)
        \\    pub readonly: StringView
        \\func refresh(mut value: Views, ref source: Span(byte)) unit | none
        \\    value = Views{writable = source, readonly = (if const _selected_result_0: StringView = BytesView.from_span(source.as_imm()).validate_utf8() -> _selected_result_0 else return none)}
        \\    return ()
        \\func inspect() int | none
        \\    var first: Array(byte, 1) = [65]
        \\    var second: Array(byte, 1) = [66]
        \\    var writable = second.span()
        \\    var views = Views{writable = writable, readonly = (if const _selected_result_1: StringView = BytesView.from_array(1, first).validate_utf8() -> _selected_result_1 else return none)}
        \\    const _: unit = refresh(views, writable) else return none
        \\    var changed = views.writable
        \\    changed[0] = 41
        \\    changed[0] = 42
        \\    return byte_int(changed[0])
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "mutable field outputs preserve untouched readonly siblings" {
    for ([_][]const u8{ "", "    var alias = Ref.from(views.changed)\n" }) |alias| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\import std.memory
            \\pub struct View
            \\    pub text: StringView
            \\struct Views
            \\    pub changed: View
            \\    pub untouched: StringView
            \\func refresh(mut value: View, imm source: Span(byte))
            \\    const text: StringView = BytesView.from_span(source.as_imm()).validate_utf8() else panic "invalid text"
            \\    value.text = text
            \\func inspect() int
            \\    var first: Array(byte, 1) = [65]
            \\    var second: Array(byte, 1) = [66]
            \\    var writable = second.span()
            \\    const original: StringView = BytesView.from_array(1, first).validate_utf8() else panic "invalid text"
            \\    var views = Views{changed = View{text = original}, untouched = original}
            \\$alias    refresh($place, writable)
            \\    const untouched = views.untouched
            \\    writable[0] = 255
            \\    return byte_int(untouched.as_bytes()[0]) - 23
            \\func run() int
            \\    if const answer = inspect() -> return answer
            \\    return 90
        , .{ .alias = alias, .place = if (alias.len == 0) "views.changed" else "alias.value" });
        defer std.testing.allocator.free(source);
        try SourceFixture.expectParity(source, 42);
    }
}

test "generic spans borrow noncopyable elements without copying" {
    try SourceFixture.expectParity(
        \\struct Entry
        \\    copy = none
        \\    pub score: int
        \\func inspect() int | none
        \\    const entries: Array(Entry, 2) = [Entry{score = 17}, Entry{score = 40}]
        \\    const view = entries.span()
        \\    ref element: Entry = view.get(1) else return none
        \\    return element.score + view.len()
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans preserve zero-sized writable ranges" {
    try SourceFixture.expectParity(
        \\struct Empty
        \\    copy = trivial
        \\func inspect() int | none
        \\    var entries: Array(Empty, 3) = [Empty{}, Empty{}, Empty{}]
        \\    var source = entries.span()
        \\    var view: Span(Empty) = source.slice(1..3) else return none
        \\    ref element: Empty = view.get(1) else return none
        \\    element = Empty{}
        \\    if (view.get(2) is Empty) -> return none
        \\    return view.len() + 40
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans cannot escalate readonly access" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func inspect() int | none
        \\    const entries = [42]
        \\    const view = entries.span()
        \\    ref element: int = view.get(0) else return none
        \\    element = 17
        \\    return element
        \\if const answer: int = inspect() -> exit(answer)
    , .reference_not_writable);
}

test "generic spans reject stale validated text through aggregate calls and loops" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func replace(ref view: Span(byte)) unit | none
        \\    ref element: byte = view.get(0) else return none
        \\    element = 255
        \\    return ()
        \\func inspect() int | none
        \\    var entries: Array(byte, 1) = [65]
        \\    var writable = entries.span()
        \\    const text: StringView = BytesView.from_span(writable.as_imm()).validate_utf8() else return none
        \\    var index = 0
        \\    loop
        \\        if index == 2 -> break
        \\        const _: unit = replace(writable) else return none
        \\        index += 1
        \\    return text.byte_length()
        \\if const answer: int = inspect() -> exit(answer)
    , .borrow_outlives_source);
    try SourceFixture.expectAnySourceDiagnostic(
        \\import std.memory
        \\func inspect() int | none
        \\    var entries: Array(byte, 1) = [65]
        \\    var writable = entries.span()
        \\    const text: StringView = BytesView.from_span(writable.as_imm()).validate_utf8() else return none
        \\    const alias = Ref.from(text)
        \\    writable[0] = 255
        \\    return alias.value.byte_length()
        \\if const answer: int = inspect() -> exit(answer)
    , .borrow_outlives_source);
}

test "List growth and generic views have parity" {
    try SourceFixture.expectParity(
        \\func inspect() int | none
        \\    var values: List(int) = List(int).new(0) else return none
        \\    const _: unit = values.append(17) else return none
        \\    const _: unit = values.append(23) else return none
        \\    const _: unit = values.reserve(8) else return none
        \\    const view: Span(int) = values.slice(0..2) else return none
        \\    return view[0] + view[1] + view.len()
        \\func run() int
        \\    if const answer: int = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans cannot escape local storage or survive owner transfer" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func escape() Span(int)
        \\    const entries = [42]
        \\    return entries.span()
        \\const view = escape()
        \\if ref element: int = view.get(0) -> exit(element)
    , .borrow_outlives_source);
    try SourceFixture.expectAnySourceDiagnostic(
        \\func consume(deinit values: List(int)) int -> values.len()
        \\func inspect() int | none
        \\    var entries: List(int) = List(int).new(1) else return none
        \\    const _: unit = entries.append(42) else return none
        \\    const view = entries.span()
        \\    consume(entries)
        \\    return view[0]
        \\if const answer: int = inspect() -> exit(answer)
    , .use_after_transfer);
}

test "validated text views reject content changes through byte references" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func inspect() int | none
        \\    var bytes: Array(byte, 1) = [65]
        \\    ref writable: byte = bytes.get(0) else return none
        \\    const view: StringView = BytesView.from_array(1, bytes).validate_utf8() else return none
        \\    writable = 255
        \\    return view.byte_length()
        \\if const answer: int = inspect() -> exit(answer)
    , .borrow_outlives_source);
}

test "variant payload references follow their owner through loop joins" {
    try SourceFixture.expectParity(
        \\import std.memory
        \\pub struct Payload
        \\    pub number: int
        \\struct Owner
        \\    pub payload: Payload | none
        \\func run() int
        \\    var owner = Owner{payload = Payload{number = 19}}
        \\    if ref value: Payload = owner.payload
        \\        var index = 0
        \\        loop
        \\            if index == 3 -> break
        \\            value.number += 1
        \\            index += 1
        \\        value.number += 20
        \\    if ref value: Payload = owner.payload -> return value.number
        \\    return 90
    , 42);
}

test "literal backing stays static with no prelude or a shadowed String name" {
    try SourceFixture.expectSourceExit(
        \\import std.prelude.{}
        \\import std.exit.{exit}
        \\struct String
        \\    pub value: int
        \\static text = "hello"
        \\exit(text.byte_length())
    , 5);
    try SourceFixture.expectParity(
        \\func text() StringView -> "forty-two"
        \\func run() int -> text().byte_length() + 33
    , 42);
}

test "owned strings convert to borrowed text for ordinary print callables" {
    try expectIo(
        \\func output() unit | none
        \\    var text = "hello"
        \\    const _: unit = text.append("!") else return none
        \\    const writer: func(imm String) unit = print
        \\    writer(text)
        \\    return ()
        \\if (output() is unit) -> exit(42)
        \\exit(90)
    , "", "hello!\n", "", 42);
}

test "from_utf8 validates before allocation and owns a copy independent of its input" {
    try expectIo(
        \\func output() unit | none
        \\    var array: Array(byte, 2) = [195, 169]
        \\    const bytes = BytesView.from_array(2, array)
        \\    var text: String = String.from_utf8(bytes) else return none
        \\    array[0] = 65
        \\    const _: unit = text.append("!") else return none
        \\    const invalid: Array(byte, 1) = [128]
        \\    if (String.from_utf8(BytesView.from_array(1, invalid)) is String) -> return none
        \\    print(text)
        \\    return ()
        \\if (output() is unit) -> exit(42)
        \\exit(90)
    , "", "é!\n", "", 42);
}

fn runWithStreams(source: []const u8, stdin: std.process.SpawnOptions.StdIo, stdout: std.process.SpawnOptions.StdIo, limit: bool) !std.process.Child.Term {
    const fixture = try SourceFixture.init(source);
    defer fixture.deinit();
    const bytes = try fixture.executable(0);
    var program = try test_sources.runtime.prepareProgram(std.testing.io, std.testing.allocator, bytes.bytes);
    defer program.deinit(std.testing.io);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, "prog") catch {};
    const argv: []const []const u8 = if (limit) &.{ "prlimit", "--as=1048576", "--", program.path } else &.{program.path};
    var child = std.process.spawn(std.testing.io, .{ .argv = argv, .stdin = stdin, .stdout = stdout, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => if (limit) return error.SkipZigTest else return err,
        else => return err,
    };
    defer child.kill(std.testing.io);
    return child.wait(std.testing.io);
}

fn nonblockingPipe() ![2]std.Io.File {
    var descriptors: [2]std.os.linux.fd_t = undefined;
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.pipe2(&descriptors, .{ .NONBLOCK = true, .CLOEXEC = true })));
    return .{
        .{ .handle = descriptors[0], .flags = .{ .nonblocking = true } },
        .{ .handle = descriptors[1], .flags = .{ .nonblocking = true } },
    };
}

test "short writes report progress" {
    const pipe = try nonblockingPipe();
    defer std.Io.File.closeMany(std.testing.io, &pipe);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(pipe[1].handle, std.os.linux.F.SETPIPE_SZ, 4096)));
    const term = try runWithStreams(
        \\import std.io.{write_once, write_all, stdout}
        \\func run() int
        \\    const array: Array(byte, 16384) = Array(byte, 16384).filled(42) else panic "unexpected none"
        \\    const bytes = BytesView.from_array(16384, array)
        \\    if const count: int = write_once(stdout, bytes)
        \\        if count <= 0 -> return 90
        \\        if count >= 16384 -> return 91
        \\        if (write_all(stdout, bytes) is unit) -> return 92
        \\        return 42
        \\    return 93
        \\exit(run())
    , .ignore, .{ .file = pipe[1] }, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
    var bytes: [4096]u8 = undefined;
    const count = try pipe[0].readStreaming(std.testing.io, &.{&bytes});
    try std.testing.expectEqual(bytes.len, count);
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
}

test "write_all preserves completed writes before an OS failure" {
    const pipe = try nonblockingPipe();
    defer std.Io.File.closeMany(std.testing.io, &pipe);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(pipe[1].handle, std.os.linux.F.SETPIPE_SZ, 4096)));
    const term = try runWithStreams(
        \\import std.io.{write_all, stdout}
        \\const array: Array(byte, 16384) = Array(byte, 16384).filled(42) else panic "unexpected none"
        \\const bytes = BytesView.from_array(16384, array)
        \\if (write_all(stdout, bytes) is unit) -> exit(90)
        \\exit(42)
    , .ignore, .{ .file = pipe[1] }, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
    var bytes: [4096]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try pipe[0].readStreaming(std.testing.io, &.{&bytes}));
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
}

test "broken output pipes propagate write failure instead of SIGPIPE termination" {
    const pipe = try nonblockingPipe();
    pipe[0].close(std.testing.io);
    defer pipe[1].close(std.testing.io);
    const term = try runWithStreams(
        \\import std.io.{write_text, stdout}
        \\if (write_text(stdout, "hello") is unit) -> exit(90)
        \\exit(42)
    , .ignore, .{ .file = pipe[1] }, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test "failed reads preserve the initialized byte prefix" {
    const input = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .write_only });
    defer input.close(std.testing.io);
    const term = try runWithStreams(
        \\import std.memory.{List}
        \\import std.io.{read_bytes, stdin}
        \\func run() int | none
        \\    var buffer: List(byte) = List(byte).new(1) else return none
        \\    const _: unit = buffer.append(41) else return none
        \\    if (read_bytes(stdin, buffer, 16) is int) -> return 90
        \\    if const first = buffer[0] -> return buffer.len() + byte_int(first)
        \\    return 91
        \\if const answer: int = run() -> exit(answer)
        \\exit(92)
    , .{ .file = input }, .ignore, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test "allocation failure preserves strings and repeated clones release their storage" {
    const term = try runWithStreams(
        \\func run() int
        \\    var text = "hello"
        \\    var index = 0
        \\    loop
        \\        if index == 1000 -> break
        \\        if (text.reserve(2147483647) is unit) -> return 90
        \\        if const copy: String = text.clone()
        \\            if copy.byte_length() <> 5 -> return 91
        \\        else
        \\            return 92
        \\        index += 1
        \\    return text.byte_length() + 37
        \\exit(run())
    , .ignore, .ignore, true);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test "string converter temporaries release their allocations" {
    const term = try runWithStreams(
        \\func run() int
        \\    var index = 0
        \\    loop
        \\        if index == 1000 -> break
        \\        const text = String([index, -index])
        \\        if text.byte_length() < 6 -> return 90
        \\        index += 1
        \\    return 42
        \\exit(run())
    , .ignore, .ignore, true);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test "print panics on string conversion allocation failure" {
    const term = try runWithStreams(
        \\const values = Array(unit, 1000000).filled(())
        \\print(values)
        \\exit(90)
        \\exit(91)
    , .ignore, .ignore, true);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, term);
}

test "temporary array backing cannot escape through a borrowed view" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func bad() BytesView -> BytesView.from_array(1, [42])
        \\const view = bad()
    , .borrow_requires_place);
}

test "borrowing a by-value variant payload cannot escape its callee frame" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\import std.memory
        \\import std.memory.{Ref}
        \\pub struct Payload
        \\    copy = trivial
        \\    pub value: int
        \\func bad(imm value: Payload | none) Ref(Payload) | none
        \\    if ref payload: Payload = value -> return Ref.from(payload)
        \\    return none
        \\if const handle: Ref(Payload) = bad(Payload{value = 42}) -> exit(handle.value.value)
    , .borrow_outlives_source);
}

test "permanent text views survive deferred construction and forwarding" {
    try SourceFixture.expectSourceExit(
        \\func run() int | none
        \\    const values: List(StringView) = ["hello", "é"]
        \\    if const first = values[0]
        \\        if const second = values[1]
        \\            return first.byte_length() + second.byte_length() + 35
        \\    return 90
        \\if const answer: int = run() -> exit(answer)
        \\exit(91)
    , 42);
    try SourceFixture.expectParity(
        \\func forward(init value: StringView) StringView -> value
        \\func run() int
        \\    if const value: StringView = forward("hello") -> return value.byte_length() + 37
        \\    return 90
    , 42);
}

test "literal canonical identity ignores escape spelling and unused literals stay lazy" {
    const fixture = try SourceFixture.init(
        \\static a: string_literal = "é"
        \\static b: string_literal = "\xC3\xA9"
        \\static c: string_literal = "\u{e9}"
        \\func unused() String -> "\q"
        \\exit(42)
    );
    defer fixture.deinit();
    const scope = (try fixture.db.get(test_sources.queries.BuildModuleScope, 0)).*.?;
    const first = (try fixture.db.get(test_sources.queries.ResolveStatic, scope.resolveStatic("a").?)).*.?;
    for ([_][]const u8{ "b", "c" }) |name| {
        const value = (try fixture.db.get(test_sources.queries.ResolveStatic, scope.resolveStatic(name).?)).*.?;
        try std.testing.expectEqual(first, value);
    }
    try fixture.expectExit(0, 42);
}

test "print is infunc and callable from an ordinary function" {
    try expectIo(
        \\func output()
        \\    print("hello")
        \\    const writer: func(imm StringView) unit = print
        \\    writer("world")
        \\output()
        \\exit(42)
    , "", "hello\nworld\n", "", 42);
}

test "print panics on a broken pipe instead of exposing catchable failure" {
    const pipe = try nonblockingPipe();
    pipe[0].close(std.testing.io);
    defer pipe[1].close(std.testing.io);
    const term = try runWithStreams(
        \\if (print("hello") is unit) -> exit(90)
        \\exit(42)
    , .ignore, .{ .file = pipe[1] }, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, term);
}

test "print panics when its newline fails and preserves completed text" {
    const pipe = try nonblockingPipe();
    defer std.Io.File.closeMany(std.testing.io, &pipe);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.fcntl(pipe[1].handle, std.os.linux.F.SETPIPE_SZ, 4096)));
    const term = try runWithStreams(
        \\const array: Array(byte, 4096) = Array(byte, 4096).filled(65) else panic "unexpected none"
        \\if const text: StringView = BytesView.from_array(4096, array).validate_utf8()
        \\    print(text)
        \\    exit(90)
        \\exit(91)
    , .ignore, .{ .file = pipe[1] }, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 134 }, term);
    var bytes: [4096]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try pipe[0].readStreaming(std.testing.io, &.{&bytes}));
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 65), byte);
}
