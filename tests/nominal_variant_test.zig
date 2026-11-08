const std = @import("std");
const sources = @import("test_sources");
const Fixture = sources.SourceFixture;
const queries = sources.queries;
const structures = sources.structures;
const testing = std.testing;

fn namedType(db: *sources.query.Database, name: []const u8) !structures.TypeId {
    const scope = (try db.get(queries.BuildModuleScope, 0)).* orelse return error.TestUnexpectedResult;
    const value = (try db.get(queries.ResolveStatic, scope.resolveStatic(name).?)).* orelse return error.TestUnexpectedResult;
    return (try db.lookupInterned(queries.CompileTimeValues, value)).type;
}

test "newline variants compose ordinary and nominal alternatives with native interpreter parity" {
    try Fixture.expectParity(
        \\struct Red
        \\struct Blue
        \\struct Green
        \\static Color =
        \\    Red
        \\  | Blue
        \\  | Green
        \\static Message =
        \\    .Empty
        \\  | .Value: int
        \\  | Color
        \\func color(c: Color) int
        \\    match c
        \\        Red -> return 20
        \\        Blue -> return 1
        \\        Green -> return 2
        \\func run() int
        \\    var message:
        \\        Message
        \\      | none = Message.Empty{}
        \\    message =
        \\        Message.Value{22}
        \\    if message is Message.Value
        \\        const payload: int = message
        \\        return color(Red{}) + payload
        \\    return 3
    , 42);
}

test "nominal variants construct narrow and convert without changing the source" {
    try Fixture.expectParity(
        \\static Result = .Success: int | .Failure: int | .Empty
        \\func run() int
        \\    var result: Result = Result.Success{42}
        \\    if result is Result.Success
        \\        const payload: int = result
        \\        if not (result is Result.Success) -> return 1
        \\        return payload
        \\    return 2
    , 42);
}

test "nominal variants aliases and composition retain case types" {
    try Fixture.expectParity(
        \\static Original = .Value: int | .Empty
        \\static Alias = Original
        \\static Extended = Original | .Cancelled
        \\func run() int
        \\    const value: Extended = Alias.Value{42}
        \\    match value
        \\        Extended.Value -> return value
        \\        Extended.Empty -> return 1
        \\        Extended.Cancelled -> return 2
    , 42);
}

test "nominal payloadless cases use only discriminator storage" {
    const fixture = try Fixture.init(
        \\static Cases = .First | .Second: unit | .Absent: none | unit | none
        \\static Single = .Only
    );
    defer fixture.deinit();
    const cases = try namedType(fixture.db, "Cases");
    const layout = (try fixture.db.get(queries.VariantLayout, cases)).*;
    try testing.expectEqualDeep(structures.TypeLayout{ .byte_size = 1, .byte_alignment = 1 }, layout.layout);
    try testing.expectEqual(@as(u32, 1), layout.tag_size);
    for ((try fixture.db.lookupInterned(queries.Types, cases.interned().?)).variant.members) |member| {
        try testing.expectEqual(@as(u32, 0), (try fixture.db.get(queries.HostTypeLayout, member)).byte_size);
    }
    try testing.expectEqual(@as(u32, 0), (try fixture.db.get(queries.HostTypeLayout, try namedType(fixture.db, "Single"))).byte_size);
}

test "nominal payloadless constructors preserve distinct alternatives" {
    try Fixture.expectParity(
        \\static Cases = .First | .Second: unit | .Absent: none | unit | none
        \\func run() int
        \\    var value: Cases = Cases.First{}
        \\    if value is unit | none -> return 1
        \\    value = Cases.Second{}
        \\    if not (value is Cases.Second) -> return 2
        \\    value = Cases.Absent{}
        \\    if value is none -> return 3
        \\    value = none
        \\    if value is none -> return 42
        \\    return 4
    , 42);
}

test "qualified payloadless cases infer instance values with native interpreter parity" {
    try Fixture.expectParity(
        \\static Color =
        \\    .Red
        \\  | .Blue: unit
        \\  | .Green: none
        \\func run() int
        \\    const col = Color.Red
        \\    const blue = Color.Blue
        \\    const green = Color.Green
        \\    if not (col is Color.Red) -> return 1
        \\    if not (blue is Color.Blue) -> return 2
        \\    if not (green is Color.Green) -> return 3
        \\    if green is none | unit -> return 4
        \\    return 42
    , 42);
    try Fixture.expectSourceExit(
        \\static Color = .Red | .Blue | .Green
        \\const col = Color.Red
        \\match col
        \\    Color.Red -> exit(42)
    , 42);
}

