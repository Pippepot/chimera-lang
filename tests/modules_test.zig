const std = @import("std");
const standard_library = @import("standard_library");
const test_sources = @import("test_sources");
const query = test_sources.query;
const queries = test_sources.queries;
const structures = test_sources.structures;
const modules = test_sources.modules;
const runtime = test_sources.runtime;
const testing = std.testing;
var allocation_failure_backing: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;

const Fixture = struct {
    db: *query.Database,

    fn init(entry: []const u8, files: []const modules.SourceFile) !Fixture {
        const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
        errdefer db.deinit();
        try modules.registerSources(db, testing.allocator, entry, files, &.{});
        return .{ .db = db };
    }

    fn expectSourceExit(source: []const u8, status: u8) !void {
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, status);
    }

    fn expectSourceDiagnostic(source: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind)) !void {
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, kind);
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
        \\  if unsafe_initialize(int, allocation, 1, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(byte, bytes, 1, 7) -> ()
        \\  else
        \\    deallocate(byte, bytes^)
        \\    fail
        \\  const number = unsafe_take(byte, bytes, 1)
        \\  deallocate(byte, bytes^)
        \\  var pairs = allocate(Pair, 2)
        \\  if unsafe_initialize(Pair, pairs, 1, Pair{first = 42, second = number}) -> ()
        \\  else
        \\    deallocate(Pair, pairs^)
        \\    fail
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
        \\  if unsafe_initialize(Tracked, allocation, 1, Tracked{value = 42}) -> ()
        \\  else
        \\    deallocate(Tracked, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 1, 40) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(bool, allocation, 0, true) -> ()
        \\  else
        \\    deallocate(bool, allocation^)
        \\    fail
        \\  if unsafe_initialize(bool, allocation, 1, true) -> ()
        \\  else
        \\    unsafe_destroy(bool, allocation, 0)
        \\    deallocate(bool, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(Tracked, allocation, 0, Tracked{value = 42}) -> ()
        \\  else
        \\    deallocate(Tracked, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 0, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 1, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(Tracked, allocation, 1, Tracked{value = 42}) -> ()
        \\  else
        \\    deallocate(Tracked, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 0, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(Empty, allocation, 1, Empty{}) -> ()
        \\  else
        \\    deallocate(Empty, allocation^)
        \\    fail
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

test "Box pointee copying uses distinct storage and consuming extraction" {
    const fixture = try Fixture.init(
        \\fallible run() int
        \\  const original = Box.new(21)
        \\  var duplicate = Box.new(original.borrow()[])
        \\  duplicate.borrow_mut()[] = 42
        \\  return original.borrow()[] + duplicate^.into_value() - 21
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new preserves in-place copying of immovable values" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\fallible run() int
        \\  const original = Box(CopyOnly).new(CopyOnly{value = 41})
        \\  const copy = Box.new(original.borrow()[])
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
        \\  if storage.unsafe_init(0, 42) -> ()
        \\  else
        \\    storage^.release()
        \\    fail
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
        \\  if unsafe_initialize(Ref(int, false), slots, 0, owner.borrow()) -> ()
        \\  else
        \\    deallocate(Ref(int, false), slots^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 0, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 0, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 0, 42) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(Callback, allocation, 0, answer) -> ()
        \\  else
        \\    deallocate(Callback, allocation^)
        \\    fail
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
        \\  if unsafe_initialize(int, allocation, 0, 41) -> ()
        \\  else
        \\    deallocate(int, allocation^)
        \\    fail
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

test "Box destination construction covers nested producers and loop results" {
    for ([_][]const u8{
        "Item{leaf = producer(42)}",
        "make(42)",
        "loop\n    if flag == 1 -> break make(42)\n    break Item{leaf = producer(1)}\n  ",
    }) |initializer| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Leaf
            \\  move = none
            \\  value: int
            \\struct Item
            \\  move = none
            \\  leaf: Leaf
            \\func leaf(value: int) Leaf -> Leaf{{value = value}}
            \\func make(value: int) Item -> Item{{leaf = leaf(value)}}
            \\fallible run(flag: int) int
            \\  const producer = leaf
            \\  const owner = Box(Item).new({s})
            \\  return owner.borrow()[].leaf.value
            \\if const result = run(1) -> exit(result) else exit(1)
        , .{initializer});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    }
}

test "Box destination construction copies immovable places and moves once" {
    const cases = [_]struct { movement: []const u8, copy: []const u8, initializer: []const u8 }{
        .{ .movement = "none", .copy = "func(imm self: Item) Item -> Item{value = self.value + 1}", .initializer = "original" },
        .{ .movement = "func(deinit self: Item) Item -> Item{value = self.value + 1}", .copy = "none", .initializer = "original^" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Item
            \\  move = {s}
            \\  copy = {s}
            \\  value: int
            \\fallible run() int
            \\  const original = Item{{value = 41}}
            \\  const owner = Box.new({s})
            \\  return owner.borrow()[].value
            \\if const result = run() -> exit(result) else exit(1)
        , .{ case.movement, case.copy, case.initializer });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    }
}

test "Box destination construction widens fresh immovable variants" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  move = none
        \\  value: int
        \\func make() Item -> Item{value = 42}
        \\static MaybeItem = Item | none
        \\fallible run(flag: int) int
        \\  const producer = make
        \\  const owner = Box(MaybeItem).new(if flag == 1 -> producer() else none)
        \\  if owner.borrow()[] is Item -> return 41
        \\  return 1
        \\fallible answer() int -> run(1) + run(0)
        \\if const result = answer() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "unevaluated initializer inference preserves lookup diagnostics" {
    const cases = [_]struct { expression: []const u8, kind: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .expression = "unknown()", .kind = .unknown_function },
        .{ .expression = "callback()", .kind = .value_not_callable },
        .{ .expression = "item.missing()", .kind = .unknown_namespace_member },
        .{ .expression = "number.missing()", .kind = .field_access_not_struct },
        .{ .expression = "item.value()", .kind = .value_not_callable },
        .{ .expression = "item.bad()", .kind = .value_not_callable },
        .{ .expression = "item.copy()", .kind = .unknown_namespace_member },
        .{ .expression = "item.missing", .kind = .unknown_field },
        .{ .expression = "number.value", .kind = .field_access_not_struct },
        .{ .expression = "number[]", .kind = .dereference_requires_ref },
    };
    for (cases) |case| for ([_][]const u8{ "Box.new", "Box(int).new" }) |constructor| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Item
            \\  value: int
            \\static Item.bad = 42
            \\const item = Item{{value = 42}}
            \\const number = 42
            \\const callback = 42
            \\if {s}({s}) -> exit(1) else exit(2)
        , .{ constructor, case.expression });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.kind);
    };
}

test "unevaluated result inference preserves divergence before lookup" {
    for ([_][]const u8{ "stop().field", "stop().method()", "stop()[]", "stop()()" }) |expression| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\func stop() never -> exit(42)
            \\const selected = if 1 == 1 -> {s} else Pinned{{value = 1}}
            \\_ = selected
            \\exit(1)
        , .{expression});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
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
        const source = try std.fmt.allocPrint(testing.allocator,
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
            \\fallible run() int
            \\  const factory = Factory{{create = make}}
            \\  const original = Item{{value = 42}}
            \\  const owner = Box.new({s})
            \\  return owner.borrow()[].value
            \\if const result = run() -> exit(result) else exit(1)
        , .{initializer});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
        const forbidden_producer = try std.mem.replaceOwned(u8, testing.allocator, source, "func make(value: int) Item -> Item{value = value}", "func make(value: int) Item -> exit(90)");
        defer testing.allocator.free(forbidden_producer);
        const forbidden_copy = try std.mem.replaceOwned(u8, testing.allocator, forbidden_producer, "copy = func(imm self: Item) Item -> Item{value = self.value}", "copy = func(imm self: Item) Item -> exit(91)");
        defer testing.allocator.free(forbidden_copy);
        const forbidden_receiver = try std.mem.replaceOwned(u8, testing.allocator, forbidden_copy, "func make_factory() Factory -> Factory{create = make}", "func make_factory() Factory -> exit(92)");
        defer testing.allocator.free(forbidden_receiver);
        try fixture.db.setInput(queries.SourceText, 0, forbidden_receiver);
        try replaceAllocationSource(fixture, "        var storage = allocate(T, 1)", "        exit(43)\n        var storage = allocate(T, 1)");
        try fixture.expectExit(0, 43);
    }
}

fn replaceAllocationSource(fixture: Fixture, original: []const u8, replacement: []const u8) !void {
    const file = (try fixture.db.input(queries.StandardFile, @intFromEnum(standard_library.File.memory_allocation))).*;
    const source = (try fixture.db.input(queries.SourceText, file)).*;
    try testing.expect(std.mem.indexOf(u8, source, original) != null);
    const edited = try std.mem.replaceOwned(u8, testing.allocator, source, original, replacement);
    defer testing.allocator.free(edited);
    const with_exit = try std.fmt.allocPrint(testing.allocator, "import std.exit.{{exit}}\n\n{s}", .{edited});
    defer testing.allocator.free(with_exit);
    try fixture.db.setInput(queries.SourceText, file, with_exit);
}

test "Box obtains storage before producer arguments conditions and ownership hooks" {
    for ([_][]const u8{
        "Box.new(make(forbidden()))",
        "Box.new(if forbidden() == 1 -> make(42) else make(1))",
        "Box(Item).new(original)",
        "Box(Item).new(original^)",
        "Box.new(Box.new(make(forbidden())))",
    }) |call| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Item
            \\  value: int
            \\  copy = func(imm self: Item) Item -> exit(90)
            \\  move = func(deinit self: Item) Item -> exit(91)
            \\func forbidden() int -> exit(92)
            \\func make(value: int) Item -> Item{{value = value}}
            \\const original = Item{{value = 41}}
            \\if {s} -> exit(1) else exit(2)
        , .{call});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try replaceAllocationSource(fixture, "        var storage = allocate(T, 1)", "        exit(42)\n        var storage = allocate(T, 1)");
        try fixture.expectExit(0, 42);
    }
}

test "init consumption requires declared failure even for literal arguments" {
    const fixture = try Fixture.init(
        \\func materialize(init item: int) int -> item
        \\exit(materialize(42))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .fallible_expression_outside_fallible_function);
}

test "allocating init consumers preserve Box ordering through aliases and indirect calls" {
    const cases = .{
        .{ .setup = "", .call = "Box.new(make(forbidden()))" },
        .{ .setup = "static Owner = Box(Item)\nstatic create = Owner.new", .call = "create(make(forbidden()))" },
        .{ .setup = "const create: fallible(init Item) Box(Item) = Box(Item).new", .call = "create(make(forbidden()))" },
        .{ .setup = "fallible invoke(imm create: fallible(init Item) Box(Item), init item: Item) Box(Item) -> create(item)", .call = "invoke(Box(Item).new, make(forbidden()))" },
    };
    inline for (cases) |case| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Item
            \\  move = none
            \\  value: int
            \\func forbidden() int -> exit(90)
            \\func make(value: int) Item -> Item{{value = value}}
            \\{s}
            \\if {s} -> exit(1) else exit(42)
        , .{ case.setup, case.call });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try replaceAllocationSource(fixture, "var storage = allocate(T, 1)", "var storage = allocate(T, -1)");
        try fixture.expectExit(0, 42);
    }
}

test "allocating init consumers construct immovable raw slots through aliases and callable values" {
    const cases = .{
        .{ .setup = "", .call = "unsafe_initialize(Item, storage, 1, make(41))" },
        .{ .setup = "", .call = "initialize_alias(storage, 1, make(41))" },
        .{ .setup = "const initialize: fallible(mut Allocation(Item), int, init Item) unit = Allocation(Item).unsafe_init", .call = "initialize(storage, 1, make(41))" },
        .{ .setup = "", .call = "storage.unsafe_init(1, make(41))" },
    };
    inline for (cases) |case| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\import std.memory.{{Allocation, allocate, deallocate, unsafe_initialize, unsafe_destroy, unsafe_borrow_initialized}}
            \\struct Item
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Item) -> exit(self.value)
            \\func make(value: int) Item -> Item{{value = value + 1}}
            \\static Slots = Allocation(Item)
            \\static initialize_alias = Slots.unsafe_init
            \\fallible run()
            \\  var storage = allocate(Item, 2)
            \\  {s}
            \\  if {s} -> ()
            \\  else
            \\    deallocate(Item, storage)
            \\    fail
            \\  const value = unsafe_borrow_initialized(Item, storage, 1).value
            \\  if value == 42
            \\    unsafe_destroy(Item, storage, 1)
            \\  else
            \\    unsafe_destroy(Item, storage, 1)
            \\    deallocate(Item, storage)
            \\    exit(91)
            \\  deallocate(Item, storage)
            \\if run() -> exit(92) else exit(93)
        , .{ case.setup, case.call });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, 42);
    }
}

test "allocating init consumers clean raw slot partial fields before receiving frames" {
    try Fixture.expectSourceExit(
        \\import std.memory.{allocate, deallocate, unsafe_initialize}
        \\struct Leaf
        \\  move = none
        \\  drop = func(deinit self: Leaf) -> exit(42)
        \\struct Item
        \\  move = none
        \\  first: Leaf
        \\  second: int
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\fallible run()
        \\  var storage = allocate(Item, 1)
        \\  if unsafe_initialize(Item, storage, 0, Item{first = Leaf{}, second = fail_value()})
        \\    deallocate(Item, storage)
        \\    exit(90)
        \\  deallocate(Item, storage)
        \\  exit(91)
        \\if run() -> exit(92) else exit(93)
    , 42);
}

test "Box allocation failure skips initialization and preserves its source" {
    const fixture = try Fixture.init(
        \\func forbidden() int -> exit(90)
        \\func make(value: int) int -> value
        \\struct Item
        \\  value: int
        \\  move = func(deinit self: Item) Item -> exit(91)
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\func run() int
        \\  const original = Item{value = 42}
        \\  if Box.new(make(forbidden())) -> return 1
        \\  if Box.new(original^) -> return 2
        \\  return 92
        \\exit(run())
    , &.{});
    defer fixture.deinit();
    try replaceAllocationSource(fixture, "var storage = allocate(T, 1)", "var storage = allocate(T, -1)");
    try fixture.expectExit(0, 42);
}

test "Box destination construction recomputes after copy capability and allocator edits" {
    const source =
        \\struct Item
        \\  move = none
        \\  value: int
        \\  copy = func(imm self: Item) Item -> Item{value = self.value + 1}
        \\fallible run() int
        \\  const original = Item{value = 41}
        \\  const owner = Box.new(original)
        \\  return owner.borrow()[].value
        \\if const result = run() -> exit(result) else exit(43)
    ;
    const fixture = try Fixture.init(source, &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    const without_copy = try std.mem.replaceOwned(u8, testing.allocator, source, "copy = func(imm self: Item) Item -> Item{value = self.value + 1}", "copy = none");
    defer testing.allocator.free(without_copy);
    try fixture.db.setInput(queries.SourceText, 0, without_copy);
    try fixture.expectDiagnostic(0, .type_not_copyable);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectExit(0, 42);
    try replaceAllocationSource(fixture, "var storage = allocate(T, 1)", "var storage = allocate(T, -1)");
    try fixture.expectExit(0, 43);
    const file = (try fixture.db.input(queries.StandardFile, @intFromEnum(standard_library.File.memory_allocation))).*;
    try fixture.db.setInput(queries.SourceText, file, standard_library.source("memory/allocation.chi"));
    try fixture.expectExit(0, 42);
}

test "Box initializer failure cleans partial fields before releasing storage" {
    const fixture = try Fixture.init(
        \\struct Leaf
        \\  move = none
        \\  value: int
        \\  drop = func(deinit self: Leaf) -> exit(self.value)
        \\struct Item
        \\  move = none
        \\  leaf: Leaf
        \\  marker: int
        \\  drop = func(deinit self: Item) -> exit(91)
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\if Box.new(Item{leaf = Leaf{value = 42}, marker = fail_value()}) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try replaceAllocationSource(fixture, "            deallocate(T, storage)", "            deallocate(T, storage)\n            exit(90)");
    try fixture.expectExit(0, 42);
}

test "Box releases uninitialized raw storage on initializer failure" {
    const initializers = [_][]const u8{
        "if 1 == 1\n      fail_value()\n      Item{}\n    else Item{}",
        "if 1 == 1\n      fail\n    else Item{}",
    };
    for (initializers) |initializer| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Item
            \\  move = none
            \\  drop = func(deinit self: Item) -> exit(90)
            \\fallible fail_value() int
            \\  1 == 0
            \\  return 0
            \\func run() int
            \\  return loop
            \\    if Box(Item).new({s}) -> break 1
            \\    break 2
            \\exit(run())
        , .{initializer});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try replaceAllocationSource(fixture, "            deallocate(T, storage)", "            deallocate(T, storage)\n            exit(42)");
        try fixture.expectExit(0, 42);
    }
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

test "ownership members expose primitive copy and move as callable values" {
    const fixture = try Fixture.init(
        \\const duplicate = int.copy
        \\const transfer = int.move
        \\const value = duplicate(42)
        \\exit(transfer(value))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members select custom hooks once for calls and aliases" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members compose fieldwise variants and generated types" {
    const fixture = try Fixture.init(
        \\struct Cell(T: type)
        \\  copy = fieldwise
        \\  value: T
        \\static IntCell = Cell(int)
        \\static Maybe = IntCell | none
        \\const original: Maybe = IntCell{value = 42}
        \\const copied = Maybe.copy(original)
        \\const moved = copied.move()
        \\if const cell = moved as IntCell -> exit(cell.value) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members preserve consuming access diagnostics" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  copy = trivial
        \\  value: int
        \\func invalid(imm item: Item) Item -> item.move()
        \\const result = invalid(Item{value = 42})
        \\exit(result.value)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .ownership_transfer_requires_owned_place);
}

test "ownership members copy immovable values independently of move support" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\const source = Item{value = 42}
        \\const copied = Item.copy(source)
        \\exit(copied.value)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members expose callable copy and move" {
    const fixture = try Fixture.init(
        \\static Callback: type = func(int) int
        \\func increment(value: int) int -> value + 1
        \\const original = Callback.copy(increment)
        \\const transferred = original.move()
        \\exit(transferred(41))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members participate in where type tests" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\func copyable(static T: type) int where T.copy is func(imm T) T -> 20
        \\func movable(static T: type) int where T.move is func(deinit T) T -> 22
        \\exit(copyable(CopyOnly) + movable(int))
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members with missing capabilities fail where conditions" {
    for ([_][]const u8{ "copy", "move" }) |name| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Item
            \\  copy = none
            \\  move = none
            \\  value: int
            \\func accept(static T: type) int where T.{s} is func({s} T) T -> 42
            \\exit(accept(Item))
        , .{ name, if (std.mem.eql(u8, name, "copy")) "imm" else "deinit" });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .where_condition_failed);
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .reserved_ownership_member);
    }
}

