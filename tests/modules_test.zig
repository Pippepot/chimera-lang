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

    fn expectLibraryDiagnostic(self: Fixture, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        const file = (try self.db.input(queries.StandardFile, @intFromEnum(standard_library.File.memory_allocation))).*;
        try self.expectDiagnostic(file, kind);
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

test "uninitialized allocation of Ref needs no referent" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
        \\fallible run() unit
        \\  const allocation = allocate(Ref(int, false), 0)
        \\  deallocate(Ref(int, false), allocation^)
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "typed allocation borrows an initialized element without copying it" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_initialized}
        \\struct Tracked
        \\  copy = none
        \\  value: int
        \\func inspect(imm item: Tracked) int -> item.value
        \\fallible run() unit
        \\  var allocation = allocate(Tracked, 2)
        \\  unsafe_initialize(Tracked, allocation, 1, Tracked{value = 42})
        \\  const observed = inspect(unsafe_borrow_initialized(Tracked, allocation, 1))
        \\  unsafe_destroy(Tracked, allocation, 1)
        \\  deallocate(Tracked, allocation^)
        \\  observed == 42
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "indexed scalar borrowing works in arithmetic and comparisons" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_initialized}
        \\fallible run() unit
        \\  var allocation = allocate(int, 2)
        \\  unsafe_initialize(int, allocation, 1, 40)
        \\  const result = 1 + unsafe_borrow_initialized(int, allocation, 1) + 1
        \\  var equal = 0
        \\  if 40 == unsafe_borrow_initialized(int, allocation, 1) -> equal = 1
        \\  unsafe_destroy(int, allocation, 1)
        \\  deallocate(int, allocation^)
        \\  result == 42
        \\  equal == 1
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "indexed boolean borrowing reads only the selected element" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_initialized}
        \\fallible run() unit
        \\  var allocation = allocate(bool, 2)
        \\  unsafe_initialize(bool, allocation, 0, true)
        \\  unsafe_initialize(bool, allocation, 1, true)
        \\  var observed = 0
        \\  if unsafe_borrow_initialized(bool, allocation, 0) == true -> observed += 21
        \\  if true == unsafe_borrow_initialized(bool, allocation, 0) -> observed += 21
        \\  unsafe_destroy(bool, allocation, 1)
        \\  unsafe_destroy(bool, allocation, 0)
        \\  deallocate(bool, allocation^)
        \\  observed == 42
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "indexed borrowed noncopyable value cannot become an owned local" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_borrow_initialized}
        \\struct Tracked
        \\  copy = none
        \\  value: int
        \\fallible run() unit
        \\  var allocation = allocate(Tracked, 1)
        \\  unsafe_initialize(Tracked, allocation, 0, Tracked{value = 42})
        \\  const invalid = unsafe_borrow_initialized(Tracked, allocation, 0)
        \\  _ = invalid
        \\  deallocate(Tracked, allocation^)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .type_not_copyable);
}