test "qualified payloadless references retain type contexts and construct in value contexts" {
    try Fixture.expectParity(
        \\static Cases = .Empty | .Unit: unit | .Absent: none | .Value: int
        \\static Empty: type = Cases.Empty
        \\static selected = if true -> Cases.Empty else Cases.Unit
        \\static Absent: type = Cases.Absent
        \\static Payloadless = Cases.Empty | Cases.Unit | Cases.Absent
        \\static saved: Cases = Cases.Empty
        \\static same = Cases.Empty == Cases.Empty
        \\func empty_type() type -> Cases.Empty
        \\func only_empty(static T: type) int where T == Cases.Empty -> 42
        \\func identity(static T: type, value: T) T -> value
        \\struct Box
        \\    value: Cases
        \\func make() Cases -> Cases.Unit
        \\func read(value: Cases) int
        \\    match value
        \\        Cases.Empty -> return 20
        \\        Cases.Unit -> return 21
        \\        Cases.Absent | Cases.Value -> return 0
        \\func run() int
        \\    const first: empty_type() = Empty
        \\    const absent: Absent = Cases.Absent
        \\    var current: Payloadless = Cases.Empty
        \\    current = Cases.Unit
        \\    var box = Box{value = Cases.Empty}
        \\    box.value = Cases.Absent
        \\    const (a, b) = (Cases.Empty, Cases.Absent)
        \\    const values: Array(Cases, 3) = [Cases.Empty, Cases.Unit, Cases.Absent]
        \\    const inferred = [Cases.Empty, Cases.Empty]
        \\    if not (absent is Cases.Absent) -> return 1
        \\    if not (current is Cases.Unit) -> return 2
        \\    if not (box.value is Cases.Absent) -> return 3
        \\    if not (a is Empty) or not (b is Absent) -> return 4
        \\    if not (values[1] is Cases.Unit) -> return 5
        \\    if not (inferred[0] is Empty) -> return 6
        \\    if not (identity(Cases.Empty, Cases.Empty) is Empty) -> return 7
        \\    if not (saved is Cases.Empty) -> return 8
        \\    if not (selected is Empty) -> return 9
        \\    if not same or only_empty(Cases.Empty) <> 42 -> return 10
        \\    return read(first) + read(make()) + 1
    , 42);
}

test "qualified payloadless overload arguments use their instance types" {
    try Fixture.expectParity(
        \\static Color = .Red | .Blue
        \\func red(value: Color.Red) int -> 42
        \\func blue(value: Color.Blue) int -> 1
        \\overload choose(blue, red)
        \\func run() int -> choose(Color.Red)
    , 42);
}

test "unit none and nominal references share static value and explicit type contexts" {
    try Fixture.expectParity(
        \\import std.ownership.{copyable, movable}
        \\static Color = .Red | .Blue | .Absent: none
        \\static Unit: type = unit
        \\static None: type = none
        \\static Red: type = Color.Red
        \\static saved_unit = unit
        \\static saved_none = none
        \\static saved_red = Color.Red
        \\static saved_absent = Color.Absent
        \\func unit_type() type -> comptime -> unit
        \\func none_type() type -> comptime -> none
        \\func red_type() type -> comptime -> Color.Red
        \\func identity(static T: type, value: T) T -> value
        \\func red_code(static value: Color) int
        \\    if value is Color.Red -> return 42
        \\    return 1
        \\func run() int
        \\    const u: unit_type() = Unit
        \\    const n: none_type() = None
        \\    const red: red_type() = Red
        \\    const inferred = identity(Color.Red)
        \\    const computed = comptime -> Color.Red
        \\    if not (u is unit) or not (saved_unit is unit) -> return 1
        \\    if not (n is none) or not (saved_none is none) -> return 2
        \\    if not (red is Color.Red) or not (saved_red is Color.Red) -> return 3
        \\    if not (inferred is Color.Red) or not (computed is Color.Red) -> return 4
        \\    if not (saved_absent is Color.Absent) -> return 5
        \\    if not copyable(Color.Red) or not movable(Color.Red) -> return 6
        \\    if not copyable(unit) or not movable(none) -> return 7
        \\    const values: Array(Color.Red, 1) = [saved_red]
        \\    if not (values[0] is Red) -> return 8
        \\    return red_code(Color.Red)
    , 42);
}

