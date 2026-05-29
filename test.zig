const std = @import("std");
const testing = std.testing;
const parser = @import("parser.zig");
const query = @import("query.zig");
const runtime = @import("runtime.zig");
const writeProgram = runtime.writeProgram;

fn expectCompileOk(db: *query.QueryDb, source_id: query.SourceId) ![]const u8 {
    const result = try db.compileResult(source_id);
    try testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try testing.expect(result.bytes != null);
    return result.bytes.?;
}

fn expectCompileErrorContains(db: *query.QueryDb, source_id: query.SourceId, text: []const u8) !void {
    const result = try db.compileResult(source_id);
    try testing.expect(result.bytes == null);
    try testing.expect(result.diagnostics.len > 0);
    try testing.expect(std.mem.indexOf(u8, result.diagnostics[0].message, text) != null);
}

fn runTestCapture(source: []const u8, args: []const []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, source);
    const prog_bytes = try expectCompileOk(&db, 0);

    writeProgram(io, prog_bytes);
    defer std.Io.Dir.cwd().deleteFile(io, "prog") catch {};

    var argv = try std.ArrayList([]const u8).initCapacity(testing.allocator, 1 + args.len);
    defer argv.deinit(testing.allocator);
    argv.appendAssumeCapacity("./prog");
    for (args) |a| argv.appendAssumeCapacity(a);

    const result = try std.process.run(testing.allocator, io, .{
        .argv = argv.items,
    });
    defer testing.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try testing.expectEqual(@as(u8, 0), code),
        else => return error.TestFailed,
    }

    return result.stdout;
}

fn testProgram(source: []const u8, expected: []const u8) !void {
    try testProgramArgs(source, expected, &.{});
}

fn testProgramArgs(source: []const u8, expected: []const u8, args: []const []const u8) !void {
    const out = try runTestCapture(source, args);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "parser builds declaration-root module" {
    const src =
        \\comptime Vec2 = struct
        \\  x: int
        \\  y: int
        \\
        \\comptime main = func() int
        \\  return 0
    ;

    var parsed = try parser.parseOwned(src, testing.allocator);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 2), parsed.root.decls.len);
    try testing.expect(parsed.root.decls[0].* == .comptime_struct);
    try testing.expect(parsed.root.decls[1].* == .comptime_func);
}

test "top-level call expression executes as entry point" {
    try testProgram(
        \\comptime foo = func() unit
        \\  print(34)
        \\foo()
    , "34\n");
}

test "compile emits ELF executable bytes" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "0");
    const elf = try expectCompileOk(&db, 0);

    try testing.expect(elf.len >= 64);
    try testing.expectEqual(@as(u8, 0x7f), elf[0]);
    try testing.expectEqual(@as(u8, 'E'), elf[1]);
    try testing.expectEqual(@as(u8, 'L'), elf[2]);
    try testing.expectEqual(@as(u8, 'F'), elf[3]);
}

test "resolver duplicate symbol" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime foo = func() int
        \\  return 0
        \\
        \\comptime foo = func() int
        \\  return 1
    );
    try expectCompileErrorContains(&db, 0, "duplicate symbol");
}

test "resolver unknown symbol" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(missing_name)");
    try expectCompileErrorContains(&db, 0, "unknown symbol");
}

test "multi-function calls and arithmetic" {
    try testProgram(
        \\comptime add = func(a: int, b: int) int
        \\  return a + b
        \\
        \\comptime mul = func(a: int, b: int) int
        \\  return a * b
        \\
        \\comptime main = func() int
        \\  print(add(2, 3))
        \\  print(mul(4, 5))
        \\  return 0
    , "5\n20\n");
}

test "first-class function value bind and call" {
    try testProgram(
        \\comptime add1 = func(x: int) int
        \\  return x + 1
        \\
        \\comptime main = func() int
        \\  const f = add1
        \\  print(f(41))
        \\  return 0
    , "42\n");
}

test "first-class function value pass return call" {
    try testProgram(
        \\comptime add1 = func(x: int) int
        \\  return x + 1
        \\
        \\comptime apply = func(f: func(int) int, x: int) int
        \\  return f(x)
        \\
        \\comptime ret_add1 = func() func(int) int
        \\  return add1
        \\
        \\comptime main = func() int
        \\  const f = ret_add1()
        \\  print(apply(f, 41))
        \\  return 0
    , "42\n");
}

test "if fallible semantics in top-level body" {
    try testProgram(
        \\if 3 < 4
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
}

test "typecheck call arity mismatch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime add = func(a: int, b: int) int
        \\  return a + b
        \\
        \\comptime main = func() int
        \\  return add(1)
    );
    try expectCompileErrorContains(&db, 0, "call argument count mismatch");
}

test "typecheck call argument type mismatch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime add = func(a: int, b: int) int
        \\  return a + b
        \\
        \\comptime main = func() int
        \\  return add(1, 2.0)
    );
    try expectCompileErrorContains(&db, 0, "call argument type mismatch");
}

test "typecheck return mismatch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime main = func() int
        \\  return 1.0
    );
    try expectCompileErrorContains(&db, 0, "return type mismatch");
}

test "monomorphize stage produces deterministic unique entries" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime a = func() int
        \\  return 1
        \\
        \\comptime b = func() int
        \\  return a()
        \\
        \\comptime main = func() int
        \\  return b()
    );

    const mono = try db.monomorphizedProgram(0);
    try testing.expect(mono != null);
    try testing.expectEqual(@as(usize, 3), mono.?.functions.items.len);

    const mono_again = try db.monomorphizedProgram(0);
    try testing.expect(mono_again != null);
    try testing.expectEqual(@as(usize, 3), mono_again.?.functions.items.len);
}