test "ownership members execute selected operations at compile time" {
    const fixture = try Fixture.init(
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
        \\  if const cell = moved as IntCell -> cell.value else 1
        \\exit(result)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "ownership members preserve reference origins" {
    for ([_][]const u8{ "copy", "move" }) |name| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\fallible run() int
            \\  const owner = Box.new(42)
            \\  const original = owner.borrow()
            \\  const callback = Ref(int, false).{s}
            \\  const handle = callback(original)
            \\  return handle[]
            \\if const result = run() -> exit(result) else exit(1)
        , .{name});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
        const invalid = try std.mem.replaceOwned(u8, testing.allocator, source, "return handle[]", "const consumed = owner^\n  return handle[]");
        defer testing.allocator.free(invalid);
        try fixture.db.setInput(queries.SourceText, 0, invalid);
        try fixture.expectDiagnostic(0, .use_after_transfer);
    }
}

test "ownership members validate definitions before where availability" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  copy = func(imm self: int) int -> self
        \\  value: int
        \\func accept(static T: type) int where T.copy is func(imm T) T -> 42
        \\exit(accept(Item))
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .struct_ownership_hook_signature_mismatch);
}

test "ownership members invalidate retained callables after capability edits" {
    const original =
        \\pub struct Item
        \\  copy = trivial
        \\  value: int
    ;
    const fixture = try Fixture.init(
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
        \\  value: int
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
        \\  value: int
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
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
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
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    };
}

test "fresh consuming selections retain static type inference" {
    for ([_][]const u8{
        "if flag == 1 -> 41 else none",
        "if flag == 1 -> producer(41) else none",
        "loop\n    if flag == 1 -> break producer(41)\n    break none\n  ",
    }) |expression| {
        const source = try std.fmt.allocPrint(testing.allocator,
            \\func make(value: int) int -> value
            \\func consume(static T: type, deinit item: T) int
            \\  if const value = item as int -> return value
            \\  return 1
            \\func run(flag: int) int
            \\  const producer = make
            \\  return consume({s})
            \\static compiled = comptime -> run(1) + run(0)
            \\exit(run(1) + run(0) + compiled - 42)
        , .{expression});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
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
        \\func run(flag: int) int
        \\  const item = make(41)
        \\  borrow alias = item
        \\  return consume(if flag == 1 -> alias else make(1), 0)
        \\exit(run(1))
        , .kind = .ownership_transfer_requires_owned_place },
        .{ .body =
        \\func run(imm item: Item, flag: int) int
        \\  return consume(if flag == 1 -> item else make(1), 0)
        \\exit(run(make(41), 1))
        , .kind = .ownership_transfer_requires_owned_place },
        .{ .body =
        \\fallible run() int
        \\  const owner = Box.new(make(42))
        \\  return consume(owner.borrow()[], 0)
        \\if const result = run() -> exit(result) else exit(1)
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, case.kind);
    }
}

test "zero-sized consuming selections keep addressable storage" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  move = fieldwise
        \\func consume(deinit item: Item) int -> 42
        \\func run(flag: int) int
        \\  const first = Item{}
        \\  const second = Item{}
        \\  return consume(if flag == 1 -> first else second)
        \\static compiled = comptime -> run(1) + run(0)
        \\exit(run(1) + run(0) + compiled - 126)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "consuming selection cleanup distinguishes successful calls from later failure" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  move = none
        \\  value: int
        \\  counter: Ref(int, true)
        \\  drop = func(deinit self: Item)
        \\    self.counter[] = self.counter[] + self.value
        \\func consume(deinit item: Item, marker: int) -> ()
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\fallible prepare(imm counter: Ref(int, true), named: int, fails: int) unit
        \\  const item = Item{value = 20, counter = counter}
        \\  if fails == 1
        \\    consume(if named == 1 -> item else Item{value = 22, counter = counter}, fail_value())
        \\  else
        \\    consume(if named == 1 -> item else Item{value = 22, counter = counter}, 0)
        \\fallible probe(named: int, fails: int) int
        \\  var counter = Box.new(0)
        \\  if prepare(counter.borrow_mut(), named, fails) -> ()
        \\  return counter.borrow()[]
        \\fallible run() int -> probe(1, 0) + probe(0, 0) + probe(1, 1) + probe(0, 1) - 40
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
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
    const fixture = try Fixture.init("", &.{});
    defer fixture.deinit();
    for ([_][]const u8{ "fieldwise", "none", "func(deinit self: Item) Item -> exit(90)", "fieldwise" }) |movement| {
        const edited = try test_sources.renderTemplate(testing.allocator, source, .{ .move = movement });
        defer testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        try fixture.expectExit(0, 42);
    }
}

test "consuming selections preserve contained reference origins" {
    const fixture = try Fixture.init(
        \\struct Item
        \\  move = none
        \\  handle: Ref(int, false)
        \\func take(deinit item: Item) Ref(int, false) from(item) -> item.handle
        \\fallible run(flag: int) int
        \\  const first_owner = Box.new(20)
        \\  const second_owner = Box.new(22)
        \\  const first = Item{handle = first_owner.borrow()}
        \\  const second = Item{handle = second_owner.borrow()}
        \\  const handle = take(if flag == 1 -> first else second)
        \\  return handle[]
        \\fallible answer() int -> run(1) + run(0)
        \\if const result = answer() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const rejected = try Fixture.init(
        \\import std.memory.{borrow_local}
        \\struct Item
        \\  move = none
        \\  value: int
        \\func invalid(deinit item: Item) Ref(Item, false) from(item) -> borrow_local(Item, item)
        \\const handle = invalid(Item{value = 42})
        \\exit(handle[].value)
    , &.{});
    defer rejected.deinit();
    try rejected.expectDiagnostic(0, .borrow_outlives_source);
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

test "pending deinit arguments retain their storage during argument evaluation" {
    const cases = [_]struct { call: []const u8, source: []const u8, replacement: []const u8 }{
        .{ .call = "take", .source = "item", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "take", .source = "item^", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "callee", .source = "item", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "generic", .source = "item", .replacement = "item = Pinned{value = 7}" },
        .{ .call = "take", .source = "holder.item", .replacement = "holder.item = Pinned{value = 7}" },
        .{ .call = "take", .source = "holder.item", .replacement = "holder = Holder{item = Pinned{value = 7}, count = 0}" },
        .{ .call = "take_int", .source = "holder.count", .replacement = "holder.count = 7" },
        .{ .call = "take", .source = "item", .replacement = "take_int(holder.count, if 1 == 1\n      item = Pinned{value = 7}\n      0\n    else 0)" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .consumed_storage_in_use);
    }
}

test "pending deinit arguments permit sibling writes and release storage after calls" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
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
    const fixture = try Fixture.init(source, &.{});
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
    const fixture = try Fixture.init(
        \\struct Item
        \\  value: int
        \\  drop = func(deinit self: Item) -> exit(self.value)
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\func take(deinit item: Item, value: int) -> ()
        \\fallible run() unit
        \\  const item = Item{value = 42}
        \\  take(item, fail_value())
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
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\fallible forward(deinit item: Item) unit
        \\  take(item, fail_value())
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
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\fallible run() unit
        \\  take(Item{value = 42}, fail_value())
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
        \\fallible fail_value() int
        \\  1 == 0
        \\  return 0
        \\fallible run() unit
        \\  const item = Item{}
        \\  take(item, fail_value())
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

fn expectNoRelocation(fixture: Fixture, name: []const u8) !void {
    const types: queries.TypeFacts(*query.Database) = .{ .ctx = fixture.db };
    const function = (try fixture.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction(name).?;
    const body = (try fixture.db.get(queries.AnalyzeFunctionInstance, .{ .item = function })).*.?;
    for (body.instructions) |instruction| {
        const copied: ?structures.TypeId = switch (instruction) {
            .struct_init => |operation| operation.type_id,
            .field_access => |operation| operation.field_type,
            .field_update => |operation| operation.type_id,
            .variant_extract => |operation| operation.target_type,
            .variant_coerce, .callable_coerce => |operation| if (operation.destination == null) operation.target_type else null,
            .value_copy => |operation| if (operation.destination == null) operation.type_id else null,
            .call_mut_argument => |operation| if (operation.destination == null) operation.type_id else null,
            else => null,
        };
        if (copied) |type_id| try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(type_id));
    }
    for (body.branch_arguments) |use| if (use.coerce_to) |type_id| try testing.expectEqual(structures.ArgumentPassing.direct, try types.argumentPassing(type_id));
    if (try types.argumentPassing(body.return_type) == .direct) return;
    for (body.blocks) |block| if (block.terminator == .return_value) {
        const returned = block.terminator.return_value;
        try testing.expect(returned.coerce_to == null);
        try testing.expect(@intFromEnum(returned.value) >= body.block_arguments.len);
        try testing.expect(body.instructions[@intFromEnum(returned.value) - body.block_arguments.len] == .result_storage);
    };
}

test "fresh results construct in their final destinations" {
    const fixture = try Fixture.init(
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
    const fixture = try Fixture.init(
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
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
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
        .{ .body = "var index = 0\nconst pinned = loop\n  index += 1\n  if index == 1 -> break none\n  break make(index)\nexit(1)", .kind = .relocation_requires_direct_move },
        .{ .body = "const pinned: Pinned = if 1 < 2 -> Pinned{value = 42} else Pinned{value = 1}\nexit(pinned.value)", .kind = null },
        .{ .body = "if 1 < 2\n  Pinned{value = 1}\nexit(42)", .kind = null },
        .{ .body = "func look(imm value: Pinned | none) int -> 42\nconst pinned = Pinned{value = 1}\nexit(look(pinned))", .kind = .relocation_requires_direct_move },
        .{ .body = "func look(imm value: Pinned | none) int\n  if value is Pinned -> return 42\n  return 1\nexit(look(make(1)) + look(Pinned{value = 1}) - 42)", .kind = null },
        .{ .body = "func keep(var value: Pinned | none) int\n  if value is Pinned -> return 42\n  return 1\nexit(keep(Pinned{value = 1}))", .kind = null },
        .{ .body = "func maybe() Pinned | none -> Pinned{value = 1}\nfunc widen() Pinned | none | int -> maybe()\nconst widened = widen()\nexit(42)", .kind = .relocation_requires_direct_move },
        .{ .body = "func look(imm value: Pinned | none) int\n  if value is Pinned -> return 1\n  return 42\nexit(look(none))", .kind = null },
        .{ .body = "func keep(static T: type, var t: T, var value: Pinned | none) int\n  if value is Pinned -> return 1\n  return t\nexit(keep(42, none))", .kind = null },
        .{ .body = "func keep(static T: type, var t: T, var value: Pinned | none) int -> 42\nexit(keep(5, make(1)))", .kind = .relocation_requires_direct_move },
        .{ .body = "func consume(static T: type, var t: T, deinit value: T | int) int\n  if const number = value as int -> return number\n  return 1\nexit(consume(Pinned{value = 1}, 42))", .kind = null },
    };
    for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ "struct Pinned\n  move = none\n  value: int\nfunc make(value: int) Pinned -> Pinned{value = value}\n", case.body });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
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
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
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
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\func look(imm item: Pinned | none) int -> 42
            \\const pinned = Pinned{{value = 42}}
            \\exit(look({s}))
        , .{expression});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectDiagnostic(0, .relocation_requires_direct_move);
    }
}

test "borrowed argument widening preserves transfer rejection and owner cleanup" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);

    const rejected = try Fixture.init(
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
        const source = try std.fmt.allocPrint(testing.allocator,
            \\struct Pinned
            \\  move = none
            \\  value: int
            \\  drop = func(deinit self: Pinned) -> exit(self.value)
            \\func make() Pinned -> Pinned{{value = 42}}
            \\func look(imm item: Pinned | none, marker: int) -> ()
            \\fallible fail_value() int
            \\  1 == 0
            \\  return 0
            \\fallible run(flag: int) unit
            \\  look(if flag == 1 -> make() else none, fail_value())
            \\if run({d}) -> exit(1) else exit(2)
        , .{flag});
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, if (flag == 1) 42 else 2);
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
    const fixture = try Fixture.init("", &.{});
    defer fixture.deinit();
    for (cases) |case| {
        const edited = try test_sources.renderTemplate(testing.allocator, source, .{ .move = case.movement, .result = case.result });
        defer testing.allocator.free(edited);
        try fixture.db.setInput(queries.SourceText, 0, edited);
        if (case.rejects_relocation) try fixture.expectDiagnostic(0, .relocation_requires_direct_move) else try fixture.expectExit(0, 42);
    }
}

test "borrowed conditional arguments view their source storage" {
    const fixture = try Fixture.init(
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
    const fixture = try Fixture.init(
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

test "replacing storage in place ends the old value before the right-hand side" {
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
        const fixture = try Fixture.init(source, &.{});
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, case.status);
    }
}

test "mutable parameters replaced in loops end each earlier value once" {
    for ([_][]const u8{ "move = none", "copy = none" }) |movement| {
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    }
}

test "a right-hand side that leaves early leaves the replaced place ended once" {
    const cases = [_]struct { body: []const u8, kind: ?std.meta.Tag(structures.Diagnostic.Kind) = null, status: u8 = 0 }{
        .{ .body = "func run(c: int) int\n  var pair = Pair{first = make(1), count = 7}\n  pair.first = if c == 1 -> make(2) else return pair.count\n  return pair.first.value\nexit(run(1) * 10 + run(0))", .status = 27 },
        .{ .body = "func run(c: int) int\n  var tracked = make(1)\n  tracked = if c == 1 -> make(2) else return 7\n  return tracked.value\nexit(run(1) * 10 + run(0))", .status = 27 },
        .{ .body = "fallible run(c: int) int\n  var pair = Pair{first = make(1), count = 3}\n  pair.first = checked(c)\n  return pair.first.value\nif const result = run(0) -> exit(result) else exit(3)", .status = 3 },
        .{ .body = "func run(c: int) int\n  var pair = Pair{first = make(1), count = 3}\n  var index = 0\n  loop\n    index += 1\n    pair.first = if index == c -> break else make(index + 1)\n    if index == 5 -> break\n  return pair.count\nexit(run(1))", .status = 3 },
        .{ .body = "func reset(mut tracked: Tracked, c: int)\n  tracked = if c == 1 -> make(2) else return\nvar tracked = make(1)\nreset(tracked, 0)\nexit(1)", .kind = .replaced_value_used },
        .{ .body = "func reset(mut tracked: Tracked, c: int)\n  var index = 0\n  loop\n    index += 1\n    tracked = if index == c -> break else make(index)\n    if index == 3 -> break\nvar tracked = make(1)\nreset(tracked, 1)\nexit(1)", .kind = .possibly_transferred },
        .{ .body = "func run(c: int) int\n  var tracked = make(1)\n  var index = 0\n  loop\n    index += 1\n    tracked = if index == c -> break else make(index)\n    if index == 5 -> break\n  return tracked.value\nexit(run(1))", .kind = .possibly_transferred },
        .{ .body = "func run() int\n  var pair = Pair{first = make(20), count = 1}\n  borrow first = pair.first\n  pair.first = make(first.value + 22)\n  return pair.first.value\nexit(run())", .kind = .borrow_outlives_source },
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
            \\fallible checked(value: int) Tracked
            \\  value > 0
            \\  return Tracked{value = value}
            \\
            ,
            case.body,
        });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        if (case.kind) |kind| try fixture.expectDiagnostic(0, kind) else try fixture.expectExit(0, case.status);
    }
}