test "qualified payloadless references preserve imported alias and specialization identities" {
    try Fixture.expectFilesParity(
        \\import lib.{Optional}
        \\static Integers = Optional(int)
        \\static Bytes = Optional(byte)
        \\static Units = Optional(unit)
        \\static Nones = Optional(none)
        \\static Extended = Integers | .Cancelled
        \\static Empty: type = Extended.Empty
        \\func run() int
        \\    const value = Empty
        \\    const other = Bytes.Empty
        \\    if value is Bytes.Empty -> return 1
        \\    if other is Integers.Empty -> return 2
        \\    if not (value is Integers.Empty) -> return 3
        \\    if not (Extended.Cancelled is Extended.Cancelled) -> return 4
        \\    const unit_payload = Units.Some
        \\    const none_payload = Nones.Some
        \\    if not (unit_payload is Units.Some) -> return 5
        \\    if not (none_payload is Nones.Some) -> return 6
        \\    return 42
    , &.{.{ .path = "lib/optional.chi", .module_path = "lib", .source =
        \\pub func Optional(static T: type) type -> .Some: T | .Empty
    }}, 42);
}

test "qualified nominal references require payloads and preserve private access" {
    try Fixture.expectSourceDiagnostic("static Cases = .Value: int | .Empty\nconst value = Cases.Value", .type_value_used_as_runtime_value);
    try Fixture.expectSourceDiagnostic("struct Empty\nconst value = Empty", .type_value_used_as_runtime_value);
    const fixture = try Fixture.initFiles(
        \\import lib
        \\static Cases = lib.cases()
        \\const forged = Cases.Empty
    , &.{.{ .path = "lib/private.chi", .module_path = "lib", .source =
        \\static Hidden = .Empty | .Value: int
        \\pub func cases() type -> Hidden
    }});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .private_access);
}

test "qualified case values refresh when payload eligibility changes" {
    const original =
        \\static Cases = .Value: unit | .Empty
        \\func run() int
        \\    const value = Cases.Value
        \\    if value is Cases.Value -> return 42
        \\    return 1
        \\exit(run())
    ;
    const fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const absent = try std.mem.replaceOwned(u8, testing.allocator, original, ".Value: unit", ".Value: none");
    defer testing.allocator.free(absent);
    try fixture.db.setInput(queries.SourceText, 0, absent);
    try fixture.expectExit(0, 42);
    const payload = try std.mem.replaceOwned(u8, testing.allocator, original, ".Value: unit", ".Value: int");
    defer testing.allocator.free(payload);
    try fixture.db.setInput(queries.SourceText, 0, payload);
    try fixture.expectDiagnostic(0, .type_value_used_as_runtime_value);
    try fixture.db.setInput(queries.SourceText, 0, original);
    try fixture.expectExit(0, 42);
}

test "nominal variants preserve ordinary alternatives and explicit converter values" {
    try Fixture.expectParity(
        \\static Mixed = .Value: int | int | none
        \\static Value = Mixed.Value
        \\func run() int
        \\    const extract = Value.int
        \\    const wrapped = Value{21}
        \\    var mixed: Mixed = 7
        \\    if not (mixed is int) -> return 1
        \\    mixed = wrapped
        \\    if not (mixed is Value) -> return 2
        \\    return extract(wrapped) + int(wrapped)
    , 42);
}

test "nominal variants wrap complete tuple and union payload types" {
    try Fixture.expectParity(
        \\static Payload = int | bool
        \\static Cases = .Pair: (int, int) | .Choice: (int | bool) | .Empty
        \\func run() int
        \\    const pair: (int, int) = Cases.Pair{(20, 22)}
        \\    const (a, b) = pair
        \\    const choice: Payload = Cases.Choice{true}
        \\    if choice is bool and choice -> return a + b
        \\    return 1
    , 42);
}

test "nominal generic specializations retain their own case identities" {
    try Fixture.expectParity(
        \\func Optional(static T: type) type -> .Some: T | .Empty
        \\static Integers = Optional(int)
        \\static Bytes = Optional(byte)
        \\static Combined = Integers | Bytes
        \\func run() int
        \\    const value: Combined = Integers.Some{42}
        \\    if value is Bytes.Some -> return 1
        \\    if value is Integers.Some -> return value
        \\    return 2
    , 42);
}

