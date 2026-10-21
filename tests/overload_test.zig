const std = @import("std");
const test_sources = @import("test_sources");
const Fixture = test_sources.SourceFixture;
const queries = test_sources.queries;
const structures = test_sources.structures;

test "primitive remainder preserves signed edges in both engines" {
    try Fixture.expectParity(
        \\func remainder(left: int, right: int) int -> left % right
        \\func run() int
        \\    const minimum = -2147483647 - 1
        \\    if remainder(minimum, -1) <> 0 -> return 90
        \\    if remainder(minimum, 3) <> -2 -> return 91
        \\    if remainder(-17, 5) <> -2 -> return 92
        \\    if remainder(17, -5) <> 2 -> return 93
        \\    if minimum % -1 <> 0 -> return 94
        \\    const operation: func(int, int) int = int.%
        \\    if operation(minimum, -1) <> 0 -> return 95
        \\    return 42
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\static invalid = 10 % 0
        \\print(invalid)
    , .compile_time_division_by_zero);
}

test "primitive argument preparation preserves copying and converters" {
    try Fixture.expectParity(
        \\func change(mut value: int) int
        \\    value = 40
        \\    return 2
        \\func run() int
        \\    var value = 1
        \\    const result = value + change(value)
        \\    if result == 3 and value == 40 -> return 42
        \\    return 0
    , 42);
    try Fixture.expectParity(
        \\struct Number
        \\    value: int
        \\converter(imm value: Number) int -> value.value
        \\func run() int -> 40 + Number{value = 2}
    , 42);
}

test "primitive predicates preserve argument snapshots converters and indirect calls" {
    try Fixture.expectParity(
        \\struct Number
        \\    value: int
        \\converter(imm value: Number) int -> value.value
        \\func change(mut value: int) int
        \\    value = 40
        \\    return 2
        \\func run() int
        \\    var value = 1
        \\    if value < change(value) and value == 40
        \\        if 40 >= Number{value = 41} -> return 90
        \\        if not bool.==(true, true) -> return 91
        \\        const less: fallible(int, int) unit = int.<
        \\        if not less(2, 3) -> return 92
        \\        const different: fallible(bool, bool) unit = bool.<>
        \\        if not different(true, false) -> return 93
        \\        if int.==(1, 2) -> return 94
        \\        return 42
        \\    return 95
    , 42);
}

test "overload named functions select logical argument types in both engines" {
    try Fixture.expectParity(
        \\func integer(value: int) int -> value
        \\func boolean(value: bool) int
        \\    if value? -> return 42
        \\    return 0
        \\pub overload choose(integer, boolean)
        \\func run() int -> choose(true) + choose(0)
    , 42);
}

test "overload generic alternatives infer and accept explicit static arguments" {
    try Fixture.expectParity(
        \\func identity(static T: type, value: T) T -> value
        \\func absent(value: none) int -> 0
        \\overload choose(identity, absent)
        \\func run() int -> choose(20) + choose(int, 22)
    , 42);
}

test "overload callable context selects and specializes a single implementation" {
    try Fixture.expectParity(
        \\func identity(static T: type, value: T) T -> value
        \\func absent(value: none) int -> 0
        \\overload choose(identity, absent)
        \\func apply(operation: func(int) int) int -> operation(42)
        \\func run() int
        \\    const selected: func(int) int = choose
        \\    return apply(choose) + selected(0)
    , 42);
}

test "overload methods and custom index types share ordinary selection" {
    try Fixture.expectParity(
        \\struct Key
        \\    value: int
        \\struct Table
        \\    value: int
        \\    func at_integer(imm self: Table, key: int) int -> self.value + key
        \\    func at_key(imm self: Table, key: Key) int -> self.value + key.value
        \\    pub overload at(at_integer, at_key)
        \\    pub overload [](at_integer, at_key)
        \\func run() int
        \\    const table = Table{value = 10}
        \\    return table.at(Key{value = 2}) + table[Key{value = 4}] + Table.[](table, 6)
    , 42);
}

