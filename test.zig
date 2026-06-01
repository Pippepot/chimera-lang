const std = @import("std");
const testing = std.testing;
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const query = @import("query.zig");
const runtime = @import("runtime.zig");
const query_cache = @import("query_cache.zig");
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

fn makeTmpSourcePath(gpa: std.mem.Allocator, tmp: *const testing.TmpDir, file_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache{c}tmp{c}{s}{c}{s}", .{
        std.fs.path.sep,
        std.fs.path.sep,
        tmp.sub_path,
        std.fs.path.sep,
        file_name,
    });
}

fn initCacheDb(cache_enabled: bool) query.QueryDb {
    return query.QueryDb.initWithOptions(testing.allocator, .{
        .persistent_cache_enabled = cache_enabled,
        .io = testing.io,
    });
}

const PersistTest = struct {
    tmp: testing.TmpDir,
    source_path: []u8,
    cache_path: []u8,

    fn init(name: []const u8, text: []const u8) !@This() {
        var tmp = testing.tmpDir(.{});
        const source_path = try makeTmpSourcePath(testing.allocator, &tmp, name);
        errdefer testing.allocator.free(source_path);
        const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}.qcache", .{source_path});
        errdefer testing.allocator.free(cache_path);
        try std.Io.Dir.cwd().writeFile(testing.io, .{
            .sub_path = source_path,
            .data = text,
        });
        return .{ .tmp = tmp, .source_path = source_path, .cache_path = cache_path };
    }

    fn deinit(self: *@This()) void {
        std.Io.Dir.cwd().deleteFile(testing.io, self.source_path) catch {};
        std.Io.Dir.cwd().deleteFile(testing.io, self.cache_path) catch {};
        testing.allocator.free(self.cache_path);
        testing.allocator.free(self.source_path);
        self.tmp.cleanup();
    }
};

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
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.ast.decls.len);
    try testing.expect(parsed.ast.nodes[parsed.ast.decls[0]].tag == .comptime_struct);
    try testing.expect(parsed.ast.nodes[parsed.ast.decls[1]].tag == .comptime_fn);
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

test "fallible and short-circuits on lhs failure" {
    try testProgram(
        \\if 2 < 1 and 1 / 0 < 1
        \\  print(11)
        \\else
        \\  print(22)
    , "22\n");
}

test "fallible or short-circuits on lhs success" {
    try testProgram(
        \\if 1 < 2 or 1 / 0 < 1
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
}

test "fallible and binds tighter than or" {
    try testProgram(
        \\if 1 < 2 or 3 < 2 and 4 < 3
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
}

test "logical operands must be fallible" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\if true and 1 < 2
        \\  print(11)
    );
    try expectCompileErrorContains(&db, 0, "logical operands must be fallible expressions");
}

test "inline if arrow supports return in function bodies" {
    try testProgram(
        \\comptime fib = func(n: int) int
        \\  if n == 1 -> return 1
        \\  if n == 0 -> return 0
        \\  return fib(n - 1) + fib(n - 2)
        \\
        \\print(fib(10))
    , "55\n");
}

test "inline comptime expression computes value at compile time" {
    try testProgram(
        \\const x = comptime -> 40 + 2
        \\print(x)
    , "42\n");
}

test "block comptime expression computes value at compile time" {
    try testProgram(
        \\const x = comptime
        \\  const a = 40
        \\  a + 2
        \\print(x)
    , "42\n");
}

test "comptime value declaration resolves dependencies regardless of order" {
    try testProgram(
        \\comptime y = x + 1
        \\comptime x = 41
        \\print(y)
    , "42\n");
}

test "comptime declaration cycle reports diagnostic" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime a = b + 1
        \\comptime b = a + 1
        \\print(a)
    );
    try expectCompileErrorContains(&db, 0, "comptime dependency cycle");
}

test "comptime expressions are pure in v1" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\const x = comptime -> print(1)
        \\print(x)
    );
    try expectCompileErrorContains(&db, 0, "operation is not allowed in pure comptime execution");
}

test "comptime expressions cannot capture runtime locals" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\const a = 41
        \\const b = comptime -> a + 1
        \\print(b)
    );
    try expectCompileErrorContains(&db, 0, "comptime can only reference comptime symbols");
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


test "query cache hits within same revision includes resolve" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "0");
    _ = try db.parsedAst(0);
    _ = try db.resolvedAst(0);
    _ = try db.typedAst(0);
    _ = try db.loweredProgram(0);
    _ = try expectCompileOk(&db, 0);

    db.resetStats();

    _ = try db.parsedAst(0);
    _ = try db.resolvedAst(0);
    _ = try db.typedAst(0);
    _ = try db.loweredProgram(0);
    _ = try expectCompileOk(&db, 0);

    const stats = db.statsSnapshot();
    try testing.expectEqual(@as(usize, 1), stats.parse_hits);
    try testing.expectEqual(@as(usize, 1), stats.resolve_hits);
    try testing.expectEqual(@as(usize, 1), stats.type_hits);
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