test "nominal compile time only payloads use static converters" {
    try Fixture.expectParity(
        \\static Cases = .Literal: int_literal | .Empty
        \\static wrapper = Cases.Literal{42}
        \\static payload: int_literal = wrapper
        \\func run() int
        \\    return payload
    , 42);
}

test "nominal cases inherit public declaration visibility and converters" {
    try Fixture.expectFilesParity(
        \\import lib.{Result}
        \\static Alias = Result
        \\static Extended = Result | .Cancelled
        \\func run() int
        \\    const value: Extended = Alias.Success{42}
        \\    if value is Extended.Success -> return value
        \\    return 1
    , &.{.{ .path = "lib/result.chi", .module_path = "lib", .source =
        \\pub static Result = .Success: int | .Failure: int | .Empty
    }}, 42);
}

test "nominal variants reject private public payloads and ordinary alternatives" {
    const declarations = [_][]const u8{
        "struct Hidden\n    copy = fieldwise\n    value: int\npub static Result = .Value: Hidden | .Empty",
        "struct Hidden\n    copy = fieldwise\n    value: int\npub static Result = Hidden | .Empty",
        "struct Hidden\n    copy = fieldwise\n    value: int\npub func Factory(static T: type) type -> .Value: T | Hidden\npub static Result = Factory(int)",
        "struct Hidden\n    copy = fieldwise\n    value: int\npub func Factory(static T: type) type -> .Value: T | .Empty\npub static Result = Factory(Hidden)",
    };
    for (declarations) |declaration| {
        const fixture = try Fixture.initFiles(
            \\import lib.{Result}
            \\const empty = Result.Empty{}
        , &.{.{ .path = "lib/result.chi", .module_path = "lib", .source = declaration }});
        defer fixture.deinit();
        try fixture.expectDiagnostic(1, .public_variant_private_type);
    }
}

test "nominal private case constructors stay private through returned types" {
    const fixture = try Fixture.initFiles(
        \\import lib
        \\static Hidden = lib.caseType()
        \\const forged = Hidden{7}
        \\exit(int(forged))
    , &.{.{ .path = "lib/private.chi", .module_path = "lib", .source =
        \\static Cases = .Value: int | .Empty
        \\pub func caseType() type -> Cases.Value
    }});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .private_struct_field);
    try fixture.db.setInput(queries.SourceText, 1, "pub static Cases = .Value: int | .Empty\npub func caseType() type -> Cases.Value");
    try fixture.expectExit(0, 7);
}

test "nominal cases reject noncopyable payloads at their declaration boundary" {
    try Fixture.expectSourceDiagnostic(
        \\struct Payload
        \\    value: int
        \\static Cases = .Value: Payload | .Empty
        \\const empty = Cases.Empty{}
    , .nominal_payload_not_copyable);
}

test "nominal constructors reject invalid payload shapes" {
    const programs = [_][]const u8{
        "static V = .Value: int | .Empty\nconst x = V.Value{}",
        "static V = .Value: int | .Empty\nconst x = V.Value{1, 2}",
        "static V = .Value: int | .Empty\nconst x = V.Empty{1, 2}",
    };
    for (programs) |program| try Fixture.expectSourceDiagnostic(program, .invalid_nominal_initializer);
    try Fixture.expectSourceDiagnostic("struct S\n    value: int\nconst x = S{42}", .positional_initializer_not_nominal);
    try Fixture.expectRejected("static V = .Value: int | .Empty\nconst x = V.Value{value = 42}");
    try Fixture.expectRejected("static V = .Value: int | .Empty\nconst x = V.Value{42}\nconst payload = x.value");
    try Fixture.expectRejected("static V = .Value: int | .Empty\nconst x: V = 42");
}

test "nominal case declarations reject duplicate names while compositions preserve distinct cases" {
    try Fixture.expectSourceDiagnostic("static V = .Value: int | .Value: bool\nconst x = V.Value{42}", .duplicate_nominal_case);
    try Fixture.expectSourceDiagnostic(
        \\static A = .Value: int | .Empty
        \\static B = .Value: int | .Empty
        \\static Combined = A | B
        \\const x = Combined.Value{42}
    , .ambiguous_nominal_case);
    try Fixture.expectParity(
        \\static A = .Value: int | .Empty
        \\static B = .Value: int | .Empty
        \\static Combined = A | B
        \\func run() int
        \\    const value: Combined = A.Value{42}
        \\    if value is B.Value -> return 1
        \\    if value is A.Value -> return value
        \\    return 2
    , 42);
}