test "copying an indexed borrowed scalar snapshots it before destruction" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_initialized}
        \\fallible run() int
        \\  var allocation = allocate(int, 1)
        \\  unsafe_initialize(int, allocation, 0, 42)
        \\  const snapshot = unsafe_borrow_initialized(int, allocation, 0)
        \\  unsafe_destroy(int, allocation, 0)
        \\  deallocate(int, allocation^)
        \\  return snapshot
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an indexed allocation element yields a storable Ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_element, read}
        \\fallible run() int
        \\  var allocation = allocate(int, 2)
        \\  unsafe_initialize(int, allocation, 1, 42)
        \\  const reference: Ref(int, false) = unsafe_borrow_element(int, allocation, 1)
        \\  const observed = read(int, false, reference)
        \\  unsafe_destroy(int, allocation, 1)
        \\  deallocate(int, allocation^)
        \\  return observed
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "typed allocation destroys a nonzero indexed element in place" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\fallible run() unit
        \\  var allocation = allocate(Tracked, 2)
        \\  unsafe_initialize(Tracked, allocation, 1, Tracked{value = 42})
        \\  unsafe_destroy(Tracked, allocation, 1)
        \\  deallocate(Tracked, allocation^)
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "destroying an allocation element invalidates a Ref of it" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_element, read}
        \\fallible run() int
        \\  var allocation = allocate(int, 1)
        \\  unsafe_initialize(int, allocation, 0, 42)
        \\  const reference = unsafe_borrow_element(int, allocation, 0)
        \\  unsafe_destroy(int, allocation, 0)
        \\  const observed = read(int, false, reference)
        \\  deallocate(int, allocation^)
        \\  return observed
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "typed allocation destroys a zero-sized initialized element" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy}
        \\struct Empty
        \\  drop = func(deinit self: Empty) -> exit(42)
        \\fallible run() unit
        \\  var allocation = allocate(Empty, 2)
        \\  unsafe_initialize(Empty, allocation, 1, Empty{})
        \\  unsafe_destroy(Empty, allocation, 1)
        \\  deallocate(Empty, allocation^)
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a Box-backed borrow can be stored and read without moving its owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference: Ref(int, false) = borrow_box(int, owner)
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box owner and Ref handle use their target type names" {
    const fixture = try Fixture.init(
        \\import std.memory.{read}
        \\fallible run() int
        \\  const owner: Box(int) = Box.new(42)
        \\  const reference: Ref(int, false) = owner.borrow()
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a const writable Ref changes its Box referent" {
    const fixture = try Fixture.init(
        \\import std.memory.{read, write}
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference: Ref(int, true) = owner.borrow_mut()
        \\  write(int, reference, 42)
        \\  return read(int, true, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Ref.as_imm preserves the origin and removes write permission" {
    const fixture = try Fixture.init(
        \\import std.memory.{read}
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  const writable = owner.borrow_mut()
        \\  const immutable: Ref(int, false) = writable.as_imm()
        \\  return read(int, false, immutable)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Ref.as_imm cannot write through its attenuated handle" {
    const fixture = try Fixture.init(
        \\import std.memory.{write}
        \\fallible run() unit
        \\  var owner = Box.new(17)
        \\  const immutable = owner.borrow_mut().as_imm()
        \\  write(int, immutable, 42)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .call_argument_type_mismatch);
}

test "Ref.as_imm cannot outlive the owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{read}
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  const immutable = owner.borrow_mut().as_imm()
        \\  const moved = owner^
        \\  _ = moved
        \\  return read(int, false, immutable)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "dereferencing a const writable Ref replaces its pointee" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = owner.borrow_mut()
        \\  reference[] = 42
        \\  return reference[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "dereference assignment rejects read-only Ref" {
    const fixture = try Fixture.init(
        \\fallible run() unit
        \\  const owner = Box.new(17)
        \\  owner.borrow()[] = 42
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .reference_not_writable);
}

test "reassigning a var Ref retargets the handle, not its previous copy" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var first = Box.new(17)
        \\  var second = Box.new(7)
        \\  var reference = first.borrow_mut()
        \\  const previous = reference
        \\  reference = second.borrow_mut()
        \\  previous[] = 42
        \\  reference[] = 8
        \\  return previous[] + reference[] - 8
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "dereferencing a Ref reads a noncopyable pointee without moving it" {
    const fixture = try Fixture.init(
        \\struct Pinned
        \\  move = none
        \\  copy = none
        \\  value: int
        \\fallible run() int
        \\  const owner = Box(Pinned).new(Pinned{value = 42})
        \\  return owner.borrow()[].value
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "dereferencing a Ref after transferring its Box is rejected" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference = owner.borrow()
        \\  const moved = owner^
        \\  _ = moved
        \\  return reference[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "dereferencing a non-Ref reports its type" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  const number = 42
        \\  return number[]
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .dereference_requires_ref);
}

test "Box duplication uses distinct storage and consuming extraction" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const original = Box.new(21)
        \\  var duplicate = original.duplicate()
        \\  duplicate.borrow_mut()[] = 42
        \\  return original.borrow()[] + duplicate^.into_value() - 21
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.duplicate preserves in-place copying of immovable values" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\fallible run() int
        \\  const original = Box(CopyOnly).new(CopyOnly{value = 41})
        \\  const copy = original.duplicate()
        \\  return copy.borrow()[].value
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Ref read and replacement methods distinguish copying from borrowing" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = owner.borrow_mut()
        \\  reference.replace(42)
        \\  return reference.read()
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Allocation methods keep raw storage explicitly managed" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation}
        \\fallible run() int
        \\  var storage = Allocation(int).allocate_raw(1)
        \\  storage.unsafe_init(0, 42)
        \\  const observed = storage.unsafe_ref(0)[]
        \\  const removed = storage.unsafe_remove(0)
        \\  storage^.release()
        \\  return observed + removed - 42
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped borrow of a named local does not copy its pointee" {
    const fixture = try Fixture.init(
        \\struct Pinned
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func run() int
        \\  const pinned = Pinned{value = 42}
        \\  borrow item = pinned
        \\  return item.value
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "scoped aliases load reference handles and callable values indirectly" {
    const fixture = try Fixture.init(
        \\func answer() int -> 42
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const handle = owner.borrow()
        \\  borrow reference = handle
        \\  const function = answer
        \\  borrow callable = function
        \\  return reference[] + callable() - 42
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped writable alias retains its referent after handle rebinding" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var first = Box.new(17)
        \\  var second = Box.new(7)
        \\  var handle = first.borrow_mut()
        \\  borrow mut item = handle[]
        \\  handle = second.borrow_mut()
        \\  item = 42
        \\  return first.borrow()[] + handle[] - 7
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped writable alias updates its named local" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  var counter = 17
        \\  borrow mut item = counter
        \\  item = 42
        \\  return counter
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped writable alias updates a named field" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 17, second = 7}
        \\  borrow mut item = pair.first
        \\  item = 42
        \\  return pair.first + pair.second - 7
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped writable alias permits field replacement" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 17, second = 7}
        \\  borrow mut item = pair
        \\  item.first = 42
        \\  return pair.first + pair.second - 7
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing an owned field through an alias invalidates its old Ref" {
    const fixture = try Fixture.init(
        \\struct Holder
        \\  owner: Box(int)
        \\fallible run() int
        \\  var holder = Holder{owner = Box.new(17)}
        \\  const old = holder.owner.borrow()
        \\  borrow mut field = holder.owner
        \\  field = Box.new(42)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "replacing a whole Box through an alias invalidates its old Ref" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const old = owner.borrow()
        \\  borrow mut item = owner
        \\  item = Box.new(42)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "replacing an inner Box through a captured Ref invalidates its old Ref" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow mut item = handle[]
        \\  const old = item.borrow()
        \\  item = Box.new(42)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "an inner Box borrowed through an outer Ref stays valid without replacement" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow mut item = handle[]
        \\  const old = item.borrow()
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 17);
}

test "a captured Ref and alias still access an owned pointee after replacement" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow mut item = handle[]
        \\  item = Box.new(42)
        \\  return item.borrow()[] + handle[].borrow()[] - 42
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "dereference replacement of an inner Box invalidates its old Ref" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow item = handle[]
        \\  const old = item.borrow()
        \\  handle[] = Box.new(42)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "Ref.replace of an inner Box invalidates its old Ref" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow item = handle[]
        \\  const old = item.borrow()
        \\  handle.replace(Box.new(42))
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a copied Ref still addresses the outer slot after replacing its inner Box" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  const copied = handle
        \\  handle[] = Box.new(42)
        \\  return copied[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a writable Ref replacement through a call invalidates its old Box" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow item = handle[]
        \\  const old = item.borrow()
        \\  replace(handle)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "nested aggregate writable references invalidate replaced contents" {
    const fixture = try Fixture.init(
        \\struct Handles
        \\  handle: Ref(Box(int), true)
        \\struct Wrapper
        \\  handles: Handles
        \\fallible replace(imm wrapper: Wrapper)
        \\  wrapper.handles.handle[] = Box.new(42)
        \\fallible run() int
        \\  var outer = Box.new(Box.new(17))
        \\  const handle = outer.borrow_mut()
        \\  const old = handle[].borrow()
        \\  replace(Wrapper{handles = Handles{handle = handle}})
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "aggregate writable effects preserve disjoint read-only origins" {
    const fixture = try Fixture.init(
        \\struct Handles
        \\  writable: Ref(Box(int), true)
        \\  readonly: Ref(Box(int), false)
        \\fallible replace(imm handles: Handles)
        \\  handles.writable[] = Box.new(17)
        \\fallible run() int
        \\  var changed = Box.new(Box.new(1))
        \\  const unchanged = Box.new(Box.new(42))
        \\  const handles = Handles{writable = changed.borrow_mut(), readonly = unchanged.borrow()}
        \\  const old = handles.readonly[].borrow()
        \\  replace(handles)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "failing indirect aggregate calls invalidate replaced contents" {
    const fixture = try Fixture.init(
        \\struct Handles
        \\  handle: Ref(Box(int), true)
        \\fallible replace(imm handles: Handles)
        \\  handles.handle[] = Box.new(42)
        \\  0 == 1
        \\fallible run() int
        \\  var outer = Box.new(Box.new(17))
        \\  const handles = Handles{handle = outer.borrow_mut()}
        \\  const old = handles.handle[].borrow()
        \\  const operation = replace
        \\  if operation(handles)
        \\    return 0
        \\  else
        \\    return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "writable references inside boxed aggregates invalidate replaced contents" {
    const source =
        \\struct Handles
        \\  handle: Ref(Box(int), true)
        \\fallible replace(imm handles: Box(Handles))
        \\  handles.borrow()[].handle[] = Box.new(42)
        \\fallible run() int
        \\  var outer = Box.new(Box.new(17))
        \\  const handle = outer.borrow_mut()
        \\  const old = handle[].borrow()
        \\  const handles = Box.new(Handles{handle = handle})
        \\  replace(handles)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    ;
    const fixture = try Fixture.init(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
    const without_write = try std.mem.replaceOwned(u8, testing.allocator, source, "  replace(handles)\n", "");
    defer testing.allocator.free(without_write);
    try fixture.db.setInput(queries.SourceText, 0, without_write);
    try fixture.expectExit(0, 17);
    const repaired = try std.mem.replaceOwned(u8, testing.allocator, source, "return old[]", "return outer.borrow()[].borrow()[]");
    defer testing.allocator.free(repaired);
    try fixture.db.setInput(queries.SourceText, 0, repaired);
    try fixture.expectExit(0, 42);
}

test "variant aggregate writable references invalidate replaced contents" {
    const fixture = try Fixture.init(
        \\struct Handles
        \\  handle: Ref(Box(int), true)
        \\fallible replace(imm candidate: Handles | int)
        \\  if const handles = candidate as Handles
        \\    handles.handle[] = Box.new(42)
        \\fallible run() int
        \\  var outer = Box.new(Box.new(17))
        \\  const handle = outer.borrow_mut()
        \\  const candidate: Handles | int = Handles{handle = handle}
        \\  const old = handle[].borrow()
        \\  replace(candidate)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "read-only references to aggregates retain nested writable effects" {
    const fixture = try Fixture.init(
        \\struct Handles
        \\  handle: Ref(Box(int), true)
        \\fallible replace(imm handles: Ref(Handles, false))
        \\  handles[].handle[] = Box.new(42)
        \\fallible run() int
        \\  var outer = Box.new(Box.new(17))
        \\  const handle = outer.borrow_mut()
        \\  const handles = Box.new(Handles{handle = handle})
        \\  const old = handle[].borrow()
        \\  replace(handles.borrow())
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "aggregate effects in loops preserve disjoint read-only origins" {
    const fixture = try Fixture.init(
        \\struct Handles
        \\  writable: Ref(Box(int), true)
        \\  readonly: Ref(Box(int), false)
        \\fallible replace(imm handles: Handles)
        \\  handles.writable[] = Box.new(17)
        \\fallible run() int
        \\  var changed = Box.new(Box.new(1))
        \\  const unchanged = Box.new(Box.new(42))
        \\  var handles = Handles{writable = changed.borrow_mut(), readonly = unchanged.borrow()}
        \\  const old = handles.readonly[].borrow()
        \\  var count = 0
        \\  loop
        \\    if count == 2 -> break
        \\    replace(handles)
        \\    count += 1
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "boxed borrowed contents cannot outlive their original owner" {
    const fixture = try Fixture.init(
        \\fallible invalid() Box(Ref(int, false))
        \\  const source = Box.new(42)
        \\  return Box.new(source.borrow())
        \\if const boxed = invalid() -> exit(boxed.borrow()[][]) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "loop field replacement removes overwritten reference origins" {
    const fixture = try Fixture.init(
        \\struct Handle
        \\  value: Ref(int, false)
        \\fallible run() int
        \\  var original = Box.new(1)
        \\  const replacement = Box.new(42)
        \\  var handle = Handle{value = original.borrow()}
        \\  loop
        \\    handle.value = replacement.borrow()
        \\    break
        \\  original = Box.new(2)
        \\  return handle.value[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "initialized raw allocation contents cannot outlive their owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, unsafe_initialize, deallocate}
        \\fallible leak() Allocation(Ref(int, false))
        \\  const owner = Box.new(42)
        \\  var slots = allocate(Ref(int, false), 1)
        \\  unsafe_initialize(Ref(int, false), slots, 0, owner.borrow())
        \\  return slots^
        \\if const slots = leak()
        \\  deallocate(Ref(int, false), slots^)
        \\  exit(1)
        \\else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "allocation capacity counts zero-sized elements" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
        \\fallible run() int
        \\  const slots = allocate(unit, 7)
        \\  const count = slots.capacity()
        \\  deallocate(unit, slots^)
        \\  return count
        \\if const count = run() -> exit(count) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 7);
}

test "empty raw allocation can escape without borrowed contents" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\fallible make() Allocation(Ref(int, false)) -> allocate(Ref(int, false), 1)
        \\if const slots = make()
        \\  deallocate(Ref(int, false), slots^)
        \\  exit(42)
        \\else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box preserves the origins of initialized borrowed contents" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const source = Box.new(42)
        \\  const boxed = Box.new(source.borrow())
        \\  return boxed.borrow()[][]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an in-place producer invalidates references into replaced owned values" {
    const fixture = try Fixture.init(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\func produce(imm handle: Ref(Box(int), true), var replacement: Box(int)) Pinned
        \\  handle[] = replacement^
        \\  return Pinned{value = 0}
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  const old = handle[].borrow()
        \\  const produced = Box.new(produce(handle, Box.new(42)))
        \\  return old[] + produced.borrow()[].value
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a failing indirect in-place producer invalidates replaced references" {
    const fixture = try Fixture.init(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\fallible produce(imm handle: Ref(Box(int), true)) Pinned
        \\  handle[] = Box.new(42)
        \\  0 == 1
        \\  return Pinned{value = 0}
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  const old = handle[].borrow()
        \\  const producer = produce
        \\  if const produced = Box.new(producer(handle))
        \\    return produced.borrow()[].value
        \\  else
        \\    return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a replacing call cannot return an unrelated Ref into its old pointee" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true), imm old: Ref(int, false)) Ref(int, false) from(old)
        \\  handle[] = Box.new(42)
        \\  return old
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  const old = handle[].borrow()
        \\  const returned = replace(handle, old)
        \\  return returned[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a copied writable Ref still addresses the slot after a replacing call" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  const copied = handle
        \\  replace(handle)
        \\  return copied[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "another writable Ref stays valid after an owned-pointee replacement call" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const first = outer.borrow_mut()
        \\  const second = outer.borrow_mut()
        \\  replace(first)
        \\  return second[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing an inner Box does not revive a handle to an old outer Box" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const stale = outer.borrow_mut()
        \\  outer = Box(Box(int)).new(Box.new(23))
        \\  const fresh = outer.borrow_mut()
        \\  replace(fresh)
        \\  return stale[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a Box borrowed through a scoped alias keeps its stable slot" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  borrow mut item = outer
        \\  const from_alias = item.borrow_mut()
        \\  const from_owner = outer.borrow_mut()
        \\  replace(from_owner)
        \\  return from_alias[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a read-only Box alias cannot create a writable Ref" {
    const fixture = try Fixture.init(
        \\fallible run() unit
        \\  var owner = Box.new(17)
        \\  borrow item = owner
        \\  _ = item.borrow_mut()
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .mutable_argument_requires_mutable_place);
}

test "borrowing through an inner Box alias does not preserve its old pointee" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const handle = outer.borrow_mut()
        \\  borrow mut item = handle[]
        \\  const old = item.borrow_mut()
        \\  handle[] = Box.new(42)
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "an attenuated Ref stays valid after an owned-pointee replacement call" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const writable = outer.borrow_mut()
        \\  const read_only = writable.as_imm()
        \\  replace(writable)
        \\  return read_only[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a selected Box-slot Ref stays valid after another handle replaces its pointee" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run(flag: bool) int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const selected = if flag == true -> outer.borrow_mut() else outer.borrow_mut()
        \\  const other = outer.borrow_mut()
        \\  replace(other)
        \\  return selected[].borrow()[]
        \\if const result = run(true) -> if result == 42 -> if const other = run(false) -> exit(other) else exit(1) else exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a rebound Box-slot Ref stays valid across a branch" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run(flag: bool) int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  var selected = outer.borrow_mut()
        \\  if flag == true -> selected = outer.borrow_mut()
        \\  const other = outer.borrow_mut()
        \\  replace(other)
        \\  return selected[].borrow()[]
        \\if const result = run(true) -> if result == 42 -> if const other = run(false) -> exit(other) else exit(1) else exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a loop-break Box-slot Ref stays valid after another handle replaces its pointee" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const selected = loop -> break outer.borrow_mut()
        \\  const other = outer.borrow_mut()
        \\  replace(other)
        \\  return selected[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing through a loop-carried Ref invalidates an old inner Ref" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  var selected = outer.borrow_mut()
        \\  const old = selected[].borrow()
        \\  var pass = 0
        \\  loop
        \\    if pass == 0
        \\      selected = outer.borrow_mut()
        \\      pass = 1
        \\      continue
        \\    replace(selected)
        \\    break
        \\  return old[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a loop-carried Ref still addresses its slot after replacing its pointee" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  var selected = outer.borrow_mut()
        \\  var pass = 0
        \\  loop
        \\    if pass == 0
        \\      selected = outer.borrow_mut()
        \\      pass = 1
        \\      continue
        \\    replace(selected)
        \\    break
        \\  return selected[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a loop-carried Ref with another possible owner cannot replace an owned pointee" {
    const fixture = try Fixture.init(
        \\fallible replace(imm handle: Ref(Box(int), true))
        \\  handle[] = Box.new(42)
        \\fallible run() int
        \\  var first_inner = Box.new(17)
        \\  var second_inner = Box.new(23)
        \\  var first = Box(Box(int)).new(first_inner^)
        \\  var second = Box(Box(int)).new(second_inner^)
        \\  var selected = first.borrow_mut()
        \\  var pass = 0
        \\  loop
        \\    if pass == 0
        \\      selected = second.borrow_mut()
        \\      pass = 1
        \\      continue
        \\    replace(selected)
        \\    break
        \\  return 42
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "independent Box handles stay valid before replacement" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var inner = Box.new(17)
        \\  var outer = Box(Box(int)).new(inner^)
        \\  const first = outer.borrow_mut()
        \\  const second = outer.borrow_mut()
        \\  return first[].borrow()[] + second[].borrow()[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 34);
}

test "a scoped writable alias keeps a mutable local current across a join" {
    const fixture = try Fixture.init(
        \\func run(flag: bool) int
        \\  var counter = 0
        \\  borrow mut item = counter
        \\  if flag == true -> item = 20 else item = 1
        \\  return counter + item
        \\exit(run(true) + run(false))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a stored Ref and scoped alias observe the same local across a join" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local}
        \\func run(flag: bool) int
        \\  var counter = 0
        \\  const reference = borrow_local(int, counter)
        \\  borrow mut item = counter
        \\  if flag == true -> item = 15 else item = 4
        \\  item = item + 1
        \\  return reference[] + counter
        \\exit(run(true) + run(false))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped alias rejects temporary sources" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  borrow item = 40 + 2
        \\  return item
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_requires_place);
}

test "a scoped writable alias needs writable access" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  borrow mut item = owner.borrow()[]
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .reference_not_writable);
}

test "a read-only scoped alias cannot replace its referent" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  var counter = 17
        \\  borrow item = counter
        \\  item = 42
        \\  return counter
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .assignment_to_immutable);
}

test "a writable scoped alias needs a mutable named place" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  const counter = 17
        \\  borrow mut item = counter
        \\  item = 42
        \\  return counter
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .mutable_borrow_requires_writable_place);
}

test "a scoped alias rejects a moved owner when used" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  borrow item = owner.borrow()[]
        \\  const moved = owner^
        \\  _ = moved
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a scoped alias can borrow another writable alias" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  var counter = 17
        \\  borrow mut first = counter
        \\  borrow mut second = first
        \\  second = 21
        \\  return counter + first
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a read-only scoped alias cannot grant writable access" {
    const fixture = try Fixture.init(
        \\func run() int
        \\  var counter = 17
        \\  borrow mut first = counter
        \\  borrow read_only = first
        \\  borrow mut second = read_only
        \\  second = 42
        \\  return counter
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .reference_not_writable);
}

test "a scoped alias can borrow a field of another alias" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 17, second = 7}
        \\  borrow mut whole = pair
        \\  borrow mut field = whole.first
        \\  field = 42
        \\  return pair.first + whole.second - 7
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "borrowing through a scoped alias addresses its referent" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local}
        \\func run() int
        \\  var counter = 42
        \\  borrow item = counter
        \\  const reference = borrow_local(int, item)
        \\  return reference[]
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped alias passes a noncopyable value to an imm call" {
    const fixture = try Fixture.init(
        \\struct Pinned
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func inspect(imm item: Pinned) int -> item.value
        \\func run() int
        \\  const pinned = Pinned{value = 42}
        \\  borrow item = pinned
        \\  return inspect(item)
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped alias can read an immutable parameter field" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func inspect(imm pair: Pair) int
        \\  borrow item = pair.first
        \\  return item + pair.second
        \\exit(inspect(Pair{first = 21, second = 21}))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped writable alias to a mut parameter copies back" {
    const fixture = try Fixture.init(
        \\func update(mut number: int)
        \\  borrow mut item = number
        \\  item = 42
        \\func run() int
        \\  var number = 17
        \\  update(number)
        \\  return number
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an aliased mut parameter copies back after failure" {
    const fixture = try Fixture.init(
        \\fallible update(mut number: int)
        \\  borrow mut item = number
        \\  item = 42
        \\  0 > 1
        \\fallible run() int
        \\  var number = 17
        \\  if update(number) -> return 1
        \\  return number
        \\if const result = run() -> exit(result) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a scoped alias is invalid after a call replaces its owner" {
    const fixture = try Fixture.init(
        \\fallible replace(mut owner: Box(int)) -> owner = Box.new(17)
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  borrow item = owner.borrow()[]
        \\  replace(owner)
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a scoped alias releases its owner after its last use" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const owner = Box.new(21)
        \\  borrow item = owner.borrow()[]
        \\  const snapshot = item
        \\  const moved = owner^
        \\  return snapshot + moved^.into_value()
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box and Ref alias analysis recomputes after source edits" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  borrow item = owner.borrow()[]
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 17);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const first = try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run });

    try fixture.db.setInput(queries.SourceText, 0,
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  borrow mut item = owner.borrow_mut()[]
        \\  item = 42
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    );
    const second = try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run });
    try testing.expect(first != second);
    try fixture.expectExit(0, 42);

    try fixture.db.setInput(queries.SourceText, 0,
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  borrow item = owner.borrow()[]
        \\  const moved = owner^
        \\  _ = moved
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    );
    try fixture.expectDiagnostic(0, .use_after_transfer);

    try fixture.db.setInput(queries.SourceText, 0,
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  borrow item = owner.borrow()[]
        \\  return item
        \\if const result = run() -> exit(result) else exit(1)
    );
    try fixture.expectExit(0, 42);
}

test "an immutable Ref parameter can be read by its callee" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func inspect(imm reference: Ref(int, false)) int -> return read(int, false, reference)
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  return inspect(borrow_box(int, owner))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a local field Ref reads its field rather than a copy" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Pair
        \\  offset: int
        \\  value: int
        \\func run() int
        \\  const pair = Pair{offset = 2, value = 40}
        \\  const reference = borrow_local(int, pair.value)
        \\  return read(int, false, reference) + pair.offset
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a nested local field Ref reaches the leaf" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Inner
        \\  first: int
        \\  second: int
        \\struct Outer
        \\  prefix: int
        \\  inner: Inner
        \\func run() int
        \\  const outer = Outer{prefix = 2, inner = Inner{first = 17, second = 40}}
        \\  const reference = borrow_local(int, outer.inner.second)
        \\  return read(int, false, reference) + outer.prefix
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "borrow_local addresses a borrowed parameter field" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Pair
        \\  prefix: int
        \\  value: int
        \\func inspect(imm pair: Pair) int -> read(int, false, borrow_local(int, pair.value))
        \\func run() int
        \\  const pair = Pair{prefix = 2, value = 40}
        \\  return inspect(pair) + pair.prefix - 2
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 40);
}

test "moving a field invalidates its Ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Pair
        \\  value: int
        \\  sibling: int
        \\func run() int
        \\  var pair = Pair{value = 42, sibling = 0}
        \\  const reference = borrow_local(int, pair.value)
        \\  const moved = pair.value^
        \\  _ = moved
        \\  return read(int, false, reference)
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "replacing a sibling invalidates a local field Ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Pair
        \\  value: int
        \\  offset: int
        \\func run() int
        \\  var pair = Pair{value = 40, offset = 1}
        \\  const reference = borrow_local(int, pair.value)
        \\  pair.offset = 2
        \\  return read(int, false, reference)
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a mut owner cannot overlap a Ref argument through another local" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func inspect(mut owner: Box(int), imm reference: Ref(int, false)) int -> read(int, false, reference)
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  const reference = borrow_box(int, owner)
        \\  return inspect(owner, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .overlapping_mutable_arguments);
}

test "a mut place cannot overlap an expression-only borrow argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func inspect(mut owner: Immovable, imm snapshot: Immovable) int
        \\  owner.value = 17
        \\  return snapshot.value
        \\func run() int
        \\  var owner = Immovable{value = 42}
        \\  return inspect(owner, read(Immovable, false, borrow_local(Immovable, owner)))
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .overlapping_mutable_arguments);
}

test "a mut place can coexist with an expression-only borrow of another local" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func inspect(mut owner: Immovable, imm snapshot: Immovable) int
        \\  owner.value = 17
        \\  return snapshot.value
        \\func run() int
        \\  var owner = Immovable{value = 17}
        \\  const other = Immovable{value = 42}
        \\  return inspect(owner, read(Immovable, false, borrow_local(Immovable, other)))
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a mut owner and a Ref of a different owner can coexist" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func inspect(mut owner: Box(int), imm reference: Ref(int, false)) int -> read(int, false, reference)
        \\fallible run() int
        \\  var first = Box.new(17)
        \\  const second = Box.new(42)
        \\  return inspect(first, borrow_box(int, second))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an owned argument cannot consume the owner of a Ref argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read, value}
        \\func inspect(imm reference: Ref(int, false), deinit owner: Box(int)) int
        \\  const removed = value(int, owner^)
        \\  return read(int, false, reference)
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference = borrow_box(int, owner)
        \\  return inspect(reference, owner^)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an argument cannot consume a previously prepared Ref origin inside a nested call" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read, value}
        \\func dispose(deinit owner: Box(int)) int -> value(int, owner^)
        \\func inspect(imm reference: Ref(int, false), imm removed: int) int -> read(int, false, reference)
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  return inspect(borrow_box(int, owner), dispose(owner^))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an indexed borrow argument cannot outlive a nested allocation transfer" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow_initialized}
        \\func dispose(deinit allocation: Allocation(int)) int
        \\  deallocate(int, allocation^)
        \\  return 0
        \\func inspect(imm item: int, imm ignored: int) int -> item
        \\fallible run() int
        \\  var allocation = allocate(int, 1)
        \\  unsafe_initialize(int, allocation, 0, 42)
        \\  return inspect(unsafe_borrow_initialized(int, allocation, 0), dispose(allocation^))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an indexed arithmetic operand cannot outlive a nested allocation transfer" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow_initialized}
        \\func dispose(deinit allocation: Allocation(int)) int
        \\  deallocate(int, allocation^)
        \\  return 0
        \\fallible run() int
        \\  var allocation = allocate(int, 1)
        \\  unsafe_initialize(int, allocation, 0, 42)
        \\  return unsafe_borrow_initialized(int, allocation, 0) + dispose(allocation^)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an indexed comparison operand cannot outlive a nested allocation transfer" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow_initialized}
        \\func dispose(deinit allocation: Allocation(int)) int
        \\  deallocate(int, allocation^)
        \\  return 42
        \\fallible run() int
        \\  var allocation = allocate(int, 1)
        \\  unsafe_initialize(int, allocation, 0, 42)
        \\  if unsafe_borrow_initialized(int, allocation, 0) == dispose(allocation^) -> return 1
        \\  return 0
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a callable field cannot outlive an argument transferring its owner" {
    const fixture = try Fixture.init(
        \\struct Handler
        \\  callback: func(int) int
        \\func answer(value: int) int -> 42
        \\func dispose(deinit owner: Box(Handler)) int -> 0
        \\fallible run() int
        \\  const owner = Box.new(Handler{callback = answer})
        \\  return owner.borrow()[].callback(dispose(owner^))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an indexed callable cannot outlive a nested allocation transfer" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_borrow_initialized}
        \\static Callback: type = func(int) int
        \\func answer(value: int) int -> 42
        \\func dispose(deinit allocation: Allocation(Callback)) int
        \\  deallocate(Callback, allocation^)
        \\  return 0
        \\fallible run() int
        \\  var allocation = allocate(Callback, 1)
        \\  unsafe_initialize(Callback, allocation, 0, answer)
        \\  return unsafe_borrow_initialized(Callback, allocation, 0)(dispose(allocation^))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an owned argument cannot consume an immutable argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{read, value}
        \\func inspect(imm owner: Box(int), deinit consumed: Box(int)) int
        \\  const removed = value(int, consumed^)
        \\  return read(int, false, borrow_box(int, owner))
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  return inspect(owner, owner^)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "an owned argument may consume a different owner than a Ref argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read, value}
        \\func inspect(imm reference: Ref(int, false), deinit owner: Box(int)) int
        \\  const removed = value(int, owner^)
        \\  return read(int, false, reference)
        \\fallible run() int
        \\  const first = Box.new(42)
        \\  const second = Box.new(17)
        \\  return inspect(borrow_box(int, first), second^)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a transferred field can be reinitialized without hiding its sibling" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a nested sibling stays available after a field transfer" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a transferred field cannot be read before reinitialization" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  const first = pair.first^
        \\  return pair.first
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a partially moved aggregate cannot be used as a whole" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  const first = pair.first^
        \\  const copied = pair
        \\  return copied.second
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a field moved on one branch is possibly unavailable after joining" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run(flag: int) int
        \\  var pair = Pair{first = 40, second = 2}
        \\  if flag == 1
        \\    const moved = pair.first^
        \\  return pair.first
        \\exit(run(1))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .possibly_transferred);
}

test "an unchanged sibling is available across partial branch and loop states" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a transferred field must be restored before a loop backedge" {
    const fixture = try Fixture.init(
        \\struct Pair
        \\  first: int
        \\  second: int
        \\func run() int
        \\  var pair = Pair{first = 40, second = 2}
        \\  loop
        \\    const moved = pair.first^
        \\    continue
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .transferred_value_not_restored_before_loop_backedge);
}

test "transferring an owned field moves its cleanup obligation" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Container
        \\  owner: Box(int)
        \\  offset: int
        \\fallible run() int
        \\  var box = Container{owner = Box.new(40), offset = 2}
        \\  const owner = box.owner^
        \\  return read(int, false, borrow_box(int, owner)) + box.offset
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "moving an owner field invalidates a Ref through that field" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Container
        \\  owner: Box(int)
        \\  offset: int
        \\fallible run() int
        \\  var box = Container{owner = Box.new(40), offset = 2}
        \\  const reference = borrow_box(int, box.owner)
        \\  const owner = box.owner^
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "reinitializing an owned field reinstates aggregate cleanup" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Container
        \\  owner: Box(Resource)
        \\  offset: int
        \\fallible run() unit
        \\  var box = Container{owner = Box.new(Resource{value = 42}), offset = 1}
        \\  const owner = box.owner^
        \\  box.owner = owner^
        \\  _ = box.offset
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an owned field moved on one branch cannot be dropped twice after joining" {
    const fixture = try Fixture.init(
        \\struct Container
        \\  owner: Box(int)
        \\  offset: int
        \\fallible run(flag: int) int
        \\  var box = Container{owner = Box.new(7), offset = 42}
        \\  if flag == 1
        \\    const owner = box.owner^
        \\  return box.offset
        \\if const first = run(1) -> if const second = run(0) -> exit(first + second - 42) else exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing a parent with a moved trivial field still destroys its owned siblings" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Inner
        \\  owner: Box(Resource)
        \\  count: int
        \\struct Outer
        \\  inner: Inner
        \\fallible run() unit
        \\  var outer = Outer{inner = Inner{owner = Box.new(Resource{value = 42}), count = 1}}
        \\  const old = outer.inner.count^
        \\  outer.inner = Inner{owner = Box.new(Resource{value = 17}), count = 2}
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a drop hook can consume an allocation field" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_element, read}
        \\struct Buffer
        \\  allocation: Allocation(int)
        \\  length: int
        \\  drop = func(deinit self: Buffer)
        \\    unsafe_destroy(int, self.allocation, 0)
        \\    deallocate(int, self.allocation^)
        \\fallible run() int
        \\  var allocation = allocate(int, 1)
        \\  unsafe_initialize(int, allocation, 0, 41)
        \\  const buffer = Buffer{allocation = allocation^, length = 1}
        \\  return read(int, false, unsafe_borrow_element(int, buffer.allocation, 0)) + buffer.length
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "transferring one owned field still destroys its owned sibling" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  moved: Box(int)
        \\  remaining: Box(Tracked)
        \\fallible run() int
        \\  var pair = Pair{moved = Box.new(17), remaining = Box.new(Tracked{value = 42})}
        \\  const moved = pair.moved^
        \\  return read(int, false, borrow_box(int, moved))
        \\if const result = run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "restoring an owned field rejoins its sibling cleanup" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  restored: Box(Tracked)
        \\  sibling: Box(int)
        \\fallible run() Box(Tracked)
        \\  var pair = Pair{restored = Box.new(Tracked{value = 17}), sibling = Box.new(1)}
        \\  const old = pair.restored^
        \\  pair.restored = Box.new(Tracked{value = 42})
        \\  return old^
        \\if const result = run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "two moved fields can be restored one at a time" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Trio
        \\  first: Box(int)
        \\  second: Box(int)
        \\  stable: Box(int)
        \\fallible run() int
        \\  var trio = Trio{first = Box.new(7), second = Box.new(20), stable = Box.new(6)}
        \\  const first = trio.first^
        \\  const second = trio.second^
        \\  trio.first = Box.new(4)
        \\  trio.second = Box.new(5)
        \\  return read(int, false, borrow_box(int, trio.first)) + read(int, false, borrow_box(int, trio.second)) + read(int, false, borrow_box(int, trio.stable)) + read(int, false, borrow_box(int, first)) + read(int, false, borrow_box(int, second))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "restoring an ownerless aggregate recovers its partial cleanup" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Pair
        \\  first: Box(int)
        \\  second: Box(int)
        \\fallible run() int
        \\  var pair = Pair{first = Box.new(7), second = Box.new(20)}
        \\  const first = pair.first^
        \\  const second = pair.second^
        \\  pair.first = Box.new(4)
        \\  pair.second = Box.new(11)
        \\  return read(int, false, borrow_box(int, pair.first)) + read(int, false, borrow_box(int, pair.second)) + read(int, false, borrow_box(int, first)) + read(int, false, borrow_box(int, second))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "nested missing owners are restored separately" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Inner
        \\  first: Box(int)
        \\  second: Box(int)
        \\struct Outer
        \\  inner: Inner
        \\  marker: int
        \\fallible run() int
        \\  var outer = Outer{inner = Inner{first = Box.new(7), second = Box.new(20)}, marker = 2}
        \\  const first = outer.inner.first^
        \\  const second = outer.inner.second^
        \\  outer.inner.first = Box.new(4)
        \\  outer.inner.second = Box.new(9)
        \\  return read(int, false, borrow_box(int, outer.inner.first)) + read(int, false, borrow_box(int, outer.inner.second)) + read(int, false, borrow_box(int, first)) + read(int, false, borrow_box(int, second)) + outer.marker
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "restored owners are destroyed in reverse field order" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 50 -> exit(50)
        \\    if self.value == 60 -> exit(60)
        \\struct Pair
        \\  first: Box(Tracked)
        \\  second: Box(Tracked)
        \\fallible run() Box(Tracked)
        \\  var pair = Pair{first = Box.new(Tracked{value = 17}), second = Box.new(Tracked{value = 31})}
        \\  const first = pair.first^
        \\  const second = pair.second^
        \\  pair.first = Box.new(Tracked{value = 50})
        \\  pair.second = Box.new(Tracked{value = 60})
        \\  _ = first
        \\  return second^
        \\if const owner = run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 60);
}

test "consecutive owned field transfers leave no aggregate cleanup" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  first: Box(Tracked)
        \\  second: Box(Tracked)
        \\fallible run() Box(Tracked)
        \\  var pair = Pair{first = Box.new(Tracked{value = 17}), second = Box.new(Tracked{value = 42})}
        \\  const first = pair.first^
        \\  const second = pair.second^
        \\  _ = read(Tracked, false, borrow_box(Tracked, second)).value
        \\  return first^
        \\if const owner = run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing a partly moved parent destroys its remaining owned children" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
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
        \\fallible run() int
        \\  var outer = Outer{inner = Inner{moved = Box.new(17), remaining = Box.new(Tracked{value = 42})}, flag = 1}
        \\  const moved = outer.inner.moved^
        \\  outer.inner = Inner{moved = Box.new(19), remaining = Box.new(Tracked{value = 31})}
        \\  return read(int, false, borrow_box(int, moved))
        \\if const result = run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a nested owned field transfer skips only its field during cleanup" {
    const fixture = try Fixture.init(
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
        \\fallible run() Box(Tracked)
        \\  var outer = Outer{inner = Inner{stable = Box.new(Tracked{value = 42}), moved = Box.new(Tracked{value = 17})}, other = Box.new(Tracked{value = 31})}
        \\  const moved = outer.inner.moved^
        \\  _ = outer.inner.stable
        \\  return moved^
        \\if const owner = run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a conditional owned field transfer never drops the moved branch twice" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\fallible run(flag: int) Box(Tracked)
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 42}), moved = Box.new(Tracked{value = 17}), marker = 1}
        \\  var chosen = Box.new(Tracked{value = 1})
        \\  if flag == 1 -> chosen = pair.moved^
        \\  _ = pair.marker
        \\  return chosen^
        \\if const owner = run(1) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a conditional owned field transfer ends the other branch before joining" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\fallible run(flag: int) Box(Tracked)
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 42}), moved = Box.new(Tracked{value = 17}), marker = 1}
        \\  var chosen = Box.new(Tracked{value = 1})
        \\  if flag == 1 -> chosen = pair.moved^
        \\  _ = pair.marker
        \\  return chosen^
        \\if const owner = run(0) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 17);
}

test "an owned sibling can be borrowed after a partial transfer join" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Pair
        \\  stable: Box(int)
        \\  movable: Box(int)
        \\fallible run(flag: int) int
        \\  var pair = Pair{stable = Box.new(41), movable = Box.new(1)}
        \\  var chosen = Box.new(0)
        \\  if flag == 1 -> chosen = pair.movable^
        \\  return read(int, false, borrow_box(int, pair.stable)) + read(int, false, borrow_box(int, chosen))
        \\if const result = run(1) -> exit(result) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a short-circuit condition joins partial ownership without double cleanup" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(int)
        \\  marker: int
        \\fallible fail_after_consuming(var owner: Box(int)) unit
        \\  0 == 1
        \\fallible run(flag: int) int
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 42}), moved = Box.new(17), marker = 1}
        \\  if flag == 1 and fail_after_consuming(pair.moved^) -> exit(1)
        \\  _ = pair.marker
        \\  return 1
        \\if const result = run(1) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "loop exits join owned field transfers before later sibling use" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  movable: Box(Tracked)
        \\  marker: int
        \\fallible run(flag: int) Box(Tracked)
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 42}), movable = Box.new(Tracked{value = 17}), marker = 1}
        \\  var selected = Box.new(Tracked{value = 0})
        \\  loop
        \\    if flag == 1
        \\      selected = pair.movable^
        \\      break
        \\    break
        \\  _ = pair.marker
        \\  return selected^
        \\if const owner = run(1) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "three loop exits normalize distinct owned field transfers" {
    const fixture = try Fixture.init(
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
        \\fallible run(flag: int) Box(Tracked)
        \\  var group = Group{sibling = Box.new(Tracked{value = 42}), second = Box.new(Tracked{value = 31}), first = Box.new(Tracked{value = 17}), marker = 1}
        \\  var selected = Box.new(Tracked{value = 0})
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
        \\if const owner = run(1) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "loop backedges preserve missing owned fields after replacing a sibling" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\fallible run() Box(Tracked)
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 31}), moved = Box.new(Tracked{value = 17}), marker = 1}
        \\  const moved = pair.moved^
        \\  var pass = 0
        \\  loop
        \\    if pass == 1 -> break
        \\    pair.sibling = Box.new(Tracked{value = 42})
        \\    pass = 1
        \\    continue
        \\  _ = pair.marker
        \\  return moved^
        \\if const owner = run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a restoring backedge cannot revive a field moved before the loop" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked)
        \\    if self.value == 17 -> exit(17)
        \\    if self.value == 42 -> exit(42)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\  marker: int
        \\fallible run(flag: int) Box(Tracked)
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 42}), moved = Box.new(Tracked{value = 17}), marker = 1}
        \\  const moved = pair.moved^
        \\  loop
        \\    if flag == 1 -> break
        \\    pair.moved = Box.new(Tracked{value = 31})
        \\    continue
        \\  _ = pair.marker
        \\  return moved^
        \\if const owner = run(1) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a restored field is ended before the next loop iteration" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  moved: Box(Tracked)
        \\fallible run() unit
        \\  var pair = Pair{sibling = Box.new(Tracked{value = 42}), moved = Box.new(Tracked{value = 17})}
        \\  const moved = pair.moved^
        \\  var pass = 0
        \\  loop
        \\    if pass == 1 -> exit(read(Tracked, false, borrow_box(Tracked, moved)).value + 74)
        \\    pair.moved = Box.new(Tracked{value = 31})
        \\    pass = 1
        \\    continue
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 31);
}

