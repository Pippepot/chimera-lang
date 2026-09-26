const std = @import("std");
const standard_library = @import("standard_library");
const test_sources = @import("test_sources");
const query = test_sources.query;
const queries = test_sources.queries;
const structures = test_sources.structures;
const modules = test_sources.modules;
const runtime = test_sources.runtime;
const testing = std.testing;

const Fixture = struct {
    db: *query.Database,

    fn init(entry: []const u8, files: []const modules.SourceFile) !Fixture {
        const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
        errdefer db.deinit();
        try modules.registerSources(db, testing.allocator, entry, files, &.{});
        return .{ .db = db };
    }

    fn deinit(self: Fixture) void {
        self.db.deinit();
    }

    fn expectExit(self: Fixture, entry: structures.FileId, status: u8) !void {
        const executable = (try self.db.get(queries.BuildExecutable, entry)).*;
        if (executable == null) {
            const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, entry, structures.Diagnostic, testing.allocator);
            defer testing.allocator.free(diagnostics);
            for (diagnostics) |diagnostic| std.debug.print("file {d} at {d}: {s}\n", .{ diagnostic.file_id, (if (diagnostic.span) |span| span.start else 0), @tagName(diagnostic.kind) });
        }
        try testing.expect(executable != null);
        try runtime.writeProgram(testing.io, executable.?.bytes);
        defer std.Io.Dir.cwd().deleteFile(testing.io, "prog") catch {};
        try testing.expectEqual(status, try runtime.runProg(testing.io, testing.allocator, &.{}));
    }

    fn expectDiagnostic(self: Fixture, file: structures.FileId, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        try testing.expect((try self.db.get(queries.BuildExecutable, 0)).* == null);
        const diagnostics = try self.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
        defer testing.allocator.free(diagnostics);
        for (diagnostics) |diagnostic| if (diagnostic.file_id == file and std.meta.activeTag(diagnostic.kind) == kind) return;
        for (diagnostics) |diagnostic| std.debug.print("file {d} at {d}: {s}\n", .{ diagnostic.file_id, (if (diagnostic.span) |span| span.start else 0), @tagName(diagnostic.kind) });
        return error.ExpectedDiagnostic;
    }
};

const physics = modules.SourceFile{ .path = "physics/body.chi", .module_path = "physics", .source =
    \\pub struct Body
    \\  x: int
    \\pub func make(imm x: int) Body -> return Body{x = x}
    \\pub func get(imm body: Body) int -> return body.x
    \\pub func identity(static T: type, imm value: T) T -> return value
    \\pub static answer = 42
    \\static hidden = 99
    \\unknown_top_level_call()
    \\exit(99)
};

test "embedded memory source is registered in the std.memory module" {
    const f = try Fixture.init("import std.memory\nexit(42)", &.{});
    defer f.deinit();
    const module = try f.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const declarations = (try f.db.get(queries.ModuleDeclarations, module)).*.?;
    try testing.expect(!declarations.resolveEntry("allocate_host_storage").?.is_public);
    try f.expectExit(0, 42);
}

test "host storage externs allocate and release bytes and report invalid sizes" {
    const f = try Fixture.init(
        \\import std.memory.{check_storage}
        \\if check_storage(1) -> if check_storage(4097) -> if check_storage(0) -> if check_storage(-1) -> exit(1) else exit(42) else exit(2) else exit(3) else exit(4)
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
        \\extern fallible allocate_host_storage(byte_size: int) HostStorage
        \\extern func deallocate_host_storage(deinit storage: HostStorage)
        \\pub fallible check_storage(byte_size: int) unit
        \\  const storage = allocate_host_storage(byte_size)
        \\  deallocate_host_storage(storage^)
    );
    try f.expectExit(0, 42);
}