test "nominal unit and none payloads have no generated conversions" {
    const fixture = try Fixture.init(
        \\static Cases = .Unit | .ExplicitUnit: unit | .Absent: none | .Value: int
        \\static UnitCase: type = Cases.Unit
        \\static ExplicitUnitCase: type = Cases.ExplicitUnit
        \\static NoneCase: type = Cases.Absent
        \\static ValueCase = Cases.Value
    );
    defer fixture.deinit();
    const requester = (try fixture.db.input(queries.FileModule, 0)).*;
    for ([_][]const u8{ "UnitCase", "ExplicitUnitCase", "NoneCase" }) |name| {
        const source_type = try namedType(fixture.db, name);
        for ([_]structures.TypeId{ .unit, .none }) |target| {
            const candidates = (try fixture.db.get(queries.ConversionCandidates, .{ .source = .{ .typed = source_type }, .target = target, .requester = requester })).* orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(usize, 0), candidates.len);
        }
    }
    const candidates = (try fixture.db.get(queries.ConversionCandidates, .{ .source = .{ .typed = try namedType(fixture.db, "ValueCase") }, .target = .int, .requester = requester })).*.?;
    try testing.expectEqual(@as(usize, 1), candidates.len);
}

test "nominal discriminator width follows actual alternative count" {
    for ([_]usize{ 256, 257 }) |count| {
        var source: std.Io.Writer.Allocating = .init(testing.allocator);
        defer source.deinit();
        try source.writer.writeAll("static Cases = ");
        for (0..count) |index| {
            if (index != 0) try source.writer.writeAll(" | ");
            try source.writer.print(".C{d}", .{index});
        }
        try source.writer.print("\nfunc run() int\n    const value: Cases = Cases.C{d}{{}}\n    if value is Cases.C{d} -> return 42\n    return 1\n", .{ count - 1, count - 1 });
        const fixture = try Fixture.init(source.written());
        defer fixture.deinit();
        const layout = (try fixture.db.get(queries.VariantLayout, try namedType(fixture.db, "Cases"))).*;
        const size: u32 = if (count == 256) 1 else 2;
        try testing.expectEqual(size, layout.layout.byte_size);
        try testing.expectEqual(size, layout.layout.byte_alignment);
        try testing.expectEqual(size, layout.tag_size);
        try Fixture.expectParity(source.written(), 42);
    }
}

test "nominal compact variants in arrays do not overwrite adjacent storage" {
    try Fixture.expectParity(
        \\static Cases = .First | .Second | .Absent: none | unit | none
        \\struct Packed
        \\    before: byte
        \\    values: Array(Cases, 4)
        \\    after: byte
        \\func run() int
        \\    var packed = Packed{before = 11, values = [Cases.First{}, Cases.Second{}, unit, none], after = 31}
        \\    packed.values[1] = Cases.Absent{}
        \\    if not (packed.values[0] is Cases.First) -> return 1
        \\    if not (packed.values[1] is Cases.Absent) -> return 2
        \\    if not (packed.values[2] is unit) -> return 3
        \\    if not (packed.values[3] is none) -> return 4
        \\    return int(packed.before) + int(packed.after)
    , 42);
}

