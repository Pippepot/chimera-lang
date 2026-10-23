const std = @import("std");
const test_sources = @import("test_sources");
const queries = test_sources.queries;
const structures = test_sources.structures;
const modules = test_sources.modules;
const testing = std.testing;
const Fixture = test_sources.SourceFixture;

test "remainder signs boundary values precedence and callable syntax agree in both engines" {
    try Fixture.expectParity(
        \\func run() int
        \\    const remainder = int.%
        \\    var minimum = -2147483648
        \\    if minimum % -1 <> 0 -> return 90
        \\    if minimum % 3 <> -2 -> return 91
        \\    if -7 % 3 <> -1 -> return 92
        \\    if 7 % -3 <> 1 -> return 93
        \\    if -7 % -3 <> -1 -> return 94
        \\    if 0 % 3 <> 0 -> return 95
        \\    if 2147483647 % minimum <> 2147483647 -> return 96
        \\    var value = 17
        \\    value %= 5
        \\    return 30 + value + int.%(17, 5) + remainder(17, 5) + 20 % 6 * 3
    , 42);
    try Fixture.expectSourceDiagnostic("exit(comptime -> 7 % 0)", .compile_time_division_by_zero);
}

test "user remainder operations support expressions and compound field assignment" {
    try Fixture.expectParity(
        \\struct Value
        \\    pub number: int
        \\    pub func %(imm left: Value, imm right: Value) Value -> Value{number = left.number % right.number}
        \\func run() int
        \\    var value = Value{number = 17}
        \\    value %= Value{number = 5}
        \\    value.number %= 3
        \\    return (value % Value{number = 3}).number + 40
    , 42);
}

test "indexed remainder assignment uses checked getter and owned replacement" {
    try Fixture.expectParity(
        \\fallible calculate() int
        \\    var values = [17, 23]
        \\    values[0] %= 5
        \\    if values[9] %= 5 -> return 90
        \\    return values[0] + 40
        \\func run() int
        \\    if const answer = calculate() -> return answer
        \\    return 91
    , 42);
}

test "end relative indexing preserves eager setters and bounds first compound assignment" {
    try Fixture.expectParity(
        \\func distance(ref calls: int) int
        \\    calls += 1
        \\    return 0
        \\func replacement(ref calls: int) int
        \\    calls += 10
        \\    return 42
        \\fallible missing(ref calls: int) int
        \\    calls += 100
        \\    fail
        \\fallible inspect() int
        \\    var values = [40]
        \\    var calls = 0
        \\    if values[^distance(calls)] = replacement(calls) -> return 90
        \\    calls == 11
        \\    if values[^distance(calls)] += replacement(calls) -> return 91
        \\    calls == 12
        \\    if values[^missing?(calls)] = replacement(calls) -> return 92
        \\    calls == 112
        \\    values[^1] += 2
        \\    return values[^1]
        \\func run() int
        \\    if const result = inspect() -> return result
        \\    return 93
    , 42);
}

test "end relative setters preserve contextual byte conversion" {
    try Fixture.expectParity(
        \\import std.text.{byte_int}
        \\fallible inspect() int
        \\    var values: Array(byte, 2) = [0, 0]
        \\    values[0] = 20
        \\    values[^1] = 22
        \\    var view = values.span()
        \\    view[0] = 21
        \\    view[^1] = 23
        \\    byte_int(values[0]) == 21
        \\    byte_int(values[^1]) == 23
        \\    var items: List(byte) = [0, 0]
        \\    items[0] = 20
        \\    items[^1] = 22
        \\    return byte_int(items[0]) + byte_int(items[^1])
        \\func run() int
        \\    if const result = inspect() -> return result
        \\    return 90
    , 42);
}