test "typed host allocation is explicit-drop and fallible" {
    const f = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\fallible use_storage(count: int) unit
        \\  const allocation: Allocation(int) = allocate(int, count)
        \\  deallocate(int, allocation^)
        \\if use_storage(0) -> if use_storage(3) -> if use_storage(-1) -> exit(1) else if use_storage(2147483647) -> exit(2) else exit(42) else exit(3) else exit(4)
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "typed allocation transfers initialized values into and out of storage" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_take}
        \\fallible round_trip() unit
        \\  var allocation = allocate(int, 3)
        \\  unsafe_initialize(int, allocation, 1, 42)
        \\  const value = unsafe_take(int, allocation, 1)
        \\  deallocate(int, allocation^)
        \\  value == 42
        \\if round_trip() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "typed allocation transfers byte and aggregate elements" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_take}
        \\struct Pair
        \\  first: int
        \\  second: byte
        \\fallible transfer() unit
        \\  var bytes = allocate(byte, 2)
        \\  unsafe_initialize(byte, bytes, 1, 7)
        \\  const number = unsafe_take(byte, bytes, 1)
        \\  deallocate(byte, bytes^)
        \\  var pairs = allocate(Pair, 2)
        \\  unsafe_initialize(Pair, pairs, 1, Pair{first = 42, second = number})
        \\  const pair = unsafe_take(Pair, pairs, 1)
        \\  deallocate(Pair, pairs^)
        \\  pair.first == 42
        \\if transfer() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref destroys its initialized value on last use" {
    const fixture = try Fixture.init(
        \\import std.memory.{Ref}
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\fallible run() unit
        \\  const owner = Ref.new(Resource{value = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref constructs immovable struct directly in owned storage" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  marker: byte
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible run() unit
        \\  const owner = Ref(Immovable).new(Immovable{marker = 7, value = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref drops a struct with a custom move without relocating it" {
    const fixture = try Fixture.init(
        \\struct CustomMove
        \\  value: int
        \\  move = func(var self: CustomMove) CustomMove -> return CustomMove{value = self.value}
        \\  drop = func(deinit self: CustomMove) -> exit(self.value)
        \\fallible run() unit
        \\  const owner = Ref(CustomMove).new(CustomMove{value = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "immovable and nested custom-move arguments borrow and write back by address" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\struct CustomMove
        \\  value: int
        \\  move = func(var self: CustomMove) CustomMove -> CustomMove{value = self.value}
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "custom drop hook does not redispatch after replacing self" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource)
        \\    self = Resource{value = self.value + 1}
        \\    exit(self.value)
        \\fallible run() unit
        \\  const owner = Ref.new(Resource{value = 41})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref in-place construction infers immovable element type" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible run() unit
        \\  const owner = Ref.new(Immovable{value = 42})
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionBody, run)).*.?;
    var constructed_in_place = false;
    for (body.instructions) |instruction| {
        if (instruction == .ref_init) constructed_in_place = true;
        try testing.expect(instruction != .struct_init);
    }
    try testing.expect(constructed_in_place);
}

test "ref constructs generated immovable structs without temporary values" {
    const fixture = try Fixture.init(
        \\struct Box(T: type)
        \\  move = none
        \\  value: T
        \\fallible run() unit
        \\  const owner = Ref.new(Box{value = 42})
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionBody, run)).*.?;
    var constructed_in_place = false;
    for (body.instructions) |instruction| {
        if (instruction == .ref_init) constructed_in_place = true;
        try testing.expect(instruction != .struct_init);
    }
    try testing.expect(constructed_in_place);
}

test "ref drops an owned field inside an immovable struct" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: Ref(Resource)
        \\fallible run() unit
        \\  const inner = Ref.new(Resource{value = 42})
        \\  const outer = Ref(Immovable).new(Immovable{field = inner^})
        \\  _ = outer
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    const run_item = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const run_body = (try fixture.db.get(queries.AnalyzeFunctionBody, run_item)).*.?;
    var dropped_in_place = false;
    for (run_body.instructions) |instruction| if (instruction == .ref_init) {
        const types: queries.TypeInterner(*query.Database) = .{ .ctx = fixture.db };
        const owner = (try types.structDefinition(instruction.ref_init.ref_type)).?;
        const drop_hook = owner.ownership.drop.?.hook.?;
        const drop_body = (try fixture.db.get(queries.AnalyzeFunctionInstance, drop_hook)).*.?;
        for (drop_body.instructions) |drop_instruction| {
            if (drop_instruction == .ref_value_for_drop) dropped_in_place = true;
        }
    };
    try testing.expect(dropped_in_place);
    try fixture.expectExit(0, 42);
}

test "ref drops nested owners with the same specialization" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Node
        \\  move = none
        \\  resource: Resource
        \\  next: Ref(Node) | none
        \\fallible run() unit
        \\  const inner = Ref(Node).new(Node{resource = Resource{value = 42}, next = none})
        \\  const outer = Ref(Node).new(Node{resource = Resource{value = 1}, next = inner^})
        \\  _ = outer
        \\  exit(2)
        \\if run() -> exit(3) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref destructor follows immovable field edits" {
    const original =
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: Resource
        \\fallible run() unit
        \\  const owner = Ref(Immovable).new(Immovable{field = Resource{value = 42}})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    ;
    const fixture = try Fixture.init(original, &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0,
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: int
        \\fallible run() unit
        \\  const owner = Ref(Immovable).new(Immovable{field = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    );
    try fixture.expectExit(0, 1);
    try fixture.db.setInput(queries.SourceText, 0, original);
    try fixture.expectExit(0, 42);
}

test "immovable ref from a conditional binding drops on the success path" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\if const owner = Ref(Immovable).new(Immovable{value = 42})
        \\  _ = owner
        \\  exit(1)
        \\else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "zero-sized immovable ref destroys its value" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  drop = func(deinit self: Immovable) -> exit(42)
        \\fallible run() unit
        \\  const owner = Ref(Immovable).new(Immovable{})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref in-place initializer cleans up fields when a later field fails" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  first: Tracked
        \\  second: int
        \\fallible fail() int
        \\  const storage = allocate(int, -1)
        \\  deallocate(int, storage^)
        \\  return 7
        \\fallible run() unit
        \\  const owner = Ref(Immovable).new(Immovable{first = Tracked{value = 42}, second = fail()})
        \\  _ = owner
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref rejects transfers and nested immovable fields" {
    const cases = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\const original = Immovable{value = 42}
        \\if Ref(Immovable).new(original) -> exit(1) else exit(2)
        , .diagnostic = .ref_requires_struct_initializer },
        .{ .source =
        \\struct Inner
        \\  move = none
        \\  value: int
        \\struct Outer
        \\  move = none
        \\  inner: Inner
        \\if Ref(Outer).new(Outer{inner = Inner{value = 42}}) -> exit(1) else exit(2)
        , .diagnostic = .type_not_movable },
        .{ .source =
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\if Ref(Explicit).new(Explicit{value = 42}) -> exit(1) else exit(2)
        , .diagnostic = .ref_requires_automatic_drop },
        .{ .source =
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\if Ref.new(Explicit{value = 42}) -> exit(1) else exit(2)
        , .diagnostic = .ref_requires_automatic_drop },
        .{ .source =
        \\import std.memory.{value}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible run() unit
        \\  const owner = Ref(Immovable).new(Immovable{value = 42})
        \\  const extracted = value(Immovable, owner^)
        \\  _ = extracted
        \\if run() -> exit(1) else exit(2)
        , .diagnostic = .ref_extraction_requires_direct_move },
    };
    for (cases) |case| {
        const fixture = try Fixture.init(case.source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.diagnostic);
    }
}