test "joins place copies of existing values without early cleanup" {
    const fixture = try Fixture.init(
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
        \\static compiled = comptime -> total()
        \\exit(total() + compiled - 188)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "variant copies and transfers construct member by member" {
    const fixture = try Fixture.init(
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
        \\  if const counted = copied as Counted -> total += counted.value
        \\  if const counted = moved as Counted -> total += counted.value
        \\  return total
        \\func narrow() int
        \\  const wide: Counted | Pinned | none = Pinned{value = 20}
        \\  if const narrowed = wide as Counted | Pinned
        \\    if const pinned = narrowed as Pinned -> return pinned.value
        \\  return 0
        \\exit(widen() + narrow())
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 33);
    try expectNoRelocation(fixture, "widen");
    try expectNoRelocation(fixture, "narrow");
}

test "variant storage changes its immovable member during compile-time execution" {
    const fixture = try Fixture.init(
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
        \\  if const first = item as First -> total += first.value
        \\  item = Second{value = 30}
        \\  if const second = item as Second -> total += second.value
        \\  item = First{value = 10}
        \\  if const first = item as First -> total += first.value
        \\  return total
        \\static compiled = comptime -> run()
        \\exit(run() + compiled - 42)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "inferred factories construct fields from their static types in order" {
    const fixture = try Fixture.init(
        \\struct Pinned
        \\  move = none
        \\  value: int
        \\struct Holder(T: type)
        \\  item: T
        \\  count: int
        \\fallible step(mut order: int, expected: int) int
        \\  order == expected
        \\  order += 1
        \\  return order
        \\fallible make(mut order: int, expected: int) Pinned -> Pinned{value = step(order, expected)}
        \\fallible run() int
        \\  var order = 0
        \\  const holder = Holder{item = make(order, 0), count = step(order, 1)}
        \\  return holder.item.value + holder.count + 39
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
    try expectNoRelocation(fixture, "run");
}

test "fields end in place when a join transfers them on another path" {
    const cases = [_][]const u8{ "move = func(deinit self: Item) Item -> exit(90)", "move = none" };
    for (cases) |movement| {
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    }
}

test "borrowed standard results copy into a destination" {
    const fixture = try Fixture.init(
        \\import std.memory.{read}
        \\struct Pinned
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\fallible run() int
        \\  const owner = Box(Pinned).new(Pinned{value = 42})
        \\  const copied: Pinned = read(Pinned, false, owner.borrow())
        \\  return copied.value
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "compile-time field reads skip unfinished sibling construction" {
    const fixture = try Fixture.init(
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
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "compile-time joins preserve storage identity before later writes" {
    const selections = [_][]const u8{
        "if 1 == 1 -> item else other",
        "(loop\n    if 1 == 1 -> break item\n    break other\n  )",
    };
    for (selections) |selection| {
        const source = try std.fmt.allocPrint(testing.allocator,
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
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    }
}

test "compile-time execution updates storage in place" {
    const fixture = try Fixture.init(
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
        \\  if const a = either as A -> total += a.value
        \\  either = B{value = 40}
        \\  if const b = either as B -> total += b.value
        \\  return total + 1
        \\static result = comptime -> run() + switch_member()
        \\exit(result + run() + switch_member() - 126)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "in-place construction failure cleans completed results" {
    const cases = [_][]const u8{
        \\fallible build(value: int) Pair -> Pair{first = Tracked{value = 42}, second = checked(value)}
        \\if build(0) -> exit(1) else exit(2)
        ,
        \\fallible run() int
        \\  const tracked = checked(42)
        \\  return 1
        \\if const result = run() -> exit(result) else exit(2)
        ,
        \\fallible run() int
        \\  if const tracked = checked(42) -> return 1
        \\  return 2
        \\if const result = run() -> exit(result) else exit(3)
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
            \\fallible checked(value: int) Tracked
            \\  value > 0
            \\  return Tracked{value = value}
            \\
            ,
            body,
        });
        defer testing.allocator.free(source);
        const fixture = try Fixture.init(source, &.{});
        defer fixture.deinit();
        try fixture.expectExit(0, 42);
    }
}

test "compile-time execution constructs results in their destinations" {
    const fixture = try Fixture.init(
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

test "Box allocation failure skips fresh producer arguments" {
    const fixture = try Fixture.init(
        \\struct Tracked
        \\  value: int
        \\  drop = func(deinit self: Tracked) -> exit(90)
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\func make(deinit item: Tracked) Immovable -> Immovable{value = item.value}
        \\func forbidden() int -> exit(91)
        \\fallible run() unit
        \\  const owner = Box.new(make(Tracked{value = forbidden()}))
        \\  _ = owner
        \\if run() -> exit(1) else exit(42)
    , &.{});
    defer fixture.deinit();
    try replaceAllocationSource(fixture, "var storage = allocate(T, 1)", "var storage = allocate(T, -1)");
    try fixture.expectExit(0, 42);
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
}

test "conditional Box construction works in an if condition" {
    const fixture = try Fixture.init(
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\if Box.new(if 1 == 1 -> Immovable{value = 42} else Immovable{value = 0}) -> exit(42) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
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
        \\fallible fail_value() int
        \\  const storage = allocate(int, -1)
        \\  deallocate(int, storage^)
        \\  return 1
        \\fallible run() unit
        \\  const owner = Box.new(Container{item = Inner{leaf = Tracked{value = 42}}, later = fail_value()})
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
        \\fallible fail_value() int
        \\  const storage = allocate(int, -1)
        \\  deallocate(int, storage^)
        \\  return 1
        \\fallible run() unit
        \\  const owner = Box.new(Outer{inner = Inner{leaf = Tracked{value = 42}}, later = fail_value()})
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
        \\fallible fail_value() int
        \\  const storage = allocate(int, -1)
        \\  deallocate(int, storage^)
        \\  return 7
        \\fallible run() unit
        \\  const owner = Box(Immovable).new(Immovable{first = Tracked{value = 42}, second = fail_value()})
        \\  _ = owner
        \\if run() -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box rejects noncopyable places and explicit-drop elements" {
    const cases = [_]struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) }{
        .{ .source =
        \\struct Immovable
        \\  move = none
        \\  value: int
        \\const original = Immovable{value = 42}
        \\if Box(Immovable).new(original) -> exit(1) else exit(2)
        , .diagnostic = .type_not_copyable },
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
        if (case.diagnostic == .type_not_copyable)
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
        \\  $hook
        \\    return Pair{first = self.second, second = self.first}
        \\fallible run() int
        \\  var first_owner = Box.new(Item{value = 17})
        \\  var second_owner = Box.new(Item{value = 23})
        \\  const first = first_owner.borrow_mut()
        \\  const second = second_owner.borrow_mut()
        \\  const source = Pair{first = first, second = second}
        \\  const copied = $operand
        \\  const handle = copied.first
        \\  $replacement
        \\  return handle[].value
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
                .replacement = if (replace_owner) "second_owner = Box.new(Item{value = 42})" else "",
            });
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
        .{ .movement = "", .hook = "copy = func(imm", .parameter = "Box(Copier)", .argument = "Box(Copier).new(source)", .access = "copied.borrow()[].target[].value" },
        .{ .movement = "  move = none\n", .hook = "copy = func(imm", .parameter = "Box(Copier)", .argument = "Box(Copier).new(source)", .access = "copied.borrow()[].target[].value" },
        .{ .movement = "", .hook = "move = func(deinit", .parameter = "Copier", .argument = "source^", .access = "copied.target[].value" },
    };
    inline for (cases) |case| {
        const source = try std.mem.concat(testing.allocator, u8, &.{
            "struct Item\n  value: int\n  drop = func(deinit self: Item) -> ()\nstruct Copier\n",
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

test "Box.new copies into a new Box without consuming its source" {
    const fixture = try Fixture.init(
        \\import std.memory.{value}
        \\struct Copyable
        \\  copy = func(imm self: Copyable) Copyable -> Copyable{value = self.value + 1}
        \\  value: int
        \\fallible run() int
        \\  const source = Copyable{value = 41}
        \\  const owner = Box(Copyable).new(source)
        \\  const copied = value(Copyable, owner^)
        \\  return copied.value + source.value - 41
        \\if const result = run() -> exit(result) else exit(1)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new constructs a copy-only value in new storage" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = trivial
        \\  value: int
        \\  drop = func(deinit self: CopyOnly) -> exit(self.value)
        \\fallible run() unit
        \\  const source = CopyOnly{value = 42}
        \\  const owner = Box(CopyOnly).new(source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new runs an immovable custom copy hook in new storage" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\  drop = func(deinit self: CopyOnly)
        \\    if self.value == 42 -> exit(42) else ()
        \\fallible run() unit
        \\  const source = CopyOnly{value = 41}
        \\  const owner = Box(CopyOnly).new(source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new copies nested fields with custom hooks into final storage" {
    const fixture = try Fixture.init(
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
        \\  const owner = Box(Outer).new(source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new copies the active member of an immovable variant" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> CopyOnly{value = self.value + 1}
        \\  value: int
        \\  drop = func(deinit self: CopyOnly)
        \\    if self.value == 42 -> exit(42) else ()
        \\static CopyOrInt = CopyOnly | int
        \\fallible run() unit
        \\  const source: CopyOrInt = CopyOnly{value = 41}
        \\  const owner = Box(CopyOrInt).new(source)
        \\  _ = owner
        \\  exit(1)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new does not copy inactive variant members" {
    const fixture = try Fixture.init(
        \\struct CopyOnly
        \\  move = none
        \\  copy = func(imm self: CopyOnly) CopyOnly -> exit(1)
        \\  value: int
        \\static CopyOrInt = CopyOnly | int
        \\fallible run() unit
        \\  const source: CopyOrInt = 41
        \\  const owner = Box(CopyOrInt).new(source)
        \\  _ = owner
        \\  exit(42)
        \\if run() -> exit(2) else exit(3)
    , &.{});
    defer fixture.deinit();
    try fixture.expectExit(0, 42);
}

test "Box.new rejects noncopyable values" {
    const fixture = try Fixture.init(
        \\struct Token
        \\  move = none
        \\  value: int
        \\const source = Token{value = 42}
        \\if Box(Token).new(source) -> exit(1) else exit(2)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .type_not_copyable);
}

test "Box.new rejects explicitly droppable values" {
    const fixture = try Fixture.init(
        \\struct Explicit
        \\  copy = trivial
        \\  drop = explicit
        \\  value: int
        \\const source = Explicit{value = 42}
        \\if Box(Explicit).new(source) -> exit(1) else exit(2)
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
    try testing.checkAllAllocationFailures(allocation_failure_backing.allocator(), checkModuleAllocations, .{});
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
    try testing.checkAllAllocationFailures(allocation_failure_backing.allocator(), checkCleanupEffectAllocations, .{});
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
    const f = try Fixture.init("import lib\nexit(lib.S.read())", &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
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

test "init checkpoint constructs and forwards through callable values" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int
        \\    return item
        \\fallible forward(init item: int) int
        \\    return materialize(item)
        \\fallible invoke(imm callback: fallible(init int) int, init item: int) int
        \\    return callback(item)
        \\if const status = invoke(forward, 42) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint generic construction has runtime and comptime parity" {
    try Fixture.expectSourceExit(
        \\fallible materialize(static T: type, init item: T) T
        \\    return item
        \\fallible forward(static T: type, init item: T) T
        \\    return materialize(T, item)
        \\static answer = if const computed = forward(40 + 2) -> computed else 97
        \\if const status = forward(answer) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint defers the entire producer and its arguments" {
    const sources = [_][]const u8{
        \\func producer(imm argument: int) int -> return argument
        \\fallible receiver(init item: int, imm eager: int) int -> return item
        \\func skipped() int -> exit(99)
        \\func stop() int -> exit(42)
        \\if const status = receiver(producer(skipped()), stop()) -> exit(status) else exit(97)
        ,
        \\func producer() int -> exit(99)
        \\fallible receiver(init item: int) int -> exit(42)
        \\if const status = receiver(producer()) -> exit(status) else exit(97)
        ,
        \\func producer() int -> exit(42)
        \\fallible receiver(init item: int) int
        \\    return item
        \\if const status = receiver(producer()) -> exit(status) else exit(97)
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
        \\fallible materialize(init item: Pinned) Pinned -> return item
        \\fallible forward(init item: Pinned) Pinned -> return materialize(item)
        \\fallible receiver(imm callback: fallible(init Pinned) Pinned, init item: Pinned) int
        \\    const value = callback(item)
        \\    return value.value
        \\if const status = receiver(forward, producer(42)) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint read captures retain their caller context" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int -> return item
        \\fallible calculate(imm base: int) int
        \\    var extra = 2
        \\    const immutable = base + 1
        \\    return materialize(immutable + extra)
        \\static answer = if const computed = calculate(39) -> computed else 97
        \\if const status = calculate(answer - 3) -> exit(status) else exit(97)
    , 42);
}

test "init capture writes update caller storage through forwarding" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible run() int
        \\    var value = 1
        \\    const result = forward(if value == 1
        \\        value = 40
        \\        2
        \\    else 0)
        \\    return value + result
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture mutable calls update caller storage through forwarding" {
    try Fixture.expectSourceExit(
        \\func change(mut value: int) int
        \\    value = 40
        \\    return 2
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible run() int
        \\    var value = 1
        \\    const result = forward(change(value))
        \\    return value + result
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture checked references survive generic indirect forwarding" {
    try Fixture.expectSourceExit(
        \\import std.memory.{borrow_local}
        \\fallible materialize(static T: type, init item: T) T from(item) -> return item
        \\fallible forward(init item: Ref(int, false)) Ref(int, false) from(item) -> return materialize(item)
        \\fallible indirect(imm callback: fallible(init Ref(int, false)) Ref(int, false), init item: Ref(int, false)) Ref(int, false) from(item) -> return callback(item)
        \\fallible run() int
        \\    var value = 42
        \\    const reference = borrow_local(int, value)
        \\    const result = indirect(forward, reference)
        \\    return result[]
        \\if const status = run() -> exit(status) else exit(97)
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
        \\fallible receive(init item: Item, imm construct: bool) int
        \\    construct == true
        \\    const value = item
        \\    1 == 0
        \\    return value.value
        \\fallible run(imm construct: bool) int
        \\    const source = Item{value = if construct == true -> 41 else 42}
        \\    if const value = receive(source^, construct) -> return value
        \\    return 21
        \\static answer = if const computed = run(false) -> if const additional_computed = run(true) -> computed + additional_computed else 97 else 97
        \\if const status = run(false) -> if const additional_status = run(true) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init capture field transfers clean partial region failure and residual fields" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    move = func(deinit self: Item) Item -> return Item{value = self.value + 1}
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 42 -> return else exit(99)
        \\struct Pair
        \\    move = none
        \\    first: Item
        \\    second: Item
        \\fallible fail_value() Item
        \\    1 == 0
        \\    return Item{value = 99}
        \\fallible materialize(init item: Pair) Pair -> return item
        \\fallible forward(init item: Pair) Pair -> return materialize(item)
        \\fallible run() int
        \\    const source = Pair{first = Item{value = 41}, second = Item{value = 42}}
        \\    if const result = forward(Pair{first = source.first^, second = fail_value()}) -> return result.second.value
        \\    return 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture deferred effects reject overlapping eager inputs and callee" {
    const sources = [_][]const u8{
        "fallible receive(imm eager: int, init item: int) int -> return item\nfallible run() int\n    var value = 1\n    return receive(value, if true == true\n        value = 42\n        0\n    else 0)\nif const status = run() -> exit(status) else exit(97)",
        "fallible receive(init item: int, imm eager: int) int -> return item\nfallible run() int\n    var value = 1\n    return receive(value^, value)\nif const status = run() -> exit(status) else exit(97)",
        "fallible receive(init item: int) int -> return item\nfallible other(init item: int) int -> return item\nfallible run() int\n    var callback: fallible(init int) int = receive\n    return callback(if true == true\n        callback = other\n        42\n    else 0)\nif const status = run() -> exit(status) else exit(97)",
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .initializer_capture_conflict);
    }
}

test "init capture consuming fields stay caller owned until the consuming call" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        if self.value == 42 -> return else exit(99)
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\func consume(deinit item: Item, imm unused: int) int -> return item.value
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    const source = Pair{first = Item{value = 42}, second = Item{value = 42}}
        \\    if const value = materialize(consume(source.first, fail_value())) -> return value
        \\    return materialize(consume(source.second, 0))
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture writes survive failure after deferred mutable calls" {
    try Fixture.expectSourceExit(
        \\fallible change(mut value: int) int
        \\    value = 42
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible run() int
        \\    var value = 1
        \\    if const result = forward(change(value)) -> return result
        \\    return value
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture reference writes execute only during construction" {
    try Fixture.expectSourceExit(
        \\func change(imm reference: Ref(int, true)) int
        \\    reference[] = 42
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible skip(init item: int) int
        \\    1 == 0
        \\    return item
        \\fallible run() int
        \\    var owner = Box.new(1)
        \\    const reference = owner.borrow_mut()
        \\    if const unused = skip(change(reference)) -> return 99
        \\    if reference[] == 1 -> materialize(change(reference)) else return 98
        \\    return reference[]
        \\if const answer = run() -> exit(answer) else exit(97)
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
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm flag: bool) int
        \\    const source = Pair{first = Item{value = 21}, second = Item{value = 21}}
        \\    return materialize(consume(if flag == true -> source.first else source.second))
        \\static answer = if const computed = run(true) -> if const additional_computed = run(false) -> computed + additional_computed else 97 else 97
        \\if const status = run(true) -> if const additional_status = run(false) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init capture loop consuming places preserve selected completion state" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    drop = func(deinit self: Item)
        \\        if self.value == 21 -> return else exit(99)
        \\func consume(deinit item: Item) int -> return item.value
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm flag: bool) int
        \\    const first = Item{value = 21}
        \\    const second = Item{value = 21}
        \\    return materialize(consume(loop -> break if flag == true -> first else second))
        \\static answer = if const computed = run(true) -> if const additional_computed = run(false) -> computed + additional_computed else 97 else 97
        \\if const status = run(true) -> if const additional_status = run(false) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init capture transfer hooks run exactly once across skipped and failed construction" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    copy = none
        \\    move = func(deinit self: Item) Item
        \\        self.counter[] = self.counter[] + 1
        \\        return Item{counter = self.counter}
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\struct Pair
        \\    move = none
        \\    first: Item
        \\    second: Item
        \\fallible fail_value(imm counter: Ref(int, true)) Item from(counter)
        \\    1 == 0
        \\    return Item{counter = counter}
        \\fallible receive(init item: Item, imm construct: bool) int
        \\    construct == true
        \\    const value = item
        \\    1 == 0
        \\    return 99
        \\fallible materialize(init item: Pair) Pair -> return item
        \\fallible root(imm construct: bool) int
        \\    var counter = Box.new(0)
        \\    const source = Item{counter = counter.borrow_mut()}
        \\    if const unused = receive(source^, construct) -> return 99
        \\    return counter.borrow()[]
        \\fallible field() int
        \\    var counter = Box.new(0)
        \\    const source = Pair{first = Item{counter = counter.borrow_mut()}, second = Item{counter = counter.borrow_mut()}}
        \\    if const unused = materialize(Pair{first = source.first^, second = fail_value(counter.borrow_mut())}) -> return 99
        \\    return counter.borrow()[]
        \\fallible run() int
        \\    const skipped = root(false)
        \\    if skipped == 10 -> () else return 100 + skipped
        \\    const completed = root(true)
        \\    if completed == 11 -> () else return 120 + completed
        \\    return skipped + completed + field()
        \\if const answer = run() -> exit(answer) else exit(98)
    , 42);
}

test "init capture shared failure continuations retain possible transfer diagnostics" {
    const sources = [_][]const u8{
        "fallible receive(init item: int, imm construct: bool) int\n    construct == true\n    const value = item\n    1 == 0\n    return value\nfallible run(imm flag: bool) int\n    var value = 42\n    if const unused = receive(value^, flag) -> return unused\n    return value\nif const status = run(false) -> exit(status) else exit(97)",
        "struct Pair\n    first: int\n    second: int\nfallible receive(init item: int, imm construct: bool) int\n    construct == true\n    const value = item\n    1 == 0\n    return value\nfallible run(imm flag: bool) int\n    const value = Pair{first = 42, second = 0}\n    if const unused = receive(value.first^, flag) -> return unused\n    return value.first\nif const status = run(false) -> exit(status) else exit(97)",
    };
    for (sources) |source| {
        try Fixture.expectSourceDiagnostic(source, .possibly_transferred);
    }
}

test "init capture nested regions share transfer completion without owning captures" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    value: int
        \\    copy = none
        \\    move = func(deinit self: Item) Item -> return Item{value = self.value + 1}
        \\    drop = func(deinit self: Item)
        \\        if self.value == 42 -> return else exit(99)
        \\struct Pair
        \\    move = none
        \\    first: Item
        \\    second: Item
        \\fallible fail_value() Item
        \\    1 == 0
        \\    return Item{value = 99}
        \\fallible materialize(init item: Pair) Pair -> return item
        \\fallible run() int
        \\    const source = Pair{first = Item{value = 41}, second = Item{value = 42}}
        \\    if const unused = materialize(materialize(Pair{first = source.first^, second = fail_value()})) -> return 98
        \\    return 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture repeated writes retain their original storage parameter" {
    try Fixture.expectSourceExit(
        \\func increment(mut value: int) int
        \\    value += 1
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    var value = 0
        \\    const unused = materialize(if true == true
        \\        value = 20
        \\        value = 41
        \\        increment(value)
        \\    else 0)
        \\    return value
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture writes refresh returned references to caller storage" {
    try Fixture.expectSourceExit(
        \\import std.memory.{borrow_local}
        \\fallible materialize(init item: Ref(int, false)) Ref(int, false) from(item) -> return item
        \\fallible run() int
        \\    var value = 1
        \\    borrow mut alias = value
        \\    const reference = materialize(if true == true
        \\        value = 42
        \\        borrow_local(int, value)
        \\    else borrow_local(int, value))
        \\    alias = 7
        \\    return reference[] + 35
        \\if const status = run() -> exit(status) else exit(97)
    , 42);
}

test "init capture explicit drop obligations survive possible skipped transfers" {
    const sources = [_][]const u8{
        "struct Item\n    value: int\n    drop = explicit\nfunc consume(deinit value: Item) int -> return value.value\nfallible materialize(init item: int) int -> return item\nfallible skip(init item: int) int\n    1 == 0\n    return item\nfallible run() int\n    const source = Item{value = 42}\n    if const value = skip(consume(source)) -> return value\n    return 0\nif const status = run() -> exit(status) else exit(97)",
        "struct Item\n    value: int\n    drop = explicit\nstruct Pair\n    first: Item\n    second: int\nfunc consume(deinit value: Item) int -> return value.value\nfallible skip(init item: int) int\n    1 == 0\n    return item\nfallible run() int\n    const source = Pair{first = Item{value = 42}, second = 0}\n    if const value = skip(consume(source.first)) -> return value\n    return 0\nif const status = run() -> exit(status) else exit(97)",
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
        \\fallible materialize(init item: Item) Item -> return item
        \\fallible run() int
        \\    var source = Item{value = 41}
        \\    const destination = materialize(if true == true
        \\        source.value = 42
        \\        source^
        \\    else Item{value = 42})
        \\    return destination.value
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture owned replacements survive later region failure" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    var counter = Box.new(0)
        \\    var source = Item{counter = counter.borrow_mut()}
        \\    if const unused = materialize(if true == true
        \\        source = Item{counter = counter.borrow_mut()}
        \\        fail_value()
        \\    else 0) -> return 99
        \\    return counter.borrow()[] + 22
        \\if const answer = run() -> exit(answer) else exit(98)
    , 42);
}

test "init captured replacement does not revive stale references" {
    const source =
        \\fallible materialize(init item: Ref(int, false)) Ref(int, false) from(item) -> return item
        \\fallible run() int
        \\    var owner = Box.new(1)
        \\    const reference = owner.borrow()
        \\    const observed = reference[]
        \\    const result = materialize(if observed == 1
        \\        owner = Box.new(2)
        \\        reference
        \\    else reference)
        \\    return result[]
        \\if const result = run() -> exit(result) else exit(97)
    ;
    const unchanged_source = try std.mem.replaceOwned(u8, testing.allocator, source, "owner = Box.new(2)", "const replacement = Box.new(2)");
    defer testing.allocator.free(unchanged_source);
    try Fixture.expectSourceExit(unchanged_source, 1);

    const fresh_branch = try std.mem.replaceOwned(u8, testing.allocator, source, "        reference", "        owner.borrow()");
    defer testing.allocator.free(fresh_branch);
    const fresh_source = try std.mem.replaceOwned(u8, testing.allocator, fresh_branch, "else reference", "else owner.borrow()");
    defer testing.allocator.free(fresh_source);
    try Fixture.expectSourceExit(fresh_source, 2);

    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: Ref(int, false)) Ref(int, false) from(item) -> return item
        \\fallible run() int
        \\    var owner = Box.new(1)
        \\    const result = materialize(if 1 == 1
        \\        const reference = owner.borrow()
        \\        owner = Box.new(2)
        \\        reference
        \\    else owner.borrow())
        \\    return result[]
        \\if const result = run() -> exit(result) else exit(97)
    , .borrow_outlives_source);

    const fixture = try Fixture.init(source, &.{});
    defer fixture.deinit();
    try testing.expect((try fixture.db.get(queries.BuildExecutable, 0)).* == null);
    const diagnostics = try fixture.db.transitiveAccumulatorValues(queries.BuildExecutable, 0, structures.Diagnostic, testing.allocator);
    defer testing.allocator.free(diagnostics);
    for (diagnostics) |diagnostic| {
        if (diagnostic.file_id != 0) continue;
        switch (diagnostic.kind) {
            .borrow_outlives_source, .initializer_capture_conflict => return,
            else => {},
        }
    }
    for (diagnostics) |diagnostic| std.debug.print("file {d} at {d}: {s}\n", .{ diagnostic.file_id, (if (diagnostic.span) |span| span.start else 0), @tagName(diagnostic.kind) });
    return error.ExpectedDiagnostic;
}

test "init capture restoration after transfer restores caller cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    weight: int
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + self.weight
        \\func take(var item: Item) int -> return 0
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    var counter = Box.new(0)
        \\    var source = Item{counter = counter.borrow_mut(), weight = 10}
        \\    if const unused = materialize(if true == true
        \\        take(source^)
        \\        source = Item{counter = counter.borrow_mut(), weight = 32}
        \\        fail_value()
        \\    else 0) -> return 99
        \\    return counter.borrow()[]
        \\if const answer = run() -> exit(answer) else exit(98)
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
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible run() int
        \\    var source = Item{value = 42}
        \\    const first = materialize(int, if true == true
        \\        take(source^)
        \\        source = Item{value = 42}
        \\        0
        \\    else 0)
        \\    const second = materialize(Item, source^)
        \\    return first + second.value
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init capture restored fields keep caller cleanup on later failure" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    weight: int
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + self.weight
        \\struct Pair
        \\    first: Item
        \\    second: int
        \\func take(var item: Item) int -> return 0
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    var counter = Box.new(0)
        \\    var source = Pair{first = Item{counter = counter.borrow_mut(), weight = 10}, second = 0}
        \\    if const unused = materialize(if true == true
        \\        take(source.first^)
        \\        source.first = Item{counter = counter.borrow_mut(), weight = 32}
        \\        fail_value()
        \\    else 0) -> return 99
        \\    return counter.borrow()[]
        \\if const answer = run() -> exit(answer) else exit(98)
    , 42);
}

test "init capture root and field alternatives share failure cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\func consume_pair(var item: Pair) int -> return 0
        \\func consume_item(var item: Item) int -> return 0
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm whole: bool) int
        \\    var counter = Box.new(0)
        \\    const source = Pair{first = Item{counter = counter.borrow_mut()}, second = Item{counter = counter.borrow_mut()}}
        \\    if const unused = materialize(if whole == true -> consume_pair(source^) + fail_value() else consume_item(source.first^) + fail_value()) -> return 99
        \\    return counter.borrow()[] + 1
        \\fallible calculate() int
        \\    const whole = run(true)
        \\    if whole == 21 -> () else return 100 + whole
        \\    return whole + run(false)
        \\if const answer = calculate() -> exit(answer) else exit(98)
    , 42);
}

test "init capture ancestor and nested field alternatives share failure cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\struct Outer
        \\    pair: Pair
        \\func take_pair(var item: Pair) int -> return 0
        \\func take_item(var item: Item) int -> return 0
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm whole: bool) int
        \\    var counter = Box.new(0)
        \\    const source = Outer{pair = Pair{first = Item{counter = counter.borrow_mut()}, second = Item{counter = counter.borrow_mut()}}}
        \\    if const unused = materialize(if whole == true -> take_pair(source.pair^) + fail_value() else take_item(source.pair.first^) + fail_value()) -> return 99
        \\    return counter.borrow()[] + 1
        \\fallible calculate() int -> return run(true) + run(false)
        \\if const answer = calculate() -> exit(answer) else exit(98)
    , 42);
}

test "init capture scoped aliases preserve deferred place access" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    var value = 1
        \\    borrow mut alias = value
        \\    const result = materialize(if true == true
        \\        alias = 42
        \\        alias
        \\    else 0)
        \\    return value + result - 42
        \\if const status = run() -> exit(status) else exit(97)
    , 42);
}

test "init capture nested reference projections survive selection and wrapping" {
    try Fixture.expectSourceExit(
        \\import std.memory.{borrow_local}
        \\struct Inner
        \\    reference: Ref(int, false)
        \\    copy = trivial
        \\struct Outer
        \\    inner: Inner
        \\fallible materialize(static T: type, init item: T) T from(item) -> return item
        \\fallible forward(static T: type, init item: T) T from(item) -> return materialize(T, item)
        \\fallible run() int
        \\    var value = 42
        \\    const source = Outer{inner = Inner{reference = borrow_local(int, value)}}
        \\    const selected = forward(Ref(int, false), source.inner.reference)
        \\    const wrapped = forward(Outer, Outer{inner = source.inner})
        \\    return selected[] + wrapped.inner.reference[] - 42
        \\if const status = run() -> exit(status) else exit(97)
    , 42);
    const selected = try Fixture.init(
        \\import std.memory.{borrow_local}
        \\struct References
        \\    external: Ref(int, false)
        \\    local: Ref(int, false)
        \\fallible materialize(init item: Ref(int, false)) Ref(int, false) from(item) -> return item
        \\fallible select(imm external: Ref(int, false)) Ref(int, false) from(external)
        \\    var local = 1
        \\    const source = References{external = external, local = borrow_local(int, local)}
        \\    return materialize(source.external)
        \\var value = 42
        \\if const status = select(borrow_local(int, value)) -> exit(status[]) else exit(97)
    , &.{});
    defer selected.deinit();
    try selected.expectExit(0, 42);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{borrow_local}
        \\struct Inner
        \\    reference: Ref(int, false)
        \\    copy = trivial
        \\struct Outer
        \\    inner: Inner
        \\fallible materialize(init item: Outer) Outer from(item) -> return item
        \\fallible escape() Ref(int, false)
        \\    var value = 42
        \\    const source = Inner{reference = borrow_local(int, value)}
        \\    return materialize(Outer{inner = source}).inner.reference
        \\if const status = escape() -> exit(status[]) else exit(97)
    , .borrow_outlives_source);
}

test "init capture multiple receiving calls share exact failure cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 21
        \\fallible receive(init item: Item, imm construct: bool) int
        \\    construct == true
        \\    const value = item
        \\    1 == 0
        \\    return 0
        \\fallible run(imm first_path: bool, imm construct: bool) int
        \\    var counter = Box.new(0)
        \\    const first = Item{counter = counter.borrow_mut()}
        \\    const second = Item{counter = counter.borrow_mut()}
        \\    if first_path == true
        \\        if const unused = receive(first^, construct) -> return 99
        \\    else
        \\        if const unused = receive(second^, construct) -> return 99
        \\    return counter.borrow()[]
        \\fallible calculate() int
        \\    return (run(true, true) + run(true, false) + run(false, true) + run(false, false)) / 4
        \\if const answer = calculate() -> exit(answer) else exit(98)
    , 42);
}

test "init capture receiving mutable reference outputs preserve initializer origins" {
    try Fixture.expectSourceExit(
        \\import std.memory.{borrow_local}
        \\fallible install(init input: Ref(int, false), mut output: Ref(int, false))
        \\    output = input
        \\fallible forward(init input: Ref(int, false), mut output: Ref(int, false))
        \\    install(input, output)
        \\fallible run() int
        \\    var old = 1
        \\    var value = 42
        \\    var output = borrow_local(int, old)
        \\    const callback: fallible(init Ref(int, false), mut Ref(int, false)) unit = forward
        \\    callback(borrow_local(int, value), output)
        \\    return output[]
        \\if const status = run() -> exit(status) else exit(97)
    , 42);
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{borrow_local}
        \\fallible install(init input: Ref(int, false), mut output: Ref(int, false))
        \\    output = input
        \\fallible escape(imm previous: Ref(int, false)) Ref(int, false) from(previous)
        \\    var local = 42
        \\    var output = previous
        \\    install(borrow_local(int, local), output)
        \\    return output
        \\var value = 1
        \\if const status = escape(borrow_local(int, value)) -> exit(status[]) else exit(97)
    , .borrow_outlives_source);
}

test "init capture consuming joins keep mixed captured and local owners separate" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\func consume(deinit item: Item, imm eager: int) int -> return 0
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm captured: bool) int
        \\    var counter = Box.new(0)
        \\    const source = Item{counter = counter.borrow_mut()}
        \\    if const unused = materialize(consume(if captured == true -> source else Item{counter = counter.borrow_mut()}, fail_value())) -> return 99
        \\    return counter.borrow()[]
        \\fallible calculate() int
        \\    const captured = run(true)
        \\    if captured == 10 -> () else return 100 + captured
        \\    return captured + run(false) + 12
        \\if const answer = calculate() -> exit(answer) else exit(98)
    , 42);
    const loop = try Fixture.init(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\func consume(deinit item: Item, imm eager: int) int -> return 0
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm captured: bool) int
        \\    var counter = Box.new(0)
        \\    const source = Item{counter = counter.borrow_mut()}
        \\    if const unused = materialize(consume(loop -> break if captured == true -> source else Item{counter = counter.borrow_mut()}, fail_value())) -> return 99
        \\    return counter.borrow()[]
        \\fallible calculate() int
        \\    const captured = run(true)
        \\    if captured == 10 -> () else return 100 + captured
        \\    return captured + run(false) + 12
        \\if const answer = calculate() -> exit(answer) else exit(98)
    , &.{});
    defer loop.deinit();
    try loop.expectExit(0, 42);
}