test "overload array brackets preserve borrowed integers and owned range handles" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var values = [10, 20, 30, 40]
        \\    ref first = values[0]
        \\    first = 12
        \\    const bounds = 1..3
        \\    var selected = values[bounds]
        \\    selected[0] = 22
        \\    const tail = values[2..]
        \\    const empty = values[4..4]
        \\    return values[0] + values[1] + tail.len() + selected.len() + empty.len() + values[..].len()
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "overload argument matching does not execute or reorder source expressions" {
    try Fixture.expectParity(
        \\func argument(mut trace: int, digit: int) int
        \\    trace = trace * 10 + digit
        \\    return digit
        \\func integers(left: int, right: int) int -> left + right
        \\func booleans(left: bool, right: bool) int -> 0
        \\overload combine(booleans, integers)
        \\func run() int
        \\    var trace = 0
        \\    const total = combine(argument(trace, 4), argument(trace, 2))
        \\    if total == 6 -> return trace
        \\    return 90
    , 42);
}

test "overload imports and reexports expose the declared set not private helpers" {
    try Fixture.expectFilesParity(
        \\import facade.{choose}
        \\func run() int -> choose(42)
    , &.{
        .{ .path = "implementation/functions.chi", .module_path = "implementation", .source =
        \\func integer(value: int) int -> value
        \\func boolean(value: bool) int -> 0
        \\pub overload choose(integer, boolean)
        },
        .{ .path = "facade/exports.chi", .module_path = "facade", .source = "pub import implementation.{choose}" },
    }, 42);
}

test "overload declarations reject empty nonfunction and duplicate alternatives" {
    try Fixture.expectSourceDiagnostic("overload choose()\nexit(0)", .empty_overload);
    try Fixture.expectSourceDiagnostic("overload choose(42)\nexit(choose(0))", .invalid_overload_candidate);
    try Fixture.expectSourceDiagnostic("func id(value: int) int -> value\noverload choose(id, id)\nexit(choose(0))", .duplicate_overload_candidate);
}

test "overload membership preserves the original signature diagnostic" {
    const fixture = try Fixture.init(
        \\func invalid(value) int -> 0
        \\overload choose(invalid)
        \\exit(choose(42))
    );
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .parameter_type_missing);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, std.testing.allocator);
    defer std.testing.allocator.free(diagnostics);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
}

test "overload mismatches and overlapping generic alternatives are explicit errors" {
    try Fixture.expectSourceDiagnostic("func id(value: int) int -> value\noverload choose(id)\nexit(choose(true))", .no_matching_overload);
    try Fixture.expectSourceDiagnostic(
        \\func id(value: int) int -> value
        \\func generic(static T: type, value: T) T -> value
        \\overload choose(id, generic)
        \\exit(choose(42))
    , .ambiguous_overload);
    try Fixture.expectSourceDiagnostic(
        \\func read(value: int) int -> value
        \\func write(mut value: int) int -> value
        \\overload choose(read, write)
        \\var value = 42
        \\exit(choose(value))
    , .ambiguous_overload);
}

test "overload selected where failure is not candidate filtering" {
    try Fixture.expectSourceDiagnostic(
        \\func constrained(static T: type, value: T) T where T is bool -> value
        \\func absent(value: none) int -> 0
        \\overload choose(constrained, absent)
        \\exit(choose(42))
    , .where_condition_failed);
}

test "overload membership edits invalidate callers and recover from ambiguity" {
    const prefix =
        \\func integer(value: int) int -> value
        \\func alternate(value: int) int -> value + 1
        \\func boolean(value: bool) int -> 0
    ;
    const fixture = try Fixture.init(prefix ++ "\noverload choose(integer, boolean)\nexit(choose(42))");
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, prefix ++ "\noverload choose(alternate, boolean)\nexit(choose(42))");
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(queries.SourceText, 0, prefix ++ "\noverload choose(integer, alternate)\nexit(choose(42))");
    try fixture.expectDiagnostic(null, .ambiguous_overload);
    try fixture.db.setInput(queries.SourceText, 0, prefix ++ "\noverload choose(integer, boolean)\nexit(choose(42))");
    try fixture.expectExit(0, 42);
}