test "ref transfers its value and releases its allocation" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const owner = Ref(int).new(42)
        \\  const number = value(int, owner^)
        \\  number == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "zero-sized ref supports consuming extraction" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const owner = Ref.new(())
        \\  _ = value(unit, owner^)
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref transfers an aggregate value" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\struct Pair
        \\  first: int
        \\  second: byte
        \\fallible take() unit
        \\  const owner = Ref.new(Pair{first = 42, second = 7})
        \\  const pair = value(Pair, owner^)
        \\  pair.first == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref can own and transfer another ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const inner = Ref.new(42)
        \\  const outer = Ref(Ref(int)).new(inner^)
        \\  const moved = value(Ref(int), outer^)
        \\  const number = value(int, moved^)
        \\  number == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "zero-sized ref destroys its initialized value on last use" {
    const fixture = try Fixture.init(
        \\import std.memory.{Ref}
        \\struct Empty
        \\  drop = func(deinit self: Empty) -> exit(42)
        \\fallible run() unit
        \\  const owner = Ref(Empty).new(Empty{})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "prelude exports ref and its constructor without exporting raw allocation" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const owner: Ref(int) = Ref.new(42)
        \\  const number = value(int, owner^)
        \\  number == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const raw = try Fixture.init(
        \\fallible use_storage() unit
        \\  const storage = allocate(int, 1)
        \\if use_storage() -> exit(42) else exit(1)
    , &.{});
    defer raw.deinit();
    try raw.expectDiagnostic(0, .unknown_function);

    const retired = try Fixture.init("if make_ref(42) -> exit(1) else exit(2)", &.{});
    defer retired.deinit();
    try retired.expectDiagnostic(0, .unknown_function);
}

test "generic struct initializer infers type from ref field" {
    const fixture = try Fixture.init(
        \\import std.memory.{Ref}
        \\struct Foo(T: type)
        \\  r: Ref(T)
        \\fallible run() unit
        \\  const f = Foo{r = Ref.new(42)}
        \\  _ = f
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "fallible condition binding initializes an inferred struct field" {
    const fixture = try Fixture.init(
        \\struct Foo(T: type)
        \\  r: Ref(T)
        \\const f = Foo{r = if const owner = Ref.new(42) -> owner^ else exit(1)}
        \\_ = f
        \\exit(42)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "fallible condition binding owns its ref on success" {
    const success = try Fixture.init(
        \\import std.memory.{value}
        \\if const owner: Ref(int) = Ref.new(42) -> exit(value(int, owner^)) else exit(1)
    , &.{});
    defer success.deinit();
    try success.expectExit(0, 42);

    const failure = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
        \\fallible invalid_ref() Ref(int)
        \\  const allocation = allocate(int, -1)
        \\  deallocate(int, allocation^)
        \\  return Ref.new(42)
        \\if const owner = invalid_ref() -> exit(1) else exit(42)
    , &.{});
    defer failure.deinit();
    try failure.expectExit(0, 42);
}

test "moving a ref preserves its owned value until the new owner's last use" {
    const fixture = try Fixture.init(
        \\import std.memory.{Ref}
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\fallible run() unit
        \\  const first = Ref.new(Resource{value = 42})
        \\  const moved = first^
        \\  _ = moved
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ref cannot be forged or accessed through its storage field" {
    const sources = [_][]const u8{
        \\import std.memory.{Ref}
        \\const fake = Ref(int){}
        \\exit(42)
        ,
        \\import std.memory.{Ref}
        \\fallible inspect() unit
        \\  const owner = Ref.new(42)
        \\  _ = owner.allocation
        \\if inspect() -> exit(42) else exit(1)
    };
    for (sources) |source| {
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .opaque_struct_access);
    }
}

test "ref cannot be implicitly copied or used after transfer" {
    const sources = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\import std.memory.{Ref}
        \\fallible copy_owner() unit
        \\  const owner = Ref.new(42)
        \\  const copied = owner
        \\  _ = copied
        \\if copy_owner() -> exit(1) else exit(2)
        , .diagnostic = .type_not_copyable },
        .{ .source =
        \\import std.memory.{Ref, value}
        \\fallible take_twice() unit
        \\  const owner = Ref.new(42)
        \\  const first = value(int, owner^)
        \\  const second = value(int, owner^)
        \\  _ = first
        \\  _ = second
        \\if take_twice() -> exit(1) else exit(2)
        , .diagnostic = .use_after_transfer },
    };
    for (sources) |case| {
        const fixture = try Fixture.init(case.source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.diagnostic);
    }
}

test "typed allocation ownership cannot be abandoned or deallocated twice" {
    const sources = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\import std.memory.{allocate}
        \\fallible leak() unit
        \\  const allocation = allocate(int, 1)
        \\if leak() -> exit(42) else exit(1)
        , .diagnostic = .value_requires_explicit_drop },
        .{ .source =
        \\import std.memory.{allocate, deallocate}
        \\fallible twice() unit
        \\  const allocation = allocate(int, 1)
        \\  deallocate(int, allocation^)
        \\  deallocate(int, allocation^)
        \\if twice() -> exit(42) else exit(1)
        , .diagnostic = .use_after_transfer },
    };
    for (sources) |case| {
        const fixture = try Fixture.init(case.source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.diagnostic);
    }
}