test "debug query diagnostics format includes resolve" {
    var buf = try std.ArrayList(u8).initCapacity(testing.allocator, 256);
    defer buf.deinit(testing.allocator);

    const stats = query.QueryStats{
        .revision = 7,
        .source_sets = 2,
        .parse_hits = 3,
        .resolve_hits = 4,
        .type_hits = 5,
        .compile_recomputes = 1,
        .dependency_checks = 5,
    };
    try query.appendQueryDiagnostics(&buf, testing.allocator, stats);

    try testing.expect(std.mem.indexOf(u8, buf.items, ";   parse: hits=3 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   resolve: hits=4 recomputes=0") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, ";   type: hits=5 recomputes=0") != null);
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

test "variant type alias supports runtime is checks and assignment" {
    try testProgram(
        \\comptime A = struct
        \\  f1: int
        \\  f2: float
        \\comptime sumtype = int | float | A
        \\var x: sumtype = 3
        \\if x is int
        \\  print(11)
        \\else
        \\  print(0)
        \\x = A{f1 = 2, f2 = 4.5}
        \\if x is int
        \\  print(0)
        \\else
        \\  print(22)
        \\if x is int | A
        \\  print(33)
        \\else
        \\  print(0)
    , "11\n22\n33\n");
}

test "variant function parameter supports runtime is checks" {
    try testProgram(
        \\comptime foo = func(x: int | float)
        \\  if x is int -> print(1)
        \\  if x is float -> print(2)
        \\
        \\foo(1)
        \\foo(1.0)
    , "1\n2\n");
}

test "if condition binding with as unwraps variant payload" {
    try testProgram(
        \\var b: int | float = 1
        \\b = 2
        \\if const i = b as int
        \\  print(i)
        \\b = 3.54
        \\if const f = b as float -> print(f)
    , "2\n3.540000\n");
}

test "if condition binding with as is scoped to success branch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\var b: int | float = 1
        \\if const i = b as int
        \\  print(i)
        \\print(i)
    );
    try expectCompileErrorContains(&db, 0, "unknown symbol");
}

test "is requires a variant lhs" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\if 1 is int
        \\  print(1)
    );
    try expectCompileErrorContains(&db, 0, "left side of 'is' must be a variant type");
}

test "is rhs must be a variant member type" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime T = int | float
        \\var x: T = 1
        \\if x is bool
        \\  print(1)
    );
    try expectCompileErrorContains(&db, 0, "right side of 'is' is not a member of the variant type");
}

test "variant type rejects duplicate members" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime T = int | int
    );
    try expectCompileErrorContains(&db, 0, "duplicate variant member type");
}

test "comptime-only program with variant alias compiles" {
    try testProgram(
        \\comptime T = int | float
    , "");
}

test "function returning variant unwraps correctly on success" {
    try testProgram(
        \\comptime foo = func(b: bool) int | unit
        \\  if b == true -> return 10
        \\
        \\if const i = foo(true) as int
        \\  print(i)
    , "10\n");
}

test "function returning variant as fails when tag does not match" {
    try testProgram(
        \\comptime foo = func(b: bool) int | unit
        \\  if b == true -> return 10
        \\
        \\if const i = foo(false) as int
        \\  print(i)
        \\else
        \\  print(99)
    , "99\n");
}

test "const/var are expressions returning their bound value" {
    try testProgram(
        \\comptime foo = func(b: bool) int | unit
        \\  if b == true -> return 42
        \\
        \\if (const i = foo(true) as int) == 42
        \\  print(i)
    , "42\n");
}

test "not inverts fallible expression success/failure" {
    try testProgram(
        \\if not (1 == 2) -> print(10)
        \\if not (1 == 1)
        \\  print(20)
        \\else
        \\  print(30)
    , "10\n30\n");
}

test "comptime const/var as expression and as in comptime eval" {
    try testProgram(
        \\comptime foo = func(b: bool) int | unit
        \\  if b == true -> return 10
        \\
        \\comptime b = if (const i = foo(true) as int)==10 -> i else 2
        \\print(b)
    , "10\n");
}

test "const in if condition scoped to then-branch only" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\if (const i = 10) == 10
        \\  print(1)
        \\else
        \\  print(i)
    );
    try expectCompileErrorContains(&db, 0, "unknown symbol");
}

test "if with mismatched branch types returns variant" {
    try testProgram(
        \\var x = if 1 == 1 -> 42 else true
        \\var y = if 1 == 2 -> 99 else 3.14
        \\if const v = x as int -> print(v)
        \\if const v = y as float -> print(v)
    , "42\n3.140000\n");
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

test "comptime function returns monomorphized struct type" {

    try testProgram(
        \\comptime Wrapper = func(comptime T: type) type
        \\  return struct
        \\    x: T
        \\comptime IntWrapper = Wrapper(int)
        \\const instance = IntWrapper{x = 42}
        \\print(instance.x)
    , "42\n");
}

test "comptime function with dual monomorphized parameter" {

    try testProgram(
        \\comptime Pair = func(comptime A: type, comptime B: type) type
        \\  return struct
        \\    first: A
        \\    second: B
        \\comptime IP = Pair(int, float)
        \\const p = IP{first = 10, second = 2.5}
        \\print(p.first)
        \\print(p.second)
    , "10\n2.500000\n");
}

test "comptime function monomorphization caching" {

    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime Wrapper = func(comptime T: type) type
        \\  return struct
        \\    x: T
        \\comptime IntWrapper = Wrapper(int)
        \\const a = IntWrapper{x = 1}
        \\comptime FloatWrapper = Wrapper(float)
        \\const b = FloatWrapper{x = 2.5}
        \\print(a.x)
        \\print(b.x)
    );
    _ = try expectCompileOk(&db, 0);
    db.resetStats();
    _ = try expectCompileOk(&db, 0);
    const stats = db.statsSnapshot();
    try testing.expect(stats.compile_hits >= 1);
    try testing.expectEqual(@as(usize, 0), stats.compile_recomputes);

}