test "overload generic namespaces infer inherited static arguments" {
    try Fixture.expectParity(
        \\struct Container(T: type)
        \\    value: T
        \\    func read(imm self: Container(T)) T -> self.value
        \\    pub overload get(read)
        \\func run() int
        \\    const container = Container(int){value = 42}
        \\    return Container.get(container)
    , 42);
}

test "overload literal defaults are independent of candidate parameter contexts" {
    try Fixture.expectParity(
        \\func owned(imm value: String) int -> 10
        \\func view(imm value: StringView) int -> 32
        \\overload choose(owned, view)
        \\func run() int -> choose("literal") + choose(StringView("view"))
    , 42);
}

test "overload implicit converters do not make alternatives eligible" {
    try Fixture.expectSourceDiagnostic(
        \\struct Source
        \\struct Target
        \\pub converter(value: Source) Target -> Target{}
        \\func target(value: Target) int -> 42
        \\overload choose(target)
        \\exit(choose(Source{}))
    , .no_matching_overload);
}

test "overload return types and fallible call syntax do not select implementations" {
    try Fixture.expectSourceDiagnostic(
        \\func integer(value: int) int -> value
        \\func boolean(value: int) bool -> true
        \\overload choose(integer, boolean)
        \\const result: int = choose(42)
        \\exit(result)
    , .ambiguous_overload);
    try Fixture.expectSourceDiagnostic(
        \\func plain(value: int) int -> value
        \\fallible checked(value: int) int -> value
        \\overload choose(plain, checked)
        \\fallible run() int -> choose?(42)
        \\if const result = run() -> exit(result)
    , .ambiguous_overload);
    try Fixture.expectSourceDiagnostic(
        \\func identity(value: int) int -> value
        \\overload choose(identity)
        \\const unresolved = choose
        \\exit(0)
    , .overload_requires_callable_context);
}

test "overload callable references distinguish mismatches from ambiguity" {
    const declarations =
        \\func first(value: int) int -> value
        \\func second(value: int) int -> value + 1
        \\overload choose(first, second)
    ;
    try Fixture.expectSourceDiagnostic(declarations ++ "\nconst selected: func(int) int = choose\nexit(0)", .ambiguous_overload);
    try Fixture.expectSourceDiagnostic(declarations ++ "\nconst selected: func(int) bool = choose\nexit(0)", .no_matching_overload);
}

test "overload zero argument calls and callable effect widening retain selection" {
    try Fixture.expectParity(
        \\func answer() int -> 21
        \\overload choose(answer)
        \\func run() int
        \\    const selected: fallible() int = choose
        \\    if const result = selected() -> return result + choose()
        \\    return 90
    , 42);
}

test "overload selected alternatives retain exact fallibility" {
    try Fixture.expectParity(
        \\func integer(value: int) int -> value
        \\fallible checked(value: bool) int
        \\    value?
        \\    return 22
        \\overload choose(integer, checked)
        \\func run() int
        \\    if const unexpected = choose(false) -> return 90
        \\    if const result = choose(true) -> return choose(20) + result
        \\    return 91
    , 42);
}

test "overload destination construction preserves fresh immovable results" {
    try Fixture.expectParity(
        \\struct Immovable
        \\    move = none
        \\    copy = none
        \\    value: int
        \\func integer(value: int) Immovable -> Immovable{value = value}
        \\func boolean(value: bool) int -> 0
        \\overload create(integer, boolean)
        \\func run() int
        \\    const result = create(42)
        \\    return result.value
    , 42);
}

test "overload custom setter and compound indexing evaluate the key once" {
    try Fixture.expectParity(
        \\struct Key
        \\    value: int
        \\struct Counter
        \\    value: int
        \\    func read(imm self: Counter, key: Key) int -> self.value
        \\    func write(mut self: Counter, key: Key, var value: int) unit
        \\        self.value = value
        \\    pub overload [](read)
        \\    pub overload []=(write)
        \\func create_key(mut evaluations: int) Key
        \\    evaluations += 1
        \\    return Key{value = 0}
        \\func run() int
        \\    var evaluations = 0
        \\    var counter = Counter{value = 40}
        \\    counter[create_key(evaluations)] += 2
        \\    if evaluations == 1 -> return counter.value
        \\    return 90
    , 42);
}