test "init checkpoint enforces one construction on every successful path" {
    const Case = struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) };
    const cases = [_]Case{
        .{ .source = "fallible bad(init item: int) int -> return 42\nif const status = bad(7) -> exit(status) else exit(97)", .diagnostic = .initializer_not_consumed },
        .{ .source = "fallible bad(init item: int) int\n    const first = item\n    return item\nif const status = bad(7) -> exit(status) else exit(97)", .diagnostic = .initializer_already_consumed },
        .{ .source = "fallible bad(init item: int) int -> return item + 1\nif const status = bad(7) -> exit(status) else exit(97)", .diagnostic = .initializer_requires_construction },
        .{ .source = "func read(imm item: int) int -> return item\nfallible bad(init item: int) int -> return read(item)\nif const status = bad(7) -> exit(status) else exit(97)", .diagnostic = .initializer_requires_construction },
        .{ .source = "fallible bad(init item: int, imm flag: int) int\n    if flag == 1\n        const value = item\n    return 42\nif const status = bad(7, 0) -> exit(status) else exit(97)", .diagnostic = .initializer_not_consumed },
        .{ .source = "fallible bad(init item: int) int\n    loop\n        const value = item\n        continue\nif const status = bad(7) -> exit(status) else exit(97)", .diagnostic = .initializer_consumed_in_loop },
        .{ .source = "struct Item\n    field: int\nfallible bad(init item: Item) int -> return item.field\nif const status = bad(Item{field = 42}) -> exit(status) else exit(97)", .diagnostic = .initializer_requires_construction },
        .{ .source = "fallible good(init item: int) int -> return item\nfallible bad(init item: int) int\n    const first = good(item)\n    return good(item)\nif const status = bad(7) -> exit(status) else exit(97)", .diagnostic = .initializer_already_consumed },
    };
    for (cases) |case| {
        try Fixture.expectSourceDiagnostic(case.source, case.diagnostic);
    }
}

