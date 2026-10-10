const std = @import("std");
const test_sources = @import("test_sources");
const SourceFixture = test_sources.SourceFixture;

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
        \\fallible inspect() int
        \\    const text: StringView = "aé\0"
        \\    const suffix = text.slice?(1, 2)
        \\    const bytes = suffix.as_bytes()
        \\    const first = bytes.get?(0)
        \\    if text.slice(2, 1) -> return 90
        \\    if text.slice(-1, 1) -> return 91
        \\    return byte_int(first) - 153
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 92
    , 42);
}

test "borrowed variant bindings alias payload without copying" {
    try SourceFixture.expectParity(
        \\pub struct Payload
        \\    pub number: int
        \\func run() int
        \\    var value: Payload | none = Payload{number = 19}
        \\    if borrow mut payload = value as Payload -> payload.number = 42
        \\    if borrow payload = value as Payload -> return payload.number
        \\    return 90
    , 42);
}

test "borrowed variant payloads can be replaced by a different member shape" {
    try SourceFixture.expectParity(
        \\struct Small
        \\    copy = trivial
        \\    pub number: int
        \\struct Large
        \\    copy = trivial
        \\    pub first: int
        \\    pub second: int
        \\func run() int
        \\    var value: Small | Large = Small{number = 1}
        \\    if borrow mut payload = value as Small -> payload.number = 42
        \\    const replacement: Small | Large = Large{first = 19, second = 23}
        \\    value = replacement
        \\    if borrow payload = value as Large -> return payload.first + payload.second
        \\    return 90
    , 42);
}

test "strings detach literal storage grow clone and clean both owners" {
    try SourceFixture.expectParity(
        \\fallible calculate() int
        \\    var text = "hé"
        \\    text.reserve?(0)
        \\    text.append?("llo")
        \\    var duplicate = text.clone?()
        \\    duplicate.append?("!")
        \\    const bytes = text.as_bytes()
        \\    if const first = bytes.get(0)
        \\        return text.byte_length() + duplicate.byte_length() + byte_int(first) - 75
        \\    return 90
        \\func run() int
        \\    if const answer = calculate() -> return answer
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
        \\fallible inspect() int
        \\    const bytes: BytesView = "\"\\\n\r\t\0"
        \\    const array: Array(byte, 0) = []
        \\    const empty = BytesView.from_array(0, array)
        \\    const text = empty.validate_utf8?()
        \\    if empty.get(0) -> return 90
        \\    return byte_int(bytes.get?(0)) + bytes.byte_length() + text.byte_length() + 2
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 91
    , 42);
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
        \\    const value = text()
        \\    if const view = value as StringView -> return view.byte_length() + 37
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

test "text output writes exact UTF-8 NUL and newline bytes to standard streams" {
    try expectIo(
        \\import std.io.{write_text, stdout, stderr}
        \\fallible output()
        \\    print?("é\0")
        \\    write_text?(stderr, "oops")
        \\    write_text?(stdout, "")
        \\if output() -> exit(42)
        \\exit(90)
    , "", "é\x00\n", "oops", 42);
}

test "byte input initializes only the returned prefix and reports EOF" {
    try expectIo(
        \\import std.memory.{List}
        \\import std.io.{read_bytes, write_all, stdin, stdout}
        \\fallible echo() int
        \\    var buffer = List(byte).new?(0)
        \\    const count = read_bytes?(stdin, buffer, 100)
        \\    const bytes = buffer.bytes?()
        \\    write_all?(stdout, bytes)
        \\    if bytes.get(count) -> return 90
        \\    const eof = read_bytes?(stdin, buffer, 1)
        \\    const empty = read_bytes?(stdin, buffer, 0)
        \\    return count + eof + empty + 36
        \\if const result = echo() -> exit(result)
        \\exit(91)
    , "a\x00\xffé!", "a\x00\xffé!", "", 42);
}

test "reached compile-time IO is rejected while untaken IO remains pure" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func run() int
        \\    if print("hello") -> return 1
        \\    return 2
        \\exit(comptime -> run())
    , .compile_time_unsupported_operation);
    try SourceFixture.expectParity(
        \\func run() int
        \\    if false
        \\        if print("hello") -> return 1
        \\    return 42
    , 42);
}