test "comptime function error passing non-type as type param" {

    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime Wrapper = func(comptime T: type) type
        \\  return T
        \\const r = Wrapper(42)
    );
    try expectCompileErrorContains(&db, 0, "call argument type mismatch");
}

test "runtime type value in const decl errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime Wrapper = func(comptime T: type) type
        \\  return struct
        \\    x: T
        \\const i3: type = Wrapper(int)
    );
    try expectCompileErrorContains(&db, 0, "type value cannot be used at runtime");
}

test "runtime type value in var decl errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\var t: type = int
    );
    try expectCompileErrorContains(&db, 0, "type value cannot be used at runtime");
}

test "comptime value used as type annotation in const decl" {
    try testProgram(
        \\comptime i: type = int
        \\const b: i = 233
        \\print(b)
    , "233\n");
}

test "comptime value not a type in annotation errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime x = 42
        \\const y: x = 1
    );
    try expectCompileErrorContains(&db, 0, "comptime value is not a type");
}

test "comptime function inline struct init" {

    try testProgram(
        \\comptime Wrapper = func(comptime T: type) type
        \\  return struct
        \\    x: T
        \\const val = Wrapper(float){x = 3.0}
        \\print(val.x)
    , "3.000000\n");
}

test "monomorphized function with comptime type param and runtime param" {

    try testProgram(
        \\comptime foo = func(comptime T: type, x: T)
        \\  print(x)
        \\foo(int, 10)
    , "10\n");
}

test "monomorphized function multiple type instantiations" {

    try testProgram(
        \\comptime foo = func(comptime T: type, x: T)
        \\  print(x)
        \\foo(int, 10)
        \\foo(float, 1.23)
    , "10\n1.230000\n");
}

test "monomorphized function int parameter used as field type" {

    try testProgram(
        \\comptime wrap = func(comptime T: type, x: T)
        \\  print(x)
        \\wrap(int, 42)
        \\wrap(float, 3.14)
    , "42\n3.140000\n");
}

test "monomorphized function arg type mismatch errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime foo = func(comptime T: type, x: T)
        \\  print(x)
        \\foo(int, 1.0)
    );
    try expectCompileErrorContains(&db, 0, "call argument type mismatch");
}

test "monomorphized function comptime arg type mismatch errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime foo = func(comptime T: type, x: T)
        \\  print(x)
        \\foo(42, 10)
    );
    try expectCompileErrorContains(&db, 0, "call argument type mismatch");
}

test "monomorphized function caching across same revision" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime foo = func(comptime T: type, x: T)
        \\  print(x)
        \\foo(int, 10)
        \\foo(int, 20)
    );
    _ = try expectCompileOk(&db, 0);
    db.resetStats();
    _ = try expectCompileOk(&db, 0);
    const stats = db.statsSnapshot();
    try testing.expect(stats.compile_hits >= 1);
    try testing.expectEqual(@as(usize, 0), stats.compile_recomputes);
}

test "comptime pure-function with comptime-only param and struct arg" {
    try testProgram(
        \\comptime Foo = struct
        \\  x: int
        \\
        \\comptime bar = func(comptime T: type)
        \\  print(T{x = 42}.x)
        \\
        \\bar(Foo)
    , "42\n");
}

test "binding type annotation mismatch errors" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "const x: int = 1.0");
    try expectCompileErrorContains(&db, 0, "binding type annotation mismatch");

    try db.setSource(0, "var y: float = 1");
    try expectCompileErrorContains(&db, 0, "binding type annotation mismatch");
}

test "comptime value decl with int type annotation" {
    try testProgram(
        \\comptime x: int = 42
        \\print(x)
    , "42\n");
}

test "comptime value decl with float type annotation" {
    try testProgram(
        \\comptime x: float = 1.5
        \\print(x)
    , "1.500000\n");
}

test "comptime value decl type annotation mismatch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime x: int = 1.0
        \\print(x)
    );
    try expectCompileErrorContains(&db, 0, "binding type annotation mismatch");
}

test "comptime function value decl with type annotation" {
    try testProgram(
        \\comptime f: func(int) int = func(n: int) int
        \\  return n + 1
        \\print(f(41))
    , "42\n");
}

test "comptime value decl with bool type annotation" {
    try testProgram(
        \\comptime flag: bool = true
        \\print(flag)
    , "true\n");
}

test "string type annotation is rejected" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "const s: string = 1");
    try expectCompileErrorContains(&db, 0, "unknown type");
}

test "string literal syntax is rejected" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "print(\"hello\")");
    try expectCompileErrorContains(&db, 0, "unexpected character");
}