test "init checkpoint consumes independently on conditional and loop exits" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int -> return item
        \\fallible choose(init item: int, imm flag: int) int
        \\    if flag == 1 -> return materialize(item) else return item
        \\fallible leave(init item: int) int
        \\    return loop -> break item
        \\static answer = if const computed = choose(20, 1) -> if const additional_computed = leave(22) -> computed + additional_computed else 97 else 97
        \\if const status = choose(20, 0) -> if const additional_status = leave(answer - 20) -> exit(status + additional_status) else exit(97) else exit(97)
    , 42);
}

test "init checkpoint rejects eager mutations and transfers of pending captures" {
    const Case = struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) };
    const cases = [_]Case{
        .{ .source = "fallible materialize(init item: int, imm eager: int) int -> return item\nfallible run() int\n    var value = 42\n    return materialize(value, if 1 == 1\n        value = 7\n        0\n    else 0)\nif const status = run() -> exit(status) else exit(97)", .diagnostic = .initializer_capture_conflict },
        .{ .source = "func take(deinit value: int) int -> return value\nfallible materialize(init item: int, imm eager: int) int -> return item\nfallible run() int\n    var value = 42\n    return materialize(value, take(value))\nif const status = run() -> exit(status) else exit(97)", .diagnostic = .initializer_capture_conflict },
        .{ .source = "func change(mut value: int) int\n    value = 7\n    return 0\nfallible materialize(init item: int, imm eager: int) int -> return item\nfallible run() int\n    var value = 42\n    return materialize(value, change(value))\nif const status = run() -> exit(status) else exit(97)", .diagnostic = .initializer_capture_conflict },
    };
    for (cases) |case| {
        try Fixture.expectSourceDiagnostic(case.source, case.diagnostic);
    }
}

test "init checkpoint supports handled failure and skipped construction" {
    try Fixture.expectSourceExit(
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: int) int -> return item
        \\fallible skip(init item: int) int
        \\    fail_value()
        \\    return item
        \\func producer() int -> exit(99)
        \\if skip(producer()) -> exit(1)
        \\if const status = materialize(if const result = fail_value() -> result else 42) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint retains captured owners and defers copy hooks" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    value: int
        \\    copy = func(imm self: Source) Source -> exit(99)
        \\    drop = func(deinit self: Source) -> exit(98)
        \\fallible skip(init item: Source) int -> exit(42)
        \\fallible run() int
        \\    var source = Source{value = 7}
        \\    return skip(source)
        \\if const status = run() -> exit(status) else exit(97)
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
        \\fallible copy_item(init item: Copied) Copied -> return item
        \\fallible pin_item(init item: Pinned) Pinned -> return item
        \\func produce() Pinned -> return Pinned{value = 42}
        \\fallible run() int
        \\    var original = Copied{value = 41}
        \\    const copied = copy_item(original)
        \\    const pinned = pin_item(produce())
        \\    return copied.value + pinned.value - 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init lexical ordinary consuming break retains cleanup before call" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    value: int
        \\    drop = func(deinit self: Source) -> exit(31)
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Source, imm eager: int) int -> return item.value
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible run() int
        \\    const source = Source{value = 42}
        \\    return consume(loop
        \\        if 1 == 1 -> break source
        \\        break Source{value = 99}
        \\    , fail_value())
        \\if const result = run() -> exit(result) else exit(99)
    , 31);
}

test "init lexical pending consumption preserves roots and fields across joins" {
    const expressions = [_][]const u8{
        \\loop
        \\        if captured == true -> break selected
        \\        break Source{counter = counter.borrow_mut(), weight = 10}
        \\    , eager(succeeds)
        ,
        \\if captured == true -> loop
        \\        if 1 == 1 -> break selected
        \\        break Source{counter = counter.borrow_mut(), weight = 99}
        \\    else Source{counter = counter.borrow_mut(), weight = 10}, eager(succeeds)
        ,
        \\loop
        \\        break loop
        \\            if captured == true -> break selected
        \\            break Source{counter = counter.borrow_mut(), weight = 10}
        \\    , eager(succeeds)
        ,
    };
    const places = [_]struct { declaration: []const u8, payload: []const u8, captured_count: u32, fresh_count: u32, adjustment: []const u8 }{
        .{
            .declaration =
            \\    const source = Source{counter = counter.borrow_mut(), weight = 1}
            \\    return
            ,
            .payload = "source",
            .captured_count = 1,
            .fresh_count = 11,
            .adjustment = " + 18",
        },
        .{
            .declaration =
            \\    const pair = Pair{selected = Source{counter = counter.borrow_mut(), weight = 1}, sibling = Source{counter = counter.borrow_mut(), weight = 100}}
            \\    return
            ,
            .payload = "pair.selected",
            .captured_count = 101,
            .fresh_count = 111,
            .adjustment = " - 382",
        },
    };
    for (places) |place| {
        const outcomes = try std.fmt.allocPrint(testing.allocator,
            \\    if const unused = attempt(counter, true, true) -> ()
            \\    if counter.borrow()[] == {d} -> () else exit(91)
            \\    if const unused = attempt(counter, false, true) -> ()
            \\    if counter.borrow()[] == {d} -> () else exit(92)
            \\    if const unused = attempt(counter, true, false) -> ()
            \\    if counter.borrow()[] == {d} -> () else exit(93)
            \\    if const unused = attempt(counter, false, false) -> ()
            \\    if counter.borrow()[] == {d} -> () else exit(94)
            \\    return counter.borrow()[]
        , .{ place.captured_count, place.captured_count + place.fresh_count, 2 * place.captured_count + place.fresh_count, 2 * (place.captured_count + place.fresh_count) });
        defer testing.allocator.free(outcomes);
        for (expressions) |expression| {
            const selected_expression = try std.mem.replaceOwned(u8, testing.allocator, expression, "selected", place.payload);
            defer testing.allocator.free(selected_expression);
            for ([_]bool{ false, true }) |deferred| {
                errdefer std.debug.print("consuming join: payload={s}, deferred={}, expression={s}\n", .{ place.payload, deferred, expression });
                const source = try std.mem.concat(testing.allocator, u8, &.{
                    \\struct Source
                    \\    counter: Ref(int, true)
                    \\    weight: int
                    \\    drop = func(deinit self: Source)
                    \\        self.counter[] = self.counter[] + self.weight
                    \\struct Pair
                    \\    selected: Source
                    \\    sibling: Source
                    \\fallible materialize(init item: int) int -> return item
                    \\fallible receiver(init item: int) int -> return item
                    \\func dispose(var item: Source) -> ()
                    \\func consume(deinit item: Source, imm extra: int) int
                    \\    const result = item.weight
                    \\    dispose(item^)
                    \\    return result
                    \\fallible eager(imm succeeds: bool) int
                    \\    succeeds == true
                    \\    return 0
                    \\fallible attempt(mut counter: Box(int), imm captured: bool, imm succeeds: bool) int
                    \\
                    ,
                    place.declaration,
                    if (deferred) " receiver(consume(" else " consume(",
                    selected_expression,
                    if (deferred) "))\n" else ")\n",
                    \\fallible run() int
                    \\    var counter = Box.new(0)
                    \\
                    ,
                    outcomes,
                    place.adjustment,
                    \\
                    \\if const answer = run() -> exit(answer) else exit(98)
                });
                defer testing.allocator.free(source);
                if (!deferred and std.mem.eql(u8, place.payload, "pair.selected") and std.mem.startsWith(u8, expression, "if captured")) {
                    try Fixture.expectSourceDiagnostic(source, .partial_field_transfer_not_supported);
                } else {
                    try Fixture.expectSourceExit(source, 42);
                }
            }
        }
    }
}

test "init lexical pending consumption discharges explicit ownership only at call" {
    const source =
        \\struct Manual
        \\    value: int
        \\    drop = explicit
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Manual, imm extra: int) int -> return item.value
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible run() int
        \\    const source = Manual{value = 42}
        \\    return consume(loop
        \\        if 1 == 1 -> break source
        \\        break source
        \\    , eager)
        \\if const answer = run() -> exit(answer) else exit(98)
    ;
    for ([_]bool{ false, true }) |fails| {
        const fixture_source = try std.mem.replaceOwned(u8, testing.allocator, source, "eager", if (fails) "fail_value()" else "0");
        defer testing.allocator.free(fixture_source);
        const fixture = try Fixture.init(fixture_source, &.{});
        defer fixture.deinit();
        if (fails) {
            try fixture.expectDiagnostic(0, .value_requires_explicit_drop);
        } else {
            try fixture.expectExit(0, 42);
        }
    }
}

test "init lexical review consuming captured break keeps caller cleanup ownership" {
    try Fixture.expectSourceExit(
        \\struct Source
        \\    value: int
        \\    drop = func(deinit self: Source) -> exit(31)
        \\struct Guard
        \\    value: int
        \\    drop = func(deinit self: Guard) -> exit(23)
        \\fallible materialize(init item: int) int -> return item
        \\fallible receiver(init item: int) int
        \\    const guard = Guard{value = 1}
        \\    const result = item
        \\    return result + guard.value
        \\func consume(deinit item: Source, imm eager: int) int -> return item.value
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible run() int
        \\    const source = Source{value = 42}
        \\    if const result = receiver(consume(loop
        \\        if 1 == 1 -> break source
        \\        break Source{value = 99}
        \\    , fail_value())) -> return result
        \\    return 99
        \\if const status = run() -> exit(status) else exit(97)
    , 23);
}

test "init lexical rejects caller return even on an unselected transfer branch" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    value: int
        \\func take(deinit item: Item) int -> return item.value
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm leave: bool) int
        \\    const source = Item{value = 42}
        \\    const unused = materialize(if leave == true
        \\        const taken = take(source)
        \\        return taken
        \\    else 0)
        \\    return source.value
        \\if const status = run(false) -> exit(status) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller return through recursive wrapped handles" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int
        \\    const result = item
        \\    return result + 100
        \\fallible recurse(imm depth: int, init item: int) int
        \\    if depth == 0 -> return materialize(item) + 100
        \\    return recurse(depth - 1, materialize(item)) + 100
        \\fallible run() int
        \\    const unused = recurse(3, materialize(if 1 == 1 -> return 42 else 0))
        \\    return 99
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects byte and zero sized caller return and break payloads" {
    const fixture = try Fixture.init(
        \\struct Empty
        \\    move = none
        \\    copy = none
        \\fallible materialize(init item: bool) bool -> return item
        \\fallible byte_return() byte
        \\    const unused = materialize(if 1 == 1 -> return 42 else false)
        \\    return 99
        \\fallible byte_break() byte
        \\    return loop
        \\        const unused = materialize(if 1 == 1 -> break 42 else false)
        \\        break 99
        \\fallible empty_return() Empty
        \\    const unused = materialize(if 1 == 1 -> return Empty{} else false)
        \\    return Empty{}
        \\fallible empty_break() Empty
        \\    return loop
        \\        const unused = materialize(if 1 == 1 -> break Empty{} else false)
        \\        break Empty{}
        \\func accept(deinit item: Empty) int -> return 21
        \\fallible calculate() int
        \\    const first = byte_return()
        \\    const second = byte_break()
        \\    return accept(empty_return()) + accept(empty_break())
        \\static answer = if const computed = byte_return() -> computed else 97
        \\static loop_answer = if const computed = byte_break() -> computed else 97
        \\static empty_answer = if const computed = calculate() -> computed else 97
        \\if const status = calculate() -> exit(status + empty_answer - 42) else exit(97)
    , &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .initializer_exit_outside_boundary);
}

