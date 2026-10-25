const std = @import("std");
const standard_library = @import("standard_library");
const test_sources = @import("test_sources");
const query = test_sources.query;
const queries = test_sources.queries;
const structures = test_sources.structures;
const modules = test_sources.modules;
const runtime = test_sources.runtime;
const testing = std.testing;
const allocation_failure_allocator = test_sources.allocation_failure_allocator;

const Fixture = test_sources.SourceFixture;

test "top-level func collection operations fall through successfully" {
    try Fixture.expectSourceExit(
        \\var numbers: List(int) = List(int).new(2) else panic "unexpected none"
        \\const _: unit = numbers.append(19) else panic "unexpected none"
        \\const _: unit = numbers.append(23) else panic "unexpected none"
        \\numbers[0] += 1
        \\numbers[0] + numbers[1] == 43
        \\var total = 0
        \\for number in numbers -> total += number
        \\total == 43
    , 0);
}

test "top-level local handlers capture failure before the entry boundary" {
    try Fixture.expectSourceExit(
        \\func absent() int | none -> return none
        \\if const unexpected: int = absent() -> exit(99)
        \\const saved: int | none = absent()
        \\saved is none
        \\const value = if const found: int = absent() -> found else 42
        \\value == 42
    , 0);
}

test "integer min max select ordered equal negative and extreme values in both engines" {
    try Fixture.expectParity(
        \\import std.math.{min, max}
        \\func check() unit | none
        \\    if not (min(19, 23) == 19) -> return none
        \\    if not (min(23, 19) == 19) -> return none
        \\    if not (max(19, 23) == 23) -> return none
        \\    if not (max(23, 19) == 23) -> return none
        \\    if not (min(0, 0) == 0) -> return none
        \\    if not (max(0, 0) == 0) -> return none
        \\    if not (min(-19, -23) == -23) -> return none
        \\    if not (min(-23, -19) == -23) -> return none
        \\    if not (max(-19, -23) == -19) -> return none
        \\    if not (max(-23, -19) == -19) -> return none
        \\    if not (min(-2147483648, 2147483647) == -2147483648) -> return none
        \\    if not (min(2147483647, -2147483648) == -2147483648) -> return none
        \\    if not (max(-2147483648, 2147483647) == 2147483647) -> return none
        \\    if not (max(2147483647, -2147483648) == 2147483647) -> return none
        \\    if not (min(-2147483648, -2147483648) == -2147483648) -> return none
        \\    if not (max(-2147483648, -2147483648) == -2147483648) -> return none
        \\    if not (min(2147483647, 2147483647) == 2147483647) -> return none
        \\    if not (max(2147483647, 2147483647) == 2147483647) -> return none
        \\    return ()
        \\func run() int
        \\    if (check() is unit) -> return 42
        \\    return 90
    , 42);
}

test "integer min max callable values evaluate arguments once from left to right" {
    try Fixture.expectParity(
        \\import std.math
        \\func argument(mut trace: int, value: int) int
        \\    trace = trace * 10 + value
        \\    return value
        \\func run() int
        \\    const lower = std.math.min
        \\    const upper = std.math.max
        \\    var trace = 0
        \\    if lower(argument(trace, 3), argument(trace, 1)) <> 1 -> return 90
        \\    if trace <> 31 -> return 91
        \\    if upper(argument(trace, 2), argument(trace, 4)) <> 4 -> return 92
        \\    if trace <> 3124 -> return 93
        \\    return 42
    , 42);
}

test "integer min max recompute static results after argument and callable edits" {
    const fixture = try Fixture.init(
        \\import std.math.{min, max}
        \\static selected = min(19, 23)
        \\exit(selected)
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 19);
    try fixture.db.setInput(queries.SourceText, 0,
        \\import std.math.{min, max}
        \\static selected = min(42, 23)
        \\exit(selected)
    );
    try fixture.expectExit(0, 23);
    try fixture.db.setInput(queries.SourceText, 0,
        \\import std.math.{min, max}
        \\static selected = max(42, 23)
        \\exit(selected)
    );
    try fixture.expectExit(0, 42);
}

test "integer clamp handles inclusive equal reversed and extreme bounds in both engines" {
    try Fixture.expectParity(
        \\import std.math.{clamp}
        \\func check() unit | none
        \\    if not (clamp(-1, 0, 10) == 0) -> return none
        \\    if not (clamp(0, 0, 10) == 0) -> return none
        \\    if not (clamp(5, 0, 10) == 5) -> return none
        \\    if not (clamp(10, 0, 10) == 10) -> return none
        \\    if not (clamp(11, 0, 10) == 10) -> return none
        \\    if not (clamp(-30, -20, -10) == -20) -> return none
        \\    if not (clamp(-15, -20, -10) == -15) -> return none
        \\    if not (clamp(0, -20, -10) == -10) -> return none
        \\    if not (clamp(-9, 3, 3) == 3) -> return none
        \\    if not (clamp(9, 3, 3) == 3) -> return none
        \\    if not (clamp(-2147483648, -2147483648, 2147483647) == -2147483648) -> return none
        \\    if not (clamp(2147483647, -2147483648, 2147483647) == 2147483647) -> return none
        \\    if not (clamp(2147483647, -2147483648, -2147483648) == -2147483648) -> return none
        \\    if not (clamp(-2147483648, 2147483647, 2147483647) == 2147483647) -> return none
        \\    if not (clamp(-1, 10, 0) == 10) -> return none
        \\    if not (clamp(5, 10, 0) == 10) -> return none
        \\    if not (clamp(11, 10, 0) == 10) -> return none
        \\    if not (clamp(0, 2147483647, -2147483648) == 2147483647) -> return none
        \\    return ()
        \\func run() int
        \\    if (check() is unit) -> return clamp(42, 0, 100)
        \\    return 90
    , 42);
}

test "multiline delimited expressions preserve nested bodies and surrounding statements" {
    try Fixture.expectParity(
        \\struct Pair
        \\    pub first: int
        \\    pub second: int
        \\func add(
        \\    first: int,
        \\    second: int,
        \\) int -> first + second
        \\func calculate() int | none
        \\    const values = [
        \\        if true
        \\            const base = 19
        \\            base + 1
        \\        else
        \\            90,
        \\        add(
        \\            20,
        \\            2,
        \\        ),
        \\    ]
        \\    const pair = Pair{
        \\        first = values[
        \\            0
        \\        ],
        \\        second = values[1],
        \\    }
        \\    return add(
        \\        pair.first,
        \\        pair.second)
        \\func run() int
        \\    if const answer: int = calculate() -> return answer
        \\    return 91
    , 42);
    try Fixture.expectParity(
        \\func run() int
        \\    const values = [20,
        \\        22].len()
        \\    const next = (
        \\        40)
        \\    return values + next
    , 42);
}

test "multiline imports and function type parameter lists execute in both engines" {
    try Fixture.expectParity(
        \\import std.prelude.{
        \\    exit,
        \\}
        \\func evaluate(imm operation: func(
        \\    imm int,
        \\    imm int,
        \\) int) int -> operation(19, 23)
        \\func run() int
        \\    const result = evaluate(
        \\        int.+,
        \\    )
        \\    return result
    , 42);
}

test "multiline headers reuse continuation indentation for genuine bodies" {
    try Fixture.expectParity(
        \\func add(
        \\    first: int,
        \\    second: int) int
        \\    return first + second
        \\func choose(static T: type) int -> 42
        \\func run() int
        \\    const answer = choose(
        \\        int)
        \\    if add(
        \\        19,
        \\        23) == answer
        \\        return answer
        \\    return 90
    , 42);
    try Fixture.expectSourceDiagnostic("func run() int -> 42\n    const stray = 1\nexit(run())", .indented_block_after_inline_body);
}

const physics = modules.SourceFile{ .path = "physics/body.chi", .module_path = "physics", .source =
    \\pub struct Body
    \\  pub x: int
    \\pub func make(imm x: int) Body -> return Body{x = x}
    \\pub func get(imm body: Body) int -> return body.x
    \\pub func identity(static T: type, imm value: T) T -> return value
    \\pub static answer = 42
    \\static hidden = 99
    \\unknown_top_level_call()
    \\exit(99)
};

test "field visibility rejects foreign initialization projections borrows and transfers" {
    const library = modules.SourceFile{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Value
        \\    secret: int
        \\    pub visible: int
        \\pub func make() Value -> Value{secret = 40, visible = 2}
    };
    const operations = [_][]const u8{
        "const value = Value{secret = 40, visible = 2}\nexit(value.visible)",
        "const value = Value{visible = 2}\nexit(value.visible)",
        "const value = Value{}\nexit(value.visible)",
        "const value = make()\nexit(value.secret)",
        "var value = make()\nvalue.secret = 42\nexit(value.visible)",
        "const value = make()\nconst field = Ref.from(value.secret)\nexit(field.value)",
        "var value = make()\nconst field = Ref.from(value.secret)\nfield.value = 42\nexit(value.visible)",
        "var value = make()\nconst moved = value.secret^\nexit(moved)",
        "func consume(deinit item: int) int -> item\nvar value = make()\nexit(consume(value.secret))",
        "const value = make()\nconst reference = Ref.from(value)\nexit(reference.value.secret)",
        "static answer = make().secret\nexit(answer)",
        "const answer = comptime -> make().secret\nexit(answer)",
    };
    for (operations) |operation| {
        const source = try testing.allocator.print("import lib.{{Value, make}}\n{s}", .{operation});
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{library});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .private_struct_field);
    }
}

test "field visibility distinguishes unknown names from private fields" {
    for ([_]struct { expression: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .expression = "value.secret", .diagnostic = .private_struct_field },
        .{ .expression = "value.missing", .diagnostic = .unknown_field },
        .{ .expression = "lib.Value{missing = 42}", .diagnostic = .unknown_struct_field },
    }) |case| {
        const source = try testing.allocator.print("import lib\nconst value = lib.make()\n_ = {s}\nexit(42)", .{case.expression});
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{.{ .path = "lib/value.chi", .module_path = "lib", .source =
            \\pub struct Value
            \\    secret: int
            \\pub func make() Value -> Value{secret = 42}
        }});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.diagnostic);
    }
}

test "field visibility permits public initialization reads writes borrows and moves" {
    const fixture = try Fixture.initFiles(
        \\import std.memory
        \\import lib.{Value}
        \\var value = Value{first = 20, second = 21}
        \\value.first = 20
        \\var field = Ref.from(value.first)
        \\field.value = 21
        \\const reference = Ref.from(value.first)
        \\const observed = reference.value
        \\const moved = value.second^
        \\exit(observed + moved)
    , &.{.{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Value
        \\    pub first: int
        \\    pub second: int
    }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "field visibility belongs to the module across files and foreign specializations" {
    const files = [_]modules.SourceFile{
        .{ .path = "lib/types.chi", .module_path = "lib", .source =
        \\pub struct Value
        \\    secret: int
        \\pub struct Cell(T: type)
        \\    secret: T
        },
        .{ .path = "lib/build.chi", .module_path = "lib", .source =
        \\pub func make() Value -> Value{secret = 21}
        \\pub func cell(static T: type, item: T) Cell(T) -> Cell(T){secret = item}
        },
        .{ .path = "lib/read.chi", .module_path = "lib", .source =
        \\import std.memory
        \\pub func read(mut value: Value) int
        \\    var field = Ref.from(value.secret)
        \\    field.value = 22
        \\    const reference = Ref.from(value.secret)
        \\    return reference.value
        \\pub func take(static T: type, var value: Cell(T)) T -> value.secret^
        },
    };
    const fixture = try Fixture.initFiles(
        \\import lib
        \\var value = lib.make()
        \\const cell = lib.cell(int, 20)
        \\exit(lib.read(value) + lib.take(int, cell^))
    , &files);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0,
        \\import lib
        \\static answer = lib.take(int, lib.cell(int, 42))
        \\exit(answer)
    );
    try fixture.expectExit(0, 42);
}

test "field visibility stays with the defining module through reexports" {
    const files = [_]modules.SourceFile{
        .{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Value
        \\    secret: int
        \\pub func make() Value -> Value{secret = 42}
        \\pub func read(imm item: Value) int -> item.secret
        },
        .{ .path = "api/export.chi", .module_path = "api", .source = "pub import lib.{Value, make, read}" },
    };
    const fixture = try Fixture.initFiles("import api\nexit(api.read(api.make()))", &files);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, "import api\nexit(api.make().secret)");
    try fixture.expectDiagnostic(0, .private_struct_field);
    try fixture.db.setInput(queries.SourceText, 0, "import api\nexit(api.inspect())");
    try fixture.db.setInput(queries.SourceText, 2,
        \\pub import lib.{Value, make, read}
        \\pub func inspect() int -> make().secret
    );
    try fixture.expectDiagnostic(2, .private_struct_field);
}

test "field visibility rejects foreign generic bodies and inferred immovable initialization" {
    const library = modules.SourceFile{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Cell(T: type)
        \\    move = none
        \\    secret: T
        \\pub func make(static T: type, item: T) Cell(T) -> Cell(T){secret = item}
    };
    for ([_][]const u8{
        "const cell = lib.Cell{secret = 42}\nexit(42)",
        "func accept(init cell: lib.Cell(int)) int -> 42\nfunc run() int | none -> accept(lib.Cell{secret = 42})\nif const result: int = run() -> exit(result) else exit(1)",
        "func read(static T: type, imm cell: T) int -> cell.secret\nconst cell = lib.make(int, 42)\nexit(read(lib.Cell(int), cell))",
    }) |body| {
        const source = try testing.allocator.print("import lib\n{s}", .{body});
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{library});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .private_struct_field);
    }
}

test "field visibility allows whole value copy move and custom hooks in runtime and comptime" {
    const library = modules.SourceFile{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Value
        \\    secret: int
        \\    copy = func(imm self: Value) Value -> Value{secret = self.secret + 1}
        \\    move = func(deinit self: Value) Value -> Value{secret = self.secret + 2}
        \\pub func make() Value -> Value{secret = 39}
        \\pub func read(imm item: Value) int -> item.secret
    };
    try Fixture.expectFilesParity(
        \\import lib
        \\func run() int
        \\    const original = lib.make()
        \\    const copied = original
        \\    const moved = copied^
        \\    return lib.read(moved)
    , &.{library}, 42);
}

test "field visibility allows automatic fieldwise cleanup and custom drop across modules" {
    const fixture = try Fixture.initFiles(
        \\import lib
        \\const value = lib.make()
        \\_ = lib.read(value)
        \\exit(1)
    , &.{.{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\struct Child
        \\    secret: int
        \\    drop = func(deinit self: Child) -> exit(self.secret)
        \\pub struct Value
        \\    child: Child
        \\pub func make() Value -> Value{child = Child{secret = 42}}
        \\pub func read(imm self: Value) int -> self.child.secret
    }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "empty struct bodies support construction and passing in both engines" {
    try Fixture.expectParity(
        \\struct Empty
        \\struct Generic(T: type)
        \\static Anonymous = struct
        \\func Generated() type -> struct
        \\static struct StaticEmpty
        \\static struct StaticGeneric(T: type)
        \\func static_score(imm first: StaticEmpty, imm second: StaticGeneric(int)) int -> 40
        \\func score(imm first: Empty, imm second: Generic(int), imm third: Anonymous, imm fourth: Generated()) int -> 2
        \\func run() int
        \\    const value = Empty{}
        \\    const moved = value^
        \\    const base = comptime -> static_score(StaticEmpty{}, StaticGeneric(int){})
        \\    return base + score(moved, Generic(int){}, Anonymous{}, Generated(){})
    , 42);
}

test "field visibility permits empty structs and validates callable field access" {
    const library = modules.SourceFile{ .path = "lib/value.chi", .module_path = "lib", .source =
        \\pub struct Empty
        \\pub struct Callbacks
        \\    operation: func() int
        \\    pub visible: func() int
        \\func answer() int -> 42
        \\pub func make() Callbacks -> Callbacks{operation = answer, visible = answer}
    };
    const fixture = try Fixture.initFiles("import lib\nconst empty = lib.Empty{}\nconst callbacks = lib.make()\nexit(callbacks.visible())", &.{library});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, "import lib\nconst callbacks = lib.make()\nexit(callbacks.operation())");
    try fixture.expectDiagnostic(0, .private_struct_field);
}

test "func call syntax handles marked expressions and unmarked conditions" {
    try Fixture.expectSourceExit(
        \\func number() int | none -> 40
        \\func variant() int | none -> 2
        \\func run() int | none
        \\    const first: int = number() else return none
        \\    if (if const _selected_result_0: int = number() -> _selected_result_0 else return none) < 0 -> return 1
        \\    if const second: int = variant() -> return first + second
        \\    return 1
        \\if (number() is int) -> if const result: int = run() -> exit(result) else exit(2) else exit(3)
    , 42);
}

test "static type calls preserve public annotation diagnostics" {
    try Fixture.expectSourceDiagnostic(
        \\func hidden(static T: type) type -> T
        \\pub struct Visible
        \\    pub value: hidden(int)
        \\const item = Visible{value = 42}
    , .public_field_private_type);
}

test "static type calls recompute after factory body edits" {
    const original =
        \\func factory(static T: type) type -> T
        \\func take(value: factory(int)) int -> 42
        \\exit(take(0))
    ;
    const fixture = try Fixture.init(original);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const changed = try std.mem.replaceOwned(u8, testing.allocator, original, "type -> T", "type -> bool");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectDiagnostic(0, .call_argument_type_mismatch);
    try fixture.db.setInput(queries.SourceText, 0, original);
    try fixture.expectExit(0, 42);
}

test "static type calls execute factory bodies and preserve compiler control" {
    const fixture = try Fixture.init(
        \\func stop(static T: type) type -> exit(42)
        \\func take(value: stop(int)) int -> 0
        \\exit(take(0))
    );
    defer fixture.deinit();
    try testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    const controls = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
}

test "embedded memory source is registered in the std.memory module" {
    const f = try Fixture.initFiles("import std.memory\nexit(42)", &.{});
    defer f.deinit();
    const module = try f.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const declarations = (try f.db.get(queries.ModuleDeclarations, module)).*.?;
    try testing.expect(!declarations.resolveEntry("allocate_host_storage").?.is_public);
    try f.expectExit(0, 42);
}

test "host storage externs allocate and release bytes and report invalid sizes" {
    const f = try Fixture.initFiles(
        \\import std.memory.{check_storage}
        \\if check_storage(1) is unit -> if check_storage(4097) is unit -> if check_storage(0) is unit -> if check_storage(-1) is unit -> exit(1) else exit(42) else exit(2) else exit(3) else exit(4)
    , &.{});
    defer f.deinit();
    const memory_module = try f.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const memory_file = (try f.db.get(queries.ModuleDeclarations, memory_module)).*.?.resolveStatic("HostStorage").?;
    const resolved = (try f.db.get(queries.ResolveItem, memory_file)).*.?;
    try f.db.setInput(queries.SourceText, resolved.file_id,
        \\struct HostStorage
        \\  address_low: int
        \\  address_high: int
        \\  byte_size: int
        \\  drop = explicit
        \\extern func allocate_host_storage(byte_size: int) HostStorage | none
        \\extern func deallocate_host_storage(deinit storage: HostStorage)
        \\pub func check_storage(byte_size: int) unit | none
        \\  const storage: HostStorage = allocate_host_storage(byte_size) else return none
        \\  deallocate_host_storage(storage^)
        \\  return ()
    );
    try f.expectExit(0, 42);
}

test "typed host allocation is explicit-drop and fallible" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func use_storage(count: int) unit | none
        \\  const allocation: Allocation(int) = (if const _selected_result_0: Allocation(int) = allocate(int, count) -> _selected_result_0^ else return none)
        \\  deallocate(int, allocation^)
        \\  return ()
        \\if (use_storage(0) is unit) -> if (use_storage(3) is unit) -> if (use_storage(-1) is unit) -> exit(1) else if (use_storage(2147483647) is unit) -> exit(2) else exit(42) else exit(3) else exit(4)
    , 42);
}

test "typed allocation transfers initialized values into and out of storage" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_take}
        \\func round_trip() unit | none
        \\  var allocation: Allocation(int) = allocate(int, 3) else return none
        \\  if (unsafe_initialize(int, allocation, 1, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  const value = unsafe_take(int, allocation, 1)
        \\  deallocate(int, allocation^)
        \\  if not (value == 42) -> return none
        \\  return ()
        \\if (round_trip() is unit) -> exit(42) else exit(1)
    , 42);
}

test "typed allocation transfers byte and aggregate elements" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_take}
        \\struct Pair
        \\  first: int
        \\  second: byte
        \\func transfer() unit | none
        \\  var bytes: Allocation(byte) = allocate(byte, 2) else return none
        \\  if (unsafe_initialize(byte, bytes, 1, 7) is unit) -> ()
        \\  else
        \\    deallocate(byte, bytes^)
        \\    return none
        \\  const number = unsafe_take(byte, bytes, 1)
        \\  deallocate(byte, bytes^)
        \\  var pairs: Allocation(Pair) = allocate(Pair, 2) else return none
        \\  if (unsafe_initialize(Pair, pairs, 1, Pair{first = 42, second = number}) is unit) -> ()
        \\  else
        \\    deallocate(Pair, pairs^)
        \\    return none
        \\  const pair = unsafe_take(Pair, pairs, 1)
        \\  deallocate(Pair, pairs^)
        \\  if not (pair.first == 42) -> return none
        \\  return ()
        \\if (transfer() is unit) -> exit(42) else exit(1)
    , 42);
}

test "uninitialized allocation of Ref needs no referent" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func run() unit | none
        \\  const allocation: Allocation(Ref(int)) = allocate(Ref(int), 0) else return none
        \\  deallocate(Ref(int), allocation^)
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "typed allocation borrows an initialized element without copying it" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\struct Tracked
        \\  copy = none
        \\  value: int
        \\func inspect(imm item: Tracked) int -> item.value
        \\func run() unit | none
        \\  var allocation: Allocation(Tracked) = allocate(Tracked, 2) else return none
        \\  if (unsafe_initialize(Tracked, allocation, 1, Tracked{value = 42}) is unit) -> ()
        \\  else
        \\    deallocate(Tracked, allocation^)
        \\    return none
        \\  const observed = inspect(unsafe_borrow(Tracked, allocation, 1))
        \\  unsafe_destroy(Tracked, allocation, 1)
        \\  deallocate(Tracked, allocation^)
        \\  if not (observed == 42) -> return none
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "indexed scalar borrowing works in arithmetic and comparisons" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\func run() unit | none
        \\  var allocation: Allocation(int) = allocate(int, 2) else return none
        \\  if (unsafe_initialize(int, allocation, 1, 40) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  const result = 1 + unsafe_borrow(int, allocation, 1) + 1
        \\  var equal = 0
        \\  if 40 == unsafe_borrow(int, allocation, 1) -> equal = 1
        \\  unsafe_destroy(int, allocation, 1)
        \\  deallocate(int, allocation^)
        \\  if not (result == 42) -> return none
        \\  if not (equal == 1) -> return none
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "indexed boolean borrowing reads only the selected element" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\func run() unit | none
        \\  var allocation: Allocation(bool) = allocate(bool, 2) else return none
        \\  if (unsafe_initialize(bool, allocation, 0, true) is unit) -> ()
        \\  else
        \\    deallocate(bool, allocation^)
        \\    return none
        \\  if (unsafe_initialize(bool, allocation, 1, true) is unit) -> ()
        \\  else
        \\    unsafe_destroy(bool, allocation, 0)
        \\    deallocate(bool, allocation^)
        \\    return none
        \\  var observed = 0
        \\  if unsafe_borrow(bool, allocation, 0) == true -> observed += 21
        \\  if true == unsafe_borrow(bool, allocation, 0) -> observed += 21
        \\  unsafe_destroy(bool, allocation, 1)
        \\  unsafe_destroy(bool, allocation, 0)
        \\  deallocate(bool, allocation^)
        \\  if not (observed == 42) -> return none
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "indexed borrowed noncopyable value cannot become an owned local" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow}
        \\struct Tracked
        \\  copy = none
        \\  value: int
        \\func run() unit | none
        \\  var allocation: Allocation(Tracked) = allocate(Tracked, 1) else return none
        \\  if (unsafe_initialize(Tracked, allocation, 0, Tracked{value = 42}) is unit) -> ()
        \\  else
        \\    deallocate(Tracked, allocation^)
        \\    return none
        \\  const invalid = unsafe_borrow(Tracked, allocation, 0)
        \\  _ = invalid
        \\  deallocate(Tracked, allocation^)
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .type_not_copyable);
}

test "copying an indexed borrowed scalar snapshots it before destruction" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 1) else return none
        \\  if (unsafe_initialize(int, allocation, 0, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  const snapshot = unsafe_borrow(int, allocation, 0)
        \\  unsafe_destroy(int, allocation, 0)
        \\  deallocate(int, allocation^)
        \\  return snapshot
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an indexed allocation element yields a storable Ref" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 2) else return none
        \\  if (unsafe_initialize(int, allocation, 1, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  const reference: Ref(int) = Ref.from(unsafe_borrow(int, allocation, 1))
        \\  const observed = (reference).value
        \\  unsafe_destroy(int, allocation, 1)
        \\  deallocate(int, allocation^)
        \\  return observed
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "typed allocation destroys a nonzero indexed element in place" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\func run() unit | none
        \\  var allocation: Allocation(Tracked) = allocate(Tracked, 2) else return none
        \\  if (unsafe_initialize(Tracked, allocation, 1, Tracked{value = 42}) is unit) -> ()
        \\  else
        \\    deallocate(Tracked, allocation^)
        \\    return none
        \\  unsafe_destroy(Tracked, allocation, 1)
        \\  deallocate(Tracked, allocation^)
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "destroying an allocation element invalidates a Ref of it" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 1) else return none
        \\  if (unsafe_initialize(int, allocation, 0, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  const reference = Ref.from(unsafe_borrow(int, allocation, 0))
        \\  unsafe_destroy(int, allocation, 0)
        \\  const observed = (reference).value
        \\  deallocate(int, allocation^)
        \\  return observed
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "typed allocation destroys a zero-sized initialized element" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy}
        \\struct Empty
        \\  drop = func(deinit self: Empty) -> exit(42)
        \\func run() unit | none
        \\  var allocation: Allocation(Empty) = allocate(Empty, 2) else return none
        \\  if (unsafe_initialize(Empty, allocation, 1, Empty{}) is unit) -> ()
        \\  else
        \\    deallocate(Empty, allocation^)
        \\    return none
        \\  unsafe_destroy(Empty, allocation, 1)
        \\  deallocate(Empty, allocation^)
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "a Box-backed borrow can be stored and read without moving its owner" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference: Ref(int) = Ref.from(owner.borrow())
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "Box owner and Ref handle use their target type names" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const owner: Box(int) = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  const reference: Ref(int) = Ref.from(owner.borrow())
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a mutable Ref changes its Box referent" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference: Ref(int) = Ref.from(owner.borrow())
        \\  reference.value = 42
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a const Ref preserves the origin and captured permission" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  var writable = Ref.from(owner.borrow())
        \\  const immutable: Ref(int) = writable
        \\  return immutable.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a Ref captured from a const owner cannot write its referent" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  const immutable = Ref.from(owner.borrow())
        \\  immutable.value = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
}

test "a const Ref cannot outlive the owner" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  const immutable = Ref.from(owner.borrow())
        \\  const moved = owner^
        \\  _ = moved
        \\  return immutable.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "writing through a mutable Ref replaces its pointee" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference = Ref.from(owner.borrow())
        \\  reference.value = 42
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "dereference assignment rejects read-only Ref" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  Ref.from(owner.borrow()).value = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
}

test "reassigning a var Ref retargets the handle, not its previous copy" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var first: Box(int) = Box.new(17) else return none
        \\  var second: Box(int) = Box.new(7) else return none
        \\  var reference = Ref.from(first.borrow())
        \\  var previous = reference
        \\  reference = Ref.from(second.borrow())
        \\  previous.value = 42
        \\  reference.value = 8
        \\  return previous.value + reference.value - 8
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "dereferencing a Ref reads a noncopyable pointee without moving it" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func run() int | none
        \\  const owner: Box(Pinned) = Box(Pinned).new(Pinned{value = 42}) else return none
        \\  return Ref.from(owner.borrow()).value.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "dereferencing a Ref after transferring its Box is rejected" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  const moved = owner^
        \\  _ = moved
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "removed postfix dereference syntax is rejected" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int
        \\  const number = 42
        \\  return number[]
        \\exit(run())
    , .invalid_expression);
}

test "Box pointee copying uses distinct storage and consuming extraction" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const original: Box(int) = Box.new(21) else return none
        \\  var duplicate: Box(int) = Box.new(Ref.from(original.borrow()).value) else panic "unexpected allocation refusal"
        \\  Ref.from(duplicate.borrow()).value = 42
        \\  return Ref.from(original.borrow()).value + duplicate^.take() - 21
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "Box.new preserves in-place copying of immovable values" {
    try Fixture.expectSourceExit(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\func run() int | none
        \\  const original: Box(CopyOnly) = Box(CopyOnly).new(CopyOnly{value = 41}) else return none
        \\  const copy: Box(CopyOnly) = Box.new(Ref.from(original.borrow()).value) else panic "unexpected allocation refusal"
        \\  return Ref.from(copy.borrow()).value.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "Ref field access distinguishes copying from borrowing" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference = Ref.from(owner.borrow())
        \\  reference.value = 42
        \\  const copied = reference.value
        \\  return copied
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "Allocation methods keep raw storage explicitly managed" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation}
        \\func run() int | none
        \\  var storage: Allocation(int) = Allocation(int).allocate(1) else return none
        \\  if (storage.unsafe_initialize(0, 42) is unit) -> ()
        \\  else
        \\    storage^.deallocate()
        \\    return none
        \\  const observed = Ref.from(storage.unsafe_borrow(0)).value
        \\  const removed = storage.unsafe_take(0)
        \\  storage^.deallocate()
        \\  return observed + removed - 42
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a scoped borrow of a named local does not copy its pointee" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pinned
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func run() int
        \\  const pinned = Pinned{value = 42}
        \\  const item: Ref(Pinned) = Ref.from(pinned) else panic "unexpected none"
        \\  return item.value.value
        \\exit(run())
    , 42);
}

test "explicit references load reference handles and callable values indirectly" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func answer() int -> 42
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const handle = Ref.from(owner.borrow())
        \\  const reference = Ref.from(handle)
        \\  const function = answer
        \\  const callable = Ref.from(function)
        \\  return reference.value.value + callable.value() - 42
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a writable reference retains its referent after handle rebinding" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int | none
        \\  var first: Box(int) = Box.new(17) else return none
        \\  var second: Box(int) = Box.new(7) else return none
        \\  var handle = Ref.from(first.borrow())
        \\  var item = Ref.from(handle.value)
        \\  handle = Ref.from(second.borrow())
        \\  item.value = 42
        \\  return Ref.from(first.borrow()).value + handle.value - 7
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a writable reference updates its named local" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int
        \\  var counter = 17
        \\  var item: Ref(int) = Ref.from(counter) else panic "unexpected none"
        \\  item.value = 42
        \\  return counter
        \\exit(run())
    , 42);
}

test "a writable reference updates a named field" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 17, second = 7}
        \\  var item: Ref(int) = Ref.from(pair.first) else panic "unexpected none"
        \\  item.value = 42
        \\  return pair.first + pair.second - 7
        \\exit(run())
    , 42);
}

test "a writable reference permits field replacement" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 17, second = 7}
        \\  var item: Ref(Pair) = Ref.from(pair) else panic "unexpected none"
        \\  item.value.first = 42
        \\  return pair.first + pair.second - 7
        \\exit(run())
    , 42);
}

test "replacing an owned field through an alias invalidates its old Ref" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\struct Holder
        \\  owner: Box(int)
        \\func run() int | none
        \\  var holder = Holder{owner = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none)}
        \\  const old = Ref.from(holder.owner.borrow())
        \\  var field = Ref.from(holder.owner)
        \\  field.value = (if const _selected_result_1: Box(int) = Box.new(42) -> _selected_result_1^ else return none)
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "replacing a whole Box through an alias invalidates its old Ref" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  const old = Ref.from(owner.borrow())
        \\  var item = Ref.from(owner)
        \\  item.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "replacing an inner Box through a captured Ref invalidates its old Ref" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  var item = Ref.from(handle.value)
        \\  const old = Ref.from(item.value.borrow())
        \\  item.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "an inner Box borrowed through an outer Ref stays valid without replacement" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  var item = Ref.from(handle.value)
        \\  const old = Ref.from(item.value.borrow())
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 17);
}

test "a captured Ref and alias still access an owned pointee after replacement" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  var item = Ref.from(handle.value)
        \\  item.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return Ref.from(item.value.borrow()).value + Ref.from(handle.value.borrow()).value - 42
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "dereference replacement of an inner Box invalidates its old Ref" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const item = Ref.from(handle.value)
        \\  const old = Ref.from(item.value.borrow())
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "replacement through a captured Ref invalidates its old inner Box" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  var item = Ref.from(handle.value)
        \\  const old = Ref.from(item.value.borrow())
        \\  item.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a copied Ref still addresses the outer slot after replacing its inner Box" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const copied = handle
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return Ref.from(copied.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a writable Ref replacement through a call invalidates its old Box" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const item = Ref.from(handle.value)
        \\  const old = Ref.from(item.value.borrow())
        \\  const _: unit = replace(handle) else return none
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "nested aggregate writable references invalidate replaced contents" {
    try Fixture.expectSourceDiagnostic(
        \\struct Handles
        \\  handle: Ref(Box(int))
        \\struct Wrapper
        \\  handles: Handles
        \\func replace(mut wrapper: Wrapper) unit | none
        \\  wrapper.handles.handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var outer: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(17) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const old = Ref.from(handle.value.borrow())
        \\  var wrapper = Wrapper{handles = Handles{handle = handle}}
        \\  const _: unit = replace(wrapper) else return none
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "aggregate writable effects preserve disjoint read-only origins" {
    try Fixture.expectSourceExit(
        \\struct Handles
        \\  writable: Ref(Box(int))
        \\  readonly: Ref(Box(int))
        \\func replace(mut handles: Handles) unit | none
        \\  handles.writable.value = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var changed: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(1) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  const unchanged: Box(Box(int)) = Box.new((if const _selected_result_2: Box(int) = Box.new(42) -> _selected_result_2^ else panic "unexpected none")) else return none
        \\  var handles = Handles{writable = Ref.from(changed.borrow()), readonly = Ref.from(unchanged.borrow())}
        \\  const old = Ref.from(handles.readonly.value.borrow())
        \\  const _: unit = replace(handles) else return none
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "failing indirect aggregate calls invalidate replaced contents" {
    try Fixture.expectSourceDiagnostic(
        \\struct Handles
        \\  handle: Ref(Box(int))
        \\func replace(mut handles: Handles) unit | none
        \\  handles.handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  if not (0 == 1) -> return none
        \\  return ()
        \\func run() int | none
        \\  var outer: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(17) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  var handles = Handles{handle = Ref.from(outer.borrow())}
        \\  const old = Ref.from(handles.handle.value.borrow())
        \\  const operation = replace
        \\  if operation(handles) is unit
        \\    return 0
        \\  else
        \\    return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "writable references inside boxed aggregates invalidate replaced contents" {
    const source =
        \\struct Handles
        \\  handle: Ref(Box(int))
        \\func replace(ref handles: Box(Handles)) unit | none
        \\  Ref.from(handles.borrow()).value.handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var outer: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(17) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const old = Ref.from(handle.value.borrow())
        \\  var handles: Box(Handles) = Box.new(Handles{handle = handle}) else return none
        \\  const _: unit = replace(handles) else return none
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    ;
    const fixture = try Fixture.initFiles(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
    const without_write = try std.mem.replaceOwned(u8, testing.allocator, source, "  const _: unit = replace(handles) else return none\n", "");
    defer testing.allocator.free(without_write);
    try fixture.db.setInput(queries.SourceText, 0, without_write);
    try fixture.expectExit(0, 17);
    const repaired = try std.mem.replaceOwned(u8, testing.allocator, source, "return old.value", "return Ref.from(Ref.from(outer.borrow()).value.borrow()).value");
    defer testing.allocator.free(repaired);
    try fixture.db.setInput(queries.SourceText, 0, repaired);
    try fixture.expectExit(0, 42);
}

test "variant aggregate writable references invalidate replaced contents" {
    try Fixture.expectSourceDiagnostic(
        \\struct Handles
        \\  handle: Ref(Box(int))
        \\func replace(mut candidate: Handles | int) unit | none
        \\  if ref handles: Handles = candidate
        \\    handles.handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var outer: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(17) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  var candidate: Handles | int = Handles{handle = handle}
        \\  const old = Ref.from(handle.value.borrow())
        \\  const _: unit = replace(candidate) else return none
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "read-only references to aggregates attenuate nested writable effects" {
    try Fixture.expectSourceDiagnostic(
        \\struct Handles
        \\  handle: Ref(Box(int))
        \\func replace(imm handles: Ref(Handles)) unit | none
        \\  handles.value.handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var outer: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(17) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const handles: Box(Handles) = Box.new(Handles{handle = handle}) else return none
        \\  const old = Ref.from(handle.value.borrow())
        \\  const _: unit = replace(Ref.from(handles.borrow())) else return none
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .reference_not_writable);
}

test "aggregate effects in loops preserve disjoint read-only origins" {
    try Fixture.expectSourceExit(
        \\struct Handles
        \\  writable: Ref(Box(int))
        \\  readonly: Ref(Box(int))
        \\func replace(mut handles: Handles) unit | none
        \\  handles.writable.value = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var changed: Box(Box(int)) = Box.new((if const _selected_result_1: Box(int) = Box.new(1) -> _selected_result_1^ else panic "unexpected none")) else return none
        \\  const unchanged: Box(Box(int)) = Box.new((if const _selected_result_2: Box(int) = Box.new(42) -> _selected_result_2^ else panic "unexpected none")) else return none
        \\  var handles = Handles{writable = Ref.from(changed.borrow()), readonly = Ref.from(unchanged.borrow())}
        \\  const old = Ref.from(handles.readonly.value.borrow())
        \\  var count = 0
        \\  loop
        \\    if count == 2 -> break
        \\    const _: unit = replace(handles) else return none
        \\    count += 1
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "boxed borrowed contents cannot outlive their original owner" {
    try Fixture.expectSourceDiagnostic(
        \\func invalid() Box(Ref(int)) | none
        \\  const source: Box(int) = Box.new(42) else return none
        \\  return Box.new(Ref.from(source.borrow()))
        \\if const boxed: Box(Ref(int)) = invalid() -> exit(Ref.from(boxed.borrow()).value.value) else exit(1)
    , .borrow_outlives_source);
}

test "loop field replacement removes overwritten reference origins" {
    try Fixture.expectSourceExit(
        \\struct Handle
        \\  value: Ref(int)
        \\func run() int | none
        \\  var original: Box(int) = Box.new(1) else return none
        \\  const replacement: Box(int) = Box.new(42) else return none
        \\  var handle = Handle{value = Ref.from(original.borrow())}
        \\  loop
        \\    handle.value = Ref.from(replacement.borrow())
        \\    break
        \\  original = (if const _selected_result_0: Box(int) = Box.new(2) -> _selected_result_0^ else return none)
        \\  return handle.value.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "initialized raw allocation contents cannot outlive their owner" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, unsafe_initialize, deallocate}
        \\func leak() Allocation(Ref(int)) | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  var slots: Allocation(Ref(int)) = allocate(Ref(int), 1) else return none
        \\  if (unsafe_initialize(Ref(int), slots, 0, Ref.from(owner.borrow())) is unit) -> ()
        \\  else
        \\    deallocate(Ref(int), slots^)
        \\    return none
        \\  return slots^
        \\if const slots: Allocation(Ref(int)) = leak()
        \\  deallocate(Ref(int), slots^)
        \\  exit(1)
        \\else exit(2)
    , .borrow_outlives_source);
}

test "allocation capacity counts zero-sized elements" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func run() int | none
        \\  const slots: Allocation(unit) = allocate(unit, 7) else return none
        \\  const count = slots.capacity()
        \\  deallocate(unit, slots^)
        \\  return count
        \\if const count: int = run() -> exit(count) else exit(1)
    , 7);
}

test "empty raw allocation can escape without borrowed contents" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func make() Allocation(Ref(int)) | none -> (if const _selected_result_0: Allocation(Ref(int)) = allocate(Ref(int), 1) -> _selected_result_0^ else return none)
        \\if const slots: Allocation(Ref(int)) = make()
        \\  deallocate(Ref(int), slots^)
        \\  exit(42)
        \\else exit(1)
    , 42);
}

test "Box preserves the origins of initialized borrowed contents" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const source: Box(int) = Box.new(42) else return none
        \\  const boxed: Box(Ref(int)) = Box.new(Ref.from(source.borrow())) else return none
        \\  return Ref.from(boxed.borrow()).value.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an in-place producer invalidates references into replaced owned values" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\func produce(var handle: Ref(Box(int)), var replacement: Box(int)) Pinned
        \\  handle.value = replacement^
        \\  return Pinned{value = 0}
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const old = Ref.from(handle.value.borrow())
        \\  const produced: Box(Pinned) = Box.new(produce(handle, (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else panic "unexpected none"))) else return none
        \\  return old.value + Ref.from(produced.borrow()).value.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a failing indirect in-place producer invalidates replaced references" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\func produce(var handle: Ref(Box(int))) Pinned | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  if not (0 == 1) -> return none
        \\  return Pinned{value = 0}
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const old = Ref.from(handle.value.borrow())
        \\  const producer = produce
        \\  if const produced: Box(Pinned | none) = Box.new(producer(handle))
        \\    if ref item: Pinned = produced.borrow() -> return item.value
        \\    return old.value
        \\  else
        \\    return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a replacing call cannot return an unrelated Ref into its old pointee" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(var handle: Ref(Box(int)), imm old: Ref(int)) Ref(int) | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return old
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const old = Ref.from(handle.value.borrow())
        \\  const returned: Ref(int) = replace(handle, old) else return none
        \\  return returned.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a copied writable Ref still addresses the slot after a replacing call" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  const copied = handle
        \\  const _: unit = replace(handle) else return none
        \\  return Ref.from(copied.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "another writable Ref stays valid after an owned-pointee replacement call" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var first = Ref.from(outer.borrow())
        \\  var second = Ref.from(outer.borrow())
        \\  const _: unit = replace(first) else return none
        \\  return Ref.from(second.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "replacing an inner Box does not revive a handle to an old outer Box" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var stale = Ref.from(outer.borrow())
        \\  outer = (if const _selected_result_1: Box(Box(int)) = Box(Box(int)).new((if const _selected_result_2: Box(int) = Box.new(23) -> _selected_result_2^ else panic "unexpected none")) -> _selected_result_1^ else return none)
        \\  var fresh = Ref.from(outer.borrow())
        \\  const _: unit = replace(fresh) else return none
        \\  return Ref.from(stale.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a Box borrowed through an explicit reference keeps its stable slot" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var item = Ref.from(outer)
        \\  var from_alias = Ref.from(item.value.borrow())
        \\  var from_owner = Ref.from(outer.borrow())
        \\  const _: unit = replace(from_owner) else return none
        \\  return Ref.from(from_alias.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a read-only Box alias cannot create a writable Ref" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  const item = Ref.from(owner)
        \\  Ref.from(item.value.borrow()).value = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
}

test "borrowing through an inner Box alias does not preserve its old pointee" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var handle = Ref.from(outer.borrow())
        \\  var item = Ref.from(handle.value)
        \\  var old = Ref.from(item.value.borrow())
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "an attenuated Ref stays valid after an owned-pointee replacement call" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var writable = Ref.from(outer.borrow())
        \\  const read_only = writable
        \\  const _: unit = replace(writable) else return none
        \\  return Ref.from(read_only.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a selected Box-slot Ref stays valid after another handle replaces its pointee" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run(flag: bool) int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var selected = if flag == true -> Ref.from(outer.borrow()) else Ref.from(outer.borrow())
        \\  var other = Ref.from(outer.borrow())
        \\  const _: unit = replace(other) else return none
        \\  return Ref.from(selected.value.borrow()).value
        \\if const result: int = run(true) -> if result == 42 -> if const other: int = run(false) -> exit(other) else exit(1) else exit(2) else exit(3)
    , 42);
}

test "a rebound Box-slot Ref stays valid across a branch" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run(flag: bool) int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var selected = Ref.from(outer.borrow())
        \\  if flag == true -> selected = Ref.from(outer.borrow())
        \\  var other = Ref.from(outer.borrow())
        \\  const _: unit = replace(other) else return none
        \\  return Ref.from(selected.value.borrow()).value
        \\if const result: int = run(true) -> if result == 42 -> if const other: int = run(false) -> exit(other) else exit(1) else exit(2) else exit(3)
    , 42);
}

test "a loop-break Box-slot Ref stays valid after another handle replaces its pointee" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var selected = loop -> break Ref.from(outer.borrow())
        \\  var other = Ref.from(outer.borrow())
        \\  const _: unit = replace(other) else return none
        \\  return Ref.from(selected.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "replacing through a loop-carried Ref invalidates an old inner Ref" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var selected = Ref.from(outer.borrow())
        \\  const old = Ref.from(selected.value.borrow())
        \\  var pass = 0
        \\  loop
        \\    if pass == 0
        \\      selected = Ref.from(outer.borrow())
        \\      pass = 1
        \\      continue
        \\    const _: unit = replace(selected) else return none
        \\    break
        \\  return old.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a loop-carried Ref still addresses its slot after replacing its pointee" {
    try Fixture.expectSourceExit(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var selected = Ref.from(outer.borrow())
        \\  var pass = 0
        \\  loop
        \\    if pass == 0
        \\      selected = Ref.from(outer.borrow())
        \\      pass = 1
        \\      continue
        \\    const _: unit = replace(selected) else return none
        \\    break
        \\  return Ref.from(selected.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a loop-carried Ref with another possible owner cannot replace an owned pointee" {
    try Fixture.expectSourceDiagnostic(
        \\func replace(var handle: Ref(Box(int))) unit | none
        \\  handle.value = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var first_inner: Box(int) = Box.new(17) else return none
        \\  var second_inner: Box(int) = Box.new(23) else return none
        \\  var first: Box(Box(int)) = Box(Box(int)).new(first_inner^) else return none
        \\  var second: Box(Box(int)) = Box(Box(int)).new(second_inner^) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  var pass = 0
        \\  loop
        \\    if pass == 0
        \\      selected = Ref.from(second.borrow())
        \\      pass = 1
        \\      continue
        \\    const _: unit = replace(selected) else return none
        \\    break
        \\  return 42
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "independent Box handles stay valid before replacement" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var inner: Box(int) = Box.new(17) else return none
        \\  var outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  var first = Ref.from(outer.borrow())
        \\  var second = Ref.from(outer.borrow())
        \\  return Ref.from(first.value.borrow()).value + Ref.from(second.value.borrow()).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 34);
}

test "a writable reference keeps a mutable local current across a join" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run(flag: bool) int
        \\  var counter = 0
        \\  var item: Ref(int) = Ref.from(counter) else panic "unexpected none"
        \\  if flag == true -> item.value = 20 else item.value = 1
        \\  return counter + item.value
        \\exit(run(true) + run(false))
    , 42);
}

test "a stored Ref and explicit reference observe the same local across a join" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run(flag: bool) int
        \\  var counter = 0
        \\  const reference: Ref(int) = Ref.from(counter) else panic "unexpected none"
        \\  var item: Ref(int) = Ref.from(counter) else panic "unexpected none"
        \\  if flag == true -> item.value = 15 else item.value = 4
        \\  item.value = item.value + 1
        \\  return reference.value + counter
        \\exit(run(true) + run(false))
    , 42);
}

test "an explicit reference rejects temporary sources" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int
        \\  const item = Ref.from(40 + 2)
        \\  return item.value
        \\exit(run())
    , .borrow_requires_place);
}

test "a writable reference needs writable access" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  var item = Ref.from(Ref.from(owner.borrow()).value)
        \\  item.value = 17
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .reference_not_writable);
}

test "a readonly reference cannot replace its referent" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int
        \\  const counter = 17
        \\  const item = Ref.from(counter)
        \\  item.value = 42
        \\  return counter
        \\exit(run())
    , .reference_not_writable);
}

test "a writable reference needs a mutable named place" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int
        \\  const counter = 17
        \\  var item = Ref.from(counter)
        \\  item.value = 42
        \\  return counter
        \\exit(run())
    , .reference_not_writable);
}

test "an explicit reference rejects a moved owner when used" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const item = Ref.from(Ref.from(owner.borrow()).value)
        \\  const moved = owner^
        \\  _ = moved
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "an explicit reference can borrow another writable reference" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int
        \\  var counter = 17
        \\  var first: Ref(int) = Ref.from(counter) else panic "unexpected none"
        \\  var second: Ref(int) = Ref.from(first.value) else panic "unexpected none"
        \\  second.value = 21
        \\  return counter + first.value
        \\exit(run())
    , 42);
}

test "a readonly reference cannot grant writable access" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func run() int
        \\  const counter = 17
        \\  var first = Ref.from(counter)
        \\  const read_only = Ref.from(first.value)
        \\  var second = Ref.from(read_only.value)
        \\  second.value = 42
        \\  return counter
        \\exit(run())
    , .reference_not_writable);
}

test "an explicit reference can borrow a field of another reference" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 17, second = 7}
        \\  var whole: Ref(Pair) = Ref.from(pair) else panic "unexpected none"
        \\  var field: Ref(int) = Ref.from(whole.value.first) else panic "unexpected none"
        \\  field.value = 42
        \\  return pair.first + whole.value.second - 7
        \\exit(run())
    , 42);
}

test "borrowing through an explicit reference addresses its referent" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int
        \\  var counter = 42
        \\  const item: Ref(int) = Ref.from(counter) else panic "unexpected none"
        \\  const reference: Ref(int) = Ref.from(item.value) else panic "unexpected none"
        \\  return reference.value
        \\exit(run())
    , 42);
}

test "an explicit reference passes a noncopyable value to an imm call" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pinned
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func inspect(imm item: Pinned) int -> item.value
        \\func run() int
        \\  const pinned = Pinned{value = 42}
        \\  const item: Ref(Pinned) = Ref.from(pinned) else panic "unexpected none"
        \\  return inspect(item.value)
        \\exit(run())
    , 42);
}

test "an explicit reference can read an immutable parameter field" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func inspect(imm pair: Pair) int
        \\  const item: Ref(int) = Ref.from(pair.first) else panic "unexpected none"
        \\  return item.value + pair.second
        \\exit(inspect(Pair{first = 21, second = 21}))
    , 42);
}

test "a writable reference to a mut parameter copies back" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func update(mut number: int)
        \\  var item: Ref(int) = Ref.from(number) else panic "unexpected none"
        \\  item.value = 42
        \\func run() int
        \\  var number = 17
        \\  update(number)
        \\  return number
        \\exit(run())
    , 42);
}

test "a referenced mut parameter copies back after failure" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func update(mut number: int) unit | none
        \\  var item = Ref.from(number)
        \\  item.value = 42
        \\  if not (0 > 1) -> return none
        \\  return ()
        \\func run() int | none
        \\  var number = 17
        \\  if (update(number) is unit) -> return 1
        \\  return number
        \\if const result: int = run() -> exit(result) else exit(2)
    , 42);
}

test "an explicit reference is invalid after a call replaces its owner" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func replace(mut owner: Box(int)) unit | none
        \\  owner = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none)
        \\  return ()
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  const item = Ref.from(Ref.from(owner.borrow()).value)
        \\  const _: unit = replace(owner) else return none
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "an explicit reference releases its owner after its last use" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(21) else return none
        \\  const item = Ref.from(Ref.from(owner.borrow()).value)
        \\  const snapshot = item.value
        \\  const moved = owner^
        \\  return snapshot + moved^.take()
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "Box and Ref alias analysis recomputes after source edits" {
    const fixture = try Fixture.initFiles(
        \\import std.memory
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  const item = Ref.from(Ref.from(owner.borrow()).value)
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 17);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const first = try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run });

    try fixture.db.setInput(queries.SourceText, 0,
        \\import std.memory
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var item = Ref.from(Ref.from(owner.borrow()).value)
        \\  item.value = 42
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    );
    const second = try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run });
    try testing.expect(first != second);
    try fixture.expectExit(0, 42);

    try fixture.db.setInput(queries.SourceText, 0,
        \\import std.memory
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  const item = Ref.from(Ref.from(owner.borrow()).value)
        \\  const moved = owner^
        \\  _ = moved
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    );
    try fixture.expectDiagnostic(0, .use_after_transfer);

    try fixture.db.setInput(queries.SourceText, 0,
        \\import std.memory
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  const item = Ref.from(Ref.from(owner.borrow()).value)
        \\  return item.value
        \\if const result: int = run() -> exit(result) else exit(1)
    );
    try fixture.expectExit(0, 42);
}

test "an immutable Ref parameter can be read by its callee" {
    try Fixture.expectSourceExit(
        \\func inspect(imm reference: Ref(int)) int -> return reference.value
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  return inspect(Ref.from(owner.borrow()))
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a local field Ref reads its field rather than a copy" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  offset: int
        \\  value: int
        \\func run() int
        \\  const pair = Pair{offset = 2, value = 40}
        \\  const reference: Ref(int) = Ref.from(pair.value) else panic "unexpected none"
        \\  return (reference).value + pair.offset
        \\exit(run())
    , 42);
}

test "a nested local field Ref reaches the leaf" {
    try Fixture.expectSourceExit(
        \\struct Inner
        \\  first: int
        \\  second: int
        \\struct Outer
        \\  prefix: int
        \\  inner: Inner
        \\func run() int
        \\  const outer = Outer{prefix = 2, inner = Inner{first = 17, second = 40}}
        \\  const reference: Ref(int) = Ref.from(outer.inner.second) else panic "unexpected none"
        \\  return (reference).value + outer.prefix
        \\exit(run())
    , 42);
}

test "Ref.from addresses a borrowed parameter field" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  prefix: int
        \\  value: int
        \\func inspect(imm pair: Pair) int -> (Ref.from(pair.value)).value
        \\func run() int
        \\  const pair = Pair{prefix = 2, value = 40}
        \\  return inspect(pair) + pair.prefix - 2
        \\exit(run())
    , 40);
}

test "moving a field invalidates its Ref" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pair
        \\  value: int
        \\  sibling: int
        \\func run() int
        \\  var pair = Pair{value = 42, sibling = 0}
        \\  const reference = Ref.from(pair.value)
        \\  const moved = pair.value^
        \\  _ = moved
        \\  return (reference).value
        \\exit(run())
    , .borrow_outlives_source);
}

test "replacing a sibling preserves a local field Ref" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  value: int
        \\  offset: int
        \\func run() int
        \\  var pair = Pair{value = 40, offset = 1}
        \\  const reference: Ref(int) = Ref.from(pair.value) else panic "unexpected none"
        \\  pair.offset = 2
        \\  return (reference).value
        \\exit(run())
    , 40);
}

test "a mut owner cannot overlap a Ref argument through another local" {
    try Fixture.expectSourceDiagnostic(
        \\func inspect(mut owner: Box(int), imm reference: Ref(int)) int -> (reference).value
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  return inspect(owner, reference)
        \\if const result: int = run() -> exit(result) else exit(1)
    , .overlapping_mutable_arguments);
}

test "a mut place cannot overlap an expression-only borrow argument" {
    try Fixture.expectSourceDiagnostic(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func inspect(mut owner: Immovable, imm snapshot: Immovable) int
        \\  owner.value = 17
        \\  return snapshot.value
        \\func run() int
        \\  var owner = Immovable{value = 42}
        \\  return inspect(owner, (Ref.from(owner)).value)
        \\exit(run())
    , .overlapping_mutable_arguments);
}

test "a mut place can coexist with an expression-only borrow of another local" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func inspect(mut owner: Immovable, imm snapshot: Immovable) int
        \\  owner.value = 17
        \\  return snapshot.value
        \\func run() int
        \\  var owner = Immovable{value = 17}
        \\  const other = Immovable{value = 42}
        \\  return inspect(owner, (Ref.from(other)).value)
        \\exit(run())
    , 42);
}

test "a mut owner and a Ref of a different owner can coexist" {
    try Fixture.expectSourceExit(
        \\func inspect(mut owner: Box(int), imm reference: Ref(int)) int -> (reference).value
        \\func run() int | none
        \\  var first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  return inspect(first, Ref.from(second.borrow()))
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an owned argument cannot consume the owner of a Ref argument" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{take}
        \\func inspect(imm reference: Ref(int), deinit owner: Box(int)) int
        \\  const removed = take(int, owner^)
        \\  return (reference).value
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  return inspect(reference, owner^)
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "an argument cannot consume a previously prepared Ref origin inside a nested call" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{take}
        \\func dispose(deinit owner: Box(int)) int -> take(int, owner^)
        \\func inspect(imm reference: Ref(int), imm removed: int) int -> (reference).value
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  return inspect(Ref.from(owner.borrow()), dispose(owner^))
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "an indexed scalar argument snapshots before a nested allocation transfer" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow}
        \\func dispose(deinit allocation: Allocation(int)) int
        \\  deallocate(int, allocation^)
        \\  return 0
        \\func inspect(imm item: int, imm ignored: int) int -> item
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 1) else return none
        \\  if (unsafe_initialize(int, allocation, 0, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  return inspect(unsafe_borrow(int, allocation, 0), dispose(allocation^))
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an indexed arithmetic operand snapshots before a nested allocation transfer" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow}
        \\func dispose(deinit allocation: Allocation(int)) int
        \\  deallocate(int, allocation^)
        \\  return 0
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 1) else return none
        \\  if (unsafe_initialize(int, allocation, 0, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  return unsafe_borrow(int, allocation, 0) + dispose(allocation^)
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an indexed comparison operand snapshots before a nested allocation transfer" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow}
        \\func dispose(deinit allocation: Allocation(int)) int
        \\  deallocate(int, allocation^)
        \\  return 42
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 1) else return none
        \\  if (unsafe_initialize(int, allocation, 0, 42) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  if unsafe_borrow(int, allocation, 0) == dispose(allocation^) -> return 42
        \\  return 0
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a callable field cannot outlive an argument transferring its owner" {
    try Fixture.expectSourceDiagnostic(
        \\struct Handler
        \\  callback: func(int) int
        \\func answer(value: int) int -> 42
        \\func dispose(deinit owner: Box(Handler)) int -> 0
        \\func run() int | none
        \\  const owner: Box(Handler) = Box.new(Handler{callback = answer}) else return none
        \\  return Ref.from(owner.borrow()).value.callback(dispose(owner^))
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "an indexed callable cannot outlive a nested allocation transfer" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow}
        \\static Callback: type = func(int) int
        \\func answer(value: int) int -> 42
        \\func dispose(deinit allocation: Allocation(Callback)) int
        \\  deallocate(Callback, allocation^)
        \\  return 0
        \\func run() int | none
        \\  var allocation: Allocation(Callback) = allocate(Callback, 1) else return none
        \\  if (unsafe_initialize(Callback, allocation, 0, answer) is unit) -> ()
        \\  else
        \\    deallocate(Callback, allocation^)
        \\    return none
        \\  return unsafe_borrow(Callback, allocation, 0)(dispose(allocation^))
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "an owned argument cannot consume an immutable argument" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{take}
        \\func inspect(imm owner: Box(int), deinit consumed: Box(int)) int
        \\  const removed = take(int, consumed^)
        \\  return (Ref.from(owner.borrow())).value
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  return inspect(owner, owner^)
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "an owned argument may consume a different owner than a Ref argument" {
    try Fixture.expectSourceExit(
        \\import std.memory.{take}
        \\func inspect(imm reference: Ref(int), deinit owner: Box(int)) int
        \\  const removed = take(int, owner^)
        \\  return (reference).value
        \\func run() int | none
        \\  const first: Box(int) = Box.new(42) else return none
        \\  const second: Box(int) = Box.new(17) else return none
        \\  return inspect(Ref.from(first.borrow()), second^)
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a transferred field can be reinitialized without hiding its sibling" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  const first = pair.first^
        \\  const second = pair.second
        \\  pair.first = 41
        \\  return first + second
        \\exit(run())
    , 42);
}

test "a nested sibling stays available after a field transfer" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\struct Outer
        \\  pair: Pair
        \\func run() int
        \\  var outer = Outer{pair = Pair{first = 40, second = 2}}
        \\  const first = outer.pair.first^
        \\  return first + outer.pair.second
        \\exit(run())
    , 42);
}

test "a transferred field cannot be read before reinitialization" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  const first = pair.first^
        \\  return pair.first
        \\exit(run())
    , .use_after_transfer);
}

test "a partially moved aggregate cannot be used as a whole" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  const first = pair.first^
        \\  const copied = pair
        \\  return copied.second
        \\exit(run())
    , .use_after_transfer);
}

test "a field moved on one branch is possibly unavailable after joining" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run(flag: int) int
        \\  var pair = Pair{first = 40, second = 2}
        \\  if flag == 1
        \\    const moved = pair.first^
        \\  return pair.first
        \\exit(run(1))
    , .possibly_transferred);
}

test "an unchanged sibling is available across partial branch and loop states" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  var first = 0
        \\  var step = 0
        \\  loop
        \\    if step == 0
        \\      first = pair.first^
        \\      pair.first = 41
        \\      step = 1
        \\      continue
        \\    break
        \\  return first + pair.second
        \\exit(run())
    , 42);
}

test "a transferred field must be restored before a loop backedge" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  loop
        \\    const moved = pair.first^
        \\    continue
        \\exit(run())
    , .transferred_value_not_restored_before_loop_backedge);
}

test "transferring an owned field moves its cleanup obligation" {
    try Fixture.expectSourceExit(
        \\struct Container
        \\  owner: Box(int)
        \\  offset: int
        \\func run() int | none
        \\  var box = Container{owner = (if const _selected_result_0: Box(int) = Box.new(40) -> _selected_result_0^ else return none), offset = 2}
        \\  const owner = box.owner^
        \\  return (Ref.from(owner.borrow())).value + box.offset
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "moving an owner field invalidates a Ref through that field" {
    try Fixture.expectSourceDiagnostic(
        \\struct Container
        \\  owner: Box(int)
        \\  offset: int
        \\func run() int | none
        \\  var box = Container{owner = (if const _selected_result_0: Box(int) = Box.new(40) -> _selected_result_0^ else return none), offset = 2}
        \\  const reference = Ref.from(box.owner.borrow())
        \\  const owner = box.owner^
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "reinitializing an owned field reinstates aggregate cleanup" {
    try Fixture.expectSourceExit(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Container
        \\  owner: Box(Resource)
        \\  offset: int
        \\func run() unit | none
        \\  var box = Container{owner = (if const _selected_result_0: Box(Resource) = Box.new(Resource{value = 42}) -> _selected_result_0^ else return none), offset = 1}
        \\  const owner = box.owner^
        \\  box.owner = owner^
        \\  _ = box.offset
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "an owned field moved on one branch cannot be dropped twice after joining" {
    try Fixture.expectSourceExit(
        \\struct Container
        \\  owner: Box(int)
        \\  offset: int
        \\func run(flag: int) int | none
        \\  var box = Container{owner = (if const _selected_result_0: Box(int) = Box.new(7) -> _selected_result_0^ else return none), offset = 42}
        \\  if flag == 1
        \\    const owner = box.owner^
        \\  return box.offset
        \\if const first: int = run(1) -> if const second: int = run(0) -> exit(first + second - 42) else exit(1) else exit(2)
    , 42);
}

test "replacing a parent with a moved trivial field still destroys its owned siblings" {
    try Fixture.expectSourceExit(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Inner
        \\  owner: Box(Resource)
        \\  count: int
        \\struct Outer
        \\  inner: Inner
        \\func run() unit | none
        \\  var outer = Outer{inner = Inner{owner = (if const _selected_result_0: Box(Resource) = Box.new(Resource{value = 42}) -> _selected_result_0^ else return none), count = 1}}
        \\  const old = outer.inner.count^
        \\  outer.inner = Inner{owner = (if const _selected_result_1: Box(Resource) = Box.new(Resource{value = 17}) -> _selected_result_1^ else return none), count = 2}
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "a drop hook can consume an allocation field" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}
        \\struct List
        \\  allocation: Allocation(int)
        \\  length: int
        \\  drop = func(deinit self: List)
        \\    unsafe_destroy(int, self.allocation, 0)
        \\    deallocate(int, self.allocation^)
        \\func run() int | none
        \\  var allocation: Allocation(int) = allocate(int, 1) else return none
        \\  if (unsafe_initialize(int, allocation, 0, 41) is unit) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    return none
        \\  const buffer = List{allocation = allocation^, length = 1}
        \\  return (Ref.from(unsafe_borrow(int, buffer.allocation, 0))).value + buffer.length
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "transferring one owned field still destroys its owned sibling" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  moved: Box(int)
        \\  remaining: Box(Tracked)
        \\func run() int | none
        \\  var pair = Pair{moved = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none), remaining = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_1^ else return none)}
        \\  const moved = pair.moved^
        \\  return (Ref.from(moved.borrow())).value
        \\if const result: int = run() -> exit(1) else exit(2)
    , 42);
}

test "restoring an owned field rejoins its sibling cleanup" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  restored: Box(Tracked)
        \\  sibling: Box(int)
        \\func run() Box(Tracked) | none
        \\  var pair = Pair{restored = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_0^ else return none), sibling = (if const _selected_result_1: Box(int) = Box.new(1) -> _selected_result_1^ else return none)}
        \\  const old = pair.restored^
        \\  pair.restored = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_2^ else return none)
        \\  return old^
        \\if const result: Box(Tracked) = run() -> exit(1) else exit(2)
    , 42);
}

test "two moved fields can be restored one at a time" {
    try Fixture.expectSourceExit(
        \\struct Trio
        \\  first: Box(int)
        \\  second: Box(int)
        \\  stable: Box(int)
        \\func run() int | none
        \\  var trio = Trio{first = (if const _selected_result_0: Box(int) = Box.new(7) -> _selected_result_0^ else return none), second = (if const _selected_result_1: Box(int) = Box.new(20) -> _selected_result_1^ else return none), stable = (if const _selected_result_2: Box(int) = Box.new(6) -> _selected_result_2^ else return none)}
        \\  const first = trio.first^
        \\  const second = trio.second^
        \\  trio.first = (if const _selected_result_3: Box(int) = Box.new(4) -> _selected_result_3^ else return none)
        \\  trio.second = (if const _selected_result_4: Box(int) = Box.new(5) -> _selected_result_4^ else return none)
        \\  return (Ref.from(trio.first.borrow())).value + (Ref.from(trio.second.borrow())).value + (Ref.from(trio.stable.borrow())).value + (Ref.from(first.borrow())).value + (Ref.from(second.borrow())).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "restoring an ownerless aggregate recovers its partial cleanup" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  first: Box(int)
        \\  second: Box(int)
        \\func run() int | none
        \\  var pair = Pair{first = (if const _selected_result_0: Box(int) = Box.new(7) -> _selected_result_0^ else return none), second = (if const _selected_result_1: Box(int) = Box.new(20) -> _selected_result_1^ else return none)}
        \\  const first = pair.first^
        \\  const second = pair.second^
        \\  pair.first = (if const _selected_result_2: Box(int) = Box.new(4) -> _selected_result_2^ else return none)
        \\  pair.second = (if const _selected_result_3: Box(int) = Box.new(11) -> _selected_result_3^ else return none)
        \\  return (Ref.from(pair.first.borrow())).value + (Ref.from(pair.second.borrow())).value + (Ref.from(first.borrow())).value + (Ref.from(second.borrow())).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "nested missing owners are restored separately" {
    try Fixture.expectSourceExit(
        \\struct Inner
        \\  first: Box(int)
        \\  second: Box(int)
        \\struct Outer
        \\  inner: Inner
        \\  marker: int
        \\func run() int | none
        \\  var outer = Outer{inner = Inner{first = (if const _selected_result_0: Box(int) = Box.new(7) -> _selected_result_0^ else return none), second = (if const _selected_result_1: Box(int) = Box.new(20) -> _selected_result_1^ else return none)}, marker = 2}
        \\  const first = outer.inner.first^
        \\  const second = outer.inner.second^
        \\  outer.inner.first = (if const _selected_result_2: Box(int) = Box.new(4) -> _selected_result_2^ else return none)
        \\  outer.inner.second = (if const _selected_result_3: Box(int) = Box.new(9) -> _selected_result_3^ else return none)
        \\  return (Ref.from(outer.inner.first.borrow())).value + (Ref.from(outer.inner.second.borrow())).value + (Ref.from(first.borrow())).value + (Ref.from(second.borrow())).value + outer.marker
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "restored owners are destroyed in reverse field order" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 50 -> exit(50)
        \\    if self.value == 60 -> exit(60)
        \\struct Pair
        \\  first: Box(Tracked)
        \\  second: Box(Tracked)
        \\func run() Box(Tracked) | none
        \\  var pair = Pair{first = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_0^ else return none), second = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_1^ else return none)}
        \\  const first = pair.first^
        \\  const second = pair.second^
        \\  pair.first = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 50}) -> _selected_result_2^ else return none)
        \\  pair.second = (if const _selected_result_3: Box(Tracked) = Box.new(Tracked{value = 60}) -> _selected_result_3^ else return none)
        \\  _ = first
        \\  return second^
        \\if const owner: Box(Tracked) = run() -> exit(1) else exit(2)
    , 60);
}

test "consecutive owned field transfers leave no aggregate cleanup" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  first: Box(Tracked)
        \\  second: Box(Tracked)
        \\func run() Box(Tracked) | none
        \\  var pair = Pair{first = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_0^ else return none), second = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_1^ else return none)}
        \\  const first = pair.first^
        \\  const second = pair.second^
        \\  _ = (Ref.from(second.borrow())).value.value
        \\  return first^
        \\if const owner: Box(Tracked) = run() -> exit(1) else exit(2)
    , 42);
}

test "replacing a partly moved parent destroys its remaining owned children" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 42 -> exit(42)
        \\struct Inner
        \\  moved: Box(int)
        \\  remaining: Box(Tracked)
        \\struct Outer
        \\  inner: Inner
        \\  flag: int
        \\func run() int | none
        \\  var outer = Outer{inner = Inner{moved = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none), remaining = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_1^ else return none)}, flag = 1}
        \\  const moved = outer.inner.moved^
        \\  outer.inner = Inner{moved = (if const _selected_result_2: Box(int) = Box.new(19) -> _selected_result_2^ else return none), remaining = (if const _selected_result_3: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_3^ else return none)}
        \\  return (Ref.from(moved.borrow())).value
        \\if const result: int = run() -> exit(1) else exit(2)
    , 42);
}

test "a nested owned field transfer skips only its field during cleanup" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Inner
        \\  stable: Box(Tracked)
        \\  moved: Box(Tracked)
        \\struct Outer
        \\  inner: Inner
        \\  other: Box(Tracked)
        \\func run() Box(Tracked) | none
        \\  var outer = Outer{inner = Inner{stable = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none)}, other = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_2^ else return none)}
        \\  const moved = outer.inner.moved^
        \\  _ = outer.inner.stable
        \\  return moved^
        \\if const owner: Box(Tracked) = run() -> exit(2) else exit(3)
    , 42);
}

test "a conditional owned field transfer never drops the moved branch twice" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\func run(flag: int) Box(Tracked) | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none), marker = 1}
        \\  var chosen: Box(Tracked) = Box.new(Tracked{value = 1}) else return none
        \\  if flag == 1 -> chosen = pair.moved^
        \\  _ = pair.marker
        \\  return chosen^
        \\if const owner: Box(Tracked) = run(1) -> exit(1) else exit(2)
    , 42);
}

test "a conditional owned field transfer ends the other branch before joining" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\func run(flag: int) Box(Tracked) | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none), marker = 1}
        \\  var chosen: Box(Tracked) = Box.new(Tracked{value = 1}) else return none
        \\  if flag == 1 -> chosen = pair.moved^
        \\  _ = pair.marker
        \\  return chosen^
        \\if const owner: Box(Tracked) = run(0) -> exit(1) else exit(2)
    , 17);
}

test "an owned sibling can be borrowed after a partial transfer join" {
    try Fixture.expectSourceExit(
        \\struct Pair
        \\  stable: Box(int)
        \\  movable: Box(int)
        \\func run(flag: int) int | none
        \\  var pair = Pair{stable = (if const _selected_result_0: Box(int) = Box.new(41) -> _selected_result_0^ else return none), movable = (if const _selected_result_1: Box(int) = Box.new(1) -> _selected_result_1^ else return none)}
        \\  var chosen: Box(int) = Box.new(0) else return none
        \\  if flag == 1 -> chosen = pair.movable^
        \\  return (Ref.from(pair.stable.borrow())).value + (Ref.from(chosen.borrow())).value
        \\if const result: int = run(1) -> exit(result) else exit(2)
    , 42);
}

test "a short-circuit condition joins partial ownership without double cleanup" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(int)
        \\  marker: int
        \\func fail_after_consuming(var owner: Box(int)) unit | none
        \\  if not (0 == 1) -> return none
        \\  return ()
        \\func run(flag: int) int | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(int) = Box.new(17) -> _selected_result_1^ else return none), marker = 1}
        \\  if flag == 1 and (fail_after_consuming(pair.moved^) is unit) -> exit(1)
        \\  _ = pair.marker
        \\  return 1
        \\if const result: int = run(1) -> exit(2) else exit(3)
    , 42);
}

test "loop exits join owned field transfers before later sibling use" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  movable: Box(Tracked)
        \\  marker: int
        \\func run(flag: int) Box(Tracked) | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), movable = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none), marker = 1}
        \\  var selected: Box(Tracked) = Box.new(Tracked{value = 0}) else return none
        \\  loop
        \\    if flag == 1
        \\      selected = pair.movable^
        \\      break
        \\    break
        \\  _ = pair.marker
        \\  return selected^
        \\if const owner: Box(Tracked) = run(1) -> exit(2) else exit(3)
    , 42);
}

test "three loop exits normalize distinct owned field transfers" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Group
        \\  sibling: Box(Tracked)
        \\  second: Box(Tracked)
        \\  first: Box(Tracked)
        \\  marker: int
        \\func run(flag: int) Box(Tracked) | none
        \\  var group = Group{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), second = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_1^ else return none), first = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_2^ else return none), marker = 1}
        \\  var selected: Box(Tracked) = Box.new(Tracked{value = 0}) else return none
        \\  loop
        \\    if flag == 1
        \\      selected = group.first^
        \\      break
        \\    if flag == 2
        \\      selected = group.second^
        \\      break
        \\    break
        \\  _ = group.marker
        \\  return selected^
        \\if const owner: Box(Tracked) = run(1) -> exit(2) else exit(3)
    , 42);
}

test "loop backedges preserve missing owned fields after replacing a sibling" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\func run() Box(Tracked) | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none), marker = 1}
        \\  const moved = pair.moved^
        \\  var pass = 0
        \\  loop
        \\    if pass == 1 -> break
        \\    pair.sibling = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_2^ else return none)
        \\    pass = 1
        \\    continue
        \\  _ = pair.marker
        \\  return moved^
        \\if const owner: Box(Tracked) = run() -> exit(2) else exit(3)
    , 42);
}

test "a restoring backedge cannot revive a field moved before the loop" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\func run(flag: int) Box(Tracked) | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none), marker = 1}
        \\  const moved = pair.moved^
        \\  loop
        \\    if flag == 1 -> break
        \\    pair.moved = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_2^ else return none)
        \\    continue
        \\  _ = pair.marker
        \\  return moved^
        \\if const owner: Box(Tracked) = run(1) -> exit(2) else exit(3)
    , 42);
}

test "a restored field is ended before the next loop iteration" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\func run() unit | none
        \\  var pair = Pair{sibling = (if const _selected_result_0: Box(Tracked) = Box.new(Tracked{value = 42}) -> _selected_result_0^ else return none), moved = (if const _selected_result_1: Box(Tracked) = Box.new(Tracked{value = 17}) -> _selected_result_1^ else return none)}
        \\  const moved = pair.moved^
        \\  var pass = 0
        \\  loop
        \\    if pass == 1 -> exit((Ref.from(moved.borrow())).value.value + 74)
        \\    pair.moved = (if const _selected_result_2: Box(Tracked) = Box.new(Tracked{value = 31}) -> _selected_result_2^ else return none)
        \\    pass = 1
        \\    continue
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 31);
}

test "three loop exits can join distinct owned results" {
    try Fixture.expectSourceExit(
        \\func run(flag: int) Box(int) | none
        \\  var first: Box(int) = Box.new(40) else return none
        \\  var second: Box(int) = Box.new(42) else return none
        \\  var third: Box(int) = Box.new(44) else return none
        \\  return loop
        \\    if flag == 1 -> break first^
        \\    if flag == 2 -> break second^
        \\    break third^
        \\if const owner: Box(int) = run(2) -> exit((Ref.from(owner.borrow())).value) else exit(1)
    , 42);
}

test "a mut parameter can replace its owned field before returning" {
    try Fixture.expectSourceExit(
        \\struct Container
        \\  owner: Box(int)
        \\  count: int
        \\func replace(mut box: Container, var replacement: Box(int))
        \\  const old = box.owner^
        \\  box.owner = replacement^
        \\func run() int | none
        \\  var box = Container{owner = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none), count = 2}
        \\  replace(box, (if const _selected_result_1: Box(int) = Box.new(40) -> _selected_result_1^ else return none))
        \\  return (Ref.from(box.owner.borrow())).value + box.count
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a mut parameter cannot leave an owned field uninitialized" {
    try Fixture.expectSourceDiagnostic(
        \\struct Container
        \\  owner: Box(int)
        \\  count: int
        \\func remove(mut box: Container)
        \\  const old = box.owner^
        \\func run() unit | none
        \\  var box = Container{owner = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none), count = 2}
        \\  remove(box)
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .field_not_restored_before_mut_return);
}

test "successive explicit-drop field transfers discharge the whole aggregate" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Pair
        \\  first: Box(int)
        \\  second: Allocation(int)
        \\func run() unit | none
        \\  const first: Box(int) = Box.new(1) else return none
        \\  const second: Allocation(int) = allocate(int, 1) else return none
        \\  var pair = Pair{first = first^, second = second^}
        \\  const moved = pair.first^
        \\  const allocation = pair.second^
        \\  deallocate(int, allocation^)
        \\  _ = moved
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "an untransferred explicit-drop sibling still requires disposal" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate}
        \\struct Pair
        \\  first: Box(int)
        \\  second: Allocation(int)
        \\func run() unit | none
        \\  const first: Box(int) = Box.new(1) else return none
        \\  const second: Allocation(int) = allocate(int, 1) else return none
        \\  var pair = Pair{first = first^, second = second^}
        \\  const moved = pair.first^
        \\  _ = moved
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .value_requires_explicit_drop);
}

test "removing an explicit-drop field leaves automatic sibling cleanup" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  storage: Allocation(int)
        \\func run() unit | none
        \\  const sibling: Box(Tracked) = Box.new(Tracked{value = 42}) else return none
        \\  const storage: Allocation(int) = allocate(int, 1) else return none
        \\  var pair = Pair{sibling = sibling^, storage = storage^}
        \\  const removed = pair.storage^
        \\  deallocate(int, removed^)
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "an explicit-drop field cannot be implicitly ended at a branch join" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Pair
        \\  sibling: Box(int)
        \\  storage: Allocation(int)
        \\func run(flag: int) int | none
        \\  const sibling: Box(int) = Box.new(42) else return none
        \\  const storage: Allocation(int) = allocate(int, 1) else return none
        \\  var pair = Pair{sibling = sibling^, storage = storage^}
        \\  if flag == 1
        \\    const removed = pair.storage^
        \\    deallocate(int, removed^)
        \\  return 42
        \\if const result: int = run(1) -> exit(result) else exit(1)
    , .explicit_drop_field_cannot_be_implicitly_ended);
}

test "explicit-drop field disposal on both branches keeps automatic sibling cleanup" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  storage: Allocation(int)
        \\func run(flag: int) unit | none
        \\  const sibling: Box(Tracked) = Box.new(Tracked{value = 42}) else return none
        \\  const storage: Allocation(int) = allocate(int, 1) else return none
        \\  var pair = Pair{sibling = sibling^, storage = storage^}
        \\  if flag == 1
        \\    const removed = pair.storage^
        \\    deallocate(int, removed^)
        \\  else
        \\    const removed = pair.storage^
        \\    deallocate(int, removed^)
        \\  return ()
        \\if (run(1) is unit) -> exit(1) else exit(2)
    , 42);
}

test "nested explicit-drop fields leave no owner after successive transfers" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Inner
        \\  first: Box(int)
        \\  second: Allocation(int)
        \\struct Outer
        \\  inner: Inner
        \\  marker: int
        \\func run() int | none
        \\  const first: Box(int) = Box.new(1) else return none
        \\  const second: Allocation(int) = allocate(int, 1) else return none
        \\  var outer = Outer{inner = Inner{first = first^, second = second^}, marker = 42}
        \\  const moved = outer.inner.first^
        \\  const allocation = outer.inner.second^
        \\  deallocate(int, allocation^)
        \\  _ = moved
        \\  return outer.marker
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "list tracks initialized length separately from allocation capacity" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  const empty: List(int) = List(int).new(0) else return none
        \\  const reserved: List(int) = List(int).new(3) else return none
        \\  return 39 + empty.len() + empty.capacity() + reserved.len() + reserved.capacity()
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "list creates empty reference-containing storage" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  const buffer: List(Ref(int)) = List(Ref(int)).new(1) else return none
        \\  return buffer.len()
        \\if const length: int = run() -> exit(length + 42) else exit(1)
    , 42);
}

test "list initialization metadata is opaque outside std.memory" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List}
        \\func run() unit | none
        \\  var buffer: List(int) = List(int).new(0) else return none
        \\  buffer.initialized = 1
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .private_struct_field);
}

test "list appends into free slots and grows from zero" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var empty: List(int) = List(int).new(0) else return none
        \\  const _: unit = empty.append(20) else return none
        \\  const _: unit = empty.append(22) else return none
        \\  var reserved: List(int) = List(int).new(2) else return none
        \\  const _: unit = reserved.append(42) else return none
        \\  return empty.len() + empty.capacity() + reserved.len() + reserved.capacity() + 35
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "list growth moves elements and drops the initialized prefix in reverse" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\func run() unit | none
        \\  var buffer: List(Tracked) = List(Tracked).new(1) else return none
        \\  const _: unit = buffer.append(Tracked{value = 17}) else return none
        \\  const _: unit = buffer.append(Tracked{value = 42}) else return none
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "list get checks bounds and borrows an initialized element" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(1) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  const element: Ref(int) = Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))
        \\  const observed = (element).value
        \\  if (buffer.get(-1) is int) -> exit(1)
        \\  if (buffer.get(1) is int) -> exit(2)
        \\  return observed
        \\if const result: int = run() -> exit(result) else exit(3)
    , 42);
}

test "list get checks bounds and replaces a writable initialized element" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(0) else return none
        \\  if (buffer.get(0) is int) -> return 1
        \\  const _: unit = buffer.append(17) else return none
        \\  if (buffer.get(-1) is int) -> return 2
        \\  if (buffer.get(1) is int) -> return 3
        \\  var writable: Ref(int) = Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))
        \\  writable.value = 42
        \\  return Ref.from((if ref _selected_result_1: int = buffer.get(0) -> _selected_result_1 else return none)).value
        \\if const result: int = run() -> exit(result) else exit(4)
    , 42);
}

test "list element replacement preserves earlier slot and view borrows" {
    const sources = .{
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  const previous = Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))
        \\  var writable = Ref.from((if ref _selected_result_1: int = buffer.get(0) -> _selected_result_1 else return none))
        \\  writable.value = 42
        \\  return previous.value
        \\if const result: int = run() -> exit(result) else exit(1)
        ,
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  const view: Span(int) = buffer.slice(0..1) else return none
        \\  var writable = Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))
        \\  writable.value = 42
        \\  return Ref.from((if ref _selected_result_1: int = view.get(0) -> _selected_result_1 else return none)).value
        \\if const result: int = run() -> exit(result) else exit(1)
    };
    inline for (sources) |source| {
        try Fixture.expectSourceExit(source, 42);
    }
}

test "list append invalidates a writable element Ref without growth" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  var writable = Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))
        \\  const _: unit = buffer.append(7) else return none
        \\  writable.value = 42
        \\  return Ref.from((if ref _selected_result_1: int = buffer.get(0) -> _selected_result_1 else return none)).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "writing through list get needs a mutable list place" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List}
        \\func run() int | none
        \\  const buffer: List(int) = List(int).new(1) else return none
        \\  Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none)).value = 42
        \\  return 0
        \\if const result: int = run() -> exit(result) else exit(1)
    , .reference_not_writable);
}

test "an explicit reference writes through checked List element access" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(1) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  var item = Ref.from(Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none)).value)
        \\  item.value = 42
        \\  return Ref.from((if ref _selected_result_1: int = buffer.get(0) -> _selected_result_1 else return none)).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an empty immovable List has no writable initialized element" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\func run() int | none
        \\  var buffer: List(Pinned) = List(Pinned).new(0) else return none
        \\  if (buffer.get(0) is Pinned) -> return 1
        \\  return buffer.len() + 42
        \\if const result: int = run() -> exit(result) else exit(2)
    , 42);
}

test "appending without growth invalidates an earlier list element Ref" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  const element = Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))
        \\  const _: unit = buffer.append(42) else return none
        \\  return (element).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "list reserve preserves initialized elements on allocation failure" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(1) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  if (buffer.reserve(-1) is unit) -> exit(1)
        \\  if (buffer.reserve(2147483647) is unit) -> exit(2)
        \\  const _: unit = buffer.reserve(3) else return none
        \\  return (Ref.from((if ref _selected_result_0: int = buffer.get(0) -> _selected_result_0 else return none))).value - buffer.len() - buffer.capacity() + 4
        \\if const result: int = run() -> exit(result) else exit(3)
    , 42);
}

test "list append rejects explicitly dropped elements" {
    const fixture = try Fixture.initFiles(
        \\import std.memory.{List}
        \\struct Explicit
        \\  value: int
        \\  drop = explicit
        \\func run() unit | none
        \\  var buffer: List(Explicit) = List(Explicit).new(1) else return none
        \\  const _: unit = buffer.append(Explicit{value = 42}) else return none
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.list_requires_automatic_drop);
}

test "list append rejects elements with custom move" {
    const fixture = try Fixture.initFiles(
        \\import std.memory.{List}
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> CustomMove{value = self.value}
        \\func run() unit | none
        \\  var buffer: List(CustomMove) = List(CustomMove).new(1) else return none
        \\  const _: unit = buffer.append(CustomMove{value = 42}) else return none
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.list_requires_direct_move);
}

test "list reserve rejects elements with custom move" {
    const source =
        \\import std.memory.{List}
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> CustomMove{value = self.value}
        \\func run() unit | none
        \\  var buffer: List(CustomMove) = List(CustomMove).new(0) else return none
        \\  const _: unit = buffer.reserve(1) else return none
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    ;
    const fixture = try Fixture.initFiles(source, &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.list_requires_direct_move);
}

test "a list view borrows a checked subrange" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  const view: Span(int) = buffer.slice(1..2) else return none
        \\  if (view.get(1) is int) -> exit(1)
        \\  if (buffer.slice(-1..0) is Span(int)) -> exit(2)
        \\  if (buffer.slice(1..3) is Span(int)) -> exit(3)
        \\  return (Ref.from((if ref _selected_result_0: int = view.get(0) -> _selected_result_0 else return none))).value + view.len() - 1
        \\if const result: int = run() -> exit(result) else exit(4)
    , 42);
}

test "list view range metadata is opaque outside std.memory" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List}
        \\func run() unit | none
        \\  var buffer: List(int) = List(int).new(0) else return none
        \\  var view: Span(int) = buffer.slice(0..0) else return none
        \\  view.size = 1
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .private_struct_field);
}

test "list view construction retains its range length" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(1) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  const view: Span(int) = buffer.slice(0..1) else return none
        \\  return 41 + view.len()
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "list view reads an initialized element" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(1) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  const view: Span(int) = buffer.slice(0..1) else return none
        \\  return (Ref.from((if ref _selected_result_0: int = view.get(0) -> _selected_result_0 else return none))).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a list view returned through an immutable parameter keeps its backing owner" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List, Span}
        \\func tail(imm buffer: List(int)) Span(int) | none
        \\  return (if const _selected_result_0: Span(int) = buffer.slice(1..) -> _selected_result_0 else return none)
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  const view: Span(int) = tail(buffer) else return none
        \\  return (Ref.from((if ref _selected_result_1: int = view.get(0) -> _selected_result_1 else return none))).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a byte list view can be returned and stored without copying its backing data" {
    try Fixture.expectSourceExit(
        \\import std.memory.{List, Span}
        \\struct ByteSlice
        \\  view: Span(byte)
        \\func slice(imm buffer: List(byte)) ByteSlice | none
        \\  return ByteSlice{view = (if const _selected_result_0: Span(byte) = buffer.slice(1..2) -> _selected_result_0^ else return none)}
        \\func run() int | none
        \\  var bytes: List(byte) = List(byte).new(2) else return none
        \\  const _: unit = bytes.append(17) else return none
        \\  const _: unit = bytes.append(42) else return none
        \\  const stored: ByteSlice = slice(bytes) else return none
        \\  const element: byte = (Ref.from(stored.view[0])).value
        \\  _ = element
        \\  return stored.view.len() + bytes.len() + 39
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a stored byte list view is invalid after backing storage changes" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List, Span}
        \\struct ByteSlice
        \\  view: Span(byte)
        \\func slice(imm buffer: List(byte)) ByteSlice | none
        \\  return ByteSlice{view = (if const _selected_result_0: Span(byte) = buffer.slice(0..1) -> _selected_result_0^ else return none)}
        \\func run() unit | none
        \\  var bytes: List(byte) = List(byte).new(1) else return none
        \\  const _: unit = bytes.append(42) else return none
        \\  const stored: ByteSlice = slice(bytes) else return none
        \\  const _: unit = bytes.append(17) else return none
        \\  const element: byte = (Ref.from(stored.view[0])).value
        \\  _ = element
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .borrow_outlives_source);
}

test "a byte buffer view cannot escape its local backing list" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List, Span}
        \\func escape() Span(byte) | none
        \\  var bytes: List(byte) = List(byte).new(1) else return none
        \\  const _: unit = bytes.append(42) else return none
        \\  return (if const _selected_result_0: Span(byte) = bytes.slice(0..1) -> _selected_result_0 else return none)
        \\if const view: Span(byte) = escape() -> exit(view.len()) else exit(1)
    , .borrow_outlives_source);
}

test "mutating a list invalidates a previously borrowed view" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{List}
        \\func run() int | none
        \\  var buffer: List(int) = List(int).new(2) else return none
        \\  const _: unit = buffer.append(17) else return none
        \\  const view: Span(int) = buffer.slice(0..1) else return none
        \\  const _: unit = buffer.append(42) else return none
        \\  return (Ref.from((if ref _selected_result_0: int = view.get(0) -> _selected_result_0 else return none))).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a named unit call result can be borrowed" {
    try Fixture.expectSourceExit(
        \\func produce() unit
        \\  const ignored = 1
        \\func run() int
        \\  const result = produce()
        \\  const reference: Ref(unit) = Ref.from(result) else panic "unexpected none"
        \\  _ = (reference).value
        \\  return 42
        \\exit(run())
    , 42);
}

test "a named unit branch result can be borrowed" {
    try Fixture.expectSourceExit(
        \\func produce() unit
        \\  const ignored = 1
        \\func run() int
        \\  const result = if 1 == 1 -> produce() else produce()
        \\  const reference: Ref(unit) = Ref.from(result) else panic "unexpected none"
        \\  _ = (reference).value
        \\  return 42
        \\exit(run())
    , 42);
}

test "a unit parameter can be borrowed during its call" {
    try Fixture.expectSourceExit(
        \\func produce() unit
        \\  const ignored = 1
        \\func inspect(imm item: unit) int
        \\  _ = (Ref.from(item)).value
        \\  return 42
        \\exit(inspect(produce()))
    , 42);
}

test "a direct-passed immutable parameter can be borrowed during its call" {
    try Fixture.expectSourceExit(
        \\func inspect(imm item: int) int -> (Ref.from(item)).value
        \\exit(inspect(42))
    , 42);
}

test "a Ref of a direct-passed parameter cannot escape its call" {
    try Fixture.expectSourceDiagnostic(
        \\func escape(imm item: int) Ref(int) -> Ref.from(item)
        \\const item = 42
        \\const reference = escape(item)
        \\exit(42)
    , .borrow_outlives_source);
}

test "a function can return a Ref derived from an immutable owner" {
    try Fixture.expectSourceExit(
        \\func view(imm owner: Box(int)) Ref(int) -> return Ref.from(owner.borrow())
        \\func forward(imm reference: Ref(int)) Ref(int) -> return reference
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference = forward(view(owner))
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "copied writable Ref handles update stable Box storage" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var writable: Ref(int) = Ref.from(owner.borrow())
        \\  var copied = writable
        \\  const shared: Ref(int) = Ref.from(owner.borrow())
        \\  copied.value = 42
        \\  return (shared).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a writable Ref can be returned through its runtime handle input" {
    try Fixture.expectSourceExit(
        \\func forward(var reference: Ref(int)) Ref(int) -> reference
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference = forward(Ref.from(owner.borrow()))
        \\  reference.value = 42
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a writable Ref returned from a mut Box follows its copied-back owner" {
    try Fixture.expectSourceExit(
        \\func view(mut owner: Box(int)) Ref(int) -> Ref.from(owner.borrow())
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference = view(owner)
        \\  reference.value = 42
        \\  return (Ref.from(owner.borrow())).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a func returned writable Ref follows the replacement mut owner" {
    try Fixture.expectSourceExit(
        \\func view(mut owner: Box(int)) Ref(int) | none
        \\  owner = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return Ref.from(owner.borrow())
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  const reference: Ref(int) = view(owner) else return none
        \\  return (reference).value + (Ref.from(owner.borrow())).value - 42
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a replaced mut Box is copied back after a later failure" {
    try Fixture.expectSourceExit(
        \\func fail_after_replace(mut owner: Box(int)) unit | none
        \\  owner = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  if not (0 > 1) -> return none
        \\  return ()
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  if (fail_after_replace(owner) is unit) -> return 1
        \\  return (Ref.from(owner.borrow())).value
        \\if const result: int = run() -> exit(result) else exit(2)
    , 42);
}

test "replacing a mut Box twice drops each outgoing owner once" {
    try Fixture.expectParity(
        \\struct Item
        \\    trace: Ref(int)
        \\    value: int
        \\    drop = func(deinit self: Item) -> self.trace.value += self.value
        \\func replace_twice(mut owner: Box(Item), ref trace: int) unit | none
        \\    owner = (if const replacement: Box(Item) = Box.new(Item{trace = Ref.from(trace), value = 23}) -> replacement^ else return none)
        \\    owner = (if const replacement: Box(Item) = Box.new(Item{trace = Ref.from(trace), value = 42}) -> replacement^ else return none)
        \\    return ()
        \\func replace() int | none
        \\    var trace = 0
        \\    var owner: Box(Item) = Box.new(Item{trace = Ref.from(trace), value = 17}) else return none
        \\    const _: unit = replace_twice(owner, trace) else return none
        \\    if trace <> 40 -> return 90
        \\    _ = owner
        \\    if trace <> 82 -> return 91
        \\    return 42
        \\func run() int
        \\    const result: int = replace() else return 92
        \\    return result
    , 42);
}

test "a read-only Ref cannot be used to write" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  reference.value = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
}

test "an immutable Box owner cannot create a writable Ref" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  Ref.from(owner.borrow()).value = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
}

test "an immutable Box borrowed place remains read-only" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  ref item = owner.borrow()
        \\  item = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .reference_not_writable);
}

test "transferring a Box owner invalidates its writable Ref" {
    try Fixture.expectSourceDiagnostic(
        \\func run() unit | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference = Ref.from(owner.borrow())
        \\  const moved = owner^
        \\  _ = moved
        \\  reference.value = 42
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .use_after_transfer);
}

test "a mut owner argument cannot overlap a writable Ref argument" {
    try Fixture.expectSourceDiagnostic(
        \\func conflict(mut owner: Box(int), var reference: Ref(int)) -> return
        \\func run() unit | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  var reference = Ref.from(owner.borrow())
        \\  conflict(owner, reference)
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .overlapping_mutable_arguments);
}

test "writing a custom-drop pointee destroys the previous value" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\func run() unit | none
        \\  var owner: Box(Tracked) = Box.new(Tracked{value = 42}) else return none
        \\  Ref.from(owner.borrow()).value = Tracked{value = 17}
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "a direct returned Ref depends only on its inferred runtime inputs" {
    const source =
        \\func select(imm first: Ref(int), imm second: Ref(int)) Ref(int) -> first
        \\func run() int
        \\  var first: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
        \\  var second: Box(int) = Box.new(17) else panic "unexpected allocation refusal"
        \\  const selected = select(Ref.from(first.borrow()), Ref.from(second.borrow()))
        \\  $invalidate
        \\  return (selected).value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    for ([_]struct { invalidate: []const u8, diagnostic: ?std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .invalidate = "const moved = first^\n  _ = moved", .diagnostic = .use_after_transfer },
        .{ .invalidate = "const moved = second^\n  _ = moved", .diagnostic = null },
        .{ .invalidate = "first = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = .borrow_outlives_source },
        .{ .invalidate = "second = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = null },
    }) |case| {
        const entry = try test_sources.renderTemplate(testing.allocator, source, .{ .invalidate = case.invalidate });
        defer testing.allocator.free(entry);
        if (case.diagnostic) |diagnostic|
            try Fixture.expectSourceDiagnostic(entry, diagnostic)
        else
            try Fixture.expectSourceExit(entry, 42);
    }
}

test "an indirect returned Ref conservatively depends on every runtime input" {
    const source =
        \\func select(imm first: Ref(int), imm second: Ref(int)) Ref(int) -> first
        \\func run() int
        \\  var first: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
        \\  var second: Box(int) = Box.new(17) else panic "unexpected allocation refusal"
        \\  var function = select
        \\  const selected = function(Ref.from(first.borrow()), Ref.from(second.borrow()))
        \\  $invalidate
        \\  return (selected).value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    for ([_]struct { invalidate: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .invalidate = "const moved = first^\n  _ = moved", .diagnostic = .use_after_transfer },
        .{ .invalidate = "const moved = second^\n  _ = moved", .diagnostic = .use_after_transfer },
        .{ .invalidate = "first = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = .borrow_outlives_source },
        .{ .invalidate = "second = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = .borrow_outlives_source },
    }) |case| {
        const entry = try test_sources.renderTemplate(testing.allocator, source, .{ .invalidate = case.invalidate });
        defer testing.allocator.free(entry);
        try Fixture.expectSourceDiagnostic(entry, case.diagnostic);
    }
}

test "a returned Ref distinguishes its origins from mut Ref writeback inputs" {
    const source =
        \\func select(imm first: Ref(int), mut output: Ref(int), imm second: Ref(int)) Ref(int)
        \\  output = second
        \\  return first
        \\func run() int
        \\  var first: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
        \\  var second: Box(int) = Box.new(17) else panic "unexpected allocation refusal"
        \\  var other: Box(int) = Box.new(1) else panic "unexpected allocation refusal"
        \\  var output = Ref.from(other.borrow())
        \\  const selected = select(Ref.from(first.borrow()), output, Ref.from(second.borrow()))
        \\  $invalidate
        \\  return (selected).value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    for ([_]struct { invalidate: []const u8, diagnostic: ?std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .invalidate = "_ = (output).value", .diagnostic = null },
        .{ .invalidate = "const moved = first^\n  _ = moved", .diagnostic = .use_after_transfer },
        .{ .invalidate = "const moved = second^\n  _ = moved", .diagnostic = null },
        .{ .invalidate = "const moved = other^\n  _ = moved", .diagnostic = null },
        .{ .invalidate = "const moved = second^\n  _ = output.value", .diagnostic = .use_after_transfer },
        .{ .invalidate = "first = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = .borrow_outlives_source },
        .{ .invalidate = "second = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = null },
        .{ .invalidate = "other = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = null },
        .{ .invalidate = "second = (if const replacement: Box(int) = Box.new(23) -> replacement^ else panic \"allocation refused\")\n  _ = output.value", .diagnostic = .borrow_outlives_source },
    }) |case| {
        const entry = try test_sources.renderTemplate(testing.allocator, source, .{ .invalidate = case.invalidate });
        defer testing.allocator.free(entry);
        const fixture = try Fixture.initFiles(entry, &.{});
        defer fixture.deinit();
        if (case.diagnostic) |diagnostic| {
            try fixture.expectDiagnostic(0, diagnostic);
        } else {
            try fixture.expectExit(0, 42);
        }
    }
}

test "returned Ref origins distinguish inferred contracts from indirect calls" {
    const source =
        \\func select(imm first: Ref(int), mut output: Ref(int)) Ref(int) -> first
        \\func run() int
        \\  const first: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
        \\  var other: Box(int) = Box.new(17) else panic "unexpected allocation refusal"
        \\  var output = Ref.from(other.borrow())
        \\  var function = select
        \\  const selected = $callee(Ref.from(first.borrow()), output)
        \\  $invalidate
        \\  return selected.value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    for ([_][]const u8{ "select", "function" }) |callee| {
        for ([_]struct { invalidate: []const u8, diagnostic: ?std.meta.Tag(structures.Diagnostic.Kind) }{
            .{ .invalidate = "_ = output.value", .diagnostic = null },
            .{ .invalidate = "const moved = other^\n  _ = moved", .diagnostic = .use_after_transfer },
            .{ .invalidate = "other = (if const _selected_result_0: Box(int) = Box.new(23) -> _selected_result_0^ else panic \"unexpected none\")", .diagnostic = .borrow_outlives_source },
        }) |case| {
            const entry = try test_sources.renderTemplate(testing.allocator, source, .{ .callee = callee, .invalidate = case.invalidate });
            defer testing.allocator.free(entry);
            const fixture = try Fixture.initFiles(entry, &.{});
            defer fixture.deinit();
            if (case.diagnostic != null and std.mem.eql(u8, callee, "function")) {
                const diagnostic = case.diagnostic.?;
                try fixture.expectDiagnostic(0, diagnostic);
            } else {
                try fixture.expectExit(0, 42);
            }
        }
    }
}

test "a returned Ref may select either runtime input while both owners live" {
    const source =
        \\func select(imm first: Ref(int), imm second: Ref(int)) Ref(int) -> $selected
        \\func run() int
        \\  const first: Box(int) = Box.new(17) else panic "unexpected allocation refusal"
        \\  const second: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
        \\  const function = select
        \\  return ($callee(Ref.from(first.borrow()), Ref.from(second.borrow()))).value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    for ([_][]const u8{ "select", "function" }) |callee| {
        for ([_]struct { selected: []const u8, status: u8 }{
            .{ .selected = "first", .status = 17 },
            .{ .selected = "second", .status = 42 },
        }) |case| {
            const entry = try test_sources.renderTemplate(testing.allocator, source, .{ .callee = callee, .selected = case.selected });
            defer testing.allocator.free(entry);
            try Fixture.expectSourceExit(entry, case.status);
        }
    }
}

test "removed from return origin syntax produces a parse diagnostic" {
    for ([_][]const u8{
        "func number(imm input: int) int from(input) -> input\nexit(number(42))",
        "func forward(imm reference: Ref(int)) Ref(int) from(reference) -> reference",
        "func forward(imm reference: Ref(int)) Ref(int) from(reference) -> return reference",
    }) |source| {
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try testing.expect((try fixture.db.get(queries.ParseFile, 0)).* == null);
        const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.ParseFile, 0, structures.Diagnostic, testing.allocator);
        defer testing.allocator.free(diagnostics);
        try testing.expectEqual(@as(usize, 1), diagnostics.len);
        try testing.expectEqual(@as(structures.FileId, 0), diagnostics[0].file_id);
    }
    const fixture = try Fixture.initFiles("extern func forward(imm reference: Ref(int)) Ref(int) from(reference)", &.{});
    defer fixture.deinit();
    try testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expect(diagnostics.len != 0);
}

test "a returned Ref can depend on an immutable owner aggregate" {
    try Fixture.expectSourceExit(
        \\struct Storage
        \\  owner: Box(int)
        \\func view(imm storage: Storage) Ref(int) -> Ref.from(storage.owner.borrow())
        \\func run() int | none
        \\  const storage = Storage{owner = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)}
        \\  return (view(storage)).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an owned Ref parameter may transfer its borrowed handle back" {
    try Fixture.expectSourceExit(
        \\func forward(var reference: Ref(int)) Ref(int) -> return reference^
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference = forward(Ref.from(owner.borrow()))
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "transferring a Ref handle does not invalidate its copy" {
    try Fixture.expectSourceExit(
        \\func forward(imm reference: Ref(int)) Ref(int) -> reference
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const original = Ref.from(owner.borrow())
        \\  const copy = forward(original)
        \\  const moved = original^
        \\  return (copy).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a conditional Ref result retains either possible owner" {
    try Fixture.expectSourceExit(
        \\func choose(imm first: Ref(int), imm second: Ref(int), pick_first: int) Ref(int)
        \\  return if pick_first == 1 -> first else second
        \\func run() int | none
        \\  const first: Box(int) = Box.new(20) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  const chosen = choose(Ref.from(first.borrow()), Ref.from(second.borrow()), 0)
        \\  return (chosen).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "reading a multi-owner Ref copies before the youngest owner ends" {
    try Fixture.expectSourceExit(
        \\func choose(imm first: Box(int), imm second: Box(int), pick_first: int) Ref(int)
        \\  return if pick_first == 1 -> Ref.from(first.borrow()) else Ref.from(second.borrow())
        \\func run() int | none
        \\  const outer: Box(int) = Box.new(17) else return none
        \\  const copied = if 1 == 1
        \\    const inner: Box(int) = Box.new(42) else return none
        \\    choose(inner, outer, 1).value
        \\  else
        \\    0
        \\  return copied
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a returned Ref cannot outlive either possible owner" {
    try Fixture.expectSourceDiagnostic(
        \\func choose(imm first: Ref(int), imm second: Ref(int), pick_first: int) Ref(int)
        \\  return if pick_first == 1 -> first else second
        \\func run() int | none
        \\  const first: Box(int) = Box.new(20) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  const chosen = choose(Ref.from(first.borrow()), Ref.from(second.borrow()), 0)
        \\  const moved = first^
        \\  return (chosen).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "a mutable Ref binding retains origins across branch assignments" {
    try Fixture.expectSourceExit(
        \\func run(pick_second: int) int | none
        \\  const first: Box(int) = Box.new(20) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  if pick_second == 1 -> selected = Ref.from(second.borrow())
        \\  return (selected).value
        \\if const result: int = run(1) -> exit(result) else exit(1)
    , 42);
}

test "a loop break retains its Ref origin" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference = loop -> break Ref.from(owner.borrow())
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a mutable Ref binding retains its origin through a loop exit" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  loop
        \\    selected = Ref.from(second.borrow())
        \\    break
        \\  return (selected).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a mutable Ref binding retains backedge origins" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  var phase = 0
        \\  const reference = loop
        \\    if phase == 0
        \\      selected = Ref.from(second.borrow())
        \\      phase = 1
        \\      continue
        \\    break selected
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a loop-carried Ref is invalid when a possible owner transfers" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  var phase = 0
        \\  loop
        \\    if phase == 0
        \\      selected = Ref.from(second.borrow())
        \\      phase = 1
        \\      continue
        \\    break
        \\  const moved = second^
        \\  return (selected).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "a Ref read inside a loop keeps backedge owners live" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  var phase = 0
        \\  loop
        \\    if phase == 0
        \\      selected = Ref.from(second.borrow())
        \\      phase = 1
        \\      continue
        \\    return selected.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a Ref of an unchanged mutable owner survives a loop header" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  return loop -> break (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a Ref of a replaced loop owner cannot be read" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  loop
        \\    owner = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\    break
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a Ref of a directly replaced owner cannot be read" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(17) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  owner = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "a Ref of an owned field cannot outlive its parent replacement" {
    try Fixture.expectSourceDiagnostic(
        \\struct Holder
        \\  box: Box(int)
        \\func run() int | none
        \\  var holder = Holder{box = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else return none)}
        \\  const reference = Ref.from(holder.box.borrow())
        \\  holder = Holder{box = (if const _selected_result_1: Box(int) = Box.new(42) -> _selected_result_1^ else return none)}
        \\  return (reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "nested loops retain their separate Ref origin sets" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var selected = Ref.from(first.borrow())
        \\  var count = 0
        \\  loop
        \\    loop
        \\      selected = Ref.from(second.borrow())
        \\      break
        \\    if count == 0
        \\      count = 1
        \\      continue
        \\    break
        \\  return (selected).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a struct containing a Ref cannot escape its local owner" {
    try Fixture.expectSourceDiagnostic(
        \\struct View
        \\  reference: Ref(int)
        \\func escape() View | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  return View{reference = Ref.from(owner.borrow())}
        \\if const view: View = escape() -> exit(42) else exit(1)
    , .borrow_outlives_source);
}

test "a Ref keeps its origin through variant widening and extraction" {
    try Fixture.expectSourceExit(
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const selected: Ref(int) | none = Ref.from(owner.borrow())
        \\  return if const reference: Ref(int) = selected -> (reference).value else 0
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "variant extraction rejects a Ref after its owner transfers" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const selected: Ref(int) | none = Ref.from(owner.borrow())
        \\  const moved = owner^
        \\  return if const reference: Ref(int) = selected -> (reference).value else 0
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "a struct containing a Ref may return with its borrowed input" {
    try Fixture.expectSourceExit(
        \\struct View
        \\  reference: Ref(int)
        \\func view(imm owner: Box(int)) View -> return View{reference = Ref.from(owner.borrow())}
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  return (view(owner).reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "an in-place Box containing a Ref retains its referent" {
    try Fixture.expectSourceDiagnostic(
        \\struct View
        \\  move = none
        \\  reference: Ref(int)
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const stored: Box(View) = Box(View).new(View{reference = Ref.from(owner.borrow())}) else return none
        \\  const moved = owner^
        \\  return ((Ref.from(stored.borrow())).value.reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "replacing a Ref field retains the new referent dependency" {
    try Fixture.expectSourceDiagnostic(
        \\struct View
        \\  reference: Ref(int)
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var view = View{reference = Ref.from(first.borrow())}
        \\  view.reference = Ref.from(second.borrow())
        \\  const moved = second^
        \\  return (view.reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "mut writeback retains origins of a Ref argument" {
    try Fixture.expectSourceExit(
        \\struct View
        \\  reference: Ref(int)
        \\func replace(mut view: View, imm reference: Ref(int))
        \\  view.reference = reference
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var view = View{reference = Ref.from(first.borrow())}
        \\  replace(view, Ref.from(second.borrow()))
        \\  return (view.reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "mut writeback retains an immutable owner's origin" {
    try Fixture.expectSourceExit(
        \\struct View
        \\  reference: Ref(int)
        \\func replace(mut view: View, imm owner: Box(int))
        \\  view.reference = Ref.from(owner.borrow())
        \\func run() int | none
        \\  const first: Box(int) = Box.new(17) else return none
        \\  const second: Box(int) = Box.new(42) else return none
        \\  var view = View{reference = Ref.from(first.borrow())}
        \\  replace(view, second)
        \\  return (view.reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "mut output cannot borrow a callee local" {
    try Fixture.expectSourceDiagnostic(
        \\struct View
        \\  reference: Ref(int)
        \\func replace(mut view: View)
        \\  const local = 42
        \\  view.reference = Ref.from(local)
        \\func run() unit | none
        \\  const owner: Box(int) = Box.new(17) else return none
        \\  var view = View{reference = Ref.from(owner.borrow())}
        \\  replace(view)
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .borrow_outlives_source);
}

test "mut writeback cannot outlive its caller-side referent" {
    try Fixture.expectSourceDiagnostic(
        \\struct View
        \\  reference: Ref(int)
        \\func replace(mut view: View, imm reference: Ref(int))
        \\  view.reference = reference
        \\func run() int | none
        \\  const outer: Box(int) = Box.new(17) else return none
        \\  var view = View{reference = Ref.from(outer.borrow())}
        \\  if 1 == 1
        \\    const inner: Box(int) = Box.new(42) else return none
        \\    replace(view, Ref.from(inner.borrow()))
        \\  return (view.reference).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .borrow_outlives_source);
}

test "func calls retain returned Ref origins" {
    try Fixture.expectSourceExit(
        \\func forward(imm reference: Ref(int)) Ref(int) | none
        \\  return reference
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  if const returned: Ref(int) = forward(Ref.from(owner.borrow())) -> return (returned).value
        \\  else return 1
        \\if const result: int = run() -> exit(result) else exit(2)
    , 42);
}

test "indirect func calls retain returned Ref origins" {
    try Fixture.expectSourceExit(
        \\func forward(imm reference: Ref(int)) Ref(int) | none
        \\  return reference
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const function = forward
        \\  if const returned: Ref(int) = function(Ref.from(owner.borrow())) -> return (returned).value
        \\  else return 1
        \\if const result: int = run() -> exit(result) else exit(2)
    , 42);
}

test "copying a Ref of a noncopyable immovable value copies only its address" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func run() int | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{value = 42}) else return none
        \\  const first = Ref.from(owner.borrow())
        \\  const second = first
        \\  return (second).value.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "a local immovable value can be borrowed without copying it" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func run() int
        \\  const local = Immovable{value = 42}
        \\  const reference: Ref(Immovable) = Ref.from(local)
        \\  return (reference).value.value
        \\exit(run())
    , 42);
}

test "replacing a borrowed scalar local preserves its address" {
    try Fixture.expectSourceExit(
        \\var number = 42
        \\const reference: Ref(int) = Ref.from(number) else panic "unexpected none"
        \\number = 7
        \\exit((reference).value)
    , 7);
}

test "a borrow of a local Box cannot escape its owner" {
    try Fixture.expectSourceDiagnostic(
        \\func escape() Ref(int) | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  return Ref.from(owner.borrow())
        \\if (escape() is Ref(int)) -> exit(1) else exit(2)
    , .borrow_outlives_source);
}

test "a borrow cannot be read after its Box owner is transferred" {
    try Fixture.expectSourceDiagnostic(
        \\func run() int | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const reference = Ref.from(owner.borrow())
        \\  const moved = owner^
        \\  return reference.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "Box destroys its initialized value on last use" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Box}
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\func run() unit | none
        \\  const owner: Box(Resource) = Box.new(Resource{value = 42}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box destination construction covers nested producers and loop results" {
    for ([_][]const u8{
        "Item{leaf = producer(42)}",
        "make(42)",
        "loop\n    if flag == 1 -> break make(42)\n    break Item{leaf = producer(1)}\n  ",
    }) |initializer| {
        const source = try testing.allocator.print(
            \\struct Leaf
            \\  move = none
            \\  value: int
            \\struct Item
            \\  move = none
            \\  leaf: Leaf
            \\func leaf(value: int) Leaf -> Leaf{{value = value}}
            \\func make(value: int) Item -> Item{{leaf = leaf(value)}}
            \\func run(flag: int) int
            \\  const producer = leaf
            \\  const owner: Box(Item) = Box(Item).new({s}) else panic "unexpected allocation refusal"
            \\  return Ref.from(owner.borrow()).value.leaf.value
            \\if const result = run(1) -> exit(result) else exit(1)
        , .{initializer});
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "Box destination construction copies immovable places and moves once" {
    const cases = [_]struct { movement: []const u8, copy: []const u8, initializer: []const u8 }{
        .{ .movement = "none", .copy = "func(imm self: Item) Item -> Item{value = self.value + 1}", .initializer = "original" },
        .{ .movement = "func(deinit self: Item) Item -> Item{value = self.value + 1}", .copy = "none", .initializer = "original^" },
    };
    for (cases) |case| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  move = {s}
            \\  copy = {s}
            \\  value: int
            \\func run() int
            \\  const original = Item{{value = 41}}
            \\  const owner: Box(Item) = Box.new({s}) else panic "allocation refused"
            \\  return Ref.from(owner.borrow()).value.value
            \\if const result = run() -> exit(result) else exit(1)
        , .{ case.movement, case.copy, case.initializer });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "Box destination construction widens fresh immovable variants" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = none
        \\  value: int
        \\func make() Item -> Item{value = 42}
        \\static MaybeItem = Item | none
        \\func run(flag: int) int | none
        \\  const producer = make
        \\  const owner: Box(MaybeItem) = Box(MaybeItem).new(if flag == 1 -> producer() else none) else return none
        \\  if Ref.from(owner.borrow()).value is Item -> return 41
        \\  return 1
        \\func answer() int | none -> (if const _selected_result_0: int = run(1) -> _selected_result_0 else return none) + (if const _selected_result_1: int = run(0) -> _selected_result_1 else return none)
        \\if const result: int = answer() -> exit(result) else exit(1)
    , 42);
}

test "unevaluated initializer inference preserves lookup diagnostics" {
    const cases = [_]struct { expression: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .expression = "unknown()", .kind = .unknown_function },
        .{ .expression = "callback()", .kind = .value_not_callable },
        .{ .expression = "item.missing()", .kind = .unknown_namespace_member },
        .{ .expression = "number.missing()", .kind = .unknown_namespace_member },
        .{ .expression = "item.value()", .kind = .value_not_callable },
        .{ .expression = "item.bad()", .kind = .value_not_callable },
        .{ .expression = "item.copy()", .kind = .unknown_namespace_member },
        .{ .expression = "item.missing", .kind = .unknown_field },
        .{ .expression = "number.value", .kind = .field_access_not_struct },
        .{ .expression = "number[]", .kind = .invalid_expression },
    };
    for (cases) |case| for ([_][]const u8{ "Box.new", "Box(int).new" }) |constructor| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  value: int
            \\static Item.bad = 42
            \\const item = Item{{value = 42}}
            \\const number = 42
            \\const callback = 42
            \\if {s}({s}) -> exit(1) else exit(2)
        , .{ constructor, case.expression });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, case.kind);
    };
}

test "unevaluated result inference preserves divergence before lookup" {
    for ([_][]const u8{ "stop().field", "stop().method()", "stop().value", "stop()()" }) |expression| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\func stop() never -> exit(42)
            \\const selected = if 1 == 1 -> {s} else Pinned{{value = 1}}
            \\_ = selected
            \\exit(1)
        , .{expression});
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "Box infers member call results without evaluating their receivers or arguments" {
    for ([_][]const u8{
        "factory.build(42)",
        "factory.identity(make(42))",
        "factory.identity(Item, make(42))",
        "factory.create(42)",
        "make_factory().build(42)",
        "original.copy()",
    }) |initializer| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  move = none
            \\  value: int
            \\  copy = func(imm self: Item) Item -> Item{{value = self.value}}
            \\func make(value: int) Item -> Item{{value = value}}
            \\struct Factory
            \\  create: func(int) Item
            \\  func build(imm self: Factory, value: int) Item -> make(value)
            \\  func identity(imm self: Factory, static T: type, imm value: T) T -> value
            \\func make_factory() Factory -> Factory{{create = make}}
            \\func run() int
            \\  const factory = Factory{{create = make}}
            \\  const original = Item{{value = 42}}
            \\  const owner: Box(Item) = Box.new({s}) else panic "allocation refused"
            \\  return Ref.from(owner.borrow()).value.value
            \\if const result = run() -> exit(result) else exit(1)
        , .{initializer});
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
        const forbidden_producer = try std.mem.replaceOwned(u8, testing.allocator, source, "func make(value: int) Item -> Item{value = value}", "func make(value: int) Item -> exit(90)");
        defer testing.allocator.free(forbidden_producer);
        const forbidden_copy = try std.mem.replaceOwned(u8, testing.allocator, forbidden_producer, "copy = func(imm self: Item) Item -> Item{value = self.value}", "copy = func(imm self: Item) Item -> exit(91)");
        defer testing.allocator.free(forbidden_copy);
        const forbidden_receiver = try std.mem.replaceOwned(u8, testing.allocator, forbidden_copy, "func make_factory() Factory -> Factory{create = make}", "func make_factory() Factory -> exit(92)");
        defer testing.allocator.free(forbidden_receiver);
        try fixture.db.setInput(queries.SourceText, 0, forbidden_receiver);
        try replaceAllocationSource(fixture, "        var storage: Allocation(T) = allocate(T, 1) else return none", "        exit(43)\n        var storage: Allocation(T) = allocate(T, 1) else return none");
        try fixture.expectExit(0, 43);
    }
}

fn replaceAllocationSource(fixture: Fixture, original: []const u8, replacement: []const u8) !void {
    const file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.memory_allocation))).*;
    const source = (try fixture.db.input(queries.SourceText, file)).*;
    try testing.expect(std.mem.indexOf(u8, source, original) != null);
    const edited = try std.mem.replaceOwned(u8, testing.allocator, source, original, replacement);
    defer testing.allocator.free(edited);
    const with_exit = try testing.allocator.print("import std.exit.{{exit}}\n\n{s}", .{edited});
    defer testing.allocator.free(with_exit);
    try fixture.db.setInput(queries.SourceText, file, with_exit);
}

test "Box obtains storage before producer arguments conditions and ownership hooks" {
    for ([_][]const u8{
        "Box.new(make(forbidden()))",
        "Box.new(if forbidden() == 1 -> make(42) else make(1))",
        "(if const _selected_result_0: Box(Item) = Box(Item).new(original) -> _selected_result_0^ else panic \"unexpected none\")",
        "(if const _selected_result_0: Box(Item) = Box(Item).new(original^) -> _selected_result_0^ else panic \"unexpected none\")",
        "Box.new(Box.new(make(forbidden())))",
    }) |call| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  value: int
            \\  copy = func(imm self: Item) Item -> exit(90)
            \\  move = func(deinit self: Item) Item -> exit(91)
            \\func forbidden() int -> exit(92)
            \\func make(value: int) Item -> Item{{value = value}}
            \\const original = Item{{value = 41}}
            \\const ignored = {s}
            \\exit(2)
        , .{call});
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try replaceAllocationSource(fixture, "        var storage: Allocation(T) = allocate(T, 1) else return none", "        exit(42)\n        var storage: Allocation(T) = allocate(T, 1) else return none");
        try fixture.expectExit(0, 42);
    }
}

test "allocating init consumers preserve Box ordering through aliases and indirect calls" {
    const cases = .{
        .{ .setup = "", .call = "Box.new(make(forbidden()))" },
        .{ .setup = "static Owner = Box(Item)\nstatic create = Owner.new", .call = "create(make(forbidden()))" },
        .{ .setup = "const create: func(init Item) Box(Item) | none = Box(Item).new", .call = "create(make(forbidden()))" },
        .{ .setup = "func invoke(imm create: func(init Item) Box(Item) | none, init item: Item) Box(Item) | none -> create(item)", .call = "invoke(Box(Item).new, make(forbidden()))" },
    };
    inline for (cases) |case| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  move = none
            \\  value: int
            \\func forbidden() int -> exit(90)
            \\func make(value: int) Item -> Item{{value = value}}
            \\{s}
            \\if const owner: Box(Item) = {s} -> exit(1) else exit(42)
        , .{ case.setup, case.call });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try replaceAllocationSource(fixture, "var storage: Allocation(T) = allocate(T, 1) else return none", "var storage: Allocation(T) = allocate(T, -1) else return none");
        try fixture.expectExit(0, 42);
    }
}

test "allocating init consumers construct immovable raw slots through aliases and callable values" {
    const cases = .{
        .{ .setup = "", .call = "unsafe_initialize(Item, storage, 1, make(41))" },
        .{ .setup = "", .call = "initialize_alias(storage, 1, make(41))" },
        .{ .setup = "const initialize: func(mut Allocation(Item), int, init Item) unit = Allocation(Item).unsafe_initialize", .call = "initialize(storage, 1, make(41))" },
        .{ .setup = "", .call = "storage.unsafe_initialize(1, make(41))" },
    };
    inline for (cases) |case| {
        const source = try testing.allocator.print(
            \\import std.memory.{{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow}}
            \\struct Item
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Item) -> exit(self.value)
            \\func make(value: int) Item -> Item{{value = value + 1}}
            \\static Slots = Allocation(Item)
            \\static initialize_alias = Slots.unsafe_initialize
            \\func run()
            \\  var storage: Allocation(Item) = allocate(Item, 2) else panic "allocation refused"
            \\  {s}
            \\  {s}
            \\  const value = unsafe_borrow(Item, storage, 1).value
            \\  if value == 42
            \\    unsafe_destroy(Item, storage, 1)
            \\  else
            \\    unsafe_destroy(Item, storage, 1)
            \\    deallocate(Item, storage)
            \\    exit(91)
            \\  deallocate(Item, storage)
            \\run()
            \\exit(93)
        , .{ case.setup, case.call });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "allocating init consumers clean raw slot partial fields before receiving frames" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize}
        \\struct Leaf
        \\  move = none
        \\  drop = func(deinit self: Leaf) -> exit(42)
        \\struct Item
        \\  move = none
        \\  first: Leaf
        \\  second: int
        \\func fail_value() int | none
        \\  if not (1 == 0) -> return none
        \\  return 0
        \\func run() unit | none
        \\  var storage: Allocation(Item) = allocate(Item, 1) else return none
        \\  if (unsafe_initialize(Item, storage, 0, Item{first = Leaf{}, second = (if const _selected_result_0: int = fail_value() -> _selected_result_0 else panic "unexpected none")}) is unit)
        \\    deallocate(Item, storage)
        \\    exit(90)
        \\  deallocate(Item, storage)
        \\  exit(91)
        \\  return ()
        \\if (run() is unit) -> exit(92) else exit(93)
    , 42);
}

test "Box allocation failure skips initialization and preserves its source" {
    const fixture = try Fixture.initFiles(
        \\func forbidden() int -> exit(90)
        \\func make(value: int) int -> value
        \\struct Item
        \\  value: int
        \\  move = func(deinit self: Item) Item -> exit(91)
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\func run() int
        \\  const original = Item{value = 42}
        \\  if (Box.new(make(forbidden())) is Box(int)) -> return 1
        \\  if (Box.new(original^) is Box(Item)) -> return 2
        \\  return 92
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try replaceAllocationSource(fixture, "var storage: Allocation(T) = allocate(T, 1) else return none", "var storage: Allocation(T) = allocate(T, -1) else return none");
    try fixture.expectExit(0, 42);
}

test "Box destination construction recomputes after copy capability and allocator edits" {
    const source =
        \\struct Item
        \\  move = none
        \\  value: int
        \\  copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func run() int | none
        \\  const original = Item{value = 41}
        \\  const owner: Box(Item) = Box.new(original) else return none
        \\  return Ref.from(owner.borrow()).value.value
        \\if const result: int = run() -> exit(result) else exit(43)
    ;
    const fixture = try Fixture.initFiles(source, &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const without_copy = try std.mem.replaceOwned(u8, testing.allocator, source, "copy = func(imm self: Item) Item -> Item{value = self.value + 1}", "copy = none");
    defer testing.allocator.free(without_copy);
    try fixture.db.setInput(queries.SourceText, 0, without_copy);
    try fixture.expectDiagnostic(0, .type_not_copyable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
    try replaceAllocationSource(fixture, "var storage: Allocation(T) = allocate(T, 1) else return none", "var storage: Allocation(T) = allocate(T, -1) else return none");
    try fixture.expectExit(0, 43);
    const file = (try fixture.db.input(queries.StandardFile, @backingInt(standard_library.File.memory_allocation))).*;
    try fixture.db.setInput(queries.SourceText, file, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(0, 42);
}

test "Box constructs immovable struct directly in owned storage" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  marker: byte
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{marker = 7, value = 42}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box drops a struct with a custom move without relocating it" {
    try Fixture.expectSourceExit(
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> return CustomMove{value = self.value}
        \\  drop = func(deinit self: CustomMove) -> exit(self.value)
        \\func run() unit | none
        \\  const owner: Box(CustomMove) = Box(CustomMove).new(CustomMove{value = 42}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "immovable and nested custom-move arguments borrow and write back by address" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> CustomMove{value = self.value}
        \\struct Wrapper
        \\  inner: CustomMove
        \\func bump_immovable(mut value: Immovable)
        \\  value.value += 1
        \\func bump_wrapper(mut value: Wrapper)
        \\  value.inner.value += 1
        \\func read_immovable(imm value: Immovable) int -> value.value
        \\func read_wrapper(imm value: Wrapper) int -> value.inner.value
        \\var first = Immovable{value = 20}
        \\var second = Wrapper{inner = CustomMove{value = 20}}
        \\bump_immovable(first)
        \\bump_wrapper(second)
        \\exit(read_immovable(first) + read_wrapper(second))
    , 42);
}

test "deinit consumes an immovable local at its original address" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = none
        \\  value: int
        \\func consume(deinit item: Item) int -> item.value
        \\const item = Item{value = 42}
        \\exit(consume(item))
    , 42);
}

test "deinit does not invoke a custom move hook" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  value: int
        \\  move = func(deinit self: Item) Item -> Item{value = self.value + 1}
        \\func consume(deinit item: Item) int -> item.value
        \\const item = Item{value = 42}
        \\exit(consume(item^))
    , 42);
}

test "deinit constructs fresh variant arguments before passing their address" {
    try Fixture.expectSourceExit(
        \\func consume(deinit item: int | none) int
        \\  if const number: int = item -> return number
        \\  return 1
        \\const indirect = consume
        \\exit(consume(20) + indirect(22))
    , 42);
}

test "deinit rejects borrowed parameters instead of copying them" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\  value: int
        \\  copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func consume(deinit item: Item) int -> item.value
        \\func forward(imm item: Item) int -> consume(item)
        \\exit(forward(Item{value = 42}))
    , .ownership_transfer_requires_owned_place);
}

test "deinit rejects borrowed fields aliases and referents" {
    const cases = [_][]const u8{
        \\func run(imm holder: Holder) int -> consume(holder.item)
        \\exit(run(Holder{item = Item{value = 42}}))
        ,
        \\import std.memory
        \\const item = Item{value = 42}
        \\const alias = Ref.from(item)
        \\exit(consume(alias.value))
        ,
        \\import std.memory
        \\const holder = Holder{item = Item{value = 42}}
        \\const alias = Ref.from(holder)
        \\exit(consume(alias.value.item))
        ,
        \\func run() int | none
        \\  const owner: Box(Item) = Box.new(Item{value = 42}) else return none
        \\  return consume(Ref.from(owner.borrow()).value)
        \\if const result: int = run() -> exit(result) else exit(1)
        ,
        \\func run(mut item: Item) int -> consume(item)
        \\var item = Item{value = 42}
        \\exit(run(item))
        ,
    };
    for (cases) |body| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            \\struct Item
            \\  copy = trivial
            \\  value: int
            \\struct Holder
            \\  item: Item
            \\func consume(deinit item: Item) int -> item.value
            \\
            ,
            body,
        });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .ownership_transfer_requires_owned_place);
    }
}

test "deinit member receivers preserve independent field availability" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = none
        \\  value: int
        \\  pub func consume(deinit self: Item) int -> self.value
        \\struct Pair
        \\  first: Item
        \\  second: Item
        \\const pair = Pair{first = Item{value = 20}, second = Item{value = 22}}
        \\const first = pair.first^.consume()
        \\exit(first + pair.second.consume())
    , 42);
}

test "ownership members expose primitive copy and move as callable values" {
    try Fixture.expectSourceExit(
        \\const duplicate = int.copy
        \\const transfer = int.move
        \\const value = duplicate(42)
        \\exit(transfer(value))
    , 42);
}

test "ownership members select custom hooks once for calls and aliases" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  value: int
        \\  copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\  move = func(deinit self: Item) Item -> Item{value = self.value + 2}
        \\const source = Item{value = 35}
        \\const copied = Item.copy(source)
        \\const moved = copied.move()
        \\const transfer = Item.move
        \\const indirect = transfer(moved)
        \\exit(indirect.value + source.copy().value - source.value + 1)
    , 42);
}

test "ownership members compose fieldwise variants and generated types" {
    try Fixture.expectSourceExit(
        \\struct Cell(T: type)
        \\  copy = fieldwise
        \\  value: T
        \\static IntCell = Cell(int)
        \\static Maybe = IntCell | none
        \\const original: Maybe = IntCell{value = 42}
        \\const copied = Maybe.copy(original)
        \\const moved = copied.move()
        \\if const cell: IntCell = moved -> exit(cell.value) else exit(1)
    , 42);
}

test "ownership members preserve consuming access diagnostics" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\  copy = trivial
        \\  value: int
        \\func invalid(imm item: Item) Item -> item.move()
        \\const result = invalid(Item{value = 42})
        \\exit(result.value)
    , .ownership_transfer_requires_owned_place);
}

test "ownership members copy immovable values independently of move support" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\const source = Item{value = 42}
        \\const copied = Item.copy(source)
        \\exit(copied.value)
    , 42);
}

test "ownership members expose callable copy and move" {
    try Fixture.expectSourceExit(
        \\static Callback: type = func(int) int
        \\func increment(value: int) int -> value + 1
        \\const original = Callback.copy(increment)
        \\const transferred = original.move()
        \\exit(transferred(41))
    , 42);
}

test "ownership members participate in where type tests" {
    try Fixture.expectSourceExit(
        \\struct CopyOnly
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\func copyable(static T: type) int where T.copy is func(imm T) T -> 20
        \\func movable(static T: type) int where T.move is func(deinit T) T -> 22
        \\exit(copyable(CopyOnly) + movable(int))
    , 42);
}

test "ownership members with missing capabilities fail where conditions" {
    for ([_][]const u8{ "copy", "move" }) |name| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  copy = none
            \\  move = none
            \\  value: int
            \\func accept(static T: type) int where T.{s} is func({s} T) T -> 42
            \\exit(accept(Item))
        , .{ name, if (std.mem.eql(u8, name, "copy")) "imm" else "deinit" });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .where_condition_failed);
    }
}

test "ownership members cannot be replaced by namespace declarations" {
    const cases = [_][]const u8{
        \\struct Item
        \\  func copy() int -> 42
        \\_ = Item.copy
        ,
        \\struct Item
        \\  copy = trivial
        \\func Item.copy() int -> 42
        \\_ = Item.copy
        ,
        \\struct Item
        \\  move: int
        \\_ = Item.move
        ,
    };
    for (cases) |source| {
        try Fixture.expectSourceDiagnostic(source, .reserved_ownership_member);
    }
}

test "ownership members execute selected operations at compile time" {
    try Fixture.expectSourceExit(
        \\struct Cell(T: type)
        \\  value: T
        \\  copy = func(imm self: Cell(T)) Cell(T) -> Cell(T){value = self.value + 1}
        \\  move = func(deinit self: Cell(T)) Cell(T) -> Cell(T){value = self.value + 2}
        \\static IntCell = Cell(int)
        \\static Maybe = IntCell | none
        \\static result = comptime
        \\  const source: Maybe = IntCell{value = 38}
        \\  const duplicate = Maybe.copy
        \\  const copied = duplicate(source)
        \\  const moved = copied.move()
        \\  if const cell: IntCell = moved -> cell.value else 1
        \\exit(result)
    , 42);
}

test "ownership members preserve reference origins" {
    for ([_][]const u8{ "copy", "move" }) |name| {
        const source = try testing.allocator.print(
            \\func run() int
            \\  var owner: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
            \\  var original = Ref.from(owner.borrow())
            \\  const callback = Ref(int).{s}
            \\  const handle = callback(original)
            \\  return handle.value
            \\if const result = run() -> exit(result) else exit(1)
        , .{name});
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
        const invalid = try std.mem.replaceOwned(u8, testing.allocator, source, "return handle.value", "const consumed = owner^\n  return handle.value");
        defer testing.allocator.free(invalid);
        try fixture.db.setInput(queries.SourceText, 0, invalid);
        try fixture.expectDiagnostic(0, .use_after_transfer);
    }
}

test "ownership members validate definitions before where availability" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\  copy = func(imm self: int) int -> self
        \\  value: int
        \\func accept(static T: type) int where T.copy is func(imm T) T -> 42
        \\exit(accept(Item))
    , .struct_ownership_hook_signature_mismatch);
}

test "ownership members invalidate retained callables after capability edits" {
    const original =
        \\pub struct Item
        \\  copy = trivial
        \\  pub value: int
    ;
    const fixture = try Fixture.initFiles(
        \\import lib
        \\static duplicate = lib.Item.copy
        \\const source = lib.Item{value = 42}
        \\const copied = duplicate(source)
        \\exit(copied.value)
    , &.{.{ .path = "lib/a.chi", .module_path = "lib", .source = original }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const scope = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?;
    const value_id = (try fixture.db.get(queries.ResolveStatic, scope.resolveStatic("duplicate").?)).*.?;
    const reference = (try fixture.db.lookupInterned(queries.CompileTimeValues, value_id)).runtime.value.function_ref;
    try fixture.db.setInput(queries.SourceText, 1,
        \\pub struct Item
        \\  copy = none
        \\  pub value: int
    );
    try fixture.expectDiagnostic(0, .unknown_namespace_member);
    try testing.expect((try fixture.db.get(queries.FunctionInstanceSignature, reference.instance())).* == null);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.FunctionInstanceSignature, reference.instance(), structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(std.meta.Tag(structures.Diagnostic.Kind).type_not_copyable, std.meta.activeTag(diagnostics[0].kind));
    try fixture.db.setInput(queries.SourceText, 1,
        \\pub struct Item
        \\  copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\  pub value: int
    );
    try fixture.expectExit(0, 43);
    try fixture.db.setInput(queries.SourceText, 1, original);
    try fixture.expectExit(0, 42);
}

test "deinit selects original storage through conditional and loop results" {
    const expressions = [_][]const u8{
        "if flag == 1 -> first else second",
        "if flag == 1 -> first^ else second^",
        "if flag == 1 -> (if flag == 1 -> first else second) else second",
        "loop\n    if flag == 1 -> break first\n    break second\n  ",
        "if flag == 1 -> first else make(1)",
        "if flag == 1 -> producer(41) else make(1)",
        "if flag == 1 -> holder.first else holder.second",
    };
    const movements = [_][]const u8{ "fieldwise", "none", "func(deinit self: Item) Item -> exit(91)" };
    for (movements) |movement| for (expressions) |expression| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  move = {s}
            \\  copy = func(imm self: Item) Item -> exit(90)
            \\  value: int
            \\  drop = func(deinit self: Item) -> ()
            \\struct Holder
            \\  move = none
            \\  first: Item
            \\  second: Item
            \\func make(value: int) Item -> Item{{value = value}}
            \\func consume(deinit item: Item, marker: int) int -> item.value
            \\func run(flag: int) int
            \\  const first = make(41)
            \\  const second = make(1)
            \\  const holder = Holder{{first = make(41), second = make(1)}}
            \\  const producer = make
            \\  const callee: func(deinit Item, int) int = consume
            \\  return callee({s}, 0)
            \\static compiled = comptime -> run(1) + run(0)
            \\exit(run(1) + run(0) + compiled - 42)
        , .{ movement, expression });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    };
}

test "fresh consuming selections construct in the known variant context" {
    const expressions = [_][]const u8{
        "if flag == 1 -> Item{value = 41} else none",
        "if flag == 1 -> producer(41) else none",
        "loop\n    if flag == 1 -> break producer(41)\n    break none\n  ",
        "if flag == 1 -> first else none",
    };
    for ([_][]const u8{ "fieldwise", "none" }) |movement| for (expressions) |expression| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  move = {s}
            \\  copy = func(imm self: Item) Item -> exit(90)
            \\  value: int
            \\func make(value: int) Item -> Item{{value = value}}
            \\func consume(deinit item: Item | none) int
            \\  if item is Item -> return 41
            \\  return 1
            \\func run(flag: int) int
            \\  const first: Item | none = Item{{value = 41}}
            \\  const producer = make
            \\  const callee = consume
            \\  return callee({s})
            \\static compiled = comptime -> run(1) + run(0)
            \\exit(run(1) + run(0) + compiled - 42)
        , .{ movement, expression });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    };
}

test "fresh consuming selections retain static type inference" {
    for ([_][]const u8{
        "if flag == 1 -> 41 else none",
        "if flag == 1 -> producer(41) else none",
        "loop\n    if flag == 1 -> break producer(41)\n    break none\n  ",
    }) |expression| {
        const source = try testing.allocator.print(
            \\func make(value: int) int -> value
            \\func consume(static T: type, deinit item: T) int
            \\  if const value: int = item -> return value
            \\  return 1
            \\func run(flag: int) int
            \\  const producer = make
            \\  return consume({s})
            \\static compiled = comptime -> run(1) + run(0)
            \\exit(run(1) + run(0) + compiled - 42)
        , .{expression});
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "consuming selections retain sources and reject borrowed authority" {
    const cases = [_]struct { body: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .body =
        \\func run(flag: int) int
        \\  const first = make(41)
        \\  const second = make(1)
        \\  const result = consume(if flag == 1 -> first else second, 0)
        \\  return first.value + result
        \\exit(run(1))
        , .kind = .possibly_transferred },
        .{ .body =
        \\func run(flag: int) int
        \\  var first = make(41)
        \\  const second = make(1)
        \\  return consume(if flag == 1 -> first else second, if flag == 1
        \\    first = make(7)
        \\    0
        \\  else 0)
        \\exit(run(1))
        , .kind = .consumed_storage_in_use },
        .{ .body =
        \\import std.memory
        \\func run(flag: int) int
        \\  const item = make(41)
        \\  const alias = Ref.from(item)
        \\  return consume(if flag == 1 -> alias.value else make(1), 0)
        \\exit(run(1))
        , .kind = .ownership_transfer_requires_owned_place },
        .{ .body =
        \\func run(imm item: Item, flag: int) int
        \\  return consume(if flag == 1 -> item else make(1), 0)
        \\exit(run(make(41), 1))
        , .kind = .ownership_transfer_requires_owned_place },
        .{ .body =
        \\func run() int | none
        \\  const owner: Box(Item) = Box.new(make(42)) else return none
        \\  return consume(Ref.from(owner.borrow()).value, 0)
        \\if const result: int = run() -> exit(result) else exit(1)
        , .kind = .ownership_transfer_requires_owned_place },
        .{ .body =
        \\func wider(deinit item: Item | none) int -> 42
        \\func run(flag: int) int
        \\  const item = make(41)
        \\  return wider(if flag == 1 -> item else make(1))
        \\exit(run(1))
        , .kind = .call_argument_type_mismatch },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            \\struct Item
            \\  move = none
            \\  copy = trivial
            \\  value: int
            \\func make(value: int) Item -> Item{value = value}
            \\func consume(deinit item: Item, marker: int) int -> item.value
            \\
            ,
            case.body,
        });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, case.kind);
    }
}

test "zero-sized consuming selections keep addressable storage" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = fieldwise
        \\func consume(deinit item: Item) int -> 42
        \\func run(flag: int) int
        \\  const first = Item{}
        \\  const second = Item{}
        \\  return consume(if flag == 1 -> first else second)
        \\static compiled = comptime -> run(1) + run(0)
        \\exit(run(1) + run(0) + compiled - 126)
    , 42);
}

test "consuming selection cleanup distinguishes successful calls from later failure" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = none
        \\  value: int
        \\  counter: Ref(int)
        \\  drop = func(deinit self: Item)
        \\    self.counter.value = self.counter.value + self.value
        \\func consume(deinit item: Item, marker: int) -> ()
        \\func fail_value() int | none
        \\  if not (1 == 0) -> return none
        \\  return 0
        \\func prepare(var counter: Ref(int), named: int, fails: int) unit | none
        \\  const item = Item{value = 20, counter = counter}
        \\  if fails == 1
        \\    consume(if named == 1 -> item else Item{value = 22, counter = counter}, (if const _selected_result_0: int = fail_value() -> _selected_result_0 else return none))
        \\  else
        \\    consume(if named == 1 -> item else Item{value = 22, counter = counter}, 0)
        \\  return ()
        \\func probe(named: int, fails: int) int | none
        \\  var counter: Box(int) = Box.new(0) else return none
        \\  if (prepare(Ref.from(counter.borrow()), named, fails) is unit) -> ()
        \\  return Ref.from(counter.borrow()).value
        \\func run() int | none -> (if const _selected_result_1: int = probe(1, 0) -> _selected_result_1 else return none) + (if const _selected_result_2: int = probe(0, 0) -> _selected_result_2 else return none) + (if const _selected_result_3: int = probe(1, 1) -> _selected_result_3 else return none) + (if const _selected_result_4: int = probe(0, 1) -> _selected_result_4 else return none) - 40
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "consuming selection storage follows movability edits" {
    const source =
        \\struct Item
        \\  move = $move
        \\  value: int
        \\func make(value: int) Item -> Item{value = value}
        \\func consume(deinit item: Item) int -> item.value
        \\func run(flag: int) int
        \\  const first = make(41)
        \\  const second = make(1)
        \\  const callee = consume
        \\  return callee(if flag == 1 -> first else second)
        \\static compiled = comptime -> run(1) + run(0)
        \\exit(run(1) + run(0) + compiled - 42)
    ;
    const fixture = try Fixture.initFiles("", &.{});
    defer fixture.deinit();
    for ([_][]const u8{ "fieldwise", "none", "func(deinit self: Item) Item -> exit(90)", "fieldwise" }) |movement| {
        const edited = try test_sources.renderTemplate(testing.allocator, source, .{ .move = movement });
        defer testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        try fixture.expectExit(0, 42);
    }
}

test "consuming selections preserve contained reference origins" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  move = none
        \\  handle: Ref(int)
        \\func take(deinit item: Item) Ref(int) -> item.handle
        \\func run(flag: int) int | none
        \\  const first_owner: Box(int) = Box.new(20) else return none
        \\  const second_owner: Box(int) = Box.new(22) else return none
        \\  const first = Item{handle = Ref.from(first_owner.borrow())}
        \\  const second = Item{handle = Ref.from(second_owner.borrow())}
        \\  const handle = take(if flag == 1 -> first else second)
        \\  return handle.value
        \\func answer() int | none -> (if const _selected_result_0: int = run(1) -> _selected_result_0 else return none) + (if const _selected_result_1: int = run(0) -> _selected_result_1 else return none)
        \\if const result: int = answer() -> exit(result) else exit(1)
    , 42);

    const rejected = try Fixture.initFiles(
        \\struct Item
        \\  move = none
        \\  value: int
        \\func invalid(deinit item: Item) Ref(Item) -> Ref.from(item)
        \\const handle = invalid(Item{value = 42})
        \\exit(handle.value.value)
    , &.{});
    defer rejected.deinit();
    try rejected.expectDiagnostic(0, .borrow_outlives_source);
}

test "deinit completes an explicit-drop root" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  drop = explicit
        \\  value: int
        \\func dispose(deinit item: Item) int -> item.value
        \\const item = Item{value = 42}
        \\exit(dispose(item))
    , 42);
}

test "deinit move hooks transfer fields through nested hooks exactly once" {
    try Fixture.expectSourceExit(
        \\struct Field
        \\  value: int
        \\  move = func(deinit self: Field) Field
        \\    const value = self.value^
        \\    return Field{value = value + 1}
        \\struct Item
        \\  field: Field
        \\  move = func(deinit self: Item) Item -> Item{field = self.field^}
        \\const item = Item{field = Field{value = 41}}
        \\const moved = item^
        \\exit(moved.field.value)
    , 42);
}

test "deinit conflicts with an earlier borrow of the same field" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\  value: int
        \\struct Holder
        \\  item: Item
        \\func take(imm borrowed: Item, deinit consumed: Item) int -> borrowed.value
        \\const holder = Holder{item = Item{value = 42}}
        \\exit(take(holder.item, holder.item))
    , .use_after_transfer);
}

test "deinit move hooks transfer fields and clean up remaining fields" {
    try Fixture.expectSourceExit(
        \\struct Child
        \\  value: int
        \\  drop = func(deinit self: Child) -> exit(self.value)
        \\struct Item
        \\  value: int
        \\  child: Child
        \\  move = func(deinit self: Item) Item -> Item{value = self.value^, child = Child{value = 1}}
        \\const item = Item{value = 0, child = Child{value = 42}}
        \\const moved = item^
        \\exit(moved.value)
    , 42);
}

test "deinit forwards an explicit-drop field from its original storage" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Holder
        \\  drop = explicit
        \\  storage: Allocation(int)
        \\func dispose(deinit holder: Holder)
        \\  deallocate(int, holder.storage)
        \\func run() unit | none
        \\  const holder = Holder{storage = (if const _selected_result_0: Allocation(int) = allocate(int, 1) -> _selected_result_0^ else return none)}
        \\  dispose(holder)
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "deinit member call consumes an owned field" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate}
        \\struct Holder
        \\  storage: Allocation(int)
        \\func dispose(deinit holder: Holder)
        \\  holder.storage.deallocate()
        \\func run() unit | none
        \\  const holder = Holder{storage = (if const _selected_result_0: Allocation(int) = allocate(int, 1) -> _selected_result_0^ else return none)}
        \\  dispose(holder)
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "deinit field consumption invalidates later field reads" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Holder
        \\  storage: Allocation(int)
        \\func invalid(deinit holder: Holder) int
        \\  deallocate(int, holder.storage)
        \\  return holder.storage.capacity()
        \\func run() int | none
        \\  const holder = Holder{storage = (if const _selected_result_0: Allocation(int) = allocate(int, 1) -> _selected_result_0^ else return none)}
        \\  return invalid(holder)
        \\if const result: int = run() -> exit(result) else exit(1)
    , .use_after_transfer);
}

test "pending deinit arguments retain their storage during argument evaluation" {
    const cases = [_]struct { call: []const u8, source: []const u8, replacement: []const u8, expected: ?u8 = null }{
        .{ .call = "take", .source = "item", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "take", .source = "item^", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "callee", .source = "item", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "generic", .source = "item", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "take", .source = "holder.item", .replacement = "holder.item = Pinned{value = 7}" },
        .{ .call = "take", .source = "holder.item", .replacement = "holder = Holder{item = Pinned{value = 7}, count = 0}" },
        .{ .call = "take_int", .source = "holder.count", .replacement = "holder.count = 7", .expected = 0 },
        .{ .call = "take", .source = "item", .replacement = "take_int(holder.count, if 1 == 1\n      item = Pinned{value = 7}\n      0\n    else 0)" },
    };
    for (cases) |case| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\struct Holder
            \\  item: Pinned
            \\  count: int
            \\func take(deinit old: Pinned, marker: int) int -> old.value + marker
            \\func take_int(deinit old: int, marker: int) int -> old + marker
            \\func generic(static T: type, deinit old: T, marker: int) int -> 42
            \\func run() int
            \\  const callee: func(deinit Pinned, int) int = take
            \\  var item = Pinned{{value = 42}}
            \\  var holder = Holder{{item = Pinned{{value = 42}}, count = 0}}
            \\  return {s}({s}, if 1 == 1
            \\    {s}
            \\    0
            \\  else 0)
            \\exit(run())
        , .{ case.call, case.source, case.replacement });
        defer testing.allocator.free(source);
        if (case.expected) |expected|
            try Fixture.expectSourceExit(source, expected)
        else
            try Fixture.expectSourceDiagnostic(source, .consumed_storage_in_use);
    }
}

test "pending deinit arguments permit sibling writes and release storage after calls" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\struct Holder
        \\  item: Pinned
        \\  count: int
        \\func take(deinit old: Pinned, marker: int) int -> old.value + marker
        \\func take_int(deinit old: int, marker: int) int -> old + marker
        \\func run() int
        \\  var holder = Holder{item = Pinned{value = 20}, count = 0}
        \\  var other = 2
        \\  const first = take(holder.item, take_int(other, if 1 == 1
        \\    holder.count = 1
        \\    holder.count
        \\  else 0))
        \\  holder.item = Pinned{value = 17}
        \\  other = 2
        \\  return first + take(holder.item, other)
        \\static compiled = comptime -> run()
        \\exit(run() + compiled - 42)
    , 42);
}

test "pending deinit storage checks follow movability edits" {
    const source =
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\func take(deinit old: Pinned, marker: int) int -> old.value
        \\func run() int
        \\  var item = Pinned{value = 42}
        \\  return take(item, if 1 == 1
        \\    item = Pinned{value = 7}
        \\    0
        \\  else 0)
        \\exit(run())
    ;
    const fixture = try Fixture.initFiles(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .consumed_storage_in_use);
    const movable = try std.mem.replaceOwned(u8, testing.allocator, source, "move = none", "move = fieldwise");
    defer testing.allocator.free(movable);
    try fixture.db.setInput(queries.SourceText, 0, movable);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectDiagnostic(0, .consumed_storage_in_use);
}

test "deinit source is cleaned when a later argument fails" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\func fail_value() int | none
        \\  if not (1 == 0) -> return none
        \\  return 0
        \\func take(deinit item: Item, value: int) -> ()
        \\func run() unit | none
        \\  const item = Item{value = 42}
        \\  take(item, (if const _selected_result_0: int = fail_value() -> _selected_result_0 else return none))
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "deinit forwarding retains residual cleanup when a later argument fails" {
    try Fixture.expectSourceExit(
        \\struct Child
        \\  value: int
        \\  drop = func(deinit self: Child) -> exit(self.value)
        \\struct Item
        \\  child: Child
        \\  drop = func(deinit self: Item) -> exit(1)
        \\func take(deinit item: Item, value: int) -> ()
        \\func fail_value() int | none
        \\  if not (1 == 0) -> return none
        \\  return 0
        \\func forward(deinit item: Item) unit | none
        \\  take(item, (if const _selected_result_0: int = fail_value() -> _selected_result_0 else return none))
        \\  return ()
        \\if (forward(Item{child = Child{value = 42}}) is unit) -> exit(2) else exit(3)
    , 42);
}

test "deinit fresh variant cleanup survives later argument failure" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\func take(deinit item: Item | none, value: int) -> ()
        \\func fail_value() int | none
        \\  if not (1 == 0) -> return none
        \\  return 0
        \\func run() unit | none
        \\  take(Item{value = 42}, (if const _selected_result_0: int = fail_value() -> _selected_result_0 else return none))
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "deinit explicit arguments cannot be abandoned by later argument failure" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\  drop = explicit
        \\func take(deinit item: Item, value: int) -> ()
        \\func fail_value() int | none
        \\  if not (1 == 0) -> return none
        \\  return 0
        \\func run() unit | none
        \\  const item = Item{}
        \\  take(item, (if const _selected_result_0: int = fail_value() -> _selected_result_0 else return none))
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , .value_requires_explicit_drop);
}

test "custom drop hook does not redispatch after replacing self" {
    try Fixture.expectSourceExit(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource)
        \\    self = Resource{value = self.value + 1}
        \\    exit(self.value)
        \\func run() unit | none
        \\  const owner: Box(Resource) = Box.new(Resource{value = 41}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

fn expectNoRelocation(fixture: Fixture, name: []const u8) !void {
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = fixture.db };
    const function = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction(name).?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = function })).*.?;
    for (body.instructions) |instruction| {
        const copied: ?structures.TypeId = switch (instruction) {
            .field_access => |operation| operation.field_type,
            .variant_extract => |operation| operation.target_type,
            .variant_coerce => |operation| if (operation.destination == null) operation.target_type else null,
            .value_copy => |operation| if (operation.destination == null) operation.type_id else null,
            else => null,
        };
        if (copied) |type_id| try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(type_id));
    }
    for (body.branch_arguments) |use| if (use.coerce_to) |type_id| try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(type_id));
    if (try types.argumentPassing(body.return_type) == .direct) return;
    for (body.blocks) |block| if (block.terminator == .return_value) {
        const returned = block.terminator.return_value;
        try testing.expect(returned.coerce_to == null);
        try testing.expect(@backingInt(returned.value) >= body.block_arguments.len);
        try testing.expect(body.instructions[@backingInt(returned.value) - body.block_arguments.len] == .result_storage);
    };
}

test "fresh results construct in their final destinations" {
    const fixture = try Fixture.initFiles(
        \\struct Tracked
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> ()
        \\struct Moved
        \\  value: int
        \\  move = func(deinit self: Moved) Moved -> exit(90)
        \\struct Pair
        \\  first: Tracked
        \\  second: Moved
        \\func make(value: int) Tracked -> Tracked{value = value}
        \\func build(choice: int) Pair
        \\  const producer = make
        \\  return Pair{first = if choice == 1 -> producer(20) else make(1), second = Moved{value = 22}}
        \\func maybe(choice: int) Pair | none
        \\  if choice == 0 -> return none
        \\  return build(choice)
        \\func pick(choice: int) Moved
        \\  var index = 0
        \\  return loop
        \\    index += 1
        \\    if index == choice -> break Moved{value = index}
        \\func present(imm value: Pair | none) int
        \\  if value is Pair -> return 1
        \\  return 0
        \\func consume(var pair: Pair) int -> pair.first.value + pair.second.value
        \\exit(consume(build(1)) + pick(3).value + present(maybe(1)) + present(maybe(0)) - 4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "build", "maybe", "pick" }) |name| try expectNoRelocation(fixture, name);
}

test "named results copy or explicitly move into their destination" {
    const fixture = try Fixture.initFiles(
        \\struct Counted
        \\  value: int
        \\  copy = func(imm self: Counted) Counted -> Counted{value = self.value + 1}
        \\  move = func(deinit self: Counted) Counted -> Counted{value = self.value + 10}
        \\struct Holder
        \\  item: Counted
        \\func fresh() Counted -> Counted{value = 0}
        \\func copied() Counted
        \\  const named = Counted{value = 0}
        \\  return named
        \\func moved() Counted
        \\  const named = Counted{value = 0}
        \\  return named^
        \\const holder = Holder{item = moved()}
        \\exit(fresh().value + copied().value + moved().value + holder.item.value + 21)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    for ([_][]const u8{ "fresh", "copied", "moved" }) |name| try expectNoRelocation(fixture, name);
}

test "a named immovable result copies only with copy capability" {
    const cases = [_]struct { copy: []const u8, result: []const u8, kind: ?std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .copy = "none", .result = "pinned", .kind = .type_not_copyable },
        .{ .copy = "trivial", .result = "pinned^", .kind = .type_not_movable },
        .{ .copy = "trivial", .result = "pinned", .kind = null },
    };
    for (cases) |case| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  copy = {s}
            \\  value: int
            \\func named() Pinned
            \\  const pinned = Pinned{{value = 42}}
            \\  return {s}
            \\exit(named().value)
        , .{ case.copy, case.result });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        if (case.kind) |kind| try fixture.expectDiagnostic(0, kind) else try fixture.expectExit(0, 42);
    }
}

test "results that cannot move directly select, widen, or reject without relocation" {
    const cases = [_]struct { body: []const u8, kind: ?std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .body = "const pinned = if 1 < 2 -> Pinned{value = 42} else Pinned{value = 1}\nexit(pinned.value)", .kind = null },
        .{ .body = "const pinned = if 1 < 2 -> Pinned{value = 42} else none\nif pinned is Pinned -> exit(42) else exit(1)", .kind = null },
        .{ .body = "const pinned = if 1 < 2\n  const value = 40\n  make(value + 2)\nelse Pinned{value = 1}\nexit(pinned.value)", .kind = null },
        .{ .body = "var index = 0\nconst pinned = loop\n  index += 1\n  if index == 42 -> break make(index)\nexit(pinned.value)", .kind = null },
        .{ .body = "var index = 0\nconst pinned = loop\n  index += 1\n  if index == 1 -> break none\n  break make(index)\nif pinned is none -> exit(42) else exit(1)", .kind = null },
        .{ .body = "const pinned: Pinned = if 1 < 2 -> Pinned{value = 42} else Pinned{value = 1}\nexit(pinned.value)", .kind = null },
        .{ .body = "if 1 < 2\n  Pinned{value = 1}\nexit(42)", .kind = null },
        .{ .body = "func look(imm value: Pinned | none) int -> 42\nconst pinned = Pinned{value = 1}\nexit(look(pinned))", .kind = .relocation_requires_direct_move },
        .{ .body = "func look(imm value: Pinned | none) int\n  if value is Pinned -> return 42\n  return 1\nexit(look(make(1)) + look(Pinned{value = 1}) - 42)", .kind = null },
        .{ .body = "func keep(var value: Pinned | none) int\n  if value is Pinned -> return 42\n  return 1\nexit(keep(Pinned{value = 1}))", .kind = null },
        .{ .body = "func maybe() Pinned | none -> Pinned{value = 1}\nfunc widen() Pinned | none | int -> maybe()\nconst widened = widen()\nexit(42)", .kind = .relocation_requires_direct_move },
        .{ .body = "func look(imm value: Pinned | none) int\n  if value is Pinned -> return 1\n  return 42\nexit(look(none))", .kind = null },
        .{ .body = "func keep(static T: type, var t: T, var value: Pinned | none) int\n  if value is Pinned -> return 1\n  return t\nexit(keep(42, none))", .kind = null },
        .{ .body = "func keep(static T: type, var t: T, var value: Pinned | none) int -> 42\nexit(keep(5, make(1)))", .kind = null },
        .{ .body = "func consume(static T: type, var t: T, deinit value: T | int) int\n  if const number: int = value -> return number\n  return 1\nexit(consume(Pinned{value = 1}, 42))", .kind = null },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ "struct Pinned\n  move = none\n  value: int\nfunc make(value: int) Pinned -> Pinned{value = value}\n", case.body });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        if (case.kind) |kind| try fixture.expectDiagnostic(0, kind) else try fixture.expectExit(0, 42);
    }
}

test "borrowed variant arguments construct through control flow" {
    const cases = [_]struct { expression: []const u8, zero_result: i32 = 0 }{
        .{ .expression = "if flag == 1 -> make(42) else none" },
        .{ .expression = "if flag == 1 -> producer(42) else none" },
        .{ .expression = "if flag == 1 -> Pinned{value = 42} else none" },
        .{ .expression = "if flag == 1 -> (if flag == 1 -> make(42) else none) else none" },
        .{ .expression = "loop\n    if flag == 1 -> break make(42)\n    break none\n  " },
        .{ .expression = "loop\n    break if flag == 1 -> make(42) else none\n  " },
        .{ .expression = "if flag == 1 -> existing else make(42)", .zero_result = 42 },
    };
    for (cases) |case| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  copy = func(imm self: Pinned) Pinned -> exit(90)
            \\  value: int
            \\  drop = func(deinit self: Pinned) -> ()
            \\func make(value: int) Pinned -> Pinned{{value = value}}
            \\func look(imm item: Pinned | none) int
            \\  if item is Pinned -> return 42
            \\  return 0
            \\func run(flag: int) int
            \\  const producer = make
            \\  const existing: Pinned | none = make(42)
            \\  const callee = look
            \\  return callee({s})
            \\static compiled = comptime -> run(1) + run(0)
            \\exit(run(1) + run(0) + compiled - 42 - {d})
        , .{ case.expression, 2 * case.zero_result });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
        try expectNoRelocation(fixture, "run");
    }
}

test "borrowed control flow cannot relocate narrower existing values" {
    const expressions = [_][]const u8{
        "if 1 == 1 -> pinned else none",
        "loop\n    if 1 == 1 -> break pinned\n    break none",
    };
    for (expressions) |expression| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\func look(imm item: Pinned | none) int -> 42
            \\const pinned = Pinned{{value = 42}}
            \\exit(look({s}))
        , .{expression});
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .relocation_requires_direct_move);
    }
}

test "borrowed argument widening preserves transfer rejection and owner cleanup" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\  move = none
        \\struct Movable
        \\  copy = none
        \\  value: int
        \\  drop = func(deinit self: Movable)
        \\    if self.value == 20 -> () else exit(90)
        \\    self.value = 50
        \\func make() Movable -> Movable{value = 20}
        \\func look(imm item: Movable | Pinned | none) int -> 42
        \\func run(flag: int) int
        \\  const existing = make()
        \\  return look(if flag == 1 -> existing else make())
        \\static compiled = comptime -> run(1) + run(0)
        \\exit(run(1) + run(0) + compiled - 126)
    , 42);

    const rejected = try Fixture.initFiles(
        \\struct Pinned
        \\  move = none
        \\func look(imm item: int | Pinned) int -> 42
        \\const number = 42
        \\exit(look(number^))
    , &.{});
    defer rejected.deinit();
    try rejected.expectDiagnostic(0, .ownership_transfer_requires_owning_context);
}

test "borrowed fresh control-flow temporaries clean up on later failure" {
    for ([_]u8{ 0, 1 }) |flag| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Pinned) -> exit(self.value)
            \\func make() Pinned -> Pinned{{value = 42}}
            \\func look(imm item: Pinned | none, marker: int) -> ()
            \\func absent() int | none -> none
            \\func run(flag: int) unit | none
            \\  look(if flag == 1 -> make() else none, (if const marker: int = absent() -> marker else return none))
            \\  return ()
            \\if run({d}) is unit -> exit(1) else exit(2)
        , .{flag});
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, if (flag == 1) 42 else 2);
    }
}

test "borrowed argument construction follows movability edits" {
    const source =
        \\struct Item
        \\  move = $move
        \\  value: int
        \\func make() Item -> Item{value = 42}
        \\func look(imm item: Item | none) int
        \\  if item is Item -> return 42
        \\  return 0
        \\func run() int
        \\  const existing = make()
        \\  return look(if 1 == 1 -> $result else none)
        \\static compiled = comptime -> run()
        \\exit(run() + compiled - 42)
    ;
    const cases = [_]struct { movement: []const u8, result: []const u8, rejects_relocation: bool = false }{
        .{ .movement = "fieldwise", .result = "existing" },
        .{ .movement = "none", .result = "existing", .rejects_relocation = true },
        .{ .movement = "none", .result = "make()" },
        .{ .movement = "fieldwise", .result = "make()" },
        .{ .movement = "none", .result = "make()" },
    };
    const fixture = try Fixture.initFiles("", &.{});
    defer fixture.deinit();
    for (cases) |case| {
        const edited = try test_sources.renderTemplate(testing.allocator, source, .{ .move = case.movement, .result = case.result });
        defer testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        if (case.rejects_relocation) try fixture.expectDiagnostic(0, .relocation_requires_direct_move) else try fixture.expectExit(0, 42);
    }
}

test "borrowed conditional arguments view their source storage" {
    const fixture = try Fixture.initFiles(
        \\struct Pinned
        \\  move = none
        \\  copy = func(imm self: Pinned) Pinned -> exit(90)
        \\  value: int
        \\func look(imm pinned: Pinned) int -> pinned.value
        \\func run(flag: int) int
        \\  const first = Pinned{value = 40}
        \\  const second = Pinned{value = 2}
        \\  return look(if flag == 1 -> first else second) + look(if flag == 0 -> first else second)
        \\exit(run(1))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try expectNoRelocation(fixture, "run");
}

test "mutable locals that cannot move directly keep their storage" {
    const fixture = try Fixture.initFiles(
        \\struct Tracked
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> ()
        \\struct Pair
        \\  first: Tracked
        \\  count: int
        \\func make(value: int) Tracked -> Tracked{value = value}
        \\func bump(mut tracked: Tracked)
        \\  tracked.value += 1
        \\func reset(mut tracked: Tracked)
        \\  tracked = make(10)
        \\func count(mut value: int)
        \\  value += 1
        \\func run() int
        \\  var pair = Pair{first = make(0), count = 0}
        \\  var index = 0
        \\  loop
        \\    index += 1
        \\    bump(pair.first)
        \\    count(pair.count)
        \\    if index == 3 -> reset(pair.first)
        \\    if index == 5
        \\      const current = pair.first.value
        \\      pair.first = make(pair.count + current)
        \\      break
        \\  var single = make(1)
        \\  bump(single)
        \\  single.value += 10
        \\  const current = single.value
        \\  single = make(current - 3)
        \\  return pair.first.value + single.value + 16
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try expectNoRelocation(fixture, "run");
    try expectNoRelocation(fixture, "bump");
    try expectNoRelocation(fixture, "reset");
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = fixture.db };
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.block_arguments) |argument| try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(argument.type_id));
}

test "replacement requiring destination construction ends the old value before the right-hand side" {
    const cases = [_]struct { body: []const u8, kind: ?std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .body = "var tracked = make(1)\ntracked = make(tracked.value)\nexit(tracked.value)", .kind = .replaced_value_used },
        .{ .body = "var pair = Pair{first = make(1), count = 2}\npair.first = make(pair.first.value)\nexit(1)", .kind = .replaced_value_used },
        .{ .body = "var pair = Pair{first = make(1), count = 2}\npair.first = make(helper(pair))\nexit(1)", .kind = .replaced_value_used },
        .{ .body = "func refill(mut tracked: Tracked)\n  tracked = make(tracked.value)\nvar tracked = make(1)\nrefill(tracked)\nexit(1)", .kind = .replaced_value_used },
        .{ .body = "var pair = Pair{first = make(1), count = 41}\npair.first = make(pair.count + 1)\nexit(pair.first.value)", .kind = null },
        .{ .body = "var tracked = make(20)\nconst previous = tracked.value\ntracked = make(previous + 22)\nexit(tracked.value)", .kind = null },
        .{ .body = "var moved = Moved{value = 40}\nconst old = moved^\nmoved = next(old^)\nexit(moved.value)", .kind = null },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            \\struct Tracked
            \\  move = none
            \\  value: int
            \\struct Pair
            \\  first: Tracked
            \\  count: int
            \\struct Moved
            \\  value: int
            \\  move = func(deinit self: Moved) Moved -> Moved{value = self.value + 1}
            \\func make(value: int) Tracked -> Tracked{value = value}
            \\func helper(imm pair: Pair) int -> pair.count
            \\func next(var moved: Moved) Moved -> Moved{value = moved.value}
            \\
            ,
            case.body,
        });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        if (case.kind) |kind| try fixture.expectDiagnostic(0, kind) else try fixture.expectExit(0, 42);
    }
}

test "in-place replacement ends the old value before constructing the new one" {
    const cases = [_]struct { body: []const u8, status: u8 }{
        .{ .body = "var tracked = Tracked{value = 42}\ntracked = noisy()", .status = 42 },
        .{ .body = "var pair = Pair{first = Tracked{value = 42}, count = 1}\npair.first = noisy()", .status = 42 },
        .{ .body = "var pair = Pair{first = Tracked{value = 42}, count = 1}\npair = Pair{first = noisy(), count = 2}", .status = 42 },
        .{ .body = "var tracked = Tracked{value = 42}\nreset(tracked)", .status = 42 },
        .{ .body = "var pair = Pair{first = Tracked{value = 42}, count = 1}\nreset(pair.first)", .status = 42 },
        .{ .body = "var tracked = Tracked{value = 7}\nvar index = 0\nloop\n  index += 1\n  if index == 3 -> break\n  tracked = Tracked{value = 40 + index}", .status = 7 },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            \\struct Tracked
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Tracked) -> exit(self.value)
            \\struct Pair
            \\  first: Tracked
            \\  count: int
            \\func noisy() Tracked -> exit(1)
            \\func reset(mut tracked: Tracked)
            \\  tracked = noisy()
            \\
            ,
            case.body,
            "\nexit(2)",
        });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, case.status);
    }
}

test "mutable parameters replaced in loops end each earlier value once" {
    for ([_][]const u8{ "move = none", "copy = none" }) |movement| {
        const source = try testing.allocator.print(
            \\struct Tracked
            \\  {s}
            \\  value: int
            \\  drop = func(deinit self: Tracked)
            \\    if self.value == 50 -> exit(50)
            \\    self.value = 50
            \\func make(value: int) Tracked -> Tracked{{value = value}}
            \\func refill(mut tracked: Tracked, count: int)
            \\  var index = 0
            \\  loop
            \\    index += 1
            \\    if index > count -> break
            \\    tracked = make(index + 39)
            \\func run(count: int) int
            \\  var tracked = make(7)
            \\  refill(tracked, count)
            \\  return tracked.value
            \\exit(run(3) - run(0) + 7)
        , .{movement});
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "a right-hand side that leaves early leaves the replaced place ended once" {
    const cases = [_]struct { body: []const u8, kind: ?std.meta.Tag(structures.Diagnostic.Kind) = null, status: u8 = 0 }{
        .{ .body = "func run(c: int) int\n  var pair = Pair{first = make(1), count = 7}\n  pair.first = if c == 1 -> make(2) else return pair.count\n  return pair.first.value\nexit(run(1) * 10 + run(0))", .status = 27 },
        .{ .body = "func run(c: int) int\n  var tracked = make(1)\n  tracked = if c == 1 -> make(2) else return 7\n  return tracked.value\nexit(run(1) * 10 + run(0))", .status = 27 },
        .{ .body = "func run(c: int) int | none\n  var pair = Pair{first = make(1), count = 3}\n  pair.first = if c > 0 -> Tracked{value = c} else return none\n  return pair.first.value\nif const result: int = run(0) -> exit(result) else exit(3)", .status = 3 },
        .{ .body = "func run(c: int) int\n  var pair = Pair{first = make(1), count = 3}\n  var index = 0\n  loop\n    index += 1\n    pair.first = if index == c -> break else make(index + 1)\n    if index == 5 -> break\n  return pair.count\nexit(run(1))", .status = 3 },
        .{ .body = "func reset(mut tracked: Tracked, c: int)\n  tracked = if c == 1 -> make(2) else return\nvar tracked = make(1)\nreset(tracked, 0)\nexit(1)", .kind = .replaced_value_used },
        .{ .body = "func reset(mut tracked: Tracked, c: int)\n  var index = 0\n  loop\n    index += 1\n    tracked = if index == c -> break else make(index)\n    if index == 3 -> break\nvar tracked = make(1)\nreset(tracked, 1)\nexit(1)", .kind = .possibly_transferred },
        .{ .body = "func run(c: int) int\n  var tracked = make(1)\n  var index = 0\n  loop\n    index += 1\n    tracked = if index == c -> break else make(index)\n    if index == 5 -> break\n  return tracked.value\nexit(run(1))", .kind = .possibly_transferred },
        .{ .body = "import std.memory\nfunc run() int\n  var pair = Pair{first = make(20), count = 1}\n  const first = Ref.from(pair.first)\n  pair.first = make(first.value.value + 22)\n  return pair.first.value\nexit(run())", .kind = .borrow_outlives_source },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            \\struct Tracked
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Tracked)
            \\    if self.value == 50 -> exit(50)
            \\    self.value = 50
            \\struct Pair
            \\  first: Tracked
            \\  count: int
            \\func make(value: int) Tracked -> Tracked{value = value}
            \\func checked(value: int) Tracked | none
            \\  if not (value > 0) -> return none
            \\  return Tracked{value = value}
            \\
            ,
            case.body,
        });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        if (case.kind) |kind| try fixture.expectDiagnostic(0, kind) else try fixture.expectExit(0, case.status);
    }
}

test "joins place copies of existing values without early cleanup" {
    const declarations =
        \\struct Tracked
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 50 -> exit(50)
        \\    self.value = 50
        \\func make(value: int) Tracked -> Tracked{value = value}
        \\func look(imm tracked: Tracked) int -> tracked.value
        \\func bind(c: int) int
        \\  const a = make(1)
        \\  const b = if c == 1 -> a else make(2)
        \\  return b.value * 10 + a.value
        \\func select(n: int) int
        \\  const a = make(1)
        \\  var index = 0
        \\  const b: Tracked = loop
        \\    index += 1
        \\    if index == n -> break a
        \\    if index == 5 -> break make(3)
        \\  return b.value * 10 + a.value
        \\func early(c: int) Tracked
        \\  const a = make(4)
        \\  const b = if c == 1
        \\    return a
        \\  else
        \\    make(2)
        \\  return make(b.value + 3)
        \\func borrowed(c: int) int
        \\  const a = make(1)
        \\  return look(if c == 1 -> a else make(2)) * 10 + a.value
        \\func total() int -> bind(1) + bind(0) + select(2) + select(7) + early(1).value + early(0).value + borrowed(1) + borrowed(0)
    ;
    const cases = [_]struct { expression: []const u8, expected: u8 }{
        .{ .expression = "bind(1)", .expected = 11 },
        .{ .expression = "bind(0)", .expected = 21 },
        .{ .expression = "select(2)", .expected = 11 },
        .{ .expression = "select(7)", .expected = 31 },
        .{ .expression = "early(1).value", .expected = 4 },
        .{ .expression = "early(0).value", .expected = 5 },
        .{ .expression = "borrowed(1)", .expected = 11 },
        .{ .expression = "borrowed(0)", .expected = 21 },
        .{ .expression = "total()", .expected = 115 },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ declarations, "\nfunc run() int -> ", case.expression });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, case.expected);
    }
}

test "variant copies and transfers construct member by member" {
    const fixture = try Fixture.initFiles(
        \\struct Counted
        \\  value: int
        \\  copy = func(imm self: Counted) Counted -> Counted{value = self.value + 1}
        \\  move = func(deinit self: Counted) Counted -> Counted{value = self.value + 10}
        \\struct Pinned
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\func widen() int
        \\  const small: Counted | none = Counted{value = 0}
        \\  const copied: Counted | none | int = small
        \\  var source: Counted | none = Counted{value = 0}
        \\  const moved: Counted | none | int = source^
        \\  var total = 0
        \\  if const counted: Counted = copied -> total += counted.value
        \\  if const counted: Counted = moved -> total += counted.value
        \\  return total
        \\func narrow() int
        \\  const wide: Counted | Pinned | none = Pinned{value = 20}
        \\  if const narrowed: Counted | Pinned = wide
        \\    if const pinned: Pinned = narrowed -> return pinned.value
        \\  return 0
        \\exit(widen() + narrow())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 33);
    try expectNoRelocation(fixture, "widen");
    try expectNoRelocation(fixture, "narrow");
}

test "variant storage changes its immovable member during compile-time execution" {
    try Fixture.expectSourceExit(
        \\struct First
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\struct Second
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\func run() int
        \\  var item: First | Second = First{value = 2}
        \\  var total = 0
        \\  if const first: First = item -> total += first.value
        \\  item = Second{value = 30}
        \\  if const second: Second = item -> total += second.value
        \\  item = First{value = 10}
        \\  if const first: First = item -> total += first.value
        \\  return total
        \\static compiled = comptime -> run()
        \\exit(run() + compiled - 42)
    , 42);
}

test "inferred factories construct fields from their static types in order" {
    const fixture = try Fixture.initFiles(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\struct Holder(T: type)
        \\  item: T
        \\  count: int
        \\func step(mut order: int, expected: int) int
        \\  if not (order == expected) -> panic "unexpected order"
        \\  order += 1
        \\  return order
        \\func make(mut order: int, expected: int) Pinned -> Pinned{value = step(order, expected)}
        \\func run() int | none
        \\  var order = 0
        \\  const holder = Holder{item = make(order, 0), count = step(order, 1)}
        \\  return holder.item.value + holder.count + 39
        \\if const result: int = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try expectNoRelocation(fixture, "run");
}

test "fields end in place when a join transfers them on another path" {
    const cases = [_][]const u8{ "move = func(deinit self: Item) Item -> exit(90)", "move = none" };
    for (cases) |movement| {
        const source = try testing.allocator.print(
            \\struct Item
            \\  value: int
            \\  {s}
            \\  drop = func(deinit self: Item) -> exit(self.value)
            \\struct Holder
            \\  item: Item
            \\  count: int
            \\func take(deinit item: Item) -> ()
            \\func finish(deinit holder: Holder, flag: int) int
            \\  if flag == 1 -> take(holder.item)
            \\  return 7
            \\exit(finish(Holder{{item = Item{{value = 42}}, count = 2}}, 0))
        , .{movement});
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "borrowed standard results copy into a destination" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\func run() int | none
        \\  const owner: Box(Pinned) = Box(Pinned).new(Pinned{value = 42}) else return none
        \\  const copied: Pinned = (Ref.from(owner.borrow())).value
        \\  return copied.value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "compile-time field reads skip unfinished sibling construction" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\  move = none
        \\  first: int
        \\  second: int
        \\struct Holder
        \\  item: Pinned | none
        \\  count: int
        \\struct Outer
        \\  holder: Holder
        \\func run(flag: int) int
        \\  var outer = Outer{holder = Holder{item = none, count = 42}}
        \\  loop
        \\    outer.holder.item = Pinned{first = 7, second = if flag == 1 -> break else 2}
        \\    break
        \\  return outer.holder.count
        \\static compiled = comptime -> run(1) + run(0)
        \\exit(run(1) + run(0) + compiled - 126)
    , 42);
}

test "compile-time joins preserve storage identity before later writes" {
    const selections = [_][]const u8{
        "if 1 == 1 -> item else other",
        "(loop\n    if 1 == 1 -> break item\n    break other\n  )",
    };
    for (selections) |selection| {
        const source = try testing.allocator.print(
            \\struct Pinned
            \\  move = none
            \\  copy = none
            \\  value: int
            \\func make() Pinned -> Pinned{{value = 20}}
            \\func look(imm item: Pinned, marker: int) int -> item.value
            \\func from_result() int
            \\  var item = make()
            \\  const other = make()
            \\  return look({s}, if 1 == 1
            \\    item.value = 42
            \\    0
            \\  else 0)
            \\func from_parameter(mut item: Pinned) int
            \\  const other = make()
            \\  return look({s}, if 1 == 1
            \\    item.value = 42
            \\    0
            \\  else 0)
            \\func run() int
            \\  var item = make()
            \\  return from_result() + from_parameter(item)
            \\static compiled = comptime -> run()
            \\exit(run() + compiled - 126)
        , .{ selection, selection });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "compile-time execution updates storage in place" {
    try Fixture.expectSourceExit(
        \\struct Tracked
        \\  move = none
        \\  value: int
        \\struct Pair
        \\  first: Tracked
        \\  count: int
        \\func make(value: int) Tracked -> Tracked{value = value}
        \\func bump(mut tracked: Tracked)
        \\  tracked.value += 1
        \\func look(imm tracked: Tracked) int -> tracked.value
        \\func run() int
        \\  var pair = Pair{first = make(0), count = 0}
        \\  var index = 0
        \\  loop
        \\    index += 1
        \\    bump(pair.first)
        \\    pair.count += 1
        \\    if index == 3 -> break
        \\  pair.first = make(pair.count + 30)
        \\  const other = make(9)
        \\  return look(if index == 3 -> pair.first else other) + look(pair.first) - 24
        \\struct A
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\struct B
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\func switch_member() int
        \\  var either: A | B = A{value = 1}
        \\  var total = 0
        \\  if const a: A = either -> total += a.value
        \\  either = B{value = 40}
        \\  if const b: B = either -> total += b.value
        \\  return total + 1
        \\static result = comptime -> run() + switch_member()
        \\exit(result + run() + switch_member() - 126)
    , 42);
}

test "in-place construction failure cleans completed results" {
    const cases = [_][]const u8{
        \\func build(value: int) Pair | none -> Pair{first = Tracked{value = 42}, second = if value > 0 -> Tracked{value = value} else return none}
        \\if (build(0) is Pair) -> exit(1) else exit(2)
        ,
        \\func run() int | none
        \\  const tracked = checked(42)
        \\  return 1
        \\if const result: int = run() -> exit(result) else exit(2)
        ,
        \\func run() int | none
        \\  if const tracked: Tracked = checked(42) -> return 1
        \\  return 2
        \\if const result: int = run() -> exit(result) else exit(3)
        ,
    };
    for (cases) |body| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            \\struct Tracked
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Tracked) -> exit(self.value)
            \\struct Pair
            \\  first: Tracked
            \\  second: Tracked
            \\func checked(value: int) Tracked | none
            \\  if not (value > 0) -> return none
            \\  return Tracked{value = value}
            \\
            ,
            body,
        });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "compile-time execution constructs results in their destinations" {
    try Fixture.expectSourceExit(
        \\struct Cell
        \\  value: int
        \\  move = func(deinit self: Cell) Cell -> Cell{value = self.value + 100}
        \\struct Pair
        \\  first: Cell
        \\  second: Cell | none
        \\func make(value: int) Cell -> Cell{value = value}
        \\func build(flag: int) Pair -> Pair{first = make(20), second = if flag == 1 -> make(22) else none}
        \\func total(imm pair: Pair) int
        \\  if pair.second is Cell -> return pair.first.value + 22
        \\  return pair.first.value
        \\func run() int
        \\  const pair = build(1)
        \\  const maybe: Cell | none = make(0)
        \\  if maybe is Cell -> return total(pair)
        \\  return 0
        \\static result = comptime -> run()
        \\exit(result + run() - 42)
    , 42);
}

test "Box in-place construction infers immovable element type" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box.new(Immovable{value = 42}) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "Box constructs generated immovable structs without temporary values" {
    try Fixture.expectSourceExit(
        \\struct Container(T: type)
        \\  move = none
        \\  value: T
        \\func run() unit | none
        \\  const owner: Box(Container(int)) = Box.new(Container{value = 42}) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "Box constructs nested immovable fields in final storage" {
    try Fixture.expectSourceExit(
        \\struct Inner
        \\  move = none
        \\  prefix: byte
        \\  value: int
        \\  drop = func(deinit self: Inner) -> exit(self.value)
        \\struct Outer
        \\  move = none
        \\  prefix: int
        \\  inner: Inner
        \\func run() unit | none
        \\  const owner: Box(Outer) = Box.new(Outer{prefix = 7, inner = Inner{prefix = 3, value = 42}}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "an ignored func immovable result still receives return storage" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make() Immovable | none -> Immovable{value = 42}
        \\if (make() is Immovable) -> exit(42) else exit(1)
    , 42);
}

test "Box constructs an immovable function result in final storage" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make() Immovable -> Immovable{value = 42}
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(make()) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box infers an immovable function result and evaluates arguments once" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make(value: int) Immovable -> Immovable{value = value}
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box.new(make(42)) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box constructs an immovable indirect function result in final storage" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make(value: int) Immovable -> Immovable{value = value}
        \\func run() unit | none
        \\  const producer = make
        \\  const owner = Box.new(producer(42))
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box retains explicit optional producer results in place" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make(value: int) Immovable | none
        \\  if not (value == 42) -> return none
        \\  return Immovable{value = value}
        \\func run(value: int) unit | none
        \\  const producer = make
        \\  const owner: Box(Immovable | none) = Box(Immovable | none).new(producer(value)) else return none
        \\  if owner.borrow() is none -> return none
        \\  return ()
        \\if (run(7) is unit) -> exit(2) else if (run(42) is unit) -> exit(3) else exit(4)
    , 42);
}

test "Box allocation failure rejects an unhandled explicit-drop producer argument" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make(deinit resource: Allocation(int)) Immovable
        \\  deallocate(int, resource^)
        \\  return Immovable{value = 42}
        \\func run() unit | none
        \\  var resource: Allocation(int) = allocate(int, 1) else return none
        \\  const owner: Box(Immovable) = Box.new(make(resource^)) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , .value_requires_explicit_drop);
}

test "Box allocation failure skips fresh producer arguments" {
    const fixture = try Fixture.initFiles(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(90)
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make(deinit item: Tracked) Immovable -> Immovable{value = item.value}
        \\func forbidden() int -> exit(91)
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box.new(make(Tracked{value = forbidden()})) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(42)
    , &.{});
    defer fixture.deinit();
    try replaceAllocationSource(fixture, "var storage: Allocation(T) = allocate(T, 1) else return none", "var storage: Allocation(T) = allocate(T, -1) else return none");
    try fixture.expectExit(0, 42);
}

test "ignored func immovable result still has return storage" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make() Immovable | none -> return Immovable{value = 42}
        \\if (make() is Immovable) -> exit(42) else exit(1)
    , 42);
}

test "Box constructs conditional immovable literals without temporary values" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func run(value: int) unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(if value == 42 -> Immovable{value = 42} else Immovable{value = 7}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run(42) is unit) -> exit(2) else exit(3)
    , 42);
}

test "conditional Box construction works in an if condition" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\if (Box.new(if 1 == 1 -> Immovable{value = 42} else Immovable{value = 0}) is Box(Immovable)) -> exit(42) else exit(1)
    , 42);
}

test "Box infers the result of conditional immovable literals" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func run(value: int) unit | none
        \\  const owner = Box.new(if value == 42 -> Immovable{value = 42} else Immovable{value = 7})
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run(42) is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box infers nested immovable fields without temporary values" {
    try Fixture.expectSourceExit(
        \\struct Inner
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Inner) -> exit(self.value)
        \\struct Container(T: type)
        \\  move = none
        \\  item: T
        \\func run() unit | none
        \\  const owner: Box(Container(Inner)) = Box.new(Container{item = Inner{value = 42}}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "inferred nested Box initialization cleans up leaves before later fields" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Inner
        \\  move = none
        \\  leaf: Tracked
        \\struct Container(T: type)
        \\  move = none
        \\  item: T
        \\  later: int
        \\func fail_value() int | none
        \\  const storage: Allocation(int) = allocate(int, -1) else return none
        \\  deallocate(int, storage^)
        \\  return 1
        \\func run() unit | none
        \\  const owner: Box(Container(Inner)) = Box.new(Container{item = Inner{leaf = Tracked{value = 42}}, later = (if const _selected_result_0: int = fail_value() -> _selected_result_0 else panic "unexpected none")}) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "nested in-place Box initialization cleans up leaves on failure" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Inner
        \\  move = none
        \\  leaf: Tracked
        \\struct Outer
        \\  move = none
        \\  inner: Inner
        \\  later: int
        \\func fail_value() int | none
        \\  const storage: Allocation(int) = allocate(int, -1) else return none
        \\  deallocate(int, storage^)
        \\  return 1
        \\func run() unit | none
        \\  const owner: Box(Outer) = Box.new(Outer{inner = Inner{leaf = Tracked{value = 42}}, later = (if const _selected_result_0: int = fail_value() -> _selected_result_0 else panic "unexpected none")}) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "Box drops an owned field inside an immovable struct" {
    try Fixture.expectSourceExit(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: Box(Resource)
        \\func run() unit | none
        \\  const inner: Box(Resource) = Box.new(Resource{value = 42}) else return none
        \\  const outer: Box(Immovable) = Box(Immovable).new(Immovable{field = inner^}) else return none
        \\  _ = outer
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box drops nested owners with the same specialization" {
    try Fixture.expectSourceExit(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Node
        \\  move = none
        \\  resource: Resource
        \\  next: Box(Node) | none
        \\func run() unit | none
        \\  const inner: Box(Node) = Box(Node).new(Node{resource = Resource{value = 42}, next = none}) else return none
        \\  const outer: Box(Node) = Box(Node).new(Node{resource = Resource{value = 1}, next = inner^}) else return none
        \\  _ = outer
        \\  exit(2)
        \\  return ()
        \\if (run() is unit) -> exit(3) else exit(4)
    , 42);
}

test "Box destructor follows immovable field edits" {
    const original =
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: Resource
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{field = Resource{value = 42}}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    ;
    const fixture = try Fixture.initFiles(original, &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0,
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: int
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{field = 42}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    );
    try fixture.expectExit(0, 1);
    try fixture.db.setInput(queries.SourceText, 0, original);
    try fixture.expectExit(0, 42);
}

test "immovable Box from a conditional binding drops on the success path" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\if const owner: Box(Immovable) = Box(Immovable).new(Immovable{value = 42})
        \\  _ = owner
        \\  exit(1)
        \\else exit(2)
    , 42);
}

test "zero-sized immovable Box destroys its value" {
    try Fixture.expectSourceExit(
        \\struct Immovable
        \\  move = none
        \\  drop = func(deinit self: Immovable) -> exit(42)
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box in-place initializer cleans up fields when a later field fails" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  first: Tracked
        \\  second: int
        \\func fail_value() int | none
        \\  const storage: Allocation(int) = allocate(int, -1) else return none
        \\  deallocate(int, storage^)
        \\  return 7
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{first = Tracked{value = 42}, second = (if const _selected_result_0: int = fail_value() -> _selected_result_0 else panic "unexpected none")}) else return none
        \\  _ = owner
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
    , 42);
}

test "Box rejects noncopyable places and explicit-drop elements" {
    const cases = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\const original = Immovable{value = 42}
        \\if (Box(Immovable).new(original) is Box(Immovable)) -> exit(1) else exit(2)
        , .diagnostic = .type_not_copyable },
        .{ .source =
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\if (Box(Explicit).new(Explicit{value = 42}) is Box(Explicit)) -> exit(1) else exit(2)
        , .diagnostic = .box_requires_automatic_drop },
        .{ .source =
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\if (Box.new(Explicit{value = 42}) is Box(Explicit)) -> exit(1) else exit(2)
        , .diagnostic = .box_requires_automatic_drop },
        .{ .source =
        \\import std.memory.{take}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func run() unit | none
        \\  const owner: Box(Immovable) = Box(Immovable).new(Immovable{value = 42}) else return none
        \\  const extracted = take(Immovable, owner^)
        \\  _ = extracted
        \\  return ()
        \\if (run() is unit) -> exit(1) else exit(2)
        , .diagnostic = .box_extraction_requires_direct_move },
    };
    for (cases) |case| {
        const fixture = try Fixture.initFiles(case.source, &.{});
        defer fixture.deinit();
        if (case.diagnostic == .type_not_copyable)
            try fixture.expectDiagnostic(0, case.diagnostic)
        else
            try fixture.expectLibraryDiagnostic(case.diagnostic);
    }
}

test "Box transfers its value and releases its allocation" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func take() unit | none
        \\  const owner: Box(int) = Box(int).new(42) else return none
        \\  const number = std.memory.take(int, owner^)
        \\  if not (number == 42) -> return none
        \\  return ()
        \\if (take() is unit) -> exit(42) else exit(1)
    , 42);
}

test "zero-sized Box supports consuming extraction" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func take() unit | none
        \\  const owner: Box(unit) = Box.new(()) else return none
        \\  _ = (if const _selected_result_0: unit = std.memory.take(unit, owner^) -> _selected_result_0 else return none)
        \\  return ()
        \\if (take() is unit) -> exit(42) else exit(1)
    , 42);
}

test "Box transfers an aggregate value" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\struct Pair
        \\  first: int
        \\  second: byte
        \\func take() unit | none
        \\  const owner: Box(Pair) = Box.new(Pair{first = 42, second = 7}) else return none
        \\  const pair = std.memory.take(Pair, owner^)
        \\  if not (pair.first == 42) -> return none
        \\  return ()
        \\if (take() is unit) -> exit(42) else exit(1)
    , 42);
}

test "Box can own and transfer another Box" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func take() unit | none
        \\  const inner: Box(int) = Box.new(42) else return none
        \\  const outer: Box(Box(int)) = Box(Box(int)).new(inner^) else return none
        \\  const moved = std.memory.take(Box(int), outer^)
        \\  const number = std.memory.take(int, moved^)
        \\  if not (number == 42) -> return none
        \\  return ()
        \\if (take() is unit) -> exit(42) else exit(1)
    , 42);
}

test "zero-sized Box destroys its initialized value on last use" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Box}
        \\struct Empty
        \\  drop = func(deinit self: Empty) -> exit(42)
        \\func run() unit | none
        \\  const owner: Box(Empty) = Box(Empty).new(Empty{}) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "prelude exports Box and its constructor without exporting raw allocation" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func take() unit | none
        \\  const owner: Box(int) = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\  const number = std.memory.take(int, owner^)
        \\  if not (number == 42) -> return none
        \\  return ()
        \\if (take() is unit) -> exit(42) else exit(1)
    , 42);

    const raw = try Fixture.initFiles(
        \\func use_storage() unit | none
        \\  const storage: Allocation(int) = allocate(int, 1) else return none
        \\  return ()
        \\if (use_storage() is unit) -> exit(42) else exit(1)
    , &.{});
    defer raw.deinit();
    try raw.expectDiagnostic(0, .unknown_function);

    const retired = try Fixture.initFiles("if make_ref(42) -> exit(1) else exit(2)", &.{});
    defer retired.deinit();
    try retired.expectDiagnostic(0, .unknown_function);
}

test "generic struct initializer infers type from Box field" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Box}
        \\struct Foo(T: type)
        \\  r: Box(T)
        \\func run() unit | none
        \\  const f = Foo{r = (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)}
        \\  _ = f
        \\  return ()
        \\if (run() is unit) -> exit(42) else exit(1)
    , 42);
}

test "func condition binding initializes an inferred struct field" {
    try Fixture.expectSourceExit(
        \\struct Foo(T: type)
        \\  r: Box(T)
        \\const f = Foo{r = if const owner: Box(int) = Box.new(42) -> owner^ else exit(1)}
        \\_ = f
        \\exit(42)
    , 42);
}

test "func condition binding owns its Box on success" {
    const success = try Fixture.initFiles(
        \\import std.memory.{take}
        \\if const owner: Box(int) = Box.new(42) -> exit(take(int, owner^)) else exit(1)
    , &.{});
    defer success.deinit();
    try success.expectExit(0, 42);

    const failure = try Fixture.initFiles(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func invalid_ref() Box(int) | none
        \\  const allocation: Allocation(int) = allocate(int, -1) else return none
        \\  deallocate(int, allocation^)
        \\  return (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\if const owner: Box(int) = invalid_ref() -> exit(1) else exit(42)
    , &.{});
    defer failure.deinit();
    try failure.expectExit(0, 42);
}

test "custom copies and moves retain all possible field origins" {
    const source =
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> ()
        \\struct Pair
        \\  first: Ref(Item)
        \\  second: Ref(Item)
        \\  $hook
        \\    return Pair{first = self.second, second = self.first}
        \\func run() int
        \\  var first_owner: Box(Item) = Box.new(Item{value = 17}) else panic "unexpected allocation refusal"
        \\  var second_owner: Box(Item) = Box.new(Item{value = 23}) else panic "unexpected allocation refusal"
        \\  var first = Ref.from(first_owner.borrow())
        \\  var second = Ref.from(second_owner.borrow())
        \\  const source = Pair{first = first, second = second}
        \\  const copied = $operand
        \\  const handle = copied.first
        \\  $replacement
        \\  return handle.value.value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    inline for (.{
        .{ .hook = "copy = func(imm self: Pair) Pair", .operand = "source" },
        .{ .hook = "move = func(deinit self: Pair) Pair", .operand = "source^" },
    }) |case| {
        inline for (.{ false, true }) |replace_owner| {
            const edited = try test_sources.renderTemplate(testing.allocator, source, .{
                .hook = case.hook,
                .operand = case.operand,
                .replacement = if (replace_owner) "second_owner = (if const _selected_result_0: Box(Item) = Box.new(Item{value = 42}) -> _selected_result_0^ else panic \"unexpected none\")" else "",
            });
            defer testing.allocator.free(edited);
            const fixture = try Fixture.initFiles(edited, &.{});
            defer fixture.deinit();
            if (replace_owner) try fixture.expectDiagnostic(0, .borrow_outlives_source) else try fixture.expectExit(0, 23);
        }
    }
}

test "nested struct updates and mutable calls preserve copied snapshots" {
    try Fixture.expectParity(
        \\struct Inner
        \\    first: int
        \\    second: int
        \\    copy = fieldwise
        \\struct Outer
        \\    inner: Inner
        \\    marker: int
        \\    copy = fieldwise
        \\func change(mut value: int)
        \\    value = value + 2
        \\func run() int
        \\    var item = Outer{inner = Inner{first = 18, second = 1}, marker = 2}
        \\    const before = item
        \\    item.inner.second = 2
        \\    change(item.inner.first)
        \\    return before.inner.first + item.inner.first + item.inner.second + item.marker
    , 42);
}

test "four byte aggregates return through direct and indirect calls" {
    try Fixture.expectSourceExit(
        \\struct Quad
        \\  first: byte
        \\  second: byte
        \\  third: byte
        \\  fourth: byte
        \\func make() Quad -> Quad{first = 1, second = 2, third = 3, fourth = 4}
        \\const direct = make()
        \\const callback = make
        \\const indirect = callback()
        \\_ = direct
        \\_ = indirect
        \\exit(42)
    , 42);
}

test "conditional reference copies preserve live origins and reject replaced owners" {
    for ([_][]const u8{ "reference", "Ref.from(owner.borrow())" }) |first| {
        for ([_]bool{ false, true }) |replace_owner| {
            const source = try testing.allocator.print(
                \\func run() int
                \\  var owner: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
                \\  const reference = Ref.from(owner.borrow())
                \\  const selected = if 1 == 1 -> {s} else reference
                \\  {s}
                \\  return selected.value
                \\if const result = run() -> exit(result) else exit(1)
            , .{ first, if (replace_owner) "owner = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else panic \"unexpected none\")" else "_ = reference" });
            defer testing.allocator.free(source);
            const fixture = try Fixture.initFiles(source, &.{});
            defer fixture.deinit();
            if (replace_owner) try fixture.expectDiagnostic(0, .borrow_outlives_source) else try fixture.expectExit(0, 42);
        }
    }
}

test "partial variant copies retain reference origins" {
    const cases = [_]struct { condition: []const u8, replace: []const u8, expected: ?u8 }{
        .{ .condition = "1 == 1", .replace = "", .expected = 42 },
        .{ .condition = "1 == 0", .replace = "", .expected = 0 },
        .{ .condition = "1 == 1", .replace = "owner = (if const _selected_result_0: Box(int) = Box.new(17) -> _selected_result_0^ else panic \"unexpected none\")", .expected = null },
    };
    for (cases) |case| {
        const source = try testing.allocator.print(
            \\func run() int
            \\  var owner: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
            \\  const reference = Ref.from(owner.borrow())
            \\  const selected = if {s} -> reference else Box.new(17)
            \\  {s}
            \\  return if const handle: Ref(int) = selected -> handle.value else 0
            \\if const result = run() -> exit(result) else exit(1)
        , .{ case.condition, case.replace });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        if (case.expected) |expected| try fixture.expectExit(0, expected) else try fixture.expectDiagnostic(0, .borrow_outlives_source);
    }
}

test "implicit drop effects retain reference parameter identities" {
    const source =
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> ()
        \\struct Guard
        \\  target: Ref(Item)
        \\  drop = func(deinit self: Guard)
        \\    self.target.value = Item{value = 42}
        \\func observe(imm previous: Item, marker: int) int -> previous.value
        \\func inspect(var reference: Ref(Item)) int
        \\  return observe(reference.value, if 1 == 1
        \\    const guard = Guard{target = reference}
        \\    0
        \\  else 0)
        \\func run() int | none
        \\  var owner: Box(Item) = Box.new(Item{value = 17}) else return none
        \\  return inspect(Ref.from(owner.borrow()))
        \\if const result: int = run() -> exit(result) else exit(1)
    ;
    const fixture = try Fixture.initFiles(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
    const repaired = try std.mem.replaceOwned(u8, testing.allocator, source, "observe(reference.value,", "observe(Item{value = 17},");
    defer testing.allocator.free(repaired);
    try fixture.db.setInput(queries.SourceText, 0, repaired);
    try fixture.expectExit(0, 17);
}

test "implicit drop effects invalidate pending expression borrows" {
    const header =
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> ()
        \\struct Replacer
        \\  target: Ref(Item)
        \\  drop = func(deinit self: Replacer)
        \\    self.target.value = Item{value = 42}
        \\struct Wrapper
        \\  guard: Replacer
        \\func observe(imm previous: Item, marker: int) int -> previous.value
        \\func run() int | none
        \\  var owner: Box(Item) = Box.new(Item{value = 17}) else return none
        \\  var reference = Ref.from(owner.borrow())
    ;
    const cases = [_]struct { before: []const u8, after: []const u8, expected: ?u8 }{
        .{ .before = "  return observe(reference.value, if 1 == 1\n", .after = "    0\n  else 0)\n", .expected = null },
        .{ .before = "  const marker = if 1 == 1\n", .after = "    0\n  else 0\n  return observe(reference.value, marker)\n", .expected = 42 },
        .{ .before = "  return if 1 == 1 -> observe(reference.value, 0) else\n", .after = "    0\n", .expected = 17 },
    };
    for ([_][]const u8{
        "Replacer{target = reference}",
        "Wrapper{guard = Replacer{target = reference}}",
        "(if const _selected_result_0: Box(Replacer) = Box.new(Replacer{target = reference}) -> _selected_result_0^ else panic \"unexpected none\")",
        "if 1 == 1 -> Replacer{target = reference} else Replacer{target = reference}",
        "loop -> break Replacer{target = reference}",
    }) |guard| {
        for (cases) |case| {
            const source = try std.mem.concat(testing.allocator, u8, &.{ header, "\n", case.before, "    const guard = ", guard, "\n", case.after, "if const result: int = run() -> exit(result) else exit(1)" });
            defer testing.allocator.free(source);
            errdefer std.debug.print("cleanup regression source:\n{s}\n", .{source});
            const fixture = try Fixture.initFiles(source, &.{});
            defer fixture.deinit();
            if (case.expected) |expected| try fixture.expectExit(0, expected) else try fixture.expectDiagnostic(0, .borrow_outlives_source);
        }
    }
}

test "custom copy permissions and move effects protect pending borrows" {
    const cases = .{
        .{ .movement = "", .hook = "copy = func(imm", .parameter = "Copier", .argument = "source", .access = "copied.target.value.value" },
        .{ .movement = "", .hook = "copy = func(imm", .parameter = "Box(Copier)", .argument = "(if const _selected_result_0: Box(Copier) = Box(Copier).new(source) -> _selected_result_0^ else panic \"unexpected none\")", .access = "Ref.from(copied.borrow()).value.target.value.value" },
        .{ .movement = "  move = none\n", .hook = "copy = func(imm", .parameter = "Box(Copier)", .argument = "(if const _selected_result_0: Box(Copier) = Box(Copier).new(source) -> _selected_result_0^ else panic \"unexpected none\")", .access = "Ref.from(copied.borrow()).value.target.value.value" },
        .{ .movement = "", .hook = "move = func(deinit", .parameter = "Copier", .argument = "source^", .access = "copied.target.value.value" },
    };
    inline for (cases) |case| {
        const is_copy = std.mem.startsWith(u8, case.hook, "copy");
        const source = try std.mem.concat(testing.allocator, u8, &.{
            "struct Item\n  value: int\n  drop = func(deinit self: Item) -> ()\nstruct Copier\n",
            case.movement,
            "  target: Ref(Item)\n  ",
            case.hook,
            " self: Copier) Copier\n    self.target.value = Item{value = 42}\n    return Copier{target = self.target}\nfunc observe(imm previous: Item, var copied: ",
            case.parameter,
            ") int -> previous.value + ",
            case.access,
            if (is_copy) " - 17" else " - 42",
            "\nfunc run() int\n  var owner: Box(Item) = Box.new(Item{value = 17}) else panic \"unexpected allocation refusal\"\n  var reference = Ref.from(owner.borrow())\n  var source = Copier{target = reference}\n  return observe(reference.value, ",
            case.argument,
            ")\nif const result: int = run() -> exit(result) else exit(1)",
        });
        defer testing.allocator.free(source);
        const fixture = try Fixture.initFiles(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .borrow_outlives_source);
        const repaired = if (is_copy)
            try std.mem.replaceOwned(u8, testing.allocator, source, "self.target.value = Item{value = 42}", "_ = self.target.value")
        else
            try std.mem.replaceOwned(u8, testing.allocator, source, "observe(reference.value, ", "observe(Item{value = 17}, ");
        defer testing.allocator.free(repaired);
        try fixture.db.setInput(queries.SourceText, 0, repaired);
        try fixture.expectExit(0, 17);
    }
}

test "Box.new copies into a new Box without consuming its source" {
    try Fixture.expectSourceExit(
        \\import std.memory.{take}
        \\struct Copyable
        \\  copy = func(imm self: Copyable) Copyable -> Copyable{value = self.value + 1}
        \\  value: int
        \\func run() int | none
        \\  const source = Copyable{value = 41}
        \\  const owner: Box(Copyable) = Box(Copyable).new(source) else return none
        \\  const copied = take(Copyable, owner^)
        \\  return copied.value + source.value - 41
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "Box.new constructs a copy-only value in new storage" {
    try Fixture.expectSourceExit(
        \\struct CopyOnly
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\  drop = func(deinit self: CopyOnly) -> exit(self.value)
        \\func run() unit | none
        \\  const source = CopyOnly{value = 42}
        \\  const owner: Box(CopyOnly) = Box(CopyOnly).new(source) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box.new runs an immovable custom copy hook in new storage" {
    try Fixture.expectSourceExit(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\  drop = func(deinit self: CopyOnly)
        \\    if self.value == 42 -> exit(42) else ()
        \\func run() unit | none
        \\  const source = CopyOnly{value = 41}
        \\  const owner: Box(CopyOnly) = Box(CopyOnly).new(source) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box.new copies nested fields with custom hooks into final storage" {
    try Fixture.expectSourceExit(
        \\struct Inner
        \\  copy = func(imm self: Inner) Inner -> Inner{value = self.value + 1}
        \\  value: int
        \\struct Middle
        \\  move = none
        \\  copy = fieldwise
        \\  first: int
        \\  inner: Inner
        \\struct Outer
        \\  move = none
        \\  copy = fieldwise
        \\  first: int
        \\  middle: Middle
        \\  drop = func(deinit self: Outer)
        \\    if self.middle.inner.value == 42 -> exit(42) else ()
        \\func run() unit | none
        \\  const source = Outer{first = 1, middle = Middle{first = 2, inner = Inner{value = 41}}}
        \\  const owner: Box(Outer) = Box(Outer).new(source) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box.new copies the active member of an immovable variant" {
    try Fixture.expectSourceExit(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\  drop = func(deinit self: CopyOnly)
        \\    if self.value == 42 -> exit(42) else ()
        \\static CopyOrInt = CopyOnly | int
        \\func run() unit | none
        \\  const source: CopyOrInt = CopyOnly{value = 41}
        \\  const owner: Box(CopyOrInt) = Box(CopyOrInt).new(source) else return none
        \\  _ = owner
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box.new does not copy inactive variant members" {
    try Fixture.expectSourceExit(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> exit(1)
        \\  value: int
        \\static CopyOrInt = CopyOnly | int
        \\func run() unit | none
        \\  const source: CopyOrInt = 41
        \\  const owner: Box(CopyOrInt) = Box(CopyOrInt).new(source) else return none
        \\  _ = owner
        \\  exit(42)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box.new rejects noncopyable values" {
    try Fixture.expectSourceDiagnostic(
        \\struct Token
        \\  move = none
        \\  value: int
        \\const source = Token{value = 42}
        \\if (Box(Token).new(source) is Box(Token)) -> exit(1) else exit(2)
    , .type_not_copyable);
}

test "Box.new rejects explicitly droppable values" {
    const fixture = try Fixture.initFiles(
        \\struct Explicit
        \\  copy = trivial
        \\  drop = explicit
        \\  value: int
        \\const source = Explicit{value = 42}
        \\if (Box(Explicit).new(source) is Box(Explicit)) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.box_requires_automatic_drop);
}

test "reference field assignment through function values retains stored origins" {
    const source =
        \\func replace(ref target: Ref(int), imm source: Ref(int)) -> target = source
        \\func run() int | none
        \\  const previous: Box(int) = Box.new(7) else return none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  var holder: Box(Ref(int)) = Box.new(Ref.from(previous.borrow())) else return none
        \\  const callback = replace
        \\  callback(holder.borrow(), Ref.from(owner.borrow()))
        \\  return holder.borrow().value
        \\if const result: int = run() -> exit(result) else exit(1)
    ;
    const fixture = try Fixture.initFiles(
        source,
        &.{},
    );
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const invalid = try std.mem.replaceOwned(u8, testing.allocator, source, "return holder.borrow().value", "const moved = owner^\n  _ = moved\n  return holder.borrow().value");
    defer testing.allocator.free(invalid);
    try fixture.db.setInput(queries.SourceText, 0, invalid);
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "library eligibility is checked for function values" {
    const fixture = try Fixture.initFiles(
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\const create = Box(Explicit).new
        \\if create(Explicit{value = 42}) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.box_requires_automatic_drop);
}

test "moving a Box preserves its owned value until the new owner's last use" {
    try Fixture.expectSourceExit(
        \\import std.memory.{Box}
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\func run() unit | none
        \\  const first: Box(Resource) = Box.new(Resource{value = 42}) else return none
        \\  const moved = first^
        \\  _ = moved
        \\  exit(1)
        \\  return ()
        \\if (run() is unit) -> exit(2) else exit(3)
    , 42);
}

test "Box cannot be forged or accessed through its storage field" {
    const sources = [_][]const u8{
        \\import std.memory.{Box}
        \\const fake = Box(int){}
        \\exit(42)
        ,
        \\import std.memory.{Box}
        \\func inspect() unit | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  _ = owner.allocation
        \\  return ()
        \\if (inspect() is unit) -> exit(42) else exit(1)
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .private_struct_field);
    }
}

test "Box cannot be implicitly copied or used after transfer" {
    const sources = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\import std.memory.{Box}
        \\func copy_owner() unit | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const copied = owner
        \\  _ = copied
        \\  return ()
        \\if (copy_owner() is unit) -> exit(1) else exit(2)
        , .diagnostic = .type_not_copyable },
        .{ .source =
        \\import std.memory.{Box, take}
        \\func take_twice() unit | none
        \\  const owner: Box(int) = Box.new(42) else return none
        \\  const first = take(int, owner^)
        \\  const second = take(int, owner^)
        \\  _ = first
        \\  _ = second
        \\  return ()
        \\if (take_twice() is unit) -> exit(1) else exit(2)
        , .diagnostic = .use_after_transfer },
    };
    for (sources) |case| {
        try Fixture.expectSourceDiagnostic(case.source, case.diagnostic);
    }
}

test "typed allocation ownership cannot be abandoned or deallocated twice" {
    const sources = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\import std.memory.{Allocation, allocate}
        \\func leak() unit | none
        \\  const allocation: Allocation(int) = allocate(int, 1) else return none
        \\  return ()
        \\if (leak() is unit) -> exit(42) else exit(1)
        , .diagnostic = .value_requires_explicit_drop },
        .{ .source =
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func twice() unit | none
        \\  const allocation: Allocation(int) = allocate(int, 1) else return none
        \\  deallocate(int, allocation^)
        \\  deallocate(int, allocation^)
        \\  return ()
        \\if (twice() is unit) -> exit(42) else exit(1)
        , .diagnostic = .use_after_transfer },
    };
    for (sources) |case| {
        try Fixture.expectSourceDiagnostic(case.source, case.diagnostic);
    }
}

test "typed allocation cannot be forged or have its storage metadata changed" {
    const sources = [_][]const u8{
        \\import std.memory.{Allocation}
        \\const fake = Allocation(int){}
        \\exit(42)
        ,
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func use_storage() unit | none
        \\  var allocation: Allocation(int) = allocate(int, 3) else return none
        \\  allocation.storage.byte_size = 0
        \\  deallocate(int, allocation^)
        \\  return ()
        \\if (use_storage() is unit) -> exit(42) else exit(1)
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .private_struct_field);
    }
}

test "host storage layout edits invalidate compiler-owned extern signatures" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "import std.memory.{}\nexit(42)", &.{}, &.{});
    const host_file = registry.fileId("$std/memory/host.chi").?;
    const declarations = (try db.get(queries.ModuleDeclarations, try db.intern(queries.ModulePaths, .{ .path = "std.memory" }))).*.?;
    const allocate = declarations.resolveFunction("allocate_host_storage").?;
    try testing.expect((try db.get(queries.FunctionSignature, allocate)).* != null);

    const original = standard_library.source("memory/host.chi");
    for ([_][]const u8{ "address_low", "address_high", "byte_size" }) |field| {
        const owned = try testing.allocator.print("{s}: int", .{field});
        defer testing.allocator.free(owned);
        const borrowed = try testing.allocator.print("{s}: ref int", .{field});
        defer testing.allocator.free(borrowed);
        const changed = try std.mem.replaceOwned(u8, testing.allocator, original, owned, borrowed);
        defer testing.allocator.free(changed);
        try db.setInput(queries.SourceText, host_file, changed);
        try testing.expect((try db.get(queries.FunctionSignature, allocate)).* == null);
        try db.setInput(queries.SourceText, host_file, original);
        try testing.expect((try db.get(queries.FunctionSignature, allocate)).* != null);
    }
    const borrowed_result = try std.mem.replaceOwned(u8, testing.allocator, original, ") HostStorage", ") ref HostStorage");
    defer testing.allocator.free(borrowed_result);
    try db.setInput(queries.SourceText, host_file, borrowed_result);
    try testing.expect((try db.get(queries.FunctionSignature, allocate)).* == null);
    try db.setInput(queries.SourceText, host_file, original);
    try testing.expect((try db.get(queries.FunctionSignature, allocate)).* != null);

    try db.setInput(queries.SourceText, host_file,
        \\struct HostStorage
        \\  address_low: bool
        \\  address_high: int
        \\  byte_size: int
        \\  drop = explicit
        \\extern func allocate_host_storage(byte_size: int) HostStorage | none
        \\extern func deallocate_host_storage(deinit storage: HostStorage)
    );
    try testing.expect((try db.get(queries.FunctionSignature, allocate)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.FunctionSignature, allocate, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.invalid_external_signature, diagnostics[0].kind);

    const typed = try Fixture.initFiles(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\func use_storage() unit | none
        \\  const allocation: Allocation(int) = allocate(int, 1) else return none
        \\  deallocate(int, allocation^)
        \\  return ()
        \\if (use_storage() is unit) -> exit(42) else exit(1)
    , &.{});
    defer typed.deinit();
    const typed_declarations = (try typed.db.get(queries.ModuleDeclarations, try typed.db.intern(queries.ModulePaths, .{ .path = "std.memory" }))).*.?;
    const typed_host = typed_declarations.resolveStatic("HostStorage").?;
    const typed_source = (try typed.db.get(queries.ResolveItem, typed_host)).*.?;
    const typed_allocate = (try typed.db.get(queries.ResolveItem, typed_declarations.resolveFunction("allocate").?)).*.?;
    try typed.db.setInput(queries.SourceText, typed_source.file_id,
        \\struct HostStorage
        \\  address_low: bool
        \\  address_high: int
        \\  byte_size: int
        \\  drop = explicit
        \\extern func allocate_host_storage(byte_size: int) HostStorage | none
        \\extern func deallocate_host_storage(deinit storage: HostStorage)
    );
    try typed.expectDiagnostic(typed_allocate.file_id, .invalid_external_signature);
}

test "standard storage shapes reject reference fields and recover after edits" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator,
        \\import std.memory
        \\import std.text
        \\static AllocationType = std.memory.Allocation(int)
        \\static BoxType = std.memory.Box(int)
        \\static SpanType = std.memory.Span(int)
        \\static LiteralType = std.text.StaticString
    , &.{}, &.{});
    const scope = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const facts: queries.TypeFacts(*query.Database) = .{ .ctx = db };
    const Shape = enum { allocation, box, span, literal };
    for ([_]struct { selected: []const u8, field: []const u8, shape: Shape }{
        .{ .selected = "AllocationType", .field = "storage: HostStorage", .shape = .allocation },
        .{ .selected = "AllocationType", .field = "count: int", .shape = .allocation },
        .{ .selected = "BoxType", .field = "allocation: Allocation(T)", .shape = .box },
        .{ .selected = "SpanType", .field = "address_low: int", .shape = .span },
        .{ .selected = "SpanType", .field = "address_high: int", .shape = .span },
        .{ .selected = "SpanType", .field = "data: StorageCursor(T)", .shape = .span },
        .{ .selected = "SpanType", .field = "size: int", .shape = .span },
        .{ .selected = "LiteralType", .field = "bytes: Span(byte)", .shape = .literal },
    }) |case| {
        const file_name = if (case.shape == .literal) "text.chi" else "memory/allocation.chi";
        const path = try testing.allocator.print("$std/{s}", .{file_name});
        defer testing.allocator.free(path);
        const file = registry.fileId(path).?;
        const original = if (case.shape == .literal) standard_library.source("text.chi") else standard_library.source("memory/allocation.chi");
        const borrowed = try std.mem.replaceOwned(u8, testing.allocator, case.field, ": ", ": ref ");
        defer testing.allocator.free(borrowed);
        const changed = try std.mem.replaceOwned(u8, testing.allocator, original, case.field, borrowed);
        defer testing.allocator.free(changed);
        const selected = scope.resolveStatic(case.selected).?;
        for ([_]bool{ true, false, true }) |accepted| {
            try db.setInput(queries.SourceText, file, if (accepted) original else changed);
            const value = (try db.lookupInterned(queries.CompileTimeValues, (try db.get(queries.ResolveStatic, selected)).*.?)).*;
            var element: ?structures.TypeId = null;
            switch (case.shape) {
                .allocation => element = try facts.allocationElement(value.type),
                .box => element = try facts.boxElement(value.type),
                .span => element = try facts.spanAccess(value.type),
                .literal => element = try facts.staticStringBytes(value.type),
            }
            try testing.expectEqual(accepted, element != null);
        }
    }
}

test "invalid external signatures recover after runtime input mode changes" {
    const fixture = try Fixture.initFiles(
        \\import std.memory.{borrow}
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  return borrow(int, owner)
        \\if const result: int = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    const memory_module = try fixture.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const declarations = (try fixture.db.get(queries.ModuleDeclarations, memory_module)).*.?;
    const resolved = (try fixture.db.get(queries.ResolveItem, declarations.resolveFunction("borrow").?)).*.?;
    const modified = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        standard_library.source("memory/allocation.chi"),
        "pub extern func borrow(static T: type, ref owner: Box(T)) ref T",
        "pub extern func borrow(static T: type, mut owner: Box(T)) ref T",
    );
    defer testing.allocator.free(modified);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, modified);
    try fixture.expectDiagnostic(resolved.file_id, .invalid_external_signature);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(0, 42);
}

test "an explicit empty prelude import also suppresses exit" {
    try Fixture.expectSourceDiagnostic("import std.prelude.{}\nexit(42)", .unknown_function);
}

test "exit is an imported function, not a reserved call name" {
    try Fixture.expectSourceExit(
        \\import std.prelude.{}
        \\import std.exit
        \\func exit(imm code: int) int -> code + 1
        \\const terminate: func(int) never = std.exit.exit
        \\terminate(exit(41))
    , 42);
}

test "an unsupported external declaration is rejected at signature lookup" {
    try Fixture.expectSourceDiagnostic("extern func goodbye(code: int) never\ngoodbye(42)", .unsupported_external_declaration);
}

test "compiler-owned extern names require the reserved module" {
    try Fixture.expectSourceDiagnostic("extern func exit(code: int) never\nexit(42)", .unsupported_external_declaration);
}

test "compiler-owned externs require their registered file" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "exit(42)", &.{}, &.{});
    const exit_file = registry.fileId("$std/exit.chi").?;
    const exit_module = try db.intern(queries.ModulePaths, .{ .path = standard_library.File.exit.modulePath() });
    const declarations = (try db.get(queries.ModuleDeclarations, exit_module)).*.?;
    const exit_item = declarations.resolveFunction(@tagName(standard_library.External.exit)).?;
    try testing.expect((try db.get(queries.FunctionShape, exit_item)).* != null);

    const key = queries.standardFileKey(standard_library.File.exit.path());
    try db.setInput(queries.StandardFile, key, 0);
    try testing.expect((try db.get(queries.FunctionShape, exit_item)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.FunctionShape, exit_item, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.unsupported_external_declaration, diagnostics[0].kind);

    try db.setInput(queries.StandardFile, key, exit_file);
    try testing.expect((try db.get(queries.FunctionShape, exit_item)).* != null);
}

test "compiler-owned exit signature invalidates and recovers" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "exit(42)", &.{}, &.{});
    const exit_file = registry.fileId("$std/exit.chi").?;
    try db.setInput(queries.SourceText, exit_file, "pub extern func exit(code: bool) never");
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(exit_file, diagnostics[0].file_id);
    try testing.expectEqual(structures.Diagnostic.Kind.invalid_external_signature, diagnostics[0].kind);

    try db.setInput(queries.SourceText, exit_file, standard_library.source("exit.chi"));
    const f: Fixture = .{ .db = db };
    try f.expectExit(0, 42);
}

test "compiler-owned exit rejects an optional result" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "exit(42)", &.{}, &.{});
    const exit_file = registry.fileId("$std/exit.chi").?;
    try db.setInput(queries.SourceText, exit_file, "pub extern func exit(code: int) unit | none");
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* == null);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.invalid_external_signature, diagnostics[0].kind);
}

test "compile-time std exit emits compiler control without an executable" {
    const f = try Fixture.initFiles("const result = comptime -> exit(42)", &.{});
    defer f.deinit();
    try testing.expect((try f.db.get(queries.BuildExecutable, 0)).* == null);
    const controls = try f.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
}

test "indirect compile-time std exit preserves compiler control" {
    const f = try Fixture.initFiles(
        \\const result = comptime
        \\  const terminate = exit
        \\  terminate(42)
    , &.{});
    defer f.deinit();
    try testing.expect((try f.db.get(queries.BuildExecutable, 0)).* == null);
    const controls = try f.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
}

test "prelude resolution is retained across user source and module changes" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "exit(42)", &.{}, &.{});
    const resolved = try db.get(queries.ResolvePreludeImports, {});

    try registry.update(db, testing.allocator, "import user\nexit(42)", &.{.{
        .path = "user/a.chi",
        .module_path = "user",
        .source = "pub static value = 1",
    }}, &.{"user"});
    try testing.expectEqual(resolved, try db.get(queries.ResolvePreludeImports, {}));
}

test "qualified module types calls initializer heads generics and compile time values" {
    const f = try Fixture.initFiles(
        \\import physics
        \\static T: type = physics.Body
        \\static saved = physics.make(40)
        \\func read(imm body: physics.Body) int -> return physics.get(body)
        \\var value: T = physics.Body{x = physics.identity(int, 2)}
        \\exit(read(saved) + value.x)
    , &.{physics});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "aliases selective names and reexports preserve nominal and callable identity" {
    const f = try Fixture.initFiles(
        \\import api as a
        \\import physics.{Body as B, make as create}
        \\var body: a.Body = create(42)
        \\var same: B = body^
        \\const get = a.get
        \\exit(get(same))
    , &.{ physics, .{ .path = "api/exports.chi", .module_path = "api", .source = "pub import physics.{Body, get}" } });
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "explicit nested modules navigate prefixes and selective module reexports" {
    const f = try Fixture.initFiles(
        \\import physics.collision
        \\import api.{collision as c}
        \\exit(physics.collision.answer + c.answer)
    , &.{
        physics,
        .{ .path = "physics/collision/ray.chi", .module_path = "physics.collision", .source = "pub static answer = 21" },
        .{ .path = "api/exports.chi", .module_path = "api", .source = "pub import physics.collision" },
    });
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "struct namespace declarations and instance fields dispatch separately" {
    const f = try Fixture.initFiles(
        \\import shapes
        \\static S = shapes.S
        \\var s = S{x = S.answer}
        \\exit(S.identity(int, s.x))
    , &.{.{ .path = "shapes/s.chi", .module_path = "shapes", .source =
        \\pub struct S
        \\  pub x: int
        \\  pub static answer = 42
        \\  pub func identity(static T: type, imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "struct namespace members require pub across modules" {
    const f = try Fixture.initFiles(
        \\import shapes
        \\const s = shapes.S{value = 40}
        \\exit(shapes.S.answer + s.read())
    , &.{.{ .path = "shapes/s.chi", .module_path = "shapes", .source =
        \\pub struct S
        \\  pub value: int
        \\  pub static answer = 2
        \\  pub func read(imm self: S) int -> return self.value
        \\  static secret = 7
        \\  func hidden(imm self: S) int -> return self.value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);

    try f.db.setInput(queries.SourceText, 0,
        \\import shapes
        \\exit(shapes.S.secret)
    );
    try f.expectDiagnostic(0, .private_access);
    try f.db.setInput(queries.SourceText, 0,
        \\import shapes
        \\const s = shapes.S{value = 42}
        \\exit(shapes.S.hidden(s))
    );
    try f.expectDiagnostic(0, .private_access);
    try f.db.setInput(queries.SourceText, 0,
        \\import shapes
        \\const s = shapes.S{value = 42}
        \\exit(s.hidden())
    );
    try f.expectDiagnostic(0, .private_access);
}

test "qualified struct members retain visibility across module files" {
    const f = try Fixture.initFiles(
        \\import lib
        \\exit(lib.S.read(lib.S{value = 21}) + lib.answer())
    , &.{
        .{ .path = "lib/s.chi", .module_path = "lib", .source =
        \\pub struct S
        \\  pub value: int
        },
        .{ .path = "lib/methods.chi", .module_path = "lib", .source =
        \\pub func S.read(imm self: S) int -> return self.value
        \\func S.hidden(imm self: S) int -> return self.value
        },
        .{ .path = "lib/api.chi", .module_path = "lib", .source =
        \\pub func answer() int -> return S.hidden(S{value = 21})
        },
    });
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 0,
        \\import lib
        \\const s = lib.S{value = 42}
        \\exit(s.hidden())
    );
    try f.expectDiagnostic(0, .private_access);
}

test "struct member visibility recomputes when pub changes" {
    const private_source =
        \\pub struct S
        \\  func answer() int -> return 42
    ;
    const f = try Fixture.initFiles("import lib\nexit(lib.S.answer())", &.{.{ .path = "lib/s.chi", .module_path = "lib", .source = private_source }});
    defer f.deinit();
    try f.expectDiagnostic(0, .private_access);
    try f.db.setInput(queries.SourceText, 1,
        \\pub struct S
        \\  pub func answer() int -> return 42
    );
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 1, private_source);
    try f.expectDiagnostic(0, .private_access);
}

test "qualified struct namespace declarations support instance calls" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\func S.id(imm self: S, static T: type, imm value: T) T -> return self.i + value
        \\var s = S{i = 2}
        \\exit(S.id(s, int, 20) + s.id(int, 18))
    , 42);
}

test "instance calls preserve receiver modes and namespace lookup" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\static S.bump = func(mut self: S, imm amount: int)
        \\  self.i += amount
        \\var s = S{i = 40}
        \\s.bump(2)
        \\exit(s.i)
    , 42);
}

test "instance calls evaluate the receiver before remaining arguments" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\static S.combine = func(imm self: S, imm value: int) int -> return self.i * 10 + value
        \\func receiver(mut state: int) S
        \\  state = state * 10 + 1
        \\  return S{i = state}
        \\func argument(mut state: int) int
        \\  state = state * 10 + 2
        \\  return state
        \\var state = 0
        \\const result = receiver(state).combine(argument(state))
        \\exit(result)
    , 22);
}

test "owned instance receivers use ordinary transfer rules" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\static S.take = func(var self: S) int -> return self.i
        \\var s = S{i = 42}
        \\exit(s^.take())
    , 42);
}

test "qualified namespace declarations attach across module files" {
    const f = try Fixture.initFiles(
        \\struct S
        \\  i: int
        \\const s = S{i = 42}
        \\exit(s.id())
    , &.{.{
        .path = "methods.chi",
        .module_path = "",
        .source = "static S.id = func(imm self: S) int -> return self.i",
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "qualified namespace declarations recompute across edits" {
    const entry =
        \\struct S
        \\  i: int
        \\const s = S{i = 42}
        \\exit(s.id())
    ;
    const original = "static S.id = func(imm self: S) int -> return self.i";
    const f = try Fixture.initFiles(entry, &.{.{
        .path = "methods.chi",
        .module_path = "",
        .source = original,
    }});
    defer f.deinit();
    try f.expectExit(0, 42);

    try f.db.setInput(queries.SourceText, 1, "static S.id = func(imm self: S) int -> return self.i + 1");
    try f.expectExit(0, 43);
    try f.db.setInput(queries.SourceText, 1, "static S.other = func(imm self: S) int -> return self.i");
    try f.expectDiagnostic(0, .unknown_namespace_member);
    try f.db.setInput(queries.SourceText, 1, original);
    try f.expectExit(0, 42);
}

test "lexical struct namespace functions support instance calls" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\  func add(imm self: S, imm amount: int) int -> return self.i + amount
        \\const s = S{i = 2}
        \\exit(s.add(40))
    , 42);
}

test "generated namespace functions support specialized instance calls" {
    try Fixture.expectSourceExit(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T -> return self.value
        \\const box = Box(int){value = 42}
        \\exit(box.get())
    , 42);
}

test "where conditions use inherited static namespace parameters" {
    const accepted = try Fixture.initFiles(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T where T is int -> return self.value
        \\const box = Box(int){value = 42}
        \\exit(box.get())
    , &.{});
    defer accepted.deinit();
    try accepted.expectExit(0, 42);

    const rejected = try Fixture.initFiles(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T where T is int -> return self.value
        \\const box = Box(bool){value = true}
        \\_ = box.get()
        \\exit(42)
    , &.{});
    defer rejected.deinit();
    try rejected.expectDiagnostic(0, .where_condition_failed);
}

test "generic struct namespace functions infer enclosing type parameters" {
    try Fixture.expectSourceExit(
        \\struct Box(T: type)
        \\  value: T
        \\  func new(imm value: T) Box(T) -> return Box(T){value = value}
        \\exit(Box.new(41).value + Box(int).new(1).value)
    , 42);
}

test "generic struct namespace rejects missing members" {
    try Fixture.expectSourceDiagnostic(
        \\struct Box(T: type)
        \\  value: T
        \\exit(Box.missing(42))
    , .unknown_namespace_member);
}

test "namespace inference requires specializing an enclosing factory" {
    try Fixture.expectSourceDiagnostic(
        \\struct Outer(T: type)
        \\  struct Inner
        \\    func make(imm value: T) T -> return value
        \\exit(Outer.Inner.make(42))
    , .static_argument_cannot_be_inferred);
}

test "where clauses on static parameters accept inline and following lines" {
    try Fixture.expectSourceExit(
        \\func bounded(static value: int) int where value > 0
        \\where value < 10
        \\  return value
        \\exit(bounded(5))
    , 5);
}

test "where clauses can repeat on one signature line" {
    try Fixture.expectSourceExit(
        \\func bounded(static value: int) int where value > 0 where value < 10 -> value
        \\exit(bounded(5))
    , 5);
}

test "where clauses follow borrowed return types without origin annotations" {
    try Fixture.expectSourceExit(
        \\func forward(static T: type, var reference: Ref(T)) Ref(T) where T is int -> reference
        \\func run() int | none
        \\  var owner: Box(int) = Box.new(42) else return none
        \\  return (forward(int, Ref.from(owner.borrow()))).value
        \\if const result: int = run() -> exit(result) else exit(1)
    , 42);
}

test "where clauses evaluate func calls at specialization" {
    const success = try Fixture.initFiles(
        \\func positive(imm value: int) unit | none
        \\  if not (value > 0) -> return none
        \\  return ()
        \\func bounded(static value: int) int where positive(value) is unit -> value
        \\exit(bounded(5))
    , &.{});
    defer success.deinit();
    try success.expectExit(0, 5);

    const failed = try Fixture.initFiles(
        \\func positive(imm value: int) unit | none
        \\  if not (value > 0) -> return none
        \\  return ()
        \\func bounded(static value: int) int where positive(value) is unit -> value
        \\exit(bounded(0))
    , &.{});
    defer failed.deinit();
    try failed.expectDiagnostic(0, .where_condition_failed);
}

test "where clauses reject a failed static specialization" {
    const source =
        \\func bounded(static value: int) int where value > 0
        \\where value < 10
        \\  return value
        \\exit(bounded(10))
    ;
    const fixture = try Fixture.initFiles(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .where_condition_failed);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    var failures: usize = 0;
    for (diagnostics) |diagnostic| {
        if (diagnostic.kind != .where_condition_failed) continue;
        failures += 1;
        try testing.expectEqual(std.mem.indexOf(u8, source, "< 10").?, diagnostic.span.?.start);
    }
    try testing.expectEqual(@as(usize, 1), failures);
}

test "where conditions reject runtime parameters even for func functions" {
    try Fixture.expectSourceDiagnostic(
        \\func check(imm value: int) int | none where value > 0 -> value
        \\if (check(5) is int) -> exit(1) else exit(2)
    , .comptime_runtime_capture);
}

test "where conditions on unused specializations stay deferred" {
    try Fixture.expectSourceExit(
        \\func unused(static value: int) int where value < 0 -> value
        \\exit(42)
    , 42);
}

test "where conditions recompute after module static edits" {
    const fixture = try Fixture.initFiles(
        \\static ceiling = 10
        \\func below(static value: int) int where value > 0 and value < ceiling -> value
        \\exit(below(5))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 5);
    try fixture.db.setInput(queries.SourceText, 0,
        \\static ceiling = 5
        \\func below(static value: int) int where value > 0 and value < ceiling -> value
        \\exit(below(5))
    );
    try fixture.expectDiagnostic(0, .where_condition_failed);
    try fixture.db.setInput(queries.SourceText, 0,
        \\static ceiling = 10
        \\func below(static value: int) int where value > 0 and value < ceiling -> value
        \\exit(below(5))
    );
    try fixture.expectExit(0, 5);
}

test "where conditions recompute after imported static edits" {
    const fixture = try Fixture.initFiles(
        \\import flags.{ceiling}
        \\func below(static value: int) int where value < ceiling -> value
        \\exit(below(5))
    , &.{.{ .path = "flags/ceiling.chi", .module_path = "flags", .source = "pub static ceiling = 10" }});
    defer fixture.deinit();
    try fixture.expectExit(0, 5);
    try fixture.db.setInput(queries.SourceText, 1, "pub static ceiling = 5");
    try fixture.expectDiagnostic(0, .where_condition_failed);
    try fixture.db.setInput(queries.SourceText, 1, "pub static ceiling = 10");
    try fixture.expectExit(0, 5);
}

test "where type tests accept structural subsets" {
    try Fixture.expectSourceExit(
        \\static Small = int | none
        \\func accept(static T: type) int where T is int | none -> 42
        \\exit(accept(Small))
    , 42);
}

test "where conditions compare static type values" {
    const matching = try Fixture.initFiles(
        \\func exact(static T: type) int where T == int -> 42
        \\exit(exact(int))
    , &.{});
    defer matching.deinit();
    try matching.expectExit(0, 42);

    const mismatched = try Fixture.initFiles(
        \\func exact(static T: type) int where T == int -> 42
        \\exit(exact(bool))
    , &.{});
    defer mismatched.deinit();
    try mismatched.expectDiagnostic(0, .where_condition_failed);
}

test "where type tests reject members outside the inspected type" {
    try Fixture.expectSourceDiagnostic(
        \\static Large = int | none
        \\func accept(static T: type) int where T is int -> 42
        \\exit(accept(Large))
    , .where_condition_failed);
}

test "where type tests short circuit disjunction" {
    try Fixture.expectSourceExit(
        \\func accept(static T: type) int where T is int or 1 / 0 > 0 -> 42
        \\exit(accept(int))
    , 42);
}

test "where type tests accept qualified module statics" {
    const fixture = try Fixture.initFiles(
        \\import flags
        \\func accept() int where flags.answer is int -> 42
        \\exit(accept())
    , &.{.{ .path = "flags/answer.chi", .module_path = "flags", .source = "pub static answer = 42" }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "where member type tests accept callables and reject absent members" {
    const callable = try Fixture.initFiles(
        \\struct WithMember
        \\  func compute(imm value: int) int -> value
        \\func accept(static T: type) int where T.compute is func(int) int -> 42
        \\exit(accept(WithMember))
    , &.{});
    defer callable.deinit();
    try callable.expectExit(0, 42);

    const missing = try Fixture.initFiles(
        \\struct WithoutMember
        \\  value: int
        \\func accept(static T: type) int where T.compute is func(int) int -> 42
        \\exit(accept(WithoutMember))
    , &.{});
    defer missing.deinit();
    try missing.expectDiagnostic(0, .where_condition_failed);
}

test "where member type tests inspect static struct fields" {
    const existing = try Fixture.initFiles(
        \\struct Config
        \\  amount: int
        \\static config = Config{amount = 42}
        \\func accept() int where config.amount is int -> 42
        \\exit(accept())
    , &.{});
    defer existing.deinit();
    try existing.expectExit(0, 42);

    const missing = try Fixture.initFiles(
        \\struct Config
        \\  amount: int
        \\static config = Config{amount = 42}
        \\func accept() int where config.missing is int -> 42
        \\exit(accept())
    , &.{});
    defer missing.deinit();
    try missing.expectDiagnostic(0, .where_condition_failed);
}

test "qualified namespace declarations share the struct member scope" {
    try Fixture.expectSourceDiagnostic(
        \\struct S
        \\  id: func() int
        \\static S.id = func(imm self: S) int -> return 42
        \\func answer() int -> return 1
        \\const s = S{id = answer}
        \\exit(s.id())
    , .duplicate_struct_member);
}

test "nested instance and callable field calls retain contiguous arguments" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\  callback: func(int) int
        \\func S.add(imm self: S, imm n: int) int -> self.i + n
        \\func S.id(imm self: S, static T: type, imm n: T) T -> n
        \\func identity(imm n: int) int -> n
        \\const s = S{i = 20, callback = identity}
        \\exit(s.id(int, s.add(s.callback(s.add(2)))))
    , 42);
}

test "namespace callable aliases preserve receiver modes and exposed signatures" {
    try Fixture.expectSourceExit(
        \\struct S
        \\  i: int
        \\func bumpValue(mut self: S, imm n: int)
        \\  self.i += n
        \\func readValue(imm self: S) int -> self.i
        \\func takeValue(var self: S) int -> self.i
        \\static S.bump = bumpValue
        \\static S.read: func(S) int = readValue
        \\static S.take = takeValue
        \\var s = S{i = 20}
        \\s.bump(1)
        \\const n = if (s.read() is int) -> s.i else 0
        \\exit(n + s^.take())
    , 42);
}

test "generated namespace callable aliases retain inherited specialization" {
    try Fixture.expectSourceExit(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T -> self.value
        \\  static read = get
        \\const box = Box(int){value = 42}
        \\exit(box.read())
    , 42);
}

test "namespace values must be callable for instance syntax" {
    for ([_][]const u8{ "42", "int" }) |value| {
        const source = try testing.allocator.print("struct S\n  i: int\nstatic S.bad = {s}\nconst s = S{{i = 1}}\nexit(s.bad())", .{value});
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .value_not_callable);
    }
}

test "qualified declaration owners require current same module struct declarations" {
    const cases = [_][]const u8{
        "func Missing.id() int -> 1\nexit(42)",
        "static S = 1\nfunc S.id() int -> 1\nexit(42)",
        "struct S(T: type)\n  i: T\nfunc S.id() int -> 1\nexit(42)",
        "struct S\n  i: int\nstatic Alias = S\nfunc Alias.id() int -> 1\nexit(42)",
        "struct S\n  i: int\nfunc S.Missing.id() int -> 1\nexit(42)",
        "static Missing.Inner = struct\n  i: int\nfunc Missing.Inner.id() int -> 1\nexit(42)",
        "import physics.{Body}\nfunc Body.id() int -> 1\nexit(42)",
    };
    for (cases) |source| {
        const f = try Fixture.initFiles(source, &.{physics});
        defer f.deinit();
        try f.expectDiagnostic(0, .invalid_namespace_owner);
    }
}

test "nested qualified owners resolve independently of declaration order" {
    const f = try Fixture.initFiles(
        \\func S.Inner.get(imm self: S.Inner) int -> self.i
        \\const s = S.Inner{i = 42}
        \\exit(s.get())
    , &.{.{ .path = "types.chi", .module_path = "", .source =
        \\struct S
        \\  struct Inner
        \\    i: int
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "qualified owner validation invalidates and recovers after owner edits" {
    const original = "struct S\n  i: int";
    const f = try Fixture.initFiles("func S.id() int -> 1\nexit(42)", &.{.{
        .path = "types.chi",
        .module_path = "",
        .source = original,
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
    for ([_][]const u8{ "", "static S = 1", "struct Other\n  i: int" }) |source| {
        try f.db.setInput(queries.SourceText, 1, source);
        try f.expectDiagnostic(0, .invalid_namespace_owner);
        try f.db.setInput(queries.SourceText, 1, original);
        try f.expectExit(0, 42);
    }
}

test "struct field access validates qualified member collisions across edits" {
    const f = try Fixture.initFiles(
        \\struct S
        \\  i: int
        \\const s = S{i = 42}
        \\exit(s.i)
    , &.{.{ .path = "members.chi", .module_path = "", .source = "static S.other = 7" }});
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 1, "static S.i = 7");
    try f.expectDiagnostic(1, .duplicate_struct_member);
    try f.db.setInput(queries.SourceText, 1, "static S.other = 7");
    try f.expectExit(0, 42);
}

test "module item locations reject unused duplicate qualified declarations" {
    const f = try Fixture.initFiles(
        \\struct S
        \\  i: int
        \\func S.get(imm self: S) int -> self.i
        \\exit(42)
    , &.{.{ .path = "members.chi", .module_path = "", .source = "func S.get(imm self: S) int -> self.i" }});
    defer f.deinit();
    try f.expectDiagnostic(1, .duplicate_struct_member);
}

test "locals and parameters shadow imports without module fallback" {
    const f = try Fixture.initFiles(
        \\import physics
        \\import physics.{answer}
        \\func read(imm physics: int) int
        \\  const answer = physics
        \\  return answer
        \\struct Local
        \\  answer: int
        \\func inspect() int
        \\  var physics = Local{answer = 42}
        \\  return read(physics.answer)
        \\exit(inspect())
    , &.{physics});
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 0, "import physics\nfunc inspect()\n  var physics = 1\n  var b: physics.Body = 2\ninspect()");
    try f.expectDiagnostic(0, .value_used_as_type);
}

test "visibility navigation namespace values and file scope errors" {
    const cases = [_]struct { source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source = "import physics\nexit(physics.hidden)", .kind = .private_access },
        .{ .source = "import physics\nexit(physics.missing)", .kind = .unknown_imported_name },
        .{ .source = "import physics\nconst p = physics", .kind = .namespace_used_as_value },
        .{ .source = "import physics\nvar p: physics = 1", .kind = .namespace_used_as_value },
        .{ .source = "import physics\nexit(physics.collision.answer)", .kind = .unknown_imported_name },
        .{ .source = "import physics.collision\nexit(physics.answer)", .kind = .unknown_imported_name },
        .{ .source = "import physics as p\nexit(physics.answer)", .kind = .unknown_value },
        .{ .source = "import physics\nfunc f(imm physics: int) int -> return physics.answer\nexit(f(1))", .kind = .field_access_not_struct },
    };
    for (cases) |case| {
        const f = try Fixture.initFiles(case.source, &.{ physics, .{ .path = "physics/collision/a.chi", .module_path = "physics.collision", .source = "pub static answer = 42" } });
        defer f.deinit();
        try f.expectDiagnostic(0, case.kind);
    }
}

test "each declaration uses the imports of its defining file" {
    const f = try Fixture.initFiles("import physics\nexit(read())", &.{ physics, .{ .path = "reader.chi", .module_path = "", .source = "func read() int -> return physics.answer" } });
    defer f.deinit();
    try f.expectDiagnostic(2, .unknown_value);
    try f.db.setInput(queries.SourceText, 2, "func read() int -> return physics.answer\nimport physics");
    try f.expectExit(0, 42);
}

test "only the designated entry body executes across same and imported modules" {
    const f = try Fixture.initFiles("import physics\nexit(physics.answer)", &.{ physics, .{ .path = "second.chi", .module_path = "", .source = "exit(43)" } });
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.expectExit(2, 43);
    try f.db.setInput(queries.SourceText, 2, "static ignored = comptime -> exit(98)\nconst ignored_runtime = comptime -> exit(99)\nunknown_top_level_call()");
    try f.expectExit(0, 42);
}

test "module cycles work and semantic cycles report declaration errors" {
    const f = try Fixture.initFiles("import a\nexit(a.run())", &.{
        .{ .path = "a/a.chi", .module_path = "a", .source = "import b\npub func run() int -> return b.answer\npub static seed = 42" },
        .{ .path = "b/b.chi", .module_path = "b", .source = "import a\npub static answer = a.seed" },
    });
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 1, "import b\npub func run() int -> return b.answer\npub static seed = b.answer");
    try f.expectDiagnostic(1, .declaration_cycle);
}

test "unused imports in dependency files are validated without executing their bodies" {
    const f = try Fixture.initFiles("import a\nexit(42)", &.{.{ .path = "a/a.chi", .module_path = "a", .source = "import missing\nexit(99)" }});
    defer f.deinit();
    try f.expectDiagnostic(1, .unknown_module);
}

const ScopeObserver = struct {
    pub const Input = structures.FileId;
    pub const Output = usize;
    var executions: std.atomic.Value(usize) = .init(0);
    pub fn run(ctx: anytype, file: Input) !Output {
        _ = executions.fetchAdd(1, .monotonic);
        const scope = (try ctx.get(queries.BuildModuleScope, file)).* orelse return 0;
        return scope.entries.len;
    }
};

test "directory refresh preserves IDs handles additions removals and equal scopes" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    const entry = "import lib.{answer}\nexit(answer)";
    const lib = modules.SourceFile{ .path = "lib/a.chi", .module_path = "lib", .source = "pub static answer = 42" };
    const helper = modules.SourceFile{ .path = "helper.chi", .module_path = "", .source = "static unused = 1" };
    const f = Fixture{ .db = db };
    try registry.update(db, testing.allocator, entry, &.{lib}, &.{});
    const id = registry.fileId(lib.path).?;
    const item = (try db.get(queries.BuildModuleScope, 0)).*.?.resolve("answer").?;
    const original_scope = try db.get(queries.BuildModuleScope, 0);
    ScopeObserver.executions.store(0, .monotonic);
    _ = try db.get(ScopeObserver, 0);
    try f.expectExit(0, 42);
    const executable = try db.get(queries.BuildExecutable, 0);
    try registry.update(db, testing.allocator, "import lib.{answer}\nimport lib.{answer}\nexit(answer)", &.{lib}, &.{});
    try testing.expectEqual(original_scope, try db.get(queries.BuildModuleScope, 0));
    try testing.expectEqual(executable, try db.get(queries.BuildExecutable, 0));
    _ = try db.get(ScopeObserver, 0);
    try testing.expectEqual(@as(usize, 1), ScopeObserver.executions.load(.monotonic));

    try registry.update(db, testing.allocator, entry, &.{ helper, lib }, &.{});
    try testing.expectEqual(id, registry.fileId(lib.path).?);
    try f.expectExit(0, 42);
    _ = try db.get(ScopeObserver, 0);
    try testing.expectEqual(@as(usize, 2), ScopeObserver.executions.load(.monotonic));
    const with_helper = try db.get(queries.BuildModuleScope, 0);
    try registry.update(db, testing.allocator, entry, &.{ lib, helper }, &.{});
    try testing.expectEqual(with_helper, try db.get(queries.BuildModuleScope, 0));
    _ = try db.get(ScopeObserver, 0);
    try testing.expectEqual(@as(usize, 2), ScopeObserver.executions.load(.monotonic));

    var renamed = lib;
    renamed.path = "lib/renamed.chi";
    try registry.update(db, testing.allocator, entry, &.{renamed}, &.{});
    try testing.expectEqual(item, (try db.get(queries.BuildModuleScope, 0)).*.?.resolve("answer").?);
    try testing.expectEqual(registry.fileId(renamed.path).?, (try db.get(queries.ResolveItem, item)).*.?.file_id);
    try f.expectExit(0, 42);

    try registry.update(db, testing.allocator, entry, &.{}, &.{});
    try f.expectDiagnostic(0, .unknown_module);
    try testing.expect((try db.get(queries.ResolveItem, item)).* == null);
    try registry.update(db, testing.allocator, entry, &.{}, &.{"lib"});
    try f.expectDiagnostic(0, .unknown_imported_name);
    try registry.update(db, testing.allocator, entry, &.{lib}, &.{});
    try f.expectExit(0, 42);
}

test "moving declarations changes defining file imports and crossing modules changes type identity" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    const entry = "import api\nvar value: api.Body = api.Body{x = 42}\nexit(value.x)";
    const body = modules.SourceFile{ .path = "physics/body.chi", .module_path = "physics", .source = "pub struct Body\n  pub x: int" };
    const api = modules.SourceFile{ .path = "api/a.chi", .module_path = "api", .source = "pub import physics.{Body}" };
    const f = Fixture{ .db = db };
    try registry.update(db, testing.allocator, entry, &.{ body, api }, &.{});
    try f.expectExit(0, 42);
    const physics_module = try db.intern(queries.ModulePaths, .{ .path = "physics" });
    const old_item = (try db.get(queries.ModuleDeclarations, physics_module)).*.?.resolve("Body").?;
    const old_type = (try db.get(queries.ResolveStatic, old_item)).*.?;
    var moved = body;
    moved.path = "types/body.chi";
    moved.module_path = "types";
    const bridge = modules.SourceFile{ .path = "physics/exports.chi", .module_path = "physics", .source = "pub import types.{Body}" };
    try registry.update(db, testing.allocator, entry, &.{ moved, bridge, api }, &.{});
    try f.expectExit(0, 42);
    const types_module = try db.intern(queries.ModulePaths, .{ .path = "types" });
    const new_item = (try db.get(queries.ModuleDeclarations, types_module)).*.?.resolve("Body").?;
    try testing.expect(old_item != new_item);
    try testing.expect(old_type != (try db.get(queries.ResolveStatic, new_item)).*.?);
    const imports = (try db.get(queries.ResolveFileImports, registry.fileId(api.path).?)).*.?;
    const imported = for (imports.imports) |binding| {
        if (std.mem.eql(u8, binding.name, "Body")) break binding.target;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(new_item, imported.declaration);
}

test "dependency import edits update calls and recover from private or missing exports" {
    const f = try Fixture.initFiles("import api\nexit(api.answer())", &.{
        .{ .path = "a/a.chi", .module_path = "a", .source = "pub static value = 41" },
        .{ .path = "b/b.chi", .module_path = "b", .source = "pub static value = 42" },
        .{ .path = "api/a.chi", .module_path = "api", .source = "import a as lib\npub func answer() int -> return lib.value" },
    });
    defer f.deinit();
    try f.expectExit(0, 41);
    try f.db.setInput(queries.SourceText, 3, "import b as lib\npub func answer() int -> return lib.value");
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 2, "static value = 42");
    try f.expectDiagnostic(3, .private_access);
    try f.db.setInput(queries.SourceText, 2, "pub static value = 43");
    try f.expectExit(0, 43);
}

fn checkModuleAllocations(gpa: std.mem.Allocator) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(gpa);
    const entry = "import shapes\nstatic S = shapes.Box(int, 42)\nconst make = S.make\nexit(make())";
    const file = modules.SourceFile{ .path = "shapes/a.chi", .module_path = "shapes", .source = "pub struct Box(T: type, amount: int)\n  static answer = amount\n  pub func make() T -> return answer" };
    try registry.update(db, gpa, entry, &.{file}, &.{});
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* != null);
    try registry.update(db, gpa, entry, &.{}, &.{});
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* == null);
}

test "module scope namespace and refresh queries release every failed allocation" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(allocation_failure_allocator, checkModuleAllocations, .{});
}

fn checkCleanupEffectAllocations(gpa: std.mem.Allocator) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, gpa,
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> ()
        \\struct Guard
        \\  target: Ref(Item)
        \\  drop = func(deinit self: Guard)
        \\    self.target.value = Item{value = 42}
        \\func observe(imm previous: Item, marker: int) int -> previous.value
        \\func inspect(var reference: Ref(Item)) int
        \\  return observe(reference.value, if 1 == 1
        \\    const guard = Guard{target = reference}
        \\    0
        \\  else 0)
    , &.{}, &.{});
    const declarations = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const inspect = declarations.resolve("inspect").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionInstance, .{ .item = inspect })).* == null);
}

test "implicit drop effect analysis releases every failed allocation" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(allocation_failure_allocator, checkCleanupEffectAllocations, .{});
}

test "type and compile-time scopes never fall back past a shadowing runtime binding" {
    const cases = [_]struct { source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source = "import physics\nfunc run(imm physics: int) physics.Body -> return 1\nrun(1)", .kind = .value_used_as_type },
        .{ .source = "import physics\nfunc run(imm physics: int)\n  var value: physics.Body | int = 1\nrun(1)", .kind = .value_used_as_type },
        .{ .source = "import physics\nfunc run(imm physics: int)\n  const value = comptime -> physics.answer\nrun(1)", .kind = .comptime_runtime_capture },
        .{ .source = "import physics\nimport physics.{answer}\nfunc run()\n  const answer = 3\n  _ = physics.identity(int, comptime -> answer)\nrun()", .kind = .comptime_runtime_capture },
    };
    for (cases) |case| {
        const f = try Fixture.initFiles(case.source, &.{physics});
        defer f.deinit();
        try f.expectDiagnostic(0, case.kind);
    }
}

test "qualified factories work in signatures fields initializers and compile time evaluation" {
    const f = try Fixture.initFiles(
        \\import lib
        \\static IntBox = lib.Box(int)
        \\struct Outer
        \\  inner: lib.Box(int)
        \\func read(imm value: lib.Box(int)) int -> return value.value
        \\static answer = lib.identity(int, 42)
        \\exit(read(lib.Box(int){value = answer}))
    , &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Box(T: type)
        \\  pub value: T
        \\pub func identity(static T: type, imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "struct namespaces validate duplicates and keep ownership hooks separate" {
    const f = try Fixture.initFiles("import lib\nexit(lib.S.read())", &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct S
        \\  copy = trivial
        \\  static answer = 42
        \\  pub func read() int -> return answer
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 1, "pub struct S\n  value: int\n  func value() int -> return 42\n  pub func read() int -> return 42");
    try f.expectDiagnostic(1, .duplicate_struct_member);
    try f.db.setInput(queries.SourceText, 1, "pub struct S\n  value: int");
    try f.expectDiagnostic(0, .unknown_namespace_member);
}

test "conflicting public exports fail even when the name is not used" {
    const f = try Fixture.initFiles("import api\nexit(42)", &.{
        .{ .path = "a/a.chi", .module_path = "a", .source = "pub static X = 1" },
        .{ .path = "b/b.chi", .module_path = "b", .source = "pub static X = 2" },
        .{ .path = "api/a.chi", .module_path = "api", .source = "pub import a.{X}" },
        .{ .path = "api/b.chi", .module_path = "api", .source = "pub import b.{X}" },
    });
    defer f.deinit();
    try f.expectDiagnostic(3, .import_conflict);
}

test "generated struct namespace members retain inherited and own specializations" {
    const f = try Fixture.initFiles(
        \\import lib
        \\static S = lib.Box(int, 20)
        \\static function = S.make
        \\static saved = function(1)
        \\const make = function
        \\exit(lib.Box(int, 20).identity(int, make(saved)))
    , &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Box(T: type, amount: int)
        \\  value: T
        \\  static offset = amount
        \\  pub func make(imm value: T) T -> return value + offset
        \\  pub func identity(static U: type, imm value: U) U -> return value + 1
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "nested generated namespace declarations preserve their enclosing static environment" {
    const f = try Fixture.initFiles(
        \\import lib
        \\static Inner = lib.Outer(int).Inner
        \\var value = Inner{value = Inner.make(42)}
        \\exit(value.value)
    , &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Outer(T: type)
        \\  pub struct Inner
        \\    pub value: T
        \\    pub func make(imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "nested generic namespace functions infer their own type parameters" {
    try Fixture.expectSourceExit(
        \\struct Outer(T: type)
        \\  struct Inner(U: type)
        \\    left: T
        \\    right: U
        \\    func new(imm left: T, imm right: U) Inner(U) -> return Inner(U){left = left, right = right}
        \\exit(Outer(int).Inner.new(20, 22).left + Outer(int).Inner.new(20, 22).right)
    , 42);
}

test "factories inside struct namespaces discover their generated namespace members" {
    const f = try Fixture.initFiles("import lib\nexit(lib.Factory.Box(int).make())", &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Factory
        \\  pub struct Box(T: type)
        \\    value: T
        \\    static answer = 42
        \\    pub func make() T -> return answer
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

fn refreshDirectory(db: *query.Database, registry: *modules.SourceRegistry, directory: std.Io.Dir) !void {
    var catalog = try modules.collectModuleFiles(testing.allocator, testing.io, directory, "main.chi");
    defer catalog.deinit(testing.allocator);
    const files = try modules.readSources(testing.io, testing.allocator, directory, catalog.files);
    defer {
        for (files) |file| testing.allocator.free(file.source);
        testing.allocator.free(files);
    }
    const entry = try directory.readFileAlloc(testing.io, "main.chi", testing.allocator, .unlimited);
    defer testing.allocator.free(entry);
    try registry.update(db, testing.allocator, entry, files, catalog.modules);
}

test "filesystem refresh keeps embedded std separate from user modules" {
    var directory = testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    try directory.dir.createDirPath(testing.io, "std/memory");
    try directory.dir.createDirPath(testing.io, "nested/std");
    try directory.dir.writeFile(testing.io, .{ .sub_path = "main.chi", .data = "import nested.std.{answer}\nexit(answer)" });
    try directory.dir.writeFile(testing.io, .{ .sub_path = "std/memory/allocation.chi", .data = "pub struct Allocation(T: type)" });
    try directory.dir.writeFile(testing.io, .{ .sub_path = "nested/std/value.chi", .data = "pub static answer = 42" });

    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try refreshDirectory(db, &registry, directory.dir);
    try testing.expect(registry.fileId("std/memory/allocation.chi") == null);
    try testing.expect(registry.fileId("$std/memory/allocation.chi") != null);
    const fixture = Fixture{ .db = db };
    try fixture.expectExit(0, 42);
}

test "filesystem refresh observes module and source additions and removals" {
    var directory = testing.tmpDir(.{ .iterate = true });
    defer directory.cleanup();
    try directory.dir.writeFile(testing.io, .{ .sub_path = "main.chi", .data = "import lib\nexit(lib.answer)" });
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    const f = Fixture{ .db = db };
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try refreshDirectory(db, &registry, directory.dir);
    try f.expectDiagnostic(0, .unknown_module);
    try directory.dir.createDirPath(testing.io, "lib");
    try refreshDirectory(db, &registry, directory.dir);
    try f.expectDiagnostic(0, .unknown_imported_name);
    try directory.dir.writeFile(testing.io, .{ .sub_path = "lib/a.chi", .data = "pub static answer = 42\nexit(99)" });
    try refreshDirectory(db, &registry, directory.dir);
    try f.expectExit(0, 42);
    try directory.dir.deleteFile(testing.io, "lib/a.chi");
    try refreshDirectory(db, &registry, directory.dir);
    try f.expectDiagnostic(0, .unknown_imported_name);
    try directory.dir.writeFile(testing.io, .{ .sub_path = "lib/b.chi", .data = "pub static answer = 43" });
    try refreshDirectory(db, &registry, directory.dir);
    try f.expectExit(0, 43);
}

test "init checkpoint constructs and forwards through callable values" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int
        \\    return item
        \\func forward(init item: int) int
        \\    return materialize(item)
        \\func invoke(imm callback: func(init int) int, init item: int) int | none
        \\    return (if const _selected_result_0: int = callback(item) -> _selected_result_0 else return none)
        \\if const status: int = invoke(forward, 42) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint generic construction has runtime and comptime parity" {
    try Fixture.expectSourceExit(
        \\func materialize(static T: type, init item: T) T
        \\    return item
        \\func forward(static T: type, init item: T) T
        \\    return materialize(T, item)
        \\static answer = if const computed: int = forward(40 + 2) -> computed else 97
        \\if const status: int = forward(answer) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint defers the entire producer and its arguments" {
    const sources = [_][]const u8{
        \\func producer(imm argument: int) int -> return argument
        \\func receiver(init item: int, imm eager: int) int | none -> return item
        \\func skipped() int -> exit(99)
        \\func stop() int -> exit(42)
        \\if const status: int = receiver(producer(skipped()), stop()) -> exit(status) else exit(97)
        ,
        \\func producer() int -> exit(99)
        \\func receiver(init item: int) int | none -> exit(42)
        \\if const status: int = receiver(producer()) -> exit(status) else exit(97)
        ,
        \\func producer() int -> exit(42)
        \\func receiver(init item: int) int | none
        \\    return item
        \\if const status: int = receiver(producer()) -> exit(status) else exit(97)
    };
    for (sources) |source| {
        try Fixture.expectSourceExit(source, 42);
    }
}

test "init checkpoint constructs immovable results through forwarded callables" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func producer(imm value: int) Pinned -> return Pinned{value = value}
        \\func materialize(init item: Pinned) Pinned -> return item
        \\func forward(init item: Pinned) Pinned -> return materialize(item)
        \\func receiver(imm callback: func(init Pinned) Pinned, init item: Pinned) int | none
        \\    const value: Pinned = callback(item) else return none
        \\    return value.value
        \\if const status: int = receiver(forward, producer(42)) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint read captures retain their caller context" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int -> return item
        \\func calculate(imm base: int) int | none
        \\    var extra = 2
        \\    const immutable = base + 1
        \\    return materialize(immutable + extra)
        \\static answer = if const computed: int = calculate(39) -> computed else 97
        \\if const status: int = calculate(answer - 3) -> exit(status) else exit(97)
    , 42);
}

test "init capture writes update caller storage through forwarding" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int -> return item
        \\func forward(init item: int) int -> return materialize(item)
        \\func run() int | none
        \\    var value = 1
        \\    const result: int = forward(if value == 1
        \\        value = 40
        \\        2
        \\    else 0) else return none
        \\    return value + result
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture mutable calls update caller storage through forwarding" {
    try Fixture.expectSourceExit(
        \\func change(mut value: int) int
        \\    value = 40
        \\    return 2
        \\func materialize(init item: int) int -> return item
        \\func forward(init item: int) int -> return materialize(item)
        \\func run() int | none
        \\    var value = 1
        \\    const result: int = forward(change(value)) else return none
        \\    return value + result
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture checked references survive generic indirect forwarding" {
    try Fixture.expectSourceExit(
        \\func materialize(static T: type, init item: T) T -> return item
        \\func forward(init item: Ref(int)) Ref(int) -> return materialize(item)
        \\func indirect(imm callback: func(init Ref(int)) Ref(int), init item: Ref(int)) Ref(int) | none -> return callback(item)
        \\func run() int | none
        \\    var value = 42
        \\    const reference = Ref.from(value)
        \\    const result: Ref(int) = indirect(forward, reference) else return none
        \\    return result.value
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
}

test "init capture root transfers distinguish skipped and completed construction" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    move = func(deinit self: Item) Item -> return Item{value = self.value + 1}
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 42 -> return else exit(99)
        \\func receive(init item: Item, imm construct: bool) int | none
        \\    if not (construct == true) -> return none
        \\    const value = item
        \\    if not (1 == 0) -> return none
        \\    return value.value
        \\func run(imm construct: bool) int | none
        \\    const source = Item{value = if construct == true -> 41 else 42}
        \\    if const value: int = receive(source^, construct) -> return value
        \\    return 21
        \\static answer = if const computed: int = run(false) -> if const additional_computed: int = run(true) -> computed + additional_computed else 97 else 97
        \\if const status: int = run(false) -> if const additional_status: int = run(true) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init capture deferred effects reject overlapping eager inputs and callee" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int -> return item
        \\func receive(imm eager: int, init item: int) int | none
        \\    const materialized: int = materialize(item)
        \\    return eager + materialized
        \\func run() int | none
        \\    var value = 42
        \\    return (if const _selected_result_0: int = receive(value, if true == true
        \\        value = 7
        \\        0
        \\    else 0) -> _selected_result_0^ else return none)
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
    try Fixture.expectSourceExit(
        \\func receive(init item: int, imm eager: int) int | none -> return item
        \\func run() int | none
        \\    var value = 1
        \\    return (if const _selected_result_0: int = receive(value^, value) -> _selected_result_0 else return none)
        \\if const status: int = run() -> exit(status) else exit(97)
    , 1);
    const sources = [_][]const u8{
        "struct Item\n    copy = none\n    value: int\nfunc receive(imm eager: Item, init item: int) int | none -> return item\nfunc run() int | none\n    var value = Item{value = 1}\n    return (if const _selected_result_0: int = receive(value, if true == true\n        value = Item{value = 42}\n        0\n    else 0) -> _selected_result_0 else return none)\nif const status: int = run() -> exit(status) else exit(97)",
        "struct Item\n    copy = none\n    value: int\nfunc receive(init item: Item, imm eager: Item) Item | none -> return item\nfunc run() Item | none\n    var value = Item{value = 1}\n    return (if const _selected_result_0: Item = receive(value^, value) -> _selected_result_0^ else return none)\nif const status: Item = run() -> exit(status.value) else exit(97)",
        "func receive(init item: int) int | none -> return item\nfunc other(init item: int) int | none -> return item\nfunc run() int | none\n    var callback: func(init int) int | none = receive\n    return callback(if true == true\n        callback = other\n        42\n    else 0)\nif const status: int = run() -> exit(status) else exit(97)",
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .initializer_capture_conflict);
    }
}

test "init capture reference writes execute only during construction" {
    try Fixture.expectSourceExit(
        \\func change(var reference: Ref(int)) int
        \\    reference.value = 42
        \\    return 0
        \\func materialize(init item: int) int -> return item
        \\func skip(init item: int) int | none
        \\    if not (1 == 0) -> return none
        \\    return item
        \\func run() int | none
        \\    var owner: Box(int) = Box.new(1) else return none
        \\    var reference = Ref.from(owner.borrow())
        \\    if const unused: int = skip(change(reference)) -> return 99
        \\    if reference.value == 1 -> materialize(change(reference)) else return 98
        \\    return reference.value
        \\if const answer: int = run() -> exit(answer) else exit(97)
    , 42);
}

test "init capture conditional consuming fields select independent completion state" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 21 -> return else exit(99)
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\func consume(deinit item: Item) int -> return item.value
        \\func materialize(init item: int) int -> return item
        \\func run(imm flag: bool) int | none
        \\    const source = Pair{first = Item{value = 21}, second = Item{value = 21}}
        \\    return materialize(consume(if flag == true -> source.first else source.second))
        \\static answer = if const computed: int = run(true) -> if const additional_computed: int = run(false) -> computed + additional_computed else 97 else 97
        \\if const status: int = run(true) -> if const additional_status: int = run(false) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init capture loop consuming places preserve selected completion state" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        if self.value == 21 -> return else exit(99)
        \\func consume(deinit item: Item) int -> return item.value
        \\func materialize(init item: int) int -> return item
        \\func run(imm flag: bool) int | none
        \\    const first = Item{value = 21}
        \\    const second = Item{value = 21}
        \\    return materialize(consume(loop -> break if flag == true -> first else second))
        \\static answer = if const computed: int = run(true) -> if const additional_computed: int = run(false) -> computed + additional_computed else 97 else 97
        \\if const status: int = run(true) -> if const additional_status: int = run(false) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init capture shared failure continuations retain possible transfer diagnostics" {
    const sources = [_][]const u8{
        "func receive(init item: int, imm construct: bool) int | none\n    if not (construct == true) -> return none\n    const value = item\n    if not (1 == 0) -> return none\n    return value\nfunc run(imm flag: bool) int | none\n    var value = 42\n    if const unused: int = receive(value^, flag) -> return unused\n    return value\nif const status: int = run(false) -> exit(status) else exit(97)",
        "struct Pair\n    first: int\n    second: int\nfunc receive(init item: int, imm construct: bool) int | none\n    if not (construct == true) -> return none\n    const value = item\n    if not (1 == 0) -> return none\n    return value\nfunc run(imm flag: bool) int | none\n    const value = Pair{first = 42, second = 0}\n    if const unused: int = receive(value.first^, flag) -> return unused\n    return value.first\nif const status: int = run(false) -> exit(status) else exit(97)",
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .possibly_transferred);
    }
}

test "init capture repeated writes retain their original storage parameter" {
    try Fixture.expectSourceExit(
        \\func increment(mut value: int) int
        \\    value += 1
        \\    return 0
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    var value = 0
        \\    const unused: int = materialize(if true == true
        \\        value = 20
        \\        value = 41
        \\        increment(value)
        \\    else 0)
        \\    return value
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture writes refresh returned references to caller storage" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func materialize(init item: Ref(int)) Ref(int) -> return item
        \\func run() int | none
        \\    var value = 1
        \\    const reference: Ref(int) = materialize(if true == true
        \\        value = 42
        \\        Ref.from(value)
        \\    else Ref.from(value)) else return none
        \\    var alias = Ref.from(value)
        \\    alias.value = 7
        \\    return reference.value + 35
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
}

test "init capture explicit drop obligations survive possible skipped transfers" {
    const sources = [_][]const u8{
        "struct Item\n    value: int\n    drop = explicit\nfunc consume(deinit value: Item) int -> return value.value\nfunc materialize(init item: int) int -> return item\nfunc skip(init item: int) int | none\n    if not (1 == 0) -> return none\n    return item\nfunc run() int | none\n    const source = Item{value = 42}\n    if const value: int = skip(consume(source)) -> return value\n    return 0\nif const status: int = run() -> exit(status) else exit(97)",
        "struct Item\n    value: int\n    drop = explicit\nstruct Pair\n    first: Item\n    second: int\nfunc consume(deinit value: Item) int -> return value.value\nfunc skip(init item: int) int | none\n    if not (1 == 0) -> return none\n    return item\nfunc run() int | none\n    const source = Pair{first = Item{value = 42}, second = 0}\n    if const value: int = skip(consume(source.first)) -> return value\n    return 0\nif const status: int = run() -> exit(status) else exit(97)",
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .value_requires_explicit_drop);
    }
}

test "init capture writes do not remove caller transfer authority" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 42 -> return else exit(99)
        \\func materialize(init item: Item) Item -> return item
        \\func run() int | none
        \\    var source = Item{value = 41}
        \\    const destination: Item = materialize(if true == true
        \\        source.value = 42
        \\        source^
        \\    else Item{value = 42})
        \\    return destination.value
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture restored sources support successive receiving calls" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 42 -> return else exit(99)
        \\func take(var item: Item) int -> return item.value
        \\func materialize(static T: type, init item: T) T -> return item
        \\func run() int | none
        \\    var source = Item{value = 42}
        \\    const first = materialize(int, if true == true
        \\        take(source^)
        \\        source = Item{value = 42}
        \\        0
        \\    else 0)
        \\    const second = materialize(Item, source^)
        \\    return first + second.value
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture explicit references preserve deferred place access" {
    try Fixture.expectSourceExit(
        \\import std.memory
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    var value = 1
        \\    var alias = Ref.from(value)
        \\    const result: int = materialize(if true == true
        \\        alias.value = 42
        \\        alias.value
        \\    else 0)
        \\    return value + result - 42
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
}

test "init capture nested reference projections survive selection and wrapping" {
    try Fixture.expectSourceExit(
        \\struct Inner
        \\    reference: Ref(int)
        \\    copy = trivial
        \\struct Outer
        \\    inner: Inner
        \\func materialize(static T: type, init item: T) T -> return item
        \\func forward(static T: type, init item: T) T -> return materialize(T, item)
        \\func run() int | none
        \\    var value = 42
        \\    const source = Outer{inner = Inner{reference = Ref.from(value)}}
        \\    const selected = forward(Ref(int), source.inner.reference) else return none
        \\    const wrapped = forward(Outer, Outer{inner = source.inner}) else return none
        \\    return selected.value + wrapped.inner.reference.value - 42
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
    const selected = try Fixture.initFiles(
        \\struct References
        \\    external: Ref(int)
        \\    local: Ref(int)
        \\func materialize(init item: Ref(int)) Ref(int) -> return item
        \\func select(imm external: Ref(int)) Ref(int) | none
        \\    var local = 1
        \\    const source = References{external = external, local = Ref.from(local)}
        \\    return materialize(source.external)
        \\var value = 42
        \\if const status: Ref(int) = select(Ref.from(value)) -> exit(status.value) else exit(97)
    , &.{});
    defer selected.deinit();
    try selected.expectExit(0, 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Inner
        \\    reference: Ref(int)
        \\    copy = trivial
        \\struct Outer
        \\    inner: Inner
        \\func materialize(init item: Outer) Outer -> return item
        \\func escape() Ref(int) | none
        \\    var value = 42
        \\    const source = Inner{reference = Ref.from(value)}
        \\    return materialize(Outer{inner = source}).inner.reference
        \\if const status: Ref(int) = escape() -> exit(status.value) else exit(97)
    , .borrow_outlives_source);
}

test "init capture multiple receiving calls share exact failure cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int)
        \\    drop = func(deinit self: Item)
        \\        self.counter.value = self.counter.value + 21
        \\func receive(init item: Item, imm construct: bool) int | none
        \\    if not (construct == true) -> return none
        \\    const value = item
        \\    if not (1 == 0) -> return none
        \\    return 0
        \\func run(imm first_path: bool, imm construct: bool) int | none
        \\    var counter: Box(int) = Box.new(0) else return none
        \\    var first = Item{counter = Ref.from(counter.borrow())}
        \\    var second = Item{counter = Ref.from(counter.borrow())}
        \\    if first_path == true
        \\        if const unused: int = receive(first^, construct) -> return 99
        \\    else
        \\        if const unused: int = receive(second^, construct) -> return 99
        \\    return Ref.from(counter.borrow()).value
        \\func calculate() int | none
        \\    return ((if const _selected_result_0: int = run(true, true) -> _selected_result_0 else return none) + (if const _selected_result_1: int = run(true, false) -> _selected_result_1 else return none) + (if const _selected_result_2: int = run(false, true) -> _selected_result_2 else return none) + (if const _selected_result_3: int = run(false, false) -> _selected_result_3 else return none)) / 4
        \\if const answer: int = calculate() -> exit(answer) else exit(98)
    , 42);
}

test "init capture receiving mutable reference outputs preserve initializer origins" {
    try Fixture.expectSourceExit(
        \\func install(init input: Ref(int), mut output: Ref(int)) unit | none
        \\    output = input
        \\    return ()
        \\func forward(init input: Ref(int), mut output: Ref(int)) unit | none
        \\    const _: unit = install(input, output) else return none
        \\    return ()
        \\func run() int | none
        \\    var old = 1
        \\    var value = 42
        \\    var output = Ref.from(old)
        \\    const callback: func(init Ref(int), mut Ref(int)) unit | none = forward
        \\    callback(Ref.from(value), output)
        \\    return output.value
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\func install(init input: Ref(int), mut output: Ref(int)) unit | none
        \\    output = input
        \\    return ()
        \\func escape(imm previous: Ref(int)) Ref(int) | none
        \\    var local = 42
        \\    var output = previous
        \\    const _: unit = install(Ref.from(local), output) else return none
        \\    return output
        \\var value = 1
        \\if const status: Ref(int) = escape(Ref.from(value)) -> exit(status.value) else exit(97)
    , .borrow_outlives_source);
}

test "init checkpoint consumes independently on conditional and loop exits" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int -> return item
        \\func choose(init item: int, imm flag: int) int | none
        \\    if flag == 1 -> return materialize(item) else return item
        \\func leave(init item: int) int | none
        \\    return loop -> break item
        \\static answer = if const computed: int = choose(20, 1) -> if const additional_computed: int = leave(22) -> computed + additional_computed else 97 else 97
        \\if const status: int = choose(20, 0) -> if const additional_status: int = leave(answer - 20) -> exit(status + additional_status) else exit(97) else exit(97)
    , 42);
}

test "init checkpoint rejects eager mutations and transfers of pending captures" {
    const Case = struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) };
    const cases = [_]Case{
        .{ .source = "func materialize(init item: int, imm eager: int) int -> return item\nfunc run() int | none\n    var value = 42\n    return materialize(value, if 1 == 1\n        value = 7\n        0\n    else 0)\nif const status: int = run() -> exit(status) else exit(97)", .diagnostic = .initializer_capture_conflict },
        .{ .source = "func take(deinit value: int) int -> return value\nfunc materialize(init item: int, imm eager: int) int -> return item\nfunc run() int | none\n    var value = 42\n    return materialize(value, take(value))\nif const status: int = run() -> exit(status) else exit(97)", .diagnostic = .initializer_capture_conflict },
        .{ .source = "func change(mut value: int) int\n    value = 7\n    return 0\nfunc materialize(init item: int, imm eager: int) int -> return item\nfunc run() int | none\n    var value = 42\n    return materialize(value, change(value))\nif const status: int = run() -> exit(status) else exit(97)", .diagnostic = .initializer_capture_conflict },
    };
    for (cases) |case| {
        try Fixture.expectSourceDiagnostic(case.source, case.diagnostic);
    }
}

test "init checkpoint supports handled failure and skipped construction" {
    try Fixture.expectSourceExit(
        \\func fail_value() int | none
        \\    if not (1 == 0) -> return none
        \\    return 0
        \\func materialize(init item: int) int -> return item
        \\func skip(init item: int) int | none
        \\    const _: int = fail_value() else return none
        \\    return item
        \\func producer() int -> exit(99)
        \\if (skip(producer()) is int) -> exit(1)
        \\if const status: int = materialize(if const result: int = fail_value() -> result else 42) -> exit(status) else exit(97)
    , 42);
}

test "unused initializer captures preserve caller cleanup ordering" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    value: int
        \\    drop = func(deinit self: Source) -> exit(42)
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    const unrelated = Source{value = 7}
        \\    _ = unrelated.value
        \\    return materialize(exit(99))
        \\if const result: int = run() -> exit(result) else exit(97)
    , 42);
}

test "init checkpoint retains captured owners and defers copy hooks" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    value: int
        \\    copy = func(imm self: Source) Source -> exit(99)
        \\    drop = func(deinit self: Source) -> exit(98)
        \\func skip(init item: Source) int | none -> exit(42)
        \\func run() int | none
        \\    var source = Source{value = 7}
        \\    return (if const _selected_result_0: int = skip(source) -> _selected_result_0 else return none)
        \\if const status: int = run() -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint copies captured values once and leaves fresh results in place" {
    try Fixture.expectSourceExit(
        \\struct Copied
        \\    value: int
        \\    copy = func(imm self: Copied) Copied -> return Copied{value = self.value + 1}
        \\struct Pinned
        \\    value: int
        \\    move = func(deinit self: Pinned) Pinned -> return Pinned{value = self.value + 7}
        \\func copy_item(init item: Copied) Copied | none -> return item
        \\func pin_item(init item: Pinned) Pinned | none -> return item
        \\func produce() Pinned -> return Pinned{value = 42}
        \\func run() int | none
        \\    var original = Copied{value = 41}
        \\    const copied: Copied = copy_item(original) else return none
        \\    const pinned: Pinned = pin_item(produce()) else return none
        \\    return copied.value + pinned.value - 42
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init lexical ordinary consuming break retains cleanup before call" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    value: int
        \\    drop = func(deinit self: Source) -> exit(31)
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Source, imm eager: int) int -> return item.value
        \\func fail_value() int | none
        \\    if not (1 == 0) -> return none
        \\    return 0
        \\func run() int | none
        \\    const source = Source{value = 42}
        \\    return consume(loop
        \\        if 1 == 1 -> break source
        \\        break Source{value = 99}
        \\    , (if const _selected_result_0: int = fail_value() -> _selected_result_0 else return none))
        \\if const result: int = run() -> exit(result) else exit(99)
    , 31);
}

test "init lexical pending consumption preserves roots and fields across joins" {
    const expressions = [_][]const u8{
        \\loop
        \\        if captured == true -> break selected
        \\        break Source{counter = Ref.from(counter.borrow()), weight = 10}
        \\    , eager(succeeds)
        ,
        \\if captured == true -> loop
        \\        if 1 == 1 -> break selected
        \\        break Source{counter = Ref.from(counter.borrow()), weight = 99}
        \\    else Source{counter = Ref.from(counter.borrow()), weight = 10}, eager(succeeds)
        ,
        \\loop
        \\        break loop
        \\            if captured == true -> break selected
        \\            break Source{counter = Ref.from(counter.borrow()), weight = 10}
        \\    , eager(succeeds)
        ,
    };
    const places = [_]struct { declaration: []const u8, payload: []const u8, captured_count: u32, fresh_count: u32, adjustment: []const u8 }{
        .{
            .declaration =
            \\    var source = Source{counter = Ref.from(counter.borrow()), weight = 1}
            \\    return
            ,
            .payload = "source",
            .captured_count = 1,
            .fresh_count = 11,
            .adjustment = " + 18",
        },
        .{
            .declaration =
            \\    var pair = Pair{selected = Source{counter = Ref.from(counter.borrow()), weight = 1}, sibling = Source{counter = Ref.from(counter.borrow()), weight = 100}}
            \\    return
            ,
            .payload = "pair.selected",
            .captured_count = 101,
            .fresh_count = 111,
            .adjustment = " - 382",
        },
    };
    for (places) |place| {
        const outcomes = try testing.allocator.print(
            \\    if const unused = attempt(counter, true, true) -> ()
            \\    if Ref.from(counter.borrow()).value == {d} -> () else exit(91)
            \\    if const unused = attempt(counter, false, true) -> ()
            \\    if Ref.from(counter.borrow()).value == {d} -> () else exit(92)
            \\    if const unused = attempt(counter, true, false) -> ()
            \\    if Ref.from(counter.borrow()).value == {d} -> () else exit(93)
            \\    if const unused = attempt(counter, false, false) -> ()
            \\    if Ref.from(counter.borrow()).value == {d} -> () else exit(94)
            \\    return Ref.from(counter.borrow()).value
        , .{ place.captured_count, place.captured_count + place.fresh_count, 2 * place.captured_count + place.fresh_count, 2 * (place.captured_count + place.fresh_count) });
        defer testing.allocator.free(outcomes);
        for (expressions) |expression| {
            const selected_expression = try std.mem.replaceOwned(u8, testing.allocator, expression, "selected", place.payload);
            defer testing.allocator.free(selected_expression);
            for ([_]bool{ false, true }) |deferred| {
                errdefer std.debug.print("consuming join: payload={s}, deferred={}, expression={s}\n", .{ place.payload, deferred, expression });
                const source = try std.mem.concat(testing.allocator, u8, &.{
                    \\struct Source
                    \\    counter: Ref(int)
                    \\    weight: int
                    \\    drop = func(deinit self: Source)
                    \\        self.counter.value = self.counter.value + self.weight
                    \\struct Pair
                    \\    selected: Source
                    \\    sibling: Source
                    \\func materialize(init item: int) int -> return item
                    \\func receiver(init item: int) int -> return item
                    \\func dispose(var item: Source) -> ()
                    \\func consume(deinit item: Source, imm extra: int) int
                    \\    const result = item.weight
                    \\    dispose(item^)
                    \\    return result
                    \\func eager(imm succeeds: bool) int
                    \\    succeeds == true
                    \\    return 0
                    \\func attempt(mut counter: Box(int), imm captured: bool, imm succeeds: bool) int
                    \\
                    ,
                    place.declaration,
                    if (deferred) " receiver(consume(" else " consume(",
                    selected_expression,
                    if (deferred) "))\n" else ")\n",
                    \\func run() int | none
                    \\    var counter: Box(int) = Box.new(0) else return none
                    \\
                    ,
                    outcomes,
                    place.adjustment,
                    \\
                    \\if const answer: int = run() -> exit(answer) else exit(98)
                });
                defer testing.allocator.free(source);
                try Fixture.expectSourceExit(source, 42);
            }
        }
    }
}

test "init lexical pending consumption discharges explicit ownership only at call" {
    const source =
        \\struct Manual
        \\    value: int
        \\    drop = explicit
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Manual, imm extra: int) int -> return item.value
        \\func fail_value() int | none
        \\    if not (1 == 0) -> return none
        \\    return 0
        \\func run() int | none
        \\    const source = Manual{value = 42}
        \\    return consume(loop
        \\        if 1 == 1 -> break source
        \\        break source
        \\    , eager)
        \\if const answer: int = run() -> exit(answer) else exit(98)
    ;
    for ([_]bool{ false, true }) |fails| {
        const fixture_source = try std.mem.replaceOwned(u8, testing.allocator, source, "eager", if (fails) "(if const value: int = fail_value() -> value else return none)" else "0");
        defer testing.allocator.free(fixture_source);
        const fixture = try Fixture.initFiles(fixture_source, &.{});
        defer fixture.deinit();
        if (fails) {
            try fixture.expectDiagnostic(0, .value_requires_explicit_drop);
        } else {
            try fixture.expectExit(0, 42);
        }
    }
}

test "init lexical rejects caller return even on an unselected transfer branch" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    value: int
        \\func take(deinit item: Item) int -> return item.value
        \\func materialize(init item: int) int -> return item
        \\func run(imm leave: bool) int | none
        \\    const source = Item{value = 42}
        \\    const unused: int = materialize(if leave == true
        \\        const taken = take(source)
        \\        return taken
        \\    else 0)
        \\    return source.value
        \\if const status: int = run(false) -> exit(status) else exit(97)
    , .initializer_exit_outside_boundary);
}

fn checkRecursiveInitializerRejection(argument: []const u8) !void {
    const source = try test_sources.renderTemplate(testing.allocator,
        \\func materialize(init item: int) int
        \\    const result = item
        \\    return result + 100
        \\func recurse(imm depth: int, init item: int) int
        \\    if depth == 0 -> return materialize(item) + 100
        \\    return recurse(depth - 1, $argument) + 100
        \\func run() int
        \\    const unused = recurse(3, materialize(if 1 == 1 -> return 42 else 0))
        \\    return 99
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .{ .argument = argument });
    defer testing.allocator.free(source);
    try Fixture.expectSourceDiagnostic(source, .initializer_exit_outside_boundary);
}

test "init lexical rejects caller return through recursive wrapped handles" {
    try checkRecursiveInitializerRejection("materialize(item)");
}

test "init lexical rejects byte and zero sized caller return and break payloads" {
    try Fixture.expectSourceDiagnostic(
        \\struct Empty
        \\    move = none
        \\    copy = none
        \\func materialize(init item: bool) bool -> return item
        \\func byte_return() byte | none
        \\    const unused: bool = materialize(if 1 == 1 -> return 42 else false) else return none
        \\    return 99
        \\func byte_break() byte | none
        \\    return loop
        \\        const unused: bool = materialize(if 1 == 1 -> break 42 else false) else return none
        \\        break 99
        \\func empty_return() Empty | none
        \\    const unused: bool = materialize(if 1 == 1 -> return Empty{} else false) else return none
        \\    return Empty{}
        \\func empty_break() Empty | none
        \\    return loop
        \\        const unused: bool = materialize(if 1 == 1 -> break Empty{} else false) else return none
        \\        break Empty{}
        \\func accept(deinit item: Empty) int -> return 21
        \\func calculate() int | none
        \\    const first: byte = byte_return() else return none
        \\    const second: byte = byte_break() else return none
        \\    return accept((if const _selected_result_0: Empty = empty_return() -> _selected_result_0^ else return none)) + accept((if const _selected_result_1: Empty = empty_break() -> _selected_result_1^ else return none))
        \\static answer = if const computed: byte = byte_return() -> computed else 97
        \\static loop_answer = if const computed: byte = byte_break() -> computed else 97
        \\static empty_answer = if const computed: int = calculate() -> computed else 97
        \\if const status: int = calculate() -> exit(status + empty_answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init capture mutable copyback and calling cleanups preserve normal results" {
    const source =
        \\func disturb(imm value: int) int -> return value * 3 + 1
        \\struct Guard
        \\    value: int
        \\    drop = func(deinit self: Guard)
        \\        const unused = disturb(self.value)
        \\func receiver(mut count: int, init item: int) int | none
        \\    const guard = Guard{value = count}
        \\    count = count + 1
        \\    const result = item
        \\    return result + guard.value
        \\func forward(mut count: int, init item: int) int | none
        \\    const guard = Guard{value = count}
        \\    count = count + 1
        \\    return (if const _selected_result_0: int = receiver(count, item) -> _selected_result_0 else return none) + guard.value
        \\func run(mut count: int) int | none
        \\    return (if const _selected_result_1: int = forward(count, 39) -> _selected_result_1 else return none)
        \\func calculate() int | none
        \\    var count = 0
        \\    const result: int = run(count) else return none
        \\    return result + count
    ;
    for ([_][]const u8{ "if const answer: int = calculate() -> exit(answer) else exit(97)", "static answer = if const value: int = calculate() -> value else 97\nexit(answer)" }) |suffix| {
        const program = try testing.allocator.print("{s}\n{s}", .{ source, suffix });
        defer testing.allocator.free(program);
        const fixture = try Fixture.initFiles(program, &.{});
        defer fixture.deinit();
        fixture.expectExit(0, 42) catch |err| {
            std.debug.print("copyback mode: {s}\n", .{suffix});
            return err;
        };
    }
}

test "init lexical rejects caller return through indirect forwarding" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int | none
        \\    const result = item
        \\    return result + 100
        \\func forward(init item: int) int -> return materialize(item)
        \\func invoke(imm callback: func(init int) int, init item: int) int | none
        \\    return callback(item) + 100
        \\func run() int | none
        \\    const result: int = invoke(forward, if 1 == 1 -> return 42 else 0) else return none
        \\    return result + 100
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller value and unit returns" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: bool) bool -> return item
        \\func run() int | none
        \\    const unused: bool = materialize(if 1 == 1 -> return 42 else false) else return none
        \\    return 100
        \\func finish() unit | none
        \\    const unused: bool = materialize(if 1 == 1 -> return () else false) else return none
        \\    exit(99)
        \\    return ()
        \\static answer = if const computed: int = run() -> computed else 97
        \\static completed = if const computed: unit = finish() -> computed else unit
        \\if (finish() is unit) -> ()
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller value and bare breaks" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int | none
        \\    const result = item
        \\    return result + 100
        \\func forward(init item: int) int -> return materialize(item) + 100
        \\func run() int | none
        \\    const result = loop
        \\        const unused: int = forward(if 1 == 1 -> break 42 else 0) else return none
        \\        break 99
        \\    loop
        \\        const unused: int = materialize(if 1 == 1 -> break else 0) else return none
        \\        exit(98)
        \\    return result
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller continue after captured writes" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int | none
        \\    const result = item
        \\    return result + 100
        \\func run() int | none
        \\    var count = 0
        \\    return loop
        \\        if count == 3 -> break 42
        \\        const unused: int = materialize(if 1 == 1
        \\            count = count + 1
        \\            continue
        \\        else 0) else return none
        \\        break 99
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical region local loops remain distinct from caller loops" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    return loop
        \\        const value: int = materialize(loop
        \\            var count = 0
        \\            loop
        \\                count = count + 1
        \\                if count == 2 -> break
        \\                continue
        \\            break 42
        \\        )
        \\        break value
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init lexical rejects caller return through recursive consumers" {
    try checkRecursiveInitializerRejection("item");
}

test "init lexical forbidden caller exits remain invalid under a failure handler" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    if const value: int = materialize(if 1 == 1 -> return 42 else 0)
        \\        return value + 100
        \\    else
        \\        return 99
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical early consumer failure does not authorize a forbidden deferred exit" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int | none
        \\    if not (1 == 0) -> return none
        \\    return item
        \\func run() int | none
        \\    if const value: int = materialize(if 1 == 1 -> return 99 else 0)
        \\        return value
        \\    else
        \\        return 42
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller return during partial aggregate construction" {
    try Fixture.expectSourceDiagnostic(
        \\struct Marker
        \\    counter: Ref(int)
        \\    step: int
        \\    drop = func(deinit self: Marker)
        \\        self.counter.value = self.counter.value * 10 + self.step
        \\struct Pending
        \\    first: Marker
        \\    last: int
        \\    drop = func(deinit self: Pending) -> exit(98)
        \\func receive(init marker: Marker, init item: Pending) int | none
        \\    const held = marker
        \\    const value = item
        \\    return value.last + held.step
        \\func run(var trace: Ref(int)) int | none
        \\    const caller = Marker{counter = trace, step = 3}
        \\    const unused: int = receive(Marker{counter = trace, step = 2}, Pending{first = Marker{counter = trace, step = 1}, last = if 1 == 1 -> return 42 else 0}) else return none
        \\    return unused + caller.step
        \\func calculate() int | none
        \\    var counter: Box(int) = Box.new(0) else return none
        \\    var answer: int = run(Ref.from(counter.borrow())) else return none
        \\    if Ref.from(counter.borrow()).value == 123 -> return answer
        \\    return 99
        \\if const answer: int = calculate() -> exit(answer) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects immovable caller return payloads" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(static T: type, init item: T) T -> return item
        \\func run() Pinned | none
        \\    const unused = materialize(if 1 == 1 -> return Pinned{value = 42} else false)
        \\    return Pinned{value = 99}
        \\func calculate() int | none
        \\    const result: Pinned = run() else return none
        \\    return result.value
        \\static answer = if const computed: int = calculate() -> computed else 97
        \\if const status: int = calculate() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects immovable caller break payloads" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(init item: int) int -> return item
        \\func run() Pinned | none
        \\    return loop
        \\        const unused: int = materialize(if 1 == 1 -> break Pinned{value = 42} else 0)
        \\        break Pinned{value = 99}
        \\func calculate() int | none
        \\    const result: Pinned = run() else return none
        \\    return result.value
        \\static answer = if const computed: int = calculate() -> computed else 97
        \\if const status: int = calculate() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller break payloads with variant types" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: bool) bool -> return item
        \\func run(imm choose: bool) int | none
        \\    const selected = loop
        \\        const unused: bool = materialize(if choose == true -> break 42 else break none) else return none
        \\        break 99
        \\    if const result: int = selected -> return result
        \\    return 0
        \\static answer = if const computed: int = run(true) -> if const additional_computed: int = run(false) -> computed + additional_computed else 97 else 97
        \\if const status: int = run(true) -> if const additional_status: int = run(false) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects exits to a loop in an enclosing initializer region" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    return materialize(loop
        \\        const unused: int = materialize(if 1 == 1 -> break 42 else 0)
        \\        break 99
        \\    )
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller returns within recursive callers" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int -> return item
        \\func run(imm depth: int) int | none
        \\    if depth == 0 -> return 39
        \\    const previous: int = run(depth - 1) else return none
        \\    const unused: int = materialize(if 1 == 1 -> return previous + 1 else 0)
        \\    return 99
        \\static answer = if const computed: int = run(3) -> computed else 97
        \\if const status: int = run(3) -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller returns of checked references" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int -> return item
        \\func select(imm reference: Ref(int)) Ref(int) | none
        \\    const unused: int = materialize(if 1 == 1 -> return reference else 0)
        \\    return reference
        \\var value = 42
        \\if const status: Ref(int) = select(Ref.from(value)) -> exit(status.value) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects checked reference caller returns in blocks and multi reference callers" {
    const sources = [_][]const u8{
        "import std.memory.{}\nfunc materialize(init item: int) int -> return item\nfunc run(imm reference: Ref(int)) Ref(int) | none\n    const unused: int = materialize(if 1 == 1\n        return reference\n    else 0)\n    exit(99)\nvar value = 42\nif (run(Ref.from(value)) is Ref(int)) -> ()",
        "import std.memory.{}\nfunc materialize(init item: int) int -> return item\nfunc select(imm allowed: Ref(int), imm other: Ref(int)) Ref(int) | none\n    const unused: int = materialize(if 1 == 1 -> return allowed else 0)\n    return allowed\nvar value = 42\nif (select(Ref.from(value), Ref.from(value)) is Ref(int)) -> ()",
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .initializer_exit_outside_boundary);
    }
}

test "init lexical rejects caller return after explicit consumption" {
    try Fixture.expectSourceDiagnostic(
        \\struct Manual
        \\    value: int
        \\    drop = explicit
        \\func consume(deinit item: Manual) int -> return item.value
        \\func materialize(init item: int) never | none
        \\    const result = item
        \\    exit(result)
        \\func run() int | none
        \\    const source = Manual{value = 42}
        \\    return materialize(if 1 == 1
        \\        const consumed = consume(source)
        \\        return consumed
        \\    else consume(source))
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller consuming breaks with captured immovable storage" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\func run() int | none
        \\    const source = Pinned{value = 42}
        \\    return consume(loop
        \\        const unused: int = materialize(if 1 == 1 -> break source else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller consuming breaks with fresh immovable storage" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\func run() int | none
        \\    return consume(loop
        \\        const unused: int = materialize(if 1 == 1 -> break Pinned{value = 42} else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init capture completed root and field transfers retain exact native cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int)
        \\    weight: int
        \\    drop = func(deinit self: Item)
        \\        self.counter.value = self.counter.value + self.weight
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\func take(var item: Item) -> ()
        \\func materialize(init item: int) int -> return item
        \\func run(var counter: Ref(int)) int | none
        \\    const source = Pair{first = Item{counter = counter, weight = 10}, second = Item{counter = counter, weight = 20}}
        \\    const unused: int = materialize(if 1 == 1
        \\        take(source.first^)
        \\        42
        \\    else 0)
        \\    return unused
        \\func run_root(var counter: Ref(int)) int | none
        \\    const source = Item{counter = counter, weight = 12}
        \\    const unused: int = materialize(if 1 == 1
        \\        take(source^)
        \\        42
        \\    else 0)
        \\    return unused
        \\func calculate() int | none
        \\    var counter: Box(int) = Box.new(0) else return none
        \\    const _: int = run(Ref.from(counter.borrow())) else return none
        \\    const _: int = run_root(Ref.from(counter.borrow())) else return none
        \\    return Ref.from(counter.borrow()).value
        \\if const answer: int = calculate() -> exit(answer) else exit(99)
    , 42);
}

test "init lexical rejects caller loop exits during partial aggregate construction" {
    try Fixture.expectSourceDiagnostic(
        \\struct Marker
        \\    counter: Ref(int)
        \\    step: int
        \\    drop = func(deinit self: Marker)
        \\        self.counter.value = self.counter.value * 10 + self.step
        \\struct Pending
        \\    first: Marker
        \\    last: int
        \\    drop = func(deinit self: Pending) -> exit(98)
        \\func receive(init marker: Marker, init item: Pending) int | none
        \\    const held = marker
        \\    const value = item
        \\    return value.last + held.step
        \\func run(var trace: Ref(int)) int | none
        \\    var pass = 0
        \\    return loop
        \\        pass = pass + 1
        \\        const caller = Marker{counter = trace, step = 3}
        \\        const unused: int = receive(Marker{counter = trace, step = 2}, Pending{first = Marker{counter = trace, step = 1}, last = if pass == 1 -> continue else break 42}) else return none
        \\        break unused + caller.step
        \\func calculate() int | none
        \\    var counter: Box(int) = Box.new(0) else return none
        \\    var result: int = run(Ref.from(counter.borrow())) else return none
        \\    if Ref.from(counter.borrow()).value == 123123 -> return result
        \\    return 99
        \\if const result: int = calculate() -> exit(result) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init capture restored roots and fields clean once after nested construction" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int)
        \\    weight: int
        \\    drop = func(deinit self: Item)
        \\        self.counter.value = self.counter.value + self.weight
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\func take(var item: Item) -> ()
        \\func materialize(init item: int) int -> return item
        \\func run(var counter: Ref(int)) int | none
        \\    var source = Pair{first = Item{counter = counter, weight = 10}, second = Item{counter = counter, weight = 15}}
        \\    const unused: int = materialize(materialize(if 1 == 1
        \\        take(source.first^)
        \\        source.first = Item{counter = counter, weight = 2}
        \\        42
        \\    else 0))
        \\    return unused
        \\func run_root(var counter: Ref(int)) int | none
        \\    var source = Item{counter = counter, weight = 10}
        \\    const unused: int = materialize(materialize(if 1 == 1
        \\        take(source^)
        \\        source = Item{counter = counter, weight = 5}
        \\        42
        \\    else 0))
        \\    return unused
        \\func calculate() int | none
        \\    var counter: Box(int) = Box.new(0) else return none
        \\    const _: int = run(Ref.from(counter.borrow())) else return none
        \\    const _: int = run_root(Ref.from(counter.borrow())) else return none
        \\    return Ref.from(counter.borrow()).value
        \\if const result: int = calculate() -> exit(result) else exit(99)
    , 42);
}

test "init capture mutable copyback occurs in every forwarding frame" {
    try Fixture.expectSourceExit(
        \\func materialize(mut value: int, init item: int) int | none
        \\    value = value + 1
        \\    return item
        \\func forward(mut value: int, init item: int) int | none
        \\    value = value + 1
        \\    return materialize(value, item)
        \\func run(mut value: int) int | none
        \\    return (if const _selected_result_1: int = forward(value, 40) -> _selected_result_1 else return none)
        \\func calculate() int | none
        \\    var value = 0
        \\    const result: int = run(value) else return none
        \\    return result + value
        \\static answer = if const computed: int = calculate() -> computed else 97
        \\if const status: int = calculate() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init lexical rejects caller consuming breaks selecting captured or fresh storage" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func produce() Pinned -> return Pinned{value = 42}
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\func run(imm choose: bool) int | none
        \\    const source = Pinned{value = 42}
        \\    return consume(loop
        \\        const unused: int = materialize(if 1 == 1 -> break (if choose == true -> source else produce()) else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\static answer = if const computed: int = run(true) -> if const additional_computed: int = run(false) -> computed + additional_computed else 97 else 97
        \\if const status: int = run(true) -> if const additional_status: int = run(false) -> exit(status + additional_status + answer - 126) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller consuming breaks for movable and immovable region locals" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    value: int
        \\    move = trivial
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Item) int -> return item.value
        \\func run() int | none
        \\    return consume(loop
        \\        const unused: int = materialize(if 1 == 1
        \\            const local = Item{value = 42}
        \\            break local
        \\        else 0)
        \\        break Item{value = 99}
        \\    )
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\func run() int | none
        \\    return consume(loop
        \\        const unused: int = materialize(if 1 == 1
        \\            const local = Pinned{value = 42}
        \\            break local
        \\        else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\if const status: int = run() -> exit(status) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init checkpoint nested pending handles preserve ordinary construction" {
    try Fixture.expectSourceExit(
        \\func materialize(init item: int) int -> return item
        \\func wrap(init item: int) int
        \\    return materialize(if 1 == 1
        \\        const result = item
        \\        result
        \\    else
        \\        const result = item
        \\        result
        \\    )
        \\func pair(init first: int, init second: int) int
        \\    const left: int = materialize((if const _selected_result_1: int = wrap(first) -> _selected_result_1 else return none))
        \\    const right: int = materialize((if const _selected_result_2: int = wrap(second) -> _selected_result_2 else return none))
        \\    return left + right
        \\func run() int | none
        \\    return (if const _selected_result_3: int = wrap(42) -> _selected_result_3 else return none)
        \\static answer = if const computed: int = run() -> computed else 97
        \\static ordinary = if const computed: int = pair(20, 22) -> computed else 97
        \\if const status: int = run() -> if const additional_status: int = pair(20, 22) -> exit(status + answer + additional_status + ordinary - 126) else exit(97) else exit(97)
    , 42);
}

test "init lexical rejects caller consuming breaks with explicit root or field moves" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    value: int
        \\    move = func(deinit self: Item) Item -> return Item{value = self.value}
        \\    copy = none
        \\struct Pair
        \\    item: Item
        \\    other: int
        \\func materialize(init item: int) int -> return item
        \\func consume(deinit item: Item) int -> return item.value
        \\func pick(deinit pair: Pair, imm root: bool) int | none
        \\    const source = Item{value = 42}
        \\    return consume(loop
        \\        const unused: int = materialize(if 1 == 1 -> break (if root == true -> source^ else pair.item^) else 0)
        \\        break Item{value = 99}
        \\    )
        \\func run(imm root: bool) int | none -> return (if const _selected_result_0: int = pick(Pair{item = Item{value = 42}, other = 0}, root) -> _selected_result_0 else return none)
        \\static answer = if const computed: int = run(true) -> if const additional_computed: int = run(false) -> computed + additional_computed else 97 else 97
        \\if const status: int = run(true) -> if const additional_status: int = run(false) -> exit(status + additional_status + answer - 126) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects nested exits while evaluating caller exit payloads" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int -> return item
        \\func run() int | none
        \\    const unused: int = materialize(if 1 == 1 -> return (if 1 == 1 -> return 42 else return 42) else 0)
        \\    return unused + 100
        \\func loop_result() int | none
        \\    return loop
        \\        const unused: int = materialize(if 1 == 1 -> break (if 1 == 1 -> break 42 else break 42) else 0)
        \\        break unused + 100
        \\static answer = if const computed: int = run() -> if const additional_computed: int = loop_result() -> computed + additional_computed else 97 else 97
        \\if const status: int = run() -> if const additional_status: int = loop_result() -> exit(status + additional_status + answer - 126) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init checkpoint keeps static parameter cleanup in the caller" {
    try Fixture.expectSourceExit(
        \\struct Marker
        \\    value: int
        \\    drop = func(deinit self: Marker) -> exit(99)
        \\func materialize(init item: int) int -> return item
        \\func stop() int -> exit(42)
        \\func run(static marker: Marker) int | none
        \\    return materialize(if marker.value == 0 -> stop() else 0)
        \\if const status: int = run(Marker{value = 0}) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint preserves mutable copy back and finite forwarding recursion" {
    try Fixture.expectSourceExit(
        \\func receive(mut count: int, init item: int) int | none
        \\    count += 1
        \\    const value = item
        \\    return value + count
        \\func walk(init item: int, imm depth: int) int
        \\    if depth == 0 -> return item
        \\    return (if const _selected_result_0: int = walk(item, depth - 1) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    var count = 0
        \\    const value: int = receive(count, (if const _selected_result_1: int = walk(40, 3) -> _selected_result_1 else return none)) else return none
        \\    return value + count
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init checkpoint handles zero sized and diverging construction" {
    const sources = [_][]const u8{
        \\func materialize(init item: unit) unit -> return item
        \\func run() int | none
        \\    const value: unit = materialize(unit)
        \\    return 42
        \\static answer = if const computed: int = run() -> computed else 97
        \\exit(answer)
        ,
        \\func materialize(init item: never) int -> return item
        \\func stop() never -> exit(42)
        \\if const status: int = materialize(stop()) -> exit(status) else exit(97)
    };
    for (sources) |source| {
        try Fixture.expectSourceExit(source, 42);
    }
}

test "init inference analyzes blocks loops and unreachable branch results" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(static T: type, init item: T) T -> return item
        \\func stop() never -> exit(99)
        \\func run(imm flag: int) int | none
        \\    const value = materialize(if flag == 1
        \\        var first = 20
        \\        const second = materialize(loop -> break first + 1)
        \\        Pinned{value = second}
        \\    else
        \\        stop()
        \\        Pinned{value = 0}.missing
        \\    )
        \\    return value.value
        \\static answer = if const computed: int = run(1) -> computed else 97
        \\if const status: int = run(1) -> exit(status + answer) else exit(97)
    , 42);
}

test "init inference determines fresh immovable variants before selecting storage" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(static T: type, init item: T) T -> return item
        \\func choose(imm flag: int) int | none
        \\    const value: none | Pinned = materialize(if flag == 1 -> Pinned{value = 21} else none)
        \\    if value is Pinned -> return 21 else return 0
        \\func leave(imm flag: int) int | none
        \\    const value: none | Pinned = materialize(loop
        \\        if flag == 1 -> break Pinned{value = 21} else break none
        \\    )
        \\    if value is Pinned -> return 21 else return 0
        \\static answer = if const computed: int = choose(1) -> if const additional_computed: int = leave(1) -> computed + additional_computed else 97 else 97
        \\if const status: int = choose(0) -> if const additional_status: int = leave(0) -> exit(status + additional_status + answer) else exit(97) else exit(97)
    , 42);
}

fn checkInitializerAllocations(gpa: std.mem.Allocator, source: []const u8) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, gpa, source, &.{}, &.{});
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* != null);
}

test "init regions release every failed allocation during inference and outlining" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(allocation_failure_allocator, checkInitializerAllocations, .{
        \\func materialize(static T: type, init item: T) T -> return item
        \\func forward(init item: int) int -> return materialize(item)
        \\func run(imm input: int) int | none
        \\    const unused = 0
        \\    const captured = input + 1
        \\    return (if const _selected_result_0: int = forward((if const _selected_result_1: T = materialize(loop -> break captured) -> _selected_result_1 else return none)) -> _selected_result_0 else return none)
        \\if const result: int = run(41) -> exit(result) else exit(1)
    });
}

test "init regions release every failed allocation during compile-time execution" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(allocation_failure_allocator, checkInitializerAllocations, .{
        \\func materialize(static T: type, init item: T) T -> return item
        \\func forward(init item: int) int -> return materialize(item)
        \\func run(imm input: int) int | none
        \\    const captured = input + 1
        \\    return (if const _selected_result_0: int = forward((if const _selected_result_1: T = materialize(loop -> break captured) -> _selected_result_1 else return none)) -> _selected_result_0 else return none)
        \\static answer = if const computed: int = run(41) -> computed else 97
        \\exit(answer)
    });
}

test "init regions release every failed allocation when materializing borrowed storage" {
    if (!@import("test_options").allocation_failures) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(allocation_failure_allocator, checkInitializerAllocations, .{
        \\func materialize(static T: type, init item: T) T -> return item
        \\func run_box() int | none
        \\    const owner: Box(int) = Box.new(42) else return none
        \\    return materialize(Ref.from(owner.borrow()).value)
        \\if const boxed: int = run_box() -> exit(boxed) else exit(1)
    });
}

test "init failure cleans partial construction before the receiving frame" {
    try Fixture.expectSourceExit(
        \\struct Field
        \\    value: int
        \\    drop = func(deinit self: Field) -> exit(42)
        \\struct Pair
        \\    move = none
        \\    first: Field
        \\    second: int
        \\    drop = func(deinit self: Pair) -> exit(99)
        \\struct Guard
        \\    drop = func(deinit self: Guard) -> exit(98)
        \\func fail_value() int | none
        \\    if not (1 == 0) -> return none
        \\    return 0
        \\func materialize(init item: Pair) int | none
        \\    const guard = Guard{}
        \\    const value = item
        \\    _ = guard
        \\    return value.second
        \\if const value: int = materialize(Pair{first = Field{value = 1}, second = (if const _selected_result_0: int = fail_value() -> _selected_result_0 else panic "unexpected none")}) -> exit(1)
        \\exit(2)
    , 42);
}

test "init captures reject reference writes and implicit cleanup across eager arguments" {
    const expressions = [_][]const u8{
        "if 1 == 1\n        reference.value = 7\n        0\n    else 0",
        "change(reference)",
        "if 1 == 1\n        const guard = Guard{target = reference}\n        0\n    else 0",
        "change_hook(Hook{target = reference})",
        "if 1 == 1\n        var hook = Hook{target = reference}\n        change_hook(hook^)\n    else 0",
        "if 1 == 1\n        const hook = Hook{target = reference}\n        move_effect(hook^)\n    else 0",
    };
    for (expressions) |expression| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Guard
            \\    target: Ref(int)
            \\    drop = func(deinit self: Guard)
            \\        self.target.value = 7
            \\struct Hook
            \\    target: Ref(int)
            \\    move = func(deinit self: Hook) Hook
            \\        self.target.value = 7
            \\        return Hook{target = self.target}
            \\func change_hook(var hook: Hook) int
            \\    hook.target.value = 7
            \\    return 0
            \\func move_effect(var hook: Hook) int -> return 0
            \\func change(var reference: Ref(int)) int
            \\    reference.value = 7
            \\    return 0
            \\func receive(init item: int, imm eager: int) int -> return item
            \\func run() int
            \\    var owner: Box(int) = Box.new(42) else panic "unexpected allocation refusal"
            \\    var reference = Ref.from(owner.borrow())
            \\    return receive(Ref.from(owner.borrow()).value, $expression)
            \\if const value = run() -> exit(value) else exit(1)
        , .{ .expression = expression });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .initializer_capture_conflict);
    }
}

test "init captures read owned storage through checked internal references" {
    try Fixture.expectSourceExit(
        \\func receive(init item: int) int | none -> return item
        \\func read_parameter(imm owner: Box(int)) int | none -> return (if const _selected_result_0: int = receive(Ref.from(owner.borrow()).value) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    const owner: Box(int) = Box.new(42) else return none
        \\    return (if const _selected_result_1: int = receive(Ref.from(owner.borrow()).value) -> _selected_result_1 else return none) + (if const _selected_result_2: int = read_parameter(owner) -> _selected_result_2 else return none) - 42
        \\if const value: int = run() -> exit(value) else exit(1)
    , 42);
}

test "init captures allow unrelated reference effects and writes after construction" {
    try Fixture.expectSourceExit(
        \\struct Guard
        \\    target: Ref(int)
        \\    drop = func(deinit self: Guard)
        \\        self.target.value = 7
        \\func receive(init item: int, imm eager: int) int | none -> return item
        \\func run() int | none
        \\    var owner: Box(int) = Box.new(42) else return none
        \\    var other: Box(int) = Box.new(0) else return none
        \\    var reference = Ref.from(owner.borrow())
        \\    var changed = Ref.from(other.borrow())
        \\    const result: int = receive(Ref.from(owner.borrow()).value, if 1 == 1
        \\        const guard = Guard{target = changed}
        \\        0
        \\    else 0) else return none
        \\    reference.value = 99
        \\    return result + Ref.from(other.borrow()).value - 7
        \\if const value: int = run() -> exit(value) else exit(1)
    , 42);
}

test "init comptime cycle checks recognize fresh environments with the same values" {
    try Fixture.expectSourceDiagnostic(
        \\func repeat(init item: int) int | none
        \\    const value = item
        \\    return (if const _selected_result_0: int = repeat(value) -> _selected_result_0 else return none)
        \\static answer = if const computed: int = repeat(42) -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init comptime cycle checks permit fresh environments with changing values" {
    try Fixture.expectSourceExit(
        \\func walk(init item: int) int
        \\    const value = item
        \\    if value == 0 -> return 42
        \\    return (if const _selected_result_0: int = walk(value - 1) -> _selected_result_0 else return none)
        \\static answer = if const computed: int = walk(3) -> computed else 97
        \\if const status: int = walk(3) -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init comptime cycle checks detect repeated nested wrapped captures" {
    try Fixture.expectSourceDiagnostic(
        \\func materialize(init item: int) int -> return item
        \\func repeat(imm depth: int, init item: int) int | none
        \\    if depth == 0 -> return (if const _selected_result_0: int = repeat(depth, item) -> _selected_result_0 else return none)
        \\    return (if const _selected_result_1: int = repeat(depth - 1, (if const _selected_result_2: int = materialize(item) -> _selected_result_2 else return none)) -> _selected_result_1 else return none)
        \\static answer = if const computed: int = repeat(3, 42) -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init comptime cycle checks compare fresh aggregate inputs by value" {
    try Fixture.expectSourceDiagnostic(
        \\struct State
        \\    first: int
        \\    second: int
        \\    third: int
        \\func repeat(init item: int, imm state: State) int | none
        \\    return (if const _selected_result_0: int = repeat(item, State{first = state.first, second = state.second, third = state.third}) -> _selected_result_0 else return none)
        \\static answer = if const computed: int = repeat(42, State{first = 1, second = 2, third = 3}) -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init comptime cycle checks snapshot changing mutable aggregate inputs" {
    try Fixture.expectSourceExit(
        \\struct State
        \\    remaining: int
        \\    second: int
        \\    third: int
        \\func walk(mut state: State, init item: int) int | none
        \\    if state.remaining == 0 -> return item
        \\    state.remaining -= 1
        \\    return (if const _selected_result_0: int = walk(state, item) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    var state = State{remaining = 3, second = 0, third = 0}
        \\    return (if const _selected_result_1: int = walk(state, 42) -> _selected_result_1 else return none) + state.remaining
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init inference supports deeply nested generic immovable construction" {
    var expression = try testing.allocator.dupe(u8, "Pinned{value = 21}");
    defer testing.allocator.free(expression);
    for (0..16) |_| {
        const nested = try testing.allocator.print("materialize({s})", .{expression});
        testing.allocator.free(expression);
        expression = nested;
    }
    const source = try test_sources.renderTemplate(testing.allocator,
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func materialize(static T: type, init item: T) T -> return item
        \\func run() int
        \\    const value = $expression
        \\    return value.value
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer) else exit(97)
    , .{ .expression = expression });
    defer testing.allocator.free(source);
    try Fixture.expectSourceExit(source, 42);
}

test "init captures reject possibly aliased borrowed parameters" {
    try Fixture.expectSourceDiagnostic(
        \\func change(var reference: Ref(int)) int
        \\    reference.value = 7
        \\    return 0
        \\func receive(init item: int, imm eager: int) int | none -> return item
        \\func relay(imm owner: Box(int), var reference: Ref(int)) int | none
        \\    return (if const _selected_result_0: int = receive(Ref.from(owner.borrow()).value, change(reference)) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    var owner: Box(int) = Box.new(42) else return none
        \\    var reference = Ref.from(owner.borrow())
        \\    return (if const _selected_result_1: int = relay(owner, reference) -> _selected_result_1 else return none)
        \\if const value: int = run() -> exit(value) else exit(1)
    , .initializer_capture_conflict);
}

test "init captures reject cleanup through possibly aliased borrowed parameters" {
    try Fixture.expectSourceDiagnostic(
        \\struct Guard
        \\    target: Ref(int)
        \\    drop = func(deinit self: Guard)
        \\        self.target.value = 7
        \\func receive(init item: int, imm eager: int) int | none -> return item
        \\func relay(imm owner: Box(int), var reference: Ref(int)) int | none
        \\    return (if const _selected_result_0: int = receive(Ref.from(owner.borrow()).value, if 1 == 1
        \\        const guard = Guard{target = reference}
        \\        0
        \\    else 0) -> _selected_result_0^ else return none)
        \\func run() int | none
        \\    var owner: Box(int) = Box.new(42) else return none
        \\    var reference = Ref.from(owner.borrow())
        \\    return (if const _selected_result_1: int = relay(owner, reference) -> _selected_result_1 else return none)
        \\if const value: int = run() -> exit(value) else exit(1)
    , .initializer_capture_conflict);
}

test "init captures permit scalar parameter copies beside reference writes" {
    try Fixture.expectSourceExit(
        \\func change(var reference: Ref(int)) int
        \\    reference.value = 7
        \\    return 0
        \\func receive(init item: int, imm eager: int) int | none -> return item
        \\func relay(imm value: int, var reference: Ref(int)) int | none
        \\    return (if const _selected_result_0: int = receive(value, change(reference)) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    var owner: Box(int) = Box.new(42) else return none
        \\    var reference = Ref.from(owner.borrow())
        \\    return (if const _selected_result_1: int = relay(Ref.from(owner.borrow()).value, reference) -> _selected_result_1 else return none)
        \\if const value: int = run() -> exit(value) else exit(1)
    , 42);
}

test "init captures preserve booleans callables and aggregate storage" {
    try Fixture.expectSourceExit(
        \\struct Payload
        \\    first: int
        \\    second: int
        \\    third: int
        \\func increment(imm value: int) int -> return value + 1
        \\func materialize(static T: type, init item: T) T -> return item
        \\func run(imm flag: bool, imm callback: func(int) int) int | none
        \\    const payload = Payload{first = 20, second = 21, third = 1}
        \\    const saved = materialize(callback)
        \\    const stable = materialize(flag)
        \\    return materialize(if stable == true -> saved(payload.first + payload.second) else 0)
        \\static answer = if const computed: int = run(true, increment) -> computed else 97
        \\if const status: int = run(true, increment) -> if const additional_status: int = run(false, increment) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init comptime cycle checks materialize aggregate and variant captures" {
    const sources = [_][]const u8{
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func walk(imm remaining: int, init item: int) int | none
        \\    if remaining == 0 -> return item
        \\    return (if const _selected_result_0: int = walk(remaining - 1, item) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    const owner = Pinned{value = 42}
        \\    return (if const _selected_result_1: int = walk(2, owner.value) -> _selected_result_1 else return none)
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
        ,
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func walk(imm remaining: int, init item: int) int | none
        \\    if remaining == 0 -> return item
        \\    return (if const _selected_result_0: int = walk(remaining - 1, item) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    const owner: Pinned | none = Pinned{value = 42}
        \\    return (if const _selected_result_1: int = walk(2, if owner is Pinned -> 42 else 0) -> _selected_result_1 else return none)
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
        ,
        \\struct Empty
        \\    move = none
        \\    copy = trivial
        \\func walk(imm remaining: int, init item: Empty) int | none
        \\    if remaining == 0
        \\        const value = item
        \\        return 42
        \\    return (if const _selected_result_0: int = walk(remaining - 1, item) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    const owner = Empty{}
        \\    return (if const _selected_result_1: int = walk(2, owner) -> _selected_result_1 else return none)
        \\static answer = if const computed: int = run() -> computed else 97
        \\if const status: int = run() -> exit(status + answer - 42) else exit(97)
        ,
    };
    for (sources) |source| {
        try Fixture.expectSourceExit(source, 42);
    }
}

test "init comptime cycle checks diagnose cycles through aggregate captures" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func repeat(init item: int) int | none -> return (if const _selected_result_0: int = repeat(item) -> _selected_result_0 else return none)
        \\func run() int | none
        \\    const owner = Pinned{value = 42}
        \\    return (if const _selected_result_1: int = repeat(owner.value) -> _selected_result_1 else return none)
        \\static answer = if const computed: int = run() -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init handled forwarding failure retains skipped capture cleanup on receiver success" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int)
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.counter.value = self.counter.value + 10
        \\func forward(init item: Item, imm construct: bool) int | none
        \\    if not (construct == true) -> return none
        \\    const value = item
        \\    return 0
        \\func receive(init item: Item, imm construct: bool) int | none
        \\    if const result: int = forward(item, construct) -> return result else return 0
        \\func run(imm construct: bool) int | none
        \\    var counter: Box(int) = Box.new(0) else return none
        \\    var source = Item{counter = Ref.from(counter.borrow())}
        \\    const result: int = receive(source^, construct) else return none
        \\    return Ref.from(counter.borrow()).value + result
        \\func calculate() int | none
        \\    const constructed: int = run(true) else return none
        \\    const skipped: int = run(false) else return none
        \\    if constructed == 10 -> return constructed + skipped + 22 else return 97
        \\if const result: int = calculate() -> exit(result) else exit(98)
    , 42);
}

test "init handled forwarding failure leaves skipped and transferred access joined" {
    try Fixture.expectSourceDiagnostic(
        \\func forward(init item: int, imm construct: bool) int | none
        \\    if not (construct == true) -> return none
        \\    return item
        \\func receive(init item: int, imm construct: bool) int | none
        \\    if const result: int = forward(item, construct) -> return result else return 0
        \\func run(imm construct: bool) int | none
        \\    const source = 42
        \\    const result: int = receive(source^, construct) else return none
        \\    return source + result
        \\if const status: int = run(false) -> exit(status) else exit(97)
    , .possibly_transferred);
}

test "allocating init callable acquisition preserves field capability diagnostics" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    move = trivial
        \\    reference: Ref(int)
        \\const callback: func(init Item) Box(Item) = Box(Item).new
        \\exit(42)
    , .struct_ownership_property_incompatible_with_fields);
}

test "init milestone1 rejects caller exits across direct aliased forwarded and indirect boundaries" {
    const cases = [_]struct { declaration: []const u8, setup: []const u8, call: []const u8 }{
        .{ .declaration = "", .setup = "", .call = "materialize" },
        .{ .declaration = "static alias = materialize", .setup = "", .call = "alias" },
        .{ .declaration = "func forward(init item: int) int -> return materialize(item)", .setup = "", .call = "forward" },
        .{ .declaration = "", .setup = "const callback: func(init int) int = materialize", .call = "callback" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "return 42", "break 42", "continue" }) |exit_statement| {
            const source = try test_sources.renderTemplate(testing.allocator,
                \\func materialize(init item: int) int -> return item
                \\$declaration
                \\func run() int
                \\    $setup
                \\    return loop
                \\        const unused = $call(if 1 == 1 -> $exit_statement else 0)
                \\        break 0
                \\if const result = run() -> exit(result) else exit(99)
            , .{ .declaration = case.declaration, .setup = case.setup, .call = case.call, .exit_statement = exit_statement });
            defer testing.allocator.free(source);
            errdefer std.debug.print("boundary case: {s}, {s}\n", .{ case.call, exit_statement });
            try Fixture.expectSourceDiagnostic(source, .initializer_exit_outside_boundary);
        }
    }
}

test "init milestone1 ordinary eager caller exits remain valid across callable forms" {
    const cases = [_]struct { declaration: []const u8, setup: []const u8, call: []const u8 }{
        .{ .declaration = "", .setup = "", .call = "receive" },
        .{ .declaration = "static alias = receive", .setup = "", .call = "alias" },
        .{ .declaration = "func forward(init item: int, imm eager: int) int | none -> return receive(item, eager)", .setup = "", .call = "forward" },
        .{ .declaration = "", .setup = "const callback: func(init int, int) int = receive", .call = "callback" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "return 42", "break 42", "continue" }) |exit_statement| {
            const source = try test_sources.renderTemplate(testing.allocator,
                \\func forbidden() int -> exit(99)
                \\func receive(init item: int, imm eager: int) int
                \\    const value = item
                \\    return value + eager
                \\$declaration
                \\func run() int
                \\    $setup
                \\    var count = 0
                \\    return loop
                \\        if count == 1 -> break 42
                \\        if const unused = $call(forbidden(), if 1 == 1
                \\            count += 1
                \\            $exit_statement
                \\        else 0) -> break 98
                \\        break 97
                \\static answer = run()
                \\exit(run() + answer - 42)
            , .{ .declaration = case.declaration, .setup = case.setup, .call = case.call, .exit_statement = exit_statement });
            defer testing.allocator.free(source);
            errdefer std.debug.print("eager case: {s}, {s}\n", .{ case.call, exit_statement });
            try Fixture.expectSourceExit(source, 42);
        }
    }
}

test "init milestone1 called producer returns and local nested loop exits remain valid" {
    try Fixture.expectSourceExit(
        \\func produce() int -> return 42
        \\func materialize(init item: int) int -> return item
        \\func forward(init item: int) int -> return materialize(item)
        \\func run() int | none
        \\    const producer: func() int = produce
        \\    const callback: func(init int) int = forward
        \\    return callback(loop
        \\        var count = 0
        \\        loop
        \\            count += 1
        \\            if count == 2 -> break
        \\            continue
        \\        break producer()
        \\    )
        \\static answer = if const result: int = run() -> result else 99
        \\if const result: int = run() -> exit(result + answer - 42) else exit(98)
    , 42);
}

test "pending root and field consumption cleans once after skipped or completed initialization" {
    const cases = [_]struct { binding: []const u8, place: []const u8 }{
        .{ .binding = "const source = Item{counter = trace, weight = 42}", .place = "source" },
        .{ .binding = "const source = Pair{first = Item{counter = trace, weight = 21}, second = Item{counter = trace, weight = 21}}", .place = "source.first" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Item
            \\    counter: Ref(int)
            \\    weight: int
            \\    copy = none
            \\    drop = func(deinit self: Item)
            \\        self.counter.value = self.counter.value + self.weight
            \\struct Pair
            \\    first: Item
            \\    second: Item
            \\func dispose(var item: Item) -> ()
            \\func consume(deinit item: Item, imm eager: int) int
            \\    const value = item.weight
            \\    dispose(item^)
            \\    return value + eager
            \\func forward(init item: int) int -> return item
            \\func receive(init item: int, imm complete: bool) int | none
            \\    if not complete -> return none
            \\    const value = forward(item)
            \\    return none
            \\func attempt(var trace: Ref(int), imm complete: bool) unit | none
            \\    $binding
            \\    const callback: func(init int, bool) int | none = receive
            \\    if const unused: int = callback(consume($place, 0), complete) -> exit(99)
            \\    return ()
            \\func run(imm complete: bool) int
            \\    var counter: Box(int) = Box.new(0) else panic "unexpected allocation refusal"
            \\    _ = attempt(Ref.from(counter.borrow()), complete)
            \\    return Ref.from(counter.borrow()).value
            \\if const first = run(false)
            \\    if first == 42
            \\        if const second = run(true) -> exit(second) else exit(98)
            \\    else exit(first)
            \\else exit(97)
        , .{ .binding = case.binding, .place = case.place });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "movable replacement reads its target independently of storage representation" {
    for ([_][]const u8{
        "var values = [10, 20]\n    values = [values[0], values[1] + 12]\n    return values[0] + values[1]",
        "var pair = Pair{values = [10, 20]}\n    pair.values = [pair.values[0], pair.values[1] + 12]\n    return pair.values[0] + pair.values[1]",
        "var pair = Pair{values = [10, 20]}\n    pair = Pair{values = [pair.values[0], pair.values[1] + 12]}\n    return pair.values[0] + pair.values[1]",
        "var values = [10, 32]\n    values = values\n    values = values^\n    return values[0] + values[1]",
        "var values = [10, 20]\n    refill(values)\n    return values[0] + values[1]",
    }) |body| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Pair
            \\    values: Array(int, 2)
            \\func refill(mut values: Array(int, 2))
            \\    values = [values[0], values[1] + 12]
            \\func calculate() int
            \\    $body
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 90
        , .{ .body = body });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "movable replacement completes its RHS before dropping the old generation" {
    for ([_][]const u8{
        "var items = [Item{trace = handle, value = 1}, Item{trace = handle, value = 2}]\n        items = produce(handle)\n        if handle.value <> 321 -> return 90\n        _ = items",
        "var pair = Pair{items = [Item{trace = handle, value = 1}, Item{trace = handle, value = 2}]}\n        pair.items = produce(handle)\n        if handle.value <> 321 -> return 90\n        _ = pair",
        "var items = [Item{trace = handle, value = 1}, Item{trace = handle, value = 2}]\n        reset(items, handle)\n        if handle.value <> 321 -> return 90\n        _ = items",
    }) |body| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Item
            \\    trace: Ref(int)
            \\    value: int
            \\    drop = func(deinit self: Item)
            \\        self.trace.value = self.trace.value * 10 + self.value
            \\struct Pair
            \\    items: Array(Item, 2)
            \\func produce(var trace: Ref(int)) Array(Item, 2)
            \\    trace.value = trace.value * 10 + 3
            \\    return [Item{trace = trace, value = 4}, Item{trace = trace, value = 5}]
            \\func reset(mut items: Array(Item, 2), var trace: Ref(int))
            \\    items = produce(trace)
            \\func calculate() int
            \\    var trace = [0]
            \\    if ref slot: int = trace.get(0)
            \\        var handle = Ref.from(slot)
            \\        $body
            \\        if handle.value == 32154 -> return 42
            \\    return 91
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 92
        , .{ .body = body });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "movable replacement preserves initialization on RHS failure and caller exits" {
    for ([_][]const u8{
        "func reset(mut values: Array(int, 2)) unit | none\n    values = (if const value: Array(int, 2) = missing() -> value^ else return none)\n    return ()\nfunc run() int\n    var values = [10, 32]\n    if (reset(values) is unit) -> return 90\n    if const first = values[0]\n        if const second = values[1] -> return first + second\n    return 91",
        "func reset(mut values: Array(int, 2))\n    values = if true -> return else [0, 0]\nfunc run() int\n    var values = [10, 32]\n    reset(values)\n    if const first = values[0]\n        if const second = values[1] -> return first + second\n    return 91",
        "func reset(mut values: Array(int, 2))\n    loop\n        values = if true -> break else [0, 0]\nfunc run() int\n    var values = [10, 32]\n    reset(values)\n    if const first = values[0]\n        if const second = values[1] -> return first + second\n    return 91",
    }) |body| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ "func missing() Array(int, 2) | none -> return none\n", body });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "completed collection conversions release captures on success failure and nested calls" {
    for ([_][]const u8{
        "const copied = [number]\n    _ = copied\n    number = 42",
        "const copied: List(int) = [number]\n    _ = copied\n    bump(number)",
        "if const copied = [checked(number)] -> touch(copied)\n    number = 42",
        "if const copied: int = missing(number) -> touch([copied])\n    number = 42",
        "take(number, [number])",
    }) |body| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\func touch(imm copied: Array(int, 1)) -> return
            \\func bump(mut number: int)
            \\    number += 22
            \\func take(mut number: int, var copied: Array(int, 1))
            \\    number += 22
            \\    _ = copied
            \\func checked(number: int) int -> number
            \\func missing(number: int) int | none -> none
            \\func run() int
            \\    var number = 20
            \\    $body
            \\    return number
        , .{ .body = body });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "completed nested conversions retain pending outer initializer captures" {
    try Fixture.expectSourceDiagnostic(
        \\func take(init first: Array(int, 1), var second: Array(int, 1), mut number: int) unit | none
        \\    const ready = first
        \\    _ = second
        \\    number += ready[0]
        \\    return ()
        \\var number = 20
        \\if (take([number], [number], number) is unit) -> exit(42)
        \\exit(90)
    , .initializer_capture_conflict);
}

test "owned indexer callable semantics update incrementally with receiver reads" {
    const source =
        \\struct Value
        \\    value: int
        \\    pub func [](imm self: Value, index: int) int -> self.value
        \\    pub func []=(mut self: Value, index: int, var item: int) unit
        \\        self.value = item^
        \\func run() int
        \\    var value = Value{value = 20}
        \\    const setter = Value.[]=
        \\    setter(value, 0, value[0] + 22)
        \\    return value.value
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const edited = try std.mem.replaceOwned(u8, testing.allocator, source, "var item: int", "init item: int");
    defer testing.allocator.free(edited);
    try fixture.db.setInput(queries.SourceText, 0, edited);
    try fixture.expectDiagnostic(0, .invalid_operation_signature);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "replacement installs even an unused result after ending the old generation" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item) -> exit(self.value)
        \\func run() int
        \\    var item = Item{value = 42}
        \\    item = Item{value = 43}
        \\    return 90
    , 42);
}

test "replacement retains its old generation through a divergent RHS" {
    try Fixture.expectParity(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item) -> exit(self.value)
        \\func stop() Item -> exit(42)
        \\func run() int
        \\    var item = Item{value = 90}
        \\    item = stop()
        \\    return 91
    , 42);
}

test "reference and indexed replacement keep their owners alive through divergent preparation" {
    for ([_]struct { binding: []const u8, replacement: []const u8 }{
        .{ .binding = "var owner: Box(Item) = Box.new(Item{value = 90}) else panic \"unexpected none\"", .replacement = "var target = Ref.from(owner.borrow())\n    target.value = exit(42)" },
        .{ .binding = "var values: List(Item) = [Item{value = 90}]", .replacement = "values[0] = exit(42)" },
        .{ .binding = "var values = [Item{value = 90}]", .replacement = "values[0] = exit(42)" },
        .{ .binding = "var values = [Item{value = 90}]", .replacement = "var span = values.span()\n    span[0] = exit(42)" },
    }) |case| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Item
            \\    value: int
            \\    drop = func(deinit self: Item) -> exit(self.value)
            \\func calculate() int
            \\    $binding
            \\    $replacement
            \\    return 92
            \\func run() int
            \\    if const result = calculate() -> return result
            \\    return 93
        , .{ .binding = case.binding, .replacement = case.replacement });
        defer testing.allocator.free(source);
        try Fixture.expectParity(source, 42);
    }
}

test "failed reference replacement does not roll back explicit RHS ownership transfer" {
    try Fixture.expectParity(
        \\func consume(var owner: Box(int)) int | none -> return none
        \\func calculate() int | none
        \\    var owner: Box(int) = Box.new(20) else return none
        \\    var target: Ref(int) = Ref.from(owner.borrow()) else return none
        \\    target.value = if true
        \\        _ = (if const _selected_result_0: int = consume(owner^) -> _selected_result_0 else return none)
        \\        return none
        \\    else 0
        \\    return 90
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 42
    , 42);
}

test "review fixes discard conditional tails preserve statement semantics" {
    try Fixture.expectParity(
        \\func identity(value: int) int -> value
        \\func run() int
        \\    if true -> _ = identity(42)
        \\    if true
        \\        _ = identity(42)
        \\    const unit_value = if true
        \\        _ = identity(42)
        \\    else ()
        \\    return 42
    , 42);
}

test "review fixes mutable variant borrow preserves parameter provenance" {
    try Fixture.expectParity(
        \\import std.memory
        \\func inspect(mut value: Box(int) | none) int
        \\    if ref box: Box(int) = value
        \\        return box.borrow()
        \\    return 1
        \\func calculate() int | none
        \\    var value: Box(int) | none = Box.new(42)
        \\    return inspect(value)
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 1
    , 42);
}

test "review fixes text comparisons accept every operand order" {
    try Fixture.expectParity(
        \\func run() int
        \\    var text = "F"
        \\    const view = text.view()
        \\    if not ("F" == view) -> return 90
        \\    if not (view == "F") -> return 91
        \\    if not (text == view) -> return 92
        \\    if not (view == text) -> return 93
        \\    if "F" <> view -> return 94
        \\    if view <> text -> return 95
        \\    if not ("G" <> view) -> return 96
        \\    return 42
    , 42);
}

test "review fixes comparisons declare their right operand type" {
    try Fixture.expectParity(
        \\struct Number
        \\    pub value: int
        \\    pub func ==(imm left: Number, imm right: int) bool -> left.value == right
        \\func run() int
        \\    if Number{value = 42} == 42 -> return 42
        \\    return 90
    , 42);
}

test "review fixes type arguments compose unions grouping and callable types" {
    try Fixture.expectParity(
        \\struct Holder(T: type)
        \\    pub value: T
        \\func answer() int -> 42
        \\func calculate() int | none
        \\    const first: Array(int | none, 2) = [none, 42]
        \\    const nested: Holder(Array((int | none), 2)) = Holder(Array((int | none), 2)){value = first}
        \\    const functions: Array(func() int, 1) = [answer]
        \\    const callback = functions[0]
        \\    const candidate = nested.value[1]
        \\    if const result: int = candidate -> return callback() + result - 42
        \\    return 90
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 1
    , 42);
}

test "review fixes consuming variant extraction transfers noncopyable payloads" {
    try Fixture.expectParity(
        \\func calculate() int | none
        \\    var source: Box(int) | none = Box.new(42)
        \\    if const payload: Box(int) = source^
        \\        const moved = payload^
        \\        return Ref.from(moved.borrow()).value
        \\    return 90
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
    try Fixture.expectParity(
        \\func create() Box(int) | none -> (if const _selected_result_0: Box(int) = Box.new(42) -> _selected_result_0^ else return none)
        \\func calculate() int | none
        \\    if const payload: Box(int) = create() -> return Ref.from(payload.borrow()).value
        \\    return 90
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
}

test "review fixes consuming variant extraction drops each active payload once" {
    try Fixture.expectParity(
        \\import std.memory
        \\struct Tracked
        \\    pub counter: Ref(int)
        \\    copy = none
        \\    drop = func(deinit self: Tracked)
        \\        self.counter.value += 1
        \\func inspect(var source: Tracked | int | none) int
        \\    if const payload: Tracked = source^ -> return 10
        \\    return 20
        \\func miss(var source: Tracked | int | none) int
        \\    if const payload: int = source^ -> return 90
        \\    return 0
        \\func subset(var source: Tracked | int | none) int
        \\    if const payload: Tracked | none = source^
        \\        if ref tracked: Tracked = payload -> return 0
        \\    return 90
        \\func calculate() int | none
        \\    var drops: Box(int) = Box.new(0) else return none
        \\    var first = inspect(Tracked{counter = Ref.from(drops.borrow())})
        \\    var second = miss(Tracked{counter = Ref.from(drops.borrow())})
        \\    var third = subset(Tracked{counter = Ref.from(drops.borrow())})
        \\    return first + second + third + Ref.from(drops.borrow()).value + 29
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
}

test "review fixes consuming variant extraction invalidates source on both paths" {
    for ([_][]const u8{ "int", "none" }) |target| {
        const read_source = try std.fmt.allocPrint(testing.allocator, "func observe(imm value: int | none) int -> 42\nvar source: int | none = 42\nif const value: {s} = source^ -> ()\nexit(observe(source))", .{target});
        defer testing.allocator.free(read_source);
        try Fixture.expectSourceDiagnostic(read_source, .use_after_transfer);
    }
}

test "review fixes reference dereferences and projections are mutable argument places" {
    try Fixture.expectParity(
        \\struct Point
        \\    pub x: int
        \\    pub y: int
        \\func increment(mut value: int)
        \\    value += 1
        \\func calculate() int | none
        \\    var owner: Box(Point) = Box.new(Point{x = 19, y = 20}) else return none
        \\    var handle: Ref(Point) = Ref.from(owner.borrow()) else return none
        \\    increment(handle.value.x)
        \\    handle.value.y += 2
        \\    return handle.value.x + handle.value.y
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
    try Fixture.expectParity(
        \\func increment(mut value: int)
        \\    value += 1
        \\func calculate() int | none
        \\    var value: Box(int) = Box.new(41) else return none
        \\    increment(Ref.from(value.borrow()).value)
        \\    return Ref.from(value.borrow()).value
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
}

test "review fixes reference field assignments evaluate the handle once" {
    try Fixture.expectParity(
        \\struct Point
        \\    pub x: int
        \\func handle(mut point: Box(Point), mut calls: int) Ref(Point)
        \\    calls += 1
        \\    return Ref.from(point.borrow())
        \\func calculate() int | none
        \\    var point: Box(Point) = Box.new(Point{x = 40}) else return none
        \\    var calls = 0
        \\    handle(point, calls).value.x += 1
        \\    return Ref.from(point.borrow()).value.x + calls
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
}

test "review fixes indexed explicit borrows avoid noncopyable element copies" {
    try Fixture.expectParity(
        \\struct Row
        \\    copy = none
        \\    pub score: int
        \\func calculate() int | none
        \\    var rows = [Row{score = 20}, Row{score = 21}]
        \\    const row: Ref(Row) = Ref.from(rows[0])
        \\    const first = row.value.score
        \\    var second: Ref(Row) = Ref.from(rows[1])
        \\    second.value.score += 1
        \\    const total = first + second.value.score
        \\    Ref.from(rows[0]).value.score += 1
        \\    return total
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 90
    , 42);
}

test "review fixes discard also works in an inline function body" {
    try Fixture.expectParity(
        \\func discard(imm value: int) -> _ = value
        \\func run() int
        \\    discard(42)
        \\    const ignored = _ = 42
        \\    return 42
    , 42);
}

test "review fixes explicit indexed borrows compose fields nesting and handled bounds" {
    try Fixture.expectParity(
        \\import std.memory
        \\struct Row
        \\    copy = none
        \\    pub score: int
        \\func calculate() int | none
        \\    var rows = [[Row{score = 20}, Row{score = 21}]]
        \\    var score = Ref.from(rows[0][0].score)
        \\    score.value += 1
        \\    if ref invalid: Array(Row, 2) = rows.get(1) -> return 90
        \\    if ref row: Row = rows[0].get(1)
        \\        row.score += 0
        \\        const first = Ref.from(rows[0][0])
        \\        return first.value.score + row.score
        \\    return 91
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 92
    , 42);
}

test "review fixes readonly reference places cannot become mutable" {
    try Fixture.expectSourceDiagnostic(
        \\func increment(mut value: int)
        \\    value += 1
        \\func calculate() int | none
        \\    const value: Box(int) = Box.new(41) else return none
        \\    increment(Ref.from(value.borrow()).value)
        \\    return 42
        \\if const result: int = calculate() -> exit(result)
    , .mutable_argument_requires_mutable_place);
    try Fixture.expectSourceDiagnostic(
        \\struct Point
        \\    pub x: int
        \\func calculate() int | none
        \\    const point: Box(Point) = Box.new(Point{x = 41}) else return none
        \\    Ref.from(point.borrow()).value.x = 42
        \\    return 42
        \\if const result: int = calculate() -> exit(result)
    , .reference_not_writable);
}

test "review fixes overlapping explicit reference arguments are rejected" {
    for ([_][]const u8{ "handle.value", "Ref.from(value.borrow()).value" }) |other| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\func observe(mut left: int, ref right: int) int
            \\    left += 1
            \\    return right
            \\func calculate() int
            \\    var value: Box(int) = Box.new(41) else panic "unexpected allocation refusal"
            \\    var handle = Ref.from(value.borrow())
            \\    return observe(handle.value, $other)
            \\if const result = calculate() -> exit(result)
        , .{ .other = other });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .overlapping_mutable_arguments);
    }
}

test "review fixes disjoint fields through one explicit reference can be mutable arguments" {
    try Fixture.expectParity(
        \\struct Pair
        \\    pub first: int
        \\    pub second: int
        \\func increment(mut left: int, mut right: int)
        \\    left += 1
        \\    right += 1
        \\func calculate() int | none
        \\    var pair: Box(Pair) = Box.new(Pair{first = 19, second = 21}) else return none
        \\    var handle: Ref(Pair) = Ref.from(pair.borrow()) else return none
        \\    increment(handle.value.first, handle.value.second)
        \\    return Ref.from(pair.borrow()).value.first + Ref.from(pair.borrow()).value.second
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
}

test "review fixes mutable variant projection still rejects owner invalidation" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory
        \\func inspect(mut value: Box(int) | none) int
        \\    if ref box: Box(int) = value
        \\        const handle = Ref.from(box.borrow())
        \\        value = none
        \\        return handle.value
        \\    return 1
        \\func calculate() int | none
        \\    var value: Box(int) | none = Box.new(42)
        \\    return inspect(value)
        \\if const result: int = calculate() -> exit(result)
    , .borrow_outlives_source);
}

test "review fixes indexed noncopyable elements can be read without moving" {
    for ([_][]const u8{ "var rows = [Row{score = 42}]", "var rows: List(Row) = [Row{score = 42}]", "var backing = [Row{score = 42}]\n    const rows = backing.span()" }) |binding| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\pub struct Row
            \\    copy = none
            \\    pub score: int
            \\func calculate() int
            \\    $binding
            \\    return rows[0].score
            \\if const result = calculate() -> exit(result)
        , .{ .binding = binding });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "review fixes extraction and type expression edits invalidate cached analyses" {
    const source =
        \\pub struct Value
        \\    copy = none
        \\    pub number: int
        \\struct Holder(T: type)
        \\    pub value: T
        \\func create() Value | none -> Value{number = 42}
        \\func run() int
        \\    const holder = Holder(Value | none){value = create()}
        \\    if const value: Value = holder.value^ -> return value.number
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const borrowed = try std.mem.replaceOwned(u8, testing.allocator, source, "holder.value^", "holder.value");
    defer testing.allocator.free(borrowed);
    try fixture.db.setInput(queries.SourceText, 0, borrowed);
    try fixture.expectDiagnostic(0, .type_not_copyable);
    const changed = try std.mem.replaceOwned(u8, testing.allocator, source, "number = 42", "number = 43");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(0, 43);
}

test "review fixes consuming extraction narrows explicit drop obligations on failure" {
    try Fixture.expectParity(
        \\struct Token
        \\    copy = none
        \\    drop = explicit
        \\    pub number: int
        \\struct Tracked
        \\    copy = none
        \\    pub counter: Ref(int)
        \\    drop = func(deinit self: Tracked)
        \\        self.counter.value += 1
        \\func dispose(deinit token: Token) -> ()
        \\func inspect(var source: Token | Tracked | none) int
        \\    if const token: Token = source^
        \\        const number = token.number
        \\        dispose(token)
        \\        return number
        \\    return 0
        \\func calculate() int | none
        \\    var drops: Box(int) = Box.new(0) else return none
        \\    const success = inspect(Token{number = 41})
        \\    var failure = inspect(Tracked{counter = Ref.from(drops.borrow())})
        \\    const empty = inspect(none)
        \\    return success + failure + empty + Ref.from(drops.borrow()).value
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Token
        \\    drop = explicit
        \\func inspect(var source: Token | none)
        \\    if const empty: none = source^ -> ()
        \\inspect(Token{})
    , .value_requires_explicit_drop);
}

test "review fixes inline unit bodies discard results with ordinary effects" {
    try Fixture.expectParity(
        \\static Void: type = unit
        \\func increment(mut value: int) -> value += 1
        \\func increment_alias(mut value: int) Void -> value += 1
        \\func run() int
        \\    var value = 40
        \\    increment(value)
        \\    increment_alias(value)
        \\    return value
    , 42);
    try Fixture.expectSourceDiagnostic("func bad() unit -> return 42\nbad()", .return_type_mismatch);
}

test "disjunction joins consumed recursive owners without retaining ended bindings" {
    try Fixture.expectParity(
        \\struct Constant
        \\    copy = trivial
        \\    value: int
        \\struct Pair
        \\    left: Box(Expr)
        \\    right: Box(Expr)
        \\struct Expr
        \\    term: Constant | Pair
        \\func literal(imm node: Expr) int | none
        \\    if const value: Constant = node.term -> return value.value
        \\    return none
        \\func evaluate() int | none
        \\    var tree: Box(Expr) = Box.new(Expr{term = Pair{left = (if const _selected_result_0: Box(Expr) = Box.new(Expr{term = Constant{value = 1}}) -> _selected_result_0^ else panic "unexpected none"), right = (if const _selected_result_1: Box(Expr) = Box.new(Expr{term = Constant{value = 2}}) -> _selected_result_1^ else panic "unexpected none")}}) else return none
        \\    var owned = tree.take()
        \\    if owned.term is Pair
        \\        const pair: Pair = owned.term^ else return none
        \\        const left = pair.left^
        \\        const right = pair.right^
        \\        if (if const _selected_result_2: int = literal(Ref.from(left.borrow()).value) -> _selected_result_2 else return none) == 0 or (if const _selected_result_4: int = literal(Ref.from(right.borrow()).value) -> _selected_result_4 else return none) == 0 -> return 1
        \\        return 42
        \\    return 4
        \\func run() int
        \\    if const result: int = evaluate() -> return result
        \\    return 90
    , 42);
}

test "disjunction joins consumed recursive owners preserve cleanup and short circuiting" {
    const fixture = try Fixture.init(
        \\import std.memory
        \\struct Constant
        \\    value: int
        \\    copy = none
        \\    drop = func(deinit self: Constant) -> print("drop")
        \\struct Pair
        \\    left: Box(Expr)
        \\    right: Box(Expr)
        \\struct Expr
        \\    term: Constant | Pair
        \\func literal(imm node: Expr, var calls: Ref(int)) int | none
        \\    calls.value += 1
        \\    if ref constant: Constant = node.term
        \\        if not (constant.value >= 0) -> return none
        \\        return constant.value
        \\    return none
        \\func zero(imm node: Expr, var calls: Ref(int)) bool
        \\    if const value: int = literal(node, calls) -> return value == 0
        \\    return false
        \\func inspect(var tree: Box(Expr), var calls: Ref(int)) int | none
        \\    var owned = tree.take()
        \\    if owned.term is Pair
        \\        const pair: Pair = owned.term^ else return none
        \\        const left = pair.left^
        \\        const right = pair.right^
        \\        if zero(left.borrow(), calls) or zero(right.borrow(), calls) -> return 1
        \\        return 0
        \\    return 90
        \\func check(left: int, right: int, expected: int, expected_calls: int) unit | none
        \\    var calls: Box(int) = Box.new(0) else return none
        \\    const tree: Box(Expr) = Box.new(Expr{term = Pair{left = (if const _selected_result_4: Box(Expr) = Box.new(Expr{term = Constant{value = left}}) -> _selected_result_4^ else panic "unexpected none"), right = (if const _selected_result_5: Box(Expr) = Box.new(Expr{term = Constant{value = right}}) -> _selected_result_5^ else panic "unexpected none")}}) else return none
        \\    if not ((if const _selected_result_6: int = inspect(tree^, Ref.from(calls.borrow())) -> _selected_result_6 else return none) == expected) -> return none
        \\    if not (Ref.from(calls.borrow()).value == expected_calls) -> return none
        \\    return ()
        \\func run() int
        \\    if not (check(0, 1, 1, 1) is unit) -> return 91
        \\    if not (check(1, 0, 1, 2) is unit) -> return 92
        \\    if not (check(1, 2, 0, 2) is unit) -> return 93
        \\    if not (check(-1, 0, 1, 2) is unit) -> return 94
        \\    if not (check(-1, 2, 0, 2) is unit) -> return 95
        \\    return 42
        \\exit(run())
    );
    defer fixture.deinit();
    const result = try fixture.runIo("");
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
    try testing.expectEqualStrings("drop\ndrop\ndrop\ndrop\ndrop\ndrop\ndrop\ndrop\ndrop\ndrop\n", result.stdout);
    try testing.expectEqualStrings("", result.stderr);
}

test "explicit references infer readonly and writable referent types" {
    try Fixture.expectParity(
        \\func copy_value(static T: type, reference: Ref(T)) T -> reference.value
        \\func replace_value(static T: type, var reference: Ref(T), value: T)
        \\    reference.value = value
        \\func increment(value: int) int -> value + 1
        \\func invoke(Ref: func(int) int) int -> Ref(41)
        \\func run() int
        \\    var value = 17
        \\    var writable: Ref(int) = Ref.from(value)
        \\    replace_value(writable, invoke(increment))
        \\    return copy_value(Ref.from(value))
    , 42);
    try Fixture.expectParity(
        \\func first(value: int) int -> value + 1
        \\func second(value: int) int -> value + 2
        \\func run() int
        \\    var callback: func(int) int = first
        \\    var reference: Ref(func(int) int) = Ref.from(callback)
        \\    reference.value = second
        \\    return callback(40)
    , 42);
}

test "explicit reference syntax rejects removed forms and permission upgrades" {
    try Fixture.expectSourceDiagnostic(
        \\var value = 42
        \\borrow mut item = value
        \\exit(value)
    , .expected_token);
    try Fixture.expectSourceDiagnostic(
        \\const value = 42
        \\const item: Ref(int, false) = Ref.from(value)
        \\exit(item.value)
    , .call_argument_count_mismatch);
    try Fixture.expectSourceDiagnostic(
        \\func inspect(value: mut int) int -> value
        \\exit(inspect(42))
    , .invalid_expression);
    try Fixture.expectSourceDiagnostic(
        \\const value: int | none = 42
        \\const reference = Ref.from(value)
        \\if ref part: int = reference.value -> part += 1
    , .reference_not_writable);
}

test "const reference carriers preserve field-sensitive generic contracts incrementally" {
    const source =
        \\struct Left
        \\    copy = none
        \\    pub value: int
        \\struct Right
        \\    copy = none
        \\    pub value: int
        \\struct Pair(A: type, B: type)
        \\    copy = trivial
        \\    pub first: Ref(A)
        \\    pub second: Ref(B)
        \\func update(static A: type, static B: type, ref pair: Pair(A, B))
        \\    pair.first.value.value += 30
        \\func first(static A: type, static B: type, ref pair: Pair(A, B)) ref A
        \\    return pair.first.value
        \\func selected(ref left: Left) ref Left
        \\    const right = Right{value = 7}
        \\    const pair = Pair(Left, Right){first = Ref.from(left), second = Ref.from(right)}
        \\    update(pair)
        \\    return first(pair)
        \\func run() int
        \\    var owner = Left{value = 12}
        \\    ref result = selected(owner)
        \\    return result.value
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const readonly = try std.mem.replaceOwned(u8, testing.allocator, source, "var owner =", "const owner =");
    defer testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectDiagnostic(0, .reference_not_writable);

    const reading = try std.mem.replaceOwned(u8, testing.allocator, readonly, "pair.first.value.value += 30", "_ = pair.first.value.value");
    defer testing.allocator.free(reading);
    try fixture.db.setInput(queries.SourceText, 0, reading);
    try fixture.expectExit(0, 12);

    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "reference tuple generic contracts recompute permissions and origins" {
    const source =
        \\struct Left
        \\    copy = none
        \\    pub value: int
        \\struct Right
        \\    copy = none
        \\    pub value: int
        \\func update(static A: type, static B: type, ref pair: (ref A, ref B))
        \\    pair.0.value += 30
        \\func first(static A: type, static B: type, ref pair: (ref A, ref B)) ref A
        \\    return pair.0
        \\func selected(ref left: Left) ref Left
        \\    const right = Right{value = 7}
        \\    const pair: (ref Left, ref Right) = (left, right)
        \\    update(pair)
        \\    return first(pair)
        \\func run() int
        \\    var owner = Left{value = 12}
        \\    ref result = selected(owner)
        \\    return result.value
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const readonly = try std.mem.replaceOwned(u8, testing.allocator, source, "var owner =", "const owner =");
    defer testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectDiagnostic(0, .reference_not_writable);

    const reading = try std.mem.replaceOwned(u8, testing.allocator, readonly, "pair.0.value += 30", "_ = pair.0.value");
    defer testing.allocator.free(reading);
    try fixture.db.setInput(queries.SourceText, 0, reading);
    try fixture.expectExit(0, 12);

    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
}

test "reference projections retain allocated parameter storage without exposing parameter copies" {
    try Fixture.expectParity(
        \\func selected(value: Box(int) | none) Ref(int) | none
        \\    if ref box: Box(int) = value -> return Ref.from(box.borrow())
        \\    return none
        \\func calculate() int | none
        \\    const owner: Box(int) = Box.new(42) else return none
        \\    if const reference: Ref(int) = selected(owner) -> return reference.value
        \\    return 90
        \\func run() int
        \\    if const result: int = calculate() -> return result
        \\    return 91
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\struct Pair
        \\    copy = trivial
        \\    value: int
        \\func escape(pair: Pair) Ref(int) -> Ref.from(pair.value)
        \\const reference = escape(Pair{value = 42})
        \\exit(reference.value)
    , .borrow_outlives_source);
}

test "replacing a variant through a reference invalidates its projected payload" {
    try Fixture.expectSourceDiagnostic(
        \\func calculate() int | none
        \\    var owner: Box(int | none) = Box(int | none).new(42) else return none
        \\    ref reference = owner.borrow()
        \\    if ref part: int = reference
        \\        reference = none
        \\        return part
        \\    return 90
        \\if const result: int = calculate() -> exit(result)
    , .borrow_outlives_source);
}

test "reference permission edits recompute projected access" {
    const source =
        \\func run() int
        \\    var value: int | none = 41
        \\    if ref part: int = value
        \\        part += 1
        \\        return part
        \\    return 90
        \\exit(run())
    ;
    const fixture = try Fixture.init(source);
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const readonly = try std.mem.replaceOwned(u8, testing.allocator, source, "var value:", "const value:");
    defer testing.allocator.free(readonly);
    try fixture.db.setInput(queries.SourceText, 0, readonly);
    try fixture.expectDiagnostic(0, .reference_not_writable);
    const changed = try std.mem.replaceOwned(u8, testing.allocator, source, "= 41", "= 42");
    defer testing.allocator.free(changed);
    try fixture.db.setInput(queries.SourceText, 0, changed);
    try fixture.expectExit(0, 43);
}