test "persistent cache reuses compile result across db instances" {
    const source_text = "print(42)\n";
    var pt = try PersistTest.init("persist_ok.chi", source_text);
    defer pt.deinit();

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        _ = try expectCompileOk(&db, 0);
    }

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        db.resetStats();
        _ = try expectCompileOk(&db, 0);
        const stats = db.statsSnapshot();
        try testing.expect(stats.compile_hits >= 1);
        try testing.expectEqual(@as(usize, 0), stats.compile_recomputes);
    }
}

test "persistent cache disable option bypasses disk cache" {
    const source_text = "print(7)\n";
    var pt = try PersistTest.init("persist_disabled.chi", source_text);
    defer pt.deinit();

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        _ = try expectCompileOk(&db, 0);
    }

    {
        var db = initCacheDb(false);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        db.resetStats();
        _ = try expectCompileOk(&db, 0);
        const stats = db.statsSnapshot();
        try testing.expectEqual(@as(usize, 0), stats.compile_hits);
        try testing.expectEqual(@as(usize, 1), stats.compile_recomputes);
    }
}

test "persistent cache stores compile failures and diagnostics" {
    const source_text = "print(missing_name)\n";
    var pt = try PersistTest.init("persist_fail.chi", source_text);
    defer pt.deinit();

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        try expectCompileErrorContains(&db, 0, "unknown symbol");
    }

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        db.resetStats();
        try expectCompileErrorContains(&db, 0, "unknown symbol");
        const stats = db.statsSnapshot();
        try testing.expect(stats.compile_hits >= 1);
    }
}

test "corrupted persistent cache is ignored and rebuilt" {
    const source_text = "print(5)\n";
    var pt = try PersistTest.init("persist_corrupt.chi", source_text);
    defer pt.deinit();

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        _ = try expectCompileOk(&db, 0);
    }

    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = pt.cache_path,
        .data = "not-a-valid-cache",
    });

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, pt.source_path, source_text);
        db.resetStats();
        _ = try expectCompileOk(&db, 0);
        const stats = db.statsSnapshot();
        try testing.expectEqual(@as(usize, 1), stats.compile_recomputes);
    }
}

test "persistent cache load frees data on hash mismatch (regression)" {
    const source_text = "print(42)\n";
    const different_text = "print(99)\n";
    var pt = try PersistTest.init("persist_hash_mismatch.chi", source_text);
    defer pt.deinit();

    try query_cache.save(testing.io, testing.allocator, .{}, .{
        .source_path = pt.source_path,
        .source_text = source_text,
        .parse = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .resolve = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .typecheck = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .lower = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .compile = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
    });

    const result = try query_cache.load(testing.io, testing.allocator, .{}, pt.source_path, different_text);
    try testing.expect(result == null);
}

test "stale cache files are removed by eager sweep" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const source_text = "print(9)\n";
    const live_source = try makeTmpSourcePath(testing.allocator, &tmp, "persist_live.chi");
    defer testing.allocator.free(live_source);
    const stale_source = try makeTmpSourcePath(testing.allocator, &tmp, "persist_stale.chi");
    defer testing.allocator.free(stale_source);
    const stale_cache = try std.fmt.allocPrint(testing.allocator, "{s}.qcache", .{stale_source});
    defer testing.allocator.free(stale_cache);
    const live_cache = try std.fmt.allocPrint(testing.allocator, "{s}.qcache", .{live_source});
    defer testing.allocator.free(live_cache);

    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = live_source,
        .data = source_text,
    });
    defer std.Io.Dir.cwd().deleteFile(testing.io, live_source) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, live_cache) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, stale_cache) catch {};

    try query_cache.save(testing.io, testing.allocator, .{}, .{
        .source_path = stale_source,
        .source_text = source_text,
        .parse = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .resolve = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .typecheck = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .lower = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
        .compile = .{ .changed_at = 1, .has_value = false, .diagnostics = &.{}, .bytes = null },
    });

    {
        var db = initCacheDb(true);
        defer db.deinit();
        try db.setSourceFile(0, live_source, source_text);
        _ = try expectCompileOk(&db, 0);
    }

    std.Io.Dir.cwd().access(testing.io, stale_cache, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    return error.TestFailed;
}

test "parser ownership syntax and parameter modes" {
    const src =
        \\comptime S = struct
        \\  move = none
        \\  copy = none
        \\  drop = explicit
        \\  x: int
        \\
        \\comptime f = func(read a: int, mut b: int, var c: int, deinit d: int, e: int) unit
        \\  0
    ;
    var parsed = try parser.parseOwned(src, testing.allocator);
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.ast.decls.len);
    const struct_decl = parsed.ast.decls[0];
    const fn_decl = parsed.ast.decls[1];

    try testing.expect(parsed.ast.nodes[struct_decl].tag == .comptime_struct);
    try testing.expect(parsed.ast.structMoveKind(struct_decl) == ast.StructMoveKind.none);
    try testing.expect(parsed.ast.structCopyKind(struct_decl) == ast.StructCopyKind.none);
    try testing.expect(parsed.ast.structDropKind(struct_decl) == ast.StructDropKind.explicit);
    try testing.expect(parsed.ast.structMoveExplicit(struct_decl));
    try testing.expect(parsed.ast.structCopyExplicit(struct_decl));
    try testing.expect(parsed.ast.structDropExplicit(struct_decl));

    try testing.expect(parsed.ast.nodes[fn_decl].tag == .comptime_fn);
    try testing.expect(parsed.ast.fnParamAccessMode(fn_decl, 0) == ast.ParamAccessMode.read);
    try testing.expect(parsed.ast.fnParamAccessMode(fn_decl, 1) == ast.ParamAccessMode.mut);
    try testing.expect(parsed.ast.fnParamAccessMode(fn_decl, 2) == ast.ParamAccessMode.var_mode);
    try testing.expect(parsed.ast.fnParamAccessMode(fn_decl, 3) == ast.ParamAccessMode.deinit);
    try testing.expect(parsed.ast.fnParamAccessMode(fn_decl, 4) == ast.ParamAccessMode.read);
}