test "init capture mutable copyback and calling cleanups preserve normal results" {
    const source =
        \\func disturb(imm value: int) int -> return value * 3 + 1
        \\struct Guard
        \\    value: int
        \\    drop = func(deinit self: Guard)
        \\        const unused = disturb(self.value)
        \\fallible receiver(mut count: int, init item: int) int
        \\    const guard = Guard{value = count}
        \\    count = count + 1
        \\    const result = item
        \\    return result + guard.value
        \\fallible forward(mut count: int, init item: int) int
        \\    const guard = Guard{value = count}
        \\    count = count + 1
        \\    return receiver(count, item) + guard.value
        \\fallible run(mut count: int) int
        \\    return forward(count, 39)
        \\fallible calculate() int
        \\    var count = 0
        \\    const result = run(count)
        \\    return result + count
    ;
    for ([_][]const u8{ "if const answer = calculate() -> exit(answer) else exit(97)", "static answer = if const value = calculate() -> value else 97\nexit(answer)" }) |suffix| {
        const program = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}", .{ source, suffix });
        defer testing.allocator.free(program);
        const fixture = try Fixture.init(program, &.{});
        defer fixture.deinit();
        fixture.expectExit(0, 42) catch |err| {
            std.debug.print("copyback mode: {s}\n", .{suffix});
            return err;
        };
    }
}

test "init lexical rejects caller return through indirect forwarding" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int
        \\    const result = item
        \\    return result + 100
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible invoke(imm callback: fallible(init int) int, init item: int) int
        \\    return callback(item) + 100
        \\fallible run() int
        \\    const result = invoke(forward, if 1 == 1 -> return 42 else 0)
        \\    return result + 100
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init checkpoint rejects unchecked deferred failure" {
    const Case = struct { source: []const u8, diagnostic: std.meta.Tag(structures.Diagnostic.Kind) };
    const cases = [_]Case{
        .{ .source = "fallible fail_value() int\n    1 == 0\n    return 0\nfallible materialize(init item: int) int -> return item\nexit(materialize(fail_value()))", .diagnostic = .fallible_expression_outside_fallible_function },
    };
    for (cases) |case| {
        try Fixture.expectSourceDiagnostic(case.source, case.diagnostic);
    }
}

test "init lexical rejects caller value and unit returns" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: bool) bool -> return item
        \\fallible run() int
        \\    const unused = materialize(if 1 == 1 -> return 42 else false)
        \\    return 100
        \\fallible finish()
        \\    const unused = materialize(if 1 == 1 -> return else false)
        \\    exit(99)
        \\static answer = if const computed = run() -> computed else 97
        \\static completed = if const computed = finish() -> computed else unit
        \\if finish() -> ()
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller value and bare breaks" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int
        \\    const result = item
        \\    return result + 100
        \\fallible forward(init item: int) int -> return materialize(item) + 100
        \\fallible run() int
        \\    const result = loop
        \\        const unused = forward(if 1 == 1 -> break 42 else 0)
        \\        break 99
        \\    loop
        \\        const unused = materialize(if 1 == 1 -> break else 0)
        \\        exit(98)
        \\    return result
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller continue after captured writes" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int
        \\    const result = item
        \\    return result + 100
        \\fallible run() int
        \\    var count = 0
        \\    return loop
        \\        if count == 3 -> break 42
        \\        const unused = materialize(if 1 == 1
        \\            count = count + 1
        \\            continue
        \\        else 0)
        \\        break 99
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical region local loops remain distinct from caller loops" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    return loop
        \\        const value = materialize(loop
        \\            var count = 0
        \\            loop
        \\                count = count + 1
        \\                if count == 2 -> break
        \\                continue
        \\            break 42
        \\        )
        \\        break value
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init lexical rejects caller return through recursive consumers" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int
        \\    const result = item
        \\    return result + 100
        \\fallible recurse(imm depth: int, init item: int) int
        \\    if depth == 0 -> return materialize(item) + 100
        \\    return recurse(depth - 1, item) + 100
        \\fallible run() int
        \\    const unused = recurse(3, materialize(if 1 == 1 -> return 42 else 0))
        \\    return 99
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical forbidden caller exits remain invalid under a failure handler" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    if const value = materialize(if 1 == 1 -> return 42 else 0)
        \\        return value + 100
        \\    else
        \\        return 99
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical early consumer failure does not authorize a forbidden deferred exit" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int
        \\    1 == 0
        \\    return item
        \\fallible run() int
        \\    if const value = materialize(if 1 == 1 -> return 99 else 0)
        \\        return value
        \\    else
        \\        return 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller return during partial aggregate construction" {
    try Fixture.expectSourceDiagnostic(
        \\struct Marker
        \\    counter: Ref(int, true)
        \\    step: int
        \\    drop = func(deinit self: Marker)
        \\        self.counter[] = self.counter[] * 10 + self.step
        \\struct Pending
        \\    first: Marker
        \\    last: int
        \\    drop = func(deinit self: Pending) -> exit(98)
        \\fallible receive(init marker: Marker, init item: Pending) int
        \\    const held = marker
        \\    const value = item
        \\    return value.last + held.step
        \\fallible run(imm trace: Ref(int, true)) int
        \\    const caller = Marker{counter = trace, step = 3}
        \\    const unused = receive(Marker{counter = trace, step = 2}, Pending{first = Marker{counter = trace, step = 1}, last = if 1 == 1 -> return 42 else 0})
        \\    return unused + caller.step
        \\fallible calculate() int
        \\    var counter = Box.new(0)
        \\    const answer = run(counter.borrow_mut())
        \\    if counter.borrow()[] == 123 -> return answer
        \\    return 99
        \\if const answer = calculate() -> exit(answer) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects immovable caller return payloads" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible run() Pinned
        \\    const unused = materialize(if 1 == 1 -> return Pinned{value = 42} else false)
        \\    return Pinned{value = 99}
        \\fallible calculate() int
        \\    const result = run()
        \\    return result.value
        \\static answer = if const computed = calculate() -> computed else 97
        \\if const status = calculate() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects immovable caller break payloads" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() Pinned
        \\    return loop
        \\        const unused = materialize(if 1 == 1 -> break Pinned{value = 42} else 0)
        \\        break Pinned{value = 99}
        \\fallible calculate() int
        \\    const result = run()
        \\    return result.value
        \\static answer = if const computed = calculate() -> computed else 97
        \\if const status = calculate() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller break payloads with variant types" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: bool) bool -> return item
        \\fallible run(imm choose: bool) int
        \\    const selected = loop
        \\        const unused = materialize(if choose == true -> break 42 else break none)
        \\        break 99
        \\    if const result = selected as int -> return result
        \\    return 0
        \\static answer = if const computed = run(true) -> if const additional_computed = run(false) -> computed + additional_computed else 97 else 97
        \\if const status = run(true) -> if const additional_status = run(false) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects exits to a loop in an enclosing initializer region" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    return materialize(loop
        \\        const unused = materialize(if 1 == 1 -> break 42 else 0)
        \\        break 99
        \\    )
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller returns within recursive callers" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm depth: int) int
        \\    if depth == 0 -> return 39
        \\    const previous = run(depth - 1)
        \\    const unused = materialize(if 1 == 1 -> return previous + 1 else 0)
        \\    return 99
        \\static answer = if const computed = run(3) -> computed else 97
        \\if const status = run(3) -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller returns of checked references" {
    try Fixture.expectSourceDiagnostic(
        \\import std.memory.{borrow_local}
        \\fallible materialize(init item: int) int -> return item
        \\fallible select(imm reference: Ref(int, false)) Ref(int, false) from(reference)
        \\    const unused = materialize(if 1 == 1 -> return reference else 0)
        \\    return reference
        \\var value = 42
        \\if const status = select(borrow_local(int, value)) -> exit(status[]) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects checked reference caller returns in blocks and multi reference callers" {
    const sources = [_][]const u8{
        "import std.memory.{borrow_local}\nfallible materialize(init item: int) int -> return item\nfallible run(imm reference: Ref(int, false)) Ref(int, false) from(reference)\n    const unused = materialize(if 1 == 1\n        return reference\n    else 0)\n    exit(99)\nvar value = 42\nif run(borrow_local(int, value)) -> ()",
        "import std.memory.{borrow_local}\nfallible materialize(init item: int) int -> return item\nfallible select(imm allowed: Ref(int, false), imm other: Ref(int, false)) Ref(int, false) from(allowed)\n    const unused = materialize(if 1 == 1 -> return allowed else 0)\n    return allowed\nvar value = 42\nif select(borrow_local(int, value), borrow_local(int, value)) -> ()",
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
        \\fallible materialize(init item: int) never
        \\    const result = item
        \\    exit(result)
        \\fallible run() int
        \\    const source = Manual{value = 42}
        \\    return materialize(if 1 == 1
        \\        const consumed = consume(source)
        \\        return consumed
        \\    else consume(source))
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller consuming breaks with captured immovable storage" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\fallible run() int
        \\    const source = Pinned{value = 42}
        \\    return consume(loop
        \\        const unused = materialize(if 1 == 1 -> break source else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller consuming breaks with fresh immovable storage" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\fallible run() int
        \\    return consume(loop
        \\        const unused = materialize(if 1 == 1 -> break Pinned{value = 42} else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init capture completed root and field transfers retain exact native cleanup" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    weight: int
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + self.weight
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\func take(var item: Item) -> ()
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm counter: Ref(int, true)) int
        \\    const source = Pair{first = Item{counter = counter, weight = 10}, second = Item{counter = counter, weight = 20}}
        \\    const unused = materialize(if 1 == 1
        \\        take(source.first^)
        \\        42
        \\    else 0)
        \\    return unused
        \\fallible run_root(imm counter: Ref(int, true)) int
        \\    const source = Item{counter = counter, weight = 12}
        \\    const unused = materialize(if 1 == 1
        \\        take(source^)
        \\        42
        \\    else 0)
        \\    return unused
        \\fallible calculate() int
        \\    var counter = Box.new(0)
        \\    run(counter.borrow_mut())
        \\    run_root(counter.borrow_mut())
        \\    return counter.borrow()[]
        \\if const answer = calculate() -> exit(answer) else exit(99)
    , 42);
}

test "init lexical rejects caller loop exits during partial aggregate construction" {
    try Fixture.expectSourceDiagnostic(
        \\struct Marker
        \\    counter: Ref(int, true)
        \\    step: int
        \\    drop = func(deinit self: Marker)
        \\        self.counter[] = self.counter[] * 10 + self.step
        \\struct Pending
        \\    first: Marker
        \\    last: int
        \\    drop = func(deinit self: Pending) -> exit(98)
        \\fallible receive(init marker: Marker, init item: Pending) int
        \\    const held = marker
        \\    const value = item
        \\    return value.last + held.step
        \\fallible run(imm trace: Ref(int, true)) int
        \\    var pass = 0
        \\    return loop
        \\        pass = pass + 1
        \\        const caller = Marker{counter = trace, step = 3}
        \\        const unused = receive(Marker{counter = trace, step = 2}, Pending{first = Marker{counter = trace, step = 1}, last = if pass == 1 -> continue else break 42})
        \\        break unused + caller.step
        \\fallible calculate() int
        \\    var counter = Box.new(0)
        \\    const result = run(counter.borrow_mut())
        \\    if counter.borrow()[] == 123123 -> return result
        \\    return 99
        \\if const result = calculate() -> exit(result) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init capture restored roots and fields clean once after nested construction" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    weight: int
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + self.weight
        \\struct Pair
        \\    first: Item
        \\    second: Item
        \\func take(var item: Item) -> ()
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm counter: Ref(int, true)) int
        \\    var source = Pair{first = Item{counter = counter, weight = 10}, second = Item{counter = counter, weight = 15}}
        \\    const unused = materialize(materialize(if 1 == 1
        \\        take(source.first^)
        \\        source.first = Item{counter = counter, weight = 2}
        \\        42
        \\    else 0))
        \\    return unused
        \\fallible run_root(imm counter: Ref(int, true)) int
        \\    var source = Item{counter = counter, weight = 10}
        \\    const unused = materialize(materialize(if 1 == 1
        \\        take(source^)
        \\        source = Item{counter = counter, weight = 5}
        \\        42
        \\    else 0))
        \\    return unused
        \\fallible calculate() int
        \\    var counter = Box.new(0)
        \\    run(counter.borrow_mut())
        \\    run_root(counter.borrow_mut())
        \\    return counter.borrow()[]
        \\if const result = calculate() -> exit(result) else exit(99)
    , 42);
}

test "init capture mutable copyback occurs in every forwarding frame" {
    try Fixture.expectSourceExit(
        \\fallible materialize(mut value: int, init item: int) int
        \\    value = value + 1
        \\    return item
        \\fallible forward(mut value: int, init item: int) int
        \\    value = value + 1
        \\    return materialize(value, item)
        \\fallible run(mut value: int) int
        \\    return forward(value, 40)
        \\fallible calculate() int
        \\    var value = 0
        \\    const result = run(value)
        \\    return result + value
        \\static answer = if const computed = calculate() -> computed else 97
        \\if const status = calculate() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init lexical rejects caller consuming breaks selecting captured or fresh storage" {
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\func produce() Pinned -> return Pinned{value = 42}
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\fallible run(imm choose: bool) int
        \\    const source = Pinned{value = 42}
        \\    return consume(loop
        \\        const unused = materialize(if 1 == 1 -> break (if choose == true -> source else produce()) else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\static answer = if const computed = run(true) -> if const additional_computed = run(false) -> computed + additional_computed else 97 else 97
        \\if const status = run(true) -> if const additional_status = run(false) -> exit(status + additional_status + answer - 126) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects caller consuming breaks for movable and immovable region locals" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    value: int
        \\    move = trivial
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Item) int -> return item.value
        \\fallible run() int
        \\    return consume(loop
        \\        const unused = materialize(if 1 == 1
        \\            const local = Item{value = 42}
        \\            break local
        \\        else 0)
        \\        break Item{value = 99}
        \\    )
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , .initializer_exit_outside_boundary);
    try Fixture.expectSourceDiagnostic(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Pinned) int -> return item.value
        \\fallible run() int
        \\    return consume(loop
        \\        const unused = materialize(if 1 == 1
        \\            const local = Pinned{value = 42}
        \\            break local
        \\        else 0)
        \\        break Pinned{value = 99}
        \\    )
        \\if const status = run() -> exit(status) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init checkpoint nested pending handles preserve ordinary construction" {
    try Fixture.expectSourceExit(
        \\fallible materialize(init item: int) int -> return item
        \\fallible wrap(init item: int) int
        \\    return materialize(if 1 == 1
        \\        const result = item
        \\        result
        \\    else
        \\        const result = item
        \\        result
        \\    )
        \\fallible pair(init first: int, init second: int) int
        \\    const left = materialize(wrap(first))
        \\    const right = materialize(wrap(second))
        \\    return left + right
        \\fallible run() int
        \\    return wrap(42)
        \\static answer = if const computed = run() -> computed else 97
        \\static ordinary = if const computed = pair(20, 22) -> computed else 97
        \\if const status = run() -> if const additional_status = pair(20, 22) -> exit(status + answer + additional_status + ordinary - 126) else exit(97) else exit(97)
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
        \\fallible materialize(init item: int) int -> return item
        \\func consume(deinit item: Item) int -> return item.value
        \\fallible pick(deinit pair: Pair, imm root: bool) int
        \\    const source = Item{value = 42}
        \\    return consume(loop
        \\        const unused = materialize(if 1 == 1 -> break (if root == true -> source^ else pair.item^) else 0)
        \\        break Item{value = 99}
        \\    )
        \\fallible run(imm root: bool) int -> return pick(Pair{item = Item{value = 42}, other = 0}, root)
        \\static answer = if const computed = run(true) -> if const additional_computed = run(false) -> computed + additional_computed else 97 else 97
        \\if const status = run(true) -> if const additional_status = run(false) -> exit(status + additional_status + answer - 126) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical rejects nested exits while evaluating caller exit payloads" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible run() int
        \\    const unused = materialize(if 1 == 1 -> return (if 1 == 1 -> return 42 else return 42) else 0)
        \\    return unused + 100
        \\fallible loop_result() int
        \\    return loop
        \\        const unused = materialize(if 1 == 1 -> break (if 1 == 1 -> break 42 else break 42) else 0)
        \\        break unused + 100
        \\static answer = if const computed = run() -> if const additional_computed = loop_result() -> computed + additional_computed else 97 else 97
        \\if const status = run() -> if const additional_status = loop_result() -> exit(status + additional_status + answer - 126) else exit(97) else exit(97)
    , .initializer_exit_outside_boundary);
}

test "init lexical nested handle captures retain single use obligations" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible wrap(init item: int) int
        \\    const first = materialize(materialize(item))
        \\    return materialize(item)
        \\if const status = wrap(42) -> exit(status) else exit(97)
    , .initializer_already_consumed);
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible wrap(imm choose: bool, init item: int) int
        \\    return materialize(if choose == true -> materialize(item) else 42)
        \\if const status = wrap(true, 42) -> exit(status) else exit(97)
    , .initializer_not_consumed);
}