test "typed allocation cannot be forged or have its storage metadata changed" {
    const sources = [_][]const u8{
        \\import std.memory.{Allocation}
        \\const fake = Allocation(int){}
        \\exit(42)
        ,
        \\import std.memory.{allocate, deallocate}
        \\fallible use_storage() unit
        \\  var allocation = allocate(int, 3)
        \\  allocation.storage.byte_size = 0
        \\  deallocate(int, allocation^)
        \\if use_storage() -> exit(42) else exit(1)
    };
    for (sources) |source| {
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .opaque_struct_access);
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

    try db.setInput(queries.SourceText, host_file,
        \\struct HostStorage
        \\  address_low: bool
        \\  address_high: int
        \\  byte_size: int
        \\  drop = explicit
        \\extern fallible allocate_host_storage(byte_size: int) HostStorage
        \\extern func deallocate_host_storage(deinit storage: HostStorage)
    );
    try testing.expect((try db.get(queries.FunctionSignature, allocate)).* == null);
    const diagnostics = try db.transitiveAccumulatorValues(queries.FunctionSignature, allocate, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.invalid_external_signature, diagnostics[0].kind);

    const typed = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
        \\fallible use_storage() unit
        \\  const allocation = allocate(int, 1)
        \\  deallocate(int, allocation^)
        \\if use_storage() -> exit(42) else exit(1)
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
        \\extern fallible allocate_host_storage(byte_size: int) HostStorage
        \\extern func deallocate_host_storage(deinit storage: HostStorage)
    );
    try typed.expectDiagnostic(typed_allocate.file_id, .invalid_external_signature);
}