test "end relative indexing recomputes distances inclusivity and source rejection" {
    const fixture = try Fixture.init("var values = [19, 23]\nexit(values[^1])");
    defer fixture.deinit();
    try fixture.expectExit(0, 23);
    try fixture.db.setInput(queries.SourceText, 0, "var values = [19, 23]\nexit(values[^2])");
    try fixture.expectExit(0, 19);
    try fixture.db.setInput(queries.SourceText, 0, "var values = [19, 23]\nvar selected = values[..=1]\nexit(selected[^1])");
    try fixture.expectExit(0, 23);
    try fixture.db.setInput(queries.SourceText, 0, "var values = [19, 23]\nvar selected = values[..1]\nexit(selected[^1])");
    try fixture.expectExit(0, 19);
    try fixture.db.setInput(queries.SourceText, 0, "const bounds = 1..=\nexit(0)");
    try fixture.expectDiagnostic(0, .invalid_expression);
    try fixture.db.setInput(queries.SourceText, 0, "var values = [19, 23]\nexit(values[^1])");
    try fixture.expectExit(0, 23);
}

test "missing operations report the actual source construct" {
    const source = "struct Label\n    pub value: int\nconst label = Label{value = 1}\nif label == label -> exit(42)";
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .missing_operation);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expectEqualStrings("==", source[diagnostics[0].span.?.start..diagnostics[0].span.?.end]);
    try testing.expectEqual(structures.Operation.@"==", diagnostics[0].kind.missing_operation.operation);
    for ([_][]const u8{ "Label.==(label, label)", "label.==(label)" }) |expression| {
        const rejected = try testing.allocator.print("struct Label\n    pub value: int\nconst label = Label{{value = 1}}\nif {s} -> exit(42)", .{expression});
        defer testing.allocator.free(rejected);
        try Fixture.expectSourceDiagnostic(rejected, .missing_operation);
    }
}

test "operation functions explicit calls have native and compile-time parity" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub func +(imm left: Value, imm right: Value) Value -> Value{value = left.value + right.value}
        \\func run() int -> Value.+(Value{value = 40}, Value{value = 2}).value
    , 42);
}

test "operation functions arithmetic expressions have native and compile-time parity" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub func +(imm left: Value, imm right: Value) Value -> Value{value = left.value + right.value}
        \\    pub func -(imm left: Value, imm right: Value) Value -> Value{value = left.value - right.value}
        \\    pub func *(imm left: Value, imm right: Value) Value -> Value{value = left.value * right.value}
        \\    pub func /(imm left: Value, imm right: Value) Value -> Value{value = left.value / right.value}
        \\    pub func -(imm self: Value) Value -> Value{value = -self.value}
        \\func run() int
        \\    const first = Value{value = 40} + Value{value = 2}
        \\    const second = first - Value{value = 2}
        \\    const third = second * Value{value = 2}
        \\    const fourth = third / Value{value = 2}
        \\    const negative = -fourth
        \\    return -negative.value + 2
    , 42);
}

test "operation functions comparisons and queried logical data preserve parity and short circuit" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub fallible ==(imm left: Value, imm right: Value) unit -> left.value == right.value
        \\    pub fallible <>(imm left: Value, imm right: Value) unit -> left.value <> right.value
        \\    pub fallible <(imm left: Value, imm right: Value) unit -> left.value < right.value
        \\    pub fallible >(imm left: Value, imm right: Value) unit -> left.value > right.value
        \\    pub fallible <=(imm left: Value, imm right: Value) unit -> left.value <= right.value
        \\    pub fallible >=(imm left: Value, imm right: Value) unit -> left.value >= right.value
        \\func skipped() bool
        \\    exit(91)
        \\func zero_value(mut count: int) Value
        \\    count += 1
        \\    return Value{value = 0}
        \\fallible missing() unit -> fail
        \\func run() int
        \\    const left = Value{value = 19}
        \\    const right = Value{value = 23}
        \\    const comparisons = bool(left <> right and left < right and right > left and left <= left and right >= right and left == left)
        \\    const zero = Value{value = 0}
        \\    const inverted = bool(not zero.value <> 0)
        \\    var count = 0
        \\    const inverted_call = bool(not zero_value(count).value <> 0)
        \\    const short_or = bool(true? or skipped()?)
        \\    const short_and = bool(false? and skipped()?)
        \\    if comparisons? and inverted? and inverted_call? and count == 1 and short_or? and not short_and? and not missing() -> return 42
        \\    return 90
    , 42);
}

