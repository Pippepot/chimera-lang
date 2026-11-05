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
        \\static UnitCase = Cases.Unit
        \\static ExplicitUnitCase = Cases.ExplicitUnit
        \\static NoneCase = Cases.Absent
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

test "nominal payload conversion copies once and drops both payload owners" {
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
        \\    const wrapper = Cases.Value{Payload{copies = copies, drops = drops, value = 42}}
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