test "three loop exits can join distinct owned results" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run(flag: int) Box(int)
        \\  var first = Box.new(40)
        \\  var second = Box.new(42)
        \\  var third = Box.new(44)
        \\  return loop
        \\    if flag == 1 -> break first^
        \\    if flag == 2 -> break second^
        \\    break third^
        \\if const owner = run(2) -> exit(read(int, false, borrow_box(int, owner))) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a mut parameter can replace its owned field before returning" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Container
        \\  owner: Box(int)
        \\  count: int
        \\func replace(mut box: Container, var replacement: Box(int))
        \\  const old = box.owner^
        \\  box.owner = replacement^
        \\fallible run() int
        \\  var box = Container{owner = Box.new(17), count = 2}
        \\  replace(box, Box.new(40))
        \\  return read(int, false, borrow_box(int, box.owner)) + box.count
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a mut parameter cannot leave an owned field uninitialized" {
    const fixture = try Fixture.init(
        \\struct Container
        \\  owner: Box(int)
        \\  count: int
        \\func remove(mut box: Container)
        \\  const old = box.owner^
        \\fallible run() unit
        \\  var box = Container{owner = Box.new(17), count = 2}
        \\  remove(box)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .field_not_restored_before_mut_return);
}

test "successive explicit-drop field transfers discharge the whole aggregate" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Pair
        \\  first: Box(int)
        \\  second: Allocation(int)
        \\fallible run() unit
        \\  const first = Box.new(1)
        \\  const second = allocate(int, 1)
        \\  var pair = Pair{first = first^, second = second^}
        \\  const moved = pair.first^
        \\  const allocation = pair.second^
        \\  deallocate(int, allocation^)
        \\  _ = moved
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an untransferred explicit-drop sibling still requires disposal" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate}
        \\struct Pair
        \\  first: Box(int)
        \\  second: Allocation(int)
        \\fallible run() unit
        \\  const first = Box.new(1)
        \\  const second = allocate(int, 1)
        \\  var pair = Pair{first = first^, second = second^}
        \\  const moved = pair.first^
        \\  _ = moved
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .value_requires_explicit_drop);
}