test "struct ownership keys are reserved and cannot be field names" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime S = struct
        \\  move: int
    );
    try expectCompileErrorContains(&db, 0, "unexpected token");
}

test "ownership copy none rejects implicit struct copy" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime A = struct
        \\  x: int
        \\const a = A{x = 1}
        \\const b = a
        \\print(b.x)
    );
    try expectCompileErrorContains(&db, 0, "copy is not allowed");
}

test "inline one-line copy hook is invoked on implicit copy" {
    try testProgram(
        \\comptime Box = struct
        \\  x: int
        \\  copy = func(read self: Box) Box -> Box{x = self.x + 1}
        \\const a = Box{x = 5}
        \\const b = a
        \\print(b.x)
    , "6\n");
}

test "inline one-line move hook is invoked on move sigil" {
    try testProgram(
        \\comptime Box = struct
        \\  x: int
        \\  move = func(var self: Box) Box -> Box{x = self.x + 10}
        \\const a = Box{x = 2}
        \\const b = a^
        \\print(b.x)
    , "12\n");
}

test "var parameter consume supports both x and x^ call forms" {
    try testProgram(
        \\comptime A = struct
        \\  x: int
        \\comptime take = func(var a: A) unit
        \\  print(a.x)
        \\const a = A{x = 1}
        \\take(a)
        \\const b = A{x = 2}
        \\take(b^)
    , "1\n2\n");
}

test "use after move is diagnosed" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime A = struct
        \\  x: int
        \\comptime take = func(var a: A) unit
        \\  print(a.x)
        \\const a = A{x = 1}
        \\take(a)
        \\print(a.x)
    );
    try expectCompileErrorContains(&db, 0, "use after move");
}

test "read parameter borrows and does not require copy" {
    try testProgram(
        \\comptime A = struct
        \\  x: int
        \\comptime show = func(read a: A) unit
        \\  print(a.x)
        \\const a = A{x = 9}
        \\show(a)
    , "9\n");
}

test "mut parameter writes back to caller value" {
    try testProgram(
        \\comptime bump = func(mut x: int) unit
        \\  x = x + 1
        \\var n = 41
        \\bump(n)
        \\print(n)
    , "42\n");
}

test "move none values cannot be transferred" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime Id = struct
        \\  move = none
        \\  x: int
        \\comptime take = func(var v: Id) unit
        \\  print(v.x)
        \\const a = Id{x = 3}
        \\take(a)
    );
    try expectCompileErrorContains(&db, 0, "stable-identity value cannot be transferred");
}

test "move none forces copy none compatibility" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime Id = struct
        \\  move = none
        \\  copy = trivial
        \\  x: int
    );
    try expectCompileErrorContains(&db, 0, "struct ownership policy is incompatible");
}

test "drop explicit requires deinit path before scope exit" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime D = struct
        \\  drop = explicit
        \\  x: int
        \\const d = D{x = 1}
    );
    try expectCompileErrorContains(&db, 0, "deinit ownership must be consumed");
}

test "drop explicit is satisfied by deinit parameter call" {
    try testProgram(
        \\comptime D = struct
        \\  drop = explicit
        \\  x: int
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
        \\const d = D{x = 7}
        \\consume(d)
    , "7\n");
}

test "deinit-to-deinit transfer is allowed" {
    try testProgram(
        \\comptime D = struct
        \\  drop = explicit
        \\  x: int
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
        \\comptime bad = func(deinit d: D) unit
        \\  consume(d)
        \\const d = D{x = 5}
        \\bad(d)
    , "5\n");
}

test "deinit-owned value cannot be transferred to var parameter" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime D = struct
        \\  drop = explicit
        \\  x: int
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
        \\comptime take = func(var d: D) unit
        \\  consume(d)
        \\comptime bad = func(deinit d: D) unit
        \\  take(d)
        \\const d = D{x = 1}
        \\bad(d)
    );
    try expectCompileErrorContains(&db, 0, "deinit-owned value cannot be transferred");
}

test "ownership hook signature mismatch is diagnosed" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\comptime S = struct
        \\  x: int
        \\  copy = func(var self: S) S
        \\    return S{x = self.x}
        \\const s = S{x = 1}
        \\print(s.x)
    );
    try expectCompileErrorContains(&db, 0, "ownership hook function signature mismatch");
}