test "nominal payload edits refresh definitions converters layouts and executable bodies" {
    const original =
        \\static Payload = int
        \\static Cases = .Value: Payload | .Empty
        \\static Case = Cases.Value
        \\func run() int
        \\    const value = Cases.Value{42}
        \\    const payload: Payload = value
        \\    return wrap(int, payload)
        \\exit(run())
    ;
    const fixture = try Fixture.init(original);
    defer fixture.deinit();
    const cases = try namedType(fixture.db, "Cases");
    const case = try namedType(fixture.db, "Case");
    const requester = (try fixture.db.input(queries.FileModule, 0)).*;
    try fixture.expectExit(0, 42);
    try testing.expectEqual(@as(u32, 8), (try fixture.db.get(queries.HostTypeLayout, cases)).byte_size);
    const multiline = try std.mem.replaceOwned(u8, testing.allocator, original, "Cases = .Value: Payload | .Empty", "Cases =\n    .Value: Payload\n  | .Empty");
    defer testing.allocator.free(multiline);
    try fixture.db.setInput(queries.SourceText, 0, multiline);
    try testing.expectEqual(cases, try namedType(fixture.db, "Cases"));
    try testing.expectEqual(case, try namedType(fixture.db, "Case"));
    try fixture.expectExit(0, 42);
    const updated = try std.mem.replaceOwned(u8, testing.allocator, original, "Payload = int", "Payload = byte");
    defer testing.allocator.free(updated);
    try fixture.db.setInput(queries.SourceText, 0, updated);
    try testing.expectEqual(cases, try namedType(fixture.db, "Cases"));
    try testing.expectEqual(case, try namedType(fixture.db, "Case"));
    try testing.expectEqual(@as(u32, 2), (try fixture.db.get(queries.HostTypeLayout, cases)).byte_size);
    const old_conversion = (try fixture.db.get(queries.ConversionCandidates, .{ .source = .{ .typed = case }, .target = .int, .requester = requester })).*.?;
    try testing.expectEqual(@as(usize, 0), old_conversion.len);
    const new_conversion = (try fixture.db.get(queries.ConversionCandidates, .{ .source = .{ .typed = case }, .target = .byte, .requester = requester })).*.?;
    try testing.expectEqual(@as(usize, 1), new_conversion.len);
    try fixture.expectExit(0, 42);
    const changed = try std.mem.replaceOwned(u8, testing.allocator, updated, "{42}", "{43}");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(0, 43);
    const reordered = try std.mem.replaceOwned(u8, testing.allocator, updated, ".Value: Payload | .Empty", ".Empty | .Value: Payload");
    defer testing.allocator.free(reordered);
    try fixture.db.setInput(queries.SourceText, 0, reordered);
    try testing.expectEqual(cases, try namedType(fixture.db, "Cases"));
    try testing.expectEqual(case, try namedType(fixture.db, "Case"));
    try fixture.expectExit(0, 42);
    const renamed = try std.mem.replaceOwned(u8, testing.allocator, reordered, ".Value", ".Success");
    defer testing.allocator.free(renamed);
    try fixture.db.setInput(queries.SourceText, 0, renamed);
    try testing.expect(case != try namedType(fixture.db, "Case"));
    const facts: queries.TypeFacts(*sources.query.Database) = .{ .ctx = fixture.db };
    const identity = (try facts.structIdentity(case)).?;
    try testing.expect((try fixture.db.get(queries.StructDefinition, identity.declared)).* == null);
    try fixture.expectExit(0, 42);
}

test "contextual nominal payload construction and conversion copy once and drop both payload owners" {
    try Fixture.expectParity(
        \\struct Payload
        \\    ref copies: int
        \\    ref drops: int
        \\    value: int
        \\    copy = func(imm self: Payload) Payload
        \\        self.copies += 1
        \\        return Payload{copies = self.copies, drops = self.drops, value = self.value}
        \\    drop = func(deinit self: Payload) unit -> self.drops += 1
        \\static Cases = .Value: Payload | .Empty
        \\func run() int
        \\    var copies = 0
        \\    var drops = 0
        \\    const wrapper: Cases.Value = .Value{Payload{copies = copies, drops = drops, value = 42}}
        \\    const payload: Payload = wrapper
        \\    if not (wrapper is Cases.Value) -> return 1
        \\    const value = payload.value
        \\    if copies <> 1 -> return 2
        \\    if drops <> 2 -> return 3
        \\    return value
    , 42);
}

test "nominal case diagnostics use qualified specialized names" {
    const fixture = try Fixture.init(
        \\static Cases = .Value: int | .Empty
        \\static Value = Cases.Value
        \\func Optional(static T: type) type -> .Some: T | .Empty
        \\static Integers = Optional(int)
        \\static Some = Integers.Some
    );
    defer fixture.deinit();
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    const types: queries.TypeFacts(*sources.query.Database) = .{ .ctx = fixture.db };
    try sources.diagnostic_rendering.writeTypeInner(types, &writer.writer, try namedType(fixture.db, "Value"));
    try writer.writer.writeByte('\n');
    try sources.diagnostic_rendering.writeTypeInner(types, &writer.writer, try namedType(fixture.db, "Some"));
    try testing.expectEqualStrings("Cases.Value\nOptional(int).Some", writer.written());
}