test "operation functions compound assignment supports user roots and fields" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub func +(imm left: Value, imm right: Value) Value -> Value{value = left.value + right.value}
        \\    pub func -(imm left: Value, imm right: Value) Value -> Value{value = left.value - right.value}
        \\    pub func *(imm left: Value, imm right: Value) Value -> Value{value = left.value * right.value}
        \\    pub func /(imm left: Value, imm right: Value) Value -> Value{value = left.value / right.value}
        \\struct Holder
        \\    item: Value
        \\func run() int
        \\    var value = Value{value = 20}
        \\    value += Value{value = 2}
        \\    value *= Value{value = 2}
        \\    value -= Value{value = 2}
        \\    value /= Value{value = 2}
        \\    var holder = Holder{item = Value{value = 20}}
        \\    holder.item += Value{value = 1}
        \\    return value.value + holder.item.value
    , 42);
}

test "operation functions primitive namespace calls and callable values have parity" {
    try Fixture.expectParity(
        \\func run() int
        \\    const add = int.+
        \\    const total = add(19, 23)
        \\    const difference = int.-(total, 2)
        \\    const product = int.*(difference, 2)
        \\    const quotient = int./(product, 2)
        \\    const negative = int.-(quotient)
        \\    if int.==(total, 42) and int.<>(total, quotient) and int.<(quotient, total) and int.>(total, quotient) and int.<=(quotient, total) and int.>=(total, quotient) and bool.==(true, true) and bool.<>(false, true) and not false?
        \\        return -negative + 2
        \\    return 90
    , 42);
}

test "operation functions primitive externs preserve arithmetic and evaluation order without prelude imports" {
    try Fixture.expectParity(
        \\import std.prelude.{}
        \\import std.exit.{exit}
        \\static declared: int_literal = 19
        \\func digit(mut order: int, imm value: int) int
        \\    order = order * 10 + value
        \\    return value
        \\func flag(mut order: int) bool
        \\    order = order * 10 + 5
        \\    return false
        \\func run() int
        \\    var order = 0
        \\    const sum = digit(order, 1) + digit(order, 2)
        \\    const comparison = bool(digit(order, 3) < digit(order, 4))
        \\    const inverted = bool(not flag(order)?)
        \\    const less = int.<
        \\    const negative = sum.-()
        \\    const uninverted = bool(not inverted?)
        \\    const literal_sum = declared + 23
        \\    const literal_negative = declared.-()
        \\    const literal_copy = declared.copy()
        \\    var total = 40
        \\    total += 2
        \\    total *= 2
        \\    total -= 2
        \\    total /= 2
        \\    const minimum = 2147483647 + 1
        \\    const maximum = minimum - 1
        \\    const doubled = 1073741824 * 2
        \\    if order == 12345 and sum == 3 and comparison? and inverted? and negative == -3 and not uninverted? and literal_sum == 42 and literal_negative == -19 and literal_copy == 19 and total == 41 and minimum == -2147483648 and maximum == 2147483647 and doubled == minimum and -minimum == minimum and -7 / 3 == -2 and int./(7, -3) == -2 and less(-2, -1) and not less(-1, -2) and not false? and true? and not bool.==(true, false) and not bool.<>(true, true)
        \\        return 42
        \\    return 90
    , 42);
}