test "byte array views validate full UTF-8 and execute through transient interpreter borrows" {
    try SourceFixture.expectParity(
        \\fallible inspect() int
        \\    const bytes: Array(byte, 4) = [240, 159, 152, 128]
        \\    const view = BytesView.from_array(4, bytes)
        \\    const text = view.validate_utf8?()
        \\    const empty = text.slice?(4, 0)
        \\    return text.byte_length() + empty.byte_length() + 38
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
    const invalid = [_][]const u8{ "[128]", "[192, 128]", "[224, 128, 128]", "[237, 160, 128]", "[240, 128, 128, 128]", "[244, 144, 128, 128]", "[245, 128, 128, 128]", "[226, 130]" };
    const counts = [_][]const u8{ "1", "2", "3", "3", "4", "4", "4", "2" };
    for (invalid, counts) |bytes, count| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\func run() int
            \\    const bytes: Array(byte, $count) = $bytes
            \\    const view = BytesView.from_array($count, bytes)
            \\    if view.validate_utf8() -> return 90
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
        \\fallible run() int
        \\    var text = "hello"
        \\    const view = text.view()
        \\    text.append?("!")
        \\    return view.byte_length()
        \\if const answer = run() -> exit(answer)
    , .borrow_outlives_source);
    try SourceFixture.expectSourceDiagnostic(
        \\pub struct Payload
        \\    pub number: int
        \\var value: Payload | none = Payload{number = 1}
        \\if borrow payload = value as Payload
        \\    value = none
        \\    exit(payload.number)
    , .borrow_outlives_source);
}