test "removing an explicit-drop field leaves automatic sibling cleanup" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  storage: Allocation(int)
        \\fallible run() unit
        \\  const sibling = Box.new(Tracked{value = 42})
        \\  const storage = allocate(int, 1)
        \\  var pair = Pair{sibling = sibling^, storage = storage^}
        \\  const removed = pair.storage^
        \\  deallocate(int, removed^)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an explicit-drop field cannot be implicitly ended at a branch join" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Pair
        \\  sibling: Box(int)
        \\  storage: Allocation(int)
        \\fallible run(flag: int) int
        \\  const sibling = Box.new(42)
        \\  const storage = allocate(int, 1)
        \\  var pair = Pair{sibling = sibling^, storage = storage^}
        \\  if flag == 1
        \\    const removed = pair.storage^
        \\    deallocate(int, removed^)
        \\  return 42
        \\if const result = run(1) -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .explicit_drop_field_cannot_be_implicitly_ended);
}

test "explicit-drop field disposal on both branches keeps automatic sibling cleanup" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\struct Pair
        \\  sibling: Box(Tracked)
        \\  storage: Allocation(int)
        \\fallible run(flag: int) unit
        \\  const sibling = Box.new(Tracked{value = 42})
        \\  const storage = allocate(int, 1)
        \\  var pair = Pair{sibling = sibling^, storage = storage^}
        \\  if flag == 1
        \\    const removed = pair.storage^
        \\    deallocate(int, removed^)
        \\  else
        \\    const removed = pair.storage^
        \\    deallocate(int, removed^)
        \\if run(1) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "nested explicit-drop fields leave no owner after successive transfers" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Inner
        \\  first: Box(int)
        \\  second: Allocation(int)
        \\struct Outer
        \\  inner: Inner
        \\  marker: int
        \\fallible run() int
        \\  const first = Box.new(1)
        \\  const second = allocate(int, 1)
        \\  var outer = Outer{inner = Inner{first = first^, second = second^}, marker = 42}
        \\  const moved = outer.inner.first^
        \\  const allocation = outer.inner.second^
        \\  deallocate(int, allocation^)
        \\  _ = moved
        \\  return outer.marker
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer tracks initialized length separately from allocation capacity" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  const empty = Buffer(int).new(0)
        \\  const reserved = Buffer(int).new(3)
        \\  return 39 + empty.len() + empty.capacity() + reserved.len() + reserved.capacity()
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer rejects Ref elements without origin tracking across mutations" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  const buffer = Buffer(Ref(int, false)).new(1)
        \\  return buffer.len()
        \\if const length = run() -> exit(length + 42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.buffer_cannot_store_borrow_element);
}

test "buffer initialization metadata is opaque outside std.memory" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() unit
        \\  var buffer = Buffer(int).new(0)
        \\  buffer.initialized = 1
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .opaque_struct_access);
}

test "buffer appends into free slots and grows from zero" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var empty = Buffer(int).new(0)
        \\  empty.append(20)
        \\  empty.append(22)
        \\  var reserved = Buffer(int).new(2)
        \\  reserved.append(42)
        \\  return empty.len() + empty.capacity() + reserved.len() + reserved.capacity() + 35
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer growth moves elements and drops the initialized prefix in reverse" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\fallible run() unit
        \\  var buffer = Buffer(Tracked).new(1)
        \\  buffer.append(Tracked{value = 17})
        \\  buffer.append(Tracked{value = 42})
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer get checks bounds and borrows an initialized element" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, read}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(1)
        \\  buffer.append(42)
        \\  const element: Ref(int, false) = buffer.get(0)
        \\  const observed = read(int, false, element)
        \\  if buffer.get(-1) -> exit(1)
        \\  if buffer.get(1) -> exit(2)
        \\  return observed
        \\if const result = run() -> exit(result) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer get_mut checks bounds and replaces an initialized element" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(0)
        \\  if buffer.get_mut(0) -> return 1
        \\  buffer.append(17)
        \\  if buffer.get_mut(-1) -> return 2
        \\  if buffer.get_mut(1) -> return 3
        \\  const writable: Ref(int, true) = buffer.get_mut(0)
        \\  writable[] = 42
        \\  return buffer.get(0)[]
        \\if const result = run() -> exit(result) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer get_mut invalidates earlier element and view borrows" {
    const sources = .{
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  const previous = buffer.get(0)
        \\  const writable = buffer.get_mut(0)
        \\  writable[] = 42
        \\  return previous[]
        \\if const result = run() -> exit(result) else exit(1)
        ,
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  const view = buffer.view(0, 1)
        \\  const writable = buffer.get_mut(0)
        \\  writable[] = 42
        \\  return view.get(0)[]
        \\if const result = run() -> exit(result) else exit(1)
    };
    inline for (sources) |source| {
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .borrow_outlives_source);
    }
}

test "buffer append invalidates a writable element Ref without growth" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  const writable = buffer.get_mut(0)
        \\  buffer.append(7)
        \\  writable[] = 42
        \\  return buffer.get(0)[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "buffer get_mut needs a mutable buffer place" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  const buffer = Buffer(int).new(1)
        \\  return buffer.get_mut(0)[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .mutable_argument_requires_mutable_place);
}

test "a scoped alias writes through checked Buffer element access" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(1)
        \\  buffer.append(17)
        \\  borrow mut item = buffer.get_mut(0)[]
        \\  item = 42
        \\  return buffer.get(0)[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an empty immovable Buffer has no writable initialized element" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\fallible run() int
        \\  var buffer = Buffer(Pinned).new(0)
        \\  if buffer.get_mut(0) -> return 1
        \\  return buffer.len() + 42
        \\if const result = run() -> exit(result) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "appending without growth invalidates an earlier buffer element Ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, read}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  const element = buffer.get(0)
        \\  buffer.append(42)
        \\  return read(int, false, element)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "buffer reserve preserves initialized elements on allocation failure" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, read}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(1)
        \\  buffer.append(42)
        \\  if buffer.reserve(-1) -> exit(1)
        \\  if buffer.reserve(2147483647) -> exit(2)
        \\  buffer.reserve(3)
        \\  return read(int, false, buffer.get(0)) - buffer.len() - buffer.capacity() + 4
        \\if const result = run() -> exit(result) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer append rejects explicitly dropped elements" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\struct Explicit
        \\  value: int
        \\  drop = explicit
        \\fallible run() unit
        \\  var buffer = Buffer(Explicit).new(1)
        \\  buffer.append(Explicit{value = 42})
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.buffer_requires_automatic_drop);
}

test "buffer append rejects elements with custom move" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> CustomMove{value = self.value}
        \\fallible run() unit
        \\  var buffer = Buffer(CustomMove).new(1)
        \\  buffer.append(CustomMove{value = 42})
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.buffer_requires_direct_move);
}

test "buffer reserve rejects elements with custom move" {
    const source =
        \\import std.memory.{Buffer}
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> CustomMove{value = self.value}
        \\fallible run() unit
        \\  var buffer = Buffer(CustomMove).new(0)
        \\  buffer.reserve(1)
        \\if run() -> exit(1) else exit(2)
    ;
    const fixture = try Fixture.init(source, &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.buffer_requires_direct_move);
}

test "a buffer view borrows a checked subrange" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, read}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  buffer.append(42)
        \\  const view = buffer.view(1, 1)
        \\  if view.get(1) -> exit(1)
        \\  if buffer.view(-1, 1) -> exit(2)
        \\  if buffer.view(1, 2) -> exit(3)
        \\  return read(int, false, view.get(0)) + view.len() - 1
        \\if const result = run() -> exit(result) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer view range metadata is opaque outside std.memory" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() unit
        \\  var buffer = Buffer(int).new(0)
        \\  var view = buffer.view(0, 0)
        \\  view.size = 1
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .opaque_struct_access);
}