test "regression: multi-field struct return from function works" {
    try testProgram(
        \\comptime Point = struct
        \\  x: int
        \\  y: int
        \\comptime make = func(x: int, y: int) Point
        \\  return Point{x = x, y = y}
        \\const pt = make(3, 4)
        \\print(pt.x)
        \\print(pt.y)
    , "3\n4\n");
    try testProgram(
        \\comptime Tri = struct
        \\  a: int
        \\  b: int
        \\  c: int
        \\comptime make = func(a: int, b: int, c: int) Tri
        \\  return Tri{a = a, b = b, c = c}
        \\const t = make(10, 20, 30)
        \\print(t.a)
        \\print(t.b)
        \\print(t.c)
    , "10\n20\n30\n");
}

test "regression: drop func indented body followed by field parses" {
    try testProgram(
        \\comptime D = struct
        \\  drop = func(deinit self: D) unit -> print(77)
        \\  x: int
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
        \\const d = D{x = 5}
        \\consume(d)
    , "5\n");
    try testProgram(
        \\comptime D = struct
        \\  x: int
        \\  drop = func(deinit self: D) unit
        \\    print(99)
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
        \\const d = D{x = 3}
        \\consume(d)
    , "3\n");
}

test "regression: field assignment p.x = expr works" {
    try testProgram(
        \\comptime Point = struct
        \\  x: int
        \\  y: int
        \\comptime set_x = func(mut p: Point, val: int) unit
        \\  p.x = val
        \\var pt = Point{x = 1, y = 2}
        \\set_x(pt, 99)
        \\print(pt.x)
    , "99\n");
}

test "regression: nested field assignment a.b.c = expr works" {
    try testProgram(
        \\comptime Inner = struct
        \\  v: int
        \\comptime Outer = struct
        \\  inner: Inner
        \\  tag: int
        \\comptime set = func(mut o: Outer, val: int) unit
        \\  o.inner.v = val
        \\var o = Outer{inner = Inner{v = 1}, tag = 2}
        \\set(o, 99)
        \\print(o.inner.v)
    , "99\n");
}

test "regression: field_access as last statement in function body" {
    try testProgram(
        \\comptime A = struct
        \\  x: int
        \\comptime f = func(a: A) int
        \\  a.x
        \\print(42)
    , "42\n");
    try testProgram(
        \\comptime A = struct
        \\  x: int
        \\comptime f = func(a: A) int
        \\  return a.x
        \\comptime g = func(a: A) int
        \\  return a.x
        \\print(99)
    , "99\n");
}

test "regression: if-const with comparison works" {
    try testProgram(
        \\if const p = 1 < 2
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
    try testProgram(
        \\if const p = 1 == 2
        \\  print(11)
        \\else
        \\  print(22)
    , "22\n");
}

test "regression: monomorphized function with comptime type param in return type" {
    try testProgram(
        \\comptime wrap = func(comptime T: type, var x: T) T
        \\  return x
        \\const w = wrap(int, 42)
        \\print(w)
    , "42\n");
    try testProgram(
        \\comptime wrap = func(comptime T: type, var x: T) T
        \\  return x
        \\comptime W = struct
        \\  v: int
        \\const w = wrap(W, W{v = 99})
        \\print(w.v)
    , "99\n");
}

test "regression: deinit-to-deinit chain works" {
    try testProgram(
        \\comptime D = struct
        \\  drop = explicit
        \\  x: int
        \\comptime inner = func(deinit d: D) unit
        \\  print(d.x)
        \\comptime outer = func(deinit d: D) unit
        \\  inner(d)
        \\const d = D{x = 7}
        \\outer(d)
    , "7\n");
}

test "regression: mut writeback with multi-field struct" {
    try testProgram(
        \\comptime Point = struct
        \\  x: int
        \\  y: int
        \\comptime set_both = func(mut p: Point) unit
        \\  p = Point{x = 10, y = 20}
        \\var pt = Point{x = 1, y = 2}
        \\set_both(pt)
        \\print(pt.x)
        \\print(pt.y)
    , "10\n20\n");
}

test "regression: swap via mut params and field assignment" {
    try testProgram(
        \\comptime Pair = struct
        \\  first: int
        \\  second: int
        \\comptime swap = func(mut p: Pair) unit
        \\  const tmp = p.first
        \\  p.first = p.second
        \\  p.second = tmp
        \\var p = Pair{first = 10, second = 20}
        \\swap(p)
        \\print(p.first)
        \\print(p.second)
    , "20\n10\n");
}

test "error: arithmetic operands must have the same type" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0, "print(1 + 2.0)");
    try expectCompileErrorContains(&db, 0, "arithmetic operands must have the same type");
}

test "error: arithmetic requires int or float operands" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0, "print(true + 1)");
    try expectCompileErrorContains(&db, 0, "arithmetic requires int or float operands");
}

test "error: as operand not variant" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\const x = 1
        \\if x as float
        \\  print(1)
    );
    try expectCompileErrorContains(&db, 0, "left side of 'as' must be a variant type");
}

test "error: as type not in variant" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime V = int | float
        \\var v: V = 1.0
        \\if v as bool
        \\  print(1)
    );
    try expectCompileErrorContains(&db, 0, "right side of 'as' is not a member of the variant type");
}

test "error: assign to const symbol" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\const x = 1
        \\x = 2
    );
    try expectCompileErrorContains(&db, 0, "cannot assign to const symbol");
}