test "generic spans borrow arrays and preserve empty slicing in both engines" {
    try SourceFixture.expectParity(
        \\import std.memory.{Span}
        \\fallible inspect() int
        \\    const numbers: Array(int, 3) = [17, 23, 2]
        \\    const view = Span(int, false).from_array(3, numbers)
        \\    const tail = view.slice?(1, 2)
        \\    const empty = tail.slice?(2, 0)
        \\    if empty.get(0) -> fail
        \\    const first = view.get?(0)
        \\    const second = tail.get?(0)
        \\    const third = tail.get?(1)
        \\    return first[] + second[] + third[] + empty.len() + Span(int, false).empty().len()
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans retain writable access and attenuate in both engines" {
    try SourceFixture.expectParity(
        \\import std.memory.{Span}
        \\fallible inspect() int
        \\    var numbers: Array(int, 2) = [17, 23]
        \\    const writable = Span(int, true).from_array_mut(2, numbers)
        \\    writable[0] = 18
        \\    const element = writable.get_mut?(0)
        \\    element[] = 19
        \\    const readonly = writable.as_imm()
        \\    return readonly[0] + readonly[1]
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
}

test "attenuated empty spans publish readonly cursors in both engines" {
    try SourceFixture.expectParity(
        \\static empty = Span(int, true).empty().as_imm()
        \\func run() int
        \\    if const endpoint = empty.slice(0, 0) -> return endpoint.len() + 42
        \\    return 90
    , 42);
}

test "aggregate call results cannot assume correspondence with input fields" {
    const cases = [_]struct { result_type: []const u8, construct: []const u8, select: []const u8 }{
        .{ .result_type = "Pair", .construct = "Pair{first = value.second, second = value.first}", .select = "reordered" },
        .{ .result_type = "Array(Pair, 1)", .construct = "[Pair{first = value.second, second = value.first}]", .select = "reordered[0]" },
        .{ .result_type = "Box(Pair)", .construct = "Box(Pair).new?(Pair{first = value.second, second = value.first})", .select = "reordered.borrow()[]" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            const source = try test_sources.renderTemplate(std.testing.allocator,
                \\struct Pair
                \\    copy = trivial
                \\    pub first: Ref(byte, true)
                \\    pub second: Ref(byte, true)
                \\fallible swap(imm value: Pair) $result_type -> $construct
                \\fallible inspect() int
                \\    var first_bytes: Array(byte, 1) = [65]
                \\    var second_bytes: Array(byte, 1) = [66]
                \\    const first = first_bytes.get_mut?(0)
                \\    const second = second_bytes.get_mut?(0)
                \\    const reordered = swap?(Pair{first = first, second = second})
                \\    const selected = $select
                \\    const text = BytesView.from_array(1, second_bytes).validate_utf8?()
                \\    selected.first[] = 255
                \\    return byte_int(text.as_bytes().get?(0))
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
        .{ .result_type = "Box(StringView)", .construct = "Box(StringView).new?(text)", .select = "returned.borrow()[]" },
        .{ .result_type = "List(StringView)", .construct = "[text]", .select = "returned[0]" },
        .{ .result_type = "StringView | none", .construct = "text", .select = "if const view = returned as StringView -> view else fail" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "exit(run())", "exit(comptime -> run())" }) |entry| {
            const source = try test_sources.renderTemplate(std.testing.allocator,
                \\struct Wrapped
                \\    pub view: StringView
                \\fallible validate(imm view: Span(byte, true)) $result_type
                \\    const text = BytesView.from_span(view.as_imm()).validate_utf8?()
                \\    return $construct
                \\fallible inspect() int
                \\    var bytes: Array(byte, 1) = [65]
                \\    const writable = bytes.span_mut()
                \\    const returned = validate?(writable)
                \\    const text = $select
                \\    writable[0] = 255
                \\    return byte_int(text.as_bytes().get?(0))
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
        \\    pub writable: Span(byte, true)
        \\    pub readonly: StringView
        \\fallible views(imm source: Span(byte, true)) Views
        \\    return Views{writable = source, readonly = BytesView.from_span(source.as_imm()).validate_utf8?()}
        \\fallible inspect() int
        \\    var bytes: Array(byte, 1) = [65]
        \\    const wrapped = views?(bytes.span_mut())
        \\    const writable = wrapped.writable
        \\    writable[0] = 41
        \\    writable[0] = 42
        \\    return byte_int(writable[0])
        \\func run() int
        \\    if const answer = inspect() -> return answer
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
                \\    pub writable: Span(byte, true)
                \\    pub readonly: StringView
                \\    $operation = func($mode self: Views) Views
                \\        if const text = BytesView.from_span(self.writable.as_imm()).validate_utf8()
                \\            return Views{writable = self.writable, readonly = text}
                \\        exit(90)
                \\fallible inspect() int
                \\    var first: Array(byte, 1) = [65]
                \\    var second: Array(byte, 1) = [66]
                \\    const writable = second.span_mut()
                \\    const original = Views{writable = writable, readonly = BytesView.from_array(1, first).validate_utf8?()}
                \\    const changed = original$transfer
                \\    writable[0] = 255
                \\    return byte_int(changed.readonly.as_bytes().get?(0))
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

test "mutable outputs preserve readonly dependencies through owned and aliased storage" {
    const cases = [_]struct { setup: []const u8, place: []const u8, select: []const u8 }{
        .{ .setup = "var view = View{text = original}", .place = "view", .select = "view.text" },
        .{ .setup = "var wrapped = Wrapped{view = View{text = original}}", .place = "wrapped.view", .select = "wrapped.view.text" },
        .{ .setup = "var wrapped = Wrapped{view = View{text = original}}\n    borrow mut alias = wrapped.view", .place = "alias", .select = "wrapped.view.text" },
        .{ .setup = "var boxed = Box(View).new?(View{text = original})\n    borrow mut alias = boxed.borrow_mut()[]", .place = "alias", .select = "boxed.borrow()[].text" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\pub struct View
            \\    pub text: StringView
            \\struct Wrapped
            \\    pub view: View
            \\fallible refresh(mut value: View, imm source: Span(byte, true))
            \\    value.text = BytesView.from_span(source.as_imm()).validate_utf8?()
            \\fallible inspect() int
            \\    var first: Array(byte, 1) = [65]
            \\    var second: Array(byte, 1) = [66]
            \\    const writable = second.span_mut()
            \\    const original = BytesView.from_array(1, first).validate_utf8?()
            \\    $setup
            \\    refresh?($place, writable)
            \\    return byte_int($select.as_bytes().get?(0)) - 24
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
        \\    pub writable: Span(byte, true)
        \\    pub readonly: StringView
        \\fallible refresh(mut value: Views, imm source: Span(byte, true))
        \\    value = Views{writable = source, readonly = BytesView.from_span(source.as_imm()).validate_utf8?()}
        \\fallible inspect() int
        \\    var first: Array(byte, 1) = [65]
        \\    var second: Array(byte, 1) = [66]
        \\    const writable = second.span_mut()
        \\    var views = Views{writable = writable, readonly = BytesView.from_array(1, first).validate_utf8?()}
        \\    refresh?(views, writable)
        \\    const changed = views.writable
        \\    changed[0] = 41
        \\    changed[0] = 42
        \\    return byte_int(changed[0])
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
}

test "mutable field outputs preserve untouched readonly siblings" {
    for ([_][]const u8{ "", "    borrow mut alias = views.changed\n" }) |alias| {
        const source = try test_sources.renderTemplate(std.testing.allocator,
            \\pub struct View
            \\    pub text: StringView
            \\struct Views
            \\    pub changed: View
            \\    pub untouched: StringView
            \\fallible refresh(mut value: View, imm source: Span(byte, true))
            \\    value.text = BytesView.from_span(source.as_imm()).validate_utf8?()
            \\fallible inspect() int
            \\    var first: Array(byte, 1) = [65]
            \\    var second: Array(byte, 1) = [66]
            \\    const writable = second.span_mut()
            \\    const original = BytesView.from_array(1, first).validate_utf8?()
            \\    var views = Views{changed = View{text = original}, untouched = original}
            \\$alias    refresh?($place, writable)
            \\    const untouched = views.untouched
            \\    writable[0] = 255
            \\    return byte_int(untouched.as_bytes().get?(0)) - 23
            \\func run() int
            \\    if const answer = inspect() -> return answer
            \\    return 90
        , .{ .alias = alias, .place = if (alias.len == 0) "views.changed" else "alias" });
        defer std.testing.allocator.free(source);
        try SourceFixture.expectParity(source, 42);
    }
}

test "generic spans borrow noncopyable elements without copying" {
    try SourceFixture.expectParity(
        \\struct Entry
        \\    copy = none
        \\    pub score: int
        \\fallible inspect() int
        \\    const entries: Array(Entry, 2) = [Entry{score = 17}, Entry{score = 40}]
        \\    const view = entries.span()
        \\    const element = view.get?(1)
        \\    return element[].score + view.len()
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans preserve zero-sized writable ranges" {
    try SourceFixture.expectParity(
        \\struct Empty
        \\    copy = trivial
        \\fallible inspect() int
        \\    var entries: Array(Empty, 3) = [Empty{}, Empty{}, Empty{}]
        \\    const view = entries.span_mut().slice?(1, 2)
        \\    const element = view.get_mut?(1)
        \\    element[] = Empty{}
        \\    if view.get(2) -> fail
        \\    return view.len() + 40
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans cannot escalate readonly access" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\fallible inspect() int
        \\    const entries = [42]
        \\    const view = entries.span()
        \\    const element = view.get_mut?(0)
        \\    return element[]
        \\if const answer = inspect() -> exit(answer)
    , .call_argument_type_mismatch);
}

test "generic spans reject stale validated text through aggregate calls and loops" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\fallible replace(imm view: Span(byte, true))
        \\    const element = view.get_mut?(0)
        \\    element[] = 255
        \\fallible inspect() int
        \\    var entries: Array(byte, 1) = [65]
        \\    const writable = entries.span_mut()
        \\    const text = BytesView.from_span(writable.as_imm()).validate_utf8?()
        \\    var index = 0
        \\    loop
        \\        if index == 2 -> break
        \\        replace?(writable)
        \\        index += 1
        \\    return text.byte_length()
        \\if const answer = inspect() -> exit(answer)
    , .borrow_outlives_source);
    try SourceFixture.expectAnySourceDiagnostic(
        \\fallible inspect() int
        \\    var entries: Array(byte, 1) = [65]
        \\    const writable = entries.span_mut()
        \\    const text = BytesView.from_span(writable.as_imm()).validate_utf8?()
        \\    borrow alias = text
        \\    writable[0] = 255
        \\    return alias.byte_length()
        \\if const answer = inspect() -> exit(answer)
    , .borrow_outlives_source);
}

test "List growth and generic views have parity" {
    try SourceFixture.expectParity(
        \\fallible inspect() int
        \\    var values = List(int).new?(0)
        \\    values.append?(17)
        \\    values.append?(23)
        \\    values.reserve?(8)
        \\    const view = values.view?(0, 2)
        \\    return view[0] + view[1] + view.len()
        \\func run() int
        \\    if const answer = inspect() -> return answer
        \\    return 90
    , 42);
}

test "generic spans cannot escape local storage or survive owner transfer" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func escape() Span(int, false)
        \\    const entries = [42]
        \\    return entries.span()
        \\const view = escape()
        \\if const element = view.get(0) -> exit(element[])
    , .borrow_outlives_source);
    try SourceFixture.expectAnySourceDiagnostic(
        \\func consume(deinit values: List(int)) int -> values.len()
        \\fallible inspect() int
        \\    var entries = List(int).new?(1)
        \\    entries.append?(42)
        \\    const view = entries.span()
        \\    consume(entries)
        \\    return view[0]
        \\if const answer = inspect() -> exit(answer)
    , .use_after_transfer);
}

test "validated text views reject content changes through byte references" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\fallible inspect() int
        \\    var bytes: Array(byte, 1) = [65]
        \\    const writable = bytes.get_mut?(0)
        \\    const view = BytesView.from_array(1, bytes).validate_utf8?()
        \\    writable[] = 255
        \\    return view.byte_length()
        \\if const answer = inspect() -> exit(answer)
    , .borrow_outlives_source);
}

test "borrowed variant aliases follow their owner through loop joins" {
    try SourceFixture.expectParity(
        \\pub struct Payload
        \\    pub number: int
        \\struct Owner
        \\    pub payload: Payload | none
        \\func run() int
        \\    var owner = Owner{payload = Payload{number = 19}}
        \\    if borrow mut value = owner.payload as Payload
        \\        var index = 0
        \\        loop
        \\            if index == 3 -> break
        \\            value.number += 1
        \\            index += 1
        \\        value.number += 20
        \\    if borrow value = owner.payload as Payload -> return value.number
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
        \\fallible output()
        \\    var text = "hello"
        \\    text.append?("!")
        \\    const writer = print
        \\    writer?(text)
        \\if output() -> exit(42)
        \\exit(90)
    , "", "hello!\n", "", 42);
}

test "from_utf8 validates before allocation and owns a copy independent of its input" {
    try expectIo(
        \\fallible output()
        \\    var array: Array(byte, 2) = [195, 169]
        \\    const bytes = BytesView.from_array(2, array)
        \\    var text = String.from_utf8?(bytes)
        \\    array[0] = 65
        \\    text.append?("!")
        \\    const invalid: Array(byte, 1) = [128]
        \\    if String.from_utf8(BytesView.from_array(1, invalid)) -> fail
        \\    print?(text)
        \\if output() -> exit(42)
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
        \\    const array = Array(byte, 16384).filled(42)
        \\    const bytes = BytesView.from_array(16384, array)
        \\    if const count = write_once(stdout, bytes)
        \\        if count <= 0 -> return 90
        \\        if count >= 16384 -> return 91
        \\        if write_all(stdout, bytes) -> return 92
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
        \\const array = Array(byte, 16384).filled(42)
        \\const bytes = BytesView.from_array(16384, array)
        \\if write_all(stdout, bytes) -> exit(90)
        \\exit(42)
    , .ignore, .{ .file = pipe[1] }, false);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
    var bytes: [4096]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try pipe[0].readStreaming(std.testing.io, &.{&bytes}));
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
}

test "broken output pipes propagate fallible failure instead of SIGPIPE termination" {
    const pipe = try nonblockingPipe();
    pipe[0].close(std.testing.io);
    defer pipe[1].close(std.testing.io);
    const term = try runWithStreams(
        \\if print("hello") -> exit(90)
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
        \\fallible run() int
        \\    var buffer = List(byte).new?(1)
        \\    buffer.append?(41)
        \\    if read_bytes(stdin, buffer, 16) -> return 90
        \\    if const first = buffer[0] -> return buffer.len() + byte_int(first)
        \\    return 91
        \\if const answer = run() -> exit(answer)
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
        \\        if text.reserve(2147483647) -> return 90
        \\        if const copy = text.clone()
        \\            if copy.byte_length() <> 5 -> return 91
        \\        else
        \\            return 92
        \\        index += 1
        \\    return text.byte_length() + 37
        \\exit(run())
    , .ignore, .ignore, true);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, term);
}

test "temporary array backing cannot escape through a borrowed view" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\func bad() BytesView -> BytesView.from_array(1, [42])
        \\const view = bad()
    , .borrow_outlives_source);
}

test "borrowing a by-value variant payload cannot escape its callee frame" {
    try SourceFixture.expectAnySourceDiagnostic(
        \\import std.memory.{Ref, borrow_local}
        \\struct Payload
        \\    pub value: int
        \\fallible bad(imm value: Payload | none) Ref(Payload, false)
        \\    if borrow payload = value as Payload -> return borrow_local(Payload, payload)
        \\    fail
        \\if const handle = bad(Payload{value = 42}) -> exit(handle[].value)
    , .borrow_outlives_source);
}

test "permanent text views survive deferred construction and forwarding" {
    try SourceFixture.expectSourceExit(
        \\fallible run() int
        \\    const values: List(StringView) = ["hello", "é"]
        \\    if const first = values[0]
        \\        if const second = values[1]
        \\            return first.byte_length() + second.byte_length() + 35
        \\    return 90
        \\if const answer = run() -> exit(answer)
        \\exit(91)
    , 42);
    try SourceFixture.expectParity(
        \\fallible forward(init value: StringView) StringView -> value
        \\func run() int
        \\    if const value = forward("hello") -> return value.byte_length() + 37
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