test "operation functions primitive namespaces reject foreign extensions" {
    for ([_][]const u8{
        "pub extern func int.+(imm left: int, imm right: int) int",
        "func int.helper(imm value: int) int -> value",
        "pub extern func bool.not(imm value: bool) bool",
        "func byte.helper(imm value: byte) byte -> value",
    }) |declaration| {
        const source = try testing.allocator.print("{s}\nexit(42)", .{declaration});
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .invalid_namespace_owner);
        const fixture = try Fixture.initFiles("import std.prelude.{}\nimport std.exit.{exit}\nexit(42)", &.{.{ .path = "std/extension.chi", .module_path = "std.prelude", .source = declaration }});
        defer fixture.deinit();
        const prelude = (try fixture.db.input(queries.StandardFile, queries.standardFileKey("prelude.chi"))).*;
        try fixture.db.setInput(queries.SourceText, prelude, "");
        try fixture.expectDiagnostic(1, .invalid_namespace_owner);
    }
}

test "operation functions primitive division by zero retains caller source locations" {
    for ([_][]const u8{
        "return 42 / 0",
        "return int./(42, 0)",
        "const operation = int./\n    return operation(42, 0)",
    }) |body| {
        const source = try testing.allocator.print("func run() int\n    {s}\nexit(comptime -> run())", .{body});
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .compile_time_division_by_zero);
    }
}

test "minimum integer division by negative one wraps for every divisor location in both engines" {
    try Fixture.expectParity(
        \\func divide(left: int, right: int) int -> left / right
        \\func divide_borrowed(left: int, ref right: int) int -> left / right
        \\func run() int
        \\    const minimum = -2147483647 - 1
        \\    var negative_one = -1
        \\    var three = 3
        \\    if minimum / -1 <> minimum -> return 90
        \\    if minimum / negative_one <> minimum -> return 91
        \\    if divide(minimum, -1) <> minimum -> return 92
        \\    if divide_borrowed(minimum, negative_one) <> minimum -> return 93
        \\    if divide(minimum, three) <> -715827882 -> return 94
        \\    if divide_borrowed(-7, three) <> -2 -> return 95
        \\    if divide(7, -1) <> -7 -> return 96
        \\    if minimum / 1 <> minimum -> return 97
        \\    if int./(minimum, -1) <> minimum -> return 98
        \\    if divide(minimum, -1) * -1 + minimum % -1 <> minimum -> return 99
        \\    return 42
    , 42);
}

test "operation functions primitive signatures invalidate and recover every call form" {
    const cases = [_]struct { valid: []const u8, invalid: []const u8, calls: []const []const u8 }{
        .{
            .valid = "pub extern func int.+(imm left: int, imm right: int) int",
            .invalid = "pub extern func int.+(imm left: int, imm right: int) ref int",
            .calls = &.{ "return 19 + 23", "return int.+(19, 23)", "const operation = int.+\n    return operation(19, 23)" },
        },
        .{
            .valid = "pub extern func int.+(imm left: int, imm right: int) int",
            .invalid = "pub extern func int.+(imm left: int, imm right: int, imm extra: int) int",
            .calls = &.{ "return 19 + 23", "return int.+(19, 23)", "const operation = int.+\n    return operation(19, 23)" },
        },
        .{
            .valid = "pub extern fallible int.<(imm left: int, imm right: int) unit",
            .invalid = "pub extern func int.<(imm left: int, imm right: int) int",
            .calls = &.{ "if 19 < 23 -> return 42\n    return 90", "if int.<(19, 23) -> return 42\n    return 90", "const operation = int.<\n    if operation(19, 23) -> return 42\n    return 90" },
        },
        .{
            .valid = "pub extern fallible bool.==(imm left: bool, imm right: bool) unit",
            .invalid = "pub extern fallible bool.==(mut left: bool, imm right: bool) unit",
            .calls = &.{
                "if true == true -> return 42\n    return 90",
                "if bool.==(true, true) -> return 42\n    return 90",
                "const operation = bool.==\n    if operation(true, true) -> return 42\n    return 90",
            },
        },
    };
    for (cases) |case| for (case.calls) |call| for ([_][]const u8{ "run()", "comptime -> run()" }) |entry| {
        errdefer std.debug.print("Primitive signature: {s}\nCall: {s}\nEntry: {s}\n", .{ case.invalid, call, entry });
        const source = try testing.allocator.print("import std.exit.{{exit}}\nfunc run() int\n    {s}\nexit({s})", .{ call, entry });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        const prelude = (try fixture.db.input(queries.StandardFile, queries.standardFileKey("prelude.chi"))).*;
        try fixture.db.setInput(queries.SourceText, prelude, case.valid);
        try fixture.expectExit(0, 42);
        try fixture.db.setInput(queries.SourceText, prelude, case.invalid);
        try fixture.expectDiagnostic(prelude, .invalid_operation_signature);
        try fixture.db.setInput(queries.SourceText, prelude, "");
        try fixture.expectDiagnostic(null, .missing_operation);
        try fixture.db.setInput(queries.SourceText, prelude, case.valid["pub ".len..]);
        try fixture.expectDiagnostic(null, .private_access);
        try fixture.db.setInput(queries.SourceText, prelude, case.valid);
        try fixture.expectExit(0, 42);
    };
}