test "buffer view construction retains its range length" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(1)
        \\  buffer.append(42)
        \\  const view = buffer.view(0, 1)
        \\  return 41 + view.len()
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "buffer view reads an initialized element" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, read}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(1)
        \\  buffer.append(42)
        \\  const view = buffer.view(0, 1)
        \\  return read(int, false, view.get(0))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a buffer view returned through an immutable parameter keeps its backing owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, BufferView, read}
        \\fallible tail(imm buffer: Buffer(int)) BufferView(int)
        \\  return buffer.view(1, buffer.len() - 1)
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  buffer.append(42)
        \\  const view = tail(buffer)
        \\  return read(int, false, view.get(0))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a byte buffer view can be returned and stored without copying its backing data" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, BufferView, read}
        \\struct ByteSlice
        \\  view: BufferView(byte)
        \\fallible slice(imm buffer: Buffer(byte)) ByteSlice
        \\  return ByteSlice{view = buffer.view(1, 1)}
        \\fallible run() int
        \\  var bytes = Buffer(byte).new(2)
        \\  bytes.append(17)
        \\  bytes.append(42)
        \\  const stored = slice(bytes)
        \\  const element: byte = read(byte, false, stored.view.get(0))
        \\  _ = element
        \\  return stored.view.len() + bytes.len() + 39
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a stored byte buffer view is invalid after backing storage changes" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, BufferView, read}
        \\struct ByteSlice
        \\  view: BufferView(byte)
        \\fallible slice(imm buffer: Buffer(byte)) ByteSlice
        \\  return ByteSlice{view = buffer.view(0, 1)}
        \\fallible run() unit
        \\  var bytes = Buffer(byte).new(1)
        \\  bytes.append(42)
        \\  const stored = slice(bytes)
        \\  bytes.append(17)
        \\  const element: byte = read(byte, false, stored.view.get(0))
        \\  _ = element
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a byte buffer view cannot escape its local backing buffer" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, BufferView}
        \\fallible escape() BufferView(byte)
        \\  var bytes = Buffer(byte).new(1)
        \\  bytes.append(42)
        \\  return bytes.view(0, 1)
        \\if const view = escape() -> exit(view.len()) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "mutating a buffer invalidates a previously borrowed view" {
    const fixture = try Fixture.init(
        \\import std.memory.{Buffer, read}
        \\fallible run() int
        \\  var buffer = Buffer(int).new(2)
        \\  buffer.append(17)
        \\  const view = buffer.view(0, 1)
        \\  buffer.append(42)
        \\  return read(int, false, view.get(0))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a named unit call result can be borrowed" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\func produce() unit
        \\  const ignored = 1
        \\func run() int
        \\  const result = produce()
        \\  const reference = borrow_local(unit, result)
        \\  _ = read(unit, false, reference)
        \\  return 42
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a named unit branch result can be borrowed" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\func produce() unit
        \\  const ignored = 1
        \\func run() int
        \\  const result = if 1 == 1 -> produce() else produce()
        \\  const reference = borrow_local(unit, result)
        \\  _ = read(unit, false, reference)
        \\  return 42
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a unit parameter can be borrowed during its call" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\func produce() unit
        \\  const ignored = 1
        \\func inspect(imm item: unit) int
        \\  _ = read(unit, false, borrow_local(unit, item))
        \\  return 42
        \\exit(inspect(produce()))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a direct-passed immutable parameter can be borrowed during its call" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\func inspect(imm item: int) int -> read(int, false, borrow_local(int, item))
        \\exit(inspect(42))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a Ref of a direct-passed parameter cannot escape its call" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local}
        \\func escape(imm item: int) Ref(int, false) -> borrow_local(int, item)
        \\const item = 42
        \\const reference = escape(item)
        \\exit(42)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a function can return a Ref derived from an immutable owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func view(imm owner: Box(int)) Ref(int, false) -> return borrow_box(int, owner)
        \\func forward(imm reference: Ref(int, false)) Ref(int, false) -> return reference
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference = forward(view(owner))
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "copied writable Ref handles update stable Box storage" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, borrow_box, read, write}
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const writable: Ref(int, true) = borrow_mut_box(int, owner)
        \\  const copied = writable
        \\  const shared: Ref(int, false) = borrow_box(int, owner)
        \\  write(int, copied, 42)
        \\  return read(int, false, shared)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a writable Ref can be returned through a declared handle origin" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, read, write}
        \\func forward(imm reference: Ref(int, true)) Ref(int, true) from(reference) -> reference
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = forward(borrow_mut_box(int, owner))
        \\  write(int, reference, 42)
        \\  return read(int, true, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a writable Ref returned from a mut Box follows its copied-back owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, borrow_box, read, write}
        \\func view(mut owner: Box(int)) Ref(int, true) from(owner) -> borrow_mut_box(int, owner)
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = view(owner)
        \\  write(int, reference, 42)
        \\  return read(int, false, borrow_box(int, owner))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a fallible returned writable Ref follows the replacement mut owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, borrow_box, read}
        \\fallible view(mut owner: Box(int)) Ref(int, true) from(owner)
        \\  owner = Box.new(42)
        \\  return borrow_mut_box(int, owner)
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = view(owner)
        \\  return read(int, true, reference) + read(int, false, borrow_box(int, owner)) - 42
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a replaced mut Box is copied back after a later failure" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible fail_after_replace(mut owner: Box(int)) unit
        \\  owner = Box.new(42)
        \\  0 > 1
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  if fail_after_replace(owner) -> return 1
        \\  return read(int, false, borrow_box(int, owner))
        \\if const result = run() -> exit(result) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing a mut Box twice drops each outgoing owner once" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible replace_twice(mut owner: Box(int)) unit
        \\  owner = Box.new(23)
        \\  owner = Box.new(42)
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  replace_twice(owner)
        \\  return read(int, false, borrow_box(int, owner))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const replace_twice = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("replace_twice").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = replace_twice })).*.?;
    var drop_count: usize = 0;
    for (body.instructions) |instruction| if (instruction == .call) {
        drop_count += 1;
    };
    try testing.expectEqual(@as(usize, 2), drop_count);
}

test "a read-only Ref cannot be used to write" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, write}
        \\fallible run() unit
        \\  var owner = Box.new(17)
        \\  var reference = borrow_box(int, owner)
        \\  write(int, reference, 42)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .call_argument_type_mismatch);
}

test "an immutable Box owner cannot create a writable Ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box}
        \\fallible run() unit
        \\  const owner = Box.new(17)
        \\  _ = borrow_mut_box(int, owner)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .mutable_argument_requires_mutable_place);
}

test "an immutable Box cannot call borrow_mut" {
    const fixture = try Fixture.init(
        \\fallible run() unit
        \\  const owner = Box.new(17)
        \\  _ = owner.borrow_mut()
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .mutable_argument_requires_mutable_place);
}

test "transferring a Box owner invalidates its writable Ref" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, write}
        \\fallible run() unit
        \\  var owner = Box.new(17)
        \\  const reference = borrow_mut_box(int, owner)
        \\  const moved = owner^
        \\  _ = moved
        \\  write(int, reference, 42)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a mut owner argument cannot overlap a writable Ref argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box}
        \\func conflict(mut owner: Box(int), imm reference: Ref(int, true)) -> return
        \\fallible run() unit
        \\  var owner = Box.new(17)
        \\  const reference = borrow_mut_box(int, owner)
        \\  conflict(owner, reference)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .overlapping_mutable_arguments);
}

test "writing a custom-drop pointee destroys the previous value" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, write}
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(self.value)
        \\fallible run() unit
        \\  var owner = Box.new(Tracked{value = 42})
        \\  write(Tracked, borrow_mut_box(Tracked, owner), Tracked{value = 17})
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a return origin contract excludes unrelated borrowed arguments" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func select(imm first: Ref(int, false), imm second: Ref(int, false)) Ref(int, false) from(first) -> first
        \\fallible run() int
        \\  const first = Box.new(42)
        \\  const second = Box.new(17)
        \\  const selected = select(borrow_box(int, first), borrow_box(int, second))
        \\  const moved = second^
        \\  _ = moved
        \\  return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an indirect call retains only its declared return origins" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func select(imm first: Ref(int, false), imm second: Ref(int, false)) Ref(int, false) from(first) -> first
        \\fallible run() int
        \\  const first = Box.new(42)
        \\  const second = Box.new(17)
        \\  const function = select
        \\  const selected = function(borrow_box(int, first), borrow_box(int, second))
        \\  const moved = second^
        \\  _ = moved
        \\  return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a mut Ref writeback does not widen a declared return origin" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func select(imm first: Ref(int, false), mut output: Ref(int, false), imm second: Ref(int, false)) Ref(int, false) from(first)
        \\  output = second
        \\  return first
        \\fallible run() int
        \\  const first = Box.new(42)
        \\  const second = Box.new(17)
        \\  const other = Box.new(1)
        \\  var output = borrow_box(int, other)
        \\  const selected = select(borrow_box(int, first), output, borrow_box(int, second))
        \\  const moved = second^
        \\  _ = moved
        \\  return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a return origin contract rejects an unlisted owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func select(imm first: Ref(int, false), imm second: Ref(int, false)) Ref(int, false) from(first) -> second
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  return read(int, false, select(borrow_box(int, first), borrow_box(int, second)))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .return_origin_not_declared);
}

test "an origin contract requires a borrowed result" {
    const fixture = try Fixture.init(
        \\func number(imm input: int) int from(input) -> input
        \\exit(number(42))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .invalid_return_origin);
}