test "init checkpoint keeps static parameter cleanup in the caller" {
    try Fixture.expectSourceExit(
        \\struct Marker
        \\    value: int
        \\    drop = func(deinit self: Marker) -> exit(99)
        \\fallible materialize(init item: int) int -> return item
        \\func stop() int -> exit(42)
        \\fallible run(static marker: Marker) int
        \\    return materialize(if marker.value == 0 -> stop() else 0)
        \\if const status = run(Marker{value = 0}) -> exit(status) else exit(97)
    , 42);
}

test "init checkpoint preserves mutable copy back and finite forwarding recursion" {
    try Fixture.expectSourceExit(
        \\fallible receive(mut count: int, init item: int) int
        \\    count += 1
        \\    const value = item
        \\    return value + count
        \\fallible walk(init item: int, imm depth: int) int
        \\    if depth == 0 -> return item
        \\    return walk(item, depth - 1)
        \\fallible run() int
        \\    var count = 0
        \\    const value = receive(count, walk(40, 3))
        \\    return value + count
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init checkpoint handles zero sized and diverging construction" {
    const sources = [_][]const u8{
        \\fallible materialize(init item: unit) unit -> return item
        \\fallible run() int
        \\    const value = materialize(unit)
        \\    return 42
        \\static answer = if const computed = run() -> computed else 97
        \\exit(answer)
        ,
        \\fallible materialize(init item: never) int -> return item
        \\func stop() never -> exit(42)
        \\if const status = materialize(stop()) -> exit(status) else exit(97)
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
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\func stop() never -> exit(99)
        \\fallible run(imm flag: int) int
        \\    const value = materialize(if flag == 1
        \\        var first = 20
        \\        const second = materialize(loop -> break first + 1)
        \\        Pinned{value = second}
        \\    else
        \\        stop()
        \\        Pinned{value = 0}.missing
        \\    )
        \\    return value.value
        \\static answer = if const computed = run(1) -> computed else 97
        \\if const status = run(1) -> exit(status + answer) else exit(97)
    , 42);
}

test "init inference determines fresh immovable variants before selecting storage" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible choose(imm flag: int) int
        \\    const value = materialize(if flag == 1 -> Pinned{value = 21} else none)
        \\    if value is Pinned -> return 21 else return 0
        \\fallible leave(imm flag: int) int
        \\    const value = materialize(loop
        \\        if flag == 1 -> break Pinned{value = 21} else break none
        \\    )
        \\    if value is Pinned -> return 21 else return 0
        \\static answer = if const computed = choose(1) -> if const additional_computed = leave(1) -> computed + additional_computed else 97 else 97
        \\if const status = choose(0) -> if const additional_status = leave(0) -> exit(status + additional_status + answer) else exit(97) else exit(97)
    , 42);
}

fn checkInitializerAllocations(gpa: std.mem.Allocator, source: []const u8) !void {
    const db = try query.Database.init(gpa, .{ .worker_count = 1 });
    defer db.deinit();
    try modules.registerSources(db, gpa, source, &.{}, &.{});
    try testing.expect((try db.get(queries.BuildExecutable, 0)).* != null);
}

test "init regions release every failed allocation during inference and outlining" {
    try testing.checkAllAllocationFailures(allocation_failure_backing.allocator(), checkInitializerAllocations, .{
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible run(imm input: int) int
        \\    const unused = 0
        \\    const captured = input + 1
        \\    return forward(materialize(loop -> break captured))
        \\if const result = run(41) -> exit(result) else exit(1)
    });
}

test "init regions release every failed allocation during compile-time execution" {
    try testing.checkAllAllocationFailures(allocation_failure_backing.allocator(), checkInitializerAllocations, .{
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible run(imm input: int) int
        \\    const captured = input + 1
        \\    return forward(materialize(loop -> break captured))
        \\static answer = if const computed = run(41) -> computed else 97
        \\exit(answer)
    });
}

test "init regions release every failed allocation when materializing borrowed storage" {
    try testing.checkAllAllocationFailures(allocation_failure_backing.allocator(), checkInitializerAllocations, .{
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible run_box() int
        \\    const owner = Box.new(42)
        \\    return materialize(owner.borrow()[])
        \\if const boxed = run_box() -> exit(boxed) else exit(1)
    });
}

test "init failure propagates through ordinary generic and indirect consumers" {
    try Fixture.expectSourceExit(
        \\fallible produce(imm flag: int) int
        \\    flag == 1
        \\    return 21
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible invoke(imm callback: fallible(init int) int, init item: int) int -> return callback(item)
        \\fallible run(imm flag: int) int
        \\    if const value = invoke(forward, produce(flag)) -> return value
        \\    return 0
        \\static answer = if const computed = run(1) -> if const additional_computed = run(0) -> computed + additional_computed else 97 else 97
        \\if const status = run(1) -> if const additional_status = run(0) -> exit(status + additional_status + answer) else exit(97) else exit(97)
    , 42);
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
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: Pair) int
        \\    const guard = Guard{}
        \\    const value = item
        \\    _ = guard
        \\    return value.second
        \\if const value = materialize(Pair{first = Field{value = 1}, second = fail_value()}) -> exit(1)
        \\exit(2)
    , 42);
}

test "init failure permission does not authorize ordinary fallible statements" {
    try Fixture.expectSourceDiagnostic(
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\func materialize(init item: int) int
        \\    const unexpected = fail_value()
        \\    return item
        \\exit(materialize(42))
    , .fallible_expression_outside_fallible_function);
}

test "init failure preserves final storage and mutable copy back" {
    try Fixture.expectSourceExit(
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible produce(imm flag: int) Pinned
        \\    flag == 1
        \\    return Pinned{value = 21}
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible receive(mut count: int, init item: Pinned) int
        \\    count += 1
        \\    const value = materialize(item)
        \\    return value.value
        \\fallible run() int
        \\    var count = 0
        \\    if const unused = receive(count, produce(0)) -> return 99
        \\    if const value = receive(count, produce(1)) -> return value + count - 2
        \\    return 98
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer) else exit(97)
    , 42);
}

test "init failure still permits skipped construction on earlier consumer failure" {
    try Fixture.expectSourceExit(
        \\fallible unwanted() int -> exit(99)
        \\fallible skip(init item: int) int
        \\    1 == 0
        \\    return item
        \\fallible run() int
        \\    if const value = skip(unwanted()) -> return value
        \\    return 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init failure partial cleanup has compile time parity" {
    const f = try Fixture.init(
        \\struct Field
        \\    value: int
        \\    drop = func(deinit self: Field) -> exit(42)
        \\struct Pair
        \\    move = none
        \\    first: Field
        \\    second: int
        \\    drop = func(deinit self: Pair) -> exit(99)
        \\fallible fail_value() int
        \\    1 == 0
        \\    return 0
        \\fallible materialize(init item: Pair) Pair -> return item
        \\fallible run() int
        \\    if const value = materialize(Pair{first = Field{value = 1}, second = fail_value()}) -> return value.second
        \\    return 98
        \\static stopped = if const computed = run() -> computed else 97
    , &.{});
    defer f.deinit();
    const item = (try f.db.get(queries.BuildModuleScope, 0)).*.?.resolveStatic("stopped").?;
    try testing.expect((try f.db.get(queries.ResolveStatic, item)).* == null);
    const controls = try f.db.transitiveAccumulatorValues(queries.ResolveStatic, item, structures.CompilerControl, testing.allocator);
    defer testing.allocator.free(controls);
    try testing.expectEqualSlices(structures.CompilerControl, &.{.{ .exit = 42 }}, controls);
}

test "init failure edits recompute the caller while retaining the consumer" {
    const source =
        \\fallible produce(imm flag: int) int
        \\    flag == 1
        \\    return 21
        \\fallible materialize(init item: int) int -> return item
        \\fallible run(imm flag: int) int
        \\    return materialize(if const value = produce(flag) -> value else 0)
        \\func observe() int
        \\    if const value = run(0) -> return 42
        \\    return 41
        \\static answer = observe()
        \\exit(observe() + answer - 42)
    ;
    const f = try Fixture.init(source, &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
    const item = (try f.db.get(queries.BuildModuleScope, 0)).*.?.resolveFunction("materialize").?;
    const body = try f.db.get(queries.AnalyzeFunctionInstance, .{ .item = item });
    const compiled = try f.db.get(queries.CompileFunction, .{ .item = item });
    const edited = try std.mem.replaceOwned(u8, testing.allocator, source, "if const value = produce(flag) -> value else 0", "produce(flag)");
    defer testing.allocator.free(edited);
    try f.db.setInput(queries.SourceText, 0, edited);
    try f.expectExit(0, 40);
    try testing.expectEqual(body, try f.db.get(queries.AnalyzeFunctionInstance, .{ .item = item }));
    try testing.expectEqual(compiled, try f.db.get(queries.CompileFunction, .{ .item = item }));
    try f.db.setInput(queries.SourceText, 0, source);
    try f.expectExit(0, 42);
}

test "init captures reject reference writes and implicit cleanup across eager arguments" {
    const expressions = [_][]const u8{
        "if 1 == 1\n        reference[] = 7\n        0\n    else 0",
        "change(reference)",
        "if 1 == 1\n        const guard = Guard{target = reference}\n        0\n    else 0",
        "copy_effect(Hook{target = reference})",
        "if 1 == 1\n        const hook = Hook{target = reference}\n        copy_effect(hook)\n    else 0",
        "if 1 == 1\n        const hook = Hook{target = reference}\n        move_effect(hook^)\n    else 0",
    };
    for (expressions) |expression| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Guard
            \\    target: Ref(int, true)
            \\    drop = func(deinit self: Guard)
            \\        self.target[] = 7
            \\struct Hook
            \\    target: Ref(int, true)
            \\    copy = func(imm self: Hook) Hook
            \\        self.target[] = 7
            \\        return Hook{target = self.target}
            \\    move = func(deinit self: Hook) Hook
            \\        self.target[] = 7
            \\        return Hook{target = self.target}
            \\func copy_effect(var hook: Hook) int -> return 0
            \\func move_effect(var hook: Hook) int -> return 0
            \\func change(imm reference: Ref(int, true)) int
            \\    reference[] = 7
            \\    return 0
            \\fallible receive(init item: int, imm eager: int) int -> return item
            \\fallible run() int
            \\    var owner = Box.new(42)
            \\    const reference = owner.borrow_mut()
            \\    return receive(owner.borrow()[], $expression)
            \\if const value = run() -> exit(value) else exit(1)
        , .{ .expression = expression });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .initializer_capture_conflict);
    }
}

test "init captures read owned storage through checked internal references" {
    try Fixture.expectSourceExit(
        \\fallible receive(init item: int) int -> return item
        \\fallible read_parameter(imm owner: Box(int)) int -> return receive(owner.borrow()[])
        \\fallible run() int
        \\    const owner = Box.new(42)
        \\    return receive(owner.borrow()[]) + read_parameter(owner) - 42
        \\if const value = run() -> exit(value) else exit(1)
    , 42);
}

test "init failure handles unit and never outcomes" {
    const sources = [_][]const u8{
        \\fallible fail_value() unit
        \\    1 == 0
        \\fallible materialize(init item: unit) unit -> return item
        \\fallible run() int
        \\    if materialize(fail_value()) -> return 99
        \\    return 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
        ,
        \\fallible fail_value() never
        \\    1 == 0
        \\    exit(99)
        \\fallible materialize(init item: never) int -> return item
        \\fallible run() int
        \\    if materialize(fail_value()) -> return 98
        \\    return 42
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    };
    for (sources) |source| {
        try Fixture.expectSourceExit(source, 42);
    }
}

test "init captures allow unrelated reference effects and writes after construction" {
    try Fixture.expectSourceExit(
        \\struct Guard
        \\    target: Ref(int, true)
        \\    drop = func(deinit self: Guard)
        \\        self.target[] = 7
        \\fallible receive(init item: int, imm eager: int) int -> return item
        \\fallible run() int
        \\    var owner = Box.new(42)
        \\    var other = Box.new(0)
        \\    const reference = owner.borrow_mut()
        \\    const changed = other.borrow_mut()
        \\    const result = receive(owner.borrow()[], if 1 == 1
        \\        const guard = Guard{target = changed}
        \\        0
        \\    else 0)
        \\    reference[] = 99
        \\    return result + other.borrow()[] - 7
        \\if const value = run() -> exit(value) else exit(1)
    , 42);
}