test "query cache hits within same revision includes resolve and monomorphize" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "0");
    _ = try db.parsedAst(0);
    _ = try db.resolvedAst(0);
    _ = try db.typedAst(0);
    _ = try db.monomorphizedProgram(0);
    _ = try db.loweredProgram(0);
    _ = try expectCompileOk(&db, 0);

    db.resetStats();

    _ = try db.parsedAst(0);
    _ = try db.resolvedAst(0);
    _ = try db.typedAst(0);
    _ = try db.monomorphizedProgram(0);
    _ = try db.loweredProgram(0);
    _ = try expectCompileOk(&db, 0);

    const stats = db.statsSnapshot();
    try testing.expectEqual(@as(usize, 1), stats.parse_hits);
    try testing.expectEqual(@as(usize, 1), stats.resolve_hits);
    try testing.expectEqual(@as(usize, 1), stats.type_hits);
    try testing.expectEqual(@as(usize, 1), stats.mono_hits);
    try testing.expectEqual(@as(usize, 1), stats.lower_hits);
    try testing.expectEqual(@as(usize, 1), stats.compile_hits);
}

test "source change invalidates all stages" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "0");
    _ = try expectCompileOk(&db, 0);

    db.resetStats();

    try db.setSource(0, "1");
    _ = try expectCompileOk(&db, 0);

    const stats = db.statsSnapshot();
    try testing.expectEqual(@as(usize, 1), stats.parse_recomputes);
    try testing.expectEqual(@as(usize, 1), stats.resolve_recomputes);
    try testing.expectEqual(@as(usize, 1), stats.type_recomputes);
    try testing.expectEqual(@as(usize, 1), stats.mono_recomputes);
    try testing.expectEqual(@as(usize, 1), stats.lower_recomputes);
    try testing.expectEqual(@as(usize, 1), stats.compile_recomputes);
}

test "compile changed_at backdates on equal output" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "5");
    _ = try expectCompileOk(&db, 0);
    const changed_before = db.changedAt(.compile, 0) orelse return error.TestFailed;

    try db.setSource(0, "5\n");
    _ = try expectCompileOk(&db, 0);
    const changed_after = db.changedAt(.compile, 0) orelse return error.TestFailed;

    try testing.expectEqual(changed_before, changed_after);
}

test "debug query diagnostics format includes resolve and monomorphize" {
    var buf = try std.ArrayList(u8).initCapacity(testing.allocator, 256);
    defer buf.deinit(testing.allocator);

    const stats = query.QueryStats{
        .revision = 7,
        .source_sets = 2,
        .parse_hits = 3,
        .resolve_hits = 4,
        .type_hits = 5,
        .mono_hits = 6,
        .compile_recomputes = 1,
        .dependency_checks = 5,
    };
    try query.appendQueryDiagnostics(&buf, testing.allocator, stats);

    try testing.expect(std.mem.indexOf(u8, buf.items, ";   parse: hits=3 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   resolve: hits=4 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   type: hits=5 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   monomorphize: hits=6 recomputes=0") != null);
}

test "arg builtin still works at top level" {
    try testProgramArgs(
        \\print(arg(1))
    , "42\n", &.{"42"});
}

test "const and var optional type annotations" {
    try testProgram(
        \\const x: int = 40
        \\var y: int = x + 1
        \\y = y + 1
        \\print(y)
    , "42\n");
    try testProgram(
        \\const x = 40
        \\var y = x + 2
        \\print(y)
    , "42\n");
}

test "struct init single field var and field access" {
    try testProgram(
        \\comptime Foo = struct
        \\  x: int
        \\var foo = Foo{x = 10}
        \\print(foo.x)
    , "10\n");
}

test "struct init multi-field var and field access" {
    try testProgram(
        \\comptime Point = struct
        \\  x: int
        \\  y: int
        \\var p = Point{x = 3, y = 4}
        \\print(p.x)
        \\print(p.y)
    , "3\n4\n");
}

test "struct init const and field access" {
    try testProgram(
        \\comptime Foo = struct
        \\  x: int
        \\const f = Foo{x = 42}
        \\print(f.x)
    , "42\n");
}

test "struct init unknown field error" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime Foo = struct
        \\  x: int
        \\var f = Foo{y = 10}
    );
    try expectCompileErrorContains(&db, 0, "struct init field name mismatch");
}

test "struct init field count mismatch error" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime Foo = struct
        \\  x: int
        \\  y: int
        \\var f = Foo{x = 1}
    );
    try expectCompileErrorContains(&db, 0, "struct init field count mismatch");
}

test "field access on non-struct error" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\const x = 5
        \\print(x.nonexistent)
    );
    try expectCompileErrorContains(&db, 0, "field access on non-struct type");
}

test "struct field type mismatch error" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime Foo = struct
        \\  x: int
        \\var f = Foo{x = 1.0}
    );
    try expectCompileErrorContains(&db, 0, "binding type annotation mismatch");
}

test "binding type annotation mismatch errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "const x: int = 1.0");
    try expectCompileErrorContains(&db, 0, "binding type annotation mismatch");

    try db.setSource(0, "var y: float = 1");
    try expectCompileErrorContains(&db, 0, "binding type annotation mismatch");
}