test "a returned Ref can depend on an immutable owner aggregate" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Storage
        \\  owner: Box(int)
        \\func view(imm storage: Storage) Ref(int, false) -> borrow_box(int, storage.owner)
        \\fallible run() int
        \\  const storage = Storage{owner = Box.new(42)}
        \\  return read(int, false, view(storage))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an owned Ref parameter may transfer its borrowed handle back" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func forward(var reference: Ref(int, false)) Ref(int, false) -> return reference^
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference = forward(borrow_box(int, owner))
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "transferring a Ref handle does not invalidate its copy" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func forward(imm reference: Ref(int, false)) Ref(int, false) -> reference
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const original = borrow_box(int, owner)
        \\  const copy = forward(original)
        \\  const moved = original^
        \\  return read(int, false, copy)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a conditional Ref result retains either possible owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func choose(imm first: Ref(int, false), imm second: Ref(int, false), pick_first: int) Ref(int, false)
        \\  return if pick_first == 1 -> first else second
        \\fallible run() int
        \\  const first = Box.new(20)
        \\  const second = Box.new(42)
        \\  const chosen = choose(borrow_box(int, first), borrow_box(int, second), 0)
        \\  return read(int, false, chosen)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "reading a multi-owner Ref copies before the youngest owner ends" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func choose(imm first: Box(int), imm second: Box(int), pick_first: int) Ref(int, false)
        \\  return if pick_first == 1 -> borrow_box(int, first) else borrow_box(int, second)
        \\fallible run() int
        \\  const outer = Box.new(17)
        \\  const copied = if 1 == 1
        \\    const inner = Box.new(42)
        \\    read(int, false, choose(inner, outer, 1))
        \\  else
        \\    0
        \\  return copied
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a returned Ref cannot outlive either possible owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\func choose(imm first: Ref(int, false), imm second: Ref(int, false), pick_first: int) Ref(int, false)
        \\  return if pick_first == 1 -> first else second
        \\fallible run() int
        \\  const first = Box.new(20)
        \\  const second = Box.new(42)
        \\  const chosen = choose(borrow_box(int, first), borrow_box(int, second), 0)
        \\  const moved = first^
        \\  return read(int, false, chosen)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a mutable Ref binding retains origins across branch assignments" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run(pick_second: int) int
        \\  const first = Box.new(20)
        \\  const second = Box.new(42)
        \\  var selected = borrow_box(int, first)
        \\  if pick_second == 1 -> selected = borrow_box(int, second)
        \\  return read(int, false, selected)
        \\if const result = run(1) -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a loop break retains its Ref origin" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference = loop -> break borrow_box(int, owner)
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a mutable Ref binding retains its origin through a loop exit" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var selected = borrow_box(int, first)
        \\  loop
        \\    selected = borrow_box(int, second)
        \\    break
        \\  return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a mutable Ref binding retains backedge origins" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var selected = borrow_box(int, first)
        \\  var phase = 0
        \\  const reference = loop
        \\    if phase == 0
        \\      selected = borrow_box(int, second)
        \\      phase = 1
        \\      continue
        \\    break selected
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a loop-carried Ref is invalid when a possible owner transfers" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var selected = borrow_box(int, first)
        \\  var phase = 0
        \\  loop
        \\    if phase == 0
        \\      selected = borrow_box(int, second)
        \\      phase = 1
        \\      continue
        \\    break
        \\  const moved = second^
        \\  return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a Ref read inside a loop keeps backedge owners live" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var selected = borrow_box(int, first)
        \\  var phase = 0
        \\  loop
        \\    if phase == 0
        \\      selected = borrow_box(int, second)
        \\      phase = 1
        \\      continue
        \\    return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a Ref of an unchanged mutable owner survives a loop header" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  const reference = borrow_box(int, owner)
        \\  return loop -> break read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a Ref of a replaced loop owner cannot be read" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = borrow_box(int, owner)
        \\  loop
        \\    owner = Box.new(42)
        \\    break
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a Ref of a directly replaced owner cannot be read" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  var owner = Box.new(17)
        \\  const reference = borrow_box(int, owner)
        \\  owner = Box.new(42)
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a Ref of an owned field cannot outlive its parent replacement" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Holder
        \\  box: Box(int)
        \\fallible run() int
        \\  var holder = Holder{box = Box.new(17)}
        \\  const reference = borrow_box(int, holder.box)
        \\  holder = Holder{box = Box.new(42)}
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "nested loops retain their separate Ref origin sets" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var selected = borrow_box(int, first)
        \\  var count = 0
        \\  loop
        \\    loop
        \\      selected = borrow_box(int, second)
        \\      break
        \\    if count == 0
        \\      count = 1
        \\      continue
        \\    break
        \\  return read(int, false, selected)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a struct containing a Ref cannot escape its local owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box}
        \\struct View
        \\  reference: Ref(int, false)
        \\fallible escape() View
        \\  const owner = Box.new(42)
        \\  return View{reference = borrow_box(int, owner)}
        \\if const view = escape() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a Ref keeps its origin through variant widening and extraction" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const selected: Ref(int, false) | none = borrow_box(int, owner)
        \\  return if const reference = selected as Ref(int, false) -> read(int, false, reference) else 0
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "variant extraction rejects a Ref after its owner transfers" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const selected: Ref(int, false) | none = borrow_box(int, owner)
        \\  const moved = owner^
        \\  return if const reference = selected as Ref(int, false) -> read(int, false, reference) else 0
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "a struct containing a Ref may return with its borrowed input" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct View
        \\  reference: Ref(int, false)
        \\func view(imm owner: Box(int)) View -> return View{reference = borrow_box(int, owner)}
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  return read(int, false, view(owner).reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "an in-place Box containing a Ref retains its referent" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct View
        \\  move = none
        \\  reference: Ref(int, false)
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const stored = Box(View).new(View{reference = borrow_box(int, owner)})
        \\  const moved = owner^
        \\  return read(int, false, read(View, false, borrow_box(View, stored)).reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "replacing a Ref field retains the new referent dependency" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct View
        \\  reference: Ref(int, false)
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var view = View{reference = borrow_box(int, first)}
        \\  view.reference = borrow_box(int, second)
        \\  const moved = second^
        \\  return read(int, false, view.reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "mut writeback retains origins of a Ref argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct View
        \\  reference: Ref(int, false)
        \\func replace(mut view: View, imm reference: Ref(int, false))
        \\  view.reference = reference
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var view = View{reference = borrow_box(int, first)}
        \\  replace(view, borrow_box(int, second))
        \\  return read(int, false, view.reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "mut writeback retains an immutable owner's origin" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct View
        \\  reference: Ref(int, false)
        \\func replace(mut view: View, imm owner: Box(int))
        \\  view.reference = borrow_box(int, owner)
        \\fallible run() int
        \\  const first = Box.new(17)
        \\  const second = Box.new(42)
        \\  var view = View{reference = borrow_box(int, first)}
        \\  replace(view, second)
        \\  return read(int, false, view.reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "mut output cannot borrow a callee local" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, borrow_box}
        \\struct View
        \\  reference: Ref(int, false)
        \\func replace(mut view: View)
        \\  const local = 42
        \\  view.reference = borrow_local(int, local)
        \\fallible run() unit
        \\  const owner = Box.new(17)
        \\  var view = View{reference = borrow_box(int, owner)}
        \\  replace(view)
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "mut writeback cannot outlive its caller-side referent" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct View
        \\  reference: Ref(int, false)
        \\func replace(mut view: View, imm reference: Ref(int, false))
        \\  view.reference = reference
        \\fallible run() int
        \\  const outer = Box.new(17)
        \\  var view = View{reference = borrow_box(int, outer)}
        \\  if 1 == 1
        \\    const inner = Box.new(42)
        \\    replace(view, borrow_box(int, inner))
        \\  return read(int, false, view.reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "fallible calls retain returned Ref origins" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible forward(imm reference: Ref(int, false)) Ref(int, false)
        \\  return reference
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  if const returned = forward(borrow_box(int, owner)) -> return read(int, false, returned)
        \\  else return 1
        \\if const result = run() -> exit(result) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "indirect fallible calls retain returned Ref origins" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible forward(imm reference: Ref(int, false)) Ref(int, false)
        \\  return reference
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const function = forward
        \\  if const returned = function(borrow_box(int, owner)) -> return read(int, false, returned)
        \\  else return 1
        \\if const result = run() -> exit(result) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "copying a Ref of a noncopyable immovable value copies only its address" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\struct Immovable
        \\  move = none
        \\  copy = none
        \\  value: int
        \\fallible run() int
        \\  const owner = Box(Immovable).new(Immovable{value = 42})
        \\  const first = borrow_box(Immovable, owner)
        \\  const second = first
        \\  return read(Immovable, false, second).value
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "a local immovable value can be borrowed without copying it" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\struct Immovable
        \\  move = none
        \\  copy = none
        \\  value: int
        \\func run() int
        \\  const local = Immovable{value = 42}
        \\  const reference: Ref(Immovable, false) = borrow_local(Immovable, local)
        \\  return read(Immovable, false, reference).value
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "replacing a borrowed scalar local invalidates its address" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_local, read}
        \\var number = 42
        \\const reference = borrow_local(int, number)
        \\number = 7
        \\exit(read(int, false, reference))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a borrow of a local Box cannot escape its owner" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box}
        \\fallible escape() Ref(int, false)
        \\  const owner = Box.new(42)
        \\  return borrow_box(int, owner)
        \\if escape() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
}

test "a borrow cannot be read after its Box owner is transferred" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box, read}
        \\fallible run() int
        \\  const owner = Box.new(42)
        \\  const reference = borrow_box(int, owner)
        \\  const moved = owner^
        \\  return read(int, false, reference)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "Box destroys its initialized value on last use" {
    const fixture = try Fixture.init(
        \\import std.memory.{Box}
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\fallible run() unit
        \\  const owner = Box.new(Resource{value = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box constructs immovable struct directly in owned storage" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  marker: byte
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible run() unit
        \\  const owner = Box(Immovable).new(Immovable{marker = 7, value = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box drops a struct with a custom move without relocating it" {
    const fixture = try Fixture.init(
        \\struct CustomMove
        \\  value: int
        \\  move = func(deinit self: CustomMove) CustomMove -> return CustomMove{value = self.value}
        \\  drop = func(deinit self: CustomMove) -> exit(self.value)
        \\fallible run() unit
        \\  const owner = Box(CustomMove).new(CustomMove{value = 42})
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit consumes an immovable local at its original address" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  move = none
        \\  value: int
        \\func consume(deinit item: Item) int -> item.value
        \\const item = Item{value = 42}
        \\exit(consume(item))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit does not invoke a custom move hook" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  value: int
        \\  move = func(deinit self: Item) Item -> Item{value = self.value + 1}
        \\func consume(deinit item: Item) int -> item.value
        \\const item = Item{value = 42}
        \\exit(consume(item^))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit constructs fresh variant arguments before passing their address" {
    const fixture = try Fixture.init(
        \\func consume(deinit item: int | none) int
        \\  if const number = item as int -> return number
        \\  return 1
        \\const indirect = consume
        \\exit(consume(20) + indirect(22))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit rejects borrowed parameters instead of copying them" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  value: int
        \\  copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\func consume(deinit item: Item) int -> item.value
        \\func forward(imm item: Item) int -> consume(item)
        \\exit(forward(Item{value = 42}))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .ownership_transfer_requires_owned_place);
}

test "deinit rejects borrowed fields aliases and referents" {
    const cases = [_][]const u8{
        \\func run(imm holder: Holder) int -> consume(holder.item)
        \\exit(run(Holder{item = Item{value = 42}}))
        ,
        \\const item = Item{value = 42}
        \\borrow alias = item
        \\exit(consume(alias))
        ,
        \\const holder = Holder{item = Item{value = 42}}
        \\borrow alias = holder
        \\exit(consume(alias.item))
        ,
        \\fallible run() int
        \\  const owner = Box.new(Item{value = 42})
        \\  return consume(owner.borrow()[])
        \\if const result = run() -> exit(result) else exit(1)
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .ownership_transfer_requires_owned_place);
    }
}

test "deinit member receivers preserve independent field availability" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit completes an explicit-drop root" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  drop = explicit
        \\  value: int
        \\func dispose(deinit item: Item) int -> item.value
        \\const item = Item{value = 42}
        \\exit(dispose(item))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit move hooks transfer fields through nested hooks exactly once" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit conflicts with an earlier borrow of the same field" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  value: int
        \\struct Holder
        \\  item: Item
        \\func take(imm borrowed: Item, deinit consumed: Item) int -> borrowed.value
        \\const holder = Holder{item = Item{value = 42}}
        \\exit(take(holder.item, holder.item))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "deinit move hooks transfer fields and clean up remaining fields" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit forwards an explicit-drop field from its original storage" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Holder
        \\  drop = explicit
        \\  storage: Allocation(int)
        \\func dispose(deinit holder: Holder)
        \\  deallocate(int, holder.storage)
        \\fallible run() unit
        \\  const holder = Holder{storage = allocate(int, 1)}
        \\  dispose(holder)
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit member call consumes an owned field" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate}
        \\struct Holder
        \\  storage: Allocation(int)
        \\func dispose(deinit holder: Holder)
        \\  holder.storage.release()
        \\fallible run() unit
        \\  const holder = Holder{storage = allocate(int, 1)}
        \\  dispose(holder)
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit field consumption invalidates later field reads" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Holder
        \\  storage: Allocation(int)
        \\func invalid(deinit holder: Holder) int
        \\  deallocate(int, holder.storage)
        \\  return holder.storage.capacity()
        \\fallible run() int
        \\  const holder = Holder{storage = allocate(int, 1)}
        \\  return invalid(holder)
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .use_after_transfer);
}

test "deinit source is cleaned when a later argument fails" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\fallible fail() int
        \\  1 == 0
        \\  return 0
        \\func take(deinit item: Item, value: int) -> ()
        \\fallible run() unit
        \\  const item = Item{value = 42}
        \\  take(item, fail())
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit forwarding retains residual cleanup when a later argument fails" {
    const fixture = try Fixture.init(
        \\struct Child
        \\  value: int
        \\  drop = func(deinit self: Child) -> exit(self.value)
        \\struct Item
        \\  child: Child
        \\  drop = func(deinit self: Item) -> exit(1)
        \\func take(deinit item: Item, value: int) -> ()
        \\fallible fail() int
        \\  1 == 0
        \\  return 0
        \\fallible forward(deinit item: Item) unit
        \\  take(item, fail())
        \\if forward(Item{child = Child{value = 42}}) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit fresh variant cleanup survives later argument failure" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\func take(deinit item: Item | none, value: int) -> ()
        \\fallible fail() int
        \\  1 == 0
        \\  return 0
        \\fallible run() unit
        \\  take(Item{value = 42}, fail())
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "deinit explicit arguments cannot be abandoned by later argument failure" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  drop = explicit
        \\func take(deinit item: Item, value: int) -> ()
        \\fallible fail() int
        \\  1 == 0
        \\  return 0
        \\fallible run() unit
        \\  const item = Item{}
        \\  take(item, fail())
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .value_requires_explicit_drop);
}

test "custom drop hook does not redispatch after replacing self" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource)
        \\    self = Resource{value = self.value + 1}
        \\    exit(self.value)
        \\fallible run() unit
        \\  const owner = Box.new(Resource{value = 41})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box in-place construction infers immovable element type" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible run() unit
        \\  const owner = Box.new(Immovable{value = 42})
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    var constructed_in_place = false;
    for (body.instructions) |instruction| {
        if (instruction == .box_init) constructed_in_place = true;
        try testing.expect(instruction != .struct_init);
    }
    try testing.expect(constructed_in_place);
}

test "Box constructs generated immovable structs without temporary values" {
    const fixture = try Fixture.init(
        \\struct Container(T: type)
        \\  move = none
        \\  value: T
        \\fallible run() unit
        \\  const owner = Box.new(Container{value = 42})
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    var constructed_in_place = false;
    for (body.instructions) |instruction| {
        if (instruction == .box_init) constructed_in_place = true;
        try testing.expect(instruction != .struct_init);
    }
    try testing.expect(constructed_in_place);
}

test "Box constructs nested immovable fields in final storage" {
    const fixture = try Fixture.init(
        \\struct Inner
        \\  move = none
        \\  prefix: byte
        \\  value: int
        \\  drop = func(deinit self: Inner) -> exit(self.value)
        \\struct Outer
        \\  move = none
        \\  prefix: int
        \\  inner: Inner
        \\fallible run() unit
        \\  const owner = Box.new(Outer{prefix = 7, inner = Inner{prefix = 3, value = 42}})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
    try fixture.expectExit(0, 42);
}

test "an ignored fallible immovable result still receives return storage" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible make() Immovable -> Immovable{value = 42}
        \\if make() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box constructs an immovable function result in final storage" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make() Immovable -> Immovable{value = 42}
        \\fallible run() unit
        \\  const owner = Box(Immovable).new(make())
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
}

test "Box infers an immovable function result and evaluates arguments once" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make(value: int) Immovable -> Immovable{value = value}
        \\fallible run() unit
        \\  const owner = Box.new(make(42))
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
}

test "Box deallocates storage when an immovable producer fails" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible make(value: int) Immovable
        \\  value == 42
        \\  return Immovable{value = value}
        \\fallible run(value: int) unit
        \\  const owner = Box.new(make(value))
        \\  _ = owner
        \\  exit(1)
        \\if run(7) -> exit(2) else if run(42) -> exit(3) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    var direct_return = false;
    for (body.blocks) |block| switch (block.terminator) {
        .fallible_call => |call| if (call.call.destination != null) {
            direct_return = true;
        },
        else => {},
    };
    try testing.expect(direct_return);
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
}

test "Box constructs an immovable indirect function result in final storage" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\func make(value: int) Immovable -> Immovable{value = value}
        \\fallible run() unit
        \\  const producer = make
        \\  const owner = Box.new(producer(42))
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
}

test "Box deallocates storage when an indirect producer fails" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible make(value: int) Immovable
        \\  value == 42
        \\  return Immovable{value = value}
        \\fallible run(value: int) unit
        \\  const producer = make
        \\  const owner = Box(Immovable).new(producer(value))
        \\  _ = owner
        \\  exit(1)
        \\if run(7) -> exit(2) else if run(42) -> exit(3) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box allocation failure rejects an unhandled explicit-drop producer argument" {
    const fixture = try Fixture.init(
        \\import std.memory.{Allocation, allocate, deallocate}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make(deinit resource: Allocation(int)) Immovable
        \\  deallocate(int, resource^)
        \\  return Immovable{value = 42}
        \\fallible run() unit
        \\  var resource = allocate(int, 1)
        \\  const owner = Box.new(make(resource^))
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .value_requires_explicit_drop);
}