test "init comptime cycle checks recognize fresh environments with the same values" {
    try Fixture.expectSourceDiagnostic(
        \\fallible repeat(init item: int) int
        \\    const value = item
        \\    return repeat(value)
        \\static answer = if const computed = repeat(42) -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init comptime cycle checks permit fresh environments with changing values" {
    try Fixture.expectSourceExit(
        \\fallible walk(init item: int) int
        \\    const value = item
        \\    if value == 0 -> return 42
        \\    return walk(value - 1)
        \\static answer = if const computed = walk(3) -> computed else 97
        \\if const status = walk(3) -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init comptime cycle checks detect repeated nested wrapped captures" {
    try Fixture.expectSourceDiagnostic(
        \\fallible materialize(init item: int) int -> return item
        \\fallible repeat(imm depth: int, init item: int) int
        \\    if depth == 0 -> return repeat(depth, item)
        \\    return repeat(depth - 1, materialize(item))
        \\static answer = if const computed = repeat(3, 42) -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init comptime cycle checks compare fresh aggregate inputs by value" {
    try Fixture.expectSourceDiagnostic(
        \\struct State
        \\    first: int
        \\    second: int
        \\    third: int
        \\fallible repeat(init item: int, imm state: State) int
        \\    return repeat(item, State{first = state.first, second = state.second, third = state.third})
        \\static answer = if const computed = repeat(42, State{first = 1, second = 2, third = 3}) -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init comptime cycle checks snapshot changing mutable aggregate inputs" {
    try Fixture.expectSourceExit(
        \\struct State
        \\    remaining: int
        \\    second: int
        \\    third: int
        \\fallible walk(mut state: State, init item: int) int
        \\    if state.remaining == 0 -> return item
        \\    state.remaining -= 1
        \\    return walk(state, item)
        \\fallible run() int
        \\    var state = State{remaining = 3, second = 0, third = 0}
        \\    return walk(state, 42) + state.remaining
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
    , 42);
}

test "init inference supports deeply nested generic immovable construction" {
    var expression = try testing.allocator.dupe(u8, "Pinned{value = 21}");
    defer testing.allocator.free(expression);
    for (0..16) |_| {
        const nested = try std.fmt.allocPrint(testing.allocator, "materialize({s})", .{expression});
        testing.allocator.free(expression);
        expression = nested;
    }
    const source = try test_sources.renderTemplate(testing.allocator,
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible run() int
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
        \\func change(imm reference: Ref(int, true)) int
        \\    reference[] = 7
        \\    return 0
        \\fallible receive(init item: int, imm eager: int) int -> return item
        \\fallible relay(imm owner: Box(int), imm reference: Ref(int, true)) int
        \\    return receive(owner.borrow()[], change(reference))
        \\fallible run() int
        \\    var owner = Box.new(42)
        \\    const reference = owner.borrow_mut()
        \\    return relay(owner, reference)
        \\if const value = run() -> exit(value) else exit(1)
    , .initializer_capture_conflict);
}

test "init captures reject cleanup through possibly aliased borrowed parameters" {
    try Fixture.expectSourceDiagnostic(
        \\struct Guard
        \\    target: Ref(int, true)
        \\    drop = func(deinit self: Guard)
        \\        self.target[] = 7
        \\fallible receive(init item: int, imm eager: int) int -> return item
        \\fallible relay(imm owner: Box(int), imm reference: Ref(int, true)) int
        \\    return receive(owner.borrow()[], if 1 == 1
        \\        const guard = Guard{target = reference}
        \\        0
        \\    else 0)
        \\fallible run() int
        \\    var owner = Box.new(42)
        \\    const reference = owner.borrow_mut()
        \\    return relay(owner, reference)
        \\if const value = run() -> exit(value) else exit(1)
    , .initializer_capture_conflict);
}

test "init captures permit scalar parameter copies beside reference writes" {
    try Fixture.expectSourceExit(
        \\func change(imm reference: Ref(int, true)) int
        \\    reference[] = 7
        \\    return 0
        \\fallible receive(init item: int, imm eager: int) int -> return item
        \\fallible relay(imm value: int, imm reference: Ref(int, true)) int
        \\    return receive(value, change(reference))
        \\fallible run() int
        \\    var owner = Box.new(42)
        \\    const reference = owner.borrow_mut()
        \\    return relay(owner.borrow()[], reference)
        \\if const value = run() -> exit(value) else exit(1)
    , 42);
}

test "init captures preserve booleans callables and aggregate storage" {
    try Fixture.expectSourceExit(
        \\struct Payload
        \\    first: int
        \\    second: int
        \\    third: int
        \\func increment(imm value: int) int -> return value + 1
        \\fallible materialize(static T: type, init item: T) T -> return item
        \\fallible run(imm flag: bool, imm callback: func(int) int) int
        \\    const payload = Payload{first = 20, second = 21, third = 1}
        \\    const saved = materialize(callback)
        \\    const stable = materialize(flag)
        \\    return materialize(if stable == true -> saved(payload.first + payload.second) else 0)
        \\static answer = if const computed = run(true, increment) -> computed else 97
        \\if const status = run(true, increment) -> if const additional_status = run(false, increment) -> exit(status + additional_status + answer - 42) else exit(97) else exit(97)
    , 42);
}

test "init handled failure preserves guarded root and field cleanup on receiver success" {
    const Case = struct { type_name: []const u8, initializer: []const u8, transfer: []const u8, expected: u8 };
    const cases = [_]Case{
        .{ .type_name = "Item", .initializer = "Item{counter = counter.borrow_mut(), weight = 10}", .transfer = "source^", .expected = 10 },
        .{ .type_name = "Pair", .initializer = "Pair{first = Item{counter = counter.borrow_mut(), weight = 10}, second = Item{counter = counter.borrow_mut(), weight = 32}}", .transfer = "source.first^", .expected = 42 },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Item
            \\    counter: Ref(int, true)
            \\    weight: int
            \\    copy = none
            \\    drop = func(deinit self: Item)
            \\        self.counter[] = self.counter[] + self.weight
            \\struct Pair
            \\    first: Item
            \\    second: Item
            \\fallible fail_value() never
            \\    1 == 0
            \\    exit(99)
            \\fallible materialize(init item: int) int -> return item
            \\fallible forward(init item: int) int -> return materialize(item)
            \\fallible receive(init item: int) int
            \\    if const result = forward(item) -> return result else return 0
            \\fallible run(imm flag: bool) int
            \\    var counter = Box.new(0)
            \\    const source: $type_name = $initializer
            \\    const callback: fallible(init int) int = receive
            \\    if const result = callback(if flag == true
            \\        const moved = $transfer
            \\        fail_value()
            \\        0
            \\    else 0) -> () else return 99
            \\    return counter.borrow()[]
            \\fallible calculate() int
            \\    const transferred = run(true)
            \\    const retained = run(false)
            \\    if transferred == retained -> return retained else return 97
            \\if const result = calculate() -> exit(result) else exit(98)
        , .{ .type_name = case.type_name, .initializer = case.initializer, .transfer = case.transfer });
        defer testing.allocator.free(source);
        try Fixture.expectSourceExit(source, case.expected);
    }
}

test "init handled failure cannot restore transferred capture access on receiver success" {
    const transfers = [_][]const u8{ "source^", "source.first^" };
    const sources = [_][]const u8{ "const source = 42", "const source = Pair{first = 42}" };
    const reads = [_][]const u8{ "source", "source.first" };
    for (transfers, sources, reads) |transfer, binding, read| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Pair
            \\    first: int
            \\fallible fail_value() never
            \\    1 == 0
            \\    exit(99)
            \\fallible materialize(init item: int) int -> return item
            \\fallible receive(init item: int) int
            \\    if const result = materialize(item) -> return result else return 0
            \\fallible run(imm flag: bool) int
            \\    $binding
            \\    if const result = receive(if flag == true
            \\        const moved = $transfer
            \\        fail_value()
            \\        0
            \\    else 0) -> return $read + result else return 99
            \\if const status = run(true) -> exit(status) else exit(97)
        , .{ .binding = binding, .transfer = transfer, .read = read });
        defer testing.allocator.free(source);
        try Fixture.expectSourceDiagnostic(source, .possibly_transferred);
    }
}

test "init comptime cycle checks materialize aggregate and variant captures" {
    const sources = [_][]const u8{
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible walk(imm remaining: int, init item: int) int
        \\    if remaining == 0 -> return item
        \\    return walk(remaining - 1, item)
        \\fallible run() int
        \\    const owner = Pinned{value = 42}
        \\    return walk(2, owner.value)
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
        ,
        \\struct Pinned
        \\    value: int
        \\    move = none
        \\    copy = none
        \\fallible walk(imm remaining: int, init item: int) int
        \\    if remaining == 0 -> return item
        \\    return walk(remaining - 1, item)
        \\fallible run() int
        \\    const owner: Pinned | none = Pinned{value = 42}
        \\    return walk(2, if owner is Pinned -> 42 else 0)
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
        ,
        \\struct Empty
        \\    move = none
        \\    copy = trivial
        \\fallible walk(imm remaining: int, init item: Empty) int
        \\    if remaining == 0
        \\        const value = item
        \\        return 42
        \\    return walk(remaining - 1, item)
        \\fallible run() int
        \\    const owner = Empty{}
        \\    return walk(2, owner)
        \\static answer = if const computed = run() -> computed else 97
        \\if const status = run() -> exit(status + answer - 42) else exit(97)
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
        \\fallible repeat(init item: int) int -> return repeat(item)
        \\fallible run() int
        \\    const owner = Pinned{value = 42}
        \\    return repeat(owner.value)
        \\static answer = if const computed = run() -> computed else 97
        \\exit(answer)
    , .compile_time_call_cycle);
}

test "init handled forwarding failure retains skipped capture cleanup on receiver success" {
    try Fixture.expectSourceExit(
        \\struct Item
        \\    counter: Ref(int, true)
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + 10
        \\fallible forward(init item: Item, imm construct: bool) int
        \\    construct == true
        \\    const value = item
        \\    return 0
        \\fallible receive(init item: Item, imm construct: bool) int
        \\    if const result = forward(item, construct) -> return result else return 0
        \\fallible run(imm construct: bool) int
        \\    var counter = Box.new(0)
        \\    const source = Item{counter = counter.borrow_mut()}
        \\    const result = receive(source^, construct)
        \\    return counter.borrow()[] + result
        \\fallible calculate() int
        \\    const constructed = run(true)
        \\    const skipped = run(false)
        \\    if constructed == 10 -> return constructed + skipped + 22 else return 97
        \\if const result = calculate() -> exit(result) else exit(98)
    , 42);
}

test "init handled forwarding failure leaves skipped and transferred access joined" {
    try Fixture.expectSourceDiagnostic(
        \\fallible forward(init item: int, imm construct: bool) int
        \\    construct == true
        \\    return item
        \\fallible receive(init item: int, imm construct: bool) int
        \\    if const result = forward(item, construct) -> return result else return 0
        \\fallible run(imm construct: bool) int
        \\    const source = 42
        \\    const result = receive(source^, construct)
        \\    return source + result
        \\if const status = run(false) -> exit(status) else exit(97)
    , .possibly_transferred);
}

test "allocating init callable acquisition preserves field capability diagnostics" {
    try Fixture.expectSourceDiagnostic(
        \\struct Item
        \\    move = trivial
        \\    reference: Ref(int, false)
        \\const callback: fallible(init Item) Box(Item) = Box(Item).new
        \\exit(42)
    , .struct_ownership_property_incompatible_with_fields);
}

test "init milestone1 rejects caller exits across direct aliased forwarded and indirect boundaries" {
    const cases = [_]struct { declaration: []const u8, setup: []const u8, call: []const u8 }{
        .{ .declaration = "", .setup = "", .call = "materialize" },
        .{ .declaration = "static alias = materialize", .setup = "", .call = "alias" },
        .{ .declaration = "fallible forward(init item: int) int -> return materialize(item)", .setup = "", .call = "forward" },
        .{ .declaration = "", .setup = "const callback: fallible(init int) int = materialize", .call = "callback" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "return 42", "break 42", "continue" }) |exit_statement| {
            const source = try test_sources.renderTemplate(testing.allocator,
                \\fallible materialize(init item: int) int -> return item
                \\$declaration
                \\fallible run() int
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
        .{ .declaration = "fallible forward(init item: int, imm eager: int) int -> return receive(item, eager)", .setup = "", .call = "forward" },
        .{ .declaration = "", .setup = "const callback: fallible(init int, int) int = receive", .call = "callback" },
    };
    for (cases) |case| {
        for ([_][]const u8{ "return 42", "break 42", "continue" }) |exit_statement| {
            const source = try test_sources.renderTemplate(testing.allocator,
                \\func forbidden() int -> exit(99)
                \\fallible receive(init item: int, imm eager: int) int
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
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible run() int
        \\    const producer: func() int = produce
        \\    const callback: fallible(init int) int = forward
        \\    return callback(loop
        \\        var count = 0
        \\        loop
        \\            count += 1
        \\            if count == 2 -> break
        \\            continue
        \\        break producer()
        \\    )
        \\static answer = if const result = run() -> result else 99
        \\if const result = run() -> exit(result + answer - 42) else exit(98)
    , 42);
}

test "init milestone1 explicit fail is handled and propagated with native and comptime parity" {
    try Fixture.expectSourceExit(
        \\fallible fail_value() int -> fail
        \\fallible materialize(init item: int) int -> return item
        \\fallible forward(init item: int) int -> return materialize(item)
        \\fallible propagate() int -> return forward(fail_value())
        \\func handled() int
        \\    const callback: fallible(init int) int = forward
        \\    if const unused = callback(if 1 == 1 -> fail else 0) -> return 99
        \\    if const unused = propagate() -> return 98
        \\    if const unused = fail_value() -> return 97
        \\    return 42
        \\static answer = handled()
        \\exit(handled() + answer - 42)
    , 42);
}

test "init milestone1 pending root and field consumption cleans exactly once on failure" {
    const cases = [_]struct { binding: []const u8, place: []const u8 }{
        .{ .binding = "const source = Item{counter = trace, weight = 42}", .place = "source" },
        .{ .binding = "const source = Pair{first = Item{counter = trace, weight = 21}, second = Item{counter = trace, weight = 21}}", .place = "source.first" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\struct Item
            \\    counter: Ref(int, true)
            \\    weight: int
            \\    copy = none
            \\    drop = func(deinit self: Item)
            \\        self.counter[] = self.counter[] + self.weight
            \\struct Pair
            \\    first: Item
            \\    second: Item
            \\func dispose(var item: Item) -> ()
            \\func consume(deinit item: Item, imm eager: int) int
            \\    const value = item.weight
            \\    dispose(item^)
            \\    return value + eager
            \\fallible fail_value() int -> fail
            \\fallible forward(init item: int) int -> return item
            \\fallible receive(init item: int) int
            \\    const value = forward(item)
            \\    fail
            \\func attempt(imm trace: Ref(int, true), imm complete: bool)
            \\    $binding
            \\    const callback: fallible(init int) int = receive
            \\    if const unused = callback(consume($place, if complete == true -> 0 else fail_value())) -> exit(99)
            \\fallible run(imm complete: bool) int
            \\    var counter = Box.new(0)
            \\    attempt(counter.borrow_mut(), complete)
            \\    return counter.borrow()[]
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

test "init milestone1 raw allocation failure destroys completed elements and releases both allocations" {
    try Fixture.expectSourceExit(
        \\import std.memory.{allocate, deallocate, unsafe_initialize, unsafe_destroy}
        \\struct Item
        \\    counter: Ref(int, true)
        \\    weight: int
        \\    move = none
        \\    copy = none
        \\    drop = func(deinit self: Item)
        \\        self.counter[] = self.counter[] + self.weight
        \\fallible fail_value() int -> fail
        \\fallible attempt(imm trace: Ref(int, true))
        \\    var separate = Box.new(0)
        \\    var first = allocate(Item, 2)
        \\    var second = if const storage = allocate(Item, 1) -> storage^
        \\    else
        \\        deallocate(Item, first^)
        \\        fail
        \\    if unsafe_initialize(Item, first, 0, Item{counter = trace, weight = 10}) -> ()
        \\    else
        \\        deallocate(Item, second^)
        \\        deallocate(Item, first^)
        \\        fail
        \\    if unsafe_initialize(Item, second, 0, Item{counter = trace, weight = 20}) -> ()
        \\    else
        \\        unsafe_destroy(Item, first, 0)
        \\        deallocate(Item, second^)
        \\        deallocate(Item, first^)
        \\        fail
        \\    if unsafe_initialize(Item, first, 1, Item{counter = separate.borrow_mut(), weight = fail_value()})
        \\        unsafe_destroy(Item, first, 1)
        \\        unsafe_destroy(Item, second, 0)
        \\        unsafe_destroy(Item, first, 0)
        \\        deallocate(Item, second^)
        \\        deallocate(Item, first^)
        \\        _ = separate
        \\        exit(99)
        \\    unsafe_destroy(Item, second, 0)
        \\    unsafe_destroy(Item, first, 0)
        \\    deallocate(Item, second^)
        \\    deallocate(Item, first^)
        \\    _ = separate
        \\    fail
        \\fallible run() int
        \\    var counter = Box.new(0)
        \\    if attempt(counter.borrow_mut()) -> return 98
        \\    return counter.borrow()[] + 12
        \\if const result = run() -> exit(result) else exit(97)
    , 42);
}

test "init milestone1 signature and forbidden exit edits recompute acceptance" {
    const source =
        \\func materialize(init item: int) int -> return item
        \\fallible run() int -> return materialize(42)
        \\if const result = run() -> exit(result) else exit(99)
    ;
    const fixture = try Fixture.init(source, &.{});
    defer fixture.deinit();
    try fixture.expectDiagnostic(0, .fallible_expression_outside_fallible_function);
    const declared = try std.mem.replaceOwned(u8, testing.allocator, source, "func materialize", "fallible materialize");
    defer testing.allocator.free(declared);
    try fixture.db.setInput(queries.SourceText, 0, declared);
    try fixture.expectExit(0, 42);
    try fixture.db.setInput(queries.SourceText, 0, source);
    try fixture.expectDiagnostic(0, .fallible_expression_outside_fallible_function);
    for ([_][]const u8{ "return 42", "break 42", "continue" }) |exit_statement| {
        const forbidden = try test_sources.renderTemplate(testing.allocator,
            \\fallible materialize(init item: int) int -> return item
            \\fallible run() int
            \\    return loop
            \\        const value = materialize(if 1 == 1 -> $exit_statement else 0)
            \\        break value
            \\if const result = run() -> exit(result) else exit(99)
        , .{ .exit_statement = exit_statement });
        defer testing.allocator.free(forbidden);
        try fixture.db.setInput(queries.SourceText, 0, forbidden);
        try fixture.expectDiagnostic(0, .initializer_exit_outside_boundary);
        const expression = try std.fmt.allocPrint(testing.allocator, "if 1 == 1 -> {s} else 0", .{exit_statement});
        defer testing.allocator.free(expression);
        const allowed = try std.mem.replaceOwned(u8, testing.allocator, forbidden, expression, "42");
        defer testing.allocator.free(allowed);
        try fixture.db.setInput(queries.SourceText, 0, allowed);
        try fixture.expectExit(0, 42);
    }
}

test "init milestone1 ownership hooks cannot consume potentially failing initializers" {
    const cases = [_]struct { hook: []const u8, parameter: []const u8, result: []const u8, body: []const u8, operation: []const u8 }{
        .{ .hook = "copy", .parameter = "imm", .result = " Item", .body = "return Item{value = constructed}", .operation = "const copied = source\n    return copied.value" },
        .{ .hook = "move", .parameter = "deinit", .result = " Item", .body = "return Item{value = constructed}", .operation = "const moved = source^\n    return moved.value" },
        .{ .hook = "drop", .parameter = "deinit", .result = "", .body = "_ = constructed", .operation = "return 42" },
    };
    for (cases) |case| {
        const source = try test_sources.renderTemplate(testing.allocator,
            \\fallible materialize(init item: int) int -> return item
            \\struct Item
            \\    value: int
            \\    $hook = func($parameter self: Item)$result
            \\        const constructed = materialize(42)
            \\        $body
            \\func run() int
            \\    const source = Item{value = 42}
            \\    $operation
            \\exit(run())
        , .{ .hook = case.hook, .parameter = case.parameter, .result = case.result, .body = case.body, .operation = case.operation });
        defer testing.allocator.free(source);
        errdefer std.debug.print("ownership hook: {s}\n", .{case.hook});
        try Fixture.expectSourceDiagnostic(source, .fallible_expression_outside_fallible_function);
    }
}