test "wide nominal variants narrow and match without chained joins" {
    var declaration: std.ArrayList(u8) = .empty;
    defer declaration.deinit(testing.allocator);
    try declaration.appendSlice(testing.allocator, "static Wide = .Case0: int");
    for (1..300) |index| {
        var buffer: [32]u8 = undefined;
        try declaration.appendSlice(testing.allocator, try std.fmt.bufPrint(&buffer, " | .Case{d}: int", .{index}));
    }
    try declaration.appendSlice(testing.allocator,
        \\
        \\func classify(value: Wide) int
        \\    if value is Wide.Case299
        \\        const payload: int = value
        \\        return payload
        \\    if value is Wide.Case0 -> return 2
        \\    return match value
        \\        Wide.Case7 -> 3
        \\        _ -> 4
        \\func run() int
        \\    const last: Wide = Wide.Case299{30}
        \\    const first: Wide = Wide.Case0{1}
        \\    const seventh: Wide = Wide.Case7{1}
        \\    const other: Wide = Wide.Case8{1}
        \\    return classify(last) + classify(first) + classify(seventh) + classify(other) + 3
    );
    const source = declaration.items;
    try Fixture.expectParity(source, 42);
}

test "contextual nominal constructors and match arms infer the original case namespace" {
    try Fixture.expectParity(
        \\static Color = .Red | .Blue | .Green
        \\func color(c: Color) int
        \\    match c
        \\        .Red -> return 42
        \\        Color.Blue | .Green -> return 1
        \\func run() int -> color(.Red)
    , 42);
}

test "contextual nominal cases flow through annotations returns fields tuples and arrays" {
    try Fixture.expectParity(
        \\static Cases = .Value: int | .Empty | .Absent: none
        \\static Alias = Cases
        \\struct Box
        \\    value: Alias
        \\func make() Alias -> if true -> .Value{20} else .Empty
        \\func read(value: Alias) int
        \\    match value
        \\        .Value -> return int(value)
        \\        .Empty | .Absent -> return 0
        \\func sum(pair: (Alias, Alias)) int
        \\    const (a, b) = pair
        \\    match pair
        \\        (.Value, .Value) -> return read(a) + read(b)
        \\        _ -> return 1
        \\func run() int
        \\    var box = Box{value = .Empty}
        \\    box.value = .Value{20}
        \\    if read(box.value) <> read(make()) -> return 2
        \\    var current: Alias = .Empty
        \\    current = .Value{20}
        \\    if read(current) <> 20 -> return 3
        \\    const values: Array(Alias, 2) = [.Absent, .Value{22}]
        \\    const narrow: Cases.Value = .Value{20}
        \\    return sum((narrow, values[1]))
    , 42);
}

test "contextual nominal cases retain imported composed and specialized identities" {
    try Fixture.expectFilesParity(
        \\import lib.{Optional}
        \\static Integers = Optional(int)
        \\static Bytes = Optional(byte)
        \\static Extended = Integers | .Cancelled
        \\func read(value: Extended) int
        \\    match value
        \\        .Some -> return int(value)
        \\        .Empty | .Cancelled -> return 1
        \\func run() int
        \\    const other: Bytes = .Some{7}
        \\    return read(.Some{42})
    , &.{.{ .path = "lib/optional.chi", .module_path = "lib", .source =
        \\pub func Optional(static T: type) type -> .Some: T | .Empty
    }}, 42);
}