test "operation functions minus callable ambiguity and independent invalidation" {
    try Fixture.expectSourceDiagnostic("const operation = int.-\nexit(42)", .ambiguous_operation_reference);
    const unary = "pub extern func int.-(imm value: int) int";
    const binary = "pub extern func int.-(imm left: int, imm right: int) int";
    const prelude_source = unary ++ "\n" ++ binary;
    const calls = [_][]const u8{
        "return -(-42)",
        "return int.-(-42)",
        "const operation: func(imm int) int = int.-\n    return operation(-42)",
        "const value = -42\n    return value.-()",
    };
    for (calls, 0..) |call, call_index| for ([_][]const u8{ "run()", "comptime -> run()" }) |entry| {
        const source = try testing.allocator.print("import std.exit.{{exit}}\nfunc run() int\n    {s}\nexit({s})", .{ call, entry });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source);
        defer fixture.deinit();
        const prelude = (try fixture.db.input(queries.StandardFile, queries.standardFileKey("prelude.chi"))).*;
        try fixture.db.setInput(queries.SourceText, prelude, prelude_source);
        try fixture.expectExit(0, 42);
        try fixture.db.setInput(queries.SourceText, prelude, "pub extern func int.-(mut value: int) int\n" ++ binary);
        try fixture.expectDiagnostic(prelude, .invalid_operation_signature);
        try fixture.db.setInput(queries.SourceText, prelude, unary ++ "\npub extern func int.-(imm left: int, imm right: int) bool");
        try fixture.expectExit(0, 42);
        try fixture.db.setInput(queries.SourceText, prelude, "extern func int.-(imm value: int) int\n" ++ binary);
        try fixture.expectDiagnostic(null, .private_access);
        try fixture.db.setInput(queries.SourceText, prelude, binary);
        try fixture.expectDiagnostic(null, if (call_index == 2) .local_type_mismatch else .missing_operation);
        try fixture.db.setInput(queries.SourceText, prelude, prelude_source);
        try fixture.expectExit(0, 42);
    };
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub func -(imm self: Value) Value -> Value{value = -self.value}
        \\func run() int
        \\    const operation = Value.-
        \\    return operation(Value{value = -42}).value
    , 42);
}

test "operation functions immovable results construct in their final destination" {
    try Fixture.expectParity(
        \\struct Value
        \\    move = none
        \\    copy = none
        \\    value: int
        \\    pub func +(imm left: Value, imm right: Value) Value -> Value{value = left.value + right.value}
        \\func run() int
        \\    const sum = Value{value = 19} + Value{value = 23}
        \\    return sum.value
    , 42);
}