test "Box allocation failure cleans an automatic-drop producer argument" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> ()
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make(deinit item: Tracked) Immovable -> Immovable{value = item.value}
        \\fallible run() unit
        \\  const owner = Box.new(make(Tracked{value = 42}))
        \\  _ = owner
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    const types: queries.AnalysisContext(*query.Database) = .{ .ctx = fixture.db };
    var drop_hook: ?structures.InstanceId = null;
    for (body.instructions) |instruction| if (instruction == .struct_init) {
        drop_hook = (try types.structDefinition(instruction.struct_init.type_id)).?.ownership.drop.?.hook;
    };
    try testing.expect(drop_hook != null);
    var cleanup_present = false;
    for (body.instructions) |instruction| if (instruction == .call) {
        if (instruction.call.target == .direct and std.meta.eql(instruction.call.target.direct, drop_hook.?)) cleanup_present = true;
    };
    try testing.expect(cleanup_present);
}

test "Box propagates mutable producer arguments on failure and success" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible make(mut value: int, succeed: int) Immovable
        \\  value += 1
        \\  succeed > 0
        \\  return Immovable{value = value}
        \\fallible run() unit
        \\  var number = 40
        \\  if const owner = Box.new(make(number, 0))
        \\    _ = owner
        \\    exit(1)
        \\  if number == 41 -> () else exit(2)
        \\  const owner = Box.new(make(number, 1))
        \\  _ = owner
        \\  exit(3)
        \\if run() -> exit(4) else exit(5)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box constructs zero-sized immovable results from fallible producers" {
    const fixture = try Fixture.init(
        \\struct Empty
        \\  move = none
        \\  drop = func(deinit self: Empty) -> exit(42)
        \\fallible make(succeed: int) Empty
        \\  succeed > 0
        \\  return Empty{}
        \\fallible run(succeed: int) unit
        \\  const owner = Box.new(make(succeed))
        \\  _ = owner
        \\  exit(1)
        \\if run(0) -> exit(2) else if run(1) -> exit(3) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ignored fallible immovable result still has return storage" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible make() Immovable -> return Immovable{value = 42}
        \\if make() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box constructs conditional immovable literals without temporary values" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible run(value: int) unit
        \\  const owner = Box(Immovable).new(if value == 42 -> Immovable{value = 42} else Immovable{value = 7})
        \\  _ = owner
        \\  exit(1)
        \\if run(42) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
}

test "conditional Box construction in an if condition reports its unsupported form" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\if Box.new(if 1 == 1 -> Immovable{value = 42} else Immovable{value = 0}) -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .box_conditional_condition_not_supported);
}

test "Box infers the result of conditional immovable literals" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\fallible run(value: int) unit
        \\  const owner = Box.new(if value == 42 -> Immovable{value = 42} else Immovable{value = 7})
        \\  _ = owner
        \\  exit(1)
        \\if run(42) -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
}

test "Box infers nested immovable fields without temporary values" {
    const fixture = try Fixture.init(
        \\struct Inner
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Inner) -> exit(self.value)
        \\struct Container(T: type)
        \\  move = none
        \\  item: T
        \\fallible run() unit
        \\  const owner = Box.new(Container{item = Inner{value = 42}})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    const run = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run })).*.?;
    for (body.instructions) |instruction| try testing.expect(instruction != .struct_init);
    try fixture.expectExit(0, 42);
}

test "inferred nested Box initialization cleans up leaves before later fields" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
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
        \\fallible fail() int
        \\  const storage = allocate(int, -1)
        \\  deallocate(int, storage^)
        \\  return 1
        \\fallible run() unit
        \\  const owner = Box.new(Container{item = Inner{leaf = Tracked{value = 42}}, later = fail()})
        \\  _ = owner
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "nested in-place Box initialization cleans up leaves on failure" {
    const fixture = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
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
        \\fallible fail() int
        \\  const storage = allocate(int, -1)
        \\  deallocate(int, storage^)
        \\  return 1
        \\fallible run() unit
        \\  const owner = Box.new(Outer{inner = Inner{leaf = Tracked{value = 42}}, later = fail()})
        \\  _ = owner
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box drops an owned field inside an immovable struct" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: Box(Resource)
        \\fallible run() unit
        \\  const inner = Box.new(Resource{value = 42})
        \\  const outer = Box(Immovable).new(Immovable{field = inner^})
        \\  _ = outer
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    const run_item = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("run").?;
    const run_body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = run_item })).*.?;
    var dropped_in_place = false;
    for (run_body.instructions) |instruction| if (instruction == .box_init) {
        const types: queries.AnalysisContext(*query.Database) = .{ .ctx = fixture.db };
        const owner = (try types.structDefinition(instruction.box_init.box_type)).?;
        const drop_hook = owner.ownership.drop.?.hook.?;
        const drop_body = (try fixture.db.get(queries.AnalyzeFunctionInstance, drop_hook)).*.?;
        for (drop_body.instructions) |drop_instruction| {
            if (drop_instruction == .storage_projection) dropped_in_place = true;
        }
    };
    try testing.expect(dropped_in_place);
    try fixture.expectExit(0, 42);
}

test "Box drops nested owners with the same specialization" {
    const fixture = try Fixture.init(
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Node
        \\  move = none
        \\  resource: Resource
        \\  next: Box(Node) | none
        \\fallible run() unit
        \\  const inner = Box(Node).new(Node{resource = Resource{value = 42}, next = none})
        \\  const outer = Box(Node).new(Node{resource = Resource{value = 1}, next = inner^})
        \\  _ = outer
        \\  exit(2)
        \\if run() -> exit(3) else exit(4)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box destructor follows immovable field edits" {
    const original =
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\struct Immovable
        \\  move = none
        \\  field: Resource
        \\fallible run() unit
        \\  const owner = Box(Immovable).new(Immovable{field = Resource{value = 42}})
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
        \\  const owner = Box(Immovable).new(Immovable{field = 42})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    );
    try fixture.expectExit(0, 1);
    try fixture.db.setInput(queries.SourceText, 0, original);
    try fixture.expectExit(0, 42);
}

test "immovable Box from a conditional binding drops on the success path" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Immovable) -> exit(self.value)
        \\if const owner = Box(Immovable).new(Immovable{value = 42})
        \\  _ = owner
        \\  exit(1)
        \\else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "zero-sized immovable Box destroys its value" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  drop = func(deinit self: Immovable) -> exit(42)
        \\fallible run() unit
        \\  const owner = Box(Immovable).new(Immovable{})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box in-place initializer cleans up fields when a later field fails" {
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
        \\  const owner = Box(Immovable).new(Immovable{first = Tracked{value = 42}, second = fail()})
        \\  _ = owner
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box rejects transfers and nested immovable fields" {
    const cases = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\const original = Immovable{value = 42}
        \\if Box(Immovable).new(original) -> exit(1) else exit(2)
        , .diagnostic = .box_requires_struct_initializer },
        .{ .source =
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\if Box(Explicit).new(Explicit{value = 42}) -> exit(1) else exit(2)
        , .diagnostic = .box_requires_automatic_drop },
        .{ .source =
        \\struct Explicit
        \\  drop = explicit
        \\  value: int
        \\if Box.new(Explicit{value = 42}) -> exit(1) else exit(2)
        , .diagnostic = .box_requires_automatic_drop },
        .{ .source =
        \\import std.memory.{value}
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\fallible run() unit
        \\  const owner = Box(Immovable).new(Immovable{value = 42})
        \\  const extracted = value(Immovable, owner^)
        \\  _ = extracted
        \\if run() -> exit(1) else exit(2)
        , .diagnostic = .box_extraction_requires_direct_move },
    };
    for (cases) |case| {
        const fixture = try Fixture.init(case.source, &.{});
        defer fixture.deinit();
        if (case.diagnostic == .box_requires_struct_initializer)
            try fixture.expectDiagnostic(0, case.diagnostic)
        else
            try fixture.expectLibraryDiagnostic(case.diagnostic);
    }
}

