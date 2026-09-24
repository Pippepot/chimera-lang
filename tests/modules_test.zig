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

test "standard prelude exports are available without an explicit import" {
    const f = try Fixture.init("exit(example())", &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "an explicit empty prelude import suppresses the default inclusion" {
    const f = try Fixture.init("import std.prelude.{}\nexit(example())", &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .unknown_function);
}

test "an explicit empty prelude import also suppresses exit" {
    const f = try Fixture.init("import std.prelude.{}\nexit(42)", &.{});
    defer f.deinit();
    try f.expectDiagnostic(0, .unknown_function);
}

test "an explicit prelude import replaces the default selection" {
    const f = try Fixture.init("import std.prelude.{example}\nimport std.exit.{exit}\nexit(example())", &.{});
    defer f.deinit();
    try f.expectExit(0, 42);
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

    try db.setInput(queries.SourceText, exit_file, standard_library.exit);
    const f: Fixture = .{ .db = db };
    try f.expectExit(0, 42);
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

test "current module declarations shadow default prelude exports" {
    const f = try Fixture.init("func example() int -> return 7\nexit(example())", &.{});
    defer f.deinit();
    try f.expectExit(0, 7);
}

test "prelude resolution is retained across user source and module changes" {
    const db = try query.Database.init(testing.allocator, .{ .worker_count = 2 });
    defer db.deinit();
    var registry: modules.SourceRegistry = .{};
    defer registry.deinit(testing.allocator);
    try registry.update(db, testing.allocator, "exit(example())", &.{}, &.{});
    const resolved = try db.get(queries.ResolvePreludeImports, {});

    try registry.update(db, testing.allocator, "import user\nexit(example())", &.{.{
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
        \\  static answer = 42
        \\  func identity(static T: type, imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
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
    const file = modules.SourceFile{ .path = "shapes/a.chi", .module_path = "shapes", .source = "pub struct Box(T: type, amount: int)\n  static answer = amount\n  func make() T -> return answer" };
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
        \\  func copy() int -> return answer
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
        \\  func make(imm value: T) T -> return value + offset
        \\  func identity(static U: type, imm value: U) U -> return value + 1
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
        \\  struct Inner
        \\    value: T
        \\    func make(imm value: T) T -> return value
    }});
    defer f.deinit();
    try f.expectExit(0, 42);
}

test "factories inside struct namespaces discover their generated namespace members" {
    const f = try Fixture.init("import lib\nexit(lib.Factory.Box(int).make())", &.{.{ .path = "lib/a.chi", .module_path = "lib", .source =
        \\pub struct Factory
        \\  struct Box(T: type)
        \\    value: T
        \\    static answer = 42
        \\    func make() T -> return answer
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