test "operation functions user indexers and qualified explicit bracket calls have parity" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\fallible Value.[](imm self: Value, index: int) int
        \\    index == 0
        \\    return self.value
        \\fallible Value.[]=(mut self: Value, index: int, var replacement: int) unit
        \\    index == 0
        \\    self.value = replacement
        \\fallible calculate() int
        \\    var value = Value{value = 19}
        \\    value[0] += 2
        \\    Value.[]=? (value, 0, 21)
        \\    return Value.[]?(value, 0) + value[0]
        \\func run() int
        \\    if const calculated = calculate() -> return calculated
        \\    return 90
    , 42);
}

test "operation functions conditional compound indexing permits an infallible getter" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub func [](imm self: Value, index: int) int -> self.value
        \\    pub fallible []=(mut self: Value, index: int, var item: int) unit
        \\        index == 0
        \\        self.value = item
        \\func run() int
        \\    var value = Value{value = 40}
        \\    if value[0] += 2 -> return value.value
        \\    return 90
    , 42);
}

test "operation functions conditional compound indexing preserves diverging getters" {
    try Fixture.expectSourceExit(
        \\struct Stop
        \\    copy = trivial
        \\    pub func [](imm self: Stop, index: int) never -> exit(42)
        \\    pub fallible []=(mut self: Stop, index: int, var value: int) unit -> ()
        \\func run() int
        \\    var values = Stop{}
        \\    if values[0] += 1 -> return 91
        \\    return 92
        \\exit(run())
    , 42);
}

test "operation functions reject signatures with extra operands modes results and failure" {
    for ([_][]const u8{
        "func +(imm left: Value, imm right: Value, imm extra: Value) Value -> left",
        "func +(mut left: Value, imm right: Value) Value -> left",
        "func +(imm left: Value, imm right: int) Value -> left",
        "func +(imm left: Value, imm right: Value) int -> 42",
        "fallible +(imm left: Value, imm right: Value) Value -> left",
        "func +(imm left: Value) Value -> left",
        "func +(imm left: Value, imm right: Value, init extra: Value) Value -> left",
    }) |declaration| {
        const source = try testing.allocator.print("struct Value\n    value: int\n    {s}\nconst operation = Value.+\nexit(42)", .{declaration});
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .invalid_operation_signature);
    }
}

test "operation functions explicit three operand calls cannot bypass signature validation" {
    for ([_][]const u8{
        "_ = Value.+(Value{value = 19}, Value{value = 21}, Value{value = 2})",
        "const operation = Value.+\n_ = operation(Value{value = 19}, Value{value = 21}, Value{value = 2})",
    }) |call| {
        const source = try testing.allocator.print(
            \\struct Value
            \\    value: int
            \\    pub func +(imm left: Value, imm right: Value, imm extra: Value) Value -> left
            \\{s}
            \\exit(42)
        , .{call});
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .invalid_operation_signature);
    }
}

test "operation functions generic type lookup specializes without importing its namespace" {
    const library: modules.SourceFile = .{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Value(T: type)
        \\    pub value: T
        \\    pub func +(imm left: Value(T), imm right: Value(T)) Value(T) -> Value(T){value = left.value + right.value}
        \\pub func make(imm value: int) Value(int) -> Value(int){value = value}
    };
    try Fixture.expectFilesParity(
        \\import lib.{make}
        \\func run() int
        \\    const calculated = make(19) + make(23)
        \\    return calculated.value
    , &.{library}, 42);
}

