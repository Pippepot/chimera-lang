const std = @import("std");
const testing = std.testing;
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