test "Box transfers its value and releases its allocation" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const owner = Box(int).new(42)
        \\  const number = value(int, owner^)
        \\  number == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "zero-sized Box supports consuming extraction" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const owner = Box.new(())
        \\  _ = value(unit, owner^)
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box transfers an aggregate value" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\struct Pair
        \\  first: int
        \\  second: byte
        \\fallible take() unit
        \\  const owner = Box.new(Pair{first = 42, second = 7})
        \\  const pair = value(Pair, owner^)
        \\  pair.first == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box can own and transfer another Box" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const inner = Box.new(42)
        \\  const outer = Box(Box(int)).new(inner^)
        \\  const moved = value(Box(int), outer^)
        \\  const number = value(int, moved^)
        \\  number == 42
        \\if take() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "zero-sized Box destroys its initialized value on last use" {
    const fixture = try Fixture.init(
        \\import std.memory.{Box}
        \\struct Empty
        \\  drop = func(deinit self: Empty) -> exit(42)
        \\fallible run() unit
        \\  const owner = Box(Empty).new(Empty{})
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "prelude exports Box and its constructor without exporting raw allocation" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\fallible take() unit
        \\  const owner: Box(int) = Box.new(42)
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

test "generic struct initializer infers type from Box field" {
    const fixture = try Fixture.init(
        \\import std.memory.{Box}
        \\struct Foo(T: type)
        \\  r: Box(T)
        \\fallible run() unit
        \\  const f = Foo{r = Box.new(42)}
        \\  _ = f
        \\if run() -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "fallible condition binding initializes an inferred struct field" {
    const fixture = try Fixture.init(
        \\struct Foo(T: type)
        \\  r: Box(T)
        \\const f = Foo{r = if const owner = Box.new(42) -> owner^ else exit(1)}
        \\_ = f
        \\exit(42)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "fallible condition binding owns its Box on success" {
    const success = try Fixture.init(
        \\import std.memory.{value}
        \\if const owner: Box(int) = Box.new(42) -> exit(value(int, owner^)) else exit(1)
    , &.{});
    defer success.deinit();
    try success.expectExit(0, 42);

    const failure = try Fixture.init(
        \\import std.memory.{allocate, deallocate}
        \\fallible invalid_ref() Box(int)
        \\  const allocation = allocate(int, -1)
        \\  deallocate(int, allocation^)
        \\  return Box.new(42)
        \\if const owner = invalid_ref() -> exit(1) else exit(42)
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
        \\  first: Ref(Item, true)
        \\  second: Ref(Item, true)
        \\  {hook}
        \\    return Pair{first = self.second, second = self.first}
        \\fallible run() int
        \\  var first_owner = Box.new(Item{value = 17})
        \\  var second_owner = Box.new(Item{value = 23})
        \\  const first = first_owner.borrow_mut()
        \\  const second = second_owner.borrow_mut()
        \\  const source = Pair{first = first, second = second}
        \\  const copied = {operand}
        \\  const handle = copied.first
        \\  {s}
        \\  return handle[].value
        \\if const result = run() -> exit(result) else exit(1)
    ;
    inline for (.{
        .{ .hook = "copy = func(imm self: Pair) Pair", .operand = "source" },
        .{ .hook = "move = func(deinit self: Pair) Pair", .operand = "source^" },
    }) |case| {
        const hooked = try std.mem.replaceOwned(u8, testing.allocator, source, "{hook}", case.hook);
        defer testing.allocator.free(hooked);
        const operation = try std.mem.replaceOwned(u8, testing.allocator, hooked, "{operand}", case.operand);
        defer testing.allocator.free(operation);
        inline for (.{ false, true }) |replace_owner| {
            const edited = try std.mem.replaceOwned(u8, testing.allocator, operation, "{s}", if (replace_owner) "second_owner = Box.new(Item{value = 42})" else "");
            defer testing.allocator.free(edited);
            const fixture = try Fixture.init(edited, &.{});
            defer fixture.deinit();
            if (replace_owner) try fixture.expectDiagnostic(0, .borrow_outlives_source) else try fixture.expectExit(0, 23);
        }
    }
}

test "four byte aggregates return through direct and indirect calls" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "conditional reference copies preserve live origins and reject replaced owners" {
    for ([_][]const u8{ "reference", "owner.borrow()" }) |first| {
        for ([_]bool{ false, true }) |replace_owner| {
            const source = try std.fmt.allocPrint(testing.allocator,
                \\fallible run() int
                \\  var owner = Box.new(42)
                \\  const reference = owner.borrow()
                \\  const selected = if 1 == 1 -> {s} else reference
                \\  {s}
                \\  return selected[]
                \\if const result = run() -> exit(result) else exit(1)
            , .{ first, if (replace_owner) "owner = Box.new(17)" else "_ = reference" });
            defer testing.allocator.free(source);
            const fixture = try Fixture.init(source, &.{});
            defer fixture.deinit();
            if (replace_owner) try fixture.expectDiagnostic(0, .borrow_outlives_source) else try fixture.expectExit(0, 42);
        }
    }
}

test "partial variant copies retain reference origins" {
    const cases = [_]struct { condition: []const u8, replace: []const u8, expected: ?u8 }{
        .{ .condition = "1 == 1", .replace = "", .expected = 42 },
        .{ .condition = "1 == 0", .replace = "", .expected = 0 },
        .{ .condition = "1 == 1", .replace = "owner = Box.new(17)", .expected = null },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fallible run() int
            \\  var owner = Box.new(42)
            \\  const reference = owner.borrow()
            \\  const selected = if {s} -> reference else Box.new(17)
            \\  {s}
            \\  return if const handle = selected as Ref(int, false) -> handle[] else 0
            \\if const result = run() -> exit(result) else exit(1)
        , .{ case.condition, case.replace });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
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
        \\  target: Ref(Item, true)
        \\  drop = func(deinit self: Guard)
        \\    self.target[] = Item{value = 42}
        \\func observe(imm previous: Item, marker: int) int -> previous.value
        \\func inspect(imm reference: Ref(Item, true)) int
        \\  return observe(reference[], if 1 == 1
        \\    const guard = Guard{target = reference}
        \\    0
        \\  else 0)
        \\fallible run() int
        \\  var owner = Box.new(Item{value = 17})
        \\  return inspect(owner.borrow_mut())
        \\if const result = run() -> exit(result) else exit(1)
    ;
    const fixture = try Fixture.init(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .borrow_outlives_source);
    const repaired = try std.mem.replaceOwned(u8, testing.allocator, source, "observe(reference[],", "observe(Item{value = 17},");
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
        \\  target: Ref(Item, true)
        \\  drop = func(deinit self: Replacer)
        \\    self.target[] = Item{value = 42}
        \\struct Wrapper
        \\  guard: Replacer
        \\func observe(imm previous: Item, marker: int) int -> previous.value
        \\fallible run() int
        \\  var owner = Box.new(Item{value = 17})
        \\  const reference = owner.borrow_mut()
    ;
    const cases = [_]struct { before: []const u8, after: []const u8, expected: ?u8 }{
        .{ .before = "  return observe(reference[], if 1 == 1\n", .after = "    0\n  else 0)\n", .expected = null },
        .{ .before = "  const marker = if 1 == 1\n", .after = "    0\n  else 0\n  return observe(reference[], marker)\n", .expected = 42 },
        .{ .before = "  return if 1 == 1 -> observe(reference[], 0) else\n", .after = "    0\n", .expected = 17 },
    };
    for ([_][]const u8{
        "Replacer{target = reference}",
        "Wrapper{guard = Replacer{target = reference}}",
        "Box.new(Replacer{target = reference})",
        "if 1 == 1 -> Replacer{target = reference} else Replacer{target = reference}",
        "loop -> break Replacer{target = reference}",
    }) |guard| {
        for (cases) |case| {
            const source = try std.mem.concat(testing.allocator, u8, &.{ header, "\n", case.before, "    const guard = ", guard, "\n", case.after, "if const result = run() -> exit(result) else exit(1)" });
            defer testing.allocator.free(source);
            errdefer std.debug.print("cleanup regression source:\n{s}\n", .{source});
            const fixture = try Fixture.init(source, &.{});
            defer fixture.deinit();
            if (case.expected) |expected| try fixture.expectExit(0, expected) else try fixture.expectDiagnostic(0, .borrow_outlives_source);
        }
    }
}

test "custom copy and move effects invalidate pending borrows" {
    const cases = .{
        .{ .movement = "", .hook = "copy = func(imm", .parameter = "Copier", .argument = "source", .access = "copied.target[].value" },
        .{ .movement = "", .hook = "copy = func(imm", .parameter = "Box(Copier)", .argument = "duplicate(Copier, source)", .access = "copied.borrow()[].target[].value" },
        .{ .movement = "  move = none\n", .hook = "copy = func(imm", .parameter = "Box(Copier)", .argument = "duplicate(Copier, source)", .access = "copied.borrow()[].target[].value" },
        .{ .movement = "", .hook = "move = func(deinit", .parameter = "Copier", .argument = "source^", .access = "copied.target[].value" },
    };
    inline for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            "import std.memory.{duplicate}\nstruct Item\n  value: int\n  drop = func(deinit self: Item) -> ()\nstruct Copier\n",
            case.movement,
            "  target: Ref(Item, true)\n  ",
            case.hook,
            " self: Copier) Copier\n    self.target[] = Item{value = 42}\n    return Copier{target = self.target}\nfunc observe(imm previous: Item, var copied: ",
            case.parameter,
            ") int -> previous.value + ",
            case.access,
            " - 42\nfallible run() int\n  var owner = Box.new(Item{value = 17})\n  const reference = owner.borrow_mut()\n  const source = Copier{target = reference}\n  return observe(reference[], ",
            case.argument,
            ")\nif const result = run() -> exit(result) else exit(1)",
        });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .borrow_outlives_source);
        const repaired = try std.mem.replaceOwned(u8, testing.allocator, source, "observe(reference[], ", "observe(Item{value = 17}, ");
        defer testing.allocator.free(repaired);
        try fixture.db.setInput(queries.SourceText, 0, repaired);
        try fixture.expectExit(0, 17);
    }
}

test "duplicate copies into a new Box without consuming its source" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate, value}
        \\struct Copyable
        \\  copy = func(imm self: Copyable) Copyable -> Copyable{value = self.value + 1}
        \\  value: int
        \\fallible run() int
        \\  const source = Copyable{value = 41}
        \\  const owner = duplicate(Copyable, source)
        \\  const copied = value(Copyable, owner^)
        \\  return copied.value + source.value - 41
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "duplicate constructs a copy-only value in new storage" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
        \\struct CopyOnly
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\  drop = func(deinit self: CopyOnly) -> exit(self.value)
        \\fallible run() unit
        \\  const source = CopyOnly{value = 42}
        \\  const owner = duplicate(CopyOnly, source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "duplicate runs an immovable custom copy hook in new storage" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\  drop = func(deinit self: CopyOnly)
        \\    if self.value == 42 -> exit(42) else ()
        \\fallible run() unit
        \\  const source = CopyOnly{value = 41}
        \\  const owner = duplicate(CopyOnly, source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "duplicate copies nested fields with custom hooks into final storage" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
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
        \\fallible run() unit
        \\  const source = Outer{first = 1, middle = Middle{first = 2, inner = Inner{value = 41}}}
        \\  const owner = duplicate(Outer, source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "duplicate copies the active member of an immovable variant" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\  drop = func(deinit self: CopyOnly)
        \\    if self.value == 42 -> exit(42) else ()
        \\static CopyOrInt = CopyOnly | int
        \\fallible run() unit
        \\  const source: CopyOrInt = CopyOnly{value = 41}
        \\  const owner = duplicate(CopyOrInt, source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "duplicate does not copy inactive variant members" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> exit(1)
        \\  value: int
        \\static CopyOrInt = CopyOnly | int
        \\fallible run() unit
        \\  const source: CopyOrInt = 41
        \\  const owner = duplicate(CopyOrInt, source)
        \\  _ = owner
        \\  exit(42)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "duplicate rejects noncopyable values" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
        \\struct Token
        \\  move = none
        \\  value: int
        \\const source = Token{value = 42}
        \\if duplicate(Token, source) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.type_not_copyable);
}

test "duplicate rejects explicitly droppable values" {
    const fixture = try Fixture.init(
        \\import std.memory.{duplicate}
        \\struct Explicit
        \\  copy = trivial
        \\  drop = explicit
        \\  value: int
        \\const source = Explicit{value = 42}
        \\if duplicate(Explicit, source) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.box_requires_automatic_drop);
}

test "reference replacement eligibility is checked for function values" {
    const fixture = try Fixture.init(
        \\fallible run() unit
        \\  const owner = Box.new(42)
        \\  var holder = Box.new(owner.borrow())
        \\  const replace = Ref(Ref(int, false), true).replace
        \\  replace(holder.borrow_mut(), owner.borrow())
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectLibraryDiagnostic(.borrow_write_cannot_store_borrow);
}

test "library eligibility is checked for function values" {
    const fixture = try Fixture.init(
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
    const fixture = try Fixture.init(
        \\import std.memory.{Box}
        \\struct Resource
        \\  value: int
        \\  drop = func(deinit self: Resource) -> exit(self.value)
        \\fallible run() unit
        \\  const first = Box.new(Resource{value = 42})
        \\  const moved = first^
        \\  _ = moved
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box cannot be forged or accessed through its storage field" {
    const sources = [_][]const u8{
        \\import std.memory.{Box}
        \\const fake = Box(int){}
        \\exit(42)
        ,
        \\import std.memory.{Box}
        \\fallible inspect() unit
        \\  const owner = Box.new(42)
        \\  _ = owner.allocation
        \\if inspect() -> exit(42) else exit(1)
    };
    for (sources) |source| {
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .opaque_struct_access);
    }
}

test "Box cannot be implicitly copied or used after transfer" {
    const sources = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\import std.memory.{Box}
        \\fallible copy_owner() unit
        \\  const owner = Box.new(42)
        \\  const copied = owner
        \\  _ = copied
        \\if copy_owner() -> exit(1) else exit(2)
        , .diagnostic = .type_not_copyable },
        .{ .source =
        \\import std.memory.{Box, value}
        \\fallible take_twice() unit
        \\  const owner = Box.new(42)
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

test "invalid external signatures release their return origins" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_box}
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  return borrow_box(int, owner)[]
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    const memory_module = try fixture.db.intern(queries.ModulePaths, .{ .path = "std.memory" });
    const declarations = (try fixture.db.get(queries.ModuleDeclarations, memory_module)).*.?;
    const resolved = (try fixture.db.get(queries.ResolveItem, declarations.resolveFunction("borrow_box").?)).*.?;
    const modified = try std.mem.replaceOwned(
        u8,
        testing.allocator,
        standard_library.source("memory/allocation.chi"),
        "pub extern func borrow_box(static T: type, imm owner: Box(T)) Ref(T, false)",
        "pub extern func borrow_box(static T: type, mut owner: Box(T)) Ref(T, false) from(owner)",
    );
    defer testing.allocator.free(modified);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, modified);
    try fixture.expectDiagnostic(resolved.file_id, .invalid_external_signature);
    try fixture.db.setInput(queries.SourceText, resolved.file_id, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(0, 42);
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

test "where conditions use inherited static namespace parameters" {
    const accepted = try Fixture.init(
        \\struct Box(T: type)
        \\  value: T
        \\  func get(imm self: Box(T)) T where T is int -> return self.value
        \\const box = Box(int){value = 42}
        \\exit(box.get())
    , &.{});
    defer accepted.deinit();
    try accepted.expectExit(0, 42);

    const rejected = try Fixture.init(
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

test "where clauses on static parameters accept inline and following lines" {
    const fixture = try Fixture.init(
        \\func bounded(static value: int) int where value > 0
        \\where value < 10
        \\  return value
        \\exit(bounded(5))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 5);
}

test "where clauses can repeat on one signature line" {
    const fixture = try Fixture.init(
        \\func bounded(static value: int) int where value > 0 where value < 10 -> value
        \\exit(bounded(5))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 5);
}

test "where clauses follow return origin contracts" {
    const fixture = try Fixture.init(
        \\import std.memory.{borrow_mut_box, read}
        \\func forward(static T: type, imm reference: Ref(T, true)) Ref(T, true) from(reference) where T is int -> reference
        \\fallible run() int
        \\  var owner = Box.new(42)
        \\  return read(int, true, forward(int, borrow_mut_box(int, owner)))
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "where clauses evaluate fallible calls at specialization" {
    const success = try Fixture.init(
        \\fallible positive(imm value: int) unit
        \\  value > 0
        \\func bounded(static value: int) int where positive(value) -> value
        \\exit(bounded(5))
    , &.{});
    defer success.deinit();
    try success.expectExit(0, 5);

    const failed = try Fixture.init(
        \\fallible positive(imm value: int) unit
        \\  value > 0
        \\func bounded(static value: int) int where positive(value) -> value
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
    const fixture = try Fixture.init(source, &.{});
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

test "where conditions reject runtime parameters even for fallible functions" {
    const fixture = try Fixture.init(
        \\fallible check(imm value: int) int where value > 0 -> value
        \\if check(5) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .comptime_runtime_capture);
}

test "where conditions on unused specializations stay deferred" {
    const fixture = try Fixture.init(
        \\func unused(static value: int) int where value < 0 -> value
        \\exit(42)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "where conditions recompute after module static edits" {
    const fixture = try Fixture.init(
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
    const fixture = try Fixture.init(
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
    const fixture = try Fixture.init(
        \\static Small = int | none
        \\func accept(static T: type) int where T is int | none -> 42
        \\exit(accept(Small))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "where conditions compare static type values" {
    const matching = try Fixture.init(
        \\func exact(static T: type) int where T == int -> 42
        \\exit(exact(int))
    , &.{});
    defer matching.deinit();
    try matching.expectExit(0, 42);

    const mismatched = try Fixture.init(
        \\func exact(static T: type) int where T == int -> 42
        \\exit(exact(bool))
    , &.{});
    defer mismatched.deinit();
    try mismatched.expectDiagnostic(0, .where_condition_failed);
}

test "where type tests reject members outside the inspected type" {
    const fixture = try Fixture.init(
        \\static Large = int | none
        \\func accept(static T: type) int where T is int -> 42
        \\exit(accept(Large))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .where_condition_failed);
}

test "where type tests short circuit disjunction" {
    const fixture = try Fixture.init(
        \\func accept(static T: type) int where T is int or 1 / 0 > 0 -> 42
        \\exit(accept(int))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "where type tests accept qualified module statics" {
    const fixture = try Fixture.init(
        \\import flags
        \\func accept() int where flags.answer is int -> 42
        \\exit(accept())
    , &.{.{ .path = "flags/answer.chi", .module_path = "flags", .source = "pub static answer = 42" }});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "where member type tests accept callables and reject absent members" {
    const callable = try Fixture.init(
        \\struct WithMember
        \\  func compute(imm value: int) int -> value
        \\func accept(static T: type) int where T.compute is func(int) int -> 42
        \\exit(accept(WithMember))
    , &.{});
    defer callable.deinit();
    try callable.expectExit(0, 42);

    const missing = try Fixture.init(
        \\struct WithoutMember
        \\  value: int
        \\func accept(static T: type) int where T.compute is func(int) int -> 42
        \\exit(accept(WithoutMember))
    , &.{});
    defer missing.deinit();
    try missing.expectDiagnostic(0, .where_condition_failed);
}

test "where member type tests inspect static struct fields" {
    const existing = try Fixture.init(
        \\struct Config
        \\  amount: int
        \\static config = Config{amount = 42}
        \\func accept() int where config.amount is int -> 42
        \\exit(accept())
    , &.{});
    defer existing.deinit();
    try existing.expectExit(0, 42);

    const missing = try Fixture.init(
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

fn checkCleanupEffectAllocations(gpa: std.mem.Allocator) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, gpa,
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> ()
        \\struct Guard
        \\  target: Ref(Item, true)
        \\  drop = func(deinit self: Guard)
        \\    self.target[] = Item{value = 42}
        \\func observe(imm previous: Item, marker: int) int -> previous.value
        \\func inspect(imm reference: Ref(Item, true)) int
        \\  return observe(reference[], if 1 == 1
        \\    const guard = Guard{target = reference}
        \\    0
        \\  else 0)
    , &.{}, &.{});
    const declarations = (try db.get(queries.BuildModuleScope, 0)).*.?;
    const inspect = declarations.resolve("inspect").?;
    try testing.expect((try db.get(queries.AnalyzeFunctionInstance, .{ .item = inspect })).* == null);
}

test "implicit drop effect analysis releases every failed allocation" {
    try testing.checkAllAllocationFailures(testing.allocator, checkCleanupEffectAllocations, .{});
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