test "error: assignment type mismatch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\var x: int = 1
        \\x = 2.0
    );
    try expectCompileErrorContains(&db, 0, "assignment type mismatch");
}

test "error: call target not function" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\const x = 1
        \\x(2)
    );
    try expectCompileErrorContains(&db, 0, "call target is not a function value");
}

test "error: comparison operands must have the same type" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0, "if 1 < 2.0\n  print(1)");
    try expectCompileErrorContains(&db, 0, "comparison operands must have the same type");
}

test "error: comparison requires numeric" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0, "if true < false\n  print(1)");
    try expectCompileErrorContains(&db, 0, "comparison requires int or float operands");
}

test "if branches variant type (no error — if returns variant)" {
    try testProgram(
        \\if 1 < 2
        \\  1
        \\else
        \\  2.0
        \\print(42)
    , "42\n");
}

test "error: equality operands must have the same type" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0, "if 1 == 2.0\n  print(1)");
    try expectCompileErrorContains(&db, 0, "equality operands must have the same type");
}

test "error: equality unsupported type" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime A = struct
        \\  x: int
        \\const a = A{x = 1}
        \\if a == a
        \\  print(1)
    );
    try expectCompileErrorContains(&db, 0, "equality is not supported for this type");
}

test "error: fallible outside fallible context" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0, "print(1 < 2)");
    try expectCompileErrorContains(&db, 0, "Fallible expression is not allowed outside fallible context");
}

test "error: function body type mismatch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime f = func() int
        \\  1.0
    );
    try expectCompileErrorContains(&db, 0, "function body type does not match declared return type");
}


test "error: if without else must have unit then-branch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\if 1 < 2
        \\  1
    );
    try expectCompileErrorContains(&db, 0, "if without else must have unit then-branch");
}

test "error: invalid borrow argument" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime f = func(mut x: int) unit
        \\  x = x + 1
        \\f(1 + 2)
    );
    try expectCompileErrorContains(&db, 0, "borrow argument must be a variable reference");
}

test "error: move borrowed value" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime f = func(x: int) int
        \\  return x
    );
    try expectCompileErrorContains(&db, 0, "cannot move a borrowed value");
}

test "error: mutate const" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime f = func(mut x: int) unit
        \\  x = x + 1
        \\const n = 1
        \\f(n)
    );
    try expectCompileErrorContains(&db, 0, "cannot mutate a const variable");
}

test "error: move not allowed for type" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime Id = struct
        \\  move = none
        \\  copy = none
        \\  x: int
        \\comptime V = int | Id
        \\var v: V = 1
        \\var w = v^
    );
    try expectCompileErrorContains(&db, 0, "move is not allowed for this type");
}

test "error: print unit value" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\const x = if 1 < 2
        \\  print(0)
        \\else
        \\  print(0)
        \\print(x)
    );
    try expectCompileErrorContains(&db, 0, "cannot print a unit value");
}

test "error: recursive struct types" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime S = struct
        \\  w: W
        \\comptime W = struct
        \\  s: S
    );
    try expectCompileErrorContains(&db, 0, "recursive struct types are not supported");
}

test "error: use after deinit" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();
    try db.setSource(0,
        \\comptime D = struct
        \\  drop = explicit
        \\  x: int
        \\comptime consume = func(deinit d: D) unit
        \\  print(d.x)
        \\const d = D{x = 1}
        \\consume(d)
        \\print(d.x)
    );
    try expectCompileErrorContains(&db, 0, "use after deinit");
}

test "comments are ignored by parser" {
    try testProgram(
        \\# this is a comment
        \\print(42)
    , "42\n");
    try testProgram(
        \\print(1) # inline comment
        \\# another comment
        \\print(2)
    , "1\n2\n");
}

test "second compile with no changes has zero recomputes" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0, "0");
    _ = try expectCompileOk(&db, 0);

    db.resetStats();

    _ = try expectCompileOk(&db, 0);

    const stats = db.statsSnapshot();
    try testing.expectEqual(@as(usize, 0), stats.parse_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.resolve_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.type_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.lower_recomputes);
    try testing.expectEqual(@as(usize, 0), stats.parse_hits);
    try testing.expectEqual(@as(usize, 0), stats.resolve_hits);
    try testing.expectEqual(@as(usize, 0), stats.type_hits);
    try testing.expectEqual(@as(usize, 0), stats.lower_hits);
    try testing.expectEqual(@as(usize, 1), stats.compile_hits);
}

// ── none type tests ──

test "none type: literal and annotation" {
    try testProgram(
        \\const n: none = none
        \\print(42)
    , "42\n");
}

test "none type: variant member and is check" {
    try testProgram(
        \\var x: int | none = 42
        \\if x is int
        \\  print(11)
        \\else
        \\  print(22)
        \\x = none
        \\if x is none
        \\  print(33)
        \\else
        \\  print(44)
    , "11\n33\n");
}