test "contextual nominal cases reject missing context missing names ambiguous names and invalid payloads" {
    try Fixture.expectSourceDiagnostic("static Color = .Red | .Blue\nconst x = .Red{}", .nominal_case_requires_context);
    try Fixture.expectSourceDiagnostic("static Color = .Red | .Blue\nconst x: Color = .Green{}", .unknown_nominal_case);
    try Fixture.expectSourceDiagnostic("static Color = .Red | .Blue\nfunc f(c: Color) int\n    match c\n        .Green -> return 1\n        _ -> return 2\nexit(f(Color.Red{}))", .unknown_nominal_case);
    try Fixture.expectSourceDiagnostic("static A = .Value: int | .Empty\nstatic B = .Value: int | .Empty\nconst x: A | B = .Value{42}", .ambiguous_nominal_case);
    try Fixture.expectSourceDiagnostic("static A = .Value: int | .Empty\nstatic B = .Value: int | .Empty\nfunc f(x: A | B) int\n    match x\n        .Value -> return 1\n        _ -> return 2\nexit(f(A.Empty{}))", .ambiguous_nominal_case);
    try Fixture.expectSourceDiagnostic("static Cases = .Value: int | .Empty\nconst x: Cases = .Value{}", .invalid_nominal_initializer);
    try Fixture.expectSourceDiagnostic("static Cases = .Value: int | .Empty\nconst x: Cases = .Value", .invalid_nominal_initializer);
    try Fixture.expectSourceDiagnostic("static Cases = .Value: int | .Empty\nconst x: Cases = .Value{1, 2}", .invalid_nominal_initializer);
    try Fixture.expectSourceDiagnostic("struct Red\nconst x: Red = .Red{}", .unknown_nominal_case);
}

test "bare nominal values preserve declaration discovery and payloadless generic identity" {
    try Fixture.expectParity(
        \\static Color = .Red | .Blue
        \\static Single = .Only
        \\func Colors(static T: type) type -> .Red | .Blue
        \\static Generated = Colors(int)
        \\static saved: Color = .Red
        \\func color(value: Color) int
        \\    match value
        \\        .Red -> return 20
        \\        .Blue -> return 1
        \\func run() int
        \\    const first: Color = .Red
        \\    const second: Color = .Red
        \\    const single: Single = .Only
        \\    const generated: Generated = .Red
        \\    if not (generated is Generated.Red) -> return 1
        \\    return color(first) + color(second) + color(saved) - 18
    , 42);
}

test "contextual nominal lookup refreshes after case and parameter edits" {
    const fixture = try Fixture.init(
        \\static A = .Value: int | .Empty
        \\static B = .Value: int | .Empty
        \\func read(value: A) int
        \\    match value
        \\        .Value -> return int(value)
        \\        .Empty -> return 1
        \\exit(read(.Value{42}))
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0,
        \\static A = .Value: int | .Empty
        \\static B = .Value: int | .Empty
        \\func read(value: B) int
        \\    match value
        \\        .Value -> return int(value)
        \\        .Empty -> return 1
        \\exit(read(.Value{43}))
    );
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(queries.SourceText, 0,
        \\static A = .Value: int | .Empty
        \\static B = .Changed: int | .Empty
        \\func read(value: B) int
        \\    match value
        \\        .Changed -> return int(value)
        \\        .Empty -> return 1
        \\exit(read(.Value{43}))
    );
    try fixture.expectDiagnostic(0, .unknown_nominal_case);
}

test "contextual nominal overload arguments use each candidate parameter without executing payloads" {
    try Fixture.expectParity(
        \\static A = .Value: int | .Empty
        \\static B = .Other: int | .Empty
        \\func first(value: A) int
        \\    match value
        \\        .Value -> return int(value)
        \\        .Empty -> return 1
        \\func second(value: B) int -> 2
        \\overload choose(second, first)
        \\func next(mut calls: int) int
        \\    calls += 1
        \\    return 40
        \\func run() int
        \\    var calls = 0
        \\    const result = choose(.Value{next(calls)})
        \\    return result + calls + 1
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\static A = .Value: int | .Empty
        \\static B = .Value: int | .Empty
        \\func first(value: A) int -> 1
        \\func second(value: B) int -> 2
        \\overload choose(first, second)
        \\exit(choose(.Value{42}))
    , .ambiguous_overload);
}

test "contextual nominal static initializers retain expected types" {
    try Fixture.expectParity(
        \\static Cases = .Value: int | .Empty
        \\static saved: Cases = .Value{42}
        \\func read(value: Cases) int
        \\    match value
        \\        .Value -> return int(value)
        \\        .Empty -> return 1
        \\func run() int -> read(saved)
    , 42);
}

test "contextual nominal cases retain private visibility" {
    const fixture = try Fixture.initFiles(
        \\import lib
        \\static Cases = lib.cases()
        \\const forged: Cases = .Value{7}
    , &.{.{ .path = "lib/private.chi", .module_path = "lib", .source =
        \\static Hidden = .Value: int | .Empty
        \\pub func cases() type -> Hidden
    }});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .private_access);
}