test "overload range indexing covers initialized lists spans and text views" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var values: List(int) = [10, 20, 30]
        \\    values.reserve?(20)
        \\    var selected = values[1..]
        \\    selected[0] = 22
        \\    const tail = selected[1..]
        \\    const bytes = BytesView("abcd")
        \\    const text = StringView("abcd")
        \\    const byte_slice = bytes[1..3]
        \\    const text_slice = text[1..]
        \\    const empty = values[3..3]
        \\    if const invalid = values[..4] -> return 90
        \\    return values[0] + values[1] + tail.len() + byte_slice.byte_length() + text_slice.byte_length() + bytes[..].byte_length() + empty.len()
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 91
    , 42);
}

test "overload range indexing rejects reversed extreme and invalid UTF8 bounds" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    const values = [10, 20, 30]
        \\    if const invalid = values[2..1] -> return 90
        \\    if const invalid = values[-1..2] -> return 91
        \\    if const invalid = values[0..2147483647] -> return 92
        \\    if const invalid = values[3..^3] -> return 93
        \\    const text = StringView("a\u{e9}z")
        \\    if const invalid = text[1..2] -> return 94
        \\    const selected = text[1..3]
        \\    return 40 + selected.byte_length()
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 95
    , 42);
}

test "overload range results cannot escape their backing owner" {
    try Fixture.expectSourceDiagnostic(
        \\fallible escaped() Span(int)
        \\    var values = [10, 20]
        \\    return values[..]
        \\if const selected = escaped() -> exit(selected.len())
    , .borrow_outlives_source);
}

test "overload typed tuples and overloaded callable arguments receive candidate contexts" {
    try Fixture.expectParity(
        \\func integer(value: int) int -> value
        \\func boolean(value: bool) bool -> value
        \\overload identity(integer, boolean)
        \\func apply(operation: func(int) int) int -> operation(40)
        \\func absent(value: none) int -> 0
        \\overload call(apply, absent)
        \\func pair(value: (int, bool)) int -> value.0
        \\overload unpack(pair, absent)
        \\func run() int -> call(identity) + unpack((2, true))
    , 42);
}

test "overload explicit static argument types select without executing rejected implementations" {
    try Fixture.expectParity(
        \\func integer(static value: int) int -> value
        \\func boolean(static value: bool) int -> 0
        \\overload choose(integer, boolean)
        \\func run() int -> choose(42)
    , 42);
}

test "overload type factories remain usable in annotations and qualified namespaces" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    pub func number() int -> 42
        \\func integer(static value: int) type -> Item
        \\func boolean(static value: bool) int -> 0
        \\overload choose(integer, boolean)
        \\func run() int
        \\    const item: choose(1) = Item{value = 0}
        \\    return choose(1).number() + item.value
    , 42);
}

test "overload noncopyable index arguments preserve borrowing and reject overlapping mutation" {
    try Fixture.expectParity(
        \\struct Key
        \\    copy = none
        \\    value: int
        \\struct Table
        \\    func read(imm self: Table, imm key: Key) int -> key.value
        \\    pub overload [](read)
        \\func run() int
        \\    const key = Key{value = 42}
        \\    const table = Table{}
        \\    return table[key]
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Key
        \\    value: int
        \\struct Table
        \\    func write(mut self: Table, imm key: Key, var value: int) unit
        \\        self.key.value = value
        \\    key: Key
        \\    pub overload []=(write)
        \\var table = Table{key = Key{value = 0}}
        \\table[table.key] = 42
    , .overlapping_mutable_arguments);
}