test "an explicit empty prelude import also suppresses exit" {
    const f = try Fixture.init("import std.prelude.{}\nexit(42)", &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .unknown_function);
}

test "exit is an imported function, not a reserved call name" {
    const f = try Fixture.init(
        \\import std.prelude.{}
        \\import std.exit
        \\func exit(imm code: int) int -> code + 1
        \\const terminate: func(int) never = std.exit.exit
        \\terminate(exit(41))
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "an unsupported external declaration is rejected at signature lookup" {
    const f = try Fixture.init("extern func goodbye(code: int) never\ngoodbye(42)", &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .unsupported_external_declaration);
}

test "compiler-owned extern names require the reserved module" {
    const f = try Fixture.init("extern func exit(code: int) never\nexit(42)", &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .unsupported_external_declaration);
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

test "external fallible declaration has a fallible signature" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "exit(42)", &.{}, &.{});
    const exit_file = registry.fileId("$std/exit.chi").?;
    try db.setInput(queries.SourceText, exit_file, "pub extern fallible exit(code: int) never");
    const diagnostics = try db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* == null);
    try testing.expectEqual(@as(usize, 1), diagnostics.len);
    try testing.expectEqual(structures.Diagnostic.Kind.invalid_external_signature, diagnostics[0].kind);
}

test "compile-time std exit emits compiler control without an executable" {
    const f = try Fixture.init("const result = comptime -> exit(42)", &.{});
    defer f.deinit();
    try testing.expect((try f.db.get(queries.BuildExecutable, 0)).* == null);
    const controls = try f.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
}