test "operation functions unary and binary minus share spelling" {
    try Fixture.expectParity(
        \\struct Value
        \\    copy = trivial
        \\    value: int
        \\    pub func -(imm self: Value) Value -> Value{value = -self.value}
        \\    pub func -(imm left: Value, imm right: Value) Value -> Value{value = left.value - right.value}
        \\    pub func neg(imm left: Value, imm right: Value) int -> left.value + right.value
        \\func run() int
        \\    const first = Value{value = 19}
        \\    const negative = -first
        \\    const explicit = Value.-(first)
        \\    const difference = Value.-(first, Value{value = -23})
        \\    const negate: func(imm Value) Value = Value.-
        \\    const subtract: func(imm Value, imm Value) Value = Value.-
        \\    const negate_int: func(imm int) int = int.-
        \\    const subtract_int: func(imm int, imm int) int = int.-
        \\    if negative.value == -19 and explicit.value == -19 and difference.value == 42 and negate(first).value == -19 and subtract(first, Value{value = -23}).value == 42 and negate_int(19) == -19 and subtract_int(19, -23) == 42 and first.-().value == -19 and first.-(Value{value = -23}).value == 42 and Value.neg(first, Value{value = 23}) == 42
        \\        return (first - Value{value = -23}).value
        \\    return 90
    , 42);
}

test "operation functions minus methods select explicit static arguments" {
    try Fixture.expectParity(
        \\struct Value
        \\    value: int
        \\    pub func -(imm self: Value, static amount: int) Value -> Value{value = self.value - amount}
        \\func run() int
        \\    const value = Value{value = 44}
        \\    const method = value.-(2)
        \\    const qualified = Value.-(value, 2)
        \\    return method.value + qualified.value - 42
    , 42);
    try Fixture.expectParity(
        \\struct Value(T: type)
        \\    value: T
        \\    pub func -(imm left: Value(T), imm right: Value(T), static adjustment: int) Value(T) -> Value(T){value = left.value - right.value + adjustment}
        \\func run() int
        \\    const first = Value(int){value = 40}
        \\    const second = Value(int){value = 2}
        \\    const method = first.-(second, 4)
        \\    const qualified = Value(int).-(first, second, 4)
        \\    return method.value + qualified.value - 42
    , 42);
}

test "operation functions minus method and qualified ambiguity recompute together" {
    for ([_][]const u8{ "value.-(2)", "Value.-(value, 2)" }) |call| {
        for ([_][]const u8{ "run()", "comptime -> run()" }) |entry| {
            const source = try test_sources.renderTemplate(testing.allocator,
                \\struct Value
                \\    value: int
                \\    pub func -(imm self: Value, static amount: int) Value -> Value{value = self.value - amount}
                \\func run() int
                \\    const value = Value{value = 44}
                \\    return $call.value
                \\exit($entry)
            , .{ .call = call, .entry = entry });
            defer testing.allocator.free(source);
            const fixture = try Fixture.init(source);
            defer fixture.deinit();
            try fixture.expectExit(0, 42);
            const ambiguous = try std.mem.replaceOwned(u8, testing.allocator, source, "func run() int", "    pub func -(imm left: Value, imm right: Value) Value -> Value{value = 42}\nfunc run() int");
            defer testing.allocator.free(ambiguous);
            try fixture.db.setInput(queries.SourceText, 0, ambiguous);
            try fixture.expectDiagnostic(0, .ambiguous_operation_reference);
            try fixture.db.setInput(queries.SourceText, 0, source);
            try fixture.expectExit(0, 42);
        }
    }
}

test "operation functions reject comparison unary and indexer signature mismatches" {
    for ([_]struct { name: []const u8, declaration: []const u8 }{
        .{ .name = "==", .declaration = "func ==(imm left: Value, imm right: Value) Value -> left" },
        .{ .name = "-", .declaration = "func -(mut self: Value) Value -> self" },
        .{ .name = "not", .declaration = "func not(imm self: Value) Value -> self" },
        .{ .name = "[]", .declaration = "fallible [](imm self: Value, mut index: bool) int -> 42" },
        .{ .name = "[]=", .declaration = "fallible []=(imm self: Value, index: int, var replacement: int) unit -> fail" },
        .{ .name = "[]=", .declaration = "fallible []=(mut self: Value, index: int, init replacement: int) unit -> fail" },
    }) |case| {
        const source = try testing.allocator.print("struct Value\n    value: int\n    {s}\nconst operation = Value.{s}\nexit(42)", .{ case.declaration, case.name });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .invalid_operation_signature);
    }
}