test "overload range indexing preserves readonly backing and excludes bulk assignment" {
    try Fixture.expectSourceDiagnostic(
        \\fallible run()
        \\    const values = [1, 2, 3]
        \\    var selected = values[..]
        \\    selected[0] = 42
        \\if run() -> exit(0)
    , .reference_not_writable);
    try Fixture.expectSourceDiagnostic(
        \\fallible run()
        \\    var values = [1, 2, 3]
        \\    values[0..2] = [4, 5]
        \\if run() -> exit(0)
    , .call_argument_type_mismatch);
}

test "overload operator sets include unary and binary forms explicitly" {
    try Fixture.expectParity(
        \\struct Number
        \\    value: int
        \\    func negate(imm self: Number) Number -> Number{value = -self.value}
        \\    func subtract(imm left: Number, imm right: Number) Number -> Number{value = left.value - right.value}
        \\    pub overload -(negate, subtract)
        \\func run() int
        \\    const first = Number{value = 44}
        \\    const second = Number{value = 2}
        \\    const negate: func(imm Number) Number = Number.-
        \\    return negate(-(first - second)).value
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Number
        \\    func negate(imm self: Number) Number -> Number{}
        \\    overload -(negate)
        \\    func -(imm self: Number) Number -> Number{}
        \\const number = Number{}
        \\const result = -number
        \\exit(0)
    , .duplicate_struct_member);
    try Fixture.expectSourceDiagnostic(
        \\struct Number
        \\    func -(imm self: Number) Number -> Number{}
        \\    func negate(imm self: Number) Number -> Number{}
        \\    overload -(negate)
        \\const number = Number{}
        \\const result = -number
        \\exit(0)
    , .duplicate_struct_member);
}

test "overload integer indexing retains checked defaults for typed literal values" {
    try Fixture.expectParity(
        \\static position: int_literal = 1
        \\fallible calculate() int
        \\    const values = [0, 42]
        \\    return values[position]
        \\func run() int
        \\    if const result = calculate() -> return result
        \\    return 90
    , 42);
}

test "overload rejected constraints and bodies are not demanded" {
    const declarations =
        \\func integer(value: int) int -> value
        \\func rejected(value: bool) int where int is bool -> unknown_name
        \\overload choose(integer, rejected)
    ;
    try Fixture.expectParity(declarations ++ "\nfunc run() int -> choose(42)", 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\nexit(choose(true))", .where_condition_failed);
}

test "overload builtin widening participates without specificity ranking" {
    const declarations =
        \\func narrow(value: int) int -> value
        \\func widen(value: int | none) int -> 42
    ;
    try Fixture.expectParity(declarations ++ "\noverload choose(widen)\nfunc run() int -> choose(1)", 42);
    try Fixture.expectSourceDiagnostic(declarations ++ "\noverload choose(narrow, widen)\nexit(choose(1))", .ambiguous_overload);
}

test "overload qualified operator declarations resolve namespace implementations" {
    try Fixture.expectParity(
        \\struct Number
        \\    value: int
        \\func Number.integer(imm self: Number, index: int) int -> self.value + index
        \\func Number.boolean(imm self: Number, index: bool) int -> 0
        \\pub overload Number.[](Number.integer, Number.boolean)
        \\func run() int
        \\    const number = Number{value = 40}
        \\    return number[2]
    , 42);
}

test "overload callable contexts refresh return types and effects" {
    const source =
        \\func integer(value: int) int -> value
        \\func boolean(value: bool) int -> 0
        \\overload choose(integer, boolean)
        \\func run() int
        \\    const selected: func(int) int = choose
        \\    return selected(42)
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const changed_effect = try std.mem.replaceOwned(u8, std.testing.allocator, source, "func integer", "fallible integer");
    defer std.testing.allocator.free(changed_effect);
    try fixture.db.setInput(queries.SourceText, 0, changed_effect);
    try fixture.expectDiagnostic(null, .no_matching_overload);
    const changed_result = try std.mem.replaceOwned(u8, std.testing.allocator, source, "int) int -> value", "int) bool -> true");
    defer std.testing.allocator.free(changed_result);
    try fixture.db.setInput(queries.SourceText, 0, changed_result);
    try fixture.expectDiagnostic(null, .no_matching_overload);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}