test "indirect compile-time std exit preserves compiler control" {
    const f = try Fixture.init(
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
    const f = try Fixture.init(
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
    const f = try Fixture.init(
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
    const f = try Fixture.init(
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
    const f = try Fixture.init(
        \\import shapes
        \\static S = shapes.S
        \\var s = S{x = S.answer}
        \\exit(S.identity(int, s.x))
    , &.{.{ .path = "shapes/s.chi", .module_path = "shapes", .source =
        \\pub struct S
        \\  x: int
        \\  pub static answer = 42
        \\  pub func identity(static T: type, imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "struct namespace members require pub across modules" {
    const f = try Fixture.init(
        \\import shapes
        \\const s = shapes.S{value = 40}
        \\exit(shapes.S.answer + s.read())
    , &.{.{ .path = "shapes/s.chi", .module_path = "shapes", .source =
        \\pub struct S
        \\  value: int
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
    const f = try Fixture.init(
        \\import lib
        \\exit(lib.S.read(lib.S{value = 21}) + lib.answer())
    , &.{
        .{ .path = "lib/s.chi", .module_path = "lib", .source =
        \\pub struct S
        \\  value: int
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
    const f = try Fixture.init("import lib\nexit(lib.S.answer())", &.{.{ .path = "lib/s.chi", .module_path = "lib", .source = private_source }});
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
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\func S.id(imm self: S, static T: type, imm value: T) T -> return self.i + value
        \\var s = S{i = 2}
        \\exit(S.id(s, int, 20) + s.id(int, 18))
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "instance calls preserve receiver modes and namespace lookup" {
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\static S.bump = func(mut self: S, imm amount: int)
        \\  self.i += amount
        \\var s = S{i = 40}
        \\s.bump(2)
        \\exit(s.i)
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "instance calls evaluate the receiver before remaining arguments" {
    const f = try Fixture.init(
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
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 22);
}

test "owned instance receivers use ordinary transfer rules" {
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\static S.take = func(var self: S) int -> return self.i
        \\var s = S{i = 42}
        \\exit(s^.take())
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "qualified namespace declarations attach across module files" {
    const f = try Fixture.init(
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
    const f = try Fixture.init(entry, &.{.{
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
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\  func add(imm self: S, imm amount: int) int -> return self.i + amount
        \\const s = S{i = 2}
        \\exit(s.add(40))
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "generated namespace functions support specialized instance calls" {
    const f = try Fixture.init(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T -> return self.value
        \\const box = Box(int){value = 42}
        \\exit(box.get())
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "generic struct namespace functions infer enclosing type parameters" {
    const f = try Fixture.init(
        \\struct Box(T: type)
        \\  value: T
        \\  func new(imm value: T) Box(T) -> return Box(T){value = value}
        \\exit(Box.new(41).value + Box(int).new(1).value)
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "generic struct namespace rejects missing members" {
    const f = try Fixture.init(
        \\struct Box(T: type)
        \\  value: T
        \\exit(Box.missing(42))
    , &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .unknown_namespace_member);
}

test "namespace inference requires specializing an enclosing factory" {
    const f = try Fixture.init(
        \\struct Outer(T: type)
        \\  struct Inner
        \\    func make(imm value: T) T -> return value
        \\exit(Outer.Inner.make(42))
    , &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .static_argument_cannot_be_inferred);
}

test "qualified namespace declarations share the struct member scope" {
    const f = try Fixture.init(
        \\struct S
        \\  id: func() int
        \\static S.id = func(imm self: S) int -> return 42
        \\func answer() int -> return 1
        \\const s = S{id = answer}
        \\exit(s.id())
    , &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .duplicate_struct_member);
}

test "nested instance and callable field calls retain contiguous arguments" {
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\  callback: func(int) int
        \\func S.add(imm self: S, imm n: int) int -> self.i + n
        \\func S.id(imm self: S, static T: type, imm n: T) T -> n
        \\func identity(imm n: int) int -> n
        \\const s = S{i = 20, callback = identity}
        \\exit(s.id(int, s.add(s.callback(s.add(2)))))
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "namespace callable aliases preserve receiver modes and exposed signatures" {
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\func bumpValue(mut self: S, imm n: int)
        \\  self.i += n
        \\func readValue(imm self: S) int -> self.i
        \\func takeValue(var self: S) int -> self.i
        \\static S.bump = bumpValue
        \\static S.read: fallible(S) int = readValue
        \\static S.take = takeValue
        \\var s = S{i = 20}
        \\s.bump(1)
        \\const n = if s.read() -> s.i else 0
        \\exit(n + s^.take())
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "generated namespace callable aliases retain inherited specialization" {
    const f = try Fixture.init(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T -> self.value
        \\  static read = get
        \\const box = Box(int){value = 42}
        \\exit(box.read())
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "namespace values must be callable for instance syntax" {
    for ([_][]const u8{ "42", "int" }) |value| {
        const source = try std.fmt.allocPrint(testing.allocator, "struct S\n  i: int\nstatic S.bad = {s}\nconst s = S{{i = 1}}\nexit(s.bad())", .{value});
        defer testing.allocator.free(source);
        const f = try Fixture.init(source, &.{});
        defer f.deinit();
        try f.expectDiagnostic(0, .value_not_callable);
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
        const f = try Fixture.init(source, &.{physics});
        defer f.deinit();
        try f.expectDiagnostic(0, .invalid_namespace_owner);
    }
}

test "nested qualified owners resolve independently of declaration order" {
    const f = try Fixture.init(
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
    const f = try Fixture.init("func S.id() int -> 1\nexit(42)", &.{.{
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
    const f = try Fixture.init(
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
    const f = try Fixture.init(
        \\struct S
        \\  i: int
        \\func S.get(imm self: S) int -> self.i
        \\exit(42)
    , &.{.{ .path = "members.chi", .module_path = "", .source = "func S.get(imm self: S) int -> self.i" }});
    defer f.deinit();
    try f.expectDiagnostic(1, .duplicate_struct_member);
}

test "locals and parameters shadow imports without module fallback" {
    const f = try Fixture.init(
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
        const f = try Fixture.init(case.source, &.{ physics, .{ .path = "physics/collision/a.chi", .module_path = "physics.collision", .source = "pub static answer = 42" } });
        defer f.deinit();
        try f.expectDiagnostic(0, case.kind);
    }
}

test "each declaration uses the imports of its defining file" {
    const f = try Fixture.init("import physics\nexit(read())", &.{ physics, .{ .path = "reader.chi", .module_path = "", .source = "func read() int -> return physics.answer" } });
    defer f.deinit();
    try f.expectDiagnostic(2, .unknown_value);
    try f.db.setInput(queries.SourceText, 2, "func read() int -> return physics.answer\nimport physics");
    try f.expectExit(0, 42);
}

test "only the designated entry body executes across same and imported modules" {
    const f = try Fixture.init("import physics\nexit(physics.answer)", &.{ physics, .{ .path = "second.chi", .module_path = "", .source = "exit(43)" } });
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.expectExit(2, 43);
    try f.db.setInput(queries.SourceText, 2, "static ignored = comptime -> exit(98)\nconst ignored_runtime = comptime -> exit(99)\nunknown_top_level_call()");
    try f.expectExit(0, 42);
}

test "module cycles work and semantic cycles report declaration errors" {
    const f = try Fixture.init("import a\nexit(a.run())", &.{
        .{ .path = "a/a.chi", .module_path = "a", .source = "import b\npub func run() int -> return b.answer\npub static seed = 42" },
        .{ .path = "b/b.chi", .module_path = "b", .source = "import a\npub static answer = a.seed" },
    });
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 1, "import b\npub func run() int -> return b.answer\npub static seed = b.answer");
    try f.expectDiagnostic(1, .declaration_cycle);
}

test "unused imports in dependency files are validated without executing their bodies" {
    const f = try Fixture.init("import a\nexit(42)", &.{.{ .path = "a/a.chi", .module_path = "a", .source = "import missing\nexit(99)" }});
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
    const body = modules.SourceFile{ .path = "physics/body.chi", .module_path = "physics", .source = "pub struct Body\n  x: int" };
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
    try testing.expectEqual(new_item, imports.imports[0].target.declaration);
}

test "dependency import edits update calls and recover from private or missing exports" {
    const f = try Fixture.init("import api\nexit(api.answer())", &.{
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
    try testing.checkAllAllocationFailures(testing.allocator, checkModuleAllocations, .{});
}

test "type and compile-time scopes never fall back past a shadowing runtime binding" {
    const cases = [_]struct { source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source = "import physics\nfunc run(imm physics: int) physics.Body -> return 1\nrun(1)", .kind = .value_used_as_type },
        .{ .source = "import physics\nfunc run(imm physics: int)\n  var value: physics.Body | int = 1\nrun(1)", .kind = .value_used_as_type },
        .{ .source = "import physics\nfunc run(imm physics: int)\n  const value = comptime -> physics.answer\nrun(1)", .kind = .comptime_runtime_capture },
        .{ .source = "import physics\nimport physics.{answer}\nfunc run()\n  const answer = 3\n  _ = physics.identity(int, comptime -> answer)\nrun()", .kind = .comptime_runtime_capture },
    };
    for (cases) |case| {
        const f = try Fixture.init(case.source, &.{physics});
        defer f.deinit();
        try f.expectDiagnostic(0, case.kind);
    }
}

test "qualified factories work in signatures fields initializers and compile time evaluation" {
    const f = try Fixture.init(
        \\import lib
        \\static IntBox = lib.Box(int)
        \\struct Outer
        \\  inner: lib.Box(int)
        \\func read(imm value: lib.Box(int)) int -> return value.value
        \\static answer = lib.identity(int, 42)
        \\exit(read(lib.Box(int){value = answer}))
    , &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Box(T: type)
        \\  value: T
        \\pub func identity(static T: type, imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "struct namespaces validate duplicates and keep ownership hooks separate" {
    const f = try Fixture.init("import lib\nexit(lib.S.copy())", &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct S
        \\  copy = trivial
        \\  static answer = 42
        \\  pub func copy() int -> return answer
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
    try f.db.setInput(queries.SourceText, 1, "pub struct S\n  copy: int\n  func copy() int -> return 42");
    try f.expectDiagnostic(1, .duplicate_struct_member);
    try f.db.setInput(queries.SourceText, 1, "pub struct S\n  value: int");
    try f.expectDiagnostic(0, .unknown_namespace_member);
}

test "conflicting public exports fail even when the name is not used" {
    const f = try Fixture.init("import api\nexit(42)", &.{
        .{ .path = "a/a.chi", .module_path = "a", .source = "pub static X = 1" },
        .{ .path = "b/b.chi", .module_path = "b", .source = "pub static X = 2" },
        .{ .path = "api/a.chi", .module_path = "api", .source = "pub import a.{X}" },
        .{ .path = "api/b.chi", .module_path = "api", .source = "pub import b.{X}" },
    });
    defer f.deinit();
    try f.expectDiagnostic(3, .import_conflict);
}

test "generated struct namespace members retain inherited and own specializations" {
    const f = try Fixture.init(
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
    const f = try Fixture.init(
        \\import lib
        \\static Inner = lib.Outer(int).Inner
        \\var value = Inner{value = Inner.make(42)}
        \\exit(value.value)
    , &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Outer(T: type)
        \\  pub struct Inner
        \\    value: T
        \\    pub func make(imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "nested generic namespace functions infer their own type parameters" {
    const f = try Fixture.init(
        \\struct Outer(T: type)
        \\  struct Inner(U: type)
        \\    left: T
        \\    right: U
        \\    func new(imm left: T, imm right: U) Inner(U) -> return Inner(U){left = left, right = right}
        \\exit(Outer(int).Inner.new(20, 22).left + Outer(int).Inner.new(20, 22).right)
    , &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "factories inside struct namespaces discover their generated namespace members" {
    const f = try Fixture.init("import lib\nexit(lib.Factory.Box(int).make())", &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
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