test "none type: assignment to variant from none" {
    try testProgram(
        \\var x: int | none = none
        \\if x is none
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
}

test "query operator without binding succeeds on non-none" {
    try testProgram(
        \\var x: int | none = 42
        \\if x?
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
}

test "query operator without binding fails on none" {
    try testProgram(
        \\var x: int | none = none
        \\if x?
        \\  print(11)
        \\else
        \\  print(22)
    , "22\n");
}

test "query operator with binding unwraps value" {
    try testProgram(
        \\var x: int | none = 42
        \\if const v = x?
        \\  print(v)
    , "42\n");
}

test "query operator with binding scoped to success branch" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\var x: int | none = 42
        \\if const v = x?
        \\  print(v)
        \\print(v)
    );
    try expectCompileErrorContains(&db, 0, "unknown symbol");
}

test "query operator errors on non-variant operand" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\var x: int = 5
        \\if x?
        \\  print(11)
    );
    try expectCompileErrorContains(&db, 0, "left side of '?' must be a variant type");
}

test "query operator errors when variant has no none" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\var x: int | float = 5
        \\if x?
        \\  print(11)
    );
    try expectCompileErrorContains(&db, 0, "variant does not contain 'none' member");
}

test "query operator with multi-member variant unwraps to variant" {
    try testProgram(
        \\var x: int | float | none = 3.14
        \\if const v = x?
        \\  if v is float -> print(11) else print(22)
    , "11\n");
}

test "query operator: if else binding with mutable binding" {
    try testProgram(
        \\var x: int | none = 42
        \\if var v = x?
        \\  print(v)
    , "42\n");
}

test "none type: in variant initializer from none" {
    try testProgram(
        \\comptime OptInt = int | none
        \\var x: OptInt = none
        \\if x is none
        \\  print(11)
        \\else
        \\  print(22)
    , "11\n");
}

test "none type: error on print none" {
    var db = query.QueryDb.init(testing.allocator);
    defer db.deinit();

    try db.setSource(0,
        \\print(none)
    );
    try expectCompileErrorContains(&db, 0, "cannot print this type");
}

test "sizeof primitive types" {
    try testProgram(
        \\print(sizeof(int))
    , "4\n");
    try testProgram(
        \\print(sizeof(bool))
    , "1\n");
    try testProgram(
        \\print(sizeof(float))
    , "4\n");
    try testProgram(
        \\print(sizeof(unit))
    , "0\n");
    try testProgram(
        \\print(sizeof(none))
    , "0\n");
}

test "sizeof struct type" {
    try testProgram(
        \\comptime Point = struct
        \\  x: int
        \\  y: int
        \\print(sizeof(Point))
    , "8\n");
}

test "sizeof struct with 3 fields" {
    try testProgram(
        \\comptime Triple = struct
        \\  a: int
        \\  b: int
        \\  c: int
        \\print(sizeof(Triple))
    , "12\n");
}

test "sizeof func type" {
    try testProgram(
        \\print(sizeof(func(int) int))
    , "8\n");
}

test "sizeof variant type" {
    try testProgram(
        \\print(sizeof(int | float))
    , "5\n");
}

test "sizeof used in arithmetic" {
    try testProgram(
        \\print(sizeof(int) + sizeof(int))
    , "8\n");
}

test "sizeof used in variable" {
    try testProgram(
        \\const s = sizeof(int)
        \\print(s)
    , "4\n");
}

test "inferred return type from explicit return" {
    try testProgram(
        \\comptime f = func(var x: int)
        \\  return x
        \\
        \\comptime main = func()
        \\  print(f(42))
        \\
    , "42\n");
}

test "inferred return type from body expression" {
    try testProgram(
        \\comptime f = func(a: int, b: int)
        \\  a + b
        \\
        \\comptime main = func()
        \\  print(f(20, 22))
        \\
    , "42\n");
}

test "inferred return type multiple returns same type" {
    try testProgram(
        \\comptime f = func(b: bool)
        \\  if b == true -> return 42
        \\  return 99
        \\
        \\comptime main = func()
        \\  print(f(true))
        \\  print(f(false))
        \\
    , "42\n99\n");
}

test "inferred return type multiple returns different types yields variant" {
    try testProgram(
        \\comptime f = func(b: bool)
        \\  if b == true -> return 42
        \\  return 1.0
        \\
        \\comptime main = func()
        \\  if const v = f(true) as int -> print(v)
        \\  if const v = f(false) as float -> print(v)
        \\
    , "42\n1.000000\n");
}

test "inferred return type no returns body expression yields unit" {
    try testProgram(
        \\comptime f = func()
        \\  none
        \\
        \\comptime main = func()
        \\  print(1)
        \\
    , "1\n");
}

test "inferred return type with monomorphized function" {
    try testProgram(
        \\comptime wrap = func(comptime T: type, var x: T)
        \\  return x
        \\
        \\comptime main = func()
        \\  print(wrap(int, 42))
        \\  print(wrap(float, 1.5))
        \\
    , "42\n1.500000\n");
}

test "inferred return type recursive function" {
    try testProgram(
        \\comptime trail = func(x: int)
        \\  if x == 0 -> return 0
        \\  trail(x - 1)
        \\  return 0
        \\
        \\comptime main = func()
        \\  print(trail(5))
        \\
    , "0\n");
}

test "inferred return type explicit annotation still works" {
    try testProgram(
        \\comptime f = func(a: int, b: int) int
        \\  return a + b
        \\
        \\comptime main = func()
        \\  print(f(20, 22))
        \\
    , "42\n");
}
